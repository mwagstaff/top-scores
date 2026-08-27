"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const manualMappingsConfig = require("./club_elo_manual_mappings.json");
const { __private } = require("./server");

test("FK Arsenal Tivat is explicitly excluded from matching Arsenal's Club Elo row", () => {
  const manualMappings = new Map(
    Object.entries(manualMappingsConfig).map(([sourceName, targetClub]) => [
      __private.normalizeTeamName(sourceName).replace(/\s+/g, " ").trim(),
      targetClub,
    ])
  );
  const arsenal = {
    Rank: 1,
    Club: "Arsenal",
    Country: "ENG",
    Elo: 2056,
  };

  const result = __private.findBestClubEloMatch(
    "FK Arsenal Tivat",
    [arsenal],
    null,
    manualMappings
  );

  assert.deepEqual(result, {
    team: null,
    confidence: 1,
    method: "manual_unmatched",
    accepted: false,
  });
});

test("Comoros is treated as a national team without blocking the Como club match", () => {
  const como = {
    Rank: 67,
    Club: "Como",
    Country: "ITA",
    Elo: 1752.68,
  };
  const comoros = {
    Rank: 110,
    Team: "Comoros",
    Country: "Comoros",
    Elo: 1374,
  };

  const comoClubResult = __private.findBestClubEloMatch("Como", [como], null, new Map());
  const comorosClubResult = __private.findBestClubEloMatch(
    "Comoros",
    [como],
    null,
    new Map()
  );
  const comorosNationalResult = __private.findBestNationalEloMatch("Comoros", [comoros]);

  assert.equal(comoClubResult.accepted, true);
  assert.equal(comoClubResult.team, como);
  assert.deepEqual(comorosClubResult, {
    team: null,
    confidence: 0,
    method: "excluded_national_team",
    accepted: false,
  });
  assert.equal(comorosNationalResult.accepted, true);
  assert.equal(comorosNationalResult.team, comoros);
});

test("top teams identity keys collapse the Paris Saint-Germain Club Elo alias", () => {
  const manualMappings = new Map([
    ["paris saint germain", "Paris SG"],
  ]);

  assert.equal(
    __private.topTeamsIdentityKey("Paris Saint-Germain", manualMappings),
    __private.topTeamsIdentityKey("Paris SG", manualMappings)
  );
  assert.equal(
    __private.normalizeTeamName("Paris SG"),
    __private.normalizeTeamName("Paris Saint-Germain")
  );
  assert.notEqual(
    __private.topTeamsIdentityKey("Arsenal", manualMappings),
    __private.topTeamsIdentityKey("FK Arsenal Tivat", manualMappings)
  );
});
