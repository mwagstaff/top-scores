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

test("foreground reconcile preserves a local activity when server state is transiently missing", () => {
  assert.deepEqual(
    liveActivityForegroundReconcileDecision({
      trigger: "app_foreground",
      reportedActiveCount: 1,
      reportedActiveActivityIds: ["activity-1"],
      hasFreshCurrentServerActivity: false,
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

test("foreground reconcile restarts only the activity explicitly invalidated by APNs", () => {
  assert.deepEqual(
    liveActivityForegroundReconcileDecision({
      trigger: "app_foreground",
      reportedActiveCount: 1,
      reportedActiveActivityIds: ["activity-1"],
      invalidatedActivityId: "activity-1",
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

test("foreground reconcile does not restart a different local activity", () => {
  assert.equal(
    liveActivityForegroundReconcileDecision({
      trigger: "app_foreground",
      reportedActiveCount: 1,
      reportedActiveActivityIds: ["new-activity"],
      invalidatedActivityId: "old-activity",
    }).requiresActivityRestart,
    false
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
