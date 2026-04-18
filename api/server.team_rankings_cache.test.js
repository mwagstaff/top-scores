const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    buildTeamRankingsUniverseSignature,
    buildTeamRankingsResponseCacheKey,
  },
} = require("./server");

function buildDataset(items, updatedAt) {
  return {
    items,
    updated_at: updatedAt,
    source: "test",
  };
}

test("team rankings universe signature ignores match timestamp churn", () => {
  const matchesA = [
    {
      league: "Premier League",
      home_team: "Arsenal",
      away_team: "Chelsea",
      date: "2026-04-18",
      time: "15:00",
    },
    {
      league: "Premier League",
      home_team: "Liverpool",
      away_team: "Everton",
      date: "2026-04-18",
      time: "17:30",
    },
  ];
  const matchesB = [
    {
      league: "Premier League",
      home_team: "Arsenal",
      away_team: "Chelsea",
      date: "2026-04-18",
      time: "15:00",
      home_score: 1,
      away_score: 0,
    },
    {
      league: "Premier League",
      home_team: "Liverpool",
      away_team: "Everton",
      date: "2026-04-18",
      time: "17:30",
      match_time: "12'",
    },
  ];

  assert.deepEqual(
    buildTeamRankingsUniverseSignature(matchesA, null),
    buildTeamRankingsUniverseSignature(matchesB, null)
  );
});

test("team rankings cache key stays stable when only merged timestamps change", () => {
  const mergedA = buildDataset(
    [
      { league: "Premier League", home_team: "Arsenal", away_team: "Chelsea" },
      { league: "Premier League", home_team: "Liverpool", away_team: "Everton" },
    ],
    "2026-04-18T00:00:00.000Z"
  );
  const mergedB = buildDataset(
    [
      { league: "Premier League", home_team: "Arsenal", away_team: "Chelsea", home_score: 1 },
      { league: "Premier League", home_team: "Liverpool", away_team: "Everton", match_time: "20'" },
    ],
    "2026-04-18T00:00:30.000Z"
  );
  const teamDataset = buildDataset([{ Club: "Arsenal", Rank: 1, Elo: 2000 }], "2026-04-18T00:00:00.000Z");

  const keyA = buildTeamRankingsResponseCacheKey({
    source: "merged",
    type: "club",
    leagueFilter: null,
    mergedDataset: mergedA,
    clubEloDataset: teamDataset,
    footballDatabaseDataset: teamDataset,
    nationalEloDataset: teamDataset,
  });
  const keyB = buildTeamRankingsResponseCacheKey({
    source: "merged",
    type: "club",
    leagueFilter: null,
    mergedDataset: mergedB,
    clubEloDataset: teamDataset,
    footballDatabaseDataset: teamDataset,
    nationalEloDataset: teamDataset,
  });

  assert.equal(keyA, keyB);
});

test("team rankings cache key changes when league-specific team universe changes", () => {
  const mergedA = buildDataset(
    [
      { league: "Premier League", home_team: "Arsenal", away_team: "Chelsea" },
      { league: "Championship", home_team: "Leeds United", away_team: "Southampton" },
    ],
    "2026-04-18T00:00:00.000Z"
  );
  const mergedB = buildDataset(
    [
      { league: "Premier League", home_team: "Arsenal", away_team: "Chelsea" },
      { league: "Premier League", home_team: "Liverpool", away_team: "Everton" },
      { league: "Championship", home_team: "Leeds United", away_team: "Southampton" },
    ],
    "2026-04-18T00:00:30.000Z"
  );
  const teamDataset = buildDataset([{ Club: "Arsenal", Rank: 1, Elo: 2000 }], "2026-04-18T00:00:00.000Z");

  const keyA = buildTeamRankingsResponseCacheKey({
    source: "merged",
    type: "club",
    leagueFilter: "Premier League",
    mergedDataset: mergedA,
    clubEloDataset: teamDataset,
    footballDatabaseDataset: teamDataset,
    nationalEloDataset: teamDataset,
  });
  const keyB = buildTeamRankingsResponseCacheKey({
    source: "merged",
    type: "club",
    leagueFilter: "Premier League",
    mergedDataset: mergedB,
    clubEloDataset: teamDataset,
    footballDatabaseDataset: teamDataset,
    nationalEloDataset: teamDataset,
  });

  assert.notEqual(keyA, keyB);
});
