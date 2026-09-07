const test = require("node:test");
const assert = require("node:assert/strict");
const { __private: { matchPassesCategoryFilters, matchPassesFixtureViewOptions } } = require("./server");
const monitor = require("./match_monitor");
const { isEnglishPremierLeagueTeam, evaluateUserNotificationDecision } = monitor.__testHooks;
const premierLeagueTeams = require("./premier_league_teams_static.json");
const fixture = (team) => ({ home_team: "Cleethorpes Town", away_team: team, league: "FA Cup" });
const passes = (team) => matchPassesCategoryFilters(fixture(team), { eplOnly: true, premierLeagueTeams });

test("Premier League categories reject similarly named clubs and retain explicit aliases", () => {
  for (const team of ["Newcastle Town", "Newcastle Town FC", "Manchester FC", "Liverpool Feds", "Everton Women", "Arsenal U21"]) {
    assert.equal(passes(team), false, team);
    assert.equal(isEnglishPremierLeagueTeam(team), false, `monitor: ${team}`);
  }
  for (const team of ["Newcastle United", "Newcastle", "Man City", "Brighton", "Wolves", "AFC Bournemouth"]) {
    assert.equal(passes(team), true, team);
    assert.equal(isEnglishPremierLeagueTeam(team), true, `monitor: ${team}`);
  }
});

test("Newcastle Town notification is rejected for EPL-only, custom EPL and Fixtures-following preferences", () => {
  monitor.setNotificationFixtureCategoryFilter((_user, match) =>
    matchPassesCategoryFilters(match, { eplOnly: true, premierLeagueTeams }));
  try {
    for (const preferences of [
      { notificationPremierLeagueTeamsOnly: true },
      { notificationAllMajorMatchesEnabled: false, selectedNotificationViewOptionIDs: ["premier-league-teams"] },
      { notificationMatchesFixturesEnabled: true, englishPremierLeagueTeamsOnly: true },
    ]) {
      const user = { apnsToken: "test-token", preferences: { notificationsEnabled: true, ...preferences } };
      assert.equal(evaluateUserNotificationDecision(user, fixture("Newcastle Town"), { type: "goal" }).shouldNotify, false);
      assert.equal(evaluateUserNotificationDecision(user, fixture("Newcastle United"), { type: "goal" }).shouldNotify, true);
    }
  } finally {
    monitor.setNotificationFixtureCategoryFilter(null);
  }
});

// AE874635 uses explicit club selections, rather than the legacy EPL-only flag.
// These are the Newcastle catalogue entries and BSD IDs observed in production.
test("production custom Newcastle United selection excludes Newcastle Town", () => {
  const context = {
    teamCatalogByID: new Map([["newcastle-united", {
      id: "newcastle-united", name: "Newcastle United",
      aliases: ["NEW", "Newcastle", "Newcastle United FC"], source_team_ids: ["4"],
    }]]),
  };
  const options = ["competition:premier-league", "team:newcastle-united"];
  monitor.setNotificationFixtureCategoryFilter((_user, match, selection) =>
    matchPassesFixtureViewOptions(match, selection.optionIDs, context));
  const user = { apnsToken: "test-token", preferences: {
    notificationsEnabled: true, notificationAllMajorMatchesEnabled: false,
    notificationMatchesFixturesEnabled: false, notificationPremierLeagueTeamsOnly: false,
    notificationDelayMinutes: 1, notificationEventTypes: ["fulltime", "redcard", "goal"],
    selectedNotificationViewOptionIDs: options,
  } };
  try {
    for (const type of ["goal", "fulltime"]) {
      for (const away_team_id of ["3097", undefined]) {
        const match = { ...fixture("Newcastle Town"), away_team_id };
        assert.equal(evaluateUserNotificationDecision(user, match, { type }).shouldNotify, false);
      }
      for (const name of ["Newcastle United", "Newcastle"]) {
        assert.equal(evaluateUserNotificationDecision(user, fixture(name), { type }).shouldNotify, true);
      }
    }
  } finally {
    monitor.setNotificationFixtureCategoryFilter(null);
  }
});
