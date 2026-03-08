const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    toMatchListPayload,
    toMonitorCandidateFromDetailsPayload,
    mergeMonitorCandidate,
    buildMonitorCandidatesForDate,
    buildFallbackMatchDetailsPayload,
    matchDetailsNeedsBackfill,
    markMatchDetailsActive,
    isMatchDetailsActive,
    normalizeMatchDetailsPayload,
    mergeMatchDetailsPayload,
    resolveStableMatchScoreStatus,
    withStableMatchDetailsState,
    filterStaleBbcMatches,
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
  const buildStarter = (number, name, position_category) => ({
    number,
    name,
    position_category,
  });

  return {
    home: {
      team: "Wolverhampton Wanderers",
      manager: "Vitor Pereira",
      formation: "4-3-3",
      starting_lineup: [
        buildStarter(1, "J. Sa", "goalkeeper"),
        buildStarter(2, "M. Doherty", "defender"),
        buildStarter(4, "S. Bueno", "defender"),
        buildStarter(12, "E. Agbadou", "defender"),
        buildStarter(24, "Toti Gomes", "defender"),
        buildStarter(3, "R. Ait-Nouri", "midfielder"),
        buildStarter(7, "André", "midfielder"),
        buildStarter(8, "João Gomes", "midfielder"),
        buildStarter(5, "M. Munetsi", "midfielder"),
        buildStarter(10, "Matheus Cunha", "attacker"),
        buildStarter(9, "J. Strand Larsen", "attacker"),
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
        buildStarter(1, "Alisson", "goalkeeper"),
        buildStarter(84, "C. Bradley", "defender"),
        buildStarter(5, "I. Konaté", "defender"),
        buildStarter(4, "V. van Dijk", "defender"),
        buildStarter(26, "A. Robertson", "defender"),
        buildStarter(38, "R. Gravenberch", "midfielder"),
        buildStarter(10, "A. Mac Allister", "midfielder"),
        buildStarter(11, "Mohamed Salah", "attacker"),
        buildStarter(8, "D. Szoboszlai", "midfielder"),
        buildStarter(18, "C. Gakpo", "attacker"),
        buildStarter(20, "Diogo Jota", "attacker"),
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

test("toMatchListPayload upgrades status from match details by match id despite team alias mismatch", () => {
  const payload = toMatchListPayload(baseMatch(), {
    matchDetailsLookup: {
      [DETAILS_ID]: detailsPayload(),
    },
  });

  assert.equal(payload.match_details_id, DETAILS_ID);
  assert.equal(payload.score_status, "FT");
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
    home_red_cards: [],
    away_red_cards: [],
    team_lineups: {
      home: {
        team: "Mansfield Town",
        manager: "Nigel Clough",
        formation: "3-5-2",
        starting_lineup: Array.from({ length: 11 }, (_, index) => ({
          number: index + 1,
          name: `Home Player ${index + 1}`,
          position_category: index === 0 ? "goalkeeper" : index < 5 ? "defender" : index < 9 ? "midfielder" : "attacker",
        })),
        substitutes: [{ number: 12, name: "Home Sub 1" }],
        substitutions: [],
      },
      away: {
        team: "Arsenal",
        manager: "Mikel Arteta",
        formation: "3-5-1-1",
        starting_lineup: Array.from({ length: 11 }, (_, index) => ({
          number: index + 20,
          name: `Away Player ${index + 1}`,
          position_category: index === 0 ? "goalkeeper" : index < 4 ? "defender" : index < 9 ? "midfielder" : "attacker",
        })),
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
    home_red_cards: [],
    away_red_cards: [],
    team_lineups: {
      home: {
        team: "Mansfield Town",
        manager: "Nigel Clough",
        formation: "3-5-2",
        starting_lineup: Array.from({ length: 11 }, (_, index) => ({
          number: index + 1,
          name: `Home Player ${index + 1}`,
          position_category: index === 0 ? "goalkeeper" : index < 5 ? "defender" : index < 9 ? "midfielder" : "attacker",
        })),
        substitutes: [{ number: 12, name: "Home Sub 1" }],
        substitutions: [],
      },
      away: {
        team: "Arsenal",
        manager: "Mikel Arteta",
        formation: "3-5-1-1",
        starting_lineup: Array.from({ length: 11 }, (_, index) => ({
          number: index + 20,
          name: `Away Player ${index + 1}`,
          position_category: index === 0 ? "goalkeeper" : index < 4 ? "defender" : index < 9 ? "midfielder" : "attacker",
        })),
        substitutes: [{ number: 40, name: "Away Sub 1" }],
        substitutions: [],
      },
    },
  });
});
