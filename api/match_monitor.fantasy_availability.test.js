const { test, beforeEach, mock } = require("node:test");
const assert = require("node:assert/strict");
const redis = require("./redis_client");
const apns = require("./apns_client");

const deadlineMs = Date.parse("2026-09-19T10:00:00Z");
const warningMs = deadlineMs - 4 * 60 * 60 * 1000;
const nextGameweek = { id: 5, name: "Gameweek 5", deadline_time: new Date(deadlineMs).toISOString() };
let users;
let elements;
let records;
let claimed;
let deliveries;
let lookupFails;
let elementLookups;

mock.method(redis, "getAllUserPreferences", async () => users);
mock.method(redis, "getUserPreferences", async (token) => users.find((user) => user.deviceToken === token));
mock.method(redis, "getFantasyReminderRecords", async () => Array.from(records.values()));
mock.method(redis, "getFantasyReminderRecord", async (id) => records.get(id) || null);
mock.method(redis, "saveFantasyReminderRecord", async (patch) => {
  const record = { ...records.get(patch.reminder_id), ...patch };
  records.set(patch.reminder_id, record);
  return record;
});
mock.method(redis, "claimFantasyReminderSendIdempotency", async (id) => {
  const alreadyClaimed = claimed.has(id);
  claimed.add(id);
  return { claimed: !alreadyClaimed, source: "test" };
});
mock.method(apns, "sendNotification", async (...args) => {
  deliveries.push(args);
  return { success: true, environment: args[4] ? "sandbox" : "production" };
});
mock.method(global, "fetch", async (url) => {
  if (url.endsWith("/fantasy/gameweek/next")) {
    return { ok: true, json: async () => nextGameweek };
  }
  assert.equal(url, process.env.FPL_BOOTSTRAP_SOURCE_URL || "https://fantasy.premierleague.com/api/bootstrap-static/");
  elementLookups += 1;
  if (lookupFails) throw new Error("Temporary bootstrap failure");
  return { ok: true, json: async () => ({ elements }) };
});
const monitor = require("./match_monitor");
const hooks = monitor.__testHooks;

beforeEach(() => {
  users = [{
    deviceToken: "device-1", apnsToken: "apns-1", isDevelopmentBuild: true,
    updatedAt: "2026-09-18T12:00:00Z",
    preferences: { notificationsEnabled: true, fantasyDeadlineRemindersEnabled: true },
    fantasy: { managerEntryID: 123, squad: { players: [
      { elementID: 1, isStarter: true },
      { elementID: 2, isStarter: true },
      { elementID: 3, isStarter: false },
      { elementID: 4, isStarter: false },
    ] } },
  }];
  elements = [
    { id: 1, status: "i", chance_of_playing_next_round: null },
    { id: 2, status: "a", chance_of_playing_next_round: 75 },
    { id: 3, status: "s", chance_of_playing_next_round: 0 },
    { id: 4, status: "a", chance_of_playing_next_round: null, chance_of_playing_this_round: 0 },
  ];
  records = new Map(); claimed = new Set(); deliveries = [];
  lookupFails = false; elementLookups = 0;
});

const evaluate = (nowMs = warningMs) => monitor.runFantasyDeadlineReminderEvaluationNow({ nowMs });
const warnings = () => deliveries.filter((delivery) => delivery[3].type === "fantasy_availability_warning");

test("availability includes bench, status flags and next-round chance, without counting null or this-round chance", () => {
  users[0].fantasy.squad.players.push({ elementID: 1 });
  assert.deepEqual(hooks.fantasyUnavailablePlayerIDs(users[0].fantasy, elements), [1, 2, 3]);
  for (const status of ["d", "u", "n"]) {
    assert.deepEqual(hooks.fantasyUnavailablePlayerIDs({ squad: { players: [{ elementID: 4 }] } },
      [{ id: 4, status, chance_of_playing_next_round: 100 }]), [4]);
  }
});

test("schedules separate four-hour warning and sends exactly once alongside existing 24-hour reminder", async () => {
  await evaluate(warningMs - 60000);
  assert.equal(warnings().length, 0);
  assert.equal(elementLookups, 0);
  assert.equal(deliveries.length, 1);
  const warning = Array.from(records.values()).find((record) => record.kind === "fantasy_availability");
  assert.equal(warning.scheduled_for_ms, warningMs);
  await evaluate();
  assert.equal(warnings().length, 1);
  assert.equal(warnings()[0][2], "⚠️ 3 players in your FPL squad may be unavailable. Gameweek deadline in 4 hours.");
  assert.equal(warnings()[0][4], true);
  assert.equal(warnings()[0][3].unavailablePlayerCount, 3);
  assert.deepEqual(warnings()[0][3].unavailablePlayerIDs, [1, 2, 3]);
  assert.equal(records.get(warning.reminder_id).status, "sent");
  await evaluate(warningMs + 60000);
  assert.equal(warnings().length, 1);
  assert.equal(elementLookups, 1);
});

test("healthy squads complete the check silently and are not rechecked later in the gameweek", async () => {
  elements = elements.map((element) => ({ ...element, status: "a", chance_of_playing_next_round: 100 }));
  await evaluate();
  assert.equal(warnings().length, 0);
  const warning = Array.from(records.values()).find((record) => record.kind === "fantasy_availability");
  assert.equal(warning.status, "skipped");
  assert.equal(warning.unavailable_player_count, 0);
  elements[0].status = "i";
  await evaluate(warningMs + 60000);
  assert.equal(warnings().length, 0);
});

test("current availability and latest synced squad are used at delivery, not scheduling", async () => {
  await evaluate(warningMs - 60000);
  users[0].fantasy.squad.players = [{ elementID: 4 }];
  elements[3].chance_of_playing_next_round = 50;
  await evaluate();
  assert.equal(warnings()[0][2], "⚠️ 1 player in your FPL squad may be unavailable. Gameweek deadline in 4 hours.");
});

test("notification opt-outs, disconnected teams, missing squads and missing APNS tokens do not warn", async () => {
  const original = structuredClone(users[0]);
  for (const change of [
    (user) => { user.preferences.notificationsEnabled = false; },
    (user) => { user.preferences.fantasyDeadlineRemindersEnabled = false; },
    (user) => { user.fantasy = null; },
    (user) => { user.fantasy.squad = null; },
    (user) => { user.apnsToken = null; },
  ]) {
    users = [structuredClone(original)]; change(users[0]);
    records.clear(); deliveries = [];
    await evaluate();
    assert.equal(warnings().length, 0);
  }
});

test("shared APNS targets deduplicate and multiple users share one bootstrap lookup", async () => {
  users.push({ ...structuredClone(users[0]), deviceToken: "device-old", updatedAt: "2026-09-17T12:00:00Z" });
  users.push({ ...structuredClone(users[0]), deviceToken: "device-2", apnsToken: "apns-2" });
  await evaluate();
  assert.equal(warnings().length, 2);
  assert.equal(elementLookups, 1);
  await evaluate();
  assert.equal(warnings().length, 2);
});

test("a newer opt-out on a shared APNS token prevents warnings from stale user records", async () => {
  users.push({ ...structuredClone(users[0]), deviceToken: "device-new",
    updatedAt: "2026-09-18T13:00:00Z", preferences: { notificationsEnabled: false } });
  await evaluate();
  assert.equal(deliveries.length, 0);
  assert.equal(elementLookups, 0);
});

test("persistent send idempotency prevents duplicate warnings if a sent record is rescheduled", async () => {
  await evaluate();
  const warning = Array.from(records.values()).find((record) => record.kind === "fantasy_availability");
  records.set(warning.reminder_id, { ...warning, status: "scheduled" });
  await evaluate(warningMs + 60000);
  assert.equal(warnings().length, 1);
});

test("bootstrap failures and missing player data retry without sending partial or false warnings", async () => {
  lookupFails = true;
  await evaluate();
  assert.equal(warnings().length, 0);
  lookupFails = false;
  const completeElements = elements;
  elements = elements.slice(0, 2);
  await evaluate(warningMs + 60000);
  assert.equal(warnings().length, 0);
  assert.equal(Array.from(records.values()).find((record) => record.kind === "fantasy_availability").status, "scheduled");
  elements = completeElements;
  await evaluate(warningMs + 120000);
  assert.equal(warnings().length, 1);
  assert.match(warnings()[0][2], /deadline in 3 hours 58 minutes/);
});

test("no warnings after deadline and disabled scheduled warnings are superseded", async () => {
  await evaluate(warningMs - 60000);
  users[0].preferences.notificationsEnabled = false;
  await evaluate();
  assert.equal(warnings().length, 0);
  assert.equal(Array.from(records.values()).find((record) => record.kind === "fantasy_availability").status, "superseded");
  users[0].preferences.notificationsEnabled = true;
  await evaluate(deadlineMs);
  assert.equal(warnings().length, 0);
});
