const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: { liveActivityForegroundReconcileDecision },
} = require("./server");

test("foreground reconcile refreshes a valid local activity without restarting it", () => {
  assert.deepEqual(
    liveActivityForegroundReconcileDecision({
      trigger: "app_foreground",
      reportedActiveCount: 1,
      hasFreshCurrentServerActivity: true,
      hasRecentDispatch: true,
    }),
    {
      isForegroundClient: true,
      shouldSuppressForegroundStart: true,
      shouldPrepareForegroundContent: true,
      requiresActivityRestart: false,
    }
  );
});

test("foreground reconcile replaces a stranded local activity after its server token is invalidated", () => {
  assert.deepEqual(
    liveActivityForegroundReconcileDecision({
      trigger: "app_foreground",
      reportedActiveCount: 1,
      hasFreshCurrentServerActivity: false,
      hasRecentDispatch: true,
    }),
    {
      isForegroundClient: true,
      shouldSuppressForegroundStart: false,
      shouldPrepareForegroundContent: true,
      requiresActivityRestart: true,
    }
  );
});

test("non-foreground reconcile preserves the existing server activity behavior", () => {
  assert.deepEqual(
    liveActivityForegroundReconcileDecision({
      trigger: "manual_reconcile",
      reportedActiveCount: null,
      hasFreshCurrentServerActivity: true,
      hasRecentDispatch: true,
    }),
    {
      isForegroundClient: false,
      shouldSuppressForegroundStart: true,
      shouldPrepareForegroundContent: false,
      requiresActivityRestart: false,
    }
  );
});
