"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  matchListingsToEvents,
  prepareListings,
  teamSimilarity,
  __private,
} = require("./live_football_tv_listings");

function listing(overrides = {}) {
  return {
    date_local: "2026-08-30",
    time_local: "16:30",
    home_team: "Manchester United",
    away_team: "Ipswich Town",
    competition: "Premier League",
    channels: [{ name: "Sky Sports Main Event" }],
    ...overrides,
  };
}

function event(id, overrides = {}) {
  return {
    _id: String(id),
    payload: {
      id,
      league_id: 1,
      event_date: "2026-08-30T15:30:00Z",
      home_team: "Manchester United",
      away_team: "Ipswich Town",
      ...overrides,
    },
  };
}

const leagues = [{ _id: "1", payload: { id: 1, name: "Premier League" } }];

test("prepareListings deduplicates source rows, normalises channels, and converts London DST", () => {
  const records = prepareListings([
    listing(),
    listing({ channels: [{ name: "Sky Sports Main Event" }, { name: "Sky Sports Premier League" }] }),
  ]);
  assert.equal(records.length, 1);
  assert.equal(records[0].kickoff_at, "2026-08-30T15:30:00.000Z");
  assert.deepEqual(records[0].channels.map((channel) => channel.name), [
    "Sky Sports Main Event",
    "Sky Sports Premier League",
  ]);
});

test("prepareListings excludes incomplete audit rows", () => {
  assert.deepEqual(prepareListings([
    listing({ home_team: "" }),
    listing({ channels: [] }),
    listing({ competition: "" }),
  ]), []);
});

test("matching accepts an exact canonical team pair and local kickoff", () => {
  const records = prepareListings([listing()]);
  const result = matchListingsToEvents(records, [event(101)], leagues);
  assert.equal(result.matched, 1);
  assert.equal(result.assignments[0].matched_event_id, "101");
  assert.equal(result.assignments[0].match_method, "canonical_teams_and_kickoff");
});

test("matching uses both fuzzy team names and kickoff proximity", () => {
  const records = prepareListings([
    listing({ home_team: "Manchester Utd", away_team: "Ipswich" }),
  ]);
  const result = matchListingsToEvents(records, [event(102)], leagues);
  assert.equal(result.matched, 1);
  assert.equal(result.assignments[0].matched_event_id, "102");
});

test("matching rejects time-only candidates with unrelated teams", () => {
  const records = prepareListings([listing()]);
  const result = matchListingsToEvents(records, [
    event(103, { home_team: "Chelsea", away_team: "Arsenal" }),
  ], leagues);
  assert.equal(result.matched, 0);
  assert.equal(result.unmatched, 1);
});

test("matching leaves equally plausible same-date candidates ambiguous", () => {
  const records = prepareListings([listing({ time_local: "16:35" })]);
  const result = matchListingsToEvents(records, [
    event(104),
    event(105, { event_date: "2026-08-30T15:40:00Z" }),
  ], leagues);
  assert.equal(result.matched, 0);
  assert.equal(result.ambiguous, 1);
  assert.equal(result.assignments[0].match_reason, "candidate_margin_too_small");
});

test("matching enforces one-to-one assignment", () => {
  const records = prepareListings([
    listing(),
    listing({ competition: "English Premier League" }),
  ]);
  const result = matchListingsToEvents(records, [event(106)], leagues);
  assert.equal(result.matched, 1);
  assert.equal(result.ambiguous, 1);
});

test("team similarity handles punctuation and common abbreviation differences", () => {
  assert.equal(teamSimilarity("Paris Saint-Germain", "Paris Saint Germain"), 1);
  assert.ok(teamSimilarity("Manchester Utd", "Manchester United") >= 0.72);
});

test("London event conversion uses the correct side of daylight saving", () => {
  assert.deepEqual(__private.londonDateTime("2026-08-30T15:30:00Z"), {
    date: "2026-08-30",
    time: "16:30",
    timestamp: Date.parse("2026-08-30T15:30:00Z"),
  });
});

test("snapshot validation rejects a structurally incomplete first scrape", () => {
  assert.throws(
    () => __private.validateSnapshot(Array.from({ length: 24 }, () => ({})), null),
    /too few valid listings/
  );
});

test("TV query bounds cover whole London days including DST changes", () => {
  assert.deepEqual(__private.listingDateBounds([{ date_local: "2026-03-29" }]), {
    start: "2026-03-29T00:00:00.000Z", end: "2026-03-29T23:00:00.000Z",
  });
  assert.deepEqual(__private.listingDateBounds([{ date_local: "2026-10-25" }]), {
    start: "2026-10-24T23:00:00.000Z", end: "2026-10-26T00:00:00.000Z",
  });
  assert.equal(__private.listingDateBounds([]), null);
  assert.equal(__private.listingDateBounds([{ date_local: "2026-02-31" }]), null);
});

test("TV reconciliation restricts the database read and preserves matching with projected fields", async () => {
  const fs = require("node:fs");
  const vm = require("node:vm");
  const records = prepareListings([listing()]);
  const reads = [];
  const details = [];
  let saved;
  const module = { exports: {} };
  const mongo = {
    getLiveFootballTvSnapshot: async () => records,
    getBsdRecords: async (collection, filter, options) => {
      reads.push({ collection, filter, options });
      if (collection === "bsd_leagues") return leagues;
      assert.equal(filter.event_date.$gte, "2026-08-29T23:00:00.000Z");
      assert.equal(filter.event_date.$lt, "2026-08-30T23:00:00.000Z");
      assert.equal(options.projection.payload, undefined);
      const payload = event(101).payload;
      return [{ _id: "101", payload: Object.fromEntries(Object.keys(options.projection)
        .filter((key) => key.startsWith("payload."))
        .map((key) => [key.slice(8), payload[key.slice(8)]])) }];
    },
    updateLiveFootballTvListingMatches: async (_, assignments) => { saved = assignments; },
  };
  vm.runInNewContext(fs.readFileSync(require.resolve("./live_football_tv_listings"), "utf8"), {
    module, console, process, Buffer,
    require: (name) => name === "./mongo_client" ? mongo
      : name === "./bsd_diagnostics" ? { detail: (record) => details.push(record) } : require(name),
  });
  const result = await module.exports.reconcileLiveFootballTvSnapshot("test");
  assert.equal(result.matched, 1);
  assert.equal(saved[0].matched_event_id, "101");
  assert.equal(reads.length, 2);
  assert.equal(details[0].candidateEventCount, 1);
  assert.equal(details[0].changedAssignmentCount, 1);
  records.length = 0;
  reads.length = 0;
  const empty = await module.exports.reconcileLiveFootballTvSnapshot("empty");
  assert.equal(empty.total, 0);
  assert.equal(reads.length, 0, "empty listings must not trigger a historical collection read");
});
