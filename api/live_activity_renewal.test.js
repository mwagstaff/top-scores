const test = require("node:test");
const assert = require("node:assert/strict");
const { renewLiveActivityIfNeeded } = require("./live_activity_renewal");
const { __private: { normalizeLiveActivityStatePatch } } = require("./redis_client");

const start = Date.parse("2026-09-05T07:00:00Z"); // 08:00 BST
function fixture() {
  const user = { deviceToken: "device", liveActivity: {
    currentActivityId: "old", currentActivityPushToken: "old-token", pushToStartToken: "start-token",
    lastStartAt: new Date(start).toISOString(), lastPayloadHash: "old-hash",
  } };
  const pushes = [];
  const deps = {
    persist: async (_, patch) => Object.assign(user.liveActivity, normalizeLiveActivityStatePatch(patch)),
    send: async payload => { pushes.push(payload); return { success: true }; },
    record: async () => {},
  };
  return { user, pushes, deps };
}
const content = { mode: "multi_live", matches: [{ matchId: "match" }] };

test("08:00 activity renews at 15:30 without ending or changing its update token", async () => {
  const { user, pushes, deps } = fixture();
  await renewLiveActivityIfNeeded(user, content, start + 7.5 * 3600000 - 1, deps);
  assert.equal(pushes.length, 0);
  await renewLiveActivityIfNeeded(user, content, start + 7.5 * 3600000, deps);
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].event, "start");
  assert.equal(pushes[0].token, "start-token");
  assert.equal(user.liveActivity.currentActivityPushToken, "old-token");
  assert.equal(user.liveActivity.lastStartAt, new Date(start).toISOString());
  assert.equal(user.liveActivity.lastPayloadHash, "old-hash");
});

test("unanswered renewals retry every five minutes with a five-attempt cap", async () => {
  const { user, pushes, deps } = fixture();
  for (let minute = 450; minute < 500; minute++) {
    await renewLiveActivityIfNeeded(user, content, start + minute * 60000, deps);
  }
  assert.equal(pushes.length, 5);
  assert.equal(user.liveActivity.renewalAttempts, 5);
});

test("failed pushes stay bounded and preserve the working activity", async () => {
  const { user, deps } = fixture();
  deps.send = async () => { throw new Error("network unavailable"); };
  await renewLiveActivityIfNeeded(user, content, start + 450 * 60000, deps);
  assert.equal(user.liveActivity.renewalAttempts, 1);
  assert.equal(user.liveActivity.currentActivityPushToken, "old-token");
});

test("fast registration is not overwritten after push delivery", async () => {
  const { user, deps } = fixture();
  deps.send = async () => {
    Object.assign(user.liveActivity, { currentActivityId: "new", currentActivityPushToken: "new-token", renewalAttempts: 0 });
    return { success: true };
  };
  await renewLiveActivityIfNeeded(user, content, start + 450 * 60000, deps);
  assert.equal(user.liveActivity.currentActivityId, "new");
  assert.equal(user.liveActivity.renewalAttempts, 0);
});

test("replacement lifetime gets its own renewal budget for late matches", async () => {
  const { user, pushes, deps } = fixture();
  Object.assign(user.liveActivity, {
    currentActivityId: "new", lastStartAt: new Date(start + 450 * 60000).toISOString(),
    renewalForActivityId: "old", renewalAttempts: 5,
  });
  await renewLiveActivityIfNeeded(user, content, start + 900 * 60000, deps);
  assert.equal(pushes.length, 1);
  assert.equal(user.liveActivity.renewalAttempts, 1);
});

test("missing start token or unknown lifetime cannot trigger renewal", async () => {
  for (const patch of [{ pushToStartToken: null }, { lastStartAt: null }]) {
    const { user, pushes, deps } = fixture();
    Object.assign(user.liveActivity, patch);
    await renewLiveActivityIfNeeded(user, content, start + 450 * 60000, deps);
    assert.equal(pushes.length, 0);
  }
});
