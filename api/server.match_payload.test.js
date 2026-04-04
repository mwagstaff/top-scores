const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    toMatchListPayload,
    toMonitorCandidateFromDetailsPayload,
    mergeMonitorCandidate,
    buildMonitorCandidatesForDate,
    buildFallbackMatchDetailsPayload,
    getMatchDetailsStatePayload,
    mergeConfirmedVarDisallowedGoalsIntoPayload,
    enrichMatchDetailsAggregateImmediately,
    enrichKnockoutAggregatesForListMatches,
    matchDetailsNeedsBackfill,
    markMatchDetailsActive,
    isMatchDetailsActive,
    normalizeMatchDetailsPayload,
    mergeMatchDetailsPayload,
    pickPreferredMatchStatus,
    resolveStableMatchScoreStatus,
    withStableMatchDetailsState,
    filterStaleBbcMatches,
    buildDefaultOperationalCacheState,
    normalizeCacheStateDomains,
    normalizeOperationalCacheState,
    bumpCacheStateSnapshot,
    normalizeMatchStatusValue,
    normalizeTeamName,
    normalizeCompetitionFilterName,
    isAllowedCompetition,
    mergeBbcAndLiveMatches,
    matchIncludesHomeNation,
    matchIsMajorTournament,
    matchPassesCategoryFilters,
  },
} = require("./server");

const DETAILS_ID = "c1e937445p2t";
const DETAILS_URL = `https://www.bbc.co.uk/sport/football/live/${DETAILS_ID}`;

function baseMatch(overrides = {}) {
  return {
    date: "2026-03-03",
    time: "20:15",
    league: "Premier League",
    home_team: "Wolves",
    away_team: "Liverpool",
    home_score: 0,
    away_score: 0,
    score_status: "49",
    details_url: DETAILS_URL,
    tv_channels: [],
    ...overrides,
  };
}

function detailsPayload(overrides = {}) {
  return {
    id: DETAILS_ID,
    date: "2026-03-03",
    time: "20:15",
    league: "Premier League",
    home_team: "Wolverhampton Wanderers",
    away_team: "Liverpool",
    home_score: 2,
    away_score: 1,
    score_status: "FT",
    updated_at: "2026-03-03T22:00:00.000Z",
    ...overrides,
  };
}

function buildCompleteTeamLineups() {
  const buildStarter = (number, name, position_category, formation_row_index, formation_slot_index, formation_row_size) => ({
    number,
    name,
    position_category,
    formation_row_index,
    formation_slot_index,
    formation_row_size,
  });

  return {
    home: {
      team: "Wolverhampton Wanderers",
      manager: "Vitor Pereira",
      formation: "4-3-3",
      starting_lineup: [
        buildStarter(1, "J. Sa", "goalkeeper", 0, 0, 1),
        buildStarter(2, "M. Doherty", "defender", 1, 0, 4),
        buildStarter(4, "S. Bueno", "defender", 1, 1, 4),
        buildStarter(12, "E. Agbadou", "defender", 1, 2, 4),
        buildStarter(24, "Toti Gomes", "defender", 1, 3, 4),
        buildStarter(3, "R. Ait-Nouri", "midfielder", 2, 0, 4),
        buildStarter(7, "André", "midfielder", 2, 1, 4),
        buildStarter(8, "João Gomes", "midfielder", 2, 2, 4),
        buildStarter(5, "M. Munetsi", "midfielder", 2, 3, 4),
        buildStarter(10, "Matheus Cunha", "attacker", 3, 0, 2),
        buildStarter(9, "J. Strand Larsen", "attacker", 3, 1, 2),
      ],
      substitutes: [
        { number: 21, name: "Pablo Sarabia" },
        { number: 11, name: "Hwang Hee-Chan" },
      ],
      substitutions: [
        {
          minute: "72'",
          player_off: { number: 5, name: "M. Munetsi" },
          player_on: { number: 21, name: "Pablo Sarabia" },
        },
      ],
    },
    away: {
      team: "Liverpool",
      manager: "Arne Slot",
      formation: "4-2-3-1",
      starting_lineup: [
        buildStarter(1, "Alisson", "goalkeeper", 0, 0, 1),
        buildStarter(84, "C. Bradley", "defender", 1, 0, 4),
        buildStarter(5, "I. Konaté", "defender", 1, 1, 4),
        buildStarter(4, "V. van Dijk", "defender", 1, 2, 4),
        buildStarter(26, "A. Robertson", "defender", 1, 3, 4),
        buildStarter(38, "R. Gravenberch", "midfielder", 2, 0, 2),
        buildStarter(10, "A. Mac Allister", "midfielder", 2, 1, 2),
        buildStarter(11, "Mohamed Salah", "attacker", 3, 0, 3),
        buildStarter(8, "D. Szoboszlai", "midfielder", 3, 1, 3),
        buildStarter(18, "C. Gakpo", "attacker", 3, 2, 3),
        buildStarter(20, "Diogo Jota", "attacker", 4, 0, 1),
      ],
      substitutes: [
        { number: 7, name: "L. Díaz" },
        { number: 9, name: "D. Núñez" },
      ],
      substitutions: [
        {
          minute: "81'",
          player_off: { number: 18, name: "C. Gakpo" },
          player_on: { number: 7, name: "L. Díaz" },
        },
      ],
    },
  };
}

function buildStartingLineupFromRows(startNumber, rows) {
  let offset = 0;
  return rows.flatMap((row, rowIndex) =>
    Array.from({ length: row.count }, (_, slotIndex) => {
      const index = offset++;
      return {
        number: startNumber + index,
        name: `${row.prefix} Player ${index + 1}`,
        position_category: row.position_category,
        formation_row_index: rowIndex,
        formation_slot_index: slotIndex,
        formation_row_size: row.count,
      };
    })
  );
}

test("toMatchListPayload upgrades status from match details by match id despite team alias mismatch", () => {
  const payload = toMatchListPayload(baseMatch(), {
    matchDetailsLookup: {
      [DETAILS_ID]: detailsPayload(),
    },
  });

  assert.equal(payload.match_details_id, DETAILS_ID);
  assert.equal(payload.score_status, "FT");
});

test("toMatchListPayload preserves explicit BBC-source flag without requiring match_details_id", () => {
  const payload = toMatchListPayload(
    baseMatch({
      details_url: null,
      match_details_id: null,
      has_bbc_source: true,
      home_score: null,
      away_score: null,
      score_status: null,
    })
  );

  assert.equal(payload.has_bbc_source, true);
  assert.equal(payload.match_details_id, undefined);
});

test("normalizeTeamName canonicalizes team aliases from shared identity config", () => {
  assert.equal(normalizeTeamName("Man City"), "manchester city");
  assert.equal(normalizeTeamName("MCI"), "manchester city");
  assert.equal(normalizeTeamName("AFC Bournemouth"), "bournemouth");
});

test("normalizeMatchStatusValue canonicalizes postponed status", () => {
  assert.equal(normalizeMatchStatusValue("Match Postponed"), "POSTPONED");
  assert.equal(normalizeMatchStatusValue("POSTPONED"), "POSTPONED");
});

test("normalizeCompetitionFilterName maps World Cup qualifying competitions to the World Cup family", () => {
  assert.equal(
    normalizeCompetitionFilterName("FIFA World Cup Qualifying - European"),
    "fifa world cup 2026"
  );
  assert.equal(
    normalizeCompetitionFilterName("FIFA World Cup 2026 Qualifying Semi-Final"),
    "fifa world cup 2026"
  );
  assert.equal(isAllowedCompetition("FIFA World Cup Qualifying - European"), true);
});

test("matchIncludesHomeNation matches the requested home nations only", () => {
  assert.equal(
    matchIncludesHomeNation(
      baseMatch({
        league: "International Friendly",
        home_team: "England",
        away_team: "Brazil",
      })
    ),
    true
  );

  assert.equal(
    matchIncludesHomeNation(
      baseMatch({
        league: "International Friendly",
        home_team: "France",
        away_team: "Germany",
      })
    ),
    false
  );
});

test("matchIsMajorTournament includes World Cup and Euros but excludes qualifying", () => {
  assert.equal(
    matchIsMajorTournament(
      baseMatch({
        league: "FIFA World Cup 2026 Group A",
      })
    ),
    true
  );

  assert.equal(
    matchIsMajorTournament(
      baseMatch({
        league: "UEFA European Championship Semi-Finals",
      })
    ),
    true
  );

  assert.equal(
    matchIsMajorTournament(
      baseMatch({
        league: "FIFA World Cup Qualifying - European",
      })
    ),
    false
  );
});

test("matchPassesCategoryFilters uses union semantics across domestic and international toggles", () => {
  const premierLeagueTeams = ["Arsenal", "Chelsea"];

  assert.equal(
    matchPassesCategoryFilters(
      baseMatch({
        league: "International Friendly",
        home_team: "Scotland",
        away_team: "Denmark",
      }),
      {
        eplOnly: true,
        homeNations: true,
        majorTournaments: false,
        premierLeagueTeams,
      }
    ),
    true
  );

  assert.equal(
    matchPassesCategoryFilters(
      baseMatch({
        league: "Serie A",
        home_team: "Napoli",
        away_team: "Roma",
      }),
      {
        eplOnly: true,
        homeNations: true,
        majorTournaments: true,
        premierLeagueTeams,
      }
    ),
    false
  );
});

test("mergeBbcAndLiveMatches prefers BBC competition metadata for duplicate fixtures", () => {
  const merged = mergeBbcAndLiveMatches(
    [
      {
        date: "2026-03-26",
        time: "19:45",
        league: "FIFA World Cup 2026 Qualifying Semi-Final",
        home_team: "Italy",
        away_team: "Northern Ireland",
        tv_channels: ["BBC Three"],
      },
    ],
    [
      {
        date: "2026-03-26",
        time: "19:45",
        league: "FIFA World Cup Qualifying - European",
        league_subcategory: "Play-offs - Semi-finals",
        home_team: "Italy",
        away_team: "Northern Ireland",
        tv_channels: [],
      },
    ]
  );

  assert.equal(merged.length, 1);
  assert.equal(merged[0].league, "FIFA World Cup Qualifying - European");
  assert.equal(merged[0].league_subcategory, "Play-offs - Semi-finals");
  assert.deepStrictEqual(merged[0].tv_channels, ["BBC Three"]);
});

test("toMatchListPayload includes score fields from resolved match state", () => {
  const payload = toMatchListPayload(baseMatch(), {
    matchDetailsLookup: {
      [DETAILS_ID]: detailsPayload(),
    },
  });

  assert.equal(payload.home_score, 2);
  assert.equal(payload.away_score, 1);
  assert.equal(payload.aggregate_home_score, undefined);
  assert.equal(payload.aggregate_away_score, undefined);
  assert.equal(payload.penalty_result, undefined);
});

test("toMatchListPayload includes details state even when details teams exactly match", () => {
  const payload = toMatchListPayload(baseMatch(), {
    matchDetailsLookup: {
      [DETAILS_ID]: detailsPayload({
        home_team: "Wolves",
      }),
    },
  });

  assert.equal(payload.score_status, "FT");
  assert.equal(payload.home_score, 2);
  assert.equal(payload.away_score, 1);
});

test("enrichMatchDetailsAggregateImmediately fetches knockout aggregate for stale details payload", async () => {
  const matchId = "c9aggr3g4t01";
  const detailsUrl = `https://www.bbc.co.uk/sport/football/live/${matchId}`;
  const payload = {
    id: matchId,
    details_url: detailsUrl,
    date: "2026-03-19",
    time: "17:45",
    league: "UEFA Europa League",
    league_subcategory: "Last 16",
    home_team: "Midtjylland",
    away_team: "Nottingham Forest",
    home_score: null,
    away_score: null,
    aggregate_home_score: null,
    aggregate_away_score: null,
    score_status: null,
    updated_at: "2026-03-19T01:00:00.000Z",
  };

  const persisted = [];
  const enriched = await enrichMatchDetailsAggregateImmediately(payload, {
    nowIso: "2026-03-19T01:05:00.000Z",
    nowMs: Date.parse("2026-03-19T01:05:00.000Z"),
    fetchMatchByDetailsUrl: async () => ({
      details_url: detailsUrl,
      home_team: "Midtjylland",
      away_team: "Nottingham Forest",
      aggregate_home_score: 1,
      aggregate_away_score: 0,
    }),
    persistOperationalMatchDetailsSafe: async (recordsById, options) => {
      persisted.push({ recordsById, options });
    },
  });

  assert.equal(enriched.aggregate_home_score, 1);
  assert.equal(enriched.aggregate_away_score, 0);
  assert.equal(persisted.length, 1);
  assert.equal(persisted[0].options.source, "request_knockout_aggregate_enrichment");
});

test("enrichKnockoutAggregatesForListMatches updates lookup for stale fixture aggregates", async () => {
  const matchId = "c9aggr3g4t02";
  const detailsUrl = `https://www.bbc.co.uk/sport/football/live/${matchId}`;
  const match = {
    date: "2026-03-19",
    time: "20:00",
    league: "UEFA Europa League",
    league_subcategory: "Last 16",
    home_team: "Aston Villa",
    away_team: "Lille",
    details_url: detailsUrl,
    tv_channels: [],
  };

  const result = await enrichKnockoutAggregatesForListMatches([match], {}, {
    nowIso: "2026-03-19T01:06:00.000Z",
    nowMs: Date.parse("2026-03-19T01:06:00.000Z"),
    fetchMatchByDetailsUrl: async () => ({
      details_url: detailsUrl,
      home_team: "Aston Villa",
      away_team: "Lille",
      aggregate_home_score: 1,
      aggregate_away_score: 0,
    }),
    persistOperationalMatchDetailsSafe: async () => {},
  });

  assert.equal(result.enrichedCount, 1);
  assert.equal(result.lookup[matchId].aggregate_home_score, 1);
  assert.equal(result.lookup[matchId].aggregate_away_score, 0);
});

test("getMatchDetailsStatePayload preserves known first-leg zero aggregate", () => {
  const payload = getMatchDetailsStatePayload({
    id: "c5yqnegjv2xt",
    details_url: "https://www.bbc.co.uk/sport/football/live/c5yqnegjv2xt",
    date: "2026-03-19",
    time: "17:45",
    league: "UEFA Conference League",
    league_subcategory: "Last 16",
    home_team: "AEK Larnaca",
    away_team: "Crystal Palace",
    home_score: null,
    away_score: null,
    aggregate_home_score: 0,
    aggregate_away_score: 0,
    first_leg_home_score: 0,
    first_leg_away_score: 0,
    score_status: null,
  });

  assert.equal(payload.aggregate_home_score, 0);
  assert.equal(payload.aggregate_away_score, 0);
  assert.equal(payload.first_leg_home_score, 0);
  assert.equal(payload.first_leg_away_score, 0);
});

test("getMatchDetailsStatePayload does not synthesize aggregate from first-leg score when aggregate is missing", () => {
  const payload = getMatchDetailsStatePayload({
    id: "c5yqnegjv2xt",
    details_url: "https://www.bbc.co.uk/sport/football/live/c5yqnegjv2xt",
    date: "2026-03-19",
    time: "17:45",
    league: "UEFA Conference League",
    league_subcategory: "Last 16",
    home_team: "AEK Larnaca",
    away_team: "Crystal Palace",
    home_score: null,
    away_score: null,
    aggregate_home_score: null,
    aggregate_away_score: null,
    first_leg_home_score: 0,
    first_leg_away_score: 0,
    score_status: null,
  });

  assert.equal(payload.aggregate_home_score, null);
  assert.equal(payload.aggregate_away_score, null);
  assert.equal(payload.first_leg_home_score, 0);
  assert.equal(payload.first_leg_away_score, 0);
});

test("mergeMatchDetailsPayload clears stale scores when refreshed details show a pre-match state", () => {
  const existing = {
    id: DETAILS_ID,
    details_url: DETAILS_URL,
    date: "2026-03-08",
    time: "12:00",
    league: "FA Cup",
    league_subcategory: "5th Round",
    home_team: "Fulham",
    away_team: "Southampton",
    home_score: 1,
    away_score: 2,
    score_status: "67",
    home_goal_scorers: [{ player: "A", goal_times: ["10'"] }],
    away_goal_scorers: [{ player: "B", goal_times: ["12'"] }],
    home_assists: [],
    away_assists: [],
    home_red_cards: [],
    away_red_cards: [],
    updated_at: "2026-03-08T00:00:00.000Z",
  };

  const incoming = normalizeMatchDetailsPayload({
    details_url: DETAILS_URL,
    date: "2026-03-08",
    time: "12:00",
    league: "FA Cup",
    league_subcategory: "5th Round",
    home_team: "Fulham",
    away_team: "Southampton",
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
    home_red_cards: [],
    away_red_cards: [],
  });

  const merged = mergeMatchDetailsPayload(existing, incoming, "2026-03-08T00:19:33.483Z");
  assert.equal(merged.home_score, null);
  assert.equal(merged.away_score, null);
  assert.equal(merged.score_status, null);
  assert.deepStrictEqual(merged.home_goal_scorers, []);
  assert.deepStrictEqual(merged.away_goal_scorers, []);
});

test("mergeMatchDetailsPayload clears stale scores when refreshed details show a postponed state", () => {
  const existing = {
    id: DETAILS_ID,
    details_url: DETAILS_URL,
    date: "2026-03-21",
    time: "15:00",
    league: "Premier League",
    home_team: "Manchester City",
    away_team: "Crystal Palace",
    home_score: 2,
    away_score: 1,
    score_status: "67",
    home_goal_scorers: [{ player: "A", goal_times: ["10'"] }],
    away_goal_scorers: [{ player: "B", goal_times: ["12'"] }],
    home_assists: [],
    away_assists: [],
    home_red_cards: [],
    away_red_cards: [],
    updated_at: "2026-03-21T00:00:00.000Z",
  };

  const incoming = normalizeMatchDetailsPayload({
    details_url: DETAILS_URL,
    date: "2026-03-21",
    time: "15:00",
    league: "Premier League",
    home_team: "Manchester City",
    away_team: "Crystal Palace",
    score_status: "Match Postponed",
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
    home_red_cards: [],
    away_red_cards: [],
  });

  const merged = mergeMatchDetailsPayload(existing, incoming, "2026-03-21T09:00:00.000Z");
  assert.equal(merged.home_score, null);
  assert.equal(merged.away_score, null);
  assert.equal(merged.score_status, "POSTPONED");
  assert.deepStrictEqual(merged.home_goal_scorers, []);
  assert.deepStrictEqual(merged.away_goal_scorers, []);
});

test("mergeMatchDetailsPayload preserves known aggregate when refreshed pre-match payload omits aggregate fields", () => {
  const existing = normalizeMatchDetailsPayload({
    details_url: "https://www.bbc.co.uk/sport/football/live/c5yqnegjv2xt",
    date: "2026-03-19",
    time: "17:45",
    league: "UEFA Conference League",
    league_subcategory: "Last 16",
    home_team: "AEK Larnaca",
    away_team: "Crystal Palace",
    home_score: null,
    away_score: null,
    aggregate_home_score: 0,
    aggregate_away_score: 0,
    first_leg_home_score: 0,
    first_leg_away_score: 0,
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
    home_red_cards: [],
    away_red_cards: [],
  });

  const incoming = normalizeMatchDetailsPayload({
    details_url: "https://www.bbc.co.uk/sport/football/live/c5yqnegjv2xt",
    date: "2026-03-19",
    time: "17:45",
    league: "UEFA Conference League",
    league_subcategory: "Last 16",
    home_team: "AEK Larnaca",
    away_team: "Crystal Palace",
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
    home_red_cards: [],
    away_red_cards: [],
    first_leg_home_score: 0,
    first_leg_away_score: 0,
  });

  const merged = mergeMatchDetailsPayload(existing, incoming, "2026-03-19T02:20:00.000Z");
  assert.equal(merged.aggregate_home_score, 0);
  assert.equal(merged.aggregate_away_score, 0);
  assert.equal(merged.first_leg_home_score, 0);
  assert.equal(merged.first_leg_away_score, 0);
});

test("pickPreferredMatchStatus keeps AET over FT for finished matches", () => {
  assert.equal(pickPreferredMatchStatus("AET", "FT"), "AET");
  assert.equal(pickPreferredMatchStatus("FT", "AET"), "AET");
});

test("pickPreferredMatchStatus prefers HT over first-half stoppage-time minutes", () => {
  assert.equal(pickPreferredMatchStatus("45+5", "HT"), "HT");
  assert.equal(pickPreferredMatchStatus("45+4", "HT"), "HT");
  assert.equal(pickPreferredMatchStatus("HT", "45+5"), "HT");
});

test("mergeMatchDetailsPayload preserves AET when refreshed data downgrades to FT", () => {
  const existing = normalizeMatchDetailsPayload({
    details_url: DETAILS_URL,
    date: "2026-03-09",
    time: "18:30",
    league: "FA Cup",
    league_subcategory: "5th Round",
    home_team: "West Ham United",
    away_team: "Brentford",
    home_score: 2,
    away_score: 2,
    score_status: "AET",
    penalty_result: "West Ham United win 5 - 3 on penalties",
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
    home_red_cards: [],
    away_red_cards: [],
  });

  const incoming = normalizeMatchDetailsPayload({
    details_url: DETAILS_URL,
    date: "2026-03-09",
    time: "18:30",
    league: "FA Cup",
    league_subcategory: "5th Round",
    home_team: "West Ham United",
    away_team: "Brentford",
    home_score: 2,
    away_score: 2,
    score_status: "FT",
    penalty_result: "West Ham United win 5 - 3 on penalties",
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
    home_red_cards: [],
    away_red_cards: [],
  });

  const merged = mergeMatchDetailsPayload(existing, incoming, "2026-03-10T09:53:35.974Z");
  assert.equal(merged.score_status, "AET");
});

test("mergeMatchDetailsPayload upgrades first-half stoppage time to HT", () => {
  const existing = normalizeMatchDetailsPayload({
    details_url: DETAILS_URL,
    date: "2026-03-14",
    time: "17:30",
    league: "Premier League",
    home_team: "Chelsea",
    away_team: "Newcastle United",
    home_score: 0,
    away_score: 1,
    score_status: "45+5",
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
    home_red_cards: [],
    away_red_cards: [],
  }, {
    nowMs: Date.parse("2026-03-14T18:20:00.000Z"),
  });

  const incoming = normalizeMatchDetailsPayload({
    details_url: DETAILS_URL,
    date: "2026-03-14",
    time: "17:30",
    league: "Premier League",
    home_team: "Chelsea",
    away_team: "Newcastle United",
    home_score: 0,
    away_score: 1,
    score_status: "HT",
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
    home_red_cards: [],
    away_red_cards: [],
  }, {
    nowMs: Date.parse("2026-03-14T18:20:00.000Z"),
  });

  const merged = mergeMatchDetailsPayload(existing, incoming, "2026-03-14T18:20:00.000Z");
  assert.equal(merged.score_status, "HT");
});

test("mergeConfirmedVarDisallowedGoalsIntoPayload appends confirmed disallowed goals to scorer timelines", async () => {
  const merged = await mergeConfirmedVarDisallowedGoalsIntoPayload(
    {
      id: DETAILS_ID,
      home_team: "Leeds United",
      away_team: "Norwich City",
      home_goal_scorers: [
        {
          player: "Brenden Aaronson",
          goal_times: ["45'"],
          own_goal_times: [],
        },
      ],
      away_goal_scorers: [],
      home_assists: [],
      away_assists: [],
    },
    {
      loadHistory: async () => ({
        matches: [
          {
            match_id: DETAILS_ID,
            events: [
              {
                event_type: "goal",
                disallowed_by_var: true,
                team: "home",
                scorer: "Lukas Nmecha",
                assister: "Wilfried Gnonto",
                goal_time: "19'",
              },
              {
                event_type: "goal",
                disallowed_by_var: true,
                team: "home",
                scorer: "Brenden Aaronson",
                goal_time: "51'",
              },
            ],
          },
        ],
      }),
    }
  );

  assert.deepStrictEqual(merged.home_goal_scorers, [
    {
      player: "Brenden Aaronson",
      goal_times: ["45'"],
      own_goal_times: [],
      disallowed_goal_times: ["51'"],
    },
    {
      player: "Lukas Nmecha",
      goal_times: [],
      own_goal_times: [],
      disallowed_goal_times: ["19'"],
    },
  ]);
  assert.deepStrictEqual(merged.away_goal_scorers, []);
  assert.deepStrictEqual(merged.home_assists, [
    {
      player: "Wilfried Gnonto",
      assist_times: ["19'"],
    },
  ]);
});

test("filterStaleBbcMatches accepts a corrected scoreless kickoff fixture over stale cached scores", () => {
  const filtered = filterStaleBbcMatches(
    [
      {
        home_team: "Fulham",
        away_team: "Southampton",
        home_score: null,
        away_score: null,
        match_time: "12:00",
      },
    ],
    [
      {
        home_team: "Fulham",
        away_team: "Southampton",
        home_score: 1,
        away_score: 2,
        match_time: "67",
      },
    ]
  );

  assert.equal(filtered.length, 1);
  assert.equal(filtered[0].home_score, null);
  assert.equal(filtered[0].away_score, null);
  assert.equal(filtered[0].match_time, "12:00");
});

test("normalizeCacheStateDomains resolves aliases and rejects unknown values", () => {
  const normalized = normalizeCacheStateDomains(["fixtures", "match-details", "bbc", "bogus"]);

  assert.deepStrictEqual(normalized.domains, ["matches", "match_details", "bbc_live"]);
  assert.deepStrictEqual(normalized.invalid, ["bogus"]);
});

test("bumpCacheStateSnapshot increments only requested cache generations", () => {
  const base = buildDefaultOperationalCacheState("2026-03-08T09:00:00.000Z");
  const bumped = bumpCacheStateSnapshot(base, ["matches", "bbc_live"], {
    updated_at: "2026-03-08T09:05:00.000Z",
    reason: "incident_fix",
    source: "admin_api",
  });

  assert.equal(bumped.domains.matches.generation, base.domains.matches.generation + 1);
  assert.equal(
    bumped.domains.match_details.generation,
    base.domains.match_details.generation
  );
  assert.equal(bumped.domains.bbc_live.generation, base.domains.bbc_live.generation + 1);
  assert.equal(bumped.domains.matches.reason, "incident_fix");
  assert.equal(bumped.domains.bbc_live.source, "admin_api");
  assert.equal(bumped.updated_at, "2026-03-08T09:05:00.000Z");
});

test("normalizeOperationalCacheState backfills missing domains", () => {
  const normalized = normalizeOperationalCacheState({
    updated_at: "2026-03-08T09:10:00.000Z",
    domains: {
      matches: {
        generation: 4,
        updated_at: "2026-03-08T09:10:00.000Z",
        reason: "manual",
        source: "admin_api",
      },
    },
  });

  assert.equal(normalized.domains.matches.generation, 4);
  assert.equal(normalized.domains.match_details.generation, 1);
  assert.equal(normalized.domains.bbc_live.generation, 1);
  assert.equal(normalized.updated_at, "2026-03-08T09:10:00.000Z");
});

test("toMatchListPayload resolves match_details_id from details lookup when list row lacks details_url", () => {
  const fallbackId = "ce3k6y7dg63t";
  const payload = toMatchListPayload(
    {
      date: "2026-03-04",
      time: "18:00",
      league: "La Liga",
      home_team: "Rayo Vallecano",
      away_team: "Real Oviedo",
      tv_channels: ["Premier Sports 2"],
    },
    {
      matchDetailsLookup: {
        [fallbackId]: {
          id: fallbackId,
          date: null,
          time: null,
          league: null,
          home_team: "Rayo Vallecano",
          away_team: "Real Oviedo",
          score_status: "56",
        },
      },
    }
  );

  assert.equal(payload.match_details_id, fallbackId);
});

test("toMatchListPayload does not resolve match_details_id from details lookup when date conflicts", () => {
  const fallbackId = "ce3k6y7dg63t";
  const payload = toMatchListPayload(
    {
      date: "2026-03-04",
      time: "18:00",
      league: "La Liga",
      home_team: "Rayo Vallecano",
      away_team: "Real Oviedo",
      tv_channels: ["Premier Sports 2"],
    },
    {
      matchDetailsLookup: {
        [fallbackId]: {
          id: fallbackId,
          date: "2026-03-01",
          time: "18:00",
          league: "La Liga",
          home_team: "Rayo Vallecano",
          away_team: "Real Oviedo",
          score_status: "FT",
        },
      },
    }
  );

  assert.equal(payload.match_details_id, undefined);
});

test("toMatchListPayload resolves match_details_id when league label differs but teams date and time match exactly", () => {
  const fallbackId = "cgqgzd55nq1t";
  const payload = toMatchListPayload(
    {
      date: "2026-03-06",
      time: "20:00",
      league: "La Liga",
      home_team: "Celta Vigo",
      away_team: "Real Madrid",
      tv_channels: ["Premier Sports 1"],
    },
    {
      matchDetailsLookup: {
        [fallbackId]: {
          id: fallbackId,
          date: "2026-03-06",
          time: "20:00",
          league: "Spanish La Liga",
          home_team: "Celta Vigo",
          away_team: "Real Madrid",
          score_status: "90+7",
        },
      },
    }
  );

  assert.equal(payload.match_details_id, fallbackId);
});

test("toMatchListPayload resolves match_details_id when details time differs by coverage-start offset", () => {
  const fallbackId = "cy030p56zx4t";
  const payload = toMatchListPayload(
    {
      date: "2026-03-22",
      time: "16:30",
      league: "Carabao Cup",
      home_team: "Arsenal",
      away_team: "Manchester City",
      tv_channels: ["ITV1"],
    },
    {
      matchDetailsLookup: {
        [fallbackId]: {
          id: fallbackId,
          date: "2026-03-22",
          time: "15:00",
          league: "League Cup",
          home_team: "Arsenal",
          away_team: "Manchester City",
          score_status: "3",
        },
      },
    }
  );

  assert.equal(payload.match_details_id, fallbackId);
});

test("enrichKnockoutAggregatesForListMatches preserves Map-backed details lookup entries", async () => {
  const fallbackId = "cy030p56zx4t";
  const match = {
    date: "2026-03-22",
    time: "16:30",
    league: "Carabao Cup Final",
    home_team: "Arsenal",
    away_team: "Manchester City",
    tv_channels: ["ITV1"],
  };
  const matchDetailsLookup = new Map([
    [
      fallbackId,
      {
        id: fallbackId,
        details_url: `https://www.bbc.co.uk/sport/football/live/${fallbackId}`,
        date: "2026-03-22",
        time: "15:00",
        league: "League Cup",
        league_subcategory: "Final",
        home_team: "Arsenal",
        away_team: "Manchester City",
        home_score: 0,
        away_score: 0,
        score_status: "50",
      },
    ],
  ]);

  const enrichment = await enrichKnockoutAggregatesForListMatches([match], matchDetailsLookup);
  assert.equal(enrichment.lookup instanceof Map, true);

  const payload = toMatchListPayload(match, {
    matchDetailsLookup: enrichment.lookup,
  });

  assert.equal(payload.match_details_id, fallbackId);
  assert.equal(payload.score_status, "50");
});

test("toMatchListPayload stabilizes stale in-progress status to FT once kickoff is well past the live window", () => {
  const payload = toMatchListPayload(
    {
      date: "2026-03-06",
      time: "15:00",
      league: "Championship",
      home_team: "Hull City",
      away_team: "Millwall",
      tv_channels: ["Sky Sports Football"],
      match_details_id: "stale123abc",
    },
    {
      matchDetailsLookup: {
        stale123abc: {
          id: "stale123abc",
          date: "2026-03-06",
          time: "15:00",
          league: "Championship",
          home_team: "Hull City",
          away_team: "Millwall",
          home_score: 1,
          away_score: 3,
          score_status: "90+9",
          updated_at: "2026-03-06T17:05:00.000Z",
        },
      },
      nowMs: Date.parse("2026-03-06T19:00:00.000Z"),
    }
  );

  assert.equal(payload.score_status, "FT");
  assert.equal(payload.home_score, 1);
  assert.equal(payload.away_score, 3);
});

test("toMonitorCandidateFromDetailsPayload can expose live fields without a date when explicitly allowed", () => {
  const candidate = toMonitorCandidateFromDetailsPayload(
    {
      id: "cgqgzd55nq1t",
      date: null,
      time: null,
      league: null,
      home_team: "Celta Vigo",
      away_team: "Real Madrid",
      home_score: 1,
      away_score: 1,
      score_status: "86",
      updated_at: "2026-03-06T21:40:00.000Z",
    },
    { allowMissingDate: true }
  );

  assert.equal(candidate.match_details_id, "cgqgzd55nq1t");
  assert.equal(candidate.date, null);
  assert.equal(candidate.time, null);
  assert.equal(candidate.score_status, "86");
  assert.equal(candidate.home_score, 1);
  assert.equal(candidate.away_score, 1);
});

test("mergeMonitorCandidate preserves merged schedule data while importing live details state", () => {
  const merged = mergeMonitorCandidate(
    {
      match_details_id: "cgqgzd55nq1t",
      date: "2026-03-06",
      time: "20:00",
      league: "La Liga",
      home_team: "Celta Vigo",
      away_team: "Real Madrid",
      tv_channels: ["Premier Sports 1"],
    },
    toMonitorCandidateFromDetailsPayload(
      {
        id: "cgqgzd55nq1t",
        date: null,
        time: null,
        league: null,
        home_team: "Celta Vigo",
        away_team: "Real Madrid",
        home_score: 1,
        away_score: 1,
        score_status: "86",
        updated_at: "2026-03-06T21:40:00.000Z",
      },
      { allowMissingDate: true }
    )
  );

  assert.equal(merged.date, "2026-03-06");
  assert.equal(merged.time, "20:00");
  assert.equal(merged.league, "La Liga");
  assert.equal(merged.score_status, "86");
  assert.equal(merged.home_score, 1);
  assert.equal(merged.away_score, 1);
});

test("buildMonitorCandidatesForDate excludes details-only matches absent from merged schedule", () => {
  const candidates = buildMonitorCandidatesForDate(
    "2026-03-06",
    [
      {
        date: "2026-03-06",
        time: "20:00",
        league: "FA Cup",
        home_team: "Wolves",
        away_team: "Liverpool",
        tv_channels: ["BBC One"],
        match_details_id: "c14mvd1104xt",
      },
    ],
    {
      c14mvd1104xt: {
        id: "c14mvd1104xt",
        date: null,
        time: null,
        league: null,
        home_team: "Wolves",
        away_team: "Liverpool",
        home_score: 1,
        away_score: 3,
        score_status: "FT",
        updated_at: "2026-03-06T22:00:00.000Z",
      },
      c20z8lddp2rt: {
        id: "c20z8lddp2rt",
        date: "2026-03-06",
        time: "19:45",
        league: "Ligue 1",
        home_team: "Paris Saint-Germain",
        away_team: "Monaco",
        home_score: 1,
        away_score: 3,
        score_status: "FT",
        updated_at: "2026-03-06T22:00:00.000Z",
      },
    }
  );

  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].match_details_id, "c14mvd1104xt");
  assert.deepEqual(candidates[0].sources, ["details", "merged"]);
  assert.equal(candidates[0].score_status, "FT");
  assert.equal(candidates[0].home_score, 1);
  assert.equal(candidates[0].away_score, 3);
});

test("buildMonitorCandidatesForDate supports Map lookups and reuses details to resolve ids", () => {
  const detailsLookup = new Map([
    [
      "cgqgzd55nq1t",
      {
        id: "cgqgzd55nq1t",
        date: "2026-03-06",
        time: "20:00",
        league: "Spanish La Liga",
        home_team: "Celta Vigo",
        away_team: "Real Madrid",
        home_score: 1,
        away_score: 3,
        score_status: "FT",
        updated_at: "2026-03-06T22:00:00.000Z",
      },
    ],
  ]);

  const candidates = buildMonitorCandidatesForDate(
    "2026-03-06",
    [
      {
        date: "2026-03-06",
        time: "20:00",
        league: "La Liga",
        home_team: "Celta Vigo",
        away_team: "Real Madrid",
        tv_channels: ["Premier Sports 1"],
      },
      {
        date: "2026-03-07",
        time: "15:00",
        league: "Premier League",
        home_team: "Arsenal",
        away_team: "Chelsea",
        tv_channels: ["Sky Sports Main Event"],
      },
    ],
    detailsLookup
  );

  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].match_details_id, "cgqgzd55nq1t");
  assert.deepEqual(candidates[0].sources, ["details", "merged"]);
  assert.equal(candidates[0].score_status, "FT");
  assert.equal(candidates[0].home_score, 1);
  assert.equal(candidates[0].away_score, 3);
});

test("resolveStableMatchScoreStatus converts stale added-time statuses to FT after the live window", () => {
  const scoreStatus = resolveStableMatchScoreStatus(
    {
      date: "2026-03-07",
      time: "12:15",
      home_score: 1,
      away_score: 2,
      score_status: "90+7",
    },
    {
      nowMs: Date.parse("2026-03-07T23:30:00.000Z"),
    }
  );

  assert.equal(scoreStatus, "FT");
});

test("normalizeMatchDetailsPayload stabilizes stale live-looking detail payloads before storage", () => {
  const payload = normalizeMatchDetailsPayload(
    {
      details_url: "https://www.bbc.co.uk/sport/football/live/cj98rz2ypvdt",
      date: "2026-03-07",
      time: "12:15",
      league: "FA Cup",
      home_team: "Mansfield Town",
      away_team: "Arsenal",
      home_score: 1,
      away_score: 2,
      score_status: "90+7",
    },
    {
      nowMs: Date.parse("2026-03-07T23:30:00.000Z"),
    }
  );

  assert.equal(payload.score_status, "FT");
  assert.equal(payload.in_progress, false);
});

test("withStableMatchDetailsState clears stale in-progress flags when a match is long finished", () => {
  const payload = withStableMatchDetailsState(
    {
      id: "cj98rz2ypvdt",
      details_url: "https://www.bbc.co.uk/sport/football/live/cj98rz2ypvdt",
      date: "2026-03-07",
      time: "12:15",
      league: "FA Cup",
      home_team: "Mansfield Town",
      away_team: "Arsenal",
      home_score: 1,
      away_score: 2,
      score_status: "90+7",
      in_progress: true,
    },
    {
      nowMs: Date.parse("2026-03-07T23:30:00.000Z"),
    }
  );

  assert.equal(payload.score_status, "FT");
  assert.equal(payload.in_progress, false);
});

test("markMatchDetailsActive enables short-lived refresh tracking for requested ids", () => {
  assert.equal(markMatchDetailsActive(DETAILS_ID), true);
  assert.equal(isMatchDetailsActive(DETAILS_ID), true);
  assert.equal(markMatchDetailsActive("not-valid!"), false);
  assert.equal(isMatchDetailsActive("not-valid!"), false);
});

test("matchDetailsNeedsBackfill refreshes cached records that are missing core metadata", () => {
  assert.equal(
    matchDetailsNeedsBackfill({
      id: "cgqgzd55nq1t",
      details_url: "https://www.bbc.co.uk/sport/football/live/cgqgzd55nq1t",
      date: null,
      time: null,
      league: null,
      home_team: "Celta Vigo",
      away_team: "Real Madrid",
      home_score: 1,
      away_score: 1,
      score_status: "FT",
      in_progress: false,
      home_goal_scorers: [{ player: "Borja Iglesias", goal_times: ["25'"] }],
      away_goal_scorers: [{ player: "A. Tchouaméni", goal_times: ["11'"] }],
      home_assists: [],
      away_assists: [],
      home_red_cards: [],
      away_red_cards: [],
    }),
    true
  );
});

test("matchDetailsNeedsBackfill refreshes cached records with malformed competition metadata", () => {
  assert.equal(
    matchDetailsNeedsBackfill({
      id: "c14mvd1104xt",
      details_url: "https://www.bbc.co.uk/sport/football/live/c14mvd1104xt",
      date: "2026-03-06",
      time: "18:45",
      league: "FA Cup -",
      home_team: "Wolverhampton Wanderers",
      away_team: "Liverpool",
      home_score: 1,
      away_score: 3,
      score_status: "FT",
      in_progress: false,
      home_goal_scorers: [{ player: "Hwang Hee-Chan", goal_times: ["90+1'"] }],
      away_goal_scorers: [
        { player: "A. Robertson", goal_times: ["51'"] },
        { player: "Mohamed Salah", goal_times: ["53'"] },
        { player: "C. Jones", goal_times: ["74'"] },
      ],
      home_assists: [],
      away_assists: [],
      home_red_cards: [],
      away_red_cards: [],
    }),
    true
  );
});

test("matchDetailsNeedsBackfill refreshes cached records that are missing parsed team lineups", () => {
  assert.equal(
    matchDetailsNeedsBackfill({
      id: "cgqgzd55nq1t",
      details_url: "https://www.bbc.co.uk/sport/football/live/cgqgzd55nq1t",
      date: "2026-03-06",
      time: "20:00",
      league: "FA Cup",
      home_team: "Mansfield Town",
      away_team: "Arsenal",
      home_score: 1,
      away_score: 2,
      score_status: "FT",
      home_goal_scorers: [{ player: "W. Evans", goal_times: ["50'"] }],
      away_goal_scorers: [
        { player: "N. Madueke", goal_times: ["41'"] },
        { player: "E. Eze", goal_times: ["66'"] },
      ],
    }),
    true
  );
});

test("matchDetailsNeedsBackfill keeps fully populated records with lineups out of the backfill queue", () => {
  assert.equal(
    matchDetailsNeedsBackfill({
      id: "cgqgzd55nq1t",
      details_url: "https://www.bbc.co.uk/sport/football/live/cgqgzd55nq1t",
      date: "2026-03-06",
      time: "20:00",
      league: "FA Cup",
      home_team: "Wolverhampton Wanderers",
      away_team: "Liverpool",
      home_score: 1,
      away_score: 3,
      score_status: "FT",
      updated_at: "2026-03-06T22:00:00.000Z",
      home_goal_scorers: [{ player: "Hwang Hee-Chan", goal_times: ["90+1'"] }],
      away_goal_scorers: [
        { player: "Darwin Núñez", goal_times: ["15'"] },
        { player: "Mohamed Salah", goal_times: ["47'"] },
        { player: "Luis Díaz", goal_times: ["82'"] },
      ],
      team_lineups: buildCompleteTeamLineups(),
    }),
    false
  );
});

test("buildFallbackMatchDetailsPayload synthesizes a details response from in-memory match records", () => {
  const payload = buildFallbackMatchDetailsPayload("cgqgzd55nq1t", {
    date: "2026-03-06",
    time: "20:00",
    league: "FA Cup",
    league_subcategory: "5th Round",
    home_team: "Mansfield Town",
    away_team: "Arsenal",
    home_score: 1,
    away_score: 2,
    score_status: "FT",
    details_url: "https://www.bbc.co.uk/sport/football/live/cgqgzd55nq1t",
    home_goal_scorers: [{ player: "W. Evans", goal_times: ["50'"] }],
    away_goal_scorers: [
      { player: "N. Madueke", goal_times: ["41'"] },
      { player: "E. Eze", goal_times: ["66'"] },
    ],
    home_assists: [],
    away_assists: [
      { player: "Gabriel Martinelli", assist_times: ["41'"] },
      { player: "C. Nørgaard", assist_times: ["66'"] },
    ],
    home_yellow_cards: [],
    away_yellow_cards: [],
    home_red_cards: [],
    away_red_cards: [],
    team_lineups: {
      home: {
        team: "Mansfield Town",
        manager: "Nigel Clough",
        formation: "3-5-2",
        starting_lineup: buildStartingLineupFromRows(1, [
          { prefix: "Home", count: 1, position_category: "goalkeeper" },
          { prefix: "Home", count: 4, position_category: "defender" },
          { prefix: "Home", count: 4, position_category: "midfielder" },
          { prefix: "Home", count: 2, position_category: "attacker" },
        ]),
        substitutes: [{ number: 12, name: "Home Sub 1" }],
        substitutions: [],
      },
      away: {
        team: "Arsenal",
        manager: "Mikel Arteta",
        formation: "3-5-1-1",
        starting_lineup: buildStartingLineupFromRows(20, [
          { prefix: "Away", count: 1, position_category: "goalkeeper" },
          { prefix: "Away", count: 3, position_category: "defender" },
          { prefix: "Away", count: 5, position_category: "midfielder" },
          { prefix: "Away", count: 1, position_category: "midfielder" },
          { prefix: "Away", count: 1, position_category: "attacker" },
        ]),
        substitutes: [{ number: 40, name: "Away Sub 1" }],
        substitutions: [],
      },
    },
  });

  assert.deepStrictEqual(payload, {
    id: "cgqgzd55nq1t",
    details_url: "https://www.bbc.co.uk/sport/football/live/cgqgzd55nq1t",
    date: "2026-03-06",
    time: "20:00",
    league: "FA Cup",
    home_team: "Mansfield Town",
    away_team: "Arsenal",
    home_score: 1,
    away_score: 2,
    aggregate_home_score: null,
    aggregate_away_score: null,
    first_leg_home_score: null,
    first_leg_away_score: null,
    score_status: "FT",
    penalty_result: null,
    in_progress: false,
    updated_at: null,
    league_subcategory: "5th Round",
    home_goal_scorers: [{ player: "W. Evans", goal_times: ["50'"] }],
    away_goal_scorers: [
      { player: "N. Madueke", goal_times: ["41'"] },
      { player: "E. Eze", goal_times: ["66'"] },
    ],
    home_assists: [],
    away_assists: [
      { player: "Gabriel Martinelli", assist_times: ["41'"] },
      { player: "C. Nørgaard", assist_times: ["66'"] },
    ],
    home_yellow_cards: [],
    away_yellow_cards: [],
    home_red_cards: [],
    away_red_cards: [],
    team_lineups: {
      home: {
        team: "Mansfield Town",
        manager: "Nigel Clough",
        formation: "3-5-2",
        starting_lineup: buildStartingLineupFromRows(1, [
          { prefix: "Home", count: 1, position_category: "goalkeeper" },
          { prefix: "Home", count: 4, position_category: "defender" },
          { prefix: "Home", count: 4, position_category: "midfielder" },
          { prefix: "Home", count: 2, position_category: "attacker" },
        ]),
        substitutes: [{ number: 12, name: "Home Sub 1" }],
        substitutions: [],
      },
      away: {
        team: "Arsenal",
        manager: "Mikel Arteta",
        formation: "3-5-1-1",
        starting_lineup: buildStartingLineupFromRows(20, [
          { prefix: "Away", count: 1, position_category: "goalkeeper" },
          { prefix: "Away", count: 3, position_category: "defender" },
          { prefix: "Away", count: 5, position_category: "midfielder" },
          { prefix: "Away", count: 1, position_category: "midfielder" },
          { prefix: "Away", count: 1, position_category: "attacker" },
        ]),
        substitutes: [{ number: 40, name: "Away Sub 1" }],
        substitutions: [],
      },
    },
  });
});
