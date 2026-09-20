const test = require("node:test");
const assert = require("node:assert/strict");
const { __testHooks } = require("./match_monitor");

test("Live Activity uses Scores club ratings and Premier League priority before the six-match cap", async () => {
  const originalFetch = global.fetch;
  const requestedPaths = [];
  const ratings = [
    ["Levski Sofia", 1517], ["RB Salzburg", 1518],
    ["OFI", 1342], ["Hoffenheim", 1736],
    ["Crystal Palace", 1755], ["Lech", 1500],
    ["Real Sociedad", 1700], ["Bournemouth", 1789],
    ["Beşiktaş", 1600], ["Marseille", 1750],
    ["Celtic", 1550], ["Ferencváros", 1500],
    ["Viktoria Plzeň", 1550], ["Union Saint-Gilloise", 1700],
    ["Juventus", 1799], ["NEC", 1550],
  ].map(([Name, Points]) => ({ Name, Points, Type: "club", aliases: [] }));

  global.fetch = async (url) => {
    const { pathname, search } = new URL(url);
    requestedPaths.push(pathname + search);
    return {
      ok: true,
      json: async () => pathname.endsWith("/config") ? { default_elo: 1000 } : ratings,
    };
  };
  try {
    await __testHooks.ensureLiveActivityTeamRatingCache();
  } finally {
    global.fetch = originalFetch;
  }
  assert.deepEqual(requestedPaths, ["/api/v1/teams/config", "/api/v1/teams?type=club"]);

  const entries = [
    ["sociedad", "20:00", "Real Sociedad", "Bournemouth"],
    ["juventus", "20:00", "Juventus", "NEC"],
    ["plzen", "20:00", "Viktoria Plzeň", "Union Saint-Gilloise"],
    ["besiktas", "20:00", "Beşiktaş", "Marseille"],
    ["celtic", "20:00", "Celtic", "Ferencváros"],
    ["palace", "20:00", "Crystal Palace", "Lech"],
    ["ofi", "17:45", "OFI", "Hoffenheim"],
    ["levski", "17:45", "Levski Sofia", "RB Salzburg"],
  ].map(([match_details_id, time, home_team, away_team]) => ({
    state: null,
    match: { match_details_id, date: "2026-09-17", time, home_team, away_team,
      league: "UEFA Europa League", home_score: null, away_score: null, score_status: null },
  }));
  const nowMs = Date.parse("2026-09-17T15:00:00Z");
  const present = (preferences) => __testHooks.buildLiveActivityPresentationForUser(
    { preferences: { liveActivityDelayMinutes: 0, matchGroupSortOrder: "kickoffThenTeamScore", ...preferences } },
    entries,
    nowMs
  ).matches.map((match) => match.match_details_id);

  // Legacy clients omit the setting; Scores defaults it to enabled.
  assert.deepEqual(present({}), ["ofi", "levski", "sociedad", "palace", "besiktas", "juventus"]);
  assert.deepEqual(present({ premierLeagueMatchesFirst: true }), present({}));
  assert.deepEqual(present({ premierLeagueMatchesFirst: false }),
    ["ofi", "levski", "sociedad", "besiktas", "juventus", "palace"]);

  const finishedEntries = entries.map((entry) => ({
    state: { finishedAtMs: nowMs - 60_000 },
    match: {
      ...entry.match,
      home_score: 2,
      away_score: 1,
      score_status: "FT",
    },
  }));
  const finishedPresentation = __testHooks.buildLiveActivityPresentationForUser(
    { preferences: { liveActivityDelayMinutes: 0, premierLeagueMatchesFirst: true } },
    finishedEntries,
    nowMs
  );
  assert.equal(finishedPresentation.mode, "multi_finished");
  assert.deepEqual(
    finishedPresentation.matches.map((match) => match.match_details_id),
    ["sociedad", "besiktas", "juventus", "palace", "plzen", "ofi"]
  );

  // Two Premier League fixtures are still ordered by their combined rating.
  const palace = entries.find((entry) => entry.match.match_details_id === "palace").match;
  const sociedad = entries.find((entry) => entry.match.match_details_id === "sociedad").match;
  const ratedPalace = { ...palace, total_team_score: 3600, score_status: "10" };
  const ratedSociedad = { ...sociedad, total_team_score: 3489, score_status: "10" };
  assert.deepEqual(__testHooks.sortUpcomingMatchesForLiveActivity([ratedSociedad, ratedPalace])
    .map((match) => match.match_details_id), ["palace", "sociedad"]);
  assert.ok(__testHooks.compareLiveActivityMatches(ratedPalace, ratedSociedad) < 0);

  const ratedBesiktas = { ...entries.find((entry) => entry.match.match_details_id === "besiktas").match,
    total_team_score: 4000, score_status: "10" };
  assert.ok(__testHooks.compareLiveActivityMatches(ratedPalace, ratedBesiktas) < 0);
  assert.ok(__testHooks.compareLiveActivityMatches(ratedPalace, ratedBesiktas,
    { premierLeagueMatchesFirst: false }) > 0);
  assert.ok(__testHooks.compareLiveActivityMatches({ ...ratedBesiktas, time: "17:45" }, ratedPalace) < 0);
  assert.ok(__testHooks.compareLiveActivityMatches(ratedBesiktas,
    { ...ratedPalace, time: "17:45", score_status: "FT" }) < 0);
});
