const test = require("node:test");
const assert = require("node:assert/strict");
const { pushToStartAttemptsForDay } = require("./live_activity_start_policy");
const { __testHooks: hooks } = require("./match_monitor");
const { __private: { mergedLiveActivityState } } = require("./redis_client");

test("07:59 foreground activity survives while scheduled pushes still wait until 08:00", () => {
  for (const date of ["2026-09-08T06:59:32Z", "2026-01-08T07:59:32Z"]) {
    assert.equal(hooks.isWithinLiveActivityActiveWindow(Date.parse(date), true), true);
    assert.equal(hooks.isWithinLiveActivityActiveWindow(Date.parse(date), false), false);
  }
  assert.equal(hooks.isWithinLiveActivityActiveWindow(Date.parse("2026-09-08T07:00:00Z")), true);
  assert.equal(hooks.isWithinLiveActivityActiveWindow(Date.parse("2026-09-08T06:54:59Z"), true), false);
  assert.equal(hooks.isWithinLiveActivityActiveWindow(Date.parse("2026-09-08T22:00:00Z"), true), false);
});

test("new morning activity cannot carry yesterday's exhausted budget into today", () => {
  const state = { lastStartAt: "2026-09-08T06:59:25Z", pushToStartAttempts: 29,
    pushToStartAttemptsUpdatedAt: "2026-09-07T12:00:00Z" };
  assert.equal(pushToStartAttemptsForDay(state, Date.parse("2026-09-08T07:00:00Z")), 0);
  delete state.pushToStartAttemptsUpdatedAt;
  assert.equal(pushToStartAttemptsForDay(state, Date.parse("2026-09-08T07:00:00Z")), 0);
});

test("London midnight resets the budget during summer time", () => {
  const state = { pushToStartAttempts: 5, pushToStartAttemptsUpdatedAt: "2026-09-07T22:55:00Z" };
  assert.equal(pushToStartAttemptsForDay(state, Date.parse("2026-09-07T22:59:59Z")), 5);
  assert.equal(pushToStartAttemptsForDay(state, Date.parse("2026-09-07T23:00:00Z")), 0);
});

test("successful reset wins over a duplicate record with 29 historic failures", () => {
  const stale = { deviceToken: "old", liveActivity: { pushToStartToken: "shared",
    pushToStartAttempts: 29, pushToStartAttemptsUpdatedAt: "2026-09-07T10:00:00Z" } };
  const current = { deviceToken: "current", liveActivity: { pushToStartToken: "shared",
    pushToStartTokenUpdatedAt: "2026-09-08T06:59:00Z",
    pushToStartAttempts: 0, pushToStartAttemptsUpdatedAt: "2026-09-08T06:59:30Z" } };
  const [target] = hooks.dedupeLiveActivityUsers([current, stale]);
  assert.equal(target.deviceToken, "current");
  assert.equal(pushToStartAttemptsForDay(target.liveActivity, Date.parse("2026-09-08T07:00:00Z")), 0);
});

test("current-day failures remain bounded even when another record owns the token", () => {
  const [target] = hooks.dedupeLiveActivityUsers([
    { deviceToken: "owner", liveActivity: { pushToStartToken: "shared", pushToStartTokenUpdatedAt: "2026-09-08T08:00:00Z" } },
    { deviceToken: "other", liveActivity: { pushToStartToken: "shared", pushToStartAttempts: 5, pushToStartAttemptsUpdatedAt: "2026-09-08T09:00:00Z" } },
  ]);
  assert.equal(pushToStartAttemptsForDay(target.liveActivity, Date.parse("2026-09-08T10:00:00Z")), 5);
});

test("retry budget timestamp persists through unrelated state patches", () => {
  const state = mergedLiveActivityState({}, { pushToStartAttempts: 3, pushToStartAttemptsUpdatedAt: "2026-09-08T08:00:00Z" });
  const updated = mergedLiveActivityState(state, { lastStartAt: "2026-09-08T09:00:00Z" });
  assert.equal(pushToStartAttemptsForDay(updated, Date.parse("2026-09-08T10:00:00Z")), 3);
});
