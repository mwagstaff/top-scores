const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    calendarSubscriptionTokenHash,
    matchesVisibleForScoresPreferences,
    normalizeCalendarSubscriptionToken,
    redactedRequestUrl,
  },
} = require("./server");

const premierLeague = {
  match_details_id: "1",
  date: "2026-08-30",
  kickoff_at: "2026-08-30T15:00:00Z",
  home_team: "Arsenal",
  away_team: "Chelsea",
  league: "Premier League",
  tv_channels: ["Sky Sports Main Event"],
  score_status: null,
};
const laLiga = {
  match_details_id: "2",
  date: "2026-08-30",
  kickoff_at: "2026-08-30T18:00:00Z",
  home_team: "Barcelona",
  away_team: "Valencia",
  league: "La Liga",
  tv_channels: ["Premier Sports 1"],
  score_status: null,
};
const postponed = {
  ...premierLeague,
  match_details_id: "3",
  home_team: "Liverpool",
  away_team: "Everton",
  score_status: "POSTPONED",
};

const fixtureViewContext = {
  competitionCatalog: new Map([
    ["premier league", { id: "premier-league" }],
    ["la liga", { id: "la-liga" }],
  ]),
};

function activePreferences(overrides = {}) {
  return {
    selectedFixtureViewOptionIDs: ["competition:premier-league"],
    favouriteFixtureViewOptionIDs: ["competition:premier-league"],
    fixtureAllMajorMatchesEnabled: false,
    competitionFilterEnabled: true,
    selectedLeagues: ["Premier League"],
    selectedChannels: [],
    channelFilterEnabled: false,
    showAllMatches: false,
    showPostponedGames: false,
    ...overrides,
  };
}

test("calendar selection follows active fixture view options and hides postponed matches", () => {
  const visible = matchesVisibleForScoresPreferences(
    [premierLeague, laLiga, postponed],
    activePreferences(),
    { fixtureViewContext, premierLeagueTeams: [] }
  );
  assert.deepEqual(visible.map((match) => match.match_details_id), ["1"]);
});

test("calendar selection honors explicit show all and postponed visibility", () => {
  const visible = matchesVisibleForScoresPreferences(
    [premierLeague, laLiga, postponed],
    activePreferences({ showAllMatches: true, showPostponedGames: true }),
    { fixtureViewContext, premierLeagueTeams: [] }
  );
  assert.deepEqual(visible.map((match) => match.match_details_id), ["1", "2", "3"]);
});

test("calendar selection applies the Scores channel filter", () => {
  const visible = matchesVisibleForScoresPreferences(
    [premierLeague, laLiga],
    activePreferences({
      showAllMatches: true,
      channelFilterEnabled: true,
      selectedChannels: ["Sky (all)"],
    }),
    { fixtureViewContext, premierLeagueTeams: [] }
  );
  assert.deepEqual(visible.map((match) => match.match_details_id), ["1"]);
});

test("calendar tokens are fixed-length base64url bearer values", () => {
  const token = "A".repeat(43);
  assert.equal(normalizeCalendarSubscriptionToken(token), token);
  assert.equal(normalizeCalendarSubscriptionToken("short"), "");
  assert.match(calendarSubscriptionTokenHash(token), /^[a-f0-9]{64}$/);
});

test("calendar bearer tokens are redacted from request logs", () => {
  const token = "B".repeat(43);
  assert.equal(
    redactedRequestUrl({
      originalUrl: `/api/v1/calendar-subscriptions/${token}.ics?source=calendar`,
    }),
    "/api/v1/calendar-subscriptions/[redacted].ics?source=calendar"
  );
});
