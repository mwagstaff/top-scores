"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { bsdEventToCanonicalMatch } = require("./bsd_adapter");
const { bsdTeamLogoAsset } = require("./bsd_team_logo_assets");
const { buildOptaIndex, findOptaMatch } = require("./opta_matching");
const { OPTA_SOURCE } = require("./fetch_opta_rankings");
const { calculateWatchability } = require("./watchability");

// Both clubs exist in BSD and Opta. Shared aliases must not merge them.
const realBetis = { Source: OPTA_SOURCE, Club: "Real Betis", OptaId: "ah8dala7suqqkj04n2l8xz4zd", OptaAliases: ["Betis"], Elo: 1785.61 };
const regionalBetis = { Source: OPTA_SOURCE, Club: "Betis CF", OptaId: "98ao4ndujvbj3upqimcgpy7ai", OptaAliases: ["Betis"], Elo: 1007.28 };
const index = buildOptaIndex([realBetis, regionalBetis]);

function fixture(awayID, awayName) {
  return bsdEventToCanonicalMatch({
    id: 601070, league_id: 7, home_team_id: 92, away_team_id: awayID,
    home_team: "Borussia Dortmund", away_team: awayName,
    event_date: "2026-11-04T20:00:00Z", status: "notstarted",
  });
}

test("Dortmund's BSD opponent resolves to Real Betis and retains its crest and four-star rating", () => {
  const match = fixture(56, "Real Betis");
  assert.equal(match.away_team, "Real Betis");
  assert.equal(match.away_team_id, "56");
  const opponent = findOptaMatch(match.away_team, index);
  assert.equal(opponent.team.OptaId, realBetis.OptaId);
  assert.equal(bsdTeamLogoAsset(match.away_team_id), "Betis");
  const rating = calculateWatchability({
    competitionName: match.league, competitionWeight: 90,
    homeElo: 1854.76, awayElo: opponent.team.Elo,
  });
  assert.equal(rating.stars, 4);
  assert.ok(rating.components.find(c => c.key === "competitive_balance").score > 80);
});

test("the separate regional Betis club retains its own BSD identity, strength and crest", () => {
  const match = fixture(1527, "Betis C.F.");
  assert.equal(match.away_team, "Betis C.F.");
  assert.equal(findOptaMatch(match.away_team, index).team.OptaId, regionalBetis.OptaId);
  assert.equal(bsdTeamLogoAsset(match.away_team_id), "Betis C.F.");
  assert.equal(findOptaMatch("Betis", index).accepted, false);
});
