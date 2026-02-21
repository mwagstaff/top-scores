const test = require("node:test");
const assert = require("node:assert/strict");

const { __testHooks } = require("./match_monitor");

function newMonitorState(overrides = {}) {
  return {
    lifecycle: {
      kickoffEmitted: false,
      halftimeEmitted: false,
      fulltimeEmitted: false,
    },
    startedAtMs: 0,
    kickoffTimeMs: null,
    ...overrides,
  };
}

test("does not emit delayed kickoff when first live status seen is HT", () => {
  const monitorState = newMonitorState();

  const oldMatch = {
    home_team: "Blackburn Rovers",
    away_team: "Preston North End",
    score_status: null,
    home_score: 0,
    away_score: 0,
    home_goal_scorers: [],
    away_goal_scorers: [],
  };

  const newMatch = {
    ...oldMatch,
    score_status: "HT",
  };

  const events = __testHooks.buildMatchEvents(oldMatch, newMatch, monitorState, Date.now());
  const types = events.map((event) => event.type);

  assert.deepEqual(types, ["halftime"]);
});

test("emits all newly discovered goals when score jumps", () => {
  const monitorState = newMonitorState();

  const oldMatch = {
    home_team: "Mainz 05",
    away_team: "Hamburger SV",
    score_status: "20'",
    home_score: 0,
    away_score: 0,
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
  };

  const newMatch = {
    home_team: "Mainz 05",
    away_team: "Hamburger SV",
    score_status: "42'",
    home_score: 1,
    away_score: 1,
    home_goal_scorers: [
      {
        player: "N. Amiri",
        goal_times: ["42'"],
      },
    ],
    away_goal_scorers: [
      {
        player: "R. Glatzel",
        goal_times: ["10'"],
      },
    ],
    home_assists: [
      {
        player: "D. da Costa",
        assist_times: ["42'"],
      },
    ],
    away_assists: [],
  };

  const events = __testHooks
    .buildMatchEvents(oldMatch, newMatch, monitorState, Date.now())
    .filter((event) => event.type === "goal");

  assert.equal(events.length, 2);
  assert.equal(events[0].title, "Goal 10'");
  assert.equal(events[0].body, "Mainz 05 0 - 1 Hamburger SV (R. Glatzel)");
  assert.equal(events[1].title, "Goal 42'");
  assert.equal(events[1].body, "Mainz 05 1 - 1 Hamburger SV (N. Amiri, assist: D. da Costa)");
});

test("counts own goals for event detection", () => {
  const total = __testHooks.countGoals([
    { player: "Eric Garcia", own_goal_times: ["6'"] },
    { player: "A. Griezmann", goal_times: ["14'"] },
  ]);

  assert.equal(total, 2);
});

test("notification dedupe key includes explicit match id", () => {
  const user = { deviceToken: "device-123" };
  const id = __testHooks.buildNotificationId(user, "c043pne0q3kt", {
    type: "kickoff",
    eventKey: "kickoff",
  });

  assert.ok(id.includes("c043pne0q3kt"));
});

test("does not stop monitoring during transient status gaps shortly after kickoff", () => {
  const nowMs = Date.now();
  const monitorState = newMonitorState({
    kickoffTimeMs: nowMs - 60 * 60 * 1000,
    startedAtMs: nowMs - 60 * 60 * 1000,
  });

  assert.equal(
    __testHooks.shouldStopMonitoringAsIrrelevant({ score_status: null }, monitorState, nowMs),
    false
  );
  assert.equal(
    __testHooks.shouldStopMonitoringAsIrrelevant(
      { score_status: null },
      monitorState,
      nowMs + 7 * 60 * 60 * 1000
    ),
    true
  );
});

test("buildScoreChangeEvent returns score update when score or status changes", () => {
  const oldMatch = {
    home_team: "Arsenal",
    away_team: "Liverpool",
    home_score: 0,
    away_score: 0,
    score_status: "10'",
    home_goal_scorers: [],
    away_goal_scorers: [],
  };

  const newMatch = {
    ...oldMatch,
    home_score: 1,
    score_status: "12'",
    home_goal_scorers: [{ player: "B. Saka", goal_times: ["12'"] }],
  };

  const event = __testHooks.buildScoreChangeEvent(oldMatch, newMatch);
  assert.ok(event);
  assert.equal(event.type, "score_update");
  assert.equal(event.scoreChanged, true);
  assert.equal(event.statusChanged, true);
  assert.equal(event.current.home_score, 1);
  assert.equal(event.current.away_score, 0);
});

test("buildScoreChangeEvent returns null when score and status unchanged", () => {
  const oldMatch = {
    home_team: "Arsenal",
    away_team: "Liverpool",
    home_score: 1,
    away_score: 1,
    score_status: "HT",
  };

  const newMatch = {
    ...oldMatch,
  };

  const event = __testHooks.buildScoreChangeEvent(oldMatch, newMatch);
  assert.equal(event, null);
});

test("suppresses backfilled goals when score is unchanged", () => {
  const monitorState = newMonitorState();
  const oldMatch = {
    home_team: "Wrexham",
    away_team: "Ipswich Town",
    score_status: "87'",
    home_score: 5,
    away_score: 3,
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
  };

  const newMatch = {
    ...oldMatch,
    score_status: "88'",
    home_goal_scorers: [
      { player: "K. Moore", goal_times: ["6'"] },
      { player: "J. Windass", goal_times: ["37'"] },
      { player: "G. Thomason", goal_times: ["66'"] },
      { player: "C. Doyle", goal_times: ["75'"] },
      { player: "N. Broadhead", goal_times: ["86'"] },
    ],
    away_goal_scorers: [
      { player: "A. Mehmeti", goal_times: ["20'"] },
      { player: "Iván Azón", goal_times: ["45+3'"] },
      { player: "C. Kipré", goal_times: ["47'"] },
    ],
  };

  const goals = __testHooks
    .buildMatchEvents(oldMatch, newMatch, monitorState, Date.now())
    .filter((event) => event.type === "goal");

  assert.equal(goals.length, 0);
});

test("caps backfilled goals to observed score delta", () => {
  const monitorState = newMonitorState();
  const oldMatch = {
    home_team: "Alpha FC",
    away_team: "Beta FC",
    score_status: "65'",
    home_score: 1,
    away_score: 1,
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
  };

  const newMatch = {
    ...oldMatch,
    score_status: "70'",
    home_score: 2,
    away_score: 1,
    home_goal_scorers: [
      { player: "A. One", goal_times: ["10'"] },
      { player: "A. Two", goal_times: ["70'"] },
    ],
    away_goal_scorers: [{ player: "B. One", goal_times: ["20'"] }],
  };

  const goals = __testHooks
    .buildMatchEvents(oldMatch, newMatch, monitorState, Date.now())
    .filter((event) => event.type === "goal");

  assert.equal(goals.length, 1);
  assert.equal(goals[0].title, "Goal 70'");
  assert.equal(goals[0].body, "Alpha FC 2 - 1 Beta FC (A. Two)");
});
