const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    toMatchListPayload,
    toMonitorCandidateFromDetailsPayload,
    mergeMonitorCandidate,
    matchDetailsNeedsBackfill,
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

test("toMatchListPayload upgrades status from match details by match id despite team alias mismatch", () => {
  const payload = toMatchListPayload(baseMatch(), {
    matchDetailsLookup: {
      [DETAILS_ID]: detailsPayload(),
    },
  });

  assert.equal(payload.match_details_id, DETAILS_ID);
  assert.equal(payload.score_status, undefined);
});

test("toMatchListPayload omits score fields even when list match has scores", () => {
  const payload = toMatchListPayload(baseMatch(), {
    matchDetailsLookup: {
      [DETAILS_ID]: detailsPayload(),
    },
  });

  assert.equal(payload.home_score, undefined);
  assert.equal(payload.away_score, undefined);
  assert.equal(payload.aggregate_home_score, undefined);
  assert.equal(payload.aggregate_away_score, undefined);
  assert.equal(payload.penalty_result, undefined);
});

test("toMatchListPayload omits score fields even when details teams exactly match", () => {
  const payload = toMatchListPayload(baseMatch(), {
    matchDetailsLookup: {
      [DETAILS_ID]: detailsPayload({
        home_team: "Wolves",
      }),
    },
  });

  assert.equal(payload.score_status, undefined);
  assert.equal(payload.home_score, undefined);
  assert.equal(payload.away_score, undefined);
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
