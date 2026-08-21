const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");

const {
  app,
  __private: {
    buildCompetitionCatalog,
    buildCompetitionWeightsPayload,
    buildFixtureCalendar,
    clubEloRowIsTopTeam,
    matchPassesFixtureViewOptions,
    normalizeCompetitionFilterName,
  },
} = require("./server");

test("competition weights payload mirrors the competition catalog name and weight pairs", () => {
  assert.deepEqual(
    buildCompetitionWeightsPayload(),
    buildCompetitionCatalog().map(({ name, weight }) => ({ name, weight }))
  );
});

test("competition catalog exposes canonical ids and aliases", () => {
  const catalog = buildCompetitionCatalog();
  const laLiga = catalog.find((entry) => entry.name === "La Liga");

  assert.ok(laLiga);
  assert.equal(laLiga.id, "la-liga");
  assert.equal(laLiga.region, "spain");
  assert.ok(laLiga.aliases.includes("Spanish La Liga"));
  assert.equal(laLiga.logo_url, null);
  assert.equal(catalog.filter((entry) => entry.name === "La Liga").length, 1);
  assert.ok(catalog.some((entry) => entry.name === "Ligue 1"));
  assert.ok(catalog.some((entry) => entry.name === "EFL League One" && entry.region === "england"));
  assert.ok(catalog.some((entry) => entry.name === "EFL League Two" && entry.region === "england"));
  assert.ok(catalog.some((entry) => entry.id === "german-super-cup" && entry.region === "germany"));
  assert.ok(catalog.every((entry) => entry.logo_url === null));
  assert.equal(normalizeCompetitionFilterName("DFL-Supercup"), "german super cup");
});

test("fixture calendar groups canonical competitions and top-match availability", () => {
  const days = buildFixtureCalendar(
    [
      {
        date: "2026-08-16",
        time: "15:00",
        league: "Spanish La Liga",
        home_team: "Barcelona",
        away_team: "Valencia",
      },
      {
        date: "2026-08-16",
        time: "16:30",
        league: "Premier League",
        home_team: "Arsenal",
        away_team: "Chelsea",
      },
    ],
    { premierLeagueTeams: ["Arsenal", "Chelsea"] }
  );

  assert.equal(days.length, 1);
  assert.equal(days[0].match_count, 2);
  assert.equal(days[0].top_match_count, 1);
  assert.deepEqual(
    days[0].competitions.map((entry) => entry.id),
    ["la-liga", "premier-league"]
  );
});

test("fixture calendar excludes postponed-only dates unless requested", () => {
  const matches = [
    {
      date: "2026-02-07",
      time: "15:00",
      league: "La Liga",
      home_team: "Rayo Vallecano",
      away_team: "Real Oviedo",
      score_status: "POSTPONED",
    },
    {
      date: "2026-02-08",
      time: "16:30",
      league: "Premier League",
      home_team: "Arsenal",
      away_team: "Chelsea",
      score_status: "FT",
    },
  ];

  const hidden = buildFixtureCalendar(matches, {
    premierLeagueTeams: ["Arsenal", "Chelsea"],
  });
  const included = buildFixtureCalendar(matches, {
    premierLeagueTeams: ["Arsenal", "Chelsea"],
    includePostponed: true,
  });

  assert.deepEqual(hidden.map((day) => day.date), ["2026-02-08"]);
  assert.deepEqual(included.map((day) => day.date), ["2026-02-07", "2026-02-08"]);
});

test("fixture-view filters support competitions, teams and exact rivalry pairings", () => {
  const clasico = {
    league: "Spanish La Liga",
    home_team: "FC Barcelona",
    away_team: "Real Madrid",
  };
  const madridLeagueMatch = {
    league: "Spanish La Liga",
    home_team: "Real Madrid",
    away_team: "Valencia",
  };

  assert.equal(matchPassesFixtureViewOptions(clasico, ["rivalry:el-clasico"]), true);
  assert.equal(matchPassesFixtureViewOptions(madridLeagueMatch, ["rivalry:el-clasico"]), false);
  assert.equal(matchPassesFixtureViewOptions(madridLeagueMatch, ["team:real-madrid"]), true);
  assert.equal(matchPassesFixtureViewOptions(clasico, ["competition:la-liga"]), true);
  assert.equal(matchPassesFixtureViewOptions(clasico, ["competition:premier-league"]), false);

  const klassiker = {
    league: "German Super Cup",
    home_team: "Borussia Dortmund",
    away_team: "Bayern Munich",
  };
  assert.equal(matchPassesFixtureViewOptions(klassiker, ["rivalry:der-klassiker"]), true);
});

test("fixture-view filters support arbitrary catalogue teams outside their competition", () => {
  const context = {
    teamCatalogByID: new Map([
      [
        "norwich-city",
        {
          id: "norwich-city",
          name: "Norwich City",
          aliases: ["Norwich"],
          source_team_ids: ["501"],
        },
      ],
    ]),
  };
  const watfordCupMatch = {
    league: "FA Cup",
    home_team: "Watford",
    away_team: "Arsenal",
  };
  const norwichCupMatch = {
    league: "FA Cup",
    home_team: "Norwich",
    home_team_id: "501",
    away_team: "Chelsea",
  };
  const unrelatedChampionshipMatch = {
    league: "Championship",
    home_team: "Coventry City",
    away_team: "Stoke City",
  };

  assert.equal(matchPassesFixtureViewOptions(watfordCupMatch, ["team:watford"]), true);
  assert.equal(
    matchPassesFixtureViewOptions(norwichCupMatch, ["team:norwich-city"], context),
    true
  );
  assert.equal(
    matchPassesFixtureViewOptions(unrelatedChampionshipMatch, ["team:watford"]),
    false
  );
});

test("top UEFA teams uses club ranking and excludes international UEFA matches", () => {
  const context = {
    isTopClub: (team) => team === "Arsenal",
  };
  const championsLeague = {
    league: "UEFA Champions League",
    home_team: "Arsenal",
    away_team: "Inter",
  };
  const nationsLeague = {
    league: "UEFA Nations League",
    home_team: "England",
    away_team: "Italy",
  };

  assert.equal(matchPassesFixtureViewOptions(championsLeague, ["rule:top-uefa-clubs"], context), true);
  assert.equal(matchPassesFixtureViewOptions(nationsLeague, ["rule:top-uefa-clubs"], context), false);
  assert.equal(clubEloRowIsTopTeam({ Rank: 40, Elo: 1650 }), true);
  assert.equal(clubEloRowIsTopTeam({ Rank: 41, Elo: 1800 }), false);
  assert.equal(clubEloRowIsTopTeam({ Elo: 1700 }), true);
});

test("UEFA team rules constrain selected club competitions without hiding the Premier League", () => {
  const context = {
    isPremierLeagueTeam: (team) => team === "Arsenal" || team === "Aston Villa",
  };
  const preset = [
    "competition:premier-league",
    "competition:uefa-champions-league",
    "competition:uefa-europa-league",
    "competition:uefa-conference-league",
    "competition:uefa-super-cup",
    "rule:premier-league-teams",
  ];
  const arsenalInEurope = {
    league: "UEFA Champions League",
    home_team: "Arsenal",
    away_team: "Paris Saint-Germain",
  };
  const nonPremierLeagueEuropeanFixture = {
    league: "UEFA Champions League",
    home_team: "Real Madrid",
    away_team: "Paris Saint-Germain",
  };
  const premierLeagueFixture = {
    league: "Premier League",
    home_team: "Arsenal",
    away_team: "Chelsea",
  };
  const unselectedEuropeanCompetition = {
    league: "UEFA Europa League",
    home_team: "Arsenal",
    away_team: "Roma",
  };
  const astonVillaSuperCup = {
    league: "UEFA Super Cup",
    home_team: "Paris Saint-Germain",
    away_team: "Aston Villa",
  };

  assert.equal(matchPassesFixtureViewOptions(arsenalInEurope, preset, context), true);
  assert.equal(matchPassesFixtureViewOptions(astonVillaSuperCup, preset, context), true);
  assert.equal(matchPassesFixtureViewOptions(nonPremierLeagueEuropeanFixture, preset, context), false);
  assert.equal(matchPassesFixtureViewOptions(premierLeagueFixture, preset, context), true);
  assert.equal(
    matchPassesFixtureViewOptions(
      unselectedEuropeanCompetition,
      ["competition:uefa-champions-league", "rule:premier-league-teams"],
      context
    ),
    false
  );
  assert.equal(
    matchPassesFixtureViewOptions(
      nonPremierLeagueEuropeanFixture,
      ["competition:uefa-champions-league"],
      context
    ),
    true
  );
});

test("GET /api/v1/competitions/weights returns competition names and weights", async () => {
  const server = http.createServer(app);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));

  try {
    const address = server.address();
    const response = await fetch(
      `http://127.0.0.1:${address.port}/api/v1/competitions/weights`
    );

    assert.equal(response.status, 200);
    assert.equal(response.headers.get("x-operational-source"), "server_config");
    assert.deepEqual(await response.json(), buildCompetitionWeightsPayload());
  } finally {
    await new Promise((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve()))
    );
  }
});
