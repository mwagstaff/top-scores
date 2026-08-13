"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const teams = require("./premier_league_teams_static.json");
const { generateSimulationSeason, generateSimulationSeasonFromFixtures, realisticResults, roundRobinRounds } = require("./goal_guesser_simulation");

test("simulation schedule is a complete isolated double round robin", () => {
  const season = generateSimulationSeason({ teams, startDate: "2026-08-14", seed: 42, runId: "run-1" });
  assert.equal(season.weeks.length, 38);
  assert.equal(season.fixtures.length, 380);
  assert.equal(season.fixtures.every((fixture) => fixture.simulation_id === "run-1" && fixture.contest_id === "simulation:run-1"), true);
  assert.equal(new Set(season.fixtures.map((fixture) => fixture.source_key)).size, 380);
});

test("round robin gives every ordered home and away pairing once", () => {
  const rounds = roundRobinRounds(["A", "B", "C", "D"]);
  const pairs = rounds.flat().map((fixture) => `${fixture.home}-${fixture.away}`);
  assert.equal(rounds.length, 6);
  assert.equal(new Set(pairs).size, 12);
});

test("canonical simulation keeps the live fixture pairings, dates, and team ids", () => {
  const canonical = [
    { _id: "live-1", season_key: "2027-28", pick_week_id: "2027-08-20", kickoff_at: "2027-08-20T19:00:00.000Z", home_team: "Arsenal", away_team: "Coventry City", home_team_id: "1", away_team_id: "2" },
    { _id: "live-2", season_key: "2027-28", pick_week_id: "2027-08-20", kickoff_at: "2027-08-21T11:30:00.000Z", home_team: "Hull City", away_team: "Manchester United", home_team_id: "3", away_team_id: "4" },
    { _id: "live-3", season_key: "2027-28", pick_week_id: "2027-08-27", kickoff_at: "2027-08-27T19:00:00.000Z", home_team: "Everton", away_team: "Leeds United", home_team_id: "5", away_team_id: "6" },
  ];
  const season = generateSimulationSeasonFromFixtures({ fixtures: canonical, seed: 42, runId: "canonical-run" });
  assert.equal(season.weeks.length, 2);
  assert.equal(season.fixtures.length, 3);
  assert.deepEqual(season.fixtures.map((fixture) => [fixture.home_team, fixture.away_team, fixture.kickoff_at]), canonical.map((fixture) => [fixture.home_team, fixture.away_team, fixture.kickoff_at]));
  assert.deepEqual(season.fixtures.map((fixture) => [fixture.home_team_id, fixture.away_team_id]), [["1", "2"], ["3", "4"], ["5", "6"]]);
  assert.deepEqual(season.fixtures.map((fixture) => fixture.simulation_week), [1, 1, 2]);
  assert.equal(season.fixtures.every((fixture) => fixture.simulation_id === "canonical-run" && fixture.status === null && fixture.result_revision === null), true);
});

test("realistic result generation is deterministic and bounded", () => {
  const season = generateSimulationSeason({ teams, startDate: "2026-08-14", runId: "run-2" });
  const fixtures = season.fixtures.slice(0, 10);
  const first = realisticResults(fixtures, 1234);
  const second = realisticResults(fixtures, 1234);
  assert.deepEqual(first, second);
  assert.equal(first.every((result) => Number.isInteger(result.home_score) && result.home_score >= 0 && result.home_score <= 8 && Number.isInteger(result.away_score) && result.away_score >= 0 && result.away_score <= 8), true);
  assert.notDeepEqual(first, realisticResults(fixtures, 5678));
});
