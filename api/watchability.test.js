"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { calculateWatchability, tierForScore, starsForScore } = require("./watchability");

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

test("tier thresholds and stars have a one-to-one mapping", () => {
  assert.equal(tierForScore(84), "highly_watchable");
  assert.equal(tierForScore(85), "must_watch");
  const result = calculateWatchability({ competitionWeight: 0 });
  assert.equal(result.stars, 1);
  for (const [score, stars, tier] of [
    [0, 1, "for_the_diehards"], [29, 1, "for_the_diehards"],
    [30, 2, "moderate"], [54, 2, "moderate"],
    [55, 3, "good_watch"], [69, 3, "good_watch"],
    [70, 4, "highly_watchable"], [84, 4, "highly_watchable"],
    [85, 5, "must_watch"], [100, 5, "must_watch"],
  ]) {
    assert.equal(starsForScore(score), stars);
    assert.equal(tierForScore(score), tier);
  }
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

// Captured from the public matches, teams and tables APIs on 27 October 2026.
test("UK cup Premier League appeal corrects the reported TV ordering", () => {
  const cases = require("./test/fixtures/watchability-2026-10-27.json");
  for (const fixture of cases) {
    const withoutBonus = calculateWatchability({ ...fixture.input, awayIsPremierLeague: false });
    assert.equal(withoutBonus.score, fixture.previousScore, fixture.match);
    const result = calculateWatchability(fixture.input);
    assert.equal(result.score, fixture.input.awayIsPremierLeague ? 62 : fixture.previousScore, fixture.match);
  }
});

test("cup appeal applies once for either side and all English cup aliases", () => {
  for (const competitionName of ["FA Cup", "English FA Cup", "EFL Cup", "English League Cup", "Carabao Cup"]) {
    const input = { competitionName, competitionWeight: 60, homeElo: 1700, awayElo: 1800 };
    const base = calculateWatchability(input);
    for (const flags of [{ homeIsPremierLeague: true }, { awayIsPremierLeague: true }, { homeIsPremierLeague: true, awayIsPremierLeague: true }]) {
      const result = calculateWatchability({ ...input, ...flags });
      assert.equal(result.score, base.score + 15);
      assert.equal(result.components.filter(c => c.key === "premier_league_cup_draw").length, 1);
    }
  }
});

test("cup appeal does not inflate leagues, European competitions or friendlies", () => {
  for (const competitionName of ["Premier League", "Serie A", "UEFA Champions League", "International Friendly", "Scottish Cup"]) {
    const input = { competitionName, competitionWeight: 60, homeElo: 1800, awayElo: 1900 };
    assert.deepEqual(calculateWatchability({ ...input, awayIsPremierLeague: true }), calculateWatchability(input));
  }
});

test("missing ratings use neutral balance and never become zero-strength clubs", () => {
  for (const missing of [null, undefined, "", 0, NaN]) {
    const result = calculateWatchability({ competitionName: "EFL Cup", competitionWeight: 60, homeElo: missing, awayElo: 2000 });
    assert.equal(result.components.find(c => c.key === "team_quality").score, 100);
    assert.equal(result.components.find(c => c.key === "competitive_balance").score, 55);
    assert.equal(result.confidence, 0.64);
  }
  const result = calculateWatchability({ homeElo: null, awayElo: null });
  assert.equal(result.components.find(c => c.key === "team_quality").score, 45);
  assert.equal(result.components.find(c => c.key === "competitive_balance").score, 55);
});

// Public /api/v1/teams ratings captured on 27 October 2026; neutral table/form.
test("elite marquee fixtures reach five stars without requiring a rivalry or final", () => {
  for (const [competitionName, competitionWeight, homeElo, awayElo, expectedScore] of [
    ["UEFA Champions League", 90, 1950.7, 1968.44, 87], // PSG / Barcelona
    ["Premier League", 100, 1925.65, 1984.55, 90], // Liverpool / Man City
    ["Premier League", 100, 2015, 1900.35, 87], // Arsenal / Chelsea
  ]) {
    const result = calculateWatchability({ competitionName, competitionWeight, homeElo, awayElo, stage: "League" });
    assert.equal(result.score, expectedScore);
    assert.equal(result.stars, 5);
    assert.equal(result.tier, "must_watch");
    assert.ok(result.components.find(c => c.key === "elite_matchup").contribution <= 7);
    assert.equal(calculateWatchability({ competitionName, competitionWeight, homeElo: awayElo, awayElo: homeElo, stage: "League" }).score, result.score);
  }
});

test("elite boost requires two strong rated clubs in an eligible competition", () => {
  for (const input of [
    { homeElo: 2015, awayElo: 1850 },
    { homeElo: 2015, awayElo: null },
    { homeElo: null, awayElo: 2015 },
    { homeElo: 2015, awayElo: 2000, competitionName: "International Friendly" },
  ]) {
    const result = calculateWatchability({ competitionName: "Premier League", competitionWeight: 100, ...input });
    assert.ok(!result.components.some(c => c.key === "elite_matchup"));
  }
});
