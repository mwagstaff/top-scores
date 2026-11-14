"use strict";

const bsd = require("./bsd_client");
const { upsertBsdRecord } = require("./mongo_client");
const DAY_MS = 86_400_000;
const PERIOD_ENDS = [45, 90, 105, 120];
const finite = (value) => typeof value === "number" && Number.isFinite(value);

function normalizePoints(raw) {
  const points = new Map();
  for (const point of Array.isArray(raw) ? raw : []) {
    if (finite(point?.m) && point.m >= 0 && point.m <= 150 && finite(point.v)) {
      points.set(point.m, { minute: point.m, value: point.v });
    }
  }
  return [...points.values()].sort((a, b) => a.minute - b.minute);
}

// Split at missing minutes, period boundaries and zero crossings. Both clients
// draw the same linear areas; neither smooths peaks or bridges missing coverage.
function momentumSegments(points) {
  const segments = [];
  let current;
  function append(a, b, side) {
    if (!current || current.side !== side || current.points.at(-1).minute !== a.minute) {
      current = { id: String(segments.length), side, points: [a] };
      segments.push(current);
    }
    current.points.push(b);
  }
  for (let index = 1; index < points.length; index += 1) {
    const a = points[index - 1], b = points[index];
    if (b.minute - a.minute > 1 || PERIOD_ENDS.some(end => a.minute <= end + 0.5 && b.minute > end + 0.5)) {
      current = null;
      continue;
    }
    if (a.value * b.value < 0) {
      const zero = { minute: a.minute + (b.minute - a.minute) * Math.abs(a.value) / (Math.abs(a.value) + Math.abs(b.value)), value: 0 };
      append(a, zero, a.value > 0 ? "home" : "away");
      append(zero, b, b.value > 0 ? "home" : "away");
    } else {
      append(a, b, (a.value || b.value) >= 0 ? "home" : "away");
    }
  }
  return segments;
}

function momentumAnnotations(incidents) {
  const items = Array.isArray(incidents) ? incidents : [];
  const disallowed = items.filter(i => i?.type === "varDecision" &&
    ((i.decision === "goalAwarded" && i.confirmed === false) ||
     (i.decision === "goalNotAwarded" && i.confirmed === true)));
  const annotations = new Map();
  for (const incident of items) {
    if (!incident || incident.rescinded === true || typeof incident.is_home !== "boolean" ||
        !finite(incident.minute) || incident.minute < 0 || incident.minute > 120 ||
        incident.period === 5 || /shootout|shoot_out/i.test(String(incident.period || "")) ||
        /shootout/i.test(String(incident.goal_type || incident.sit || ""))) continue;
    let kind, label;
    if (incident.type === "goal") {
      if (incident.confirmed === false || disallowed.some(i => i.player_id != null && i.player_id === incident.player_id &&
          i.is_home === incident.is_home && i.minute === incident.minute && (i.added_time || 0) === (incident.added_time || 0))) continue;
      kind = "goal";
      label = /own/i.test(incident.goal_type || "") ? "Own goal" : /penalty/i.test(incident.goal_type || "") ? "Penalty goal" : "Goal";
    } else if (incident.type === "card" && /red|yellowred|second.?yellow/i.test(incident.card_type || "")) {
      kind = "red_card";
      label = /yellow/i.test(incident.card_type) ? "Second yellow · Red card" : "Red card";
    } else if (incident.type === "penalty_missed") {
      kind = "penalty_missed";
      label = "Missed penalty";
    } else if (disallowed.includes(incident)) {
      kind = "disallowed_goal";
      label = "Goal disallowed";
    } else continue;
    const added = finite(incident.added_time) && incident.added_time > 0 ? incident.added_time : 0;
    // BSD compresses each period's added time into its .5 bucket (observed in
    // regulation and extra-time responses). Keep the actual time in the label.
    const minute = incident.minute + (added > 0 && PERIOD_ENDS.includes(incident.minute) ? 0.5 : 0);
    const time = `${incident.minute}${added ? `+${added}` : ""}′`;
    const side = incident.is_home ? "home" : "away";
    const player = String(incident.player || "").trim();
    const id = `${kind}:${side}:${time}:${incident.player_id ?? player}`;
    annotations.set(id, { id, minute, time, side, kind, label: `${label}${player ? ` · ${player}` : ""}` });
  }
  return [...annotations.values()].sort((a, b) => a.minute - b.minute || a.id.localeCompare(b.id));
}

function projectMomentum(doc, event, incidents, now = Date.now()) {
  const points = normalizePoints(doc?.payload?.momentum);
  const segments = momentumSegments(points);
  const annotations = momentumAnnotations(incidents);
  const lastMinute = Math.max(0, ...points.map(p => p.minute));
  const extraTime = Boolean(event.extra_time_score) || /extra/i.test(event.period || "") || lastMinute > 90.5;
  const end = Math.max(extraTime ? 120.5 : 90.5, lastMinute, ...annotations.map(a => a.minute));
  const finished = event.status === "finished";
  const age = now - Date.parse(event.event_date);
  const recent = Number.isFinite(age) && age >= 0 && age <= 14 * DAY_MS;
  const settling = finished && age < 5 * 60 * 60 * 1000;
  return {
    status: segments.length ? "available" : doc ? "unavailable" : "pending",
    segments, annotations, end_minute: end,
    scale: Math.max(100, ...points.map(p => Math.abs(p.value))),
    ticks: [{ minute: 0, label: "0′" }, { minute: 45.5, label: "HT" },
      ...(extraTime ? [{ minute: 90.5, label: "90′" }, { minute: 105.5, label: "105′" }] : []),
      { minute: end, label: finished ? "FT" : extraTime ? "120′" : "90′" }],
    updated_at: doc?.updated_at || null,
    refresh_after_seconds: !finished || settling || (!doc && recent) ? 60 : null,
  };
}

function selectMomentumBackfill(events, docs, now = Date.now()) {
  const checked = new Map(docs.map(doc => [String(doc._id), Date.parse(doc.updated_at)]));
  return events.filter(event => {
    const age = now - Date.parse(event.event_date);
    return event.status === "finished" && age >= 0 && age <= 14 * DAY_MS &&
      !(now - checked.get(String(event._id)) < DAY_MS);
  }).sort((a, b) => b.event_date.localeCompare(a.event_date)).slice(0, 20).map(event => String(event._id));
}

function createMomentumIngestor({ client = bsd, save = upsertBsdRecord, now = Date.now } = {}) {
  const pending = new Map(), failures = new Map();
  function ingest(id, options = {}) {
    id = String(id);
    if (pending.has(id)) return pending.get(id);
    for (const [key, until] of failures) if (until <= now()) failures.delete(key);
    if (failures.has(id)) return Promise.resolve();
    const task = (async () => {
      const payload = await client.getEventStats(id, { initiator: "bsd_runtime", ...options });
      if (String(payload?.event_id) !== id || !Array.isArray(payload?.momentum) ||
          payload.momentum.some(p => !finite(p?.m) || !finite(p?.v))) {
        throw new Error("Invalid BSD momentum response");
      }
      await save("bsd_event_stats", id, payload, { event_id: id });
    })().catch(error => {
      failures.set(id, now() + 15 * 60_000);
      throw error;
    }).finally(() => pending.delete(id));
    pending.set(id, task);
    return task;
  }
  ingest.canFetch = id => !(failures.get(String(id)) > now());
  return ingest;
}

module.exports = { normalizePoints, momentumSegments, momentumAnnotations, projectMomentum,
  selectMomentumBackfill, createMomentumIngestor, ingestMomentum: createMomentumIngestor() };
