#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// BSD runtime (long-running launchd-managed service, mirrors scraper.js's
// multi-cadence pattern — no HTTP port, just timed jobs):
//
//   - leagues refresh                                   every 12h  (+ on start)
//   - bounded current/recent events refresh             every 15m (+ on start)
//   - live poll (/events/live)                           every 5s while a match
//     is in progress, dropping to a 30s recon between matches
//   - incidents poll for in-progress events             every 10s
//   - lineups poll for live and soon-to-start events on an adaptive cadence
//   - post-match event/incidents/lineups reconciliation at 0m, 2m and 15m
//   - standings (tables): 30s poll while an allowlisted league has a match
//     in progress, a one-off settle-flush the moment it stops, otherwise once
//     daily at midnight London time (+ on start)
//
// Run: BSD_API_KEY=... MONGODB_URI_TOP_SCORES=... node api/bsd_poller.js
// Stop with Ctrl-C / SIGTERM (graceful: clears timers, closes Mongo).
// ---------------------------------------------------------------------------

const bsd = require("./bsd_client");
const http = require("http");
const crypto = require("crypto");
const bsdHttpMetrics = require("./bsd_http_metrics");
const {
  eventToRecord,
  refreshIncrementalEvents,
} = require("./fetch_bsd_events");
const {
  ingestLeagues,
  ingestStandings,
  refreshAllStandings,
  refreshAllReference,
} = require("./fetch_bsd_reference");
const { refreshAllBroadcasts } = require("./fetch_bsd_broadcasts");
const { refreshAllPredictions } = require("./fetch_bsd_predictions");
const { projectBsdMatches } = require("./bsd_adapter");
const { BSD_LEAGUE_ALLOWLIST } = require("./bsd_config");
const {
  upsertBsdRecords,
  upsertBsdRecord,
  getBsdRecords,
  saveOperationalDataset,
  getOperationalDatasetMetadata,
  closeMongoConnection,
} = require("./mongo_client");

const BSD_CURRENT_MATCHES_DATASET = "bsd_current_matches";

const LIVE_POLL_MS = Number(process.env.BSD_LIVE_POLL_MS || 5_000);
// With no match in progress, /events/live is only checked at this lighter
// recon cadence; the full LIVE_POLL_MS cadence resumes once a match appears.
const LIVE_IDLE_POLL_MS = Number(process.env.BSD_LIVE_IDLE_POLL_MS || 30_000);
const INCIDENTS_POLL_MS = Number(process.env.BSD_INCIDENTS_POLL_MS || 10_000);
const LINEUPS_POLL_MS = Number(process.env.BSD_LINEUPS_POLL_MS || 30_000);
const REFERENCE_REFRESH_MS = Number(process.env.BSD_REFERENCE_REFRESH_MS || 12 * 60 * 60 * 1000);
const EVENTS_REFRESH_MS = Number(process.env.BSD_EVENTS_REFRESH_MS || 15 * 60 * 1000);
const BROADCASTS_REFRESH_MS = Number(process.env.BSD_BROADCASTS_REFRESH_MS || 6 * 60 * 60 * 1000);
const PREDICTIONS_REFRESH_MS = Number(process.env.BSD_PREDICTIONS_REFRESH_MS || 6 * 60 * 60 * 1000);
// Standings (tables): poll cadence while an allowlisted league has a live match.
const STANDINGS_LIVE_POLL_MS = Number(process.env.BSD_STANDINGS_LIVE_POLL_MS || 30_000);
const DETAIL_FETCH_CONCURRENCY = Math.max(
  1,
  Math.floor(Number(process.env.BSD_DETAIL_FETCH_CONCURRENCY) || 8)
);
const PREMATCH_LINEUP_WINDOW_MS = Number(
  process.env.BSD_PREMATCH_LINEUP_WINDOW_MS || 2 * 60 * 60 * 1000
);
const PREMATCH_LINEUP_CLOSE_WINDOW_MS = Number(
  process.env.BSD_PREMATCH_LINEUP_CLOSE_WINDOW_MS || 45 * 60 * 1000
);
const PREMATCH_LINEUP_EARLY_POLL_MS = Number(
  process.env.BSD_PREMATCH_LINEUP_EARLY_POLL_MS || 5 * 60 * 1000
);
const PREMATCH_LINEUP_CLOSE_POLL_MS = Number(
  process.env.BSD_PREMATCH_LINEUP_CLOSE_POLL_MS || 60_000
);
const SETTLEMENT_DELAYS_MS = String(process.env.BSD_SETTLEMENT_DELAYS_MS || "0,120000,900000")
  .split(",")
  .map((value) => Number(value))
  .filter((value) => Number.isFinite(value) && value >= 0);
const BSD_METRICS_PORT = Number(process.env.BSD_METRICS_PORT || 3016);
// Standings daily refresh target time (London), used once no league is live.
const STANDINGS_DAILY_HOUR_UK = Number(process.env.BSD_STANDINGS_DAILY_HOUR_UK ?? 0);
const STANDINGS_DAILY_MINUTE_UK = Number(process.env.BSD_STANDINGS_DAILY_MINUTE_UK ?? 15);

// Ids of events currently reported live by /events/live.
let liveEventIds = [];
// Allowlisted league ids with at least one currently live match.
let liveLeagueIds = new Set();
let livePollInFlight = false;
let lastLivePollAt = 0;
let incidentsPollInFlight = false;
let lineupsPollInFlight = false;
let referenceRefreshInFlight = false;
let eventsRefreshInFlight = false;
let broadcastsRefreshInFlight = false;
let predictionsRefreshInFlight = false;
let standingsPollInFlight = false;
let standingsDailyRefreshTimer = null;
let metricsServer = null;
let timers = [];
let projectionRefreshInFlight = false;
let projectionRefreshPending = false;
let currentMatchesProjectionHash = null;
let liveEventsPayloadHash = null;
const incidentPayloadHashes = new Map();
const settlementTimers = new Map();
const lastSuccessfulPollAt = new Map();

bsd.setRequestObserver(bsdHttpMetrics.trackRequestMetric);

function markPollSuccess(name) {
  lastSuccessfulPollAt.set(name, Date.now());
}

function hashPayload(payload) {
  return crypto.createHash("sha1").update(JSON.stringify(payload)).digest("hex");
}

async function mapWithConcurrency(items, concurrency, worker) {
  const source = Array.isArray(items) ? items : [];
  if (source.length === 0) return [];
  const results = new Array(source.length);
  let nextIndex = 0;
  const workerCount = Math.min(
    source.length,
    Math.max(1, Math.floor(Number(concurrency) || 1))
  );
  const workers = Array.from({ length: workerCount }, async () => {
    while (nextIndex < source.length) {
      const index = nextIndex;
      nextIndex += 1;
      // eslint-disable-next-line no-await-in-loop
      results[index] = await worker(source[index], index);
    }
  });
  await Promise.all(workers);
  return results;
}

async function refreshCurrentMatchesProjection(reason) {
  if (projectionRefreshInFlight) {
    projectionRefreshPending = true;
    return;
  }
  projectionRefreshInFlight = true;
  try {
    do {
      projectionRefreshPending = false;
      const startedAt = Date.now();
      const matches = await projectBsdMatches();
      const payloadHash = hashPayload(matches);
      if (!currentMatchesProjectionHash) {
        const existingMetadata = await getOperationalDatasetMetadata([
          BSD_CURRENT_MATCHES_DATASET,
        ]);
        currentMatchesProjectionHash =
          existingMetadata && existingMetadata[BSD_CURRENT_MATCHES_DATASET]
            ? existingMetadata[BSD_CURRENT_MATCHES_DATASET].payload_hash || null
            : null;
      }
      if (payloadHash === currentMatchesProjectionHash) {
        continue;
      }
      await saveOperationalDataset({
        name: BSD_CURRENT_MATCHES_DATASET,
        updated_at: new Date().toISOString(),
        source: `bsd_poller:${reason}`,
        payload: matches,
        payload_count: matches.length,
        payload_hash: payloadHash,
      });
      currentMatchesProjectionHash = payloadHash;
      console.log(
        `[bsd-runtime] current match projection: ${matches.length} matches in ${Date.now() - startedAt}ms`
      );
    } while (projectionRefreshPending);
  } catch (error) {
    console.error(`[bsd-runtime] projection refresh failed: ${error.message || error}`);
  } finally {
    projectionRefreshInFlight = false;
  }
}

// Mirrors server.js's millisecondsUntilNextLondonTime — duplicated rather than
// shared because bsd_poller.js is a separate standalone process from the
// Express app and importing server.js would start the whole HTTP server.
const londonDateTimeFormatter = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/London",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hour12: false,
});

function londonDateTimeParts(date) {
  const parts = londonDateTimeFormatter.formatToParts(date);
  const values = {};
  for (const part of parts) {
    if (part.type === "literal") continue;
    values[part.type] = Number(part.value);
  }
  return {
    hour: Number.isFinite(values.hour) ? values.hour : 0,
    minute: Number.isFinite(values.minute) ? values.minute : 0,
  };
}

function millisecondsUntilNextLondonTime(targetHour, targetMinute, now = new Date()) {
  const safeHour = Number.isFinite(targetHour) ? Math.max(0, Math.min(23, Math.floor(targetHour))) : 0;
  const safeMinute = Number.isFinite(targetMinute)
    ? Math.max(0, Math.min(59, Math.floor(targetMinute)))
    : 0;

  const maxMinutesToSearch = 60 * 48;
  let candidate = new Date(now.getTime() + 60 * 1000);
  for (let i = 0; i < maxMinutesToSearch; i += 1) {
    const parts = londonDateTimeParts(candidate);
    if (parts.hour === safeHour && parts.minute === safeMinute) {
      candidate.setSeconds(0, 0);
      return Math.max(1000, candidate.getTime() - now.getTime());
    }
    candidate = new Date(candidate.getTime() + 60 * 1000);
  }
  return 24 * 60 * 60 * 1000;
}

// Pure helpers (exported for testing) for the live-league tracking that
// drives the standings live-poll/settle-flush tiers.
function computeLiveLeagueIds(events, allowlist) {
  const allowlistSet = new Set((allowlist || []).map(String));
  const ids = new Set();
  (Array.isArray(events) ? events : []).forEach((event) => {
    const id = event && event.league_id != null ? String(event.league_id) : null;
    if (id && allowlistSet.has(id)) ids.add(id);
  });
  return ids;
}

function filterAllowlistedLiveEvents(events, allowlist) {
  const allowlistSet = new Set((allowlist || []).map(String));
  return (Array.isArray(events) ? events : []).filter((event) => {
    const leagueId = event && event.league_id != null ? String(event.league_id) : null;
    return event && event.id != null && leagueId && allowlistSet.has(leagueId);
  });
}

function diffSettledLeagueIds(previousLiveIds, nextLiveIds) {
  return [...previousLiveIds].filter((id) => !nextLiveIds.has(id));
}

function diffSettledEventIds(previousLiveIds, nextLiveIds) {
  const next = new Set((nextLiveIds || []).map(String));
  return (previousLiveIds || []).filter((id) => !next.has(String(id)));
}

async function pollLiveEvents() {
  if (livePollInFlight) return;
  // Downtime tier: nothing was live on the last check, so only recon at the
  // lighter cadence. The 10s interval keeps ticking, so the full cadence
  // resumes on the first poll that finds a live match.
  if (liveEventIds.length === 0 && Date.now() - lastLivePollAt < LIVE_IDLE_POLL_MS) return;
  livePollInFlight = true;
  lastLivePollAt = Date.now();
  try {
    const data = await bsd.getLiveEvents({ initiator: "bsd_runtime" });
    const events = Array.isArray(data && data.events) ? data.events : [];
    const allowlistedEvents = filterAllowlistedLiveEvents(events, BSD_LEAGUE_ALLOWLIST);
    const nextLiveEventIds = allowlistedEvents.map((event) => event.id);
    const settledEventIds = diffSettledEventIds(liveEventIds, nextLiveEventIds);
    liveEventIds = nextLiveEventIds;
    const nextLiveEventsPayloadHash = hashPayload(allowlistedEvents);
    const liveEventsChanged = nextLiveEventsPayloadHash !== liveEventsPayloadHash;
    if (liveEventsChanged && allowlistedEvents.length > 0) {
      await upsertBsdRecords("bsd_events", allowlistedEvents.map(eventToRecord));
    }
    liveEventsPayloadHash = nextLiveEventsPayloadHash;

    const nextLiveLeagueIds = computeLiveLeagueIds(events, BSD_LEAGUE_ALLOWLIST);
    const settledLeagueIds = diffSettledLeagueIds(liveLeagueIds, nextLiveLeagueIds);
    liveLeagueIds = nextLiveLeagueIds;
    if (settledLeagueIds.length > 0) {
      void flushSettledStandings(settledLeagueIds);
    }
    if (settledEventIds.length > 0) {
      settledEventIds.forEach((id) => incidentPayloadHashes.delete(String(id)));
      scheduleSettledEventReconciliation(settledEventIds);
    }

    console.log(
      `[bsd-runtime] live events: ${allowlistedEvents.length} allowlisted/${events.length} global`
    );
    markPollSuccess("live_events");
    if (liveEventsChanged) void refreshCurrentMatchesProjection("live_events");
  } catch (error) {
    console.error(`[bsd-runtime] live poll failed: ${error.message || error}`);
  } finally {
    livePollInFlight = false;
  }
}

// One final standings fetch for a league the moment its last live match ends,
// so the table reflects the result without waiting for the daily refresh.
async function flushSettledStandings(leagueIds) {
  await mapWithConcurrency(leagueIds, DETAIL_FETCH_CONCURRENCY, async (leagueId) => {
    try {
      await ingestStandings(leagueId);
    } catch (error) {
      console.error(`[bsd-runtime] settled standings league ${leagueId} failed: ${error.message || error}`);
    }
  });
}

async function reconcileSettledEvent(eventId) {
  const options = { initiator: "bsd_runtime", trigger: "post_match_settlement" };
  const [eventResult, incidentsResult, lineupsResult] = await Promise.allSettled([
    bsd.getEvent(eventId, options),
    bsd.getIncidents(eventId, options),
    bsd.getLineups(eventId, options),
  ]);

  if (eventResult.status === "fulfilled" && eventResult.value) {
    await upsertBsdRecords("bsd_events", [eventToRecord(eventResult.value)]);
  } else if (eventResult.status === "rejected") {
    console.error(
      `[bsd-runtime] settled event ${eventId} detail failed: ${eventResult.reason.message || eventResult.reason}`
    );
  }

  if (incidentsResult.status === "fulfilled") {
    const incidents = incidentsResult.value;
    await upsertBsdRecord("bsd_incidents", eventId, incidents, {
      event_id: incidents && incidents.event_id != null ? incidents.event_id : eventId,
    });
  } else {
    console.error(
      `[bsd-runtime] settled event ${eventId} incidents failed: ${incidentsResult.reason.message || incidentsResult.reason}`
    );
  }

  if (lineupsResult.status === "fulfilled") {
    const lineups = lineupsResult.value;
    await upsertBsdRecord("bsd_lineups", eventId, lineups, {
      event_id: lineups && lineups.event_id != null ? lineups.event_id : eventId,
      lineup_status: (lineups && lineups.lineup_status) || null,
    });
  } else {
    console.error(
      `[bsd-runtime] settled event ${eventId} lineups failed: ${lineupsResult.reason.message || lineupsResult.reason}`
    );
  }
}

async function reconcileSettledEvents(eventIds, reason) {
  await mapWithConcurrency(eventIds, DETAIL_FETCH_CONCURRENCY, async (eventId) => {
    try {
      await reconcileSettledEvent(eventId);
    } catch (error) {
      console.error(`[bsd-runtime] settled event ${eventId} reconciliation failed: ${error.message || error}`);
    }
  });
  markPollSuccess("settlement");
  void refreshCurrentMatchesProjection(`settlement_${reason}`);
}

function scheduleSettledEventReconciliation(eventIds) {
  const ids = [...new Set((eventIds || []).map(String).filter(Boolean))];
  if (ids.length === 0) return;
  SETTLEMENT_DELAYS_MS.forEach((delayMs) => {
    if (delayMs === 0) {
      void reconcileSettledEvents(ids, "immediate");
      return;
    }
    const timer = setTimeout(() => {
      settlementTimers.delete(timer);
      void reconcileSettledEvents(ids, `${delayMs}ms`);
    }, delayMs);
    settlementTimers.set(timer, timer);
    if (timer && typeof timer.unref === "function") timer.unref();
  });
}

// Standings for every league currently flagged live — the "poll every minute
// while matches are in progress" tier.
async function pollLiveStandings() {
  if (standingsPollInFlight || liveLeagueIds.size === 0) return;
  standingsPollInFlight = true;
  const leagueIds = [...liveLeagueIds];
  try {
    await mapWithConcurrency(leagueIds, DETAIL_FETCH_CONCURRENCY, async (leagueId) => {
      try {
        await ingestStandings(leagueId);
      } catch (error) {
        console.error(`[bsd-runtime] live standings league ${leagueId} failed: ${error.message || error}`);
      }
    });
    markPollSuccess("standings");
  } finally {
    standingsPollInFlight = false;
  }
}

function scheduleStandingsDailyRefresh() {
  if (standingsDailyRefreshTimer) {
    clearTimeout(standingsDailyRefreshTimer);
    standingsDailyRefreshTimer = null;
  }
  const delayMs = millisecondsUntilNextLondonTime(STANDINGS_DAILY_HOUR_UK, STANDINGS_DAILY_MINUTE_UK);
  standingsDailyRefreshTimer = setTimeout(async () => {
    standingsDailyRefreshTimer = null;
    try {
      await refreshAllStandings();
      markPollSuccess("standings");
      console.log("[bsd-runtime] daily standings refresh complete");
    } catch (error) {
      console.error(`[bsd-runtime] daily standings refresh failed: ${error.message || error}`);
    } finally {
      scheduleStandingsDailyRefresh();
    }
  }, delayMs);
  if (standingsDailyRefreshTimer && typeof standingsDailyRefreshTimer.unref === "function") {
    standingsDailyRefreshTimer.unref();
  }
}

function buildMetricsText() {
  const base = bsdHttpMetrics.buildPrometheusMetricsText({
    runtime: "bsd_poller",
    service: "top-scores-bsd-poller",
  });
  const memory = process.memoryUsage();
  const rateLimit = bsd.getRateLimitState();
  const freshnessLines = [];
  [...lastSuccessfulPollAt.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .forEach(([poll, timestampMs]) => {
      freshnessLines.push(
        `top_scores_bsd_poll_last_success_timestamp_seconds{poll="${poll}"} ${timestampMs / 1000}`
      );
    });
  return `${base.trimEnd()}\n` + [
    "# HELP top_scores_bsd_live_events Current number of allowlisted live events.",
    "# TYPE top_scores_bsd_live_events gauge",
    `top_scores_bsd_live_events ${liveEventIds.length}`,
    "# HELP top_scores_bsd_rate_limiter_tokens Currently available BSD request tokens.",
    "# TYPE top_scores_bsd_rate_limiter_tokens gauge",
    `top_scores_bsd_rate_limiter_tokens ${rateLimit.tokens}`,
    "# HELP top_scores_bsd_rate_limiter_queue_depth Requests waiting for a BSD rate-limit token.",
    "# TYPE top_scores_bsd_rate_limiter_queue_depth gauge",
    `top_scores_bsd_rate_limiter_queue_depth ${rateLimit.queueDepth}`,
    "# HELP top_scores_bsd_request_concurrency Current and maximum concurrent BSD HTTP requests.",
    "# TYPE top_scores_bsd_request_concurrency gauge",
    `top_scores_bsd_request_concurrency{kind="active"} ${rateLimit.activeRequests}`,
    `top_scores_bsd_request_concurrency{kind="max"} ${rateLimit.maxConcurrentRequests}`,
    "# HELP top_scores_bsd_request_queue_depth Requests waiting for a BSD HTTP concurrency slot.",
    "# TYPE top_scores_bsd_request_queue_depth gauge",
    `top_scores_bsd_request_queue_depth ${rateLimit.requestQueueDepth}`,
    "# HELP top_scores_bsd_poll_last_success_timestamp_seconds Unix timestamp of the latest successful poll cycle.",
    "# TYPE top_scores_bsd_poll_last_success_timestamp_seconds gauge",
    ...freshnessLines,
    "# HELP top_scores_process_resident_memory_bytes Resident set size of the BSD poller process.",
    "# TYPE top_scores_process_resident_memory_bytes gauge",
    `top_scores_process_resident_memory_bytes ${memory.rss}`,
    "# HELP top_scores_process_heap_bytes V8 heap usage and capacity of the BSD poller process.",
    "# TYPE top_scores_process_heap_bytes gauge",
    `top_scores_process_heap_bytes{kind=\"used\"} ${memory.heapUsed}`,
    `top_scores_process_heap_bytes{kind=\"total\"} ${memory.heapTotal}`,
    "# HELP top_scores_process_external_memory_bytes External memory held by the BSD poller process.",
    "# TYPE top_scores_process_external_memory_bytes gauge",
    `top_scores_process_external_memory_bytes ${memory.external}`,
    "# HELP top_scores_process_uptime_seconds Uptime of the BSD poller process.",
    "# TYPE top_scores_process_uptime_seconds gauge",
    `top_scores_process_uptime_seconds ${process.uptime()}`,
    "",
  ].join("\n");
}

function startMetricsServer() {
  if (!Number.isFinite(BSD_METRICS_PORT) || BSD_METRICS_PORT <= 0) {
    console.log("[bsd-runtime] metrics endpoint disabled");
    return null;
  }
  if (metricsServer) return metricsServer;

  const server = http.createServer((req, res) => {
    const path = String(req.url || "").split("?")[0];
    if (path === "/health") {
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ ok: true, service: "top-scores-bsd-poller" }));
      return;
    }
    if (path === "/metrics") {
      res.writeHead(200, { "Content-Type": "text/plain; version=0.0.4; charset=utf-8" });
      res.end(buildMetricsText());
      return;
    }
    res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("Not found\n");
  });

  // A broken metrics endpoint (e.g. port already in use) must never take down
  // data ingestion — log and carry on without metrics.
  server.on("error", (error) => {
    console.error(`[bsd-runtime] metrics server error: ${error.message || error}`);
    if (metricsServer === server) metricsServer = null;
  });

  metricsServer = server;
  server.listen(BSD_METRICS_PORT, () => {
    console.log(`[bsd-runtime] metrics listening on http://localhost:${BSD_METRICS_PORT}/metrics`);
  });
  return metricsServer;
}

function closeMetricsServer() {
  if (!metricsServer) return Promise.resolve();
  const server = metricsServer;
  metricsServer = null;
  return new Promise((resolve) => {
    server.close(() => resolve());
  });
}

async function pollIncidents() {
  if (incidentsPollInFlight) return;
  if (liveEventIds.length === 0) {
    markPollSuccess("incidents");
    return;
  }
  incidentsPollInFlight = true;
  const ids = [...liveEventIds];
  try {
    let changedCount = 0;
    await mapWithConcurrency(ids, DETAIL_FETCH_CONCURRENCY, async (id) => {
      try {
        const incidents = await bsd.getIncidents(id, { initiator: "bsd_runtime" });
        const nextHash = hashPayload(incidents);
        if (incidentPayloadHashes.get(String(id)) === nextHash) return;
        await upsertBsdRecord("bsd_incidents", id, incidents, {
          event_id: incidents && incidents.event_id != null ? incidents.event_id : id,
        });
        incidentPayloadHashes.set(String(id), nextHash);
        changedCount += 1;
      } catch (error) {
        console.error(`[bsd-runtime] incidents event ${id} failed: ${error.message || error}`);
      }
    });
    console.log(
      `[bsd-runtime] incidents polled for ${ids.length} events (${changedCount} changed)`
    );
    markPollSuccess("incidents");
    if (changedCount > 0) void refreshCurrentMatchesProjection("incidents");
  } finally {
    incidentsPollInFlight = false;
  }
}

function selectPrematchLineupEventIds(
  events,
  lineupDocs,
  currentLiveIds,
  nowMs = Date.now(),
  options = {}
) {
  const windowMs = Number(options.windowMs ?? PREMATCH_LINEUP_WINDOW_MS);
  const closeWindowMs = Number(options.closeWindowMs ?? PREMATCH_LINEUP_CLOSE_WINDOW_MS);
  const earlyPollMs = Number(options.earlyPollMs ?? PREMATCH_LINEUP_EARLY_POLL_MS);
  const closePollMs = Number(options.closePollMs ?? PREMATCH_LINEUP_CLOSE_POLL_MS);
  const liveIds = new Set((currentLiveIds || []).map(String));
  const lineupsById = new Map(
    (lineupDocs || []).map((doc) => [String(doc && doc._id), doc])
  );

  return (events || [])
    .filter((event) => {
      if (!event || event._id == null) return false;
      const id = String(event._id);
      if (liveIds.has(id)) return false;
      const status = String(event.status || (event.payload && event.payload.status) || "").toLowerCase();
      if (status !== "notstarted") return false;
      const kickoffMs = Date.parse(
        event.event_date || (event.payload && event.payload.event_date) || ""
      );
      const untilKickoffMs = kickoffMs - nowMs;
      if (!Number.isFinite(kickoffMs) || untilKickoffMs < 0 || untilKickoffMs > windowMs) {
        return false;
      }

      const lineupDoc = lineupsById.get(id);
      const lineupStatus = String(
        (lineupDoc && lineupDoc.lineup_status) ||
          (lineupDoc && lineupDoc.payload && lineupDoc.payload.lineup_status) ||
          ""
      ).toLowerCase();
      if (lineupStatus === "confirmed") return false;

      const lastPollMs = Date.parse((lineupDoc && lineupDoc.updated_at) || "");
      if (!Number.isFinite(lastPollMs)) return true;
      const cadenceMs = untilKickoffMs <= closeWindowMs ? closePollMs : earlyPollMs;
      return nowMs - lastPollMs >= cadenceMs;
    })
    .map((event) => String(event._id));
}

async function loadLineupPollCandidates(nowMs = Date.now()) {
  const liveIds = [...new Set(liveEventIds.map(String))];
  const startIso = new Date(nowMs).toISOString();
  const endIso = new Date(nowMs + PREMATCH_LINEUP_WINDOW_MS).toISOString();
  const upcomingEvents = await getBsdRecords(
    "bsd_events",
    {
      status: "notstarted",
      event_date: { $gte: startIso, $lte: endIso },
    },
    {
      projection: { _id: 1, status: 1, event_date: 1, payload: 1 },
      sort: { event_date: 1 },
    }
  );
  const candidateIds = [...new Set([...liveIds, ...upcomingEvents.map((event) => String(event._id))])];
  const lineupDocs = candidateIds.length > 0
    ? await getBsdRecords("bsd_lineups", { _id: { $in: candidateIds } })
    : [];
  const lineupsById = new Map(lineupDocs.map((doc) => [String(doc._id), doc]));
  const unconfirmedLiveIds = liveIds.filter((id) => {
    const doc = lineupsById.get(id);
    return String(
      (doc && doc.lineup_status) || (doc && doc.payload && doc.payload.lineup_status) || ""
    ).toLowerCase() !== "confirmed";
  });
  const prematchIds = selectPrematchLineupEventIds(
    upcomingEvents,
    lineupDocs,
    liveIds,
    nowMs
  );
  return [...new Set([...unconfirmedLiveIds, ...prematchIds])];
}

// Poll lineups for live matches and upcoming matches inside the pre-match
// window. The candidate selector slows down outside the final 45 minutes and
// stops as soon as BSD reports a confirmed lineup.
async function pollLineups() {
  if (lineupsPollInFlight) return;
  lineupsPollInFlight = true;
  try {
    const ids = await loadLineupPollCandidates();
    await mapWithConcurrency(ids, DETAIL_FETCH_CONCURRENCY, async (id) => {
      try {
        const lineups = await bsd.getLineups(id, { initiator: "bsd_runtime" });
        await upsertBsdRecord("bsd_lineups", id, lineups, {
          event_id: lineups && lineups.event_id != null ? lineups.event_id : id,
          lineup_status: (lineups && lineups.lineup_status) || null,
        });
      } catch (error) {
        console.error(`[bsd-runtime] lineups event ${id} failed: ${error.message || error}`);
      }
    });
    if (ids.length > 0) console.log(`[bsd-runtime] lineups polled for ${ids.length} events`);
    markPollSuccess("lineups");
  } finally {
    lineupsPollInFlight = false;
  }
}

// Initial on-start population: leagues + standings, so a freshly deployed
// process is fully populated before the standings live/daily cadences below
// have had a chance to run.
async function refreshReference() {
  if (referenceRefreshInFlight) return;
  referenceRefreshInFlight = true;
  try {
    await refreshAllReference();
    markPollSuccess("reference");
    void refreshCurrentMatchesProjection("reference");
  } catch (error) {
    console.error(`[bsd-runtime] reference refresh failed: ${error.message || error}`);
  } finally {
    referenceRefreshInFlight = false;
  }
}

// Recurring 12h slot: leagues only — standings now have their own live/daily
// cadence (see pollLiveStandings / scheduleStandingsDailyRefresh below).
async function refreshLeagues() {
  if (referenceRefreshInFlight) return;
  referenceRefreshInFlight = true;
  try {
    await ingestLeagues();
    markPollSuccess("leagues");
    void refreshCurrentMatchesProjection("leagues");
  } catch (error) {
    console.error(`[bsd-runtime] leagues refresh failed: ${error.message || error}`);
  } finally {
    referenceRefreshInFlight = false;
  }
}

async function refreshEvents() {
  if (eventsRefreshInFlight) return;
  eventsRefreshInFlight = true;
  try {
    await refreshIncrementalEvents();
    markPollSuccess("events");
    void refreshCurrentMatchesProjection("events_refresh");
  } catch (error) {
    console.error(`[bsd-runtime] events refresh failed: ${error.message || error}`);
  } finally {
    eventsRefreshInFlight = false;
  }
}

async function refreshBroadcasts() {
  if (broadcastsRefreshInFlight) return;
  broadcastsRefreshInFlight = true;
  try {
    await refreshAllBroadcasts();
    markPollSuccess("broadcasts");
    void refreshCurrentMatchesProjection("broadcasts");
  } catch (error) {
    console.error(`[bsd-runtime] broadcasts refresh failed: ${error.message || error}`);
  } finally {
    broadcastsRefreshInFlight = false;
  }
}

async function refreshPredictions() {
  if (predictionsRefreshInFlight) return;
  predictionsRefreshInFlight = true;
  try {
    await refreshAllPredictions();
    markPollSuccess("predictions");
  } catch (error) {
    console.error(`[bsd-runtime] predictions refresh failed: ${error.message || error}`);
  } finally {
    predictionsRefreshInFlight = false;
  }
}

function start() {
  console.log(
    `[bsd-runtime] starting (live=${LIVE_POLL_MS}ms, live_idle=${LIVE_IDLE_POLL_MS}ms, incidents=${INCIDENTS_POLL_MS}ms, ` +
      `lineups=${LINEUPS_POLL_MS}ms, events=${EVENTS_REFRESH_MS}ms, reference=${REFERENCE_REFRESH_MS}ms, ` +
      `broadcasts=${BROADCASTS_REFRESH_MS}ms, predictions=${PREDICTIONS_REFRESH_MS}ms, ` +
      `standings_live=${STANDINGS_LIVE_POLL_MS}ms, standings_daily=${STANDINGS_DAILY_HOUR_UK}:${String(STANDINGS_DAILY_MINUTE_UK).padStart(2, "0")} Europe/London)`
  );

  startMetricsServer();

  // Kick off immediate runs so a freshly started/deployed process is
  // populated without waiting for the first interval to elapse.
  refreshReference();
  refreshEvents();
  refreshBroadcasts();
  refreshPredictions();
  pollLiveEvents();
  pollLineups();
  scheduleStandingsDailyRefresh();

  timers.push(setInterval(pollLiveEvents, LIVE_POLL_MS));
  timers.push(setInterval(pollIncidents, INCIDENTS_POLL_MS));
  timers.push(setInterval(pollLineups, LINEUPS_POLL_MS));
  timers.push(setInterval(pollLiveStandings, STANDINGS_LIVE_POLL_MS));
  timers.push(setInterval(refreshEvents, EVENTS_REFRESH_MS));
  timers.push(setInterval(refreshLeagues, REFERENCE_REFRESH_MS));
  timers.push(setInterval(refreshBroadcasts, BROADCASTS_REFRESH_MS));
  timers.push(setInterval(refreshPredictions, PREDICTIONS_REFRESH_MS));
}

async function stop(signal) {
  console.log(`[bsd-runtime] ${signal} received, shutting down`);
  timers.forEach((timer) => clearInterval(timer));
  timers = [];
  if (standingsDailyRefreshTimer) {
    clearTimeout(standingsDailyRefreshTimer);
    standingsDailyRefreshTimer = null;
  }
  settlementTimers.forEach((timer) => clearTimeout(timer));
  settlementTimers.clear();
  try {
    await closeMetricsServer();
    await closeMongoConnection();
  } catch (_err) {
    // best effort
  }
  process.exit(0);
}

if (require.main === module) {
  process.on("SIGINT", () => stop("SIGINT"));
  process.on("SIGTERM", () => stop("SIGTERM"));
  start();
}

module.exports = {
  pollLiveEvents,
  pollIncidents,
  pollLineups,
  pollLiveStandings,
  flushSettledStandings,
  reconcileSettledEvent,
  reconcileSettledEvents,
  scheduleSettledEventReconciliation,
  scheduleStandingsDailyRefresh,
  refreshReference,
  refreshLeagues,
  refreshEvents,
  refreshBroadcasts,
  refreshPredictions,
  startMetricsServer,
  closeMetricsServer,
  start,
  stop,
  __private: {
    computeLiveLeagueIds,
    filterAllowlistedLiveEvents,
    diffSettledLeagueIds,
    diffSettledEventIds,
    mapWithConcurrency,
    selectPrematchLineupEventIds,
    millisecondsUntilNextLondonTime,
    buildMetricsText,
  },
};
