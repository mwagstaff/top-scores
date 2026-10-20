"use strict";

const bsd = require("./bsd_client");
const { getBsdRecords, upsertBsdRecord } = require("./mongo_client");
const { bsdPlayerMatchStats, bsdEventToCanonicalMatch } = require("./bsd_adapter");
const pending = new Map();

async function cachedPerformance(collection, id, ttl, fetchPayload) {
  const [doc] = await getBsdRecords(collection, { _id: String(id) });
  const effectiveTTL = doc?.payload?.player_stats?.length === 0 ? Math.min(ttl, 60000) : ttl;
  if (doc && Date.now() - Date.parse(doc.updated_at) < effectiveTTL) return doc.payload;
  const key = `${collection}:${id}`;
  if (!pending.has(key)) {
    const task = (async () => {
      const payload = await fetchPayload();
      await upsertBsdRecord(collection, id, payload);
      return payload;
    })().finally(() => pending.delete(key));
    pending.set(key, task);
  }
  if (doc) {
    pending.get(key).catch(error => console.warn("[BSD] Performance refresh failed:", error.message));
    return doc.payload;
  }
  return pending.get(key);
}

async function getMatchPerformance(id) {
  const [event] = await getBsdRecords("bsd_events", { _id: String(id) });
  if (!event) return null;
  if (event.status === "notstarted") return { players: [] };
  const ttl = event.status === "finished" ? 86400000 : 60000;
  const payload = await cachedPerformance("bsd_player_stats", id, ttl, async () => {
    const value = await bsd.getEventPlayerStats(id, { initiator: "api", trigger: "lineup_stats" });
    if (!Array.isArray(value?.player_stats)) throw new Error("Missing player_stats");
    return value;
  });
  return { players: payload.player_stats.map(row => ({ player_id: String(row.player_id), stats: bsdPlayerMatchStats(row) })) };
}

function historyRows(stats, events) {
  const byId = new Map(events.map(event => [String(event.id), event]));
  return stats.flatMap(stat => {
    const event = byId.get(String(stat.event_id));
    if (!event || event.status !== "finished" || !(stat.minutes_played > 0)) return [];
    const match = bsdEventToCanonicalMatch(event);
    return [{ event_id: String(event.id), date: event.event_date,
      home_team: match.home_team, away_team: match.away_team,
      home_score: match.home_score == null ? null : Number(match.home_score),
      away_score: match.away_score == null ? null : Number(match.away_score),
      result_note: match.penalty_result,
      is_home: stat.team_id == null ? null
        : String(stat.team_id) === String(event.home_team_id) ? true
        : String(stat.team_id) === String(event.away_team_id) ? false : null,
      stats: bsdPlayerMatchStats(stat) }];
  }).sort((a, b) => Date.parse(b.date) - Date.parse(a.date)).slice(0, 20);
}

async function getPlayerPerformance(id) {
  const history = await cachedPerformance("bsd_player_history", id, 60 * 60 * 1000, async () => {
    const stats = await bsd.getPlayerStats(id, { initiator: "api", query: {
      date_from: new Date(Date.now() - 90 * 86400000).toISOString(),
    } });
    const played = stats.filter(row => row.minutes_played > 0);
    const ids = [...new Set(played.map(row => String(row.event_id)))];
    const docs = ids.length ? (await Promise.all([
      getBsdRecords("bsd_events", { _id: { $in: ids } }),
      getBsdRecords("bsd_history_events", { _id: { $in: ids } }),
    ])).flat() : [];
    const events = docs.map(doc => doc.payload).filter(Boolean);
    const known = new Set(events.map(event => String(event.id)));
    // The local fixture window may not cover older appearances. Fetch missing
    // event metadata in small batches, without delaying the profile itself.
    const missing = ids.filter(id => !known.has(id));
    for (let i = 0; i < missing.length; i += 4) {
      const batch = await Promise.all(missing.slice(i, i + 4).map(id => bsd.getEvent(id, { initiator: "api", trigger: "player_history" })));
      events.push(...batch.filter(Boolean));
      await Promise.all(batch.filter(Boolean).map(event => upsertBsdRecord("bsd_history_events", event.id, event)));
    }
    return { matches: historyRows(played, events) };
  });
  // Match details are served from bsd_events, not the history-only cache.
  // Check after reading cached history so availability reflects the serving store.
  const ids = history.matches.map(row => row.event_id);
  const available = ids.length ? await getBsdRecords("bsd_events", { _id: { $in: ids } }) : [];
  const matchesById = new Map(available.filter(doc => doc.payload).map(doc => [
    String(doc.payload.id), bsdEventToCanonicalMatch(doc.payload),
  ]));
  return { matches: history.matches.map(row => ({ ...row, match: matchesById.get(row.event_id) || null })) };
}

module.exports = { getMatchPerformance, getPlayerPerformance, historyRows };
