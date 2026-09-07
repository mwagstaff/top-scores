const test = require("node:test");
const assert = require("node:assert/strict");
// Replace I/O before loading route handlers; no server or APNs connection starts.
const redis = require("./redis_client");
const apns = require("./apns_client");
let state;
let pushes;
redis.getUserPreferences = async () => ({ deviceToken: "device", liveActivity: state });
redis.updateUserLiveActivityState = async (_, patch) => {
  state = redis.__private.mergedLiveActivityState(state, patch);
  return { liveActivity: state };
};
apns.sendLiveActivityPush = async payload => { pushes.push(payload); return { success: true }; };
const { app } = require("./server");
function reset() {
  const oldStart = Date.now() - 7.5 * 3600000;
  state = { currentActivityId: "old", currentActivityPushToken: "aa".repeat(32),
    lastStartAt: new Date(oldStart).toISOString(),
    currentActivityGeneratedAtEpochSeconds: Math.floor(Date.now() / 1000) + 30,
    renewalForActivityId: "old", renewalRequestedAt: new Date(Date.now() - 60000).toISOString(),
    renewalAttempts: 1 };
  pushes = [];
}
async function call(path, body) {
  const route = app._router.stack.find(layer => layer.route?.path === `/api/v1/live-activity/${path}`).route;
  const res = { set() { return this; }, setHeader() {}, status(code) { this.code = code; return this; }, json(body) { this.body = body; return this; } };
  await route.stack.at(-1).handle({ deviceToken: "device", body }, res);
  assert.equal(res.code, 200, JSON.stringify(res.body));
  return res.body;
}
test("tokenless start acknowledgement preserves old update target", async () => {
  reset();
  await call("activity-started", { activityId: "new" });
  assert.equal(state.currentActivityId, "old");
  assert.equal(pushes.length, 0);
});
test("replacement token wins over a newer score timestamp and retires old target", async () => {
  reset();
  const created = Math.floor(Date.now() / 1000);
  await call("activity-token", { activityId: "new", activityPushToken: "bb".repeat(32),
    activityGeneratedAtEpochSeconds: created, activityStartedAtEpochSeconds: created });
  assert.equal(state.currentActivityId, "new");
  assert.equal(state.lastStartAt, new Date(created * 1000).toISOString());
  assert.equal(state.renewalAttempts, 0);
  assert.equal(pushes[0].event, "end");
  assert.equal(pushes[0].token, "aa".repeat(32));
  await call("activity-token", { activityId: "old", activityPushToken: "aa".repeat(32), activityGeneratedAtEpochSeconds: created + 50 });
  await call("activity-ended", { activityId: "old", activeActivityCount: 0 });
  assert.equal(state.currentActivityId, "new");
});
test("same-activity token refresh does not reset its eight-hour clock or renewal attempts", async () => {
  reset();
  const startedAt = state.lastStartAt;
  await call("activity-token", { activityId: "old", activityPushToken: "aa".repeat(32), activityGeneratedAtEpochSeconds: Math.floor(Date.now() / 1000) });
  assert.equal(state.lastStartAt, startedAt);
  assert.equal(state.renewalAttempts, 1);
});
test("legacy client renewal can register despite newer content on the old activity", async () => {
  reset();
  await call("activity-token", { activityId: "new", activityPushToken: "bb".repeat(32), activityGeneratedAtEpochSeconds: Math.floor(Date.now() / 1000) });
  assert.equal(state.currentActivityId, "new");
});
