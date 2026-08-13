"use strict";

const crypto = require("crypto");
const { getDb } = require("./mongo_client");
const { scorePrediction, pickWeekIdForDate, seasonKeyForDate, __private } = require("./goal_guesser");

const PREFIX = "/api/v1/goal-guesser-test";
const PREMIER_LEAGUE = "Premier League";
const GG_COLLECTIONS = [
  "gg_sessions",
  "gg_memberships",
  "gg_picks",
  "gg_league_cards",
  "gg_wildcards",
  "gg_admin_audit_events",
  "gg_simulation_runs",
  "gg_leagues",
  "gg_fixtures",
  "gg_contests",
  "gg_players",
  "gg_harness_runs",
];

function normalizeDate(value) {
  const match = String(value || "").match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) return null;
  const date = new Date(`${value}T12:00:00.000Z`);
  return Number.isFinite(date.getTime()) ? date.toISOString().slice(0, 10) : null;
}

function addDays(dateString, days) {
  const date = new Date(`${dateString}T12:00:00.000Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

function mulberry32(seed) {
  let value = Number(seed) >>> 0;
  return () => {
    value += 0x6d2b79f5;
    let next = value;
    next = Math.imul(next ^ (next >>> 15), next | 1);
    next ^= next + Math.imul(next ^ (next >>> 7), next | 61);
    return ((next ^ (next >>> 14)) >>> 0) / 4294967296;
  };
}

function slug(value) {
  return String(value || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
}

function firstFriday(dateString) {
  const normalized = normalizeDate(dateString);
  if (!normalized) return null;
  const friday = pickWeekIdForDate(normalized);
  return friday === normalized ? normalized : addDays(friday, 7);
}

function roundRobinRounds(teams) {
  if (!Array.isArray(teams) || teams.length < 2 || teams.length % 2 !== 0) {
    throw new Error("An even number of at least two teams is required");
  }
  const rotation = [...teams];
  const rounds = [];
  for (let round = 0; round < teams.length - 1; round += 1) {
    const fixtures = [];
    for (let index = 0; index < teams.length / 2; index += 1) {
      const left = rotation[index];
      const right = rotation[rotation.length - 1 - index];
      const swap = (round + index) % 2 === 1;
      fixtures.push({ home: swap ? right : left, away: swap ? left : right });
    }
    rounds.push(fixtures);
    rotation.splice(1, 0, rotation.pop());
  }
  return [...rounds, ...rounds.map((fixtures) => fixtures.map(({ home, away }) => ({ home: away, away: home })))];
}

function generateSeason({ teams, startDate, seed = 20260801, runId = crypto.randomUUID() }) {
  const friday = firstFriday(startDate);
  if (!friday) throw new Error("start_date must use YYYY-MM-DD");
  const random = mulberry32(seed);
  const rounds = roundRobinRounds(teams);
  const seasonKey = seasonKeyForDate(friday);
  const contestId = `premier-league:${seasonKey}:score-picks`;
  const times = ["19:30", "12:30", "15:00", "15:00", "17:30", "14:00", "16:30", "20:00", "20:00", "20:00"];
  const dayOffsets = [0, 1, 1, 1, 1, 2, 2, 3, 3, 3];
  const now = new Date().toISOString();
  const fixtures = [];
  rounds.forEach((matches, roundIndex) => {
    const pickWeekId = addDays(friday, roundIndex * 7);
    matches.forEach((match, matchIndex) => {
      const date = addDays(pickWeekId, dayOffsets[matchIndex]);
      const kickoffAt = new Date(`${date}T${times[matchIndex]}:00.000Z`).toISOString();
      const providerId = `${runId}:${roundIndex + 1}:${matchIndex + 1}`;
      fixtures.push({
        _id: crypto.randomUUID(),
        source_key: `harness:${providerId}`,
        source_ids: { harness: providerId },
        contest_id: contestId,
        competition: PREMIER_LEAGUE,
        season_key: seasonKey,
        pick_week_id: pickWeekId,
        original_kickoff_at: kickoffAt,
        kickoff_at: kickoffAt,
        home_team: match.home,
        away_team: match.away,
        home_team_key: slug(match.home),
        away_team_key: slug(match.away),
        home_team_id: `harness:${slug(match.home)}`,
        away_team_id: `harness:${slug(match.away)}`,
        status: null,
        home_score: null,
        away_score: null,
        result_revision: null,
        harness_run_id: runId,
        harness_round: roundIndex + 1,
        harness_result_home: Math.floor(random() * 6),
        harness_result_away: Math.floor(random() * 5),
        created_at: now,
        updated_at: now,
      });
    });
  });
  return { runId, contestId, seasonKey, startDate: friday, rounds, fixtures };
}

function resultRevision(homeScore, awayScore, correction = 0) {
  return crypto.createHash("sha256").update(`${homeScore}:${awayScore}:FT:${correction}`).digest("hex");
}

async function scoreFixture(db, fixture) {
  const picks = await db.collection("gg_picks").find({
    fixture_id: fixture._id,
    scored_result_revision: { $ne: fixture.result_revision },
  }).toArray();
  if (!picks.length) return 0;
  const scoredAt = new Date().toISOString();
  await db.collection("gg_picks").bulkWrite(picks.map((pick) => {
    const score = scorePrediction(pick.home_score, pick.away_score, fixture.home_score, fixture.away_score, pick.power_pick);
    const baseScore = scorePrediction(pick.home_score, pick.away_score, fixture.home_score, fixture.away_score, false);
    return {
      updateOne: {
        filter: { _id: pick._id },
        update: { $set: { points: score.points, base_points: baseScore.points, score_tier: score.tier, scored_result_revision: fixture.result_revision, scored_at: scoredAt } },
      },
    };
  }), { ordered: false });
  return picks.length;
}

function registerGoalGuesserTestHarnessRoutes(app, options = {}) {
  if (options.enabled !== true) return;
  const harnessKey = String(options.key || "");
  const expectedDatabase = String(options.databaseName || "");

  app.use(PREFIX, async (req, res, next) => {
    if (process.env.NODE_ENV !== "test") return res.status(404).json({ error: "Test harness is disabled" });
    if (harnessKey.length < 16) return res.status(503).json({ error: "GOAL_GUESSER_TEST_HARNESS_KEY must contain at least 16 characters" });
    const supplied = String(req.get("x-goal-guesser-harness-key") || "");
    const left = Buffer.from(supplied);
    const right = Buffer.from(harnessKey);
    if (left.length !== right.length || !crypto.timingSafeEqual(left, right)) return res.status(401).json({ error: "Invalid harness key" });
    const db = await getDb();
    if (!db) return res.status(503).json({ error: "MongoDB is unavailable" });
    if (!expectedDatabase || db.databaseName !== expectedDatabase) {
      return res.status(409).json({ error: `Harness refused database ${db.databaseName}; expected ${expectedDatabase || "an explicit test database"}` });
    }
    req.goalGuesserHarness = { db };
    const run = await db.collection("gg_harness_runs").find({}).sort({ created_at: -1 }).limit(1).next();
    if (run?.current_time) __private.setGoalGuesserTestNow(run.current_time);
    return next();
  });

  app.get(`${PREFIX}/state`, async (req, res) => {
    const { db } = req.goalGuesserHarness;
    const [players, leagues, fixtures, picks, runs] = await Promise.all([
      db.collection("gg_players").countDocuments(),
      db.collection("gg_leagues").countDocuments(),
      db.collection("gg_fixtures").countDocuments(),
      db.collection("gg_picks").countDocuments(),
      db.collection("gg_harness_runs").find({}).sort({ created_at: -1 }).limit(5).toArray(),
    ]);
    return res.json({ database: db.databaseName, players, leagues, fixtures, picks, runs });
  });

  app.delete(`${PREFIX}/reset`, async (req, res) => {
    const { db } = req.goalGuesserHarness;
    const deleted = {};
    for (const name of GG_COLLECTIONS) deleted[name] = (await db.collection(name).deleteMany({})).deletedCount;
    __private.setGoalGuesserTestNow(null);
    return res.json({ database: db.databaseName, deleted });
  });

  app.post(`${PREFIX}/seed-season`, async (req, res) => {
    const { db } = req.goalGuesserHarness;
    const teams = Array.isArray(req.body?.teams) ? req.body.teams.map(String) : require("./premier_league_teams_static.json");
    const generated = generateSeason({ teams, startDate: req.body?.start_date, seed: req.body?.seed });
    const existing = await db.collection("gg_fixtures").countDocuments({});
    if (existing > 0) return res.status(409).json({ error: "Reset the test database before seeding another season" });
    const now = new Date().toISOString();
    await db.collection("gg_contests").insertOne({
      _id: generated.contestId,
      competition_key: "premier-league",
      competition_name: PREMIER_LEAGUE,
      season_key: generated.seasonKey,
      game_type: "score-picks",
      scoring_version: 1,
      result_basis: "normal_time",
      created_at: now,
      updated_at: now,
    });
    await db.collection("gg_fixtures").insertMany(generated.fixtures);
    const weeks = generated.rounds.map((fixtures, index) => ({ pick_week_id: addDays(generated.startDate, index * 7), fixture_count: fixtures.length }));
    const currentTime = new Date(Date.parse(`${generated.startDate}T00:00:00.000Z`) - 12 * 60 * 60 * 1000).toISOString();
    const run = { _id: generated.runId, season_key: generated.seasonKey, start_date: generated.startDate, seed: Number(req.body?.seed || 20260801), fixture_count: generated.fixtures.length, weeks, current_time: currentTime, created_at: now };
    await db.collection("gg_harness_runs").insertOne(run);
    __private.setGoalGuesserTestNow(currentTime);
    return res.status(201).json({ run_id: run._id, season_key: run.season_key, start_date: run.start_date, fixture_count: run.fixture_count, current_time: currentTime, weeks });
  });

  app.post(`${PREFIX}/runs/:runId/weeks/:pickWeekId/postpone`, async (req, res) => {
    const { db } = req.goalGuesserHarness;
    const fixture = await db.collection("gg_fixtures").findOne({ harness_run_id: req.params.runId, pick_week_id: req.params.pickWeekId, _id: String(req.body?.fixture_id || "") });
    if (!fixture) return res.status(404).json({ error: "Harness fixture not found" });
    const revisedKickoff = new Date(__private.currentTimeMs() + 5 * 24 * 60 * 60 * 1000).toISOString();
    await db.collection("gg_fixtures").updateOne({ _id: fixture._id }, { $set: { kickoff_at: revisedKickoff, status: "POSTPONED", home_score: null, away_score: null, result_revision: null, updated_at: new Date().toISOString() } });
    return res.json({ fixture_id: fixture._id, original_kickoff_at: fixture.original_kickoff_at, revised_kickoff_at: revisedKickoff, pick_week_id: fixture.pick_week_id });
  });

  app.post(`${PREFIX}/runs/:runId/weeks/:pickWeekId/settle`, async (req, res) => {
    const { db } = req.goalGuesserHarness;
    const fixtures = await db.collection("gg_fixtures").find({ harness_run_id: req.params.runId, pick_week_id: req.params.pickWeekId }).sort({ original_kickoff_at: 1 }).toArray();
    if (!fixtures.length) return res.status(404).json({ error: "Harness week not found" });
    const settled = [];
    let scoredPicks = 0;
    const clockAfterWeek = new Date(Math.max(...fixtures.map((fixture) => Date.parse(fixture.kickoff_at))) + 3 * 60 * 60 * 1000).toISOString();
    __private.setGoalGuesserTestNow(clockAfterWeek);
    await db.collection("gg_harness_runs").updateOne({ _id: req.params.runId }, { $set: { current_time: clockAfterWeek, updated_at: new Date().toISOString() } });
    for (let index = 0; index < fixtures.length; index += 1) {
      const fixture = fixtures[index];
      const homeScore = fixture.harness_result_home;
      const awayScore = fixture.harness_result_away;
      const revision = resultRevision(homeScore, awayScore, Number(fixture.harness_correction || 0));
      await db.collection("gg_fixtures").updateOne({ _id: fixture._id }, { $set: { status: "FT", home_score: homeScore, away_score: awayScore, result_revision: revision, updated_at: new Date().toISOString() } });
      const current = { ...fixture, status: "FT", home_score: homeScore, away_score: awayScore, result_revision: revision };
      scoredPicks += await scoreFixture(db, current);
      settled.push({ fixture_id: fixture._id, home_score: homeScore, away_score: awayScore, result_revision: revision });
    }
    return res.json({ pick_week_id: req.params.pickWeekId, current_time: clockAfterWeek, fixtures: settled, scored_picks: scoredPicks });
  });

  app.post(`${PREFIX}/runs/:runId/fixtures/:fixtureId/correct`, async (req, res) => {
    const { db } = req.goalGuesserHarness;
    const fixture = await db.collection("gg_fixtures").findOne({ harness_run_id: req.params.runId, _id: req.params.fixtureId });
    const homeScore = Number(req.body?.home_score);
    const awayScore = Number(req.body?.away_score);
    if (!fixture || !Number.isInteger(homeScore) || !Number.isInteger(awayScore) || homeScore < 0 || awayScore < 0) return res.status(400).json({ error: "A fixture and non-negative integer scores are required" });
    const correction = Number(fixture.harness_correction || 0) + 1;
    const revision = resultRevision(homeScore, awayScore, correction);
    await db.collection("gg_fixtures").updateOne({ _id: fixture._id }, { $set: { status: "FT", home_score: homeScore, away_score: awayScore, harness_result_home: homeScore, harness_result_away: awayScore, harness_correction: correction, result_revision: revision, updated_at: new Date().toISOString() } });
    const scoredPicks = await scoreFixture(db, { ...fixture, status: "FT", home_score: homeScore, away_score: awayScore, result_revision: revision });
    return res.json({ fixture_id: fixture._id, home_score: homeScore, away_score: awayScore, result_revision: revision, scored_picks: scoredPicks });
  });
}

module.exports = {
  registerGoalGuesserTestHarnessRoutes,
  roundRobinRounds,
  generateSeason,
  firstFriday,
};
