const test = require("node:test");
const assert = require("node:assert/strict");

const matchMonitor = require("./match_monitor");
const { __testHooks } = matchMonitor;

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

test("includes aggregate score in halftime notification body when available", () => {
  const monitorState = newMonitorState();

  const oldMatch = {
    home_team: "Atletico Madrid",
    away_team: "Club Brugge",
    score_status: null,
    home_score: 0,
    away_score: 0,
    home_goal_scorers: [],
    away_goal_scorers: [],
  };

  const newMatch = {
    ...oldMatch,
    score_status: "HT",
    home_score: 1,
    away_score: 0,
    aggregate_home_score: 4,
    aggregate_away_score: 3,
  };

  const events = __testHooks.buildMatchEvents(oldMatch, newMatch, monitorState, Date.now());
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "halftime");
  assert.equal(events[0].body, "Atletico Madrid 1 - 0 Club Brugge (agg: 4-3)");
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

test("includes aggregate score in goal notification body when available", () => {
  const monitorState = newMonitorState();

  const oldMatch = {
    home_team: "Atletico Madrid",
    away_team: "Club Brugge",
    score_status: "10'",
    home_score: 0,
    away_score: 0,
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
  };

  const newMatch = {
    ...oldMatch,
    score_status: "15'",
    home_score: 1,
    away_score: 0,
    aggregate_home_score: 4,
    aggregate_away_score: 3,
    home_goal_scorers: [{ player: "A. Griezmann", goal_times: ["15'"] }],
  };

  const goals = __testHooks
    .buildMatchEvents(oldMatch, newMatch, monitorState, Date.now())
    .filter((event) => event.type === "goal");

  assert.equal(goals.length, 1);
  assert.equal(goals[0].body, "Atletico Madrid 1 - 0 Club Brugge (agg: 4-3) (A. Griezmann)");
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

test("buildScoreChangeEvent includes aggregate score in body when available", () => {
  const oldMatch = {
    home_team: "Atletico Madrid",
    away_team: "Club Brugge",
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
    aggregate_home_score: 4,
    aggregate_away_score: 3,
  };

  const event = __testHooks.buildScoreChangeEvent(oldMatch, newMatch);
  assert.ok(event);
  assert.equal(event.body, "Atletico Madrid 1 - 0 Club Brugge (agg: 4-3) (12')");
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

test("emits goal when timeline appears before score delta", () => {
  const monitorState = newMonitorState();
  const snap0 = {
    home_team: "Sheffield United",
    away_team: "Sheffield Wednesday",
    score_status: null,
    home_score: 0,
    away_score: 0,
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
  };

  const snap1 = {
    ...snap0,
    score_status: "2'",
    home_goal_scorers: [{ player: "P. Bamford", goal_times: ["2'"] }],
    home_assists: [{ player: "G. Hamer", assist_times: ["2'"] }],
  };

  const poll1Goals = __testHooks
    .buildMatchEvents(snap0, snap1, monitorState, Date.now())
    .filter((event) => event.type === "goal");
  assert.equal(poll1Goals.length, 0);

  const snap2 = {
    ...snap1,
    score_status: "4'",
    home_score: 1,
    away_score: 0,
  };

  const poll2Goals = __testHooks
    .buildMatchEvents(snap1, snap2, monitorState, Date.now())
    .filter((event) => event.type === "goal");
  assert.equal(poll2Goals.length, 1);
  assert.equal(poll2Goals[0].title, "Goal 2'");
  assert.equal(
    poll2Goals[0].body,
    "Sheffield United 1 - 0 Sheffield Wednesday (P. Bamford, assist: G. Hamer)"
  );
});

test("prefers newest timeline entries when score catches up after backfill", () => {
  const monitorState = newMonitorState();
  const snap0 = {
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

  const snap1 = {
    ...snap0,
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

  const poll1Goals = __testHooks
    .buildMatchEvents(snap0, snap1, monitorState, Date.now())
    .filter((event) => event.type === "goal");
  assert.equal(poll1Goals.length, 0);

  const snap2 = {
    ...snap1,
    score_status: "89'",
    home_score: 6,
    away_score: 3,
    home_goal_scorers: [...snap1.home_goal_scorers, { player: "S. Smith", goal_times: ["89'"] }],
  };

  const poll2Goals = __testHooks
    .buildMatchEvents(snap1, snap2, monitorState, Date.now())
    .filter((event) => event.type === "goal");
  assert.equal(poll2Goals.length, 1);
  assert.equal(poll2Goals[0].title, "Goal 89'");
  assert.equal(poll2Goals[0].body, "Wrexham 6 - 3 Ipswich Town (S. Smith)");
});

test("getStatus includes monitor diagnostics envelope", () => {
  const status = matchMonitor.getStatus({
    matchId: "c4g79d0dnent",
    limitRecent: 5,
  });

  assert.equal(typeof status.isMonitoring, "boolean");
  assert.ok(Array.isArray(status.monitoredMatchIds));
  assert.ok(Array.isArray(status.monitoredMatches));
  assert.ok(status.diagnostics && typeof status.diagnostics === "object");
  assert.deepEqual(status.diagnostics.filter, {
    match_id: "c4g79d0dnent",
    limit_recent: 5,
  });
  assert.ok(status.diagnostics.coverage_summary && typeof status.diagnostics.coverage_summary === "object");
  assert.equal(
    typeof status.diagnostics.coverage_summary.expected_active_match_count,
    "number"
  );
  assert.equal(
    typeof status.diagnostics.coverage_summary.coverage_ratio,
    "number"
  );
  assert.ok(Array.isArray(status.diagnostics.recent_decisions));
  assert.ok(Array.isArray(status.diagnostics.recent_monitor_starts));
  assert.ok(Array.isArray(status.diagnostics.recent_monitor_stops));
});
