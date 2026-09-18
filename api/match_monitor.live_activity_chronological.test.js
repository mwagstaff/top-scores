const test = require("node:test");
const assert = require("node:assert/strict");
const { __testHooks } = require("./match_monitor");

const fixtures = [
  ["brentford", "20:00", "Premier League", "Brentford", "Chelsea", 3600],
  ["worcester", "19:45", "Southern Premier League Central", "Worcester", "Stratford", 2000],
  ["yate", "19:45", "Southern Premier League South", "Yate", "Chippenham", 2100],
  ["espanyol", "20:00", "La Liga", "Espanyol", "Elche", 3100],
  ["bayern", "19:30", "Bundesliga", "Bayern", "Union Berlin", 3900],
  ["monza", "19:45", "Serie A", "Monza", "Sassuolo", 3000],
  ["arsenal", "20:15", "Premier League", "Arsenal", "Liverpool", 4100],
].map(([match_details_id, time, league, home_team, away_team, total_team_score]) => ({
  match_details_id, date: "2026-09-18", time, league, home_team, away_team,
  total_team_score, home_score: null, away_score: null, score_status: null,
}));

test("Live Activity orders the screenshot fixtures globally by kickoff before applying its six-match cap", () => {
  for (const matchGroupSortOrder of ["kickoffThenTeamScore", "kickoffThenAlphabetical"]) {
    for (const premierLeagueMatchesFirst of [true, false]) {
      const presentation = __testHooks.buildLiveActivityPresentationForUser(
        { preferences: { liveActivityDelayMinutes: 0, matchGroupSortOrder, premierLeagueMatchesFirst } },
        fixtures.map((match) => ({ match, state: null })),
        Date.parse("2026-09-18T11:00:00Z")
      );
      assert.equal(presentation.mode, "multi_upcoming");
      assert.deepEqual(presentation.matches.map((match) => match.time),
        ["19:30", "19:45", "19:45", "19:45", "20:00", "20:00"]);
      assert.equal(presentation.matches[0].match_details_id, "bayern");
      assert.ok(!presentation.matches.some((match) => match.match_details_id === "arsenal"));
      const content = __testHooks.buildLiveActivityContentState(
        presentation.mode, presentation.matches, presentation.delayMinutes,
        Date.parse("2026-09-18T11:00:00Z")
      );
      assert.deepEqual(content.matches.map((match) => match.time),
        ["19:30", "19:45", "19:45", "19:45", "20:00", "20:00"]);
    }
  }
});

test("Live Activity kickoff ordering also applies across competitions to live and finished matches", () => {
  for (const score_status of ["10", "FT"]) {
    const sorted = fixtures.map((match) => ({ ...match, score_status }))
      .sort(__testHooks.compareLiveActivityMatches);
    assert.deepEqual(sorted.map((match) => match.time),
      ["19:30", "19:45", "19:45", "19:45", "20:00", "20:00", "20:15"]);
  }
});

test("Same-kickoff matches use team rating across competition boundaries", () => {
  const prefs = { premierLeagueMatchesFirst: false };
  const sameKickoff = fixtures.filter((match) => match.time === "19:45");
  assert.deepEqual(__testHooks.sortUpcomingMatchesForLiveActivity(sameKickoff, prefs)
    .map((match) => match.match_details_id), ["monza", "yate", "worcester"]);
  assert.deepEqual(sameKickoff.slice().sort((lhs, rhs) =>
    __testHooks.compareLiveActivityMatches(lhs, rhs, prefs))
    .map((match) => match.match_details_id), ["monza", "yate", "worcester"]);

  const lowerWeightHigherRating = [
    { ...fixtures[0], total_team_score: 3000 },
    { ...fixtures[3], total_team_score: 3500 },
  ];
  assert.deepEqual(__testHooks.sortUpcomingMatchesForLiveActivity(lowerWeightHigherRating, prefs)
    .map((match) => match.match_details_id), ["espanyol", "brentford"]);
  assert.deepEqual(lowerWeightHigherRating.slice().sort((lhs, rhs) =>
    __testHooks.compareLiveActivityMatches(lhs, rhs, prefs))
    .map((match) => match.match_details_id), ["espanyol", "brentford"]);
});
