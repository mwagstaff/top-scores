"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { __private } = require("./bsd_poller");
const {
  computeLiveLeagueIds,
  filterAllowlistedLiveEvents,
  diffSettledLeagueIds,
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
  assert.match(text, /^top_scores_process_resident_memory_bytes \d+$/m);
  assert.match(text, /^top_scores_process_heap_bytes\{kind="used"\} \d+$/m);
});
