const test = require("node:test");
const assert = require("node:assert/strict");
const { __testHooks } = require("./match_monitor");

const nowMs = Date.parse("2026-10-06T14:03:00Z");
const user = { preferences: { liveActivityDelayMinutes: 2 } };
const fixture = (match_details_id, time, home_team, away_team, score_status = null) => ({
  match_details_id, date: "2026-10-06", time, home_team, away_team,
  league: "UEFA Nations League", score_status,
  home_score: score_status === null ? null : 0,
  away_score: score_status === null ? null : 0,
});
const pending = [
  fixture("india", "15:00", "India", "Uruguay"),
  fixture("kazakhstan", "15:00", "Kazakhstan", "Faroe Islands"),
];
const upcoming = [
  fixture("croatia", "19:45", "Croatia", "Spain"),
  fixture("england", "19:45", "England", "Czechia"),
];
const present = (matches) => __testHooks.buildLiveActivityPresentationForUser(
  user, matches.map((match) => ({ match, state: null })), nowMs
);

test("pending kickoffs keep later fixtures in the Live Activity", () => {
  for (const pendingMatches of [pending.slice(0, 1), pending]) {
    const presentation = present([...upcoming, ...pendingMatches]);
    assert.equal(presentation.mode, "multi_upcoming");
    assert.deepEqual(presentation.matches.map((match) => match.match_details_id),
      [...pendingMatches, ...upcoming].map((match) => match.match_details_id));
    const content = __testHooks.buildLiveActivityContentState(
      presentation.mode, presentation.matches, presentation.delayMinutes, nowMs
    );
    assert.deepEqual(content.matches.map((match) => match.matchId),
      presentation.matches.map((match) => match.match_details_id));
    assert.ok(content.matches.every((match) => match.homeScore === undefined && match.awayScore === undefined));
  }
});

test("a pending kickoff does not hide matches waiting for their spoiler delay", () => {
  const presentation = present([pending[0], { ...pending[1], score_status: "0" }, ...upcoming]);
  assert.equal(presentation.mode, "multi_upcoming");
  assert.deepEqual(presentation.matches.map((match) => match.match_details_id),
    ["india", "kazakhstan", "croatia", "england"]);
  assert.ok(presentation.matches.every((match) => match.home_score === null && match.away_score === null));
});

test("live mode keeps pending kickoffs alongside later fixtures", () => {
  const liveMatch = fixture("kazakhstan", "15:00", "Kazakhstan", "Faroe Islands", "1");
  const presentation = __testHooks.buildLiveActivityPresentationForUser(user, [
    { match: pending[0], state: null },
    { match: liveMatch, state: {
      lastState: liveMatch,
      history: [{ timestampMs: nowMs - 2 * 60 * 1000, match: liveMatch }],
    } },
    ...upcoming.map((match) => ({ match, state: null })),
  ], nowMs);
  assert.equal(presentation.mode, "single_live");
  assert.deepEqual(presentation.matches.map((match) => match.match_details_id),
    ["kazakhstan", "india", "croatia", "england"]);
});

test("pending kickoffs and upcoming fixtures share the six-match limit", () => {
  const presentation = present([...pending, ...upcoming,
    fixture("scotland", "19:45", "Scotland", "Slovenia"),
    fixture("switzerland", "19:45", "Switzerland", "North Macedonia"),
    fixture("late", "20:00", "Moldova", "Slovakia"),
  ]);
  assert.equal(presentation.matches.length, 6);
  assert.deepEqual(presentation.matches.slice(0, 2).map((match) => match.match_details_id),
    ["india", "kazakhstan"]);
  assert.ok(!presentation.matches.some((match) => match.match_details_id === "late"));
});
