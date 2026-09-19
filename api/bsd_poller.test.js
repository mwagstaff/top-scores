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
  selectIncompleteFinishedEventIds,
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

test("finished incidents repair finds missing, empty, unnamed and stale pre-match incidents", () => {
  const nowMs = Date.parse("2026-09-17T20:00:00Z");
  const events = ["missing", "empty", "no-subs", "unnamed", "healthy", "fresh", "pre-match", "no-bench"]
    .map((_id) => ({ _id, status: "finished", event_date: "2026-09-15T19:00:00Z" }));
  const incidentDocs = [
    { _id: "empty", payload: { incidents: [] } },
    { _id: "no-subs", payload: { incidents: [{ type: "goal" }] } },
    { _id: "unnamed", payload: { incidents: [{ type: "substitution", player_in: "", player_out: "A" }] } },
    { _id: "healthy", payload: { incidents: [{ type: "substitution", player_in: "B", player_out: "A" }] } },
    { _id: "fresh", updated_at: "2026-09-17T19:00:00Z", payload: { incidents: [] } },
    { _id: "pre-match", updated_at: "2026-09-17T16:00:00Z", payload: { incidents: [] } },
    { _id: "no-bench", payload: { incidents: [{ type: "goal" }] } },
  ];
  events.find((event) => event._id === "pre-match").event_date = "2026-09-17T16:30:00Z";
  // A stale pre-match snapshot must be eligible even when fetched within 24h.
  const lineupDocs = events.filter((event) => event._id !== "no-bench").map(({ _id }) => ({
    _id, payload: { lineups: { home: { substitutes: [{ id: 1 }] } } },
  }));
  assert.deepEqual(selectIncompleteFinishedEventIds(events, incidentDocs, lineupDocs, nowMs),
    ["missing", "empty", "no-subs", "unnamed", "pre-match"]);
});

test("finished incidents repair excludes live, old and just-finished matches and bounds each batch", () => {
  const nowMs = Date.parse("2026-09-17T20:00:00Z");
  const events = [
    { _id: "live", status: "inprogress", event_date: "2026-09-17T16:00:00Z" },
    { _id: "old", status: "finished", event_date: "2026-07-01T16:00:00Z" },
    { _id: "recent", status: "finished", event_date: "2026-09-17T19:00:00Z" },
    ...Array.from({ length: 25 }, (_, i) => ({
      _id: String(i), status: "finished", event_date: "2026-09-15T19:00:00Z",
    })),
  ];
  const ids = selectIncompleteFinishedEventIds(events, [], [], nowMs);
  assert.deepEqual(ids, Array.from({ length: 20 }, (_, i) => String(i)));
  const freshlyRetried = ids.map((_id) => ({ _id, updated_at: "2026-09-17T19:00:00Z", payload: { incidents: [] } }));
  assert.deepEqual(selectIncompleteFinishedEventIds(events, freshlyRetried, [], nowMs),
    ["20", "21", "22", "23", "24"]);
  const failedAttempts = new Map(ids.map((id) => [id, nowMs]));
  assert.deepEqual(selectIncompleteFinishedEventIds(events, [], [], nowMs, failedAttempts),
    ["20", "21", "22", "23", "24"]);
  assert.equal(selectIncompleteFinishedEventIds(events.slice(3), [], [], nowMs + 24 * 60 * 60 * 1000, failedAttempts)[0], "0");
});

test("finished incidents repair saves recovered events and continues after individual failures", async () => {
  const vm = require("node:vm");
  const fs = require("node:fs");
  const saved = [];
  const calls = [];
  const publications = [];
  const events = ["recovered", "failed", "malformed"].map((_id) => ({
    _id, status: "finished", event_date: new Date(Date.now() - 2 * 24 * 60 * 60 * 1000).toISOString(),
  }));
  const recoveredPayload = { event_id: "recovered", incidents: [
    { type: "substitution", player_in: "B", player_out: "A", minute: 64 },
  ] };
  const overrides = {
    "./fetch_bsd_events": { refreshIncrementalEvents: async () => {} },
    "./live_football_tv_listings": { reconcileActiveLiveFootballTvListings: async () => {} },
    "./bsd_current_matches": {
      publishBsdCurrentMatchesProjection: async (reason) => {
        publications.push(reason);
        return { changed: false, payload_hash: "repaired" };
      },
    },
    "./mongo_client": {
      getBsdRecords: async (collection, filter) => {
        if (collection === "bsd_events") {
          assert.equal(filter.status, "finished");
          assert.ok(filter.league_id.$in.includes("8"));
          return events;
        }
        return [];
      },
      upsertBsdRecord: async (...args) => saved.push(args),
    },
    "./bsd_client": {
      setRequestObserver() {},
      async getIncidents(id, options) {
        calls.push([id, options.trigger]);
        if (id === "failed") throw new Error("upstream unavailable");
        return id === "malformed" ? {} : recoveredPayload;
      },
    },
  };
  const pollerModule = { exports: {} };
  vm.runInNewContext(fs.readFileSync(require.resolve("./bsd_poller"), "utf8"), {
    require: (name) => overrides[name] || require(name), module: pollerModule,
    process, AbortController, console: { error() {}, log() {}, warn() {} },
  });
  await pollerModule.exports.refreshEvents();
  assert.deepEqual(calls.map(([id]) => id), ["recovered", "failed", "malformed"]);
  assert.ok(calls.every(([, trigger]) => trigger === "finished_incidents_repair"));
  assert.equal(saved.length, 1);
  assert.equal(saved[0][0], "bsd_incidents");
  assert.equal(saved[0][1], "recovered");
  assert.equal(saved[0][2], recoveredPayload);
  assert.equal(saved[0][3].event_id, "recovered");
  assert.deepEqual(publications, ["events_refresh"]);
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

function isolatedPollerState(overrides = {}, clock = Date) {
  const vm = require("node:vm");
  const fs = require("node:fs");
  const dependencies = {
    "./bsd_client": { setRequestObserver() {} },
    "./mongo_client": { getBsdRecords: async () => [], upsertBsdRecord: async () => {} },
    "./bsd_current_matches": {
      publishBsdCurrentMatchesProjection: async () => ({ changed: false, payload_hash: "test" }),
    },
    ...overrides,
  };
  return vm.runInNewContext(
    fs.readFileSync(require.resolve("./bsd_poller"), "utf8") + `
      ;({ poller: module.exports, finishedIncidentRepairAttempts, incidentPayloadHashes,
          setLiveIds(ids) { liveEventIds = ids; } });`,
    {
      require: (name) => dependencies[name] || require(name), module: { exports: {} },
      process, AbortController, Date: clock, console: { error() {}, log() {}, warn() {} },
    }
  );
}

test("finished incident repair drops expired retry history even when no matches remain", async () => {
  const nowMs = Date.parse("2026-09-19T20:00:00Z");
  const dayMs = 24 * 60 * 60 * 1000;
  const state = isolatedPollerState({}, class extends Date {
    static now() { return nowMs; }
  });
  state.finishedIncidentRepairAttempts.set("old", nowMs - 2 * dayMs);
  state.finishedIncidentRepairAttempts.set("expired", nowMs - dayMs);
  state.finishedIncidentRepairAttempts.set("recent", nowMs - dayMs + 1);

  await state.poller.reconcileIncompleteFinishedIncidents();

  assert.deepEqual([...state.finishedIncidentRepairAttempts.keys()], ["recent"]);
});

test("an incident response arriving after settlement does not retain the finished event hash", async () => {
  let completeRequest;
  let writes = 0;
  const state = isolatedPollerState({
    "./bsd_client": {
      setRequestObserver() {},
      getIncidents: () => new Promise((resolve) => { completeRequest = resolve; }),
    },
    "./mongo_client": { upsertBsdRecord: async () => { writes += 1; } },
  });
  state.setLiveIds([101]);
  state.incidentPayloadHashes.set("101", "previous");
  const polling = state.poller.pollIncidents();

  // The live poll removes both the ID and hash when a match finishes.
  state.setLiveIds([]);
  state.incidentPayloadHashes.delete("101");
  completeRequest({ event_id: 101, incidents: [] });
  await polling;

  assert.equal(writes, 1);
  assert.equal(state.incidentPayloadHashes.size, 0);

  // Hashes must still deduplicate writes for matches that remain live.
  state.setLiveIds([102]);
  const livePolling = state.poller.pollIncidents();
  completeRequest({ event_id: 102, incidents: [] });
  await livePolling;
  const repeatedPolling = state.poller.pollIncidents();
  completeRequest({ event_id: 102, incidents: [] });
  await repeatedPolling;
  assert.equal(writes, 2);
  assert.equal(state.incidentPayloadHashes.size, 1);
});

test("live event hashes are pruned even when saving the next live snapshot fails", async () => {
  const state = isolatedPollerState({
    "./bsd_client": {
      setRequestObserver() {},
      getLiveEvents: async () => ({ events: [{ id: 102, league_id: 1 }] }),
    },
    "./mongo_client": { upsertBsdRecords: async () => { throw new Error("Mongo unavailable"); } },
  });
  state.setLiveIds([101, 102]);
  state.incidentPayloadHashes.set("101", "finished");
  state.incidentPayloadHashes.set("102", "live");

  await state.poller.pollLiveEvents();

  assert.deepEqual([...state.incidentPayloadHashes.keys()], ["102"]);
});
