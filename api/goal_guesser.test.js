"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  scorePrediction,
  pickWeekIdForDate,
  seasonKeyForDate,
  isFinalStatus,
  __private,
} = require("./goal_guesser");

test("scorePrediction applies the highest scoring tier", () => {
  assert.deepEqual(scorePrediction(2, 1, 2, 1), { points: 12, tier: "exact" });
  assert.deepEqual(scorePrediction(2, 0, 2, 1), { points: 5, tier: "result_and_team_score" });
  assert.deepEqual(scorePrediction(3, 0, 2, 1), { points: 3, tier: "result" });
  assert.deepEqual(scorePrediction(2, 2, 2, 1), { points: 1, tier: "team_score" });
  assert.deepEqual(scorePrediction(0, 2, 2, 1), { points: 0, tier: "none" });
});

test("scorePrediction doubles every Power Pick tier", () => {
  assert.equal(scorePrediction(2, 1, 2, 1, true).points, 24);
  assert.equal(scorePrediction(2, 0, 2, 1, true).points, 10);
  assert.equal(scorePrediction(3, 0, 2, 1, true).points, 6);
  assert.equal(scorePrediction(2, 2, 2, 1, true).points, 2);
});

test("Friday through Thursday share a stable pick week", () => {
  assert.equal(pickWeekIdForDate("2026-08-21"), "2026-08-21");
  assert.equal(pickWeekIdForDate("2026-08-24"), "2026-08-21");
  assert.equal(pickWeekIdForDate("2026-08-27"), "2026-08-21");
  assert.equal(pickWeekIdForDate("2026-08-28"), "2026-08-28");
  assert.equal(pickWeekIdForDate("2026-03-29"), "2026-03-27");
  assert.equal(pickWeekIdForDate("2026-10-25"), "2026-10-23");
});

test("season keys cross the calendar year", () => {
  assert.equal(seasonKeyForDate("2026-08-21"), "2026-27");
  assert.equal(seasonKeyForDate("2027-02-10"), "2026-27");
});

test("final statuses are intentionally narrow", () => {
  assert.equal(isFinalStatus("FT"), true);
  assert.equal(isFinalStatus("Finished"), true);
  assert.equal(isFinalStatus("AET"), true);
  assert.equal(isFinalStatus("Pens"), true);
  assert.equal(isFinalStatus("Postponed"), false);
  assert.equal(isFinalStatus("Abandoned"), false);
});

test("credential hashes verify without retaining plaintext", () => {
  const stored = __private.secretDigest("a secret");
  assert.equal(__private.secretMatches("a secret", stored), true);
  assert.equal(__private.secretMatches("wrong", stored), false);
  assert.equal(Object.values(stored).includes("a secret"), false);
});

test("names are normalized and bounded", () => {
  assert.equal(__private.normalizeName("  Mike   W  "), "Mike W");
  assert.equal(__private.normalizeName(""), null);
  assert.equal(__private.normalizeLeagueName("A".repeat(41)), null);
});

test("email identities are normalized without accepting malformed addresses", () => {
  assert.equal(__private.normalizeEmail("  Mike.Example@Example.COM "), "mike.example@example.com");
  assert.equal(__private.normalizeEmail("missing-at.example.com"), null);
  assert.equal(__private.normalizeEmail("two@@example.com"), null);
  assert.equal(__private.normalizeEmail("a@localhost"), null);
});

test("Plunk login email uses the server-side key and an idempotency key", async () => {
  const previousKey = process.env.PLUNK_SECRET_KEY;
  const previousFrom = process.env.GOAL_GUESSER_EMAIL_FROM;
  const previousFetch = global.fetch;
  process.env.PLUNK_SECRET_KEY = "sk_test_only";
  process.env.GOAL_GUESSER_EMAIL_FROM = "goal-guesser@example.com";
  try {
    global.fetch = async (url, options) => {
      assert.equal(url, "https://next-api.useplunk.com/v1/send");
      assert.equal(options.method, "POST");
      assert.equal(options.headers.authorization, "Bearer sk_test_only");
      assert.equal(options.headers["idempotency-key"], "goal-guesser-login-challenge");
      assert.deepEqual(JSON.parse(options.body), {
        to: "player@example.com",
        from: { name: "Goal Guesser", email: "goal-guesser@example.com" },
        subject: "Your code",
        body: "<p>123456</p>",
      });
      return { ok: true, json: async () => ({ success: true, data: {} }) };
    };
    assert.equal(await __private.sendPlunkEmail({
      to: "player@example.com",
      subject: "Your code",
      body: "<p>123456</p>",
      idempotencyKey: "goal-guesser-login-challenge",
    }), true);
  } finally {
    global.fetch = previousFetch;
    if (previousKey === undefined) delete process.env.PLUNK_SECRET_KEY; else process.env.PLUNK_SECRET_KEY = previousKey;
    if (previousFrom === undefined) delete process.env.GOAL_GUESSER_EMAIL_FROM; else process.env.GOAL_GUESSER_EMAIL_FROM = previousFrom;
  }
});

test("fixture filtering accepts only the canonical Premier League label", () => {
  assert.equal(__private.isPremierLeagueMatch({ league: "Premier League" }), true);
  assert.equal(__private.isPremierLeagueMatch({ league: "Championship" }), false);
  assert.equal(__private.isPremierLeagueMatch({ league: "premier league" }), false);
  assert.equal(__private.isPremierLeagueMatch({ league: "Premier League Cup" }), false);
});

test("missing final scores never become zero-zero", () => {
  assert.equal(__private.integerScore(null), null);
  assert.equal(__private.integerScore(""), null);
  assert.equal(__private.integerScore("2"), 2);
  assert.equal(__private.integerScore("2.5"), null);
});

test("leaderboard uses competition ranking with shared positions", () => {
  const rows = __private.rankLeaderboard([
    { name: "C", points: 12, exact_scores: 1, correct_results: 1 },
    { name: "A", points: 18, exact_scores: 1, correct_results: 3 },
    { name: "B", points: 12, exact_scores: 1, correct_results: 1 },
    { name: "D", points: 12, exact_scores: 0, correct_results: 4 },
  ]);
  assert.deepEqual(rows.map((row) => [row.name, row.position]), [["A", 1], ["B", 2], ["C", 2], ["D", 4]]);
});

test("test-only virtual time controls server locking without changing the client clock", () => {
  const previousEnvironment = process.env.NODE_ENV;
  process.env.NODE_ENV = "test";
  try {
    __private.setGoalGuesserTestNow("2026-08-14T20:00:00.000Z");
    assert.equal(__private.currentTimeMs(), Date.parse("2026-08-14T20:00:00.000Z"));
    assert.equal(__private.fixtureResponse({ _id: "fixture", kickoff_at: "2026-08-14T19:30:00.000Z" }).locked, true);
    assert.equal(__private.fixtureResponse({ _id: "fixture", kickoff_at: "2026-08-21T19:30:00.000Z" }).locked, false);
  } finally {
    __private.setGoalGuesserTestNow(null);
    if (previousEnvironment === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = previousEnvironment;
  }
});

test("a pick week locks every scorecard row at its first scheduled kickoff", () => {
  const fixtures = [
    { _id: "first", pick_week_id: "2026-08-21", kickoff_at: "2026-08-21T18:30:00.000Z" },
    { _id: "later", pick_week_id: "2026-08-21", kickoff_at: "2026-08-23T15:00:00.000Z" },
  ];
  const locks = __private.pickWeekLockTimes(fixtures);
  const nowMs = Date.parse("2026-08-21T18:31:00.000Z");
  assert.equal(locks.get("2026-08-21"), Date.parse(fixtures[0].kickoff_at));
  assert.equal(__private.fixtureResponse(fixtures[1], null, nowMs, locks.get("2026-08-21") <= nowMs).locked, true);
});
