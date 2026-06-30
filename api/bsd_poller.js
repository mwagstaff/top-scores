#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// BSD runtime (long-running launchd-managed service, mirrors scraper.js's
// multi-cadence pattern — no HTTP port, just timed jobs):
//
//   - leagues refresh                                   every 12h  (+ on start)
//   - events refresh (events + incidents/lineups/teams) every 1h (+ on start)
//   - live poll (/events/live)                          every 10s
//   - incidents poll for in-progress events              every 30s
//   - lineups poll for in-progress events not yet confirmed every 30s
//   - standings (tables): live poll while an allowlisted league has a match
//     in progress, a one-off settle-flush the moment it stops, otherwise once
//     daily at midnight London time (+ on start)
//
// Run: BSD_API_KEY=... MONGODB_URI_TOP_SCORES=... node api/bsd_poller.js
// Stop with Ctrl-C / SIGTERM (graceful: clears timers, closes Mongo).
// ---------------------------------------------------------------------------

const bsd = require("./bsd_client");
const { eventToRecord, refreshAllEvents } = require("./fetch_bsd_events");
const {
  ingestLeagues,
  ingestStandings,
  refreshAllStandings,
  refreshAllReference,
} = require("./fetch_bsd_reference");
const { refreshAllBroadcasts } = require("./fetch_bsd_broadcasts");
const { refreshAllPredictions } = require("./fetch_bsd_predictions");
const { buildBsdTsdbMaps } = require("./bsd_player_map");
const { BSD_LEAGUE_ALLOWLIST } = require("./bsd_config");
const {
  upsertBsdRecords,
  upsertBsdRecord,
  getBsdRecord,
  closeMongoConnection,
} = require("./mongo_client");

const LIVE_POLL_MS = Number(process.env.BSD_LIVE_POLL_MS || 10_000);
const INCIDENTS_POLL_MS = Number(process.env.BSD_INCIDENTS_POLL_MS || 30_000);
const LINEUPS_POLL_MS = Number(process.env.BSD_LINEUPS_POLL_MS || 30_000);
const REFERENCE_REFRESH_MS = Number(process.env.BSD_REFERENCE_REFRESH_MS || 12 * 60 * 60 * 1000);
const EVENTS_REFRESH_MS = Number(process.env.BSD_EVENTS_REFRESH_MS || 60 * 60 * 1000);
// TV broadcasts change rarely — a daily snapshot is plenty.
const BROADCASTS_REFRESH_MS = Number(process.env.BSD_BROADCASTS_REFRESH_MS || 24 * 60 * 60 * 1000);
// Predictions are recomputed upstream infrequently — a daily snapshot is plenty.
const PREDICTIONS_REFRESH_MS = Number(process.env.BSD_PREDICTIONS_REFRESH_MS || 24 * 60 * 60 * 1000);
// BSD<->TSDB player/team id map: rebuilt periodically as line-ups appear.
const MAP_REFRESH_MS = Number(process.env.BSD_MAP_REFRESH_MS || 5 * 60 * 1000);
// Standings (tables): poll cadence while an allowlisted league has a live match.
const STANDINGS_LIVE_POLL_MS = Number(process.env.BSD_STANDINGS_LIVE_POLL_MS || 60_000);
// Standings daily refresh target time (London), used once no league is live.
const STANDINGS_DAILY_HOUR_UK = Number(process.env.BSD_STANDINGS_DAILY_HOUR_UK ?? 0);
const STANDINGS_DAILY_MINUTE_UK = Number(process.env.BSD_STANDINGS_DAILY_MINUTE_UK ?? 15);

// Ids of events currently reported live by /events/live.
let liveEventIds = [];
// Allowlisted league ids with at least one currently live match.
let liveLeagueIds = new Set();
let livePollInFlight = false;
let incidentsPollInFlight = false;
let lineupsPollInFlight = false;
let referenceRefreshInFlight = false;
let eventsRefreshInFlight = false;
let broadcastsRefreshInFlight = false;
let predictionsRefreshInFlight = false;
let mapRefreshInFlight = false;
let standingsPollInFlight = false;
let standingsDailyRefreshTimer = null;
let timers = [];

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

function diffSettledLeagueIds(previousLiveIds, nextLiveIds) {
  return [...previousLiveIds].filter((id) => !nextLiveIds.has(id));
}

async function pollLiveEvents() {
  if (livePollInFlight) return;
  livePollInFlight = true;
  try {
    const data = await bsd.getLiveEvents({ initiator: "bsd_runtime" });
    const events = Array.isArray(data && data.events) ? data.events : [];
    liveEventIds = events
      .filter((event) => event && event.id != null)
      .map((event) => event.id);
    if (events.length > 0) {
      await upsertBsdRecords("bsd_events", events.map(eventToRecord));
    }

    const nextLiveLeagueIds = computeLiveLeagueIds(events, BSD_LEAGUE_ALLOWLIST);
    const settledLeagueIds = diffSettledLeagueIds(liveLeagueIds, nextLiveLeagueIds);
    liveLeagueIds = nextLiveLeagueIds;
    if (settledLeagueIds.length > 0) {
      void flushSettledStandings(settledLeagueIds);
    }

    console.log(`[bsd-runtime] live events: ${events.length}`);
  } catch (error) {
    console.error(`[bsd-runtime] live poll failed: ${error.message || error}`);
  } finally {
    livePollInFlight = false;
  }
}

// One final standings fetch for a league the moment its last live match ends,
// so the table reflects the result without waiting for the daily refresh.
async function flushSettledStandings(leagueIds) {
  for (const leagueId of leagueIds) {
    try {
      // eslint-disable-next-line no-await-in-loop
      await ingestStandings(leagueId);
    } catch (error) {
      console.error(`[bsd-runtime] settled standings league ${leagueId} failed: ${error.message || error}`);
    }
  }
}

// Standings for every league currently flagged live — the "poll every minute
// while matches are in progress" tier.
async function pollLiveStandings() {
  if (standingsPollInFlight || liveLeagueIds.size === 0) return;
  standingsPollInFlight = true;
  const leagueIds = [...liveLeagueIds];
  try {
    for (const leagueId of leagueIds) {
      try {
        // eslint-disable-next-line no-await-in-loop
        await ingestStandings(leagueId);
      } catch (error) {
        console.error(`[bsd-runtime] live standings league ${leagueId} failed: ${error.message || error}`);
      }
    }
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

async function pollIncidents() {
  if (incidentsPollInFlight || liveEventIds.length === 0) return;
  incidentsPollInFlight = true;
  const ids = [...liveEventIds];
  try {
    for (const id of ids) {
      try {
        // eslint-disable-next-line no-await-in-loop
        const incidents = await bsd.getIncidents(id, { initiator: "bsd_runtime" });
        // eslint-disable-next-line no-await-in-loop
        await upsertBsdRecord("bsd_incidents", id, incidents, {
          event_id: incidents && incidents.event_id != null ? incidents.event_id : id,
        });
      } catch (error) {
        console.error(`[bsd-runtime] incidents event ${id} failed: ${error.message || error}`);
      }
    }
    console.log(`[bsd-runtime] incidents polled for ${ids.length} events`);
  } finally {
    incidentsPollInFlight = false;
  }
}

// Lineups for live events are only otherwise picked up by the hourly events
// refresh, which leaves a gap for matches that kick off (or whose lineups are
// published) in between cycles. Poll lineups for live events here too, but
// skip any already confirmed — lineups rarely change once settled, so this
// keeps the extra API calls bounded to events still awaiting confirmation.
async function pollLineups() {
  if (lineupsPollInFlight || liveEventIds.length === 0) return;
  lineupsPollInFlight = true;
  const ids = [...liveEventIds];
  try {
    for (const id of ids) {
      try {
        // eslint-disable-next-line no-await-in-loop
        const existing = await getBsdRecord("bsd_lineups", id);
        if (existing && existing.lineup_status === "confirmed") continue;
        // eslint-disable-next-line no-await-in-loop
        const lineups = await bsd.getLineups(id, { initiator: "bsd_runtime" });
        // eslint-disable-next-line no-await-in-loop
        await upsertBsdRecord("bsd_lineups", id, lineups, {
          event_id: lineups && lineups.event_id != null ? lineups.event_id : id,
          lineup_status: (lineups && lineups.lineup_status) || null,
        });
      } catch (error) {
        console.error(`[bsd-runtime] lineups event ${id} failed: ${error.message || error}`);
      }
    }
    console.log(`[bsd-runtime] lineups polled for ${ids.length} events`);
  } finally {
    lineupsPollInFlight = false;
  }
}

async function refreshMaps() {
  if (mapRefreshInFlight) return;
  mapRefreshInFlight = true;
  try {
    await buildBsdTsdbMaps();
  } catch (error) {
    console.error(`[bsd-runtime] map refresh failed: ${error.message || error}`);
  } finally {
    mapRefreshInFlight = false;
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
    await refreshAllEvents();
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
  } catch (error) {
    console.error(`[bsd-runtime] predictions refresh failed: ${error.message || error}`);
  } finally {
    predictionsRefreshInFlight = false;
  }
}

function start() {
  console.log(
    `[bsd-runtime] starting (live=${LIVE_POLL_MS}ms, incidents=${INCIDENTS_POLL_MS}ms, ` +
      `lineups=${LINEUPS_POLL_MS}ms, events=${EVENTS_REFRESH_MS}ms, reference=${REFERENCE_REFRESH_MS}ms, ` +
      `broadcasts=${BROADCASTS_REFRESH_MS}ms, predictions=${PREDICTIONS_REFRESH_MS}ms, map=${MAP_REFRESH_MS}ms, ` +
      `standings_live=${STANDINGS_LIVE_POLL_MS}ms, standings_daily=${STANDINGS_DAILY_HOUR_UK}:${String(STANDINGS_DAILY_MINUTE_UK).padStart(2, "0")} Europe/London)`
  );

  // Kick off immediate runs so a freshly started/deployed process is
  // populated without waiting for the first interval to elapse.
  refreshReference();
  refreshEvents();
  refreshBroadcasts();
  refreshPredictions();
  pollLiveEvents();
  refreshMaps();
  scheduleStandingsDailyRefresh();

  timers.push(setInterval(pollLiveEvents, LIVE_POLL_MS));
  timers.push(setInterval(pollIncidents, INCIDENTS_POLL_MS));
  timers.push(setInterval(pollLineups, LINEUPS_POLL_MS));
  timers.push(setInterval(pollLiveStandings, STANDINGS_LIVE_POLL_MS));
  timers.push(setInterval(refreshEvents, EVENTS_REFRESH_MS));
  timers.push(setInterval(refreshLeagues, REFERENCE_REFRESH_MS));
  timers.push(setInterval(refreshBroadcasts, BROADCASTS_REFRESH_MS));
  timers.push(setInterval(refreshPredictions, PREDICTIONS_REFRESH_MS));
  timers.push(setInterval(refreshMaps, MAP_REFRESH_MS));
}

async function stop(signal) {
  console.log(`[bsd-runtime] ${signal} received, shutting down`);
  timers.forEach((timer) => clearInterval(timer));
  timers = [];
  if (standingsDailyRefreshTimer) {
    clearTimeout(standingsDailyRefreshTimer);
    standingsDailyRefreshTimer = null;
  }
  try {
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
  scheduleStandingsDailyRefresh,
  refreshReference,
  refreshLeagues,
  refreshEvents,
  refreshBroadcasts,
  refreshPredictions,
  refreshMaps,
  start,
  stop,
  __private: {
    computeLiveLeagueIds,
    diffSettledLeagueIds,
    millisecondsUntilNextLondonTime,
  },
};
