"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const { calculateWatchability } = require("./watchability");

// Exercise the server adapter without connecting to Redis or starting a server.
const source = fs.readFileSync(require.resolve("./server"), "utf8");
const start = source.indexOf("function watchabilityIndexForMatch(");
const end = source.indexOf("\nfunction ", start + 1);
assert.ok(start >= 0 && end > start);
function adapter({ premierLeagueTeams = [], ratings = {} } = {}) {
  const context = {
    watchabilityIndexByMatchKey: new Map(),
    matchKey: (match) => `${match.home_team}:${match.away_team}`,
    zonedDateTimeToUtcMs: () => Date.now() + 3600000,
    MATCH_DISPLAY_TIME_ZONE: "Europe/London",
    normalizeMatchStatusValue: () => "",
    isInProgressMatchStatus: () => false,
    isFinishedMatchStatus: () => false,
    currentWatchabilityContext: () => ({
      fixtureContext: {
        clubEloTeamForName: (name) => ratings[name] || null,
        isPremierLeagueTeam: (name) => premierLeagueTeams.includes(name),
      },
      tables: [],
    }),
    isLikelyNationalTeamName: () => false,
    watchabilityTableForLeague: () => null,
    watchabilityStandingForTeam: () => null,
    watchabilityRivalryForMatch: () => null,
    calculateWatchability,
  };
  vm.runInNewContext(source.slice(start, end), context);
  return context.watchabilityIndexForMatch;
}

const match = {
  home_team: "Fleetwood Town", away_team: "Arsenal", league: "EFL Cup",
  league_subcategory: "Round 4", tv_channels: ["Sky Sports"],
};

test("server forwards current Premier League membership and ratings into cup scoring", () => {
  const rate = adapter({
    premierLeagueTeams: ["Arsenal"],
    ratings: { "Fleetwood Town": { Points: 1352.77 }, Arsenal: { Points: 2015 } },
  });
  assert.equal(rate(match, 60).score, 62);
  assert.equal(rate({ ...match, home_team: "Arsenal", away_team: "Fleetwood Town" }, 60).score, 62);
  assert.equal(rate({ ...match, tv_channels: [] }, 60), null);
});

test("server keeps absent ratings unknown and missing membership does not award cup appeal", () => {
  const result = adapter()(match, 60);
  assert.equal(result.components.some(c => c.key === "premier_league_cup_draw"), false);
  assert.equal(result.components.find(c => c.key === "team_quality").score, 45);
  assert.equal(result.components.find(c => c.key === "competitive_balance").score, 55);
  assert.equal(result.confidence, 0.74);
});
