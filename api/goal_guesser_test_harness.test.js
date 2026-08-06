"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { roundRobinRounds, generateSeason, firstFriday } = require("./goal_guesser_test_harness");

const teams = Array.from({ length: 20 }, (_, index) => `Team ${index + 1}`);

test("round robin produces 380 fixtures with balanced home and away matches", () => {
  const rounds = roundRobinRounds(teams);
  assert.equal(rounds.length, 38);
  assert.ok(rounds.every((round) => round.length === 10));
  const fixtures = rounds.flat();
  assert.equal(fixtures.length, 380);
  for (const team of teams) {
    assert.equal(fixtures.filter((fixture) => fixture.home === team).length, 19);
    assert.equal(fixtures.filter((fixture) => fixture.away === team).length, 19);
    assert.equal(fixtures.filter((fixture) => fixture.home === team || fixture.away === team).length, 38);
  }
  for (let left = 0; left < teams.length; left += 1) {
    for (let right = left + 1; right < teams.length; right += 1) {
      const pair = fixtures.filter((fixture) => [fixture.home, fixture.away].includes(teams[left]) && [fixture.home, fixture.away].includes(teams[right]));
      assert.deepEqual(pair.map((fixture) => `${fixture.home}:${fixture.away}`).sort(), [`${teams[left]}:${teams[right]}`, `${teams[right]}:${teams[left]}`].sort());
    }
  }
});

test("season generation is deterministic and every fixture remains Premier League", () => {
  const first = generateSeason({ teams, startDate: "2026-08-14", seed: 42, runId: "run-one" });
  const second = generateSeason({ teams, startDate: "2026-08-14", seed: 42, runId: "run-two" });
  assert.equal(first.fixtures.length, 380);
  assert.deepEqual(first.fixtures.map((fixture) => [fixture.home_team, fixture.away_team, fixture.harness_result_home, fixture.harness_result_away]), second.fixtures.map((fixture) => [fixture.home_team, fixture.away_team, fixture.harness_result_home, fixture.harness_result_away]));
  assert.ok(first.fixtures.every((fixture) => fixture.competition === "Premier League"));
  assert.equal(new Set(first.fixtures.map((fixture) => fixture.pick_week_id)).size, 38);
});

test("season start advances to the next Friday", () => {
  assert.equal(firstFriday("2026-08-14"), "2026-08-14");
  assert.equal(firstFriday("2026-08-15"), "2026-08-21");
});
