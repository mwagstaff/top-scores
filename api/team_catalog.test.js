"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  buildTeamCatalog,
  buildTeamCatalogIndex,
  filterTeamCatalog,
} = require("./team_catalog");

const competitions = [
  {
    id: "championship",
    name: "Championship",
    aliases: ["English League Championship"],
  },
  { id: "fa-cup", name: "FA Cup", aliases: ["English FA Cup"] },
  { id: "premier-league", name: "Premier League", aliases: [] },
  { id: "league-one", name: "EFL League One", aliases: ["League One"] },
];

const matches = [
  {
    league: "Championship",
    home_team: "Watford",
    away_team: "Norwich City",
    home_team_id: "500",
    away_team_id: "501",
  },
  {
    league: "English FA Cup",
    home_team: "Norwich",
    away_team: "Arsenal",
    home_team_id: "501",
    away_team_id: "1",
  },
  {
    league: "FA Cup",
    home_team: "W101",
    away_team: "TBC",
  },
];

test("buildTeamCatalog groups canonical aliases and competition memberships", () => {
  const teams = buildTeamCatalog(matches, competitions);
  const watford = teams.find((team) => team.id === "watford");
  const norwich = teams.find((team) => team.id === "norwich-city");

  assert.ok(watford);
  assert.deepEqual(watford.competition_ids, ["championship"]);
  assert.ok(norwich);
  assert.deepEqual(norwich.competition_ids, ["championship", "fa-cup"]);
  assert.ok(norwich.aliases.includes("Norwich"));
  assert.equal(teams.some((team) => team.name === "TBC" || team.name === "W101"), false);
});

test("filterTeamCatalog browses by competition and ranks search matches", () => {
  const teams = buildTeamCatalog(matches, competitions);
  const championship = filterTeamCatalog(teams, { competitionID: "championship" });
  const search = filterTeamCatalog(teams, { query: "nor" });

  assert.deepEqual(championship.map((team) => team.name), ["Norwich City", "Watford"]);
  assert.equal(search[0].id, "norwich-city");
});

test("team catalogue index resolves alias slugs", () => {
  const teams = buildTeamCatalog(matches, competitions);
  const index = buildTeamCatalogIndex(teams);

  assert.equal(index.get("norwich").id, "norwich-city");
  assert.deepEqual(
    filterTeamCatalog(teams, { ids: ["norwich"] }).map((team) => team.id),
    ["norwich-city"]
  );
});

test("buildTeamCatalog keeps only the latest domestic league membership", () => {
  const historicalAndCurrentMatches = [
    {
      date: "2017-05-07",
      league: "Championship",
      home_team: "Newcastle United",
      away_team: "Brighton & Hove Albion",
    },
    {
      date: "2026-08-22",
      league: "Premier League",
      home_team: "Newcastle United",
      away_team: "Arsenal",
      score_status: "POSTPONED",
    },
    {
      date: "2026-05-02",
      league: "Championship",
      home_team: "Plymouth Argyle",
      away_team: "Norwich City",
    },
    {
      date: "2026-08-22",
      league: "EFL League One",
      home_team: "Plymouth Argyle",
      away_team: "Mansfield Town",
    },
    {
      date: "2010-12-26",
      league: "Premier League",
      home_team: "Birmingham City",
      away_team: "Everton",
      score_status: "POSTPONED",
    },
    {
      date: "2026-08-22",
      league: "Championship",
      home_team: "Birmingham City",
      away_team: "Blackburn Rovers",
    },
    {
      date: "2009-01-10",
      league: "Premier League",
      home_team: "Blackburn Rovers",
      away_team: "Fulham",
      score_status: "POSTPONED",
    },
    {
      date: "2011-04-10",
      league: "Premier League",
      home_team: "Blackpool",
      away_team: "Arsenal",
      score_status: "POSTPONED",
    },
    {
      date: "2026-08-22",
      league: "EFL League One",
      home_team: "Blackpool",
      away_team: "Reading",
    },
  ];

  const teams = buildTeamCatalog(historicalAndCurrentMatches, competitions, {
    authoritativeCompetitionTeams: {
      "premier-league": ["Newcastle United"],
    },
  });
  const newcastle = teams.find((team) => team.id === "newcastle-united");
  const plymouth = teams.find((team) => team.id === "plymouth-argyle");
  const birmingham = teams.find((team) => team.id === "birmingham-city");
  const blackburn = teams.find((team) => team.id === "blackburn-rovers");
  const blackpool = teams.find((team) => team.id === "blackpool");

  assert.deepEqual(newcastle.competition_ids, ["premier-league"]);
  assert.deepEqual(plymouth.competition_ids, ["league-one"]);
  assert.deepEqual(birmingham.competition_ids, ["championship"]);
  assert.deepEqual(blackburn.competition_ids, ["championship"]);
  assert.deepEqual(blackpool.competition_ids, ["league-one"]);
  assert.equal(
    filterTeamCatalog(teams, { competitionID: "championship" })
      .some((team) => team.id === "newcastle-united" || team.id === "plymouth-argyle"),
    false
  );
});
