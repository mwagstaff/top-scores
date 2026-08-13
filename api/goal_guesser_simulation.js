"use strict";

const crypto = require("crypto");

const PREMIER_LEAGUE = "Premier League";

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

function nextFriday(value = new Date().toISOString().slice(0, 10)) {
  const normalized = normalizeDate(value);
  if (!normalized) return null;
  const date = new Date(`${normalized}T12:00:00.000Z`);
  const days = (5 - date.getUTCDay() + 7) % 7;
  return addDays(normalized, days);
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

function roundRobinRounds(teams) {
  if (!Array.isArray(teams) || teams.length < 2 || teams.length % 2 !== 0) throw new Error("An even number of at least two teams is required");
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
  return [...rounds, ...rounds.map((fixtures) => fixtures.map(({ home, away }) => ({ home: away, away: home })) )];
}

function seasonKeyForDate(dateString) {
  const match = String(dateString || "").match(/^(\d{4})-(\d{2})-/);
  if (!match) return "simulation";
  const year = Number(match[1]);
  const start = Number(match[2]) >= 7 ? year : year - 1;
  return `${start}-${String(start + 1).slice(-2)}`;
}

function generateSimulationSeason({ teams, startDate, seed = 20260801, runId = crypto.randomUUID() }) {
  const friday = nextFriday(startDate);
  if (!friday) throw new Error("start_date must use YYYY-MM-DD");
  const rounds = roundRobinRounds(teams);
  const seasonKey = seasonKeyForDate(friday);
  const contestId = `simulation:${runId}`;
  const times = ["19:30", "12:30", "15:00", "15:00", "17:30", "14:00", "16:30", "20:00", "20:00", "20:00"];
  const dayOffsets = [0, 1, 1, 1, 1, 2, 2, 3, 3, 3];
  const now = new Date().toISOString();
  const fixtures = [];
  rounds.forEach((matches, roundIndex) => {
    const pickWeekId = addDays(friday, roundIndex * 7);
    matches.forEach((match, matchIndex) => {
      const kickoffAt = new Date(`${addDays(pickWeekId, dayOffsets[matchIndex])}T${times[matchIndex]}:00.000Z`).toISOString();
      fixtures.push({
        _id: crypto.randomUUID(),
        source_key: `simulation:${runId}:${roundIndex + 1}:${matchIndex + 1}`,
        source_ids: { simulation: `${roundIndex + 1}:${matchIndex + 1}` },
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
        home_team_id: null,
        away_team_id: null,
        status: null,
        home_score: null,
        away_score: null,
        result_revision: null,
        simulation_id: runId,
        simulation_week: roundIndex + 1,
        created_at: now,
        updated_at: now,
      });
    });
  });
  const weeks = rounds.map((fixturesInWeek, index) => ({
    index: index + 1,
    pick_week_id: addDays(friday, index * 7),
    fixture_count: fixturesInWeek.length,
  }));
  return { runId, contestId, seasonKey, startDate: friday, fixtures, weeks, seed: Number(seed) };
}

function generateSimulationSeasonFromFixtures({ fixtures: canonicalFixtures, seed = 20260801, runId = crypto.randomUUID() }) {
  const ordered = [...(Array.isArray(canonicalFixtures) ? canonicalFixtures : [])]
    .filter((fixture) => fixture && fixture._id && fixture.pick_week_id && Number.isFinite(Date.parse(fixture.kickoff_at)))
    .sort((left, right) => Date.parse(left.kickoff_at) - Date.parse(right.kickoff_at));
  if (!ordered.length) throw new Error("No upcoming Premier League fixtures are available to copy");

  const weekIds = [...new Set(ordered.map((fixture) => fixture.pick_week_id))];
  const weekIndex = new Map(weekIds.map((pickWeekId, index) => [pickWeekId, index + 1]));
  const seasonKey = ordered[0].season_key || seasonKeyForDate(ordered[0].kickoff_at.slice(0, 10));
  const contestId = `simulation:${runId}`;
  const now = new Date().toISOString();
  const fixtures = ordered.map((fixture, index) => ({
    _id: crypto.randomUUID(),
    source_key: `simulation:${runId}:canonical:${fixture._id}`,
    source_ids: { simulation: String(index + 1), canonical_fixture: fixture._id },
    contest_id: contestId,
    competition: PREMIER_LEAGUE,
    season_key: seasonKey,
    pick_week_id: fixture.pick_week_id,
    original_kickoff_at: fixture.original_kickoff_at || fixture.kickoff_at,
    kickoff_at: fixture.kickoff_at,
    home_team: fixture.home_team,
    away_team: fixture.away_team,
    home_team_key: fixture.home_team_key || slug(fixture.home_team),
    away_team_key: fixture.away_team_key || slug(fixture.away_team),
    home_team_id: fixture.home_team_id || null,
    away_team_id: fixture.away_team_id || null,
    status: null,
    home_score: null,
    away_score: null,
    result_revision: null,
    simulation_id: runId,
    simulation_week: weekIndex.get(fixture.pick_week_id),
    created_at: now,
    updated_at: now,
  }));
  const weeks = weekIds.map((pickWeekId, index) => ({
    index: index + 1,
    pick_week_id: pickWeekId,
    fixture_count: fixtures.filter((fixture) => fixture.pick_week_id === pickWeekId).length,
  }));
  return { runId, contestId, seasonKey, startDate: weekIds[0], fixtures, weeks, seed: Number(seed) };
}

function poisson(random, lambda) {
  const limit = Math.exp(-lambda);
  let product = 1;
  let count = 0;
  do { count += 1; product *= random(); } while (product > limit && count < 10);
  return Math.min(8, count - 1);
}

function realisticResults(fixtures, seed) {
  const random = mulberry32(seed);
  return fixtures.map((fixture) => {
    const homeBias = ((hashNumber(fixture.home_team) % 21) - 10) / 100;
    const awayBias = ((hashNumber(fixture.away_team) % 21) - 10) / 100;
    return {
      fixture_id: fixture._id,
      home_score: poisson(random, 1.55 + homeBias),
      away_score: poisson(random, 1.2 + awayBias),
    };
  });
}

function hashNumber(value) {
  return crypto.createHash("sha256").update(String(value)).digest().readUInt32BE(0);
}

function resultRevision(fixtureId, homeScore, awayScore, revision) {
  return crypto.createHash("sha256").update(`${fixtureId}:${homeScore}:${awayScore}:FT:${revision}`).digest("hex");
}

module.exports = { addDays, nextFriday, roundRobinRounds, generateSimulationSeason, generateSimulationSeasonFromFixtures, realisticResults, resultRevision };
