import test from "node:test";
import assert from "node:assert/strict";
import { normalizeNextGoal } from "../src/client/nextGoal.ts";

test("two-way estimates omit the neutral segment and retain relative chances", () => {
  const data = normalizeNextGoal({ status: "available", probabilities: { home: 0.3, away: 0.2, no_goal: null },
    evidence: { shots_home_10m: 0, shots_away_10m: 2 } });
  assert.deepEqual(data?.shares, [{ side: "home", value: 0.6 }, { side: "away", value: 0.4 }]);
  assert.equal(data?.shots, "Shots, last 10′: 0–2");
});

test("malformed estimates and unknown states stay hidden", () => {
  for (const probabilities of [{}, { home: -1, away: 2 }, { home: NaN, away: 0 }, { home: 0, away: 0, no_goal: null }]) {
    assert.equal(normalizeNextGoal({ status: "available", probabilities }), null);
  }
  assert.equal(normalizeNextGoal({ status: "unknown" }), null);
});

test("settlement retains the graded summary and refresh interval only", () => {
  const data = normalizeNextGoal({ status: "settled", calls: [{ summary: "Missed · Fulham scored at 67′" }], refresh_after_seconds: 60 });
  assert.deepEqual(data?.shares, []);
  assert.equal(data?.calls.length, 1);
  assert.equal(data?.refresh_after_seconds, 60);
});

test("a cached live estimate expires three minutes after coverage was confirmed", () => {
  const seen = "2026-11-22T13:00:00.000Z";
  const data = normalizeNextGoal({ status: "available", last_seen_at: seen,
    probabilities: { home: 0.35, no_goal: 0.4, away: 0.25 } });
  assert.equal(data?.expiresAt, Date.parse(seen) + 180_000);
});
