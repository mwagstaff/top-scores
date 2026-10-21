"use strict";

const bsd = require("./bsd_client");
const { getBsdRecords, upsertBsdRecord } = require("./mongo_client");

const LIVE_TTL = 15_000;
const FULL_REFRESH_MS = 120_000;
const DAY_MS = 86400_000;
const UPCOMING = new Set(["notstarted", "not_started", "upcoming", "postponed", "cancelled"]);

function validatePayload(payload, id) {
  if (String(payload?.event_id) !== String(id) || !Array.isArray(payload?.commentary) ||
      typeof payload.has_play_by_play !== "boolean" ||
      payload.commentary.some(line => !line || typeof line.id !== "string" || !line.id ||
        typeof line.text !== "string" || typeof line.type !== "string" ||
        !Number.isInteger(line.period) || !Number.isInteger(line.minute) ||
        typeof line.important !== "boolean")) {
    throw new Error("Invalid BSD commentary response");
  }
}

// Keep BSD's match order, including its ordering of periods and added time.
// A delta containing a known ID updates that line; new IDs append.
function mergeLines(previous, incoming) {
  return [...new Map([...previous, ...incoming].map(line => [line.id, line])).values()];
}

function createCommentaryService({
  client = bsd, read = getBsdRecords, save = upsertBsdRecord, now = Date.now,
} = {}) {
  const pending = new Map();
  const failures = new Map();

  function policy(event, doc) {
    const status = event.status || event.payload?.status;
    const kickoff = Date.parse(event.event_date || event.payload?.event_date);
    const settling = status === "finished" && (!Number.isFinite(kickoff) || now() - kickoff < 5 * 60 * 60 * 1000);
    const ttl = status === "finished" ? (settling ? 60_000 : DAY_MS)
      : UPCOMING.has(status) ? 30_000 : LIVE_TTL;
    // Empty coverage is retried even on a completed match.
    const effectiveTTL = doc?.payload?.commentary?.length === 0 ? Math.min(ttl, 60_000) : ttl;
    return { status, ttl: effectiveTTL, refresh: status === "finished" && !settling ? null : effectiveTTL / 1000 };
  }

  function response(doc, event) {
    const { ttl, refresh, status } = policy(event, doc);
    const stale = now() - Date.parse(doc.updated_at) >= ttl || doc.payload.status !== status;
    return {
      ...doc.payload,
      updated_at: doc.updated_at,
      stale,
      refresh_after_seconds: stale ? 15 : refresh,
    };
  }

  function refresh(id, doc, event, forceFull = false) {
    if (pending.has(id)) return pending.get(id);
    for (const [key, failure] of failures) {
      if (failure.until <= now()) failures.delete(key);
    }
    if (failures.has(id)) return Promise.reject(failures.get(id).error);
    const task = (async () => {
      const status = policy(event, doc).status;
      const full = forceFull || !doc || status === "finished" ||
        doc.payload.status !== status ||
        !(now() - Date.parse(doc.full_refreshed_at) < FULL_REFRESH_MS);
      const lastID = doc?.payload?.commentary?.at(-1)?.id;
      let since = !full && lastID ? lastID : null;
      let payload = await client.getCommentary(id, {
        initiator: forceFull ? "bsd_runtime" : "api",
        trigger: forceFull ? "post_match_settlement" : "match_commentary",
        query: since ? { since, order: "asc" } : { order: "asc" },
      });
      validatePayload(payload, id);
      // An unrecognised cursor returns the whole list, including existing IDs.
      // Re-read without the cursor to remove deleted/replaced lines as well.
      if (since && payload.commentary.some(line => doc.payload.commentary.some(old => old.id === line.id))) {
        payload = await client.getCommentary(id, {
          initiator: "api", trigger: "match_commentary_reconcile", query: { order: "asc" },
        });
        validatePayload(payload, id);
        since = null;
      }
      payload = { ...payload, commentary: mergeLines(since ? doc.payload.commentary : [], payload.commentary) };
      const updatedAt = new Date(now()).toISOString();
      const fullRefreshedAt = since ? doc.full_refreshed_at : updatedAt;
      await save("bsd_commentary", id, payload, { event_id: id, full_refreshed_at: fullRefreshedAt });
      return { payload, updated_at: updatedAt, full_refreshed_at: fullRefreshedAt };
    })().catch(error => {
      failures.set(id, { error, until: now() + 30_000 });
      throw error;
    }).finally(() => pending.delete(id));
    pending.set(id, task);
    return task;
  }

  async function getMatchCommentary(id) {
    id = String(id);
    const [events, docs] = await Promise.all([
      read("bsd_events", { _id: id }), read("bsd_commentary", { _id: id }),
    ]);
    const event = events[0];
    if (!event) return null;
    const doc = docs[0];
    const { status } = policy(event, doc);
    if (!doc && UPCOMING.has(status)) {
      return { event_id: Number(id), status, has_play_by_play: false, commentary: [],
        updated_at: null, stale: false, refresh_after_seconds: 30 };
    }
    if (doc) {
      const cached = response(doc, event);
      if (cached.stale) {
        // Preserve the last successful snapshot if BSD or Mongo is unavailable.
        void refresh(id, doc, event).catch(() => {});
      }
      return cached;
    }
    return response(await refresh(id, null, event), event);
  }

  async function refreshCachedMatchCommentary(id) {
    id = String(id);
    const [doc] = await read("bsd_commentary", { _id: id });
    if (!doc) return; // Only reconcile matches whose commentary was requested.
    const [event] = await read("bsd_events", { _id: id });
    if (event) await refresh(id, doc, event, true);
  }

  return { getMatchCommentary, refreshCachedMatchCommentary };
}

module.exports = { createCommentaryService, ...createCommentaryService() };
