"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { __private } = require("./bsd_poller");
const {
  computeLiveLeagueIds,
  filterAllowlistedLiveEvents,
  diffSettledLeagueIds,
  diffSettledEventIds,
  mapWithConcurrency,
  selectPrematchLineupEventIds,
  millisecondsUntilNextLondonTime,
  buildMetricsText,
} = __private;

test("computeLiveLeagueIds: keeps only allowlisted league ids, deduped", () => {
  const events = [
    { id: 1, league_id: 27 },
    { id: 2, league_id: 27 },
    { id: 3, league_id: 999 }, // not allowlisted
    { id: 4, league_id: null },
  ];
  const ids = computeLiveLeagueIds(events, ["27", "1"]);
  assert.deepEqual([...ids], ["27"]);
});

test("computeLiveLeagueIds: handles empty/non-array input", () => {
  assert.equal(computeLiveLeagueIds([], ["27"]).size, 0);
  assert.equal(computeLiveLeagueIds(null, ["27"]).size, 0);
});

test("filterAllowlistedLiveEvents: excludes global events outside configured leagues", () => {
  const events = [
    { id: 1, league_id: 27 },
    { id: 2, league_id: "1" },
    { id: 3, league_id: 999 },
    { id: null, league_id: 27 },
  ];
  assert.deepEqual(filterAllowlistedLiveEvents(events, ["27", "1"]), events.slice(0, 2));
  assert.deepEqual(filterAllowlistedLiveEvents(null, ["27"]), []);
});

test("diffSettledLeagueIds: returns leagues that dropped out of the live set", () => {
  const previous = new Set(["27", "1"]);
  const next = new Set(["27"]);
  assert.deepEqual(diffSettledLeagueIds(previous, next), ["1"]);
});

test("diffSettledLeagueIds: empty when nothing settled or nothing was live", () => {
  assert.deepEqual(diffSettledLeagueIds(new Set(), new Set(["27"])), []);
  assert.deepEqual(diffSettledLeagueIds(new Set(["27"]), new Set(["27"])), []);
});

test("diffSettledEventIds: returns events that disappeared from the live list", () => {
  assert.deepEqual(diffSettledEventIds([101, "102", 103], ["101", 103]), ["102"]);
  assert.deepEqual(diffSettledEventIds([], [101]), []);
});

test("mapWithConcurrency preserves result order and bounds active workers", async () => {
  let active = 0;
  let maxActive = 0;
  const results = await mapWithConcurrency([1, 2, 3, 4, 5], 2, async (value) => {
    active += 1;
    maxActive = Math.max(maxActive, active);
    await new Promise((resolve) => setTimeout(resolve, value % 2));
    active -= 1;
    return value * 10;
  });
  assert.deepEqual(results, [10, 20, 30, 40, 50]);
  assert.equal(maxActive, 2);
});

test("selectPrematchLineupEventIds applies adaptive cadence and skips confirmed/live events", () => {
  const nowMs = Date.parse("2026-08-15T12:00:00Z");
  const events = [
    { _id: "early-due", status: "notstarted", event_date: "2026-08-15T13:30:00Z" },
    { _id: "early-fresh", status: "notstarted", event_date: "2026-08-15T13:30:00Z" },
    { _id: "close-due", status: "notstarted", event_date: "2026-08-15T12:30:00Z" },
    { _id: "confirmed", status: "notstarted", event_date: "2026-08-15T12:20:00Z" },
    { _id: "already-live", status: "notstarted", event_date: "2026-08-15T12:10:00Z" },
    { _id: "too-far", status: "notstarted", event_date: "2026-08-15T15:00:00Z" },
  ];
  const lineupDocs = [
    { _id: "early-fresh", updated_at: "2026-08-15T11:58:00Z" },
    { _id: "close-due", updated_at: "2026-08-15T11:58:00Z" },
    { _id: "confirmed", lineup_status: "confirmed", updated_at: "2026-08-15T11:00:00Z" },
  ];
  const ids = selectPrematchLineupEventIds(
    events,
    lineupDocs,
    ["already-live"],
    nowMs,
    {
      windowMs: 2 * 60 * 60 * 1000,
      closeWindowMs: 45 * 60 * 1000,
      earlyPollMs: 5 * 60 * 1000,
      closePollMs: 60 * 1000,
    }
  );
  assert.deepEqual(ids, ["early-due", "close-due"]);
});

test("millisecondsUntilNextLondonTime: returns a positive delay within 24h", () => {
  const delayMs = millisecondsUntilNextLondonTime(0, 15);
  assert.ok(delayMs > 0);
  assert.ok(delayMs <= 24 * 60 * 60 * 1000);
});

test("millisecondsUntilNextLondonTime: clamps out-of-range hour/minute", () => {
  const delayMs = millisecondsUntilNextLondonTime(99, 99);
  assert.ok(delayMs > 0);
  assert.ok(delayMs <= 24 * 60 * 60 * 1000);
});

test("buildMetricsText exposes BSD poller metrics", () => {
  const text = buildMetricsText();
  assert.match(text, /top_scores_runtime_info\{[^}]*runtime="bsd_poller"[^}]*\}\s+1\b/);
  assert.match(text, /^# HELP top_scores_bsd_http_requests_total\b/m);
  assert.match(text, /^# HELP top_scores_bsd_http_timeouts_total\b/m);
  assert.match(text, /^top_scores_bsd_live_events \d+$/m);
  assert.match(text, /^top_scores_bsd_rate_limiter_queue_depth \d+$/m);
  assert.match(text, /^top_scores_bsd_request_concurrency\{kind="max"\} \d+$/m);
  assert.match(text, /^top_scores_process_resident_memory_bytes \d+$/m);
  assert.match(text, /^top_scores_process_heap_bytes\{kind="used"\} \d+$/m);
});
