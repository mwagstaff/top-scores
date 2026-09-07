const test = require("node:test");
const assert = require("node:assert/strict");
const { migrateRecord } = require("./migrate_notification_team_subscriptions");
const { buildNotificationTeamRegistry } = require("../notification_team_subscriptions");
const registry = buildNotificationTeamRegistry([{ id: "newcastle-united", name: "Newcastle United", source_team_ids: ["4"] }]);
const initial = () => ({ deviceToken: "AE874635-test", apnsToken: "unchanged", preferencesRevision: 42, preferences: { notificationDelayMinutes: 1, selectedNotificationViewOptionIDs: ["team:newcastle-united"] } });

test("migration dry run does not write or create a backup", async () => {
  const result = await migrateRecord({ source: "redis", key: "AE874635-test", registry, apply: false, read: async () => initial(), write: () => assert.fail("write"), backup: () => assert.fail("backup") });
  assert.equal(result.status, "would_update");
});

test("migration retries concurrent edits, preserves user state and is idempotent", async () => {
  let record = initial();
  let calls = 0;
  const backups = [];
  const options = { source: "redis", key: record.deviceToken, registry, apply: true, now: "2026-09-05T18:00:00Z",
    read: async () => ({ ...record }), backup: async (entry) => backups.push(entry),
    write: async (old, next, timestamp) => {
      if (++calls === 1) { record = { ...record, preferencesRevision: 43, apnsToken: "new-token" }; return false; }
      record = { ...old, notificationTeamSubscriptions: next, notificationTeamSubscriptionsUpdatedAt: timestamp }; return true;
    },
  };
  assert.equal((await migrateRecord(options)).status, "updated");
  assert.equal(record.apnsToken, "new-token");
  assert.equal(record.preferencesRevision, 43);
  assert.equal(record.preferences.notificationDelayMinutes, 1);
  assert.equal(record.notificationTeamSubscriptions.bindings["newcastle-united"], "4");
  assert.equal((await migrateRecord(options)).status, "unchanged");
  assert.equal(calls, 2);
  assert.equal(backups.length, 2);
});
