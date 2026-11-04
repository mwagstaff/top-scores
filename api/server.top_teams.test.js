const test = require("node:test");
const assert = require("node:assert/strict");
const { DEFAULT_TOP_TEAMS_CONFIG: config } = require("./config");
const { __private: {
  clubEloRowMeetsTopTeamsThreshold: qualifies,
  buildFixtureViewFilterContext,
  matchPassesFixtureViewOptions,
} } = require("./server");

test("the lower threshold belongs to exactly the 24 approved clubs", () => {
  assert.deepEqual(config.established_major_clubs.map((team) => team.name).sort(), [
    "Real Madrid", "Barcelona", "Atletico Madrid", "Juventus", "Inter Milan",
    "AC Milan", "Napoli", "Lazio", "Roma", "Bayern Munich", "Borussia Dortmund",
    "VfB Stuttgart", "Bayer Leverkusen", "Eintracht Frankfurt", "Paris Saint-Germain",
    "Marseille", "Lyon", "Monaco", "Benfica", "Porto", "Sporting CP", "Ajax", "PSV", "Feyenoord",
  ].sort());
  assert.equal(new Set(config.established_major_clubs.map((team) => team.opta_id)).size, 24);
  for (const team of config.established_major_clubs) {
    assert.ok(team.opta_id);
    assert.equal(qualifies({ Name: team.name, OptaId: team.opta_id, Elo: 1750 }), true, team.name);
    assert.equal(qualifies({ Name: team.name, OptaId: team.opta_id, Elo: 1749.99 }), false, team.name);
    assert.equal(qualifies({ Name: team.name, OptaId: "unrelated-club", Elo: 1799.99 }), false, team.name);
    for (const name of [team.name, ...team.aliases]) {
      assert.equal(qualifies({ Club: name, Elo: 1750 }), true, name);
    }
  }
});

test("other clubs need 1800 and missing ratings never qualify", () => {
  for (const Name of [
    "Stade Rennais", "Olympiacos FC", "Viking FK", "Freiburg", "RB Leipzig",
    "Athletic Bilbao", "Valencia", "Sevilla", "Real Betis", "Real Sociedad",
    "Villarreal", "Fiorentina", "Bologna", "Torino", "Borussia Mönchengladbach",
    "Werder Bremen", "Hamburg", "Schalke", "Saint-Étienne", "Lens", "Anderlecht",
    "Club Brugge", "Galatasaray", "Fenerbahçe", "Beşiktaş", "Panathinaikos",
    "AEK Athens", "Sparta Prague", "Slavia Prague", "Red Star Belgrade", "Partizan",
    "Dinamo Zagreb", "Hajduk Split", "Dynamo Kyiv", "Shakhtar Donetsk", "FCSB",
    "Rosenborg", "Copenhagen", "Basel", "Rapid Vienna",
  ]) {
    assert.equal(qualifies({ Name, Elo: 1799.99 }), false, Name);
    assert.equal(qualifies({ Name, Elo: 1800 }), true, Name);
  }
  for (const row of [null, {}, { Name: "Lazio" }, { Name: "Lazio", Elo: null }, { Name: "Lazio", Elo: "invalid" }]) {
    assert.equal(qualifies(row), false);
  }
});

test("shared fixture and notification preset excludes Rennes-Olympiacos but preserves approved clubs and exemptions", () => {
  const ratings = [
    ["Stade Rennais", 1756, "FRANCE"], ["Olympiacos FC", 1757.17, "GREECE"],
    ["VfB Stuttgart", 1780.60, "GERMANY"], ["Lazio", 1790.86, "ITALY"],
    ["AC Milan", 1782.06, "ITALY"], ["Napoli", 1787.44, "ITALY"],
    ["Ajax", 1726.68, "NETHERLANDS"], ["Feyenoord", 1748.40, "NETHERLANDS"],
    ["Celtic", 1600, "SCO"], ["Club Brugge", 1848.53, "BELGIUM"],
  ];
  const context = buildFixtureViewFilterContext({
    premierLeagueTeams: ["Arsenal"],
    clubEloTeams: ratings.map(([Name, Elo, Country]) => ({ Name, Club: Name, Elo, Country })),
    manualMappings: new Map(),
    teamCatalogSnapshot: { teams: [], byID: new Map() },
  });
  const passes = (home_team, away_team, league = "UEFA Europa League", league_subcategory = null) =>
    matchPassesFixtureViewOptions({ home_team, away_team, league, league_subcategory }, ["preset:top-teams"], context);
  assert.equal(passes("Stade Rennais", "Olympiacos FC"), false);
  for (const club of ["VfB Stuttgart", "Lazio", "AC Milan", "Napoli", "Club Brugge", "Celtic"]) {
    assert.equal(passes(club, "Stade Rennais"), true, club);
    assert.equal(passes("Stade Rennais", club), true, club);
  }
  assert.equal(passes("Ajax", "Feyenoord"), false);
  assert.equal(passes("Viking FK", "Sabah FK", "UEFA Champions League", "League Phase"), true);
  assert.equal(passes("Viking FK", "Sabah FK", "UEFA Champions League", "Third qualifying round"), false);
  assert.equal(passes("Lazio", "Viking FK", "UEFA Champions League", "Third qualifying round"), true);
  assert.equal(passes("Arsenal", "Olympiacos FC", "Club Friendlies"), true);
  assert.equal(passes("Real Madrid", "Stade Rennais", "Club Friendlies"), true);
  assert.equal(passes("England", "France", "International Friendly"), true);
  assert.equal(passes("Lazio", "Napoli", "Serie A"), false);
});
