const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

function loadRedisWithFakeClient(fakeClient, warnings, mongoStore = null) {
  const module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(require.resolve("./redis_client"), "utf8"), {
    module,
    require: (name) => name === "redis" ? { createClient: () => fakeClient }
      : name === "./mongo_client" && mongoStore ? mongoStore : require(name),
    process,
    Buffer,
    console: { log() {}, warn: (...args) => warnings.push(args), error() {} },
  });
  return module.exports;
}

test("first Redis read completes while expiry maintenance is still blocked", async () => {
  let finishSweep;
  const sweep = new Promise((resolve) => { finishSweep = resolve; });
  const handlers = {};
  let connects = 0;
  let scans = 0;
  const expired = [];
  const fakeClient = {
    on(event, handler) { handlers[event] = handler; },
    async connect() { connects += 1; handlers.connect(); },
    async ttl() { return -1; },
    async expire(key) { expired.push(key); },
    async *scanIterator() { scans += 1; await sweep; yield ["old-history"]; },
    async sMembers() { return ["601133"]; },
    async mGet() { return [JSON.stringify({ id: "601133", home_score: 2, away_score: 1 })]; },
    async get() { return null; },
  };
  const warnings = [];
  const redis = loadRedisWithFakeClient(fakeClient, warnings);
  let snapshot;
  const pending = redis.getAllOperationalMatchDetails().then((value) => { snapshot = value; });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(snapshot?.records["601133"].home_score, 2);
  assert.equal(scans, 1, "the maintenance sweep should have started");
  assert.equal(expired.includes("old-history"), false);
  assert.equal(await redis.getClient(), fakeClient);
  assert.equal(connects, 1);
  finishSweep();
  await pending;
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(expired.includes("old-history"), "maintenance must still finish in the background");
  assert.equal(warnings.length, 0);
});

test("failed background expiry maintenance does not make Redis unavailable", async () => {
  const handlers = {};
  const warnings = [];
  const fakeClient = {
    on(event, handler) { handlers[event] = handler; },
    async connect() { handlers.connect(); },
    async ttl() { throw new Error("maintenance failed"); },
  };
  const redis = loadRedisWithFakeClient(fakeClient, warnings);
  assert.equal(await redis.getClient(), fakeClient);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(await redis.getClient(), fakeClient);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0].join(" "), /Failed applying TTL policy: maintenance failed/);
});

const {
  __private: {
    mergedLiveActivityState,
    mergePreferenceWriteLiveActivity,
    normalizeLiveActivityStatePatch,
    normalizedPreferencesRevision,
    isStalePreferencesRevision,
  },
} = require("./redis_client");

test("preference write preserves lifecycle state registered after the write began", () => {
  const staleIncoming = {
    preferences: { showAllMatches: true },
    liveActivity: {
      pushToStartToken: "start-token",
      currentActivityId: null,
      currentActivityPushToken: null,
    },
  };
  const current = {
    liveActivity: {
      pushToStartToken: "start-token",
      currentActivityId: "activity-1",
      currentActivityPushToken: "update-token",
      lastStartAt: "2026-09-14T16:31:52.000Z",
    },
  };

  const merged = mergePreferenceWriteLiveActivity(staleIncoming, current);

  assert.deepEqual(merged.preferences, { showAllMatches: true });
  assert.equal(merged.liveActivity.currentActivityId, "activity-1");
  assert.equal(merged.liveActivity.currentActivityPushToken, "update-token");
  assert.equal(merged.liveActivity.lastStartAt, "2026-09-14T16:31:52.000Z");
});

test("explicit lifecycle patch still applies during an atomic preference write", () => {
  const merged = mergePreferenceWriteLiveActivity(
    { preferences: {}, liveActivity: { currentActivityId: null } },
    { liveActivity: { currentActivityId: "activity-1", pendingStartAt: "old" } },
    { pendingStartAt: null }
  );

  assert.equal(merged.liveActivity.currentActivityId, "activity-1");
  assert.equal(merged.liveActivity.pendingStartAt, null);
});

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

test("concurrent preference and Live Activity writes preserve the latest filters", async (t) => {
  const { spawn, spawnSync } = require("node:child_process");
  const { once } = require("node:events");
  const os = require("node:os");
  const path = require("node:path");
  const { createClient } = require("redis");
  if (spawnSync("redis-server", ["--version"]).error) {
    t.skip("redis-server is required for atomic write integration tests");
    return;
  }
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "preferences-race-"));
  const socket = path.join(directory, "redis.sock");
  const server = spawn("redis-server", ["--port", "0", "--unixsocket", socket,
    "--save", "", "--appendonly", "no"], { stdio: "ignore" });
  const client = createClient({ socket: { path: socket } });
  client.on("error", () => {});
  t.after(async () => {
    if (client.isOpen) await client.quit();
    const exited = once(server, "exit");
    server.kill();
    await exited;
    fs.rmSync(directory, { recursive: true, force: true });
  });
  await client.connect();
  let beforeCommit = null;
  const wrapped = new Proxy(client, {
    get(target, property) {
      if (property === "connect") return async () => {};
      if (property === "multi") return () => {
        const transaction = target.multi();
        const exec = transaction.exec.bind(transaction);
        transaction.exec = async () => {
          const callback = beforeCommit;
          beforeCommit = null;
          if (callback) await callback();
          return exec();
        };
        return transaction;
      };
      if (property === "eval") return async (...args) => {
        const callback = beforeCommit;
        beforeCommit = null;
        if (callback) await callback();
        return target.eval(...args);
      };
      const value = target[property];
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  const mirrors = [];
  const redis = loadRedisWithFakeClient(wrapped, [], {
    getUserPreferences: async () => null,
    upsertUserPreferences: async (record) => mirrors.push(record),
  });
  const token = "race-test";
  const key = `top_scores:user_preferences:${token}`;
  const all = { showAllMatches: true, selectedFixtureViewOptionIDs: [], selectedLeagues: [] };
  const top = { ...all, showAllMatches: false, selectedFixtureViewOptionIDs: ["preset:top-teams"] };
  const read = async () => JSON.parse(await client.get(key));

  await t.test("Live Activity callback cannot restore Show all after Top teams saves", async () => {
    await redis.saveUserPreferences(token, all, "apns", true, { preferencesRevision: 1 });
    beforeCommit = () => redis.saveUserPreferences(token, top, "apns", true, { preferencesRevision: 2 });
    await redis.updateUserLiveActivityState(token, { currentActivityId: "activity-new" });
    const saved = await read();
    assert.deepEqual(saved.preferences, top);
    assert.equal(saved.preferencesRevision, 2);
    assert.equal(saved.liveActivity.currentActivityId, "activity-new");
    assert.equal(saved.storageRevision, 3);
  });
  await t.test("older preference sync cannot win after passing an earlier revision check", async () => {
    beforeCommit = () => redis.saveUserPreferences(token, top, "apns", true, { preferencesRevision: 4 });
    await redis.saveUserPreferences(token, all, "apns", true, { preferencesRevision: 3 });
    assert.deepEqual((await read()).preferences, top);
    assert.equal((await read()).preferencesRevision, 4);
  });
  await t.test("preference sync preserves a concurrently registered ActivityKit token", async () => {
    beforeCommit = () => redis.updateUserLiveActivityState(token, { currentActivityPushToken: "fresh-token" });
    await redis.saveUserPreferences(token, top, "apns", true, { preferencesRevision: 5 });
    assert.equal((await read()).liveActivity.currentActivityPushToken, "fresh-token");
    assert.deepEqual((await read()).preferences.selectedLeagues, []);
    assert.deepEqual(JSON.parse(JSON.stringify(mirrors.at(-1).preferences)), top);
  });
});
