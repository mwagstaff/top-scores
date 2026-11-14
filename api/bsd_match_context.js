"use strict";

const bsd = require("./bsd_client");
const { getBsdRecords, upsertBsdRecord } = require("./mongo_client");
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const UPCOMING = new Set(["notstarted", "not_started", "upcoming"]);
const text = value => typeof value === "string" ? value.trim() : "";
const count = value => Number.isInteger(value) && value >= 0 ? value : null;
const id = value => /^[1-9]\d*$/.test(String(value ?? "")) ? String(value) : null;

function isPrematch(event, now = Date.now()) {
  return UPCOMING.has(event?.status) && Date.parse(event.event_date) > now;
}

function lineupInterval(event, doc, now = Date.now(), options = {}) {
  const until = Date.parse(event?.event_date) - now;
  const confirmed = (doc?.payload?.lineup_status || doc?.lineup_status) === "confirmed";
  if (!UPCOMING.has(event?.status)) return confirmed ? Infinity : 60_000;
  if (until < -3 * HOUR || until > 14 * DAY || !Number.isFinite(until)) return Infinity;
  if (confirmed) return 5 * 60_000;
  if (until <= (options.closeWindowMs ?? 75 * 60_000)) return options.closePollMs ?? 60_000;
  if (until <= 2 * HOUR) return options.earlyPollMs ?? 5 * 60_000;
  return until <= 2 * DAY ? 2 * HOUR : 6 * HOUR;
}

function validateLineups(payload, eventID) {
  if (String(payload?.event_id) !== String(eventID) ||
      !["predicted", "confirmed", "unavailable"].includes(payload?.lineup_status) ||
      (payload.lineup_status === "unavailable" ? payload.lineups !== null :
        !payload.lineups || !["home", "away"].every(side => payload.lineups[side] == null ||
          (Array.isArray(payload.lineups[side].players) && Array.isArray(payload.lineups[side].substitutes))))) {
    throw new Error("Invalid BSD lineups response");
  }
}

function normalizeH2H(payload) {
  if (!payload || count(payload.total_matches) === null) return null;
  const seen = new Set();
  const recent = (Array.isArray(payload.recent_matches) ? payload.recent_matches : [])
    .filter(row => row && text(row.home) && text(row.away) && Number.isFinite(Date.parse(row.date)))
    .sort((a, b) => Date.parse(b.date) - Date.parse(a.date))
    .filter(row => {
      const key = id(row.event_id) || `${row.date}|${row.home_team_id ?? row.home}|${row.away_team_id ?? row.away}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    }).slice(0, 10).map(row => ({
      event_id: id(row.event_id), date: row.date,
      home_team: text(row.home), away_team: text(row.away),
      home_team_id: id(row.home_team_id), away_team_id: id(row.away_team_id),
      home_score: count(row.home_score), away_score: count(row.away_score),
      match_id: null, // Enabled only after checking the local event catalogue.
    }));
  return { total_matches: count(payload.total_matches), home_wins: count(payload.home_wins),
    draws: count(payload.draws), away_wins: count(payload.away_wins), recent_matches: recent };
}

function projectMatchContext(event, { lineups, h2h, metadata } = {}, now = Date.now()) {
  const prematch = isPrematch(event, now);
  const sourceStatus = lineups?.payload?.lineup_status;
  const lineupStatus = sourceStatus === "confirmed" ? "confirmed"
    : sourceStatus === "predicted" && prematch ? "predicted" : "unavailable";
  const facts = [...new Set((Array.isArray(metadata?.payload?.funfacts) ? metadata.payload.funfacts : [])
    .map(fact => text(fact?.sentence)).filter(Boolean))];
  // BSD previews include simple Markdown. Deliver readable plain text on both
  // clients; raw HTML and links are never interpreted as executable content.
  const preview = text(metadata?.payload?.ai_preview?.text)
    .replace(/\*\*([^*]+)\*\*/g, "$1").replace(/^#{1,6}\s+/gm, "").replace(/^[-*]\s+/gm, "• ");
  // A short retry hydrates a cold screen without blocking its first response.
  const pending = !h2h || !metadata || (prematch && !lineups);
  return {
    kickoff_at: event?.event_date || null,
    is_upcoming: UPCOMING.has(event?.status),
    lineup_status: lineupStatus,
    lineup_updated_at: lineups?.payload?.updated_at || null,
    head_to_head: normalizeH2H(h2h?.payload),
    match_preview: prematch && preview ? { text: preview,
      generated_at: text(metadata.payload.ai_preview.generated_at) || null } : null,
    fun_facts: facts,
    refresh_after_seconds: pending ? 15 : UPCOMING.has(event?.status) ? 30 : null,
  };
}

function createMatchContextService({ client = bsd, read = getBsdRecords, save = upsertBsdRecord,
  now = Date.now } = {}) {
  const pending = new Map();
  const retryAfter = new Map();

  function due(resource, event, doc) {
    if (resource === "lineups" && !isPrematch(event, now())) return false;
    if (!doc) return true;
    const age = now() - Date.parse(doc.updated_at);
    const ttl = resource === "lineups" ? Math.min(6 * HOUR, lineupInterval(event, doc, now()))
      : resource === "h2h" ? DAY : isPrematch(event, now()) ? 2 * HOUR : DAY;
    return !Number.isFinite(age) || age >= ttl;
  }

  async function refresh(event, docs = {}, { includeLineups = false } = {}) {
    const eventID = id(event?.id);
    if (!eventID) return;
    // Bound this low-priority enrichment independently of live score requests.
    if (pending.has(eventID)) return pending.get(eventID);
    for (const [key, until] of retryAfter) if (until <= now()) retryAfter.delete(key);
    if (pending.size >= 2 || retryAfter.has(eventID)) return;
    const task = (async () => {
      let failure;
      for (const resource of includeLineups ? ["lineups", "h2h", "metadata"] : ["h2h", "metadata"]) {
        if (!due(resource, event, docs[resource])) continue;
        try {
          const payload = resource === "h2h"
            ? await client.getHeadToHead(eventID, { initiator: "bsd_runtime", trigger: "match_context" })
            : resource === "lineups" ? await client.getLineups(eventID, { initiator: "bsd_runtime", trigger: "match_context" })
            : await client.getEventMetadata(eventID, { initiator: "bsd_runtime", trigger: "match_context" });
          if (resource === "lineups") validateLineups(payload, eventID);
          else if (resource === "h2h" ? normalizeH2H(payload) === null
            : String(payload?.event_id) !== eventID || !Array.isArray(payload?.funfacts) ||
              !(payload.ai_preview === null || typeof payload.ai_preview?.text === "string")) {
            throw new Error(`Invalid BSD ${resource} response`);
          }
          await save(`bsd_${resource}`, eventID, payload, { event_id: eventID });
        } catch (error) { failure ??= error; }
      }
      if (failure) throw failure;
    })().catch(error => {
      retryAfter.set(eventID, now() + 60_000);
      throw error;
    }).finally(() => pending.delete(eventID));
    pending.set(eventID, task);
    return task;
  }

  async function load(event, { refreshInBackground = false, lineupsDoc = null } = {}) {
    const eventID = id(event?.id);
    const rows = await Promise.all(["lineups", "h2h", "metadata"].map(resource =>
      resource === "lineups" && lineupsDoc ? Promise.resolve(lineupsDoc)
        : read(`bsd_${resource}`, { _id: eventID }).then(result => result[0] || null)));
    const docs = { lineups: rows[0], h2h: rows[1], metadata: rows[2] };
    if (refreshInBackground) void refresh(event, docs, { includeLineups: true }).catch(error => {
      console.warn(`[bsd-context] event ${eventID}: ${error.message}`);
    });
    const context = projectMatchContext(event, docs, now());
    const recent = context.head_to_head?.recent_matches || [];
    const ids = recent.map(row => row.event_id).filter(Boolean);
    if (ids.length) {
      // A catalogue ID alone can be a stub. Match details need a usable stored
      // event payload; do not send either client to an unavailable page.
      const known = new Set((await read("bsd_events", { _id: { $in: ids } }, {
        projection: { _id: 1, "payload.id": 1, "payload.event_date": 1, "payload.home_team": 1, "payload.away_team": 1 },
      }))
        .filter(doc => id(doc.payload?.id) === String(doc._id) && text(doc.payload?.home_team) &&
          text(doc.payload?.away_team) && Number.isFinite(Date.parse(doc.payload?.event_date)))
        .map(doc => String(doc._id)));
      for (const row of recent) if (known.has(row.event_id)) row.match_id = row.event_id;
    }
    return { context, docs };
  }

  return { load, refresh, due };
}

module.exports = { isPrematch, lineupInterval, validateLineups, projectMatchContext, normalizeH2H,
  createMatchContextService, ...createMatchContextService() };
