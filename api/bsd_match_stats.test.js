"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { projectMatchStats } = require("./bsd_match_stats");
const event = { status: "inprogress", event_date: "2026-11-14T15:00:00Z" };
const project = payload => projectMatchStats({ payload, updated_at: "2026-11-14T16:00:00Z" }, event);
const row = (result, id, period = "all") => result.periods.find(p => p.id === period)?.rows.find(r => r.id === id);

test("stats work without momentum; missing values are distinct from zero and invalid numbers", () => {
  const result = project({ stats: { home: { ball_possession: 0, red_cards: 0, fouls: -1, total_shots: "7" }, away: { ball_possession: 100, red_cards: null } } });
  assert.equal(result.status, "available");
  assert.equal(row(result, "red_cards").home_display, "0");
  assert.equal(row(result, "red_cards").away_display, "—");
  assert.equal(row(result, "fouls"), undefined);
  assert.equal(row(result, "total_shots"), undefined);
  assert.equal(result.updated_at, "2026-11-14T16:00:00Z");
  assert.equal(result.refresh_after_seconds, 60);
});

test("only supplied halves are exposed, including zero-only coverage; no percentage subtraction", () => {
  const result = project({ stats: { home: { ball_possession: 54 }, away: { ball_possession: 46 },
    first_half: { home: { ball_possession: 38, corner_kicks: 0 }, away: { ball_possession: 62 } }, second_half: { home: { fouls: null } } } });
  assert.deepEqual(result.periods.map(p => p.id), ["all", "first_half"]);
  assert.equal(row(result, "ball_possession", "first_half").home, 38);
  assert.equal(row(result, "corner_kicks", "first_half").home, 0);
});

test("xG uses the per-side block and provenance, not a conflicting root flag or aggregate", () => {
  const result = project({ xg_estimated: true, stats: { home: { expected_goals: 4, xg: { actual: 0.876, estimated: false } },
    away: { xg: { actual: 1.123, estimated: true } } } });
  const xg = row(result, "xg");
  assert.equal(xg.home_display, "0.88");
  assert.equal(xg.home_estimated, false);
  assert.equal(xg.away_display, "1.12");
  assert.equal(xg.away_estimated, true);
});

test("ratio metrics preserve attempts, zeroes and percentages; aliases do not duplicate rows", () => {
  const result = project({ stats: { home: { crosses: { value: 0, total: 6, pct: 0 }, tackles: 9, total_tackles: 9, goals_prevented: -0.17 },
    away: { crosses: { value: 8, total: 2 }, total_tackles: 4 } } });
  assert.equal(row(result, "crosses").home_display, "0/6 (0%)");
  assert.equal(row(result, "crosses").away, null);
  assert.equal(row(result, "tackles").away, 4);
  assert.equal(row(result, "goals_prevented").home_display, "-0.17");
  assert.equal(row(result, "total_tackles"), undefined);
});

test("shot feed overrides conflicting counts consistently and excludes shootouts from every period", () => {
  const bag = { home: { total_shots: 99, shots_on_target: 20 }, away: { total_shots: 88, shots_on_target: 10 } };
  const result = project({ stats: { ...bag, first_half: bag, second_half: bag }, shotmap: [
    { home: true, min: 45, added: 7, type: "goal" }, { home: false, min: 46, type: "save" },
    { home: true, min: 90, added: 5, type: "block" }, { home: false, min: 110, type: "post" },
    { home: true, min: 120, type: "goal", sit: "shootout" },
  ] });
  assert.equal(row(result, "total_shots").home, 2);
  assert.equal(row(result, "total_shots").away, 2);
  assert.equal(row(result, "shots_on_target").home, 1);
  assert.equal(row(result, "total_shots", "first_half").home, 1);
  assert.equal(row(result, "total_shots", "first_half").away, 0);
  assert.equal(row(result, "total_shots", "second_half").away, 1);
  assert.equal(row(result, "hit_woodwork", "second_half").away, 0);
});

test("empty or malformed shot feeds use aggregate fallback; unknown minutes cannot fabricate halves", () => {
  const bag = { home: { total_shots: 4 }, away: { total_shots: 2 } };
  for (const shotmap of [[], [{ home: null, min: 2, type: "goal" }], [{ home: true, min: 121, type: "goal", sit: "shootout" }]]) {
    assert.equal(row(project({ stats: bag, shotmap }), "total_shots").home, 4);
  }
  const result = project({ stats: { ...bag, first_half: bag }, shotmap: [{ home: true, min: null, type: "goal" }] });
  assert.equal(row(result, "total_shots").home, 1);
  assert.equal(row(result, "total_shots", "first_half").home, 4);
  assert.equal(project({ stats: {}, shotmap: [] }).periods.length, 0);
});

test("pending, unavailable, settled and late coverage have independent refresh policy", () => {
  const now = Date.parse("2026-11-14T18:00:00Z");
  const finished = { status: "finished", event_date: "2026-11-13T15:00:00Z" };
  assert.equal(projectMatchStats(null, finished, now).status, "pending");
  assert.equal(projectMatchStats(null, finished, now).refresh_after_seconds, 60);
  const empty = projectMatchStats({ payload: { stats: {} } }, finished, now);
  assert.equal(empty.status, "unavailable");
  assert.equal(empty.refresh_after_seconds, null);
});
