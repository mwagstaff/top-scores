"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { normalizePoints, momentumSegments, momentumAnnotations, projectMomentum, selectMomentumBackfill, createMomentumIngestor } = require("./bsd_momentum");

test("momentum preserves fractional added-time buckets and zero, rejects missing values", () => {
  assert.deepEqual(normalizePoints([{ m: 45.5, v: -4 }, { m: 1, v: null }, { m: 2, v: 0 }, { m: 45.5, v: -8 }, { m: 3, v: Infinity }]),
    [{ minute: 2, value: 0 }, { minute: 45.5, value: -8 }]);
});
test("areas cross at zero without changing sides early, and never bridge gaps or halves", () => {
  const segments = momentumSegments(normalizePoints([{ m: 1, v: 10 }, { m: 2, v: -10 }, { m: 4, v: -20 }, { m: 45.5, v: 20 }, { m: 46, v: 20 }, { m: 47, v: 10 }]));
  assert.equal(segments.length, 3);
  assert.equal(segments[0].side, "home");
  assert.deepEqual(segments[0].points.at(-1), { minute: 1.5, value: 0 });
  assert.equal(segments[1].side, "away");
  assert.equal(segments[2].points[0].minute, 46);
});
test("annotations include decisive events, omit rescinded cards and shootouts, and reconcile disallowed goals", () => {
  const goal = { type: "goal", minute: 45, added_time: 3, is_home: true, player: "Player", player_id: 1 };
  const incidents = [goal, goal,
    { ...goal, minute: 60, added_time: null },
    { ...goal, minute: 60, added_time: null, type: "varDecision", decision: "goalAwarded", confirmed: false },
    { ...goal, type: "card", card_type: "yellow" },
    { ...goal, type: "card", card_type: "red", rescinded: true },
    { ...goal, type: "card", card_type: "yellowRed", minute: 80, added_time: null, is_home: false },
    { ...goal, type: "penalty_missed", minute: 90, added_time: 7 },
    { ...goal, type: "penalty_missed", minute: 120, added_time: null, period: 5 },
    { ...goal, minute: 121 },
  ];
  const annotations = momentumAnnotations(incidents);
  assert.deepEqual(annotations.map(a => a.kind), ["goal", "disallowed_goal", "red_card", "penalty_missed"]);
  assert.equal(annotations[0].minute, 45.5);
  assert.equal(annotations[0].time, "45+3′");
  assert.equal(annotations.at(-1).minute, 90.5);
  assert.equal(annotations[2].side, "away");
});
test("own goals are marked for the credited side and undecided VAR is omitted", () => {
  const annotations = momentumAnnotations([
    { type: "goal", goal_type: "own", minute: 12, is_home: false, player: "Defender" },
    { type: "varDecision", minute: 40, is_home: true, decision: "goalAwarded", confirmed: null },
    { type: "varDecision", minute: 52, is_home: true, decision: "goalNotAwarded", confirmed: true },
  ]);
  assert.equal(annotations.length, 2);
  assert.equal(annotations[0].label, "Own goal · Defender");
  assert.equal(annotations[0].side, "away");
});
test("extra-time domain, symmetric scale, missing coverage and late refresh policy", () => {
  const now = Date.parse("2026-11-14T18:00:00Z");
  const event = { status: "finished", event_date: "2026-11-14T15:00:00Z", extra_time_score: { home: 1, away: 0 } };
  const doc = { updated_at: "2026-11-14T17:59:00Z", payload: { momentum: [{ m: 120, v: -150 }, { m: 120.5, v: -100 }] } };
  const result = projectMomentum(doc, event, [], now);
  assert.equal(result.end_minute, 120.5);
  assert.equal(result.scale, 150);
  assert.equal(result.refresh_after_seconds, 60);
  assert.deepEqual(result.ticks.map(t => t.label), ["0′", "HT", "90′", "105′", "FT"]);
  assert.equal(projectMomentum({ payload: { momentum: [] } }, { ...event, event_date: "2026-11-10T15:00:00Z" }, [], now).refresh_after_seconds, null);
  assert.equal(projectMomentum(null, { ...event, event_date: "2026-11-10T15:00:00Z" }, [], now).refresh_after_seconds, 60);
  assert.equal(projectMomentum(null, { ...event, event_date: "2026-10-10T15:00:00Z" }, [], now).refresh_after_seconds, null);
});
test("backfill includes only past 14 days, caps batches and retries checked data daily", () => {
  const now = Date.parse("2026-11-14T18:00:00Z");
  const events = Array.from({ length: 25 }, (_, i) => ({ _id: String(i), status: "finished", event_date: new Date(now - i * 3600000).toISOString() }));
  events.push({ _id: "old", status: "finished", event_date: "2026-10-30T17:00:00Z" },
    { _id: "future", status: "finished", event_date: "2026-11-15T17:00:00Z" },
    { _id: "live", status: "inprogress", event_date: "2026-11-14T17:00:00Z" });
  const ids = selectMomentumBackfill(events, [{ _id: "0", updated_at: new Date(now).toISOString() }], now);
  assert.equal(ids.length, 20);
  assert.equal(ids[0], "1");
  assert.equal(ids.at(-1), "20");
});
test("ingestion coalesces concurrent requests, caches empty coverage and preserves data on invalid responses", async () => {
  let calls = 0, release;
  const saved = [];
  const ingest = createMomentumIngestor({
    client: { getEventStats: async id => { calls++; await new Promise(resolve => { release = resolve; }); return { event_id: id, momentum: [] }; } },
    save: async (...args) => saved.push(args),
  });
  const first = ingest("42"), second = ingest("42");
  release(); await Promise.all([first, second]);
  assert.equal(calls, 1);
  assert.equal(saved[0][0], "bsd_event_stats");
  let now = 0;
  const invalid = createMomentumIngestor({ client: { getEventStats: async () => ({ event_id: 43, momentum: [] }) }, save: async () => assert.fail("must not overwrite valid data"), now: () => now });
  await assert.rejects(invalid("42"), /Invalid BSD momentum/);
  assert.equal(invalid.canFetch("42"), false);
  assert.equal(invalid.canFetch("other"), true);
  now += 15 * 60000;
  assert.equal(invalid.canFetch("42"), true);
});
