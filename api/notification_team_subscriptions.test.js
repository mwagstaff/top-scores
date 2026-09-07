const test = require("node:test");
const assert = require("node:assert/strict");
const { buildNotificationTeamRegistry, migrateNotificationTeamSubscriptions } = require("./notification_team_subscriptions");
const { __private: { notificationFixtureContext, matchPassesFixtureViewOptions, matchPassesCategoryFilters, toMonitorCandidateFromDetailsPayload } } = require("./server");
const teams = [
  { id: "newcastle-united", name: "Newcastle United", aliases: ["Newcastle", "NEW"], source_team_ids: ["4"], competition_ids: ["premier-league"] },
  { id: "newcastle-town", name: "Newcastle Town", aliases: ["Newcastle"], source_team_ids: ["3097"], competition_ids: ["fa-cup"] },
  { id: "ambiguous", name: "Ambiguous", source_team_ids: ["5", "6"] },
];
const registry = buildNotificationTeamRegistry(teams);
const user = { preferences: { selectedNotificationViewOptionIDs: ["competition:premier-league", "team:newcastle-united"] } };
const match = { id: "601466", league: "FA Cup", date: "2026-09-05", home_team: "Cleethorpes Town", away_team: "Newcastle United", home_team_id: "123", away_team_id: "3097" };

test("legacy canonical selectors migrate to a single BSD ID despite conflicting aliases", () => {
  assert.deepEqual(migrateNotificationTeamSubscriptions(user, registry), {
    version: 1, provider: "bsd", bindings: { "newcastle-united": "4" }, unresolved: {},
  });
  const unresolved = migrateNotificationTeamSubscriptions({ preferences: { selectedNotificationViewOptionIDs: ["team:newcastle", "team:ambiguous", "team:missing"] } }, registry);
  assert.deepEqual(Object.keys(unresolved.bindings), []);
  assert.equal(Object.keys(unresolved.unresolved).length, 3);
});

test("bindings are idempotent, survive catalogue renames, and track old client selection edits", () => {
  const migrated = { ...user, notificationTeamSubscriptions: migrateNotificationTeamSubscriptions(user, registry) };
  const empty = buildNotificationTeamRegistry([]);
  assert.deepEqual(migrateNotificationTeamSubscriptions(migrated, empty), migrated.notificationTeamSubscriptions);
  const changed = { ...migrated, preferences: { selectedNotificationViewOptionIDs: ["team:newcastle-town"] } };
  assert.deepEqual(migrateNotificationTeamSubscriptions(changed, registry).bindings, { "newcastle-town": "3097" });
});

test("different or missing BSD ID cannot be overridden by identical names or contaminated aliases", () => {
  const migrated = { ...user, notificationTeamSubscriptions: migrateNotificationTeamSubscriptions(user, registry) };
  const context = notificationFixtureContext(migrated, registry, {});
  for (const away_team_id of ["3097", null, undefined, "", "invalid"]) {
    assert.equal(matchPassesFixtureViewOptions({ ...match, away_team_id }, user.preferences.selectedNotificationViewOptionIDs, context), false);
  }
  for (const away_team_id of [4, "4"]) {
    assert.equal(matchPassesFixtureViewOptions({ ...match, away_team: "Renamed Club", away_team_id }, user.preferences.selectedNotificationViewOptionIDs, context), true);
  }
  assert.equal(matchPassesFixtureViewOptions({ ...match, away_team_id: "4" }, user.preferences.selectedNotificationViewOptionIDs, notificationFixtureContext(user, registry, {})), false, "unmigrated selections fail closed");
});

test("current Premier League membership is checked using fixture IDs", () => {
  const filters = { eplOnly: true, premierLeagueTeamIDs: registry.premierLeagueIDs };
  assert.equal(matchPassesCategoryFilters(match, filters), false);
  assert.equal(matchPassesCategoryFilters({ ...match, away_team: "Unknown name", away_team_id: "4" }, filters), true);
  assert.equal(matchPassesCategoryFilters({ ...match, away_team_id: undefined }, filters), false);
});

test("monitor candidates retain IDs from BSD detail records", () => {
  const candidate = toMonitorCandidateFromDetailsPayload(match);
  assert.equal(candidate.home_team_id, "123");
  assert.equal(candidate.away_team_id, "3097");
});

test("rivalry subscriptions migrate both clubs and compare BSD IDs in either order", () => {
  const rivalryRegistry = buildNotificationTeamRegistry([
    { id: "celtic", name: "Celtic", source_team_ids: ["230"] },
    { id: "rangers", name: "Rangers", source_team_ids: ["231"] },
  ]);
  const selected = ["rivalry:old-firm"];
  const subscriber = { preferences: { selectedNotificationViewOptionIDs: selected } };
  subscriber.notificationTeamSubscriptions = migrateNotificationTeamSubscriptions(subscriber, rivalryRegistry);
  const context = notificationFixtureContext(subscriber, rivalryRegistry, {});
  assert.equal(matchPassesFixtureViewOptions({ home_team: "Wrong", away_team: "Names", home_team_id: "230", away_team_id: "231" }, selected, context), true);
  assert.equal(matchPassesFixtureViewOptions({ home_team: "Celtic", away_team: "Rangers", home_team_id: "230", away_team_id: "999" }, selected, context), false);
});

test("malformed bindings fail closed instead of enabling name fallback", () => {
  const malformed = { ...user, notificationTeamSubscriptions: { version: 1 } };
  assert.equal(matchPassesFixtureViewOptions({ ...match, away_team_id: "4" }, user.preferences.selectedNotificationViewOptionIDs, notificationFixtureContext(malformed, registry, {})), false);
});
