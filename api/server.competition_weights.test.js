const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");

const {
  app,
  __private: {
    buildCompetitionCatalog,
    buildCompetitionWeightsPayload,
    buildFixtureCalendar,
  },
} = require("./server");

test("competition weights payload mirrors the competition catalog name and weight pairs", () => {
  assert.deepEqual(
    buildCompetitionWeightsPayload(),
    buildCompetitionCatalog().map(({ name, weight }) => ({ name, weight }))
  );
});

test("competition catalog exposes canonical ids, aliases and logo metadata", () => {
  const catalog = buildCompetitionCatalog();
  const laLiga = catalog.find((entry) => entry.name === "La Liga");

  assert.ok(laLiga);
  assert.equal(laLiga.id, "la-liga");
  assert.equal(laLiga.region, "spain");
  assert.ok(laLiga.aliases.includes("Spanish La Liga"));
  assert.match(laLiga.logo_url, /^https:\/\//);
  assert.equal(catalog.filter((entry) => entry.name === "La Liga").length, 1);
  assert.ok(catalog.some((entry) => entry.name === "Ligue 1"));
  assert.ok(catalog.some((entry) => entry.name === "EFL League One" && entry.region === "england"));
  assert.ok(catalog.some((entry) => entry.name === "EFL League Two" && entry.region === "england"));
  assert.ok(catalog.every((entry) => /^https:\/\//.test(entry.logo_url)));
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
