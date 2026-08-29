const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    mergedLiveActivityState,
    normalizeLiveActivityStatePatch,
    normalizedPreferencesRevision,
    isStalePreferencesRevision,
  },
} = require("./redis_client");

test("normalizedPreferencesRevision accepts only non-negative safe integers", () => {
  assert.equal(normalizedPreferencesRevision(0), 0);
  assert.equal(normalizedPreferencesRevision("42"), 42);
  assert.equal(normalizedPreferencesRevision(-1), null);
  assert.equal(normalizedPreferencesRevision(1.5), null);
  assert.equal(normalizedPreferencesRevision("not-a-number"), null);
  assert.equal(normalizedPreferencesRevision(null), null);
  assert.equal(normalizedPreferencesRevision(""), null);
  assert.equal(normalizedPreferencesRevision(false), null);
});

test("isStalePreferencesRevision rejects only an older versioned update", () => {
  assert.equal(isStalePreferencesRevision(9, 10), true);
  assert.equal(isStalePreferencesRevision(10, 10), false);
  assert.equal(isStalePreferencesRevision(11, 10), false);
  assert.equal(isStalePreferencesRevision(null, 10), false);
  assert.equal(isStalePreferencesRevision(9, null), false);
});

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

test("normalizeLiveActivityStatePatch preserves explicit ActivityKit invalidation state", () => {
  assert.deepEqual(
    normalizeLiveActivityStatePatch({
      invalidatedActivityId: "activity-1",
      invalidatedAt: "2026-08-29T10:00:00.000Z",
    }),
    {
      invalidatedActivityId: "activity-1",
      invalidatedAt: "2026-08-29T10:00:00.000Z",
    }
  );
});
