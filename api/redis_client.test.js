const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    mergedLiveActivityState,
    normalizeLiveActivityStatePatch,
  },
} = require("./redis_client");

test("normalizeLiveActivityStatePatch preserves push-to-start attempts", () => {
  assert.deepEqual(
    normalizeLiveActivityStatePatch({
      pushToStartAttempts: 4.9,
    }),
    {
      pushToStartAttempts: 4,
    }
  );
});

test("normalizeLiveActivityStatePatch clamps invalid push-to-start attempts", () => {
  assert.deepEqual(
    normalizeLiveActivityStatePatch({
      pushToStartAttempts: -2,
    }),
    {
      pushToStartAttempts: 0,
    }
  );

  assert.deepEqual(
    normalizeLiveActivityStatePatch({
      pushToStartAttempts: "not-a-number",
    }),
    {
      pushToStartAttempts: 0,
    }
  );
});

test("mergedLiveActivityState persists attempt counter with other live activity fields", () => {
  const merged = mergedLiveActivityState(
    {
      pushToStartToken: "existing-token",
      pendingStartAt: "2026-04-30T10:00:00.000Z",
      pushToStartAttempts: 1,
    },
    {
      pendingStartAt: null,
      pushToStartAttempts: 5,
    }
  );

  assert.equal(merged.pushToStartToken, "existing-token");
  assert.equal(merged.pendingStartAt, null);
  assert.equal(merged.pushToStartAttempts, 5);
});
