const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    toMatchListPayload,
    dedupeMatchListPayloads,
    toMonitorCandidateFromDetailsPayload,
    mergeMonitorCandidate,
    buildMonitorCandidatesForDate,
    buildFallbackMatchDetailsPayload,
    getMatchDetailsStatePayload,
    getMatchDetailsSummaryPayload,
    mergePreferredOperationalMatchDetailsSnapshots,
    toOperationalAdminMatchPayload,
    normalizeAdminRedisMatchIds,
    normalizeAdminRogueMatchSelectors,
    collectAdminRogueMatchTargets,
    collectLiveSourceDuplicateTargets,
    collectCanonicalDuplicateTargets,
    canonicalMatchDetailsToListPayload,
    canonicalMatchDetailsRecordsToListPayloads,
    canonicalMatchDetailsRecordsToPublicListPayloads,
    getMatchListLastKnownPayload,
    setMatchListLastKnownPayload,
    overlayCurrentDayBsdProjection,
    buildMatchQueryResponseCacheKey,
    buildTeamRankingsResponseCacheKey,
    buildTeamRankingsBaseCacheKey,
    buildCanonicalMatchWriteAuditEntry,
    transformBbcLiveMatchWithDetails,
    mergeConfirmedVarDisallowedGoalsIntoPayload,
    mergeConfirmedVarDisallowedGoalsIntoPayloads,
    enrichMatchDetailsAggregateImmediately,
    enrichKnockoutAggregatesForListMatches,
    matchDetailsNeedsBackfill,
    hasRenderableTeamLineups,
    markMatchDetailsActive,
    isMatchDetailsActive,
    normalizeMatchDetailsPayload,
    mergeMatchDetailsPayload,
    playerDetailsPayloadFromMatchLineups,
    withConfiguredMatchDetailsPlayerImages,
    withConfiguredPlayerDetailsImage,
    buildSyntheticMatchDetailsId,
    pickPreferredMatchStatus,
    resolveStableMatchScoreStatus,
    withStableMatchDetailsState,
    filterStaleMatches,
    shouldRefreshCanonicalMatchDetails,
    buildDefaultOperationalCacheState,
    normalizeCacheStateDomains,
    normalizeOperationalCacheState,
    bumpCacheStateSnapshot,
    normalizeMatchStatusValue,
    normalizeTeamName,
    normalizeCompetitionFilterName,
    normalizeMatchesListMode,
    isAllowedCompetition,
    isAllowedCompetitionMatch,
    isAllowedMatchDetailsPayload,
    matchPassesCompetitionTableValidation,
    collectDisallowedCompetitionTargets,
    clearFootballOperationalMemoryState,
    collectInProgressMatchDetailTargets,
    mergeBsdAndLiveMatches,
    matchIncludesHomeNation,
    matchIsMajorGameOfInterest,
    matchIsMajorTournament,
    matchPassesCategoryFilters,
    buildFixtureViewFilterContext,
    isChampionsLeagueQualifyingMatch,
    matchPassesTopTeamsPreset,
    matchPassesFixtureViewOptions,
    isListPayloadVisibleForMode,
    mergeClubEloFixtureMetadata,
    operationalMatchSortDesc,
    upsertMatchDetailsFromMatch,
  },
} = require("./server");

const DETAILS_ID = "c1e937445p2t";
const DETAILS_URL = `https://www.bbc.co.uk/sport/football/live/${DETAILS_ID}`;

function kickoffWithinLiveWindow() {
  const kickoff = new Date(Date.now() - 60 * 60 * 1000);
  return {
    date: kickoff.toISOString().slice(0, 10),
    time: kickoff.toISOString().slice(11, 16),
  };
}

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

test("player details fall back to the newest cached match lineup", () => {
  const payload = playerDetailsPayloadFromMatchLineups("34259208", [
    {
      date: "2026-01-10",
      time: "15:00",
      home_team: "Previous Club",
      away_team: "Opponent",
      team_lineups: {
        home: {
          starting_lineup: [{
            number: 20,
            name: "Mamadou Doumbia",
            id_player: "34259208",
            position: "F",
            position_category: "attacker",
            cutout_url: "https://example.com/old.png",
          }],
        },
      },
    },
    {
      date: "2026-08-16",
      time: "13:30",
      home_team: "Watford",
      away_team: "Southampton",
      team_lineups: {
        home: {
          starting_lineup: [{
            number: 20,
            name: "Mamadou Doumbia",
            id_player: "34259208",
            position: "F",
            position_category: "attacker",
            cutout_url: "https://example.com/current.png",
          }],
        },
      },
    },
  ]);

  assert.deepStrictEqual(payload, {
    id: "34259208",
    name: "Mamadou Doumbia",
    team: "Watford",
    born: null,
    description: null,
    side: null,
    position: "Forward",
    birth_location: null,
    cutout_url: "https://example.com/current.png",
    thumb_url: null,
    render_url: null,
  });
});

test("configured BSD player details use the direct BSD player id", async () => {
  const payload = await withConfiguredPlayerDetailsImage(
    {
      id: "6525",
      name: "Cameron Burgess",
      cutout_url: "https://example.test/cutout.png",
      thumb_url: "https://example.test/thumb.png",
      render_url: "https://example.test/render.png",
    },
    "6525"
  );

  assert.equal(payload.cutout_url, "https://sports.bzzoiro.com/img/player/6525/");
  assert.equal(payload.thumb_url, null);
  assert.equal(payload.render_url, null);
});

test("configured BSD match details use direct BSD lineup ids", async () => {
  const payload = await withConfiguredMatchDetailsPlayerImages(
    {
      team_lineups: {
        home: {
          starting_lineup: [{
            id_player: "6525",
            name: "Cameron Burgess",
            cutout_url: "https://example.test/cutout.png",
          }],
          substitutes: [],
          substitutions: [],
        },
      },
    }
  );

  assert.equal(
    payload.team_lineups.home.starting_lineup[0].cutout_url,
    "https://sports.bzzoiro.com/img/player/6525/"
  );
});

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
        id_player: null,
        position: null,
        position_short: null,
        cutout_url: null,
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
      has_bsd_source: true,
      home_score: null,
      away_score: null,
      score_status: null,
    })
  );

  assert.equal(payload.has_bsd_source, true);
  assert.equal(payload.match_details_id, undefined);
});

test("toMatchListPayload preserves venue kickoff and light context metadata", () => {
  const payload = toMatchListPayload(
    baseMatch({
      venue_id: "273",
      kickoff_at: "2026-06-19T22:00:00.000Z",
      light_context: "day",
    })
  );

  assert.equal(payload.venue_id, "273");
  assert.equal(payload.kickoff_at, "2026-06-19T22:00:00.000Z");
  assert.equal(payload.light_context, "day");
});

test("toMatchListPayload includes server-controlled competition weight", () => {
  const payload = toMatchListPayload(baseMatch({ league: "FIFA World Cup" }));

  assert.equal(payload.league, "FIFA World Cup 2026");
  assert.equal(typeof payload.competition_weight, "number");
});

test("shouldRefreshCanonicalMatchDetails heals missing canonical records", () => {
  clearFootballOperationalMemoryState();

  assert.equal(
    shouldRefreshCanonicalMatchDetails(
      baseMatch({
        score_status: "FT",
        home_score: 2,
        away_score: 1,
        home_goal_scorers: [{ player: "Matheus Cunha", goal_times: ["55'"] }],
        away_goal_scorers: [{ player: "Mohamed Salah", goal_times: ["12'"] }],
        team_lineups: buildCompleteTeamLineups(),
      })
    ),
    true
  );
});

test("shouldRefreshCanonicalMatchDetails heals incomplete canonical records", () => {
  clearFootballOperationalMemoryState();

  upsertMatchDetailsFromMatch(baseMatch());

  assert.equal(
    shouldRefreshCanonicalMatchDetails(
      baseMatch({
        score_status: "FT",
        home_score: 2,
        away_score: 1,
        home_goal_scorers: [{ player: "Matheus Cunha", goal_times: ["55'"] }],
        away_goal_scorers: [{ player: "Mohamed Salah", goal_times: ["12'"] }],
        team_lineups: buildCompleteTeamLineups(),
      })
    ),
    true
  );
});

test("shouldRefreshCanonicalMatchDetails skips unchanged canonical records", () => {
  clearFootballOperationalMemoryState();

  const livePayload = baseMatch({
    home_team: "Wolverhampton Wanderers",
    score_status: "FT",
    home_score: 2,
    away_score: 1,
    home_goal_scorers: [{ player: "Matheus Cunha", goal_times: ["55'", "81'"] }],
    away_goal_scorers: [{ player: "Mohamed Salah", goal_times: ["12'"] }],
    team_lineups: buildCompleteTeamLineups(),
  });
  upsertMatchDetailsFromMatch(livePayload);

  assert.equal(shouldRefreshCanonicalMatchDetails(livePayload), false);
});

test("canonicalMatchDetailsToListPayload materializes a list row from canonical Redis state", () => {
  const payload = canonicalMatchDetailsToListPayload({
    ...detailsPayload({
      score_status: "AET",
      penalty_result: "Leeds United win 4 - 2 on penalties",
      tv_channels: ["TNT Sports 1"],
      has_bsd_source: true,
    }),
    league_subcategory: "Quarter-finals",
  });

  assert.deepStrictEqual(payload, {
    date: "2026-03-03",
    time: "20:15",
    league: "Premier League",
    league_subcategory: "Quarter-finals",
    home_team: "Wolverhampton Wanderers",
    away_team: "Liverpool",
    tv_channels: ["TNT Sports 1"],
    match_details_id: DETAILS_ID,
    home_score: 1,
    away_score: 1,
    score_status: "AET",
    penalty_result: "Leeds United win 4 - 2 on penalties",
    has_bsd_source: true,
  });
});

test("buildMonitorCandidatesForDate does not regress finished matches to stale BBC live minutes", () => {
  const date = "2026-03-03";
  const time = "15:00";

  const candidates = buildMonitorCandidatesForDate(
    date,
    [
      {
        date,
        time,
        league: "Premier League",
        home_team: "Newcastle United",
        away_team: "AFC Bournemouth",
        home_score: 1,
        away_score: 2,
        score_status: "FT",
        match_details_id: "c0lejl83egpt",
      },
    ],
    {},
    {
      bbcMatches: [
        {
          date,
          time,
          home_team: "Newcastle United",
          away_team: "AFC Bournemouth",
          home_score: 1,
          away_score: 2,
          match_time: "90+8",
        },
      ],
    }
  );

  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].match_details_id, "c0lejl83egpt");
  assert.equal(candidates[0].score_status, "FT");
});

test("normalizeMatchDetailsPayload strips staged knockout suffixes from league when subcategory is present", () => {
  const payload = normalizeMatchDetailsPayload({
    id: "ucl-quarter-1",
    date: "2026-04-07",
    time: "20:00",
    league: "UEFA Champions League Quarter-Final 1st Leg",
    league_subcategory: "Quarter-finals",
    home_team: "Sporting CP",
    away_team: "Arsenal",
    details_url: "https://www.bbc.co.uk/sport/football/live/uc1quarter1",
    tv_channels: ["TNT Sports 1"],
  });

  assert.equal(payload.league, "UEFA Champions League");
  assert.equal(payload.league_subcategory, "Quarter-finals");
});

test("canonicalMatchDetailsRecordsToListPayloads dedupes duplicate canonical records", () => {
  const payloads = canonicalMatchDetailsRecordsToListPayloads({
    [DETAILS_ID]: detailsPayload(),
    duplicate: {
      ...detailsPayload(),
      id: "duplicate",
      details_url: "https://www.bbc.co.uk/sport/football/live/duplicate",
      updated_at: "2026-03-03T22:05:00.000Z",
    },
  });

  assert.equal(payloads.length, 1);
  assert.equal(payloads[0].home_team, "Wolverhampton Wanderers");
  assert.equal(payloads[0].away_team, "Liverpool");
});

test("canonicalMatchDetailsRecordsToPublicListPayloads excludes competitions outside the allowlist", () => {
  const payloads = canonicalMatchDetailsRecordsToPublicListPayloads({
    allowed: detailsPayload({
      league: "FA Cup",
      home_team: "West Ham United",
      away_team: "Leeds United",
    }),
    womens: {
      ...detailsPayload({
        id: "womens001",
        league: "Women's FA Cup",
        home_team: "Arsenal Women",
        away_team: "Brighton Women",
      }),
      details_url: "https://www.bbc.co.uk/sport/football/live/womens001",
    },
    wsl2: {
      ...detailsPayload({
        id: "wsl2001",
        league: "WSL 2",
        home_team: "Crystal Palace Women",
        away_team: "Ipswich Women",
      }),
      details_url: "https://www.bbc.co.uk/sport/football/live/wsl2001",
    },
  });

  assert.equal(payloads.length, 1);
  assert.equal(payloads[0].league, "FA Cup");
});

test("canonicalMatchDetailsRecordsToPublicListPayloads supplements missing canonical fixtures from fallback matches", () => {
  const payloads = canonicalMatchDetailsRecordsToPublicListPayloads(
    {},
    {
      fallbackMatches: [
        {
          date: "2026-04-07",
          time: "19:00",
          league: "UEFA Champions League",
          league_subcategory: "Quarter-finals",
          home_team: "Real Madrid",
          away_team: "Bayern Munich",
          has_bsd_source: true,
          tv_channels: [],
        },
      ],
    }
  );

  assert.equal(payloads.length, 1);
  assert.equal(payloads[0].home_team, "Real Madrid");
  assert.equal(payloads[0].away_team, "Bayern Munich");
  assert.equal(payloads[0].league, "UEFA Champions League");
  assert.equal(payloads[0].league_subcategory, "Quarter-finals");
  assert.equal(payloads[0].has_bsd_source, true);
});

test("canonicalMatchDetailsRecordsToListPayloads drops stale TBC final placeholders", () => {
  const payloads = canonicalMatchDetailsRecordsToListPayloads({
    old_placeholder: {
      id: "oldplaceholder",
      date: "2026-05-20",
      time: "20:00",
      league: "UEFA Europa League",
      league_subcategory: "Final",
      home_team: "TBC",
      away_team: "TBC",
      updated_at: "2026-05-18T10:00:00.000Z",
      tv_channels: [],
    },
    latest_final: {
      id: "latestfinal",
      date: "2026-05-20",
      time: "20:00",
      league: "UEFA Europa League",
      league_subcategory: "Final",
      home_team: "Freiburg",
      away_team: "Aston Villa",
      updated_at: "2026-05-20T08:00:00.000Z",
      tv_channels: [],
    },
  });

  assert.equal(payloads.length, 1);
  assert.equal(payloads[0].match_details_id, "latestfinal");
  assert.equal(payloads[0].home_team, "Freiburg");
  assert.equal(payloads[0].away_team, "Aston Villa");
  assert.equal(payloads[0]._source_updated_at, undefined);
});

test("canonicalMatchDetailsRecordsToListPayloads keeps latest one-team-overlap play-off final fixture", () => {
  const payloads = canonicalMatchDetailsRecordsToListPayloads({
    old_tbc: {
      id: "oldtbc",
      date: "2026-05-23",
      time: "00:00",
      league: "Championship",
      league_subcategory: "Promotion Play-offs - Final",
      home_team: "Hull City",
      away_team: "TBC",
      updated_at: "2026-05-17T10:00:00.000Z",
      tv_channels: [],
    },
    old_opponent: {
      id: "oldopponent",
      date: "2026-05-23",
      time: "16:30",
      league: "Championship",
      league_subcategory: "Promotion Play-offs - Final",
      home_team: "Hull City",
      away_team: "Southampton",
      updated_at: "2026-05-18T10:00:00.000Z",
      tv_channels: ["Sky Sports Football"],
    },
    latest_opponent: {
      id: "latestopponent",
      date: "2026-05-23",
      time: "00:00",
      league: "Championship",
      league_subcategory: "Promotion Play-offs - Final",
      home_team: "Hull City",
      away_team: "Middlesbrough",
      updated_at: "2026-05-20T08:00:00.000Z",
      tv_channels: [],
    },
  });

  assert.equal(payloads.length, 1);
  assert.equal(payloads[0].match_details_id, "latestopponent");
  assert.equal(payloads[0].home_team, "Hull City");
  assert.equal(payloads[0].away_team, "Middlesbrough");
});

test("canonicalMatchDetailsRecordsToListPayloads lets resolved BBC final suppress stale scheduled fallback", () => {
  const payloads = canonicalMatchDetailsRecordsToListPayloads(
    {
      latest_result: {
        id: "latestresult",
        date: "2026-05-23",
        time: "15:00",
        league: "Championship",
        league_subcategory: "Promotion Play-offs - Final",
        home_team: "Hull City",
        away_team: "Middlesbrough",
        home_score: 1,
        away_score: 0,
        score_status: "FT",
        has_bsd_source: true,
        updated_at: "2026-05-23T16:55:00.000Z",
        tv_channels: [],
      },
    },
    {
      fallbackMatches: [
        {
          date: "2026-05-23",
          time: "16:30",
          league: "Championship",
          league_subcategory: "Promotion Play-offs - Final",
          home_team: "Hull City",
          away_team: "Southampton",
          has_bsd_source: true,
          tv_channels: ["Sky Sports Football"],
        },
      ],
    }
  );

  assert.equal(payloads.length, 1);
  assert.equal(payloads[0].match_details_id, "latestresult");
  assert.equal(payloads[0].home_team, "Hull City");
  assert.equal(payloads[0].away_team, "Middlesbrough");
  assert.equal(payloads[0].home_score, 1);
  assert.equal(payloads[0].away_score, 0);
  assert.equal(payloads[0].score_status, "FT");
});

test("buildCanonicalMatchWriteAuditEntry captures previous and next summaries", () => {
  const entry = buildCanonicalMatchWriteAuditEntry(
    DETAILS_ID,
    detailsPayload({
      home_score: 3,
      away_score: 2,
      score_status: "PENS",
    }),
    detailsPayload({
      home_score: 2,
      away_score: 2,
      score_status: "AET",
      penalty_result: "Leeds United win 4 - 2 on penalties",
    }),
    {
      source: "match_monitor_poll",
      reason: "monitor_poll",
      written_at: "2026-04-05T18:47:00.000Z",
    }
  );

  assert.deepStrictEqual(entry, {
    match_id: DETAILS_ID,
    written_at: "2026-04-05T18:47:00.000Z",
    source: "match_monitor_poll",
    reason: "monitor_poll",
    previous: {
      home_team: "Wolverhampton Wanderers",
      away_team: "Liverpool",
      home_score: 3,
      away_score: 2,
      score_status: "Pens",
      penalty_result: null,
      updated_at: "2026-03-03T22:00:00.000Z",
    },
    next: {
      home_team: "Wolverhampton Wanderers",
      away_team: "Liverpool",
      home_score: 2,
      away_score: 2,
      score_status: "AET",
      penalty_result: "Leeds United win 4 - 2 on penalties",
      updated_at: "2026-03-03T22:00:00.000Z",
    },
    metadata: null,
  });
});

test("getMatchDetailsStatePayload normalizes settled penalty shootouts back to a draw scoreline", () => {
  const payload = getMatchDetailsStatePayload({
    ...detailsPayload({
      home_score: 3,
      away_score: 2,
      score_status: "AET",
      penalty_result: "Leeds United win 4 - 2 on penalties",
    }),
    home_team: "West Ham United",
    away_team: "Leeds United",
  });

  assert.equal(payload.home_score, 2);
  assert.equal(payload.away_score, 2);
  assert.equal(payload.penalty_result, "Leeds United win 4 - 2 on penalties");
});

test("getMatchDetailsSummaryPayload omits heavyweight fixture detail fields", () => {
  const payload = getMatchDetailsSummaryPayload({
    ...detailsPayload({
      date: "2099-08-15",
      time: "20:00",
      home_score: 2,
      away_score: 1,
      score_status: "84'",
    }),
    team_lineups: {
      home: { starting_lineup: [{ name: "Home player" }] },
      away: { starting_lineup: [{ name: "Away player" }] },
    },
    tv_channels: [{ name: "Example Sports" }],
  });

  assert.equal(payload.home_score, 2);
  assert.equal(payload.away_score, 1);
  assert.equal(payload.score_status, "84");
  assert.equal(payload.in_progress, true);
  assert.equal(payload.team_lineups, undefined);
  assert.equal(payload.tv_channels, undefined);
});

test("mergeMatchDetailsPayload normalizes settled penalty shootouts back to a draw scoreline", () => {
  const merged = mergeMatchDetailsPayload(
    detailsPayload({
      home_team: "West Ham United",
      away_team: "Leeds United",
      home_score: 2,
      away_score: 2,
      score_status: "AET",
      penalty_result: "Leeds United win 4 - 2 on penalties",
    }),
    normalizeMatchDetailsPayload({
      details_url: "https://www.bbc.co.uk/sport/football/live/c75k3rv779xt",
      date: "2026-04-05",
      time: "15:30",
      league: "FA Cup",
      home_team: "West Ham United",
      away_team: "Leeds United",
      home_score: 3,
      away_score: 2,
      score_status: "AET",
      penalty_result: "Leeds United win 4 - 2 on penalties",
    }),
    "2026-04-05T22:29:00.161Z"
  );

  assert.equal(merged.home_score, 2);
  assert.equal(merged.away_score, 2);
  assert.equal(merged.penalty_result, "Leeds United win 4 - 2 on penalties");
});

test("toOperationalAdminMatchPayload exposes normalized penalty score and competition fields", () => {
  const payload = toOperationalAdminMatchPayload({
    ...detailsPayload({
      home_team: "West Ham United",
      away_team: "Leeds United",
      league: "FA Cup",
      league_subcategory: "Quarter-finals",
      home_score: 3,
      away_score: 2,
      score_status: "AET",
      penalty_result: "Leeds United win 4 - 2 on penalties",
    }),
    league_subcategory: "Quarter-finals",
  });

  assert.equal(payload.home_score, 2);
  assert.equal(payload.away_score, 2);
  assert.equal(payload.league, "FA Cup");
  assert.equal(payload.league_subcategory, "Quarter-finals");
});

test("buildSyntheticMatchDetailsId creates a stable canonical id for future fixtures without BBC ids", () => {
  const fixture = {
    date: "2026-04-11",
    time: "11:30",
    league: "Premier League",
    home_team: "Arsenal",
    away_team: "AFC Bournemouth",
  };

  const first = buildSyntheticMatchDetailsId(fixture);
  const second = buildSyntheticMatchDetailsId({
    ...fixture,
    home_team: "Arsenal",
    away_team: "AFC Bournemouth",
  });

  assert.ok(first);
  assert.match(first, /^syn[a-z0-9]{16}$/);
  assert.equal(first, second);
});

test("normalizeMatchDetailsPayload falls back to a synthetic canonical id for future fixtures", () => {
  const payload = normalizeMatchDetailsPayload({
    date: "2026-04-11",
    time: "11:30",
    league: "Premier League",
    home_team: "Arsenal",
    away_team: "AFC Bournemouth",
    tv_channels: ["Sky Sports"],
  });

  assert.ok(payload);
  assert.match(payload.id, /^syn[a-z0-9]{16}$/);
  assert.equal(payload.league, "Premier League");
  assert.equal(payload.home_team, "Arsenal");
  assert.equal(payload.away_team, "AFC Bournemouth");
});

test("normalizeAdminRedisMatchIds accepts singular and plural ids and removes invalid entries", () => {
  assert.deepEqual(
    normalizeAdminRedisMatchIds({
      match_id: "C75K3RV779XT",
      match_ids: ["c75k3rv779xt", "not-valid!", "cdxzkljkjxkt"],
    }),
    ["c75k3rv779xt", "cdxzkljkjxkt"]
  );
});

test("operationalMatchSortDesc sorts admin Redis rows by kickoff latest to oldest", () => {
  const rows = [
    {
      match_id: "older",
      date: "2026-04-05",
      time: "15:30",
      updated_at: "2026-04-05T23:50:00.000Z",
    },
    {
      match_id: "latest",
      date: "2026-04-06",
      time: "20:00",
      updated_at: "2026-04-05T01:00:00.000Z",
    },
    {
      match_id: "middle",
      date: "2026-04-06",
      time: "12:30",
      updated_at: "2026-04-05T22:00:00.000Z",
    },
  ];

  const sortedIds = rows.sort(operationalMatchSortDesc).map((row) => row.match_id);
  assert.deepEqual(sortedIds, ["latest", "middle", "older"]);
});

test("mergePreferredOperationalMatchDetailsSnapshots prefers fresher memory match state over stale Redis state", () => {
  const merged = mergePreferredOperationalMatchDetailsSnapshots(
    {
      updated_at: "2026-04-05T22:59:06.585Z",
      records: {
        cn43ql18lg8t: {
          id: "cn43ql18lg8t",
          date: "2026-04-05",
          time: "19:45",
          league: "Serie A",
          home_team: "Inter Milan",
          away_team: "Roma",
          home_score: 5,
          away_score: 2,
          score_status: "FT",
          updated_at: "2026-04-05T22:59:06.585Z",
        },
      },
    },
    {
      updated_at: "2026-04-05T22:57:38.360Z",
      records: {
        cn43ql18lg8t: {
          id: "cn43ql18lg8t",
          date: "2026-04-05",
          time: "19:45",
          league: "Serie A",
          home_team: "Inter Milan",
          away_team: "Roma",
          home_score: 5,
          away_score: 2,
          score_status: "90+5",
          updated_at: "2026-04-05T22:57:38.360Z",
        },
      },
    }
  );

  assert.equal(merged.records.cn43ql18lg8t.score_status, "FT");
  assert.equal(merged.source, "memory+redis_preferred");
});

test("mergePreferredOperationalMatchDetailsSnapshots includes future fixtures that only exist in memory", () => {
  const merged = mergePreferredOperationalMatchDetailsSnapshots(
    {
      updated_at: "2026-04-06T07:00:00.000Z",
      records: {
        abcdef123456: {
          id: "abcdef123456",
          date: "2026-04-06",
          time: "15:00",
          league: "Championship",
          home_team: "Millwall",
          away_team: "Norwich City",
          updated_at: "2026-04-06T07:00:00.000Z",
        },
      },
    },
    {
      updated_at: "2026-04-06T06:30:00.000Z",
      records: {},
    }
  );

  assert.ok(merged.records.abcdef123456);
  assert.equal(merged.total, 1);
});

test("normalizeTeamName canonicalizes team aliases from shared identity config", () => {
  assert.equal(normalizeTeamName("Man City"), "manchester city");
  assert.equal(normalizeTeamName("MCI"), "manchester city");
  assert.equal(normalizeTeamName("AFC Bournemouth"), "bournemouth");
  assert.equal(normalizeTeamName("QPR"), "queens park rangers");
  assert.equal(normalizeTeamName("West Brom"), "west bromwich albion");
  assert.equal(normalizeTeamName("AZ"), "az alkmaar");
  assert.equal(normalizeTeamName("Mainz"), "fsv mainz 05");
});

test("normalizeMatchStatusValue canonicalizes postponed status", () => {
  assert.equal(normalizeMatchStatusValue("Match Postponed"), "POSTPONED");
  assert.equal(normalizeMatchStatusValue("POSTPONED"), "POSTPONED");
});

test("normalizeMatchStatusValue canonicalizes penalty shootout progress tallies", () => {
  assert.equal(normalizeMatchStatusValue("P 0-0"), "P 0-0");
  assert.equal(normalizeMatchStatusValue("p 4 - 3"), "P 4-3");
});

test("normalizeCompetitionFilterName maps World Cup qualifying competitions to the World Cup family", () => {
  assert.equal(
    normalizeCompetitionFilterName("FIFA World Cup"),
    "fifa world cup 2026"
  );
  assert.equal(
    normalizeCompetitionFilterName("FIFA World Cup Qualifying - European"),
    "fifa world cup 2026"
  );
  assert.equal(
    normalizeCompetitionFilterName("FIFA World Cup 2026 Qualifying Semi-Final"),
    "fifa world cup 2026"
  );
  assert.equal(isAllowedCompetition("FIFA World Cup"), true);
  assert.equal(isAllowedCompetition("FIFA World Cup Qualifying - European"), true);
  assert.equal(isAllowedCompetition("DFB-Pokal"), false);
  assert.equal(isAllowedCompetition("Ukraine Premier League"), false);
  assert.equal(isAllowedCompetition("Scottish Championship"), true);
});

test("matchPassesCompetitionTableValidation only rejects generic English league labels when both teams are absent from the BBC table", () => {
  const tables = [
    {
      league_id: "premier-league",
      league_name: "Premier League",
      rows: [{ team: "Arsenal" }, { team: "Chelsea" }],
    },
    {
      league_id: "championship",
      league_name: "Championship",
      rows: [
        { team: "Blackburn Rovers" },
        { team: "West Bromwich Albion" },
        { team: "Millwall" },
        { team: "Preston North End" },
        { team: "Queens Park Rangers" },
      ],
    },
  ];

  assert.equal(
    matchPassesCompetitionTableValidation(
      { league: "Premier League", home_team: "Arsenal", away_team: "Chelsea" },
      null,
      tables
    ),
    true
  );
  assert.equal(
    matchPassesCompetitionTableValidation(
      { league: "Premier League", home_team: "Epitsentr", away_team: "Kudrivka" },
      null,
      tables
    ),
    false
  );
  assert.equal(
    matchPassesCompetitionTableValidation(
      { league: "Championship", home_team: "Blackburn Rovers", away_team: "West Brom" },
      null,
      tables
    ),
    true
  );
  assert.equal(
    matchPassesCompetitionTableValidation(
      { league: "Championship", home_team: "Millwall", away_team: "Leicester City" },
      null,
      tables
    ),
    true
  );
  assert.equal(
    matchPassesCompetitionTableValidation(
      { league: "Championship", home_team: "Queen's Park", away_team: "Ross County" },
      null,
      tables
    ),
    false
  );
  assert.equal(
    matchPassesCompetitionTableValidation(
      { league: "Scottish Championship", home_team: "Queen's Park", away_team: "Ross County" },
      null,
      tables
    ),
    true
  );
});

test("canonical BSD fixtures are not hidden by a stale partial league table", () => {
  const staleTables = [
    {
      league_id: "premier-league",
      league_name: "Premier League",
      rows: [{ team: "Brighton & Hove Albion" }, { team: "Aston Villa" }],
    },
  ];
  const manCityFixture = {
    league: "Premier League",
    home_team: "Manchester City",
    away_team: "Bournemouth",
  };

  assert.equal(isAllowedCompetitionMatch(manCityFixture, { tables: staleTables }), false);
  assert.equal(
    isAllowedCompetitionMatch(
      { ...manCityFixture, has_bsd_source: true },
      { tables: staleTables }
    ),
    true
  );
});

test("isAllowedMatchDetailsPayload rejects generic competition labels when table membership disagrees", () => {
  const tables = [
    {
      league_id: "premier-league",
      league_name: "Premier League",
      rows: [{ team: "Arsenal" }, { team: "Chelsea" }],
    },
    {
      league_id: "championship",
      league_name: "Championship",
      rows: [{ team: "Blackburn Rovers" }, { team: "West Bromwich Albion" }],
    },
  ];

  assert.equal(
    isAllowedMatchDetailsPayload(
      {
        id: "c98m9778p3lt",
        date: "2026-04-06",
        time: "16:00",
        league: "Premier League",
        home_team: "Epitsentr",
        away_team: "Kudrivka",
      },
      null,
      { tables }
    ),
    false
  );
  assert.equal(
    isAllowedMatchDetailsPayload(
      {
        id: "209543",
        date: "2026-08-23",
        time: "16:30",
        league: "Premier League",
        home_team: "Newcastle United",
        away_team: "Liverpool",
        home_score: 2,
        away_score: 1,
        score_status: "71",
        has_bsd_source: true,
      },
      null,
      { tables }
    ),
    true
  );
  assert.equal(
    isAllowedMatchDetailsPayload(
      {
        id: "cblackburn1",
        date: "2026-04-06",
        time: "15:00",
        league: "Championship",
        home_team: "Blackburn Rovers",
        away_team: "West Brom",
      },
      null,
      { tables }
    ),
    true
  );
  assert.equal(
    isAllowedMatchDetailsPayload(
      {
        id: "cscot1",
        date: "2026-04-06",
        time: "19:45",
        league: "Scottish Championship",
        home_team: "Queen's Park",
        away_team: "Ross County",
      },
      null,
      { tables }
    ),
    true
  );
});

test("collectDisallowedCompetitionTargets includes generic competition rows that fail table validation", () => {
  const tables = [
    {
      league_id: "premier-league",
      league_name: "Premier League",
      rows: [{ team: "Arsenal" }, { team: "Chelsea" }],
    },
    {
      league_id: "championship",
      league_name: "Championship",
      rows: [{ team: "Blackburn Rovers" }, { team: "West Bromwich Albion" }],
    },
  ];

  const rogueId = "c98m9778p3lt";
  const targets = collectDisallowedCompetitionTargets(
    {
      mergedMatches: [
        {
          match_details_id: rogueId,
          date: "2026-04-06",
          time: "16:00",
          league: "Premier League",
          home_team: "Epitsentr",
          away_team: "Kudrivka",
        },
        {
          match_details_id: "cgood1",
          date: "2026-04-06",
          time: "15:00",
          league: "Championship",
          home_team: "Blackburn Rovers",
          away_team: "West Brom",
        },
      ],
    },
    new Map([
      [
        rogueId,
        {
          id: rogueId,
          date: "2026-04-06",
          time: "16:00",
          league: "Premier League",
          home_team: "Epitsentr",
          away_team: "Kudrivka",
        },
      ],
    ]),
    { tables }
  );

  assert.equal(targets.disallowedMergedMatches.length, 1);
  assert.equal(targets.disallowedMergedMatches[0].home_team, "Epitsentr");
  assert.deepStrictEqual(targets.matchedCanonicalMatchIds, [rogueId]);
  assert.deepStrictEqual(targets.disallowedCompetitions, ["Premier League"]);
});

test("mergeMatchDetailsPayload preserves a more specific competition name over a generic refresh", () => {
  const premierMerged = mergeMatchDetailsPayload(
    detailsPayload({
      league: "Ukraine Premier League",
      home_score: null,
      away_score: null,
      score_status: null,
    }),
    detailsPayload({
      league: "Premier League",
      home_score: 1,
      away_score: 0,
      score_status: "FT",
    }),
    "2026-04-06T20:30:00.000Z"
  );

  const championshipMerged = mergeMatchDetailsPayload(
    detailsPayload({
      league: "Scottish Championship",
      home_team: "Arbroath",
      away_team: "Queen's Park",
      home_score: null,
      away_score: null,
      score_status: null,
    }),
    detailsPayload({
      league: "Championship",
      home_team: "Arbroath",
      away_team: "Queen's Park",
      home_score: 2,
      away_score: 1,
      score_status: "FT",
    }),
    "2026-04-06T20:31:00.000Z"
  );

  assert.equal(premierMerged.league, "Ukraine Premier League");
  assert.equal(championshipMerged.league, "Scottish Championship");
});

test("normalizeMatchesListMode only accepts fixtures and results", () => {
  assert.equal(normalizeMatchesListMode("fixtures"), "fixtures");
  assert.equal(normalizeMatchesListMode("results"), "results");
  assert.equal(normalizeMatchesListMode("RESULTS"), "results");
  assert.equal(normalizeMatchesListMode(""), null);
  assert.equal(normalizeMatchesListMode("table"), null);
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

test("matchIsMajorGameOfInterest includes promotion play-offs and configured derbies", () => {
  assert.equal(
    matchIsMajorGameOfInterest(
      baseMatch({
        league: "UEFA Super Cup",
      })
    ),
    true
  );

  assert.equal(
    matchIsMajorGameOfInterest(
      baseMatch({
        league: "Championship",
        league_subcategory: "Promotion Play-offs - Semi-finals",
        home_team: "Middlesbrough",
        away_team: "Southampton",
      })
    ),
    true
  );

  assert.equal(
    matchIsMajorGameOfInterest(
      baseMatch({
        league: "Scottish Premiership",
        home_team: "Rangers",
        away_team: "Celtic",
      })
    ),
    true
  );

  assert.equal(
    matchIsMajorGameOfInterest(
      baseMatch({
        league: "La Liga",
        home_team: "Real Madrid",
        away_team: "Barcelona",
      })
    ),
    true
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
        league: "Ligue 1",
        home_team: "Nantes",
        away_team: "Rennes",
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

test("matchPassesCategoryFilters does not treat teams outside the current season as Premier League teams", () => {
  const currentPremierLeagueTeams = ["Arsenal", "Coventry City"];

  for (const match of [
    baseMatch({
      league: "Club Friendlies",
      home_team: "Paris Saint-Germain",
      away_team: "Manchester United",
    }),
    baseMatch({
      league: "EFL Cup",
      home_team: "West Ham United",
      away_team: "Portsmouth",
    }),
    baseMatch({
      league: "EFL Cup",
      home_team: "Burnley",
      away_team: "Notts County",
    }),
  ]) {
    assert.equal(
      matchPassesCategoryFilters(match, {
        eplOnly: true,
        premierLeagueTeams: currentPremierLeagueTeams,
      }),
      false
    );
  }
});

test("matchPassesCategoryFilters fails closed when the current Premier League dataset is unavailable", () => {
  assert.equal(
    matchPassesCategoryFilters(
      baseMatch({
        league: "Club Friendlies",
        home_team: "Paris Saint-Germain",
        away_team: "Manchester United",
      }),
      {
        eplOnly: true,
        premierLeagueTeams: [],
      }
    ),
    false
  );
});

test("top teams includes Champions League league-phase matches but gates qualifying rounds", () => {
  const context = {
    isPremierLeagueTeam: () => false,
    isTopTeamsHomeAssociationClub: (teamName) => teamName === "Celtic",
    isTopTeamsMajorClub: (teamName) => teamName === "Juventus",
  };
  const leaguePhase = {
    league: "UEFA Champions League",
    league_subcategory: "League Phase",
    home_team: "Slavia Prague",
    away_team: "Young Boys",
  };
  const minorQualifier = {
    ...leaguePhase,
    league_subcategory: "Third qualifying round",
  };
  const ukQualifier = {
    ...minorQualifier,
    home_team: "Celtic",
  };
  const majorQualifier = {
    ...minorQualifier,
    away_team: "Juventus",
  };

  assert.equal(isChampionsLeagueQualifyingMatch(leaguePhase), false);
  assert.equal(isChampionsLeagueQualifyingMatch(minorQualifier), true);
  assert.equal(matchPassesTopTeamsPreset(leaguePhase, context), true);
  assert.equal(matchPassesTopTeamsPreset(minorQualifier, context), false);
  assert.equal(matchPassesTopTeamsPreset(ukQualifier, context), true);
  assert.equal(matchPassesTopTeamsPreset(majorQualifier, context), true);
});

test("top teams applies unconditional and conditional inclusion rules", () => {
  const context = {
    isPremierLeagueTeam: (teamName) => teamName === "Everton",
    isTopTeamsHomeAssociationClub: (teamName) => teamName === "Shamrock Rovers",
    isTopTeamsMajorClub: (teamName) => teamName === "AC Milan",
  };
  const match = (league, home_team, away_team, league_subcategory = null) => ({
    league,
    league_subcategory,
    home_team,
    away_team,
  });

  assert.equal(matchPassesTopTeamsPreset(match("EFL Cup", "Preston North End", "Everton"), context), true);
  assert.equal(matchPassesTopTeamsPreset(match("International Friendly", "Ireland", "Japan"), context), true);
  assert.equal(matchPassesTopTeamsPreset(match("La Liga", "Real Madrid", "Getafe"), context), true);
  assert.equal(matchPassesTopTeamsPreset(match("UEFA Europa League", "Shamrock Rovers", "Basel"), context), true);
  assert.equal(matchPassesTopTeamsPreset(match("UEFA Conference League", "AC Milan", "Basel"), context), true);
  assert.equal(matchPassesTopTeamsPreset(match("UEFA Europa League", "Basel", "Young Boys"), context), false);
  assert.equal(matchPassesTopTeamsPreset(match("Serie A", "AC Milan", "Udinese"), context), false);
  assert.equal(
    matchPassesFixtureViewOptions(
      match("EFL Cup", "Preston North End", "Everton"),
      ["preset:top-teams"],
      context
    ),
    true
  );
});

test("top teams always includes Premier League fixtures", () => {
  assert.equal(
    matchPassesTopTeamsPreset(
      {
        league: "Premier League",
        home_team: "Coventry City",
        away_team: "Hull City",
      },
      {
        isPremierLeagueTeam: () => false,
        isTopTeamsHomeAssociationClub: () => false,
        isTopTeamsMajorClub: () => false,
      }
    ),
    true
  );
});

test("top teams derives current Premier League clubs from the live team catalog", () => {
  const context = buildFixtureViewFilterContext({
    premierLeagueTeams: ["Liverpool"],
    clubEloTeams: [],
    manualMappings: new Map(),
    teamCatalogSnapshot: {
      teams: [
        {
          id: "coventry-city",
          name: "Coventry City",
          aliases: ["Coventry"],
          competition_ids: ["english-league-cup", "premier-league"],
        },
        {
          id: "hull-city",
          name: "Hull City",
          aliases: ["Hull"],
          competition_ids: ["premier-league"],
        },
      ],
      byID: new Map(),
      updatedAt: "2026-08-27T00:00:00.000Z",
    },
  });

  assert.equal(context.isPremierLeagueTeam("Coventry City"), true);
  assert.equal(context.isPremierLeagueTeam("Hull"), true);
  assert.equal(
    matchPassesTopTeamsPreset(
      {
        league: "EFL Cup",
        home_team: "Coventry City",
        away_team: "Oxford United",
      },
      context
    ),
    true
  );
});

test("mergeBsdAndLiveMatches prefers BBC competition metadata for duplicate fixtures", () => {
  const merged = mergeBsdAndLiveMatches(
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

test("mergeBsdAndLiveMatches ignores unmatched live-football rows", () => {
  const merged = mergeBsdAndLiveMatches(
    [
      {
        date: "2026-04-06",
        time: "20:00",
        league: "Championship",
        home_team: "Blackburn Rovers",
        away_team: "West Brom",
        tv_channels: ["Sky Sports Football"],
      },
    ],
    []
  );

  assert.deepStrictEqual(merged, []);
});

test("mergeBsdAndLiveMatches keeps BBC team names while merging live TV metadata", () => {
  const merged = mergeBsdAndLiveMatches(
    [
      {
        date: "2026-04-06",
        time: "15:00",
        league: "Championship",
        home_team: "Preston North End",
        away_team: "QPR",
        tv_channels: ["Sky Sports Football"],
      },
    ],
    [
      {
        date: "2026-04-06",
        time: "15:00",
        league: "Championship",
        home_team: "Preston North End",
        away_team: "Queens Park Rangers",
        tv_channels: [],
        has_bsd_source: true,
      },
    ]
  );

  assert.equal(merged.length, 1);
  assert.equal(merged[0].home_team, "Preston North End");
  assert.equal(merged[0].away_team, "Queens Park Rangers");
  assert.equal(merged[0].has_bsd_source, true);
  assert.deepStrictEqual(merged[0].tv_channels, ["Sky Sports Football"]);
});

test("mergeBsdAndLiveMatches collapses Bundesliga aliases onto the BBC-backed FT row", () => {
  const merged = mergeBsdAndLiveMatches(
    [
      {
        date: "2026-04-19",
        time: "16:30",
        league: "Bundesliga",
        home_team: "Bayern Munich",
        away_team: "VfB Stuttgart",
        tv_channels: ["Amazon Prime PPV"],
        home_score: 4,
        away_score: 2,
        score_status: "90",
      },
    ],
    [
      {
        date: "2026-04-19",
        time: "16:30",
        league: "German Bundesliga",
        home_team: "Bayern Munich",
        away_team: "Stuttgart",
        tv_channels: [],
        home_score: 4,
        away_score: 2,
        score_status: "FT",
        details_url: "https://www.bbc.co.uk/sport/football/live/c89558d5d5nt",
        has_bsd_source: true,
      },
    ]
  );

  assert.equal(merged.length, 1);
  assert.equal(merged[0].league, "Bundesliga");
  assert.equal(merged[0].away_team, "Stuttgart");
  assert.equal(merged[0].score_status, "FT");
  assert.equal(merged[0].details_url, "https://www.bbc.co.uk/sport/football/live/c89558d5d5nt");
  assert.equal(merged[0].has_bsd_source, true);
});

test("mergeBsdAndLiveMatches collapses Serie A alias rows onto the BBC-backed FT rows", () => {
  const veronaMerged = mergeBsdAndLiveMatches(
    [
      {
        date: "2026-04-19",
        time: "14:00",
        league: "Serie A",
        home_team: "Verona",
        away_team: "AC Milan",
        tv_channels: ["DAZN", "BBC Alba", "BBC iPlayer", "BBC Sport Website"],
      },
    ],
    [
      {
        date: "2026-04-19",
        time: "14:00",
        league: "Italian Serie A",
        home_team: "Hellas Verona",
        away_team: "AC Milan",
        home_score: 0,
        away_score: 1,
        score_status: "FT",
        details_url: "https://www.bbc.co.uk/sport/football/live/c5yjjq5jlrmt",
        has_bsd_source: true,
      },
    ]
  );

  assert.equal(veronaMerged.length, 1);
  assert.equal(veronaMerged[0].league, "Serie A");
  assert.equal(veronaMerged[0].home_team, "Hellas Verona");
  assert.equal(veronaMerged[0].score_status, "FT");
  assert.equal(veronaMerged[0].details_url, "https://www.bbc.co.uk/sport/football/live/c5yjjq5jlrmt");

  const pisaMerged = mergeBsdAndLiveMatches(
    [
      {
        date: "2026-04-19",
        time: "17:00",
        league: "Serie A",
        home_team: "Pisa",
        away_team: "Genoa",
        tv_channels: ["DAZN"],
      },
    ],
    [
      {
        date: "2026-04-19",
        time: "17:00",
        league: "Italian Serie A",
        home_team: "Pisa",
        away_team: "Genoa",
        home_score: 1,
        away_score: 2,
        score_status: "FT",
        details_url: "https://www.bbc.co.uk/sport/football/live/cx2vvg0v3rpt",
        has_bsd_source: true,
      },
    ]
  );

  assert.equal(pisaMerged.length, 1);
  assert.equal(pisaMerged[0].league, "Serie A");
  assert.equal(pisaMerged[0].score_status, "FT");
  assert.equal(pisaMerged[0].details_url, "https://www.bbc.co.uk/sport/football/live/cx2vvg0v3rpt");
});

test("mergeBsdAndLiveMatches collapses La Liga and Bundesliga alias rows onto BBC-backed FT rows", () => {
  const osasunaMerged = mergeBsdAndLiveMatches(
    [
      {
        date: "2026-04-12",
        time: "13:00",
        league: "La Liga",
        home_team: "Osasuna",
        away_team: "Real Betis",
        tv_channels: ["Premier Sports 2"],
      },
    ],
    [
      {
        date: "2026-04-12",
        time: "13:00",
        league: "Spanish La Liga",
        home_team: "Osasuna",
        away_team: "Real Betis",
        home_score: 1,
        away_score: 1,
        score_status: "FT",
        details_url: "https://www.bbc.co.uk/sport/football/live/cx24nxnxggkt",
        has_bsd_source: true,
      },
    ]
  );

  assert.equal(osasunaMerged.length, 1);
  assert.equal(osasunaMerged[0].league, "La Liga");
  assert.equal(osasunaMerged[0].score_status, "FT");
  assert.equal(osasunaMerged[0].details_url, "https://www.bbc.co.uk/sport/football/live/cx24nxnxggkt");

  const stuttgartMerged = mergeBsdAndLiveMatches(
    [
      {
        date: "2026-04-12",
        time: "16:30",
        league: "Bundesliga",
        home_team: "VfB Stuttgart",
        away_team: "Hamburg",
        tv_channels: ["Amazon Prime PPV"],
      },
    ],
    [
      {
        date: "2026-04-12",
        time: "16:30",
        league: "German Bundesliga",
        home_team: "Stuttgart",
        away_team: "Hamburger SV",
        home_score: 4,
        away_score: 0,
        score_status: "FT",
        details_url: "https://www.bbc.co.uk/sport/football/live/c705j1jx2y0t",
        has_bsd_source: true,
      },
    ]
  );

  assert.equal(stuttgartMerged.length, 1);
  assert.equal(stuttgartMerged[0].league, "Bundesliga");
  assert.equal(stuttgartMerged[0].score_status, "FT");
  assert.equal(stuttgartMerged[0].details_url, "https://www.bbc.co.uk/sport/football/live/c705j1jx2y0t");
});

test("collectAdminRogueMatchTargets only selects the exact rogue short-name row", () => {
  const { selectors, invalid } = normalizeAdminRogueMatchSelectors({
    matches: [
      {
        date: "2026-04-06",
        time: "15:00",
        league: "Championship",
        home_team: "Preston North End",
        away_team: "QPR",
      },
    ],
  });

  assert.deepStrictEqual(invalid, []);

  const rogueId = buildSyntheticMatchDetailsId({
    date: "2026-04-06",
    time: "15:00",
    league: "Championship",
    home_team: "Preston North End",
    away_team: "QPR",
  });
  const bbcId = buildSyntheticMatchDetailsId({
    date: "2026-04-06",
    time: "15:00",
    league: "Championship",
    home_team: "Preston North End",
    away_team: "Queens Park Rangers",
  });

  const targets = collectAdminRogueMatchTargets(
    selectors,
    [
      {
        date: "2026-04-06",
        time: "15:00",
        league: "Championship",
        home_team: "Preston North End",
        away_team: "QPR",
        match_details_id: rogueId,
      },
      {
        date: "2026-04-06",
        time: "15:00",
        league: "Championship",
        home_team: "Preston North End",
        away_team: "Queens Park Rangers",
        match_details_id: bbcId,
        has_bsd_source: true,
      },
    ],
    new Map([
      [
        rogueId,
        {
          id: rogueId,
          date: "2026-04-06",
          time: "15:00",
          league: "Championship",
          home_team: "Preston North End",
          away_team: "QPR",
        },
      ],
      [
        bbcId,
        {
          id: bbcId,
          date: "2026-04-06",
          time: "15:00",
          league: "Championship",
          home_team: "Preston North End",
          away_team: "Queens Park Rangers",
          has_bsd_source: true,
        },
      ],
    ])
  );

  assert.equal(targets.matchedMergedMatches.length, 1);
  assert.equal(targets.matchedMergedMatches[0].away_team, "QPR");
  assert.deepStrictEqual(targets.matchedCanonicalMatchIds, [rogueId]);
});

test("collectLiveSourceDuplicateTargets finds live-only duplicates of BBC-backed fixtures", () => {
  const mainzLiveId = buildSyntheticMatchDetailsId({
    date: "2026-04-09",
    time: "20:00",
    league: "UEFA Conference League",
    home_team: "Mainz",
    away_team: "Strasbourg",
  });
  const mainzBbcId = "cmainzbbc1";
  const azLiveId = buildSyntheticMatchDetailsId({
    date: "2026-04-09",
    time: "20:00",
    league: "UEFA Conference League",
    home_team: "Shakhtar Donetsk",
    away_team: "AZ",
  });
  const azBbcId = "cshakhtar1";

  const detailsLookup = new Map([
    [
      mainzLiveId,
      {
        id: mainzLiveId,
        date: "2026-04-09",
        time: "20:00",
        league: "UEFA Conference League",
        home_team: "Mainz",
        away_team: "Strasbourg",
      },
    ],
    [
      mainzBbcId,
      {
        id: mainzBbcId,
        date: "2026-04-09",
        time: "20:00",
        league: "UEFA Conference League Quarter-Final 1st Leg",
        home_team: "Mainz 05",
        away_team: "Strasbourg",
        details_url: `https://www.bbc.co.uk/sport/football/live/${mainzBbcId}`,
        has_bsd_source: true,
      },
    ],
    [
      azLiveId,
      {
        id: azLiveId,
        date: "2026-04-09",
        time: "20:00",
        league: "UEFA Conference League",
        home_team: "Shakhtar Donetsk",
        away_team: "AZ",
      },
    ],
    [
      azBbcId,
      {
        id: azBbcId,
        date: "2026-04-09",
        time: "20:00",
        league: "UEFA Conference League Quarter-Final 1st Leg",
        home_team: "Shakhtar Donetsk",
        away_team: "AZ Alkmaar",
        details_url: `https://www.bbc.co.uk/sport/football/live/${azBbcId}`,
        has_bsd_source: true,
      },
    ],
  ]);

  const targets = collectLiveSourceDuplicateTargets(
    {
      liveMatches: [
        {
          date: "2026-04-09",
          time: "20:00",
          league: "UEFA Conference League",
          home_team: "Mainz",
          away_team: "Strasbourg",
        },
        {
          date: "2026-04-09",
          time: "20:00",
          league: "UEFA Conference League",
          home_team: "Shakhtar Donetsk",
          away_team: "AZ",
        },
      ],
      recentMatches: [],
      mergedMatches: [],
    },
    detailsLookup
  );

  assert.deepStrictEqual(
    targets.duplicate_canonical_match_ids.sort(),
    [azLiveId, mainzLiveId].sort()
  );
  assert.equal(targets.duplicate_live_matches.length, 2);
  assert.equal(targets.duplicate_live_matches[0].home_team, "Mainz");
  assert.equal(targets.duplicate_live_matches[1].away_team, "AZ");
});

test("collectCanonicalDuplicateTargets finds weaker canonical alias duplicates", () => {
  const mainzAliasId = buildSyntheticMatchDetailsId({
    date: "2026-04-09",
    time: "20:00",
    league: "UEFA Conference League",
    home_team: "Mainz",
    away_team: "Strasbourg",
  });
  const mainzBbcId = "cmainzbbc1";
  const azAliasId = buildSyntheticMatchDetailsId({
    date: "2026-04-09",
    time: "20:00",
    league: "UEFA Conference League",
    home_team: "Shakhtar Donetsk",
    away_team: "AZ",
  });
  const azBbcId = "cshakhtar1";

  const detailsLookup = new Map([
    [
      mainzAliasId,
      {
        id: mainzAliasId,
        date: "2026-04-09",
        time: "20:00",
        league: "UEFA Conference League",
        home_team: "Mainz",
        away_team: "Strasbourg",
        updated_at: "2026-04-09T18:00:00.000Z",
      },
    ],
    [
      mainzBbcId,
      {
        id: mainzBbcId,
        date: "2026-04-09",
        time: "20:00",
        league: "UEFA Conference League Quarter-Final 1st Leg",
        home_team: "Mainz 05",
        away_team: "Strasbourg",
        details_url: `https://www.bbc.co.uk/sport/football/live/${mainzBbcId}`,
        has_bsd_source: true,
        updated_at: "2026-04-09T18:01:00.000Z",
      },
    ],
    [
      azAliasId,
      {
        id: azAliasId,
        date: "2026-04-09",
        time: "20:00",
        league: "UEFA Conference League",
        home_team: "Shakhtar Donetsk",
        away_team: "AZ",
        updated_at: "2026-04-09T18:00:00.000Z",
      },
    ],
    [
      azBbcId,
      {
        id: azBbcId,
        date: "2026-04-09",
        time: "20:00",
        league: "UEFA Conference League Quarter-Final 1st Leg",
        home_team: "Shakhtar Donetsk",
        away_team: "AZ Alkmaar",
        details_url: `https://www.bbc.co.uk/sport/football/live/${azBbcId}`,
        has_bsd_source: true,
        updated_at: "2026-04-09T18:01:00.000Z",
      },
    ],
  ]);

  const targets = collectCanonicalDuplicateTargets(
    {
      mergedMatches: [
        {
          date: "2026-04-09",
          time: "20:00",
          league: "UEFA Conference League",
          home_team: "Mainz",
          away_team: "Strasbourg",
          match_details_id: mainzAliasId,
        },
        {
          date: "2026-04-09",
          time: "20:00",
          league: "UEFA Conference League Quarter-Final 1st Leg",
          home_team: "Mainz 05",
          away_team: "Strasbourg",
          match_details_id: mainzBbcId,
        },
        {
          date: "2026-04-09",
          time: "20:00",
          league: "UEFA Conference League",
          home_team: "Shakhtar Donetsk",
          away_team: "AZ",
          match_details_id: azAliasId,
        },
        {
          date: "2026-04-09",
          time: "20:00",
          league: "UEFA Conference League Quarter-Final 1st Leg",
          home_team: "Shakhtar Donetsk",
          away_team: "AZ Alkmaar",
          match_details_id: azBbcId,
        },
      ],
    },
    detailsLookup
  );

  assert.deepStrictEqual(
    targets.duplicate_canonical_match_ids.sort(),
    [azAliasId, mainzAliasId].sort()
  );
  assert.equal(targets.duplicate_merged_matches.length, 2);
  assert.equal(targets.duplicate_merged_matches[0].home_team, "Mainz");
  assert.equal(targets.duplicate_merged_matches[1].away_team, "AZ");
});

test("mergePreferredOperationalMatchDetailsSnapshots filters disallowed competitions", () => {
  const snapshot = mergePreferredOperationalMatchDetailsSnapshots(
    {
      updated_at: "2026-04-06T17:00:00.000Z",
      records: {
        allowed1: {
          id: "allowed1",
          date: "2026-04-06",
          time: "15:00",
          league: "Championship",
          home_team: "Preston North End",
          away_team: "Queens Park Rangers",
        },
      },
    },
    {
      updated_at: "2026-04-06T16:00:00.000Z",
      records: {
        mls1: {
          id: "mls1",
          date: "2026-04-06",
          time: "19:00",
          league: "MLS",
          home_team: "FC Dallas",
          away_team: "Colorado Rapids",
        },
      },
    }
  );

  assert.deepStrictEqual(Object.keys(snapshot.records).sort(), ["allowed1"]);
  assert.equal(snapshot.total, 1);
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

test("buildMatchQueryResponseCacheKey ignores pagination and changes with filters", () => {
  const baseOptions = {
    listCacheKey: "base",
    dateFrom: "2025-05-18",
    dateTo: "2026-05-18",
    leagues: [],
    teams: [],
    channels: [],
    filterMode: "intersection",
    listMode: "results",
    sortOrder: "desc",
    eplOnly: true,
    majorUefa: true,
    homeNations: true,
    majorTournaments: true,
    premierLeagueUpdatedAt: "2026-05-18T12:00:00.000Z",
  };

  assert.equal(
    buildMatchQueryResponseCacheKey({ ...baseOptions, page: 1, pageSize: 120 }),
    buildMatchQueryResponseCacheKey({ ...baseOptions, page: 6, pageSize: 120 })
  );
  assert.notEqual(
    buildMatchQueryResponseCacheKey(baseOptions),
    buildMatchQueryResponseCacheKey({ ...baseOptions, homeNations: false })
  );
});

test("older match-list rebuild cannot replace a newer live-score payload", () => {
  const source = "bsd-rebuild-order-regression";
  const newerPayload = [{
    match_details_id: "209543",
    home_team: "Newcastle United",
    away_team: "Liverpool",
    home_score: 1,
    away_score: 0,
    score_status: "35",
  }];
  const olderPayload = [{
    match_details_id: "209543",
    home_team: "Newcastle United",
    away_team: "Liverpool",
    home_score: 0,
    away_score: 0,
    score_status: null,
  }];

  assert.equal(setMatchListLastKnownPayload(source, newerPayload, 2), true);
  assert.equal(setMatchListLastKnownPayload(source, olderPayload, 1), false);
  assert.deepEqual(getMatchListLastKnownPayload(source), newerPayload);
});

test("current BSD projection restores missing live fixtures in a stale public list", () => {
  const date = "2026-08-23";
  const fixture = (id, homeTeam, awayTeam, overrides = {}) => ({
    id,
    match_details_id: id,
    date,
    time: "14:00",
    league: "Premier League",
    home_team: homeTeam,
    away_team: awayTeam,
    has_bsd_source: true,
    tv_channels: [],
    ...overrides,
  });
  const cachedPayload = [
    fixture("209541", "Brighton & Hove Albion", "Aston Villa", {
      home_score: 4,
      away_score: 0,
      score_status: "FT",
    }),
    fixture("209543", "Newcastle United", "Liverpool", {
      time: "16:30",
      home_score: 0,
      away_score: 0,
    }),
  ];
  const projection = [
    fixture("209542", "Manchester City", "Bournemouth", {
      home_score: 2,
      away_score: 1,
      score_status: "FT",
    }),
    fixture("209543", "Newcastle United", "Liverpool", {
      time: "16:30",
      home_score: 1,
      away_score: 0,
      score_status: "HT",
    }),
    fixture("future-fixture", "Arsenal", "Chelsea", {
      date: "2026-08-24",
      time: "20:00",
    }),
  ];

  const result = overlayCurrentDayBsdProjection(cachedPayload, projection, date);
  const premierLeagueMatches = result.filter((match) => match.league === "Premier League");
  const newcastle = premierLeagueMatches.find((match) => match.match_details_id === "209543");

  assert.equal(premierLeagueMatches.length, 3);
  assert.equal(newcastle.home_score, 1);
  assert.equal(newcastle.away_score, 0);
  assert.equal(newcastle.score_status, "HT");
  assert.equal(result.some((match) => match.match_details_id === "future-fixture"), false);
});

test("buildTeamRankingsBaseCacheKey ignores type while response keys preserve it", () => {
  const baseOptions = {
    source: "merged",
    leagueFilter: null,
    mergedDataset: {
      updated_at: "2026-05-18T12:00:00.000Z",
      items: [
        { home_team: "Arsenal", away_team: "Burnley" },
      ],
    },
    clubEloDataset: {
      updated_at: "2026-05-18T12:00:00.000Z",
      items: [{ Club: "Arsenal" }],
    },
    footballDatabaseDataset: {
      updated_at: "2026-05-18T12:00:00.000Z",
      items: [{ Club: "Arsenal" }],
    },
    nationalEloDataset: {
      updated_at: "2026-05-18T12:00:00.000Z",
      items: [{ Team: "England" }],
    },
  };

  assert.notEqual(
    buildTeamRankingsResponseCacheKey({ ...baseOptions, type: "club" }),
    buildTeamRankingsResponseCacheKey({ ...baseOptions, type: "national" })
  );
  assert.equal(
    buildTeamRankingsBaseCacheKey({ ...baseOptions, type: "club" }),
    buildTeamRankingsBaseCacheKey({ ...baseOptions, type: "national" })
  );
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

test("dedupeMatchListPayloads collapses duplicate match ids and preserves the richest fields", () => {
  const deduped = dedupeMatchListPayloads([
    {
      date: "2026-04-04",
      time: "12:30",
      league: "FA Cup",
      league_subcategory: "Quarter-finals",
      home_team: "Manchester City",
      away_team: "Liverpool",
      match_details_id: "clydqev9y9et",
      has_bsd_source: true,
      tv_channels: ["BBC One"],
    },
    {
      date: "2026-04-04",
      time: "12:30",
      league: "FA Cup",
      home_team: "Manchester City",
      away_team: "Liverpool",
      match_details_id: "clydqev9y9et",
      home_score: 4,
      away_score: 0,
      score_status: "FT",
      tv_channels: ["BBC iPlayer"],
    },
  ]);

  assert.equal(deduped.length, 1);
  assert.equal(deduped[0].match_details_id, "clydqev9y9et");
  assert.equal(deduped[0].score_status, "FT");
  assert.equal(deduped[0].home_score, 4);
  assert.equal(deduped[0].away_score, 0);
  assert.equal(deduped[0].has_bsd_source, true);
  assert.deepEqual(deduped[0].tv_channels, ["BBC One", "BBC iPlayer"]);
  assert.equal(deduped[0].league_subcategory, "Quarter-finals");
});

test("dedupeMatchListPayloads collapses duplicate fixtures even when one row lacks a matching id", () => {
  const deduped = dedupeMatchListPayloads([
    {
      date: "2026-04-04",
      time: "12:30",
      league: "FA Cup",
      home_team: "Manchester City",
      away_team: "Liverpool",
      home_score: 4,
      away_score: 0,
      score_status: "FT",
    },
    {
      date: "2026-04-04",
      time: "12:00",
      league: "FA Cup",
      home_team: "Man City",
      away_team: "Liverpool",
      match_details_id: "clydqev9y9et",
      tv_channels: ["BBC Sport Website"],
    },
  ]);

  assert.equal(deduped.length, 1);
  assert.equal(deduped[0].match_details_id, "clydqev9y9et");
  assert.equal(deduped[0].home_score, 4);
  assert.equal(deduped[0].away_score, 0);
  assert.equal(deduped[0].score_status, "FT");
  assert.deepEqual(deduped[0].tv_channels, ["BBC Sport Website"]);
});

test("dedupeMatchListPayloads keeps same-day placeholder knockout fixtures separate", () => {
  const deduped = dedupeMatchListPayloads([
    {
      date: "2026-07-01",
      time: "02:00",
      league: "FIFA World Cup 2026",
      league_subcategory: "Round of 32",
      home_team: "Mexico",
      away_team: "Ecuador",
      match_details_id: "8365",
    },
    {
      date: "2026-07-01",
      time: "17:00",
      league: "FIFA World Cup 2026",
      league_subcategory: "Round of 32",
      home_team: "England",
      away_team: "TBC",
      match_details_id: "8366",
    },
    {
      date: "2026-07-01",
      time: "21:00",
      league: "FIFA World Cup 2026",
      league_subcategory: "Round of 32",
      home_team: "Belgium",
      away_team: "TBC",
      match_details_id: "8367",
    },
  ]);

  assert.deepEqual(
    deduped.map((match) => match.match_details_id).sort(),
    ["8365", "8366", "8367"]
  );
});

test("dedupeMatchListPayloads collapses Bundesliga alias rows and keeps the BBC live match id", () => {
  const deduped = dedupeMatchListPayloads([
    {
      date: "2026-04-19",
      time: "16:30",
      league: "Bundesliga",
      home_team: "Bayern Munich",
      away_team: "VfB Stuttgart",
      match_details_id: "syn117060f1bbf79bb5",
      home_score: 4,
      away_score: 2,
      score_status: "90",
      tv_channels: ["Amazon Prime PPV"],
    },
    {
      date: "2026-04-19",
      time: "16:30",
      league: "German Bundesliga",
      home_team: "Bayern Munich",
      away_team: "Stuttgart",
      match_details_id: "c89558d5d5nt",
      has_bsd_source: true,
      home_score: 4,
      away_score: 2,
      score_status: "FT",
    },
  ]);

  assert.equal(deduped.length, 1);
  assert.equal(deduped[0].match_details_id, "c89558d5d5nt");
  assert.equal(deduped[0].score_status, "FT");
  assert.equal(deduped[0].has_bsd_source, true);
  assert.equal(deduped[0].away_team, "Stuttgart");
});

test("dedupeMatchListPayloads collapses Serie A alias rows and keeps the BBC live match ids", () => {
  const veronaDeduped = dedupeMatchListPayloads([
    {
      date: "2026-04-19",
      time: "14:00",
      league: "Serie A",
      home_team: "Verona",
      away_team: "AC Milan",
      match_details_id: "syn7e079aaa69ff1abc",
      tv_channels: ["DAZN", "BBC Alba", "BBC iPlayer", "BBC Sport Website"],
    },
    {
      date: "2026-04-19",
      time: "14:00",
      league: "Italian Serie A",
      home_team: "Hellas Verona",
      away_team: "AC Milan",
      match_details_id: "c5yjjq5jlrmt",
      home_score: 0,
      away_score: 1,
      score_status: "FT",
      has_bsd_source: true,
    },
  ]);

  assert.equal(veronaDeduped.length, 1);
  assert.equal(veronaDeduped[0].match_details_id, "c5yjjq5jlrmt");
  assert.equal(veronaDeduped[0].league, "Italian Serie A");
  assert.equal(veronaDeduped[0].score_status, "FT");

  const pisaDeduped = dedupeMatchListPayloads([
    {
      date: "2026-04-19",
      time: "17:00",
      league: "Serie A",
      home_team: "Pisa",
      away_team: "Genoa",
      match_details_id: "synd2aa8898becc3574",
      tv_channels: ["DAZN"],
    },
    {
      date: "2026-04-19",
      time: "17:00",
      league: "Italian Serie A",
      home_team: "Pisa",
      away_team: "Genoa",
      match_details_id: "cx2vvg0v3rpt",
      home_score: 1,
      away_score: 2,
      score_status: "FT",
      has_bsd_source: true,
    },
  ]);

  assert.equal(pisaDeduped.length, 1);
  assert.equal(pisaDeduped[0].match_details_id, "cx2vvg0v3rpt");
  assert.equal(pisaDeduped[0].league, "Italian Serie A");
  assert.equal(pisaDeduped[0].score_status, "FT");
});

test("dedupeMatchListPayloads collapses La Liga and Bundesliga alias rows and keeps the BBC live match ids", () => {
  const osasunaDeduped = dedupeMatchListPayloads([
    {
      date: "2026-04-12",
      time: "13:00",
      league: "La Liga",
      home_team: "Osasuna",
      away_team: "Real Betis",
      match_details_id: "syn913f0b827e8d1aca",
      tv_channels: ["Premier Sports 2"],
    },
    {
      date: "2026-04-12",
      time: "13:00",
      league: "Spanish La Liga",
      home_team: "Osasuna",
      away_team: "Real Betis",
      match_details_id: "cx24nxnxggkt",
      home_score: 1,
      away_score: 1,
      score_status: "FT",
      has_bsd_source: true,
    },
  ]);

  assert.equal(osasunaDeduped.length, 1);
  assert.equal(osasunaDeduped[0].match_details_id, "cx24nxnxggkt");
  assert.equal(osasunaDeduped[0].score_status, "FT");
  assert.equal(osasunaDeduped[0].has_bsd_source, true);

  const stuttgartDeduped = dedupeMatchListPayloads([
    {
      date: "2026-04-12",
      time: "16:30",
      league: "Bundesliga",
      home_team: "VfB Stuttgart",
      away_team: "Hamburg",
      match_details_id: "syn0ec2a20debd46f6b",
      tv_channels: ["Amazon Prime PPV"],
    },
    {
      date: "2026-04-12",
      time: "16:30",
      league: "German Bundesliga",
      home_team: "Stuttgart",
      away_team: "Hamburger SV",
      match_details_id: "c705j1jx2y0t",
      home_score: 4,
      away_score: 0,
      score_status: "FT",
      has_bsd_source: true,
    },
  ]);

  assert.equal(stuttgartDeduped.length, 1);
  assert.equal(stuttgartDeduped[0].match_details_id, "c705j1jx2y0t");
  assert.equal(stuttgartDeduped[0].score_status, "FT");
  assert.equal(stuttgartDeduped[0].has_bsd_source, true);
});

test("isListPayloadVisibleForMode excludes future same-day fixtures from results", () => {
  const now = new Date("2026-04-04T17:45:00Z");
  assert.equal(
    isListPayloadVisibleForMode(
      {
        date: "2026-04-04",
        time: "20:00",
        home_team: "Southampton",
        away_team: "Arsenal",
        score_status: null,
      },
      "results",
      now
    ),
    false
  );

  assert.equal(
    isListPayloadVisibleForMode(
      {
        date: "2026-04-04",
        time: "17:15",
        home_team: "Chelsea",
        away_team: "Port Vale",
        score_status: "72",
      },
      "results",
      now
    ),
    true
  );
});

test("isListPayloadVisibleForMode keeps future fixtures visible without legacy BBC markers", () => {
  const now = new Date("2026-04-04T17:45:00Z");
  assert.equal(
    isListPayloadVisibleForMode(
      {
        date: "2026-04-05",
        time: "15:00",
        league: "Premier League",
        home_team: "West Ham United",
        away_team: "Wolves",
        score_status: null,
        match_details_id: "cn43ql18lg8t",
      },
      "fixtures",
      now
    ),
    true
  );
});

test("isListPayloadVisibleForMode keeps in-progress previous-day matches visible in fixtures", () => {
  const now = new Date("2026-04-05T00:20:00Z");

  assert.equal(
    isListPayloadVisibleForMode(
      {
        date: "2026-04-04",
        time: "23:00",
        home_team: "Atletico Madrid",
        away_team: "Club Brugge",
        score_status: "77",
      },
      "fixtures",
      now
    ),
    true
  );

  assert.equal(
    isListPayloadVisibleForMode(
      {
        date: "2026-04-04",
        time: "19:45",
        home_team: "Chelsea",
        away_team: "Port Vale",
        score_status: "FT",
      },
      "fixtures",
      now
    ),
    false
  );
});

test("isListPayloadVisibleForMode keeps penalty shootouts in progress visible in results", () => {
  const now = new Date("2026-04-04T17:45:00Z");
  assert.equal(
    isListPayloadVisibleForMode(
      {
        date: "2026-04-04",
        time: "17:15",
        home_team: "Atletico Madrid",
        away_team: "Real Sociedad",
        score_status: "P 0-0",
      },
      "results",
      now
    ),
    true
  );
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
    persistLiveActivityMatchTimelineSnapshotsSafe: async () => {},
    saveOperationalMatchWriteLogEntries: async () => {},
    historyMatchesById: new Map(),
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
    persistLiveActivityMatchTimelineSnapshotsSafe: async () => {},
    saveOperationalMatchWriteLogEntries: async () => {},
    historyMatchesById: new Map(),
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

test("toMatchListPayload preserves first-leg scores for running aggregates", () => {
  const payload = toMatchListPayload({
    id: "224835",
    date: "2026-08-25",
    time: "20:00",
    league: "UEFA Champions League",
    league_subcategory: "Playoff round",
    home_team: "LASK",
    away_team: "Celtic",
    home_score: 5,
    away_score: 1,
    aggregate_home_score: 5,
    aggregate_away_score: 4,
    first_leg_home_score: 0,
    first_leg_away_score: 3,
    score_status: "120",
    has_bsd_source: true,
    tv_channels: [],
  });

  assert.equal(payload.aggregate_home_score, 5);
  assert.equal(payload.aggregate_away_score, 4);
  assert.equal(payload.first_leg_home_score, 0);
  assert.equal(payload.first_leg_away_score, 3);
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

test("pickPreferredMatchStatus keeps FT over stale added-time live statuses by default", () => {
  assert.equal(pickPreferredMatchStatus("FT", "90+8"), "FT");
  assert.equal(pickPreferredMatchStatus("FT", "LIVE"), "FT");
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

test("mergeMatchDetailsPayload preserves FT when refreshed live poll regresses to added time", () => {
  const existing = normalizeMatchDetailsPayload({
    details_url: "https://www.bbc.co.uk/sport/football/live/c87wj3l13zzt",
    date: "2026-04-05",
    time: "20:00",
    league: "Spanish La Liga",
    home_team: "Alaves",
    away_team: "Osasuna",
    home_score: 2,
    away_score: 2,
    score_status: "FT",
  });

  const incoming = normalizeMatchDetailsPayload({
    details_url: "https://www.bbc.co.uk/sport/football/live/c87wj3l13zzt",
    date: "2026-04-05",
    time: "20:00",
    league: "Spanish La Liga",
    home_team: "Alaves",
    away_team: "Osasuna",
    home_score: 2,
    away_score: 2,
    score_status: "90+8",
  });

  const merged = mergeMatchDetailsPayload(existing, incoming, "2026-04-05T22:59:35.396Z");
  assert.equal(merged.score_status, "FT");
});

test("mergeMatchDetailsPayload lets BSD live state correct a stale terminal status", () => {
  const nowMs = Date.parse("2026-06-18T20:56:21.000Z");
  const existing = normalizeMatchDetailsPayload({
    id: "2461110",
    match_details_id: "2461110",
    date: "2026-06-18",
    time: "20:00",
    league: "FIFA World Cup",
    home_team: "Switzerland",
    away_team: "Bosnia-Herzegovina",
    home_score: 2,
    away_score: 0,
    score_status: "FT",
  }, { nowMs });

  const incoming = normalizeMatchDetailsPayload({
    id: "2461110",
    match_details_id: "2461110",
    date: "2026-06-18",
    time: "20:00",
    league: "FIFA World Cup",
    home_team: "Switzerland",
    away_team: "Bosnia-Herzegovina",
    home_score: 3,
    away_score: 1,
    score_status: "90+6",
    has_bsd_source: true,
  }, { nowMs });

  const merged = mergeMatchDetailsPayload(existing, incoming, "2026-06-18T20:56:21.000Z");
  assert.equal(merged.score_status, "90+6");
  assert.equal(merged.home_score, 3);
  assert.equal(merged.away_score, 1);
  assert.equal(merged.in_progress, true);
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

test("mergeConfirmedVarDisallowedGoalsIntoPayload removes stale disallowed goals from scorelines", async () => {
  clearFootballOperationalMemoryState();
  const merged = await mergeConfirmedVarDisallowedGoalsIntoPayload(
    {
      id: DETAILS_ID,
      home_team: "West Ham United",
      away_team: "Leeds United",
      home_score: 3,
      away_score: 2,
      score_status: "AET",
      home_goal_scorers: [
        {
          player: "Mateus Fernandes",
          goal_times: ["90+3'"],
          own_goal_times: [],
        },
        {
          player: "A. Disasi",
          goal_times: ["90+6'"],
          own_goal_times: [],
        },
        {
          player: "V. Castellanos",
          goal_times: ["91'"],
          own_goal_times: [],
        },
      ],
      away_goal_scorers: [
        {
          player: "A. Tanaka",
          goal_times: ["26'"],
          own_goal_times: [],
        },
        {
          player: "D. Calvert-Lewin",
          goal_times: ["75' pen"],
          own_goal_times: [],
        },
      ],
      home_assists: [
        {
          player: "A. Traoré",
          assist_times: ["90+6'", "91'"],
        },
      ],
      away_assists: [
        {
          player: "N. Okafor",
          assist_times: ["26'"],
        },
      ],
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
                scorer: "V. Castellanos",
                assister: "A. Traoré",
                goal_time: "91'",
              },
            ],
          },
        ],
      }),
    }
  );

  assert.equal(merged.home_score, 2);
  assert.equal(merged.away_score, 2);
  assert.deepStrictEqual(merged.home_goal_scorers, [
    {
      player: "Mateus Fernandes",
      goal_times: ["90+3'"],
      own_goal_times: [],
    },
    {
      player: "A. Disasi",
      goal_times: ["90+6'"],
      own_goal_times: [],
    },
    {
      player: "V. Castellanos",
      goal_times: [],
      own_goal_times: [],
      disallowed_goal_times: ["91'"],
    },
  ]);
  assert.deepStrictEqual(merged.home_assists, [
    {
      player: "A. Traoré",
      assist_times: ["90+6'", "91'"],
    },
  ]);
});

test("mergeConfirmedVarDisallowedGoalsIntoPayload removes stale disallowed goals by minute when scorer name differs", async () => {
  clearFootballOperationalMemoryState();
  const merged = await mergeConfirmedVarDisallowedGoalsIntoPayload(
    {
      id: DETAILS_ID,
      home_team: "West Ham United",
      away_team: "Leeds United",
      home_score: 3,
      away_score: 2,
      score_status: "AET",
      home_goal_scorers: [
        {
          player: "Mateus Fernandes",
          goal_times: ["90+3'"],
          own_goal_times: [],
        },
        {
          player: "A. Disasi",
          goal_times: ["90+6'"],
          own_goal_times: [],
        },
        {
          player: "Valentin Castellanos",
          goal_times: ["91'"],
          own_goal_times: [],
        },
      ],
      away_goal_scorers: [
        {
          player: "A. Tanaka",
          goal_times: ["26'"],
          own_goal_times: [],
        },
        {
          player: "D. Calvert-Lewin",
          goal_times: ["75' pen"],
          own_goal_times: [],
        },
      ],
      home_assists: [
        {
          player: "A. Traoré",
          assist_times: ["90+6'", "91'"],
        },
      ],
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
                scorer: "V. Castellanos",
                assister: "A. Traoré",
                goal_time: "91'",
              },
            ],
          },
        ],
      }),
    }
  );

  assert.equal(merged.home_score, 2);
  assert.deepStrictEqual(merged.home_goal_scorers, [
    {
      player: "Mateus Fernandes",
      goal_times: ["90+3'"],
      own_goal_times: [],
    },
    {
      player: "A. Disasi",
      goal_times: ["90+6'"],
      own_goal_times: [],
    },
    {
      player: "Valentin Castellanos",
      goal_times: [],
      own_goal_times: [],
      disallowed_goal_times: ["91'"],
    },
  ]);
});

test("mergeConfirmedVarDisallowedGoalsIntoPayloads corrects paged list payloads with shared history", async () => {
  clearFootballOperationalMemoryState();
  let loadHistoryCalls = 0;
  const merged = await mergeConfirmedVarDisallowedGoalsIntoPayloads(
    [
      {
        id: DETAILS_ID,
        home_team: "West Ham United",
        away_team: "Leeds United",
        home_score: 3,
        away_score: 2,
        score_status: "AET",
        home_goal_scorers: [
          { player: "Mateus Fernandes", goal_times: ["90+3'"], own_goal_times: [] },
          { player: "A. Disasi", goal_times: ["90+6'"], own_goal_times: [] },
          { player: "Valentin Castellanos", goal_times: ["91'"], own_goal_times: [] },
        ],
        away_goal_scorers: [
          { player: "A. Tanaka", goal_times: ["26'"], own_goal_times: [] },
          { player: "D. Calvert-Lewin", goal_times: ["75' pen"], own_goal_times: [] },
        ],
      },
      {
        id: "cothermatch001",
        home_team: "Arsenal",
        away_team: "Chelsea",
        home_score: 1,
        away_score: 0,
        score_status: "FT",
        home_goal_scorers: [{ player: "B. Saka", goal_times: ["15'"], own_goal_times: [] }],
        away_goal_scorers: [],
      },
    ],
    {
      loadHistory: async () => {
        loadHistoryCalls += 1;
        return {
          matches: [
            {
              match_id: DETAILS_ID,
              events: [
                {
                  event_type: "goal",
                  disallowed_by_var: true,
                  team: "home",
                  scorer: "V. Castellanos",
                  goal_time: "91'",
                },
              ],
            },
          ],
        };
      },
    }
  );

  assert.equal(loadHistoryCalls, 1);
  assert.equal(merged[0].home_score, 2);
  assert.equal(merged[0].away_score, 2);
  assert.equal(merged[1].home_score, 1);
  assert.equal(merged[1].away_score, 0);
});

test("mergeConfirmedVarDisallowedGoalsIntoPayloads skips shared history for upcoming fixtures", async () => {
  let loadHistoryCalls = 0;
  const timings = {};
  const payloads = [
    {
      match_details_id: DETAILS_ID,
      date: "2026-05-18",
      time: "20:00",
      home_team: "Arsenal",
      away_team: "Burnley",
    },
    {
      match_details_id: "cothermatch001",
      date: "2026-05-19",
      time: "19:30",
      home_team: "Chelsea",
      away_team: "Tottenham Hotspur",
    },
  ];

  const merged = await mergeConfirmedVarDisallowedGoalsIntoPayloads(payloads, {
    timings,
    loadHistory: async () => {
      loadHistoryCalls += 1;
      return { matches: [] };
    },
  });

  assert.equal(loadHistoryCalls, 0);
  assert.deepStrictEqual(merged, payloads);
  assert.equal(timings.var_history_candidate_count, 0);
  assert.equal(timings.var_history_skipped, true);
  assert.equal(timings.var_history_skip_reason, "no_candidate_payloads");
  assert.equal(timings.var_history_ms, 0);
  assert.equal(timings.var_apply_ms, 0);
});

test("mergeConfirmedVarDisallowedGoalsIntoPayload corrects list payloads that only carry match_details_id", async () => {
  clearFootballOperationalMemoryState();
  const merged = await mergeConfirmedVarDisallowedGoalsIntoPayload(
    {
      match_details_id: DETAILS_ID,
      home_team: "West Ham United",
      away_team: "Leeds United",
      home_score: 3,
      away_score: 2,
      score_status: "AET",
      home_goal_scorers: [
        { player: "Mateus Fernandes", goal_times: ["90+3'"], own_goal_times: [] },
        { player: "A. Disasi", goal_times: ["90+6'"], own_goal_times: [] },
        { player: "Valentin Castellanos", goal_times: ["91'"], own_goal_times: [] },
      ],
      away_goal_scorers: [
        { player: "A. Tanaka", goal_times: ["26'"], own_goal_times: [] },
        { player: "D. Calvert-Lewin", goal_times: ["75' pen"], own_goal_times: [] },
      ],
      home_assists: [
        { player: "A. Traoré", assist_times: ["91'"] },
      ],
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
                scorer: "V. Castellanos",
                assister: "A. Traoré",
                goal_time: "91'",
              },
            ],
          },
        ],
      }),
    }
  );

  assert.equal(merged.home_score, 2);
  assert.equal(merged.away_score, 2);
  assert.deepStrictEqual(merged.home_goal_scorers, [
    { player: "Mateus Fernandes", goal_times: ["90+3'"], own_goal_times: [] },
    { player: "A. Disasi", goal_times: ["90+6'"], own_goal_times: [] },
    {
      player: "Valentin Castellanos",
      goal_times: [],
      own_goal_times: [],
      disallowed_goal_times: ["91'"],
    },
  ]);
});

test("transformBbcLiveMatchWithDetails replaces transient shootout tally with confirmed AET score", () => {
  const transformed = transformBbcLiveMatchWithDetails(
    {
      home_team: "West Ham United",
      away_team: "Leeds United",
      home_score: 3,
      away_score: 2,
      match_time: "Pens",
      details_url: "https://www.bbc.co.uk/sport/football/live/c75k3rv779xt",
    },
    {
      id: "c75k3rv779xt",
      home_team: "West Ham United",
      away_team: "Leeds United",
      home_score: 2,
      away_score: 2,
      score_status: "AET",
      penalty_result: "Leeds United win 4 - 2 on penalties",
      home_goal_scorers: [
        { player: "Mateus Fernandes", goal_times: ["90+3'"], own_goal_times: [] },
        { player: "A. Disasi", goal_times: ["90+6'"], own_goal_times: [] },
      ],
      away_goal_scorers: [
        { player: "A. Tanaka", goal_times: ["26'"], own_goal_times: [] },
        { player: "D. Calvert-Lewin", goal_times: ["75' pen"], own_goal_times: [] },
      ],
    }
  );

  assert.equal(transformed.home_score, 2);
  assert.equal(transformed.away_score, 2);
  assert.equal(transformed.match_time, "AET");
  assert.equal(transformed.penalty_result, "Leeds United win 4 - 2 on penalties");
  assert.deepStrictEqual(transformed.home_goal_scorers, [
    { player: "Mateus Fernandes", goal_times: ["90+3'"], own_goal_times: [] },
    { player: "A. Disasi", goal_times: ["90+6'"], own_goal_times: [] },
  ]);
});

test("filterStaleMatches accepts a corrected scoreless kickoff fixture over stale cached scores", () => {
  const filtered = filterStaleMatches(
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

  assert.deepStrictEqual(normalized.domains, ["matches", "match_details"]);
  assert.deepStrictEqual(normalized.invalid, ["bbc", "bogus"]);
});

test("bumpCacheStateSnapshot increments only requested cache generations", () => {
  const base = buildDefaultOperationalCacheState("2026-03-08T09:00:00.000Z");
  const bumped = bumpCacheStateSnapshot(base, ["matches"], {
    updated_at: "2026-03-08T09:05:00.000Z",
    reason: "incident_fix",
    source: "admin_api",
  });

  assert.equal(bumped.domains.matches.generation, base.domains.matches.generation + 1);
  assert.equal(
    bumped.domains.match_details.generation,
    base.domains.match_details.generation
  );
  assert.equal(bumped.domains.matches.reason, "incident_fix");
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
  assert.equal(normalized.updated_at, "2026-03-08T09:10:00.000Z");
});

test("mergeClubEloFixtureMetadata keeps canonical match updated_at unchanged", () => {
  const payload = detailsPayload({
    updated_at: "2026-04-05T22:59:35.396Z",
    metadata: {
      existing: true,
    },
  });

  const merged = mergeClubEloFixtureMetadata(
    payload,
    {
      date: "2026-04-06",
      country: "Spain",
      home_team: "Alaves",
      away_team: "Osasuna",
    },
    {
      confidence: 0.93,
      minTeamConfidence: 0.88,
    },
    "2026-04-05T23:15:31.552Z",
    "https://clubelo.example/fixtures"
  );

  assert.equal(merged.updated_at, "2026-04-05T22:59:35.396Z");
  assert.equal(
    merged.metadata.club_elo_fixture_probabilities.updated_at,
    "2026-04-05T23:15:31.552Z"
  );
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

test("toMatchListPayload ignores incompatible match details payloads and leaves the fixture unhydrated", () => {
  const payload = toMatchListPayload(
    {
      date: "2026-04-04",
      time: "19:45",
      league: "Premier League",
      home_team: "Southampton",
      away_team: "Arsenal",
      details_url: "https://www.bbc.co.uk/sport/football/live/clydqev9y9et",
      home_score: null,
      away_score: null,
      score_status: null,
      tv_channels: ["Sky Sports Main Event"],
    },
    {
      matchDetailsLookup: {
        clydqev9y9et: {
          id: "clydqev9y9et",
          date: "2026-04-04",
          time: "12:30",
          league: "FA Cup",
          home_team: "Manchester City",
          away_team: "Liverpool",
          home_score: 4,
          away_score: 0,
          score_status: "FT",
        },
      },
    }
  );

  assert.equal(payload.match_details_id, undefined);
  assert.equal(payload.home_score, undefined);
  assert.equal(payload.away_score, undefined);
  assert.equal(payload.score_status, undefined);
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
    nowMs: Date.parse("2026-03-22T16:50:00.000Z"),
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

test("toMatchListPayload prefers fresher BSD live list state over stale details FT", () => {
  const payload = toMatchListPayload(
    {
      id: "2461110",
      match_details_id: "2461110",
      date: "2026-06-18",
      time: "20:00",
      league: "FIFA World Cup",
      home_team: "Switzerland",
      away_team: "Bosnia-Herzegovina",
      home_score: 3,
      away_score: 1,
      score_status: "90+6",
      has_bsd_source: true,
      updated_at: "2026-06-18T20:56:21.000Z",
    },
    {
      matchDetailsLookup: {
        2461110: {
          id: "2461110",
          date: "2026-06-18",
          time: "20:00",
          league: "FIFA World Cup",
          home_team: "Switzerland",
          away_team: "Bosnia-Herzegovina",
          home_score: 2,
          away_score: 0,
          score_status: "FT",
          updated_at: "2026-06-18T20:03:00.000Z",
        },
      },
      nowMs: Date.parse("2026-06-18T20:58:00.000Z"),
    }
  );

  assert.equal(payload.score_status, "90+6");
  assert.equal(payload.home_score, 3);
  assert.equal(payload.away_score, 1);
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

test("buildMonitorCandidatesForDate overlays BBC live state when merged details lag behind", () => {
  const candidates = buildMonitorCandidatesForDate(
    "2026-04-04",
    [
      {
        date: "2026-04-04",
        time: "17:30",
        league: "FA Cup",
        home_team: "Chelsea",
        away_team: "Port Vale",
        tv_channels: ["BBC One"],
        match_details_id: "clyew9r7jdet",
      },
    ],
    {
      clyew9r7jdet: {
        id: "clyew9r7jdet",
        date: "2026-04-04",
        time: "17:30",
        league: "FA Cup",
        home_team: "Chelsea",
        away_team: "Port Vale",
        updated_at: "2026-04-04T17:40:00.000Z",
      },
    },
    {
      bbcMatches: [
        {
          home_team: "Chelsea",
          away_team: "Port Vale",
          home_score: 2,
          away_score: 0,
          match_time: "42",
        },
      ],
      now: new Date("2026-04-04T18:12:00.000Z"),
    }
  );

  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].match_details_id, "clyew9r7jdet");
  assert.equal(candidates[0].score_status, "42");
  assert.equal(candidates[0].home_score, 2);
  assert.equal(candidates[0].away_score, 0);
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

test("resolveStableMatchScoreStatus converts stale live-looking statuses without kickoff metadata to FT", () => {
  const scoreStatus = resolveStableMatchScoreStatus(
    {
      home_score: 1,
      away_score: 0,
      score_status: "74",
      updated_at: "2026-03-07T12:15:00.000Z",
    },
    {
      nowMs: Date.parse("2026-03-07T15:30:00.000Z"),
    }
  );

  assert.equal(scoreStatus, "FT");
});

test("markMatchDetailsActive enables short-lived refresh tracking for requested ids", () => {
  assert.equal(markMatchDetailsActive(DETAILS_ID), true);
  assert.equal(isMatchDetailsActive(DETAILS_ID), true);
  assert.equal(markMatchDetailsActive("not-valid!"), false);
  assert.equal(isMatchDetailsActive("not-valid!"), false);
});

test("collectInProgressMatchDetailTargets includes live matches without active refresh markers", () => {
  clearFootballOperationalMemoryState();
  const kickoff = kickoffWithinLiveWindow();

  upsertMatchDetailsFromMatch(
    baseMatch({
      ...kickoff,
      details_url: DETAILS_URL,
      score_status: "111",
      home_score: 2,
      away_score: 2,
      has_bsd_source: true,
    }),
    new Date(Date.now() - 5 * 60 * 1000).toISOString()
  );

  const targets = collectInProgressMatchDetailTargets();
  assert.deepStrictEqual(
    targets.map((target) => ({ id: target.id, details_url: target.seed_match.details_url })),
    [{ id: DETAILS_ID, details_url: DETAILS_URL }]
  );

  clearFootballOperationalMemoryState();
});

test("collectInProgressMatchDetailTargets keeps finished enrichment polling behind the active window", () => {
  clearFootballOperationalMemoryState();
  const kickoff = kickoffWithinLiveWindow();

  upsertMatchDetailsFromMatch(
    baseMatch({
      ...kickoff,
      details_url: DETAILS_URL,
      score_status: "FT",
      home_score: 1,
      away_score: 0,
      home_goal_scorers: [],
      away_goal_scorers: [],
    }),
    "2026-03-03T21:30:00.000Z"
  );

  assert.deepStrictEqual(collectInProgressMatchDetailTargets(), []);

  assert.equal(markMatchDetailsActive(DETAILS_ID), true);
  assert.deepStrictEqual(
    collectInProgressMatchDetailTargets().map((target) => target.id),
    [DETAILS_ID]
  );

  clearFootballOperationalMemoryState();
});

test("collectInProgressMatchDetailTargets excludes stale live records with missing kickoff metadata", () => {
  clearFootballOperationalMemoryState();

  upsertMatchDetailsFromMatch(
    baseMatch({
      details_url: DETAILS_URL,
      date: null,
      time: null,
      score_status: "74",
      home_score: 1,
      away_score: 0,
      has_bsd_source: true,
    }),
    "2026-03-03T12:15:00.000Z"
  );

  assert.deepStrictEqual(collectInProgressMatchDetailTargets(), []);

  clearFootballOperationalMemoryState();
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

test("matchDetailsNeedsBackfill refreshes cached records with one-sided parsed team lineups", () => {
  const malformedLineups = {
    home: {
      team: "Canada",
      starting_lineup: [],
      substitutes: [],
      substitutions: [],
    },
    away: {
      team: "Bosnia-Herzegovina",
      starting_lineup: Array.from({ length: 22 }, (_, index) => ({
        number: index + 1,
        name: `Player ${index + 1}`,
        position_category: index === 0 ? "goalkeeper" : "midfielder",
      })),
      substitutes: [],
      substitutions: [],
    },
  };

  assert.equal(hasRenderableTeamLineups(malformedLineups), false);
  assert.equal(
    matchDetailsNeedsBackfill({
      id: "2461104",
      date: "2026-06-12",
      time: "20:00",
      league: "FIFA World Cup 2026",
      home_team: "Canada",
      away_team: "Bosnia-Herzegovina",
      home_score: 1,
      away_score: 1,
      score_status: "FT",
      team_lineups: malformedLineups,
    }),
    true
  );
});

test("matchDetailsNeedsBackfill accepts renderable non-11v11 lineups", () => {
  assert.equal(
    matchDetailsNeedsBackfill({
      id: "2461104",
      date: "2026-06-12",
      time: "20:00",
      league: "FIFA World Cup 2026",
      home_team: "Canada",
      away_team: "Bosnia-Herzegovina",
      home_score: 0,
      away_score: 0,
      score_status: "FT",
      team_lineups: {
        home: {
          team: "Canada",
          starting_lineup: [{
            number: 1,
            name: "Canada Player",
            id_player: "1001",
            position_category: "goalkeeper",
          }],
          substitutes: [],
          substitutions: [],
        },
        away: {
          team: "Bosnia-Herzegovina",
          starting_lineup: [{ number: 1, name: "Bosnia Player", position_category: "goalkeeper" }],
          substitutes: [],
          substitutions: [],
        },
      },
    }),
    false
  );
});

test("matchDetailsNeedsBackfill refreshes BSD lineups missing player ids", () => {
  assert.equal(
    matchDetailsNeedsBackfill({
      id: "2461104",
      date: "2026-06-12",
      time: "20:00",
      league: "FIFA World Cup 2026",
      home_team: "Canada",
      away_team: "Bosnia-Herzegovina",
      home_score: 1,
      away_score: 1,
      score_status: "FT",
      team_lineups: {
        home: {
          team: "Canada",
          starting_lineup: [{ number: 1, name: "Canada Player", position_category: "goalkeeper" }],
          substitutes: [],
          substitutions: [],
        },
        away: {
          team: "Bosnia-Herzegovina",
          starting_lineup: [{
            number: 1,
            name: "Bosnia Player",
            id_player: "2001",
            position_category: "goalkeeper",
          }],
          substitutes: [],
          substitutions: [],
        },
      },
    }),
    true
  );
});

test("matchDetailsNeedsBackfill refreshes resolvable substitution players missing ids", () => {
  assert.equal(
    matchDetailsNeedsBackfill({
      id: "2461104",
      date: "2026-06-13",
      time: "20:00",
      league: "FIFA World Cup 2026",
      home_team: "USA",
      away_team: "Paraguay",
      home_score: 4,
      away_score: 1,
      score_status: "FT",
      team_lineups: {
        home: {
          team: "USA",
          starting_lineup: [
            { number: 8, name: "Malik Tillman", id_player: "1008", position_category: "midfielder" },
          ],
          substitutes: [
            { number: 7, name: "Giovanni Reyna", id_player: "34170047", cutout_url: "https://example.test/reyna.png" },
          ],
          substitutions: [
            {
              minute: "82'",
              player_off: { number: 8, name: "Malik Tillman", id_player: "1008" },
              player_on: { number: null, name: "Reyna" },
            },
          ],
        },
        away: {
          team: "Paraguay",
          starting_lineup: [
            { number: 1, name: "Paraguay Player", id_player: "2001", position_category: "goalkeeper" },
          ],
          substitutes: [],
          substitutions: [],
        },
      },
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
    tv_channels: [],
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
        substitutes: [
          { number: 12, name: "Home Sub 1", id_player: null, position: null, position_short: null, cutout_url: null },
        ],
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
        substitutes: [
          { number: 40, name: "Away Sub 1", id_player: null, position: null, position_short: null, cutout_url: null },
        ],
        substitutions: [],
      },
    },
  });
});
