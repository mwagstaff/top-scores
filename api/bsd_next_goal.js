"use strict";

const bsd = require("./bsd_client");
const { getBsdRecords, upsertBsdRecord } = require("./mongo_client");
const { BSD_LEAGUE_ALLOWLIST } = require("./bsd_config");
const { isDeepStrictEqual } = require("node:util");
const allowed = new Set(BSD_LEAGUE_ALLOWLIST);
const probability = value => Number.isFinite(value) && value >= 0 && value <= 1;
const minuteValue = value => Number.isInteger(value) && value >= 0;

function forecast(raw) {
  const p = raw?.probabilities;
  if (!p || !probability(p.home) || !probability(p.away) ||
      (p.no_goal !== null && !probability(p.no_goal)) || !minuteValue(raw.minute) ||
      !minuteValue(raw.score?.home) || !minuteValue(raw.score?.away)) return null;
  const total = p.home + p.away + (p.no_goal ?? 0);
  if (!total || (p.no_goal !== null && Math.abs(total - 1) > 0.01)) return null;
  return { minute: raw.minute, score: raw.score, leader: raw.leader ?? null, is_call: raw.is_call === true,
    call_paused: raw.call_paused === true, evidence: raw.evidence ?? null, minutes_since_goal: raw.minutes_since_goal ?? null,
    probabilities: { home: p.home / total, away: p.away / total, no_goal: p.no_goal === null ? null : p.no_goal / total } };
}

function createNextGoalIngestor({ client = bsd, get = getBsdRecords, save = upsertBsdRecord, now = Date.now } = {}) {
  let disabledUntil = 0;
  async function guarded(task) {
    if (now() < disabledUntil) return;
    try { await task(); }
    catch (error) {
      if (error.statusCode !== 403) throw error;
      if (now() >= disabledUntil) console.warn("[bsd-runtime] next goal unavailable (403), retrying in one hour");
      disabledUntil = now() + 3_600_000;
    }
  }
  const options = { initiator: "bsd_runtime" };
  function reads() {
    return guarded(async () => {
      const rows = (await client.getNextGoal(options)).filter(r => r.event?.id != null && allowed.has(String(r.event.league_id)));
      const ids = rows.map(r => String(r.event.id));
      const previous = new Map((await get("bsd_next_goal", { _id: { $in: ids } })).map(d => [d._id, d.payload]));
      const seen = {};
      for (const r of rows) {
        const id = String(r.event.id);
        const payload = forecast(r);
        if (!payload) continue;
        if (!isDeepStrictEqual(previous.get(id), payload)) await save("bsd_next_goal", id, payload, { event_id: id });
        seen[id] = now();
      }
      // One heartbeat for the whole successful bulk poll. Material forecasts are independent.
      await save("bsd_next_goal", "coverage", seen);
    });
  }
  function calls(filter) {
    return guarded(async () => {
      const rows = (await client.getNextGoalCalls(filter, options)).filter(call =>
        call.id != null && call.event?.id != null && allowed.has(String(call.event.league_id)));
      if (!rows.length) return;
      const ids = rows.map(call => String(call.id));
      const previous = new Map((await get("bsd_next_goal_calls", { _id: { $in: ids } })).map(d => [d._id, d.payload]));
      for (const call of rows) {
        const { id, minute, side, team, probability, score_at_call, outcome, resolved_minute, called_at, resolved_at } = call;
        const payload = { minute, side, team, probability, score_at_call, outcome, resolved_minute, called_at, resolved_at };
        if (!isDeepStrictEqual(previous.get(String(id)), payload)) {
          await save("bsd_next_goal_calls", String(id), payload, { event_id: String(call.event.id) });
        }
      }
    });
  }
  return { reads, calls };
}

function callSummary(call, match) {
  if (!minuteValue(call?.minute) || !probability(call.probability) || !["home", "away"].includes(call.side)) return null;
  const home = call.side === "home";
  const team = home ? match.home_team : match.away_team;
  const other = home ? match.away_team : match.home_team;
  const time = minuteValue(call.resolved_minute) ? ` at ${call.resolved_minute}′` : "";
  const outcome = { hit: `Correct · ${team} scored${time}`, miss: `Missed · ${other} scored${time}`,
    nogoal: "No further goal", unclear: "Outcome unclear", open: "Awaiting outcome" }[call.outcome];
  return outcome ? `${call.minute}′ · Called ${team} to score next (${Math.round(call.probability * 100)}%) · ${outcome}` : null;
}

function projectNextGoal(docs, callDocs, event, match, now = Date.now()) {
  const id = String(event.id);
  const calls = callDocs.flatMap(doc => {
    const summary = callSummary(doc.payload, match);
    return summary ? [{ ...doc.payload, id: doc._id, summary }] : [];
  }).sort((a, b) => a.minute - b.minute);
  if (["FT", "AET"].includes(match.score_status)) {
    if (!calls.length) return null;
    const settled = docs.find(d => d._id === "settled:" + id)?.payload?.at ?? Date.parse(event.last_updated);
    return { status: "settled", calls, refresh_after_seconds: now - settled < 900_000 ? 60 : null };
  }
  if (!match.score_status || ["POSTPONED", "ABANDONED", "Pens"].includes(match.score_status)) return null;
  const doc = docs.find(d => d._id === id);
  if (!doc) return allowed.has(String(event.league_id)) && minuteValue(event.current_minute) && event.current_minute < 15
    ? { status: "warming_up", message: "Next-goal chances start around 10′", refresh_after_seconds: 30 } : null;
  const read = doc.payload;
  const seen = docs.find(d => d._id === "coverage")?.payload?.[id];
  const scoreChanged = read.score.home !== match.home_score || read.score.away !== match.away_score;
  const stale = !seen || now - seen > 180_000;
  const updating = scoreChanged || stale || read.call_paused;
  const message = scoreChanged ? "Updating after goal…" : stale ? "Updating…" : read.call_paused ? "Paused after goal" : read.is_call ? "Strong call" : null;
  return { ...read, calls, status: updating ? "updating" : "available", message, updated_at: doc.updated_at,
    last_seen_at: seen ? new Date(seen).toISOString() : null, refresh_after_seconds: 30 };
}

module.exports = { createNextGoalIngestor, projectNextGoal, forecast };
