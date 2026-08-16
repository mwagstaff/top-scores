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
  assert.equal(__private.normalizeTeamName("  Wagstaff   Wanderers  "), "Wagstaff Wanderers");
  assert.equal(__private.normalizeTeamName("A".repeat(41)), null);
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

test("admin test email is a simple transactional delivery check", () => {
  const message = __private.testEmailMessage(new Date("2026-08-16T14:30:00.000Z"));
  assert.equal(message.subject, "Goal Guesser delivery check");
  assert.match(message.body, /requested from the Goal Guesser admin area/);
  assert.match(message.body, /16 Aug 2026, 14:30 UTC/);
  assert.doesNotMatch(message.body, /href=|https?:\/\/|unsubscribe|limited time|act now/i);
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

test("league cards replace a pick score instead of stacking with its Power Pick", () => {
  const exactPower = { points: 24, base_points: 12, power_pick: true, score_tier: "exact" };
  assert.equal(__private.cardPointsForPick(exactPower, { type: "triple_threat" }), 36);
  assert.equal(__private.cardPointsForPick(exactPower, { type: "exacta" }), 22);
  assert.equal(__private.cardPointsForPick(exactPower, { type: "all_or_nothing" }), 24);
  assert.equal(__private.cardPointsForPick({ points: 3, base_points: 3, score_tier: "result" }, { type: "all_or_nothing" }), 0);
  assert.equal(__private.cardPointsForPick({ points: 5, base_points: 5, score_tier: "result_and_team_score" }, { type: "wildcard" }), 10);
});

test("monthly championships group every fixture in a calendar month", () => {
  const fixtures = [
    { pick_week_id: "2026-08-21", kickoff_at: "2026-08-21T19:00:00.000Z" },
    { pick_week_id: "2026-08-28", kickoff_at: "2026-08-28T19:00:00.000Z" },
    { pick_week_id: "2026-09-04", kickoff_at: "2026-09-04T19:00:00.000Z" },
  ];
  assert.deepEqual(__private.monthlyChampionships(fixtures).map((month) => [month.id, month.weeks.length]), [["month-2026-08", 2], ["month-2026-09", 1]]);
});

test("Momentum requires two recent scores above the player's own baseline", () => {
  const fixtures = Array.from({ length: 6 }, (_, index) => ({ _id: `f${index}`, pick_week_id: `week-${index}`, kickoff_at: `2026-09-${String(index + 1).padStart(2, "0")}T12:00:00.000Z`, result_revision: "final" }));
  const fixtureById = new Map(fixtures.map((fixture) => [fixture._id, fixture]));
  const picks = [8, 10, 12, 10, 19, 20].map((points, index) => ({ player_id: "player", fixture_id: `f${index}`, points }));
  const momentum = __private.momentumForMembership({ player_id: "player", scoring_from: "2026-01-01T00:00:00.000Z" }, picks, fixtureById, __private.completedWeeks(fixtures));
  assert.deepEqual(momentum, { player_id: "player", baseline: 10, latest: 20, streak: 2, eligible: true });
});

test("rival duels pair neighbours and never award a winner for a tie", () => {
  const rows = [{ player_id: "a", name: "A" }, { player_id: "b", name: "B" }, { player_id: "c", name: "C" }];
  const duels = __private.rivalDuels(rows, new Map([["a", 12], ["b", 12], ["c", 20]]), "week");
  assert.equal(duels.length, 1);
  assert.equal(duels[0].winner_player_id, null);
});

test("gameplay summary exposes weekly rank, badges, and movement around the viewer", () => {
  const memberships = ["a", "b", "c", "d"].map((player_id) => ({ player_id, scoring_from: "2026-01-01T00:00:00.000Z" }));
  const names = new Map([["a", "Alex"], ["b", "Billie"], ["c", "Casey"], ["d", "Drew"]]);
  const fixtures = [
    { _id: "w1", pick_week_id: "2026-08-21", kickoff_at: "2026-08-21T19:00:00.000Z", result_revision: "final" },
    { _id: "w2", pick_week_id: "2026-08-28", kickoff_at: "2026-08-28T19:00:00.000Z", result_revision: "final" },
  ];
  const picks = [
    ["a", "w1", 10, "result"], ["b", "w1", 5, "result_and_team_score"], ["c", "w1", 1, "team_score"], ["d", "w1", 0, "none"],
    ["a", "w2", 0, "none"], ["b", "w2", 12, "exact"], ["c", "w2", 3, "result"], ["d", "w2", 0, "none"],
  ].map(([player_id, fixture_id, points, score_tier]) => ({ player_id, fixture_id, points, base_points: points, score_tier }));
  const summary = __private.gameplaySummary({ memberships, names, picks, fixtures, cards: [], viewerId: "b" });
  assert.deepEqual(summary.viewer, { player_id: "b", total_points: 17, exact_scores: 1, position: 1, previous_position: 2, movement: 1, player_count: 4, last_week_id: "2026-08-28", last_week_points: 12 });
  assert.equal(summary.table_snapshot.find((row) => row.player_id === "b").movement, 1);
  assert.deepEqual(summary.weekly_performance.at(-1).badges.map((badge) => badge.label), ["Best in class!", "Top 3!", "Exact score"]);
});

test("fixture responses expose the card-adjusted points awarded for a result", () => {
  const response = __private.fixtureResponse(
    { _id: "fixture", kickoff_at: "2026-08-21T19:00:00.000Z" },
    { home_score: 2, away_score: 1, points: 12, base_points: 12, score_tier: "exact", updated_at: "now" },
    Date.parse("2026-08-22T00:00:00.000Z"),
    true,
    { type: "triple_threat" }
  );
  assert.equal(response.pick.awarded_points, 36);
  assert.equal(response.pick.applied_card_type, "triple_threat");
});

test("admin access requires an allowlisted verified email", () => {
  __private.configureAdminEmails(" mike.wagstaff@gmail.com,second@example.com ");
  assert.equal(__private.isAdminPlayer({ email: "MIKE.WAGSTAFF@gmail.com", email_verified: true }), true);
  assert.equal(__private.isAdminPlayer({ email: "mike.wagstaff@gmail.com", email_verified: false }), false);
  assert.equal(__private.isAdminPlayer({ email: "someone@example.com", email_verified: true }), false);
  __private.configureAdminEmails(undefined);
});

test("admin middleware rejects direct API access from non-admin players", () => {
  __private.configureAdminEmails("mike.wagstaff@gmail.com");
  let status = 0;
  let message = null;
  let nextCalled = false;
  const response = { status(value) { status = value; return this; }, json(value) { message = value; return this; } };
  __private.requireAdmin({ goalGuesser: { player: { email: "member@example.com", email_verified: true } } }, response, () => { nextCalled = true; });
  assert.equal(status, 403);
  assert.deepEqual(message, { error: "Goal Guesser administrator access required" });
  assert.equal(nextCalled, false);
  __private.requireAdmin({ goalGuesser: { player: { email: "mike.wagstaff@gmail.com", email_verified: true } } }, response, () => { nextCalled = true; });
  assert.equal(nextCalled, true);
  __private.configureAdminEmails(undefined);
});

test("fixture scope queries keep simulated and live seasons separate", () => {
  assert.deepEqual(__private.fixtureScopeQuery("simulation-1", { pick_week_id: "week-1" }), { competition: "Premier League", simulation_id: "simulation-1", pick_week_id: "week-1" });
  assert.deepEqual(__private.fixtureScopeQuery(null), { competition: "Premier League", simulation_id: { $exists: false } });
});

test("team logo references resolve membership overrides before player defaults", () => {
  assert.equal(__private.resolvedTeamLogoReference({ team_logo_asset_id: "player-logo" }, { team_logo_asset_id: "league-logo" }).asset_id, "league-logo");
  assert.equal(__private.resolvedTeamLogoReference({ team_logo_asset_id: "player-logo" }, {}).asset_id, "player-logo");
  assert.equal(__private.resolvedTeamLogoReference({}, {}), null);
});
