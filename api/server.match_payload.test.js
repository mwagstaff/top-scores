const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    toMatchListPayload,
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
  assert.equal(payload.score_status, "FT");
});

test("toMatchListPayload does not overwrite scoreline when match details teams do not exactly match", () => {
  const payload = toMatchListPayload(baseMatch(), {
    matchDetailsLookup: {
      [DETAILS_ID]: detailsPayload(),
    },
  });

  assert.equal(payload.home_score, 0);
  assert.equal(payload.away_score, 0);
});

test("toMatchListPayload still merges scoreline when match details teams exactly match", () => {
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
