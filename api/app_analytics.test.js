"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { EventEmitter } = require("node:events");
const { createAppAnalytics, normalizeEvent, windows, routeFamily } = require("./app_analytics");

const now = Date.parse("2026-09-27T12:00:00Z");
const token = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa";
function payload(overrides = {}) {
  return { schemaVersion: 2, eventId: crypto.randomUUID(), event: "app_open", recordedAt: new Date(now - 1000).toISOString(),
    surface: "ios_app", state: "foreground", buildType: "production", appVersion: "2.1", osVersion: "26.5", deviceType: "phone", ...overrides };
}

test("London calendar boundaries follow BST and both DST transitions", () => {
  assert.equal(windows(now).today[0], Date.parse("2026-09-26T23:00:00Z"));
  const spring = windows(Date.parse("2026-03-30T12:00:00Z")).yesterday;
  const autumn = windows(Date.parse("2026-10-26T12:00:00Z")).yesterday;
  assert.equal(spring[1] - spring[0], 23 * 3600000);
  assert.equal(autumn[1] - autumn[0], 25 * 3600000);
  const afterSpring = Date.parse("2026-03-31T00:30:00+01:00");
  assert.ok(windows(afterSpring).earlier_day[0] <= afterSpring - 48 * 3600000);
});

test("validation bounds identifiers, event names, timestamps and duration metadata", () => {
  for (const change of [{ event: "search_private_text" }, { screen: "private search" }, { eventId: "bad" },
    { recordedAt: new Date(now - 49 * 3600000).toISOString() }, { recordedAt: new Date(now + 3600000).toISOString() }]) {
    assert.throws(() => normalizeEvent(payload(change), token, now), { status: 400 });
  }
  const normalized = normalizeEvent(payload({ durationMs: null, appVersion: "arbitrary", deviceModel: "secret" }), token, now);
  assert.equal(normalized.duration_seconds, null);
  assert.equal(normalized.app_version, "unknown");
  assert.equal(normalized.os_major, "26");
  assert.equal(normalized.deviceModel, undefined);
  assert.equal(normalized.expires_at - normalized.recorded_at, 45 * 86400000);
  assert.equal(normalizeEvent(payload({ schemaVersion: undefined }), token, now).schema, 1);
});

test("request metrics cover early routes and collapse dynamic paths without identifiers", () => {
  assert.equal(routeFamily("/api/v1/prediction-game/fixtures/secret"), "prediction-game");
  assert.equal(routeFamily("/api/v1/anything/private"), "other");
  const analytics = createAppAnalytics();
  const res = new EventEmitter(); res.statusCode = 200;
  let called = false;
  analytics.requestMiddleware({ path: "/api/v1/matches/private", get: (key) => ({ "X-Device-Token": token, "X-Client-Surface": "widget", "X-Client-State": "background", "X-Build-Type": "production" })[key] }, res, () => { called = true; });
  res.emit("finish");
  const metrics = analytics.metrics();
  assert.equal(called, true);
  assert.match(metrics, /surface="widget".*state="background".*route="matches"/);
  assert.doesNotMatch(metrics, /private|aaaaaaaa/);
});

test("database failure does not report a healthy zero audience and permits retries", async () => {
  const analytics = createAppAnalytics({ database: async () => null, clock: () => now });
  await assert.rejects(analytics.accept(payload(), token), { status: 503 });
  await analytics.refresh();
  assert.match(analytics.metrics(), /top_scores_audience_ready 0/);
  assert.doesNotMatch(analytics.metrics(), /top_scores_audience_active_installations/);
});

test("Mongo persistence, deduplication, audience exclusion, feature reach and snapshots", { skip: !process.env.APP_ANALYTICS_TEST_MONGO_URI }, async () => {
  const { MongoClient } = require("mongodb");
  const uri = process.env.APP_ANALYTICS_TEST_MONGO_URI;
  assert.match(uri, /^mongodb:\/\/127\.0\.0\.1:/, "Integration tests only use an isolated local database");
  const client = new MongoClient(uri);
  await client.connect();
  const db = client.db(`app_analytics_test_${process.pid}_${Date.now()}`);
  let clock = now;
  const options = { database: async () => db, clock: () => clock };
  try {
    const first = createAppAnalytics(options);
    const opened = payload();
    assert.equal((await first.accept(opened, token)).duplicate, false);
    assert.equal((await first.accept(opened, token)).duplicate, true);
    const concurrent = payload({ event: "manual_refresh", screen: "tables" });
    const deliveries = await Promise.all(Array.from({ length: 8 }, () => first.accept(concurrent, token)));
    assert.equal(deliveries.filter((delivery) => !delivery.duplicate).length, 1);
    await first.accept(payload({ event: "screen_view", screen: "tables" }), token);
    await first.accept(payload({ event: "screen_view", screen: "tables" }), token);
    await first.accept(payload({ event: "screen_view", screen: "fantasy" }), token);
    await first.accept(payload({ recordedAt: new Date(now - 3 * 86400000).toISOString(), schemaVersion: undefined }), crypto.randomUUID());
    for (const override of [{ buildType: "debug" }, { state: "background" }, { surface: "widget" }, { schemaVersion: undefined }]) {
      await first.accept(payload(override), crypto.randomUUID());
    }
    const other = crypto.randomUUID();
    await first.accept(payload({ recordedAt: new Date(now - 86400000).toISOString() }), other);
    await first.refresh();
    let metrics = first.metrics();
    assert.match(metrics, /active_installations\{window="today"\} 1/);
    assert.match(metrics, /active_installations\{window="7d"\} 2/);
    assert.match(metrics, /active_installations\{window="30d"\} 2/);
    assert.match(metrics, /feature_installations\{window="today",screen="tables"\} 1/);
    assert.match(metrics, /feature_visits\{window="today",screen="tables"\} 2/);
    assert.match(metrics, /events\{window="today",event="app_open"\} 1/);
    assert.match(metrics, /installations_by_dimension\{window="7d",dimension="app_version",value="2.1"\} 2/);
    assert.doesNotMatch(metrics, new RegExp(token));
    const samples = metrics.split("\n").filter((line) => line && !line.startsWith("#")).map((line) => line.slice(0, line.lastIndexOf(" ")));
    assert.equal(new Set(samples).size, samples.length, "Each Prometheus sample must have a unique name and label set");
    const restarted = createAppAnalytics(options);
    assert.equal((await restarted.accept(opened, token)).duplicate, true);
    await restarted.refresh();
    assert.match(restarted.metrics(), /active_installations\{window="7d"\} 2/);
    const stored = await db.collection("app_analytics_events").findOne({ event: "app_open" });
    assert.match(stored.installation, /^[a-f0-9]{64}$/);
    assert.notEqual(stored.installation, token);
    const daily = await db.collection("app_analytics_daily").findOne({ _id: "2026-09-27" });
    assert.equal(daily.summary.audience[0].total[0].count, 1);
    assert.doesNotMatch(JSON.stringify(daily), new RegExp(stored.installation));
    const indexes = await db.collection("app_analytics_events").indexes();
    assert.ok(indexes.some((index) => index.expireAfterSeconds === 0));
    // An update changes the installation's version bucket without counting it twice.
    clock += 10000;
    await restarted.accept(payload({ appVersion: "2.2", recordedAt: new Date(clock - 1).toISOString() }), token);
    await restarted.refresh();
    metrics = restarted.metrics();
    assert.match(metrics, /active_installations\{window="7d"\} 2/);
    assert.match(metrics, /dimension="app_version",value="2.2"\} 1/);
    clock += 4 * 60000;
    assert.match(restarted.metrics(), /top_scores_audience_ready 0/);
    // Rolling counts expire even before Mongo's asynchronous TTL cleanup.
    clock += 31 * 86400000;
    await restarted.refresh();
    assert.match(restarted.metrics(), /active_installations\{window="30d"\} 0/);
  } finally { await db.dropDatabase(); await client.close(); }
});
