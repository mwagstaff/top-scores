const test = require("node:test");
const assert = require("node:assert/strict");
const redis = require("./redis_client");
const apns = require("./apns_client");
let user;
let pushes;
redis.updateUserLiveActivityState = async (_, patch) => {
  user.liveActivity = redis.__private.mergedLiveActivityState(user.liveActivity, patch);
};
redis.saveLiveActivityDebugRecord = async () => {};
apns.sendLiveActivityPush = async payload => { pushes.push(payload); return { success: true }; };
const { __testHooks: { dispatchLiveActivityForUser } } = require("./match_monitor");
const now = Date.parse("2026-10-04T11:00:00Z");
const presentation = { mode: "single_live", delayMinutes: 0, matches: [{
  match_id: "match", date: "2026-10-04", time: "12:00", league: "Test",
  home_team: "Home", away_team: "Away", home_score: 0, away_score: 0, match_time: "1'",
}] };
function reset(state) {
  user = { deviceToken: "device", liveActivity: { pushToStartToken: "start-token", ...state } };
  pushes = [];
}
test("changing scores cannot turn an accepted start into repeated live activities", async () => {
  reset({ pendingStartAt: new Date(now).toISOString(), lastMode: "single_upcoming", lastPayloadHash: "previous" });
  for (let minute = 3; minute <= 300; minute += 3) {
    await dispatchLiveActivityForUser(user, presentation, now + minute * 60000);
  }
  assert.equal(pushes.length, 0);
  assert.equal(user.liveActivity.pendingStartAt, new Date(now).toISOString());
});
test("a temporarily empty schedule does not forget an unconfirmed activity", async () => {
  reset({ pendingStartAt: new Date(now).toISOString() });
  await dispatchLiveActivityForUser(user, { mode: "none", matches: [] }, now + 60000);
  await dispatchLiveActivityForUser(user, presentation, now + 180000);
  assert.equal(pushes.length, 0);
  assert.equal(user.liveActivity.pendingStartAt, new Date(now).toISOString());
});
test("expired old update token does not trigger a second accepted renewal", async () => {
  reset({ renewalForActivityId: "old", renewalAcceptedAt: new Date(now).toISOString() });
  await dispatchLiveActivityForUser(user, presentation, now + 31 * 60000);
  assert.equal(pushes.length, 0);
});
test("a tokenless local activity blocks another remote start after two minutes", async () => {
  reset({ currentActivityId: "local", lastStartAt: new Date(now).toISOString() });
  await dispatchLiveActivityForUser(user, presentation, now + 180000);
  assert.equal(pushes.length, 0);
});

test("unconfirmed starts become eligible again after the full visibility window", async () => {
  reset({ pendingStartAt: new Date(now).toISOString() });
  await dispatchLiveActivityForUser(user, presentation, now + 12 * 3600000);
  assert.equal(user.liveActivity.pendingStartAt, null);
  await dispatchLiveActivityForUser(user, presentation, now + 12 * 3600000 + 15000);
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].event, "start");
});
