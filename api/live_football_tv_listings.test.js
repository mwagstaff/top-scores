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
