const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    calendarSubscriptionTokenHash,
    matchesVisibleForScoresPreferences,
    matchesVisibleForTVCalendarPreferences,
    calendarFeedOptions,
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

test("calendar selection keeps an abandoned match when postponed games are hidden", () => {
  const abandoned = {
    ...postponed,
    match_details_id: "588260",
    home_team: "Barrow AFC",
    away_team: "Forest Green Rovers",
    home_score: 1,
    away_score: 0,
    score_status: "ABANDONED",
  };
  const visible = matchesVisibleForScoresPreferences(
    [premierLeague, postponed, abandoned],
    activePreferences(),
    { fixtureViewContext, premierLeagueTeams: [] }
  );
  assert.deepEqual(visible.map((match) => match.match_details_id), ["1", "588260"]);
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

test("calendar selection applies the Scores channel filter to structured tv_channels objects", () => {
  const structuredPremierLeague = {
    ...premierLeague,
    tv_channels: [{ name: "Sky Sports Main Event", country: "United Kingdom", countryCode: "GB", logo: null }],
  };
  const structuredLaLiga = {
    ...laLiga,
    tv_channels: [{ name: "Premier Sports 1", country: "United Kingdom", countryCode: "GB", logo: null }],
  };
  const visible = matchesVisibleForScoresPreferences(
    [structuredPremierLeague, structuredLaLiga],
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

const tvOptions = { fixtureViewContext, premierLeagueTeams: [], ratingForMatch: (match) => match.watchability_index };
const ratedMatches = [85, 84, 70, 69, 55, 54, null].map((score, index) => ({
  ...premierLeague, match_details_id: String(index), watchability_index: score === null ? null : { score },
}));

test("TV calendar thresholds include boundaries and all includes unrated broadcasts", () => {
  for (const [minimum, ids] of [[85, ["0"]], [70, ["0", "1", "2"]], [55, ["0", "1", "2", "3", "4"]], [0, ["0", "1", "2", "3", "4", "5", "6"]]]) {
    const result = matchesVisibleForTVCalendarPreferences(ratedMatches, activePreferences(), minimum, tvOptions);
    assert.deepEqual(result.map((match) => match.match_details_id), ids);
  }
});

test("TV calendars require a named broadcast and honor competition and channel settings", () => {
  const matches = [
    { ...premierLeague, tv_channels: [{ name: "Sky Sports Main Event" }, { name: "TNT Sports 1" }] },
    laLiga,
    { ...premierLeague, match_details_id: "no-tv", tv_channels: [] },
    { ...premierLeague, match_details_id: "invalid-tv", tv_channels: [{ name: "" }] },
    postponed,
  ];
  const result = matchesVisibleForTVCalendarPreferences(matches, activePreferences({
    channelFilterEnabled: true, selectedChannels: ["Sky (all)"],
  }), 0, tvOptions);
  assert.deepEqual(result.map((match) => match.match_details_id), ["1"]);
  assert.deepEqual(result[0].tv_channels, ["Sky Sports Main Event"]);
  assert.equal(matches[0].tv_channels.length, 2);
  assert.deepEqual(matchesVisibleForTVCalendarPreferences([laLiga], activePreferences(), 0, tvOptions), []);
});

test("calendar options preserve legacy feeds and reject invalid or ambiguous filters", () => {
  assert.deepEqual(calendarFeedOptions({}), { type: "matches" });
  for (const minimumScore of ["0", "55", "70", "85"]) {
    const options = calendarFeedOptions({ type: "tv", minimumScore });
    assert.equal(options.minimumScore, Number(minimumScore));
    assert.match(options.calendarName, /Top Scores — TV:/);
  }
  assert.equal(calendarFeedOptions({ type: "tv" }).minimumScore, 0);
  for (const query of [{ type: "other" }, { minimumScore: "85" }, { type: "tv", minimumScore: "NaN" }, { type: "tv", minimumScore: "" }, { type: "tv", minimumScore: ["85", "0"] }, { type: "tv", minimumScore: "86" }]) {
    assert.equal(calendarFeedOptions(query), null);
  }
});
