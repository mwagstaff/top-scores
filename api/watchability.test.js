"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { calculateWatchability, tierForScore } = require("./watchability");

function standing(position, points, overrides = {}) {
  return {
    position,
    points,
    team_count: 20,
    played: 20,
    goals_for: 32,
    form: ["W", "D", "W", "L", "W"],
    ...overrides,
  };
}

test("tier thresholds and star rounding match the product calibration", () => {
  assert.equal(tierForScore(84), "highly_watchable");
  assert.equal(tierForScore(85), "must_watch");
  const result = calculateWatchability({ competitionWeight: 0 });
  assert.equal(result.stars, Math.round(result.score / 20));
});

test("Leeds against Brentford calibrates to a lower highly-watchable score", () => {
  const result = calculateWatchability({
    competitionName: "Premier League",
    competitionWeight: 100,
    homeElo: 1759.66040039,
    awayElo: 1828.95019531,
    stage: "League",
  });

  assert.equal(result.tier, "highly_watchable");
  assert.equal(result.score, 72);
});

test("Sunderland against Fulham is a good watch rather than highly watchable", () => {
  const result = calculateWatchability({
    competitionName: "Premier League",
    competitionWeight: 100,
    homeElo: 1686.75891113,
    awayElo: 1790.57385254,
    stage: "League",
  });

  assert.equal(result.tier, "good_watch");
  assert.equal(result.score, 68);
});

test("Premier League fixtures featuring a high-draw club retain their calibration", () => {
  const chelseaBrighton = calculateWatchability({
    competitionName: "Premier League",
    competitionWeight: 100,
    homeElo: 1880.36804199,
    awayElo: 1829.68884277,
    stage: "League",
  });
  const manchesterUnitedIpswich = calculateWatchability({
    competitionName: "Premier League",
    competitionWeight: 100,
    homeElo: 1876.9630127,
    awayElo: 1624.99560547,
    stage: "League",
  });

  assert.equal(chelseaBrighton.score, 82);
  assert.equal(manchesterUnitedIpswich.score, 73);
});

test("a high-profile Championship fixture receives a bounded club-stature boost", () => {
  const westHamWolves = calculateWatchability({
    competitionName: "Championship",
    competitionWeight: 40,
    homeElo: 1741.88684082,
    awayElo: 1697.10461426,
    stage: "League",
  });
  const swanseaWatford = calculateWatchability({
    competitionName: "Championship",
    competitionWeight: 40,
    homeElo: 1508.37060547,
    awayElo: 1508.77441406,
    stage: "League",
  });

  assert.equal(westHamWolves.score, 62);
  assert.equal(westHamWolves.stars, 3);
  assert.equal(westHamWolves.tier, "good_watch");
  assert.equal(swanseaWatford.score, 43);
  assert.equal(swanseaWatford.stars, 2);
});

test("Real Madrid against a much weaker La Liga opponent remains moderate", () => {
  const result = calculateWatchability({
    competitionName: "La Liga",
    competitionWeight: 50,
    homeElo: 1950,
    awayElo: 1500,
    homeStanding: standing(1, 52),
    awayStanding: standing(16, 19),
    stage: "League",
  });

  assert.equal(result.tier, "moderate");
  assert.ok(result.score < 55);
});

test("a crunch El Clasico reaches must-watch without making every La Liga game must-watch", () => {
  const result = calculateWatchability({
    competitionName: "La Liga",
    competitionWeight: 50,
    homeElo: 1970,
    awayElo: 1950,
    homeStanding: standing(1, 58),
    awayStanding: standing(2, 56),
    stage: "League",
    rivalryName: "El Clasico",
  });

  assert.equal(result.tier, "must_watch");
  assert.ok(result.components.some((component) => component.key === "rivalry"));
});

test("a curated marquee derby remains must-watch when its domestic table is unavailable", () => {
  const result = calculateWatchability({
    competitionName: "Bundesliga",
    competitionWeight: 48,
    homeElo: 1990,
    awayElo: 1810,
    stage: "League",
    rivalryName: "Der Klassiker",
  });

  assert.equal(result.tier, "must_watch");
  assert.equal(result.score, 85);
});

test("a Champions League final can be must-watch without a rivalry modifier", () => {
  const result = calculateWatchability({
    competitionName: "UEFA Champions League",
    competitionWeight: 90,
    homeElo: 1950,
    awayElo: 1920,
    stage: "Final",
  });

  assert.equal(result.tier, "must_watch");
});
