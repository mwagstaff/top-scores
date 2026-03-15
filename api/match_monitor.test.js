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

function formatLocalDateTimeParts(timestampMs) {
  const date = new Date(timestampMs);
  const yyyy = String(date.getFullYear());
  const mm = String(date.getMonth() + 1).padStart(2, "0");
  const dd = String(date.getDate()).padStart(2, "0");
  const hh = String(date.getHours()).padStart(2, "0");
  const min = String(date.getMinutes()).padStart(2, "0");
  return {
    date: `${yyyy}-${mm}-${dd}`,
    time: `${hh}:${min}`,
  };
}

function liveActivityUser(delayMinutes = 5, extraPreferences = {}) {
  return {
    preferences: {
      liveActivityDelayMinutes: delayMinutes,
      ...extraPreferences,
    },
  };
}

function liveActivityUserWithFantasyScore(score, delayMinutes = 5, extraPreferences = {}) {
  return {
    ...liveActivityUser(delayMinutes, extraPreferences),
    fantasy: {
      managerEntryID: 123456,
      squad: {
        managerEntryID: 123456,
        gameweekID: 29,
        gameweekTitle: "GW29",
        effectiveContributions: [{ elementID: 1, displayName: "Saka", teamName: "Arsenal", points: score }],
      },
    },
  };
}

test("isMatchRelevant keeps recently kicked off fixtures eligible until live status arrives", () => {
  const nowMs = Date.now();
  const kickoff = formatLocalDateTimeParts(nowMs - 5 * 60 * 1000);

  assert.equal(
    __testHooks.isMatchRelevant(
      {
        date: kickoff.date,
        time: kickoff.time,
        home_team: "Burnley",
        away_team: "Bournemouth",
        score_status: null,
      },
      nowMs
    ),
    true
  );
});

test("mergeSnapshotWithFallback preserves existing league when new payload omits it", () => {
  const merged = __testHooks.mergeSnapshotWithFallback(
    {
      league: "La Liga",
      home_team: "Rayo Vallecano",
      away_team: "Real Oviedo",
      score_status: "55",
    },
    {
      league: null,
      home_team: "Rayo Vallecano",
      away_team: "Real Oviedo",
      score_status: "56",
    }
  );

  assert.equal(merged.league, "La Liga");
  assert.equal(merged.score_status, "56");
});

test("mergeSnapshotWithFallback clears stale aggregate when incoming payload sets aggregate to null", () => {
  const merged = __testHooks.mergeSnapshotWithFallback(
    {
      home_team: "Tottenham Hotspur",
      away_team: "Crystal Palace",
      score_status: "21",
      aggregate_home_score: 0,
      aggregate_away_score: 0,
    },
    {
      score_status: "22",
      aggregate_home_score: null,
      aggregate_away_score: null,
    }
  );

  assert.equal(merged.score_status, "22");
  assert.equal(merged.aggregate_home_score, null);
  assert.equal(merged.aggregate_away_score, null);
});

test("updateScoreReversionState tracks three consecutive BBC score reversions before confirmation", () => {
  const state = newMonitorState();
  const baseline = {
    home_team: "Leeds United",
    away_team: "Norwich City",
    home_score: 1,
    away_score: 0,
    score_status: "20",
    home_goal_scorers: [
      {
        player: "Lukas Nmecha",
        goal_times: ["19'"],
      },
    ],
    home_assists: [
      {
        player: "Wilfried Gnonto",
        assist_times: ["19'"],
      },
    ],
    away_goal_scorers: [],
  };
  const reverted = {
    home_team: "Leeds United",
    away_team: "Norwich City",
    home_score: 0,
    away_score: 0,
    score_status: "21",
    home_goal_scorers: [],
    home_assists: [],
    away_goal_scorers: [],
  };

  let reversion = __testHooks.updateScoreReversionState(state, baseline, reverted, 1000);
  assert.equal(reversion.consecutivePolls, 1);
  assert.equal(reversion.affectedTeam, "home");
  assert.equal(reversion.removedGoal.goalTime, "19'");
  assert.equal(reversion.removedGoal.player, "Lukas Nmecha");
  assert.equal(reversion.removedGoal.assister, "Wilfried Gnonto");

  for (let index = 0; index < 2; index += 1) {
    reversion = __testHooks.updateScoreReversionState(state, reverted, reverted, 1001 + index);
  }

  assert.equal(reversion.consecutivePolls, 3);
  assert.deepStrictEqual(reversion.baseline, {
    home_score: 1,
    away_score: 0,
    score_status: "20",
  });
  assert.deepStrictEqual(reversion.reverted, {
    home_score: 0,
    away_score: 0,
    score_status: "21",
  });
});

test("confirmVarDisallowedGoal matches BBC LiveText overturned goal entries", async () => {
  const reversionState = {
    baseline: {
      home_score: 1,
      away_score: 0,
      score_status: "20",
    },
    reverted: {
      home_score: 0,
      away_score: 0,
      score_status: "21",
    },
    affectedTeam: "home",
    consecutivePolls: 3,
    removedGoal: {
      team: "home",
      player: "Lukas Nmecha",
      goalTime: "19'",
      assister: "Wilfried Gnonto",
      minute: 19,
    },
  };

  const confirmation = await __testHooks.confirmVarDisallowedGoal(
    "cr5lln18q4lt",
    {
      home_team: "Leeds United",
      away_team: "Norwich City",
      details_url: "https://www.bbc.co.uk/sport/football/live/cr5lln18q4lt",
    },
    reversionState,
    {
      fetchLiveText: async () => ({
        entries: [
          {
            minute: "21'",
            minute_value: 21,
            text: "VAR Decision: No Goal Leeds United 0-0 Norwich City.",
          },
          {
            minute: "19'",
            minute_value: 19,
            text: "GOAL OVERTURNED BY VAR: Lukas Nmecha (Leeds United) scores but the goal is ruled out after a VAR review.",
          },
        ],
      }),
    }
  );

  assert.deepStrictEqual(confirmation, {
    team: "home",
    scorer: "Lukas Nmecha",
    goalMinuteLabel: "19'",
    decisionMinuteLabel: "21'",
  });
  assert.equal(Number.isFinite(reversionState.confirmedAtMs), true);
});

test("confirmScoreCorrection matches on-pitch offside reversions without VAR", async () => {
  const reversionState = {
    baseline: {
      home_score: 1,
      away_score: 0,
      score_status: "74",
    },
    reverted: {
      home_score: 0,
      away_score: 0,
      score_status: "74",
    },
    affectedTeam: "home",
    consecutivePolls: 3,
    removedGoal: {
      team: "home",
      player: "Joelinton",
      goalTime: "74'",
      assister: null,
      minute: 74,
    },
  };

  const confirmation = await __testHooks.confirmScoreCorrection(
    "c0rjxqpdjert",
    {
      home_team: "Newcastle United",
      away_team: "Barcelona",
      details_url: "https://www.bbc.co.uk/sport/football/live/c0rjxqpdjert",
    },
    reversionState,
    {
      fetchLiveText: async () => ({
        entries: [
          {
            minute: "74'",
            minute_value: 74,
            text: "Offside, Newcastle United. Joelinton is caught offside.",
          },
        ],
      }),
    }
  );

  assert.deepStrictEqual(confirmation, {
    team: "home",
    scorer: "Joelinton",
    goalMinuteLabel: "74'",
    correctionMinuteLabel: "74'",
  });
  assert.equal(Number.isFinite(reversionState.confirmedAtMs), true);
});

test("confirmScoreCorrection waits for longer stable reversion when live text has no explicit cause", async () => {
  const reversionState = {
    baseline: {
      home_score: 1,
      away_score: 0,
      score_status: "74",
    },
    reverted: {
      home_score: 0,
      away_score: 0,
      score_status: "75",
    },
    affectedTeam: "home",
    consecutivePolls: 4,
    removedGoal: {
      team: "home",
      player: "Joelinton",
      goalTime: "74'",
      assister: null,
      minute: 74,
    },
  };

  const match = {
    home_team: "Newcastle United",
    away_team: "Barcelona",
    details_url: "https://www.bbc.co.uk/sport/football/live/c0rjxqpdjert",
  };
  const options = {
    fetchLiveText: async () => ({
      entries: [
        {
          minute: "75'",
          minute_value: 75,
          text: "Attempt missed. Harvey Barnes (Newcastle United) right footed shot from outside the box is close.",
        },
      ],
    }),
  };

  assert.equal(await __testHooks.confirmScoreCorrection("c0rjxqpdjert", match, reversionState, options), null);
  assert.equal(reversionState.confirmedAtMs, undefined);

  reversionState.consecutivePolls = 5;

  const confirmation = await __testHooks.confirmScoreCorrection("c0rjxqpdjert", match, reversionState, options);
  assert.deepStrictEqual(confirmation, {
    team: "home",
    scorer: "Joelinton",
    goalMinuteLabel: "74'",
    correctionMinuteLabel: null,
  });
  assert.equal(Number.isFinite(reversionState.confirmedAtMs), true);
});

test("buildVarDisallowedGoalEvent uses goal notification semantics and reverted scoreline", () => {
  const event = __testHooks.buildVarDisallowedGoalEvent(
    "cr5lln18q4lt",
    {
      home_team: "Leeds United",
      away_team: "Norwich City",
      home_score: 0,
      away_score: 0,
    },
    {
      team: "home",
      scorer: "Lukas Nmecha",
      goalMinuteLabel: "19'",
      decisionMinuteLabel: "21'",
    },
    {
      affectedTeam: "home",
      removedGoal: {
        player: "Lukas Nmecha",
        assister: "Wilfried Gnonto",
        goalTime: "19'",
      },
    }
  );

  assert.equal(event.type, "goal");
  assert.equal(event.disallowedByVar, true);
  assert.equal(event.title, "Goal disallowed by VAR 19'");
  assert.equal(event.body, "Leeds United 0 - 0 Norwich City");
  assert.equal(event.scorer, "Lukas Nmecha");
  assert.equal(event.assister, "Wilfried Gnonto");
  assert.equal(event.varDecisionTime, "21'");
});

test("buildScoreCorrectionEvent uses goal notification semantics and reverted scoreline", () => {
  const event = __testHooks.buildScoreCorrectionEvent(
    "c0rjxqpdjert",
    {
      home_team: "Newcastle United",
      away_team: "Barcelona",
      home_score: 0,
      away_score: 0,
    },
    {
      team: "home",
      scorer: "Joelinton",
      goalMinuteLabel: "74'",
      correctionMinuteLabel: "74'",
    },
    {
      affectedTeam: "home",
      removedGoal: {
        player: "Joelinton",
        assister: null,
        goalTime: "74'",
      },
    }
  );

  assert.equal(event.type, "goal");
  assert.equal(event.scoreCorrection, true);
  assert.equal(event.title, "Score correction");
  assert.equal(event.body, "Newcastle United 0 - 0 Barcelona");
  assert.equal(event.scorer, "Joelinton");
  assert.equal(event.goalTime, "74'");
});

test("buildNotificationPayload preserves disallowed-goal metadata for APNS delivery", () => {
  const payload = __testHooks.buildNotificationPayload("cr5lln18q4lt", {
    type: "goal",
    eventKey: "var_disallowed:home:19':Lukas Nmecha:cr5lln18q4lt",
    goalTime: "19'",
    disallowedByVar: true,
    varDecisionTime: "21'",
  });

  assert.deepStrictEqual(payload, {
    event_type: "goal",
    match_id: "cr5lln18q4lt",
    event_key: "var_disallowed:home:19':Lukas Nmecha:cr5lln18q4lt",
    goal_time: "19'",
    disallowed_by_var: true,
    var_decision_time: "21'",
  });
});

test("buildNotificationPayload preserves score-correction metadata for APNS delivery", () => {
  const payload = __testHooks.buildNotificationPayload("c0rjxqpdjert", {
    type: "goal",
    eventKey: "score_correction:home:74':Joelinton:0:0:c0rjxqpdjert",
    goalTime: "74'",
    scoreCorrection: true,
  });

  assert.deepStrictEqual(payload, {
    event_type: "goal",
    match_id: "c0rjxqpdjert",
    event_key: "score_correction:home:74':Joelinton:0:0:c0rjxqpdjert",
    goal_time: "74'",
    score_correction: true,
  });
});

test("shouldSkipLiveActivityUpdate bypasses payload dedupe when forceDispatch is enabled", () => {
  const state = {
    lastPayloadHash: "abc123",
    lastScoreHash: "score123",
    lastMode: "multi_live",
    lastDispatchAt: "2026-03-13T12:00:00.000Z",
  };

  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "abc123", "multi_live", false),
    true
  );
  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "abc123", "multi_live", true),
    false
  );
});

test("buildLiveActivityPayloadHash ignores generatedAtEpochSeconds", () => {
  const baseline = {
    mode: "multi_live",
    generatedAtEpochSeconds: 100,
    delayMinutes: 0,
    delayLabel: null,
    matches: [
      {
        matchId: "abc",
        homeTeam: "Arsenal",
        awayTeam: "Chelsea",
        homeScore: 1,
        awayScore: 0,
        matchTime: "55",
      },
    ],
  };

  const updatedTimestamp = {
    ...baseline,
    generatedAtEpochSeconds: 145,
  };

  assert.equal(
    __testHooks.buildLiveActivityPayloadHash(baseline),
    __testHooks.buildLiveActivityPayloadHash(updatedTimestamp)
  );
});

test("shouldSkipLiveActivityUpdate throttles live non-score changes to once per minute", () => {
  const state = {
    lastPayloadHash: "old-payload",
    lastScoreHash: "score123",
    lastMode: "multi_live",
    lastDispatchAt: "2026-03-13T12:00:00.000Z",
  };

  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "new-payload", "multi_live", false, {
      scoreHash: "score123",
      nowMs: Date.parse("2026-03-13T12:00:45.000Z"),
    }),
    true
  );
  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "new-payload", "multi_live", false, {
      scoreHash: "score123",
      nowMs: Date.parse("2026-03-13T12:01:01.000Z"),
    }),
    false
  );
});

test("shouldSkipLiveActivityUpdate dispatches live score changes immediately", () => {
  const state = {
    lastPayloadHash: "old-payload",
    lastScoreHash: "score123",
    lastMode: "multi_live",
    lastDispatchAt: "2026-03-13T12:00:00.000Z",
  };

  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "new-payload", "multi_live", false, {
      scoreHash: "score456",
      nowMs: Date.parse("2026-03-13T12:00:15.000Z"),
    }),
    false
  );
});

test("shouldSkipLiveActivityUpdate dispatches non-live changes immediately", () => {
  const state = {
    lastPayloadHash: "old-payload",
    lastScoreHash: "score123",
    lastMode: "multi_upcoming",
    lastDispatchAt: "2026-03-13T12:00:00.000Z",
  };

  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "new-payload", "multi_upcoming", false, {
      scoreHash: "score123",
      nowMs: Date.parse("2026-03-13T12:00:15.000Z"),
    }),
    false
  );
});

test("shouldPreserveExistingLiveActivityOnEmpty keeps active activity during forced startup reconcile", () => {
  assert.equal(
    __testHooks.shouldPreserveExistingLiveActivityOnEmpty("activity-token-123", {
      preserveExistingOnEmpty: true,
    }),
    true
  );
  assert.equal(
    __testHooks.shouldPreserveExistingLiveActivityOnEmpty("activity-token-123", {
      preserveExistingOnEmpty: false,
    }),
    false
  );
  assert.equal(
    __testHooks.shouldPreserveExistingLiveActivityOnEmpty("", {
      preserveExistingOnEmpty: true,
    }),
    false
  );
});

test("buildLiveActivityPresentationForUser suppresses stale high-minute live status and ends activity", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 130 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(),
    [
      {
        state: null,
        match: {
          match_details_id: "c4gq92l5de2t",
          date: kickoff.date,
          time: kickoff.time,
          league: "Premier League",
          home_team: "Tottenham Hotspur",
          away_team: "Crystal Palace",
          home_score: 1,
          away_score: 3,
          score_status: "90+5",
          updated_at: new Date(nowMs - 8 * 60 * 1000).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, null);
  assert.equal(Array.isArray(presentation.matches), true);
  assert.equal(presentation.matches.length, 0);
});

test("buildLiveActivityPresentationForUser excludes non-Premier League matches when EPL-only filter is enabled", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 12 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(0, {
      englishPremierLeagueTeamsOnly: true,
    }),
    [
      {
        state: null,
        match: {
          match_details_id: "cexample123",
          date: kickoff.date,
          time: kickoff.time,
          league: "UEFA Champions League",
          home_team: "Galatasaray",
          away_team: "Barcelona",
          home_score: 1,
          away_score: 0,
          score_status: "12",
          tv_channels: ["TNT Sports 1"],
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, null);
  assert.deepStrictEqual(presentation.matches, []);
});

test("buildLiveActivityPresentationForUser excludes matches without matching TV channels when channel filtering is enabled", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 12 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(0, {
      channelFilterEnabled: true,
      selectedChannels: ["TNT (all)"],
    }),
    [
      {
        state: null,
        match: {
          match_details_id: "cexample456",
          date: kickoff.date,
          time: kickoff.time,
          league: "UEFA Champions League",
          home_team: "Real Madrid",
          away_team: "Manchester City",
          home_score: 0,
          away_score: 0,
          score_status: "12",
          tv_channels: [],
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, null);
  assert.deepStrictEqual(presentation.matches, []);
});

test("buildLiveActivityEntriesForUser uses the first filtered fixture section and ignores stale extra matches", () => {
  const nowMs = Date.parse("2026-03-10T23:21:00Z");
  const user = liveActivityUser(0, {
    englishPremierLeagueTeamsOnly: true,
  });

  const monitoredEntries = [
    {
      matchId: "cnewbarca",
      state: {
        lastState: {
          match_details_id: "cnewbarca",
          date: "2026-03-10",
          time: "19:45",
          league: "UEFA Champions League",
          home_team: "Newcastle United",
          away_team: "Barcelona",
          home_score: 1,
          away_score: 0,
          score_status: "90+8",
          updated_at: "2026-03-10T22:15:00Z",
        },
      },
      match: {
        match_details_id: "cnewbarca",
        date: "2026-03-10",
        time: "19:45",
        league: "UEFA Champions League",
        home_team: "Newcastle United",
        away_team: "Barcelona",
        home_score: 1,
        away_score: 0,
        score_status: "90+8",
        updated_at: "2026-03-10T22:15:00Z",
      },
    },
    {
      matchId: "coldmatch",
      state: null,
      match: {
        match_details_id: "coldmatch",
        date: "2026-03-08",
        time: "16:30",
        league: "Premier League",
        home_team: "Brighton & Hove Albion",
        away_team: "Arsenal",
        home_score: 0,
        away_score: 1,
        score_status: "FT",
      },
    },
  ];

  const operationalMatches = [
    {
      match_details_id: "coldmatch",
      date: "2026-03-08",
      time: "16:30",
      league: "Premier League",
      home_team: "Brighton & Hove Albion",
      away_team: "Arsenal",
      home_score: 0,
      away_score: 1,
      score_status: "FT",
      tv_channels: ["Sky Sports Premier League"],
    },
    {
      match_details_id: "cshwwat",
      date: "2026-03-10",
      time: "19:45",
      league: "Championship",
      home_team: "Sheffield Wednesday",
      away_team: "Watford",
      home_score: null,
      away_score: null,
      score_status: null,
      tv_channels: ["Sky Sports Football"],
    },
    {
      match_details_id: "cgalliv",
      date: "2026-03-10",
      time: "19:45",
      league: "UEFA Champions League",
      home_team: "Galatasaray",
      away_team: "Liverpool",
      home_score: 1,
      away_score: 0,
      score_status: "FT",
      tv_channels: ["Amazon Prime Video"],
    },
    {
      match_details_id: "cnewbarca",
      date: "2026-03-10",
      time: "19:45",
      league: "UEFA Champions League",
      home_team: "Newcastle United",
      away_team: "Barcelona",
      home_score: 1,
      away_score: 1,
      score_status: "FT",
      tv_channels: ["Amazon Prime Video"],
    },
    {
      match_details_id: "catmtot",
      date: "2026-03-10",
      time: "20:00",
      league: "UEFA Champions League",
      home_team: "Atletico Madrid",
      away_team: "Tottenham Hotspur",
      home_score: 5,
      away_score: 2,
      score_status: "FT",
      tv_channels: ["Amazon Prime Video"],
    },
    {
      match_details_id: "ctomorrow",
      date: "2026-03-11",
      time: "20:00",
      league: "UEFA Champions League",
      home_team: "Real Madrid",
      away_team: "Manchester City",
      home_score: null,
      away_score: null,
      score_status: null,
      tv_channels: ["TNT Sports 1"],
    },
  ];

  const entries = __testHooks.buildLiveActivityEntriesForUser(
    user,
    monitoredEntries,
    operationalMatches,
    nowMs
  );

  assert.deepStrictEqual(
    entries.map((entry) => entry.match.match_details_id),
    ["cgalliv", "cnewbarca", "catmtot"]
  );
  assert.equal(entries[1].match.score_status, "FT");
  assert.equal(entries[1].match.home_score, 1);
  assert.equal(entries[1].match.away_score, 1);
});

test("buildLiveActivityEntriesForUser keeps monitored live matches when the operational feed drops them", () => {
  const nowMs = Date.parse("2026-03-14T20:35:16Z");
  const user = liveActivityUser(2, {
    englishPremierLeagueTeamsOnly: true,
  });

  const monitoredEntries = [
    {
      matchId: "cpqw34l8xrnt",
      state: {
        lastState: {
          match_details_id: "cpqw34l8xrnt",
          date: "2026-03-14",
          time: "20:00",
          league: "Premier League",
          home_team: "West Ham United",
          away_team: "Manchester City",
          home_score: 0,
          away_score: 1,
          score_status: "36",
          updated_at: "2026-03-14T20:35:03Z",
        },
        history: [
          {
            timestampMs: nowMs - 5 * 60 * 1000,
            match: {
              match_details_id: "cpqw34l8xrnt",
              date: "2026-03-14",
              time: "20:00",
              league: "Premier League",
              home_team: "West Ham United",
              away_team: "Manchester City",
              home_score: 0,
              away_score: 0,
              score_status: "31",
            },
          },
        ],
      },
      match: {
        match_details_id: "cpqw34l8xrnt",
        date: "2026-03-14",
        time: "20:00",
        league: "Premier League",
        home_team: "West Ham United",
        away_team: "Manchester City",
        home_score: 0,
        away_score: 1,
        score_status: "36",
        updated_at: "2026-03-14T20:35:03Z",
      },
    },
  ];

  const operationalMatches = [
    {
      match_details_id: "cz0gjnl5ev8t",
      date: "2026-03-14",
      time: "17:30",
      league: "Premier League",
      home_team: "Arsenal",
      away_team: "Everton",
      home_score: 2,
      away_score: 0,
      score_status: "FT",
      tv_channels: ["TNT Sports 1"],
    },
    {
      match_details_id: "cjengzxj4e0t",
      date: "2026-03-14",
      time: "17:30",
      league: "Premier League",
      home_team: "Chelsea",
      away_team: "Newcastle United",
      home_score: 0,
      away_score: 1,
      score_status: "FT",
      tv_channels: ["TNT Sports 1"],
    },
  ];

  const entries = __testHooks.buildLiveActivityEntriesForUser(
    user,
    monitoredEntries,
    operationalMatches,
    nowMs
  );

  assert.deepStrictEqual(
    entries.map((entry) => entry.match.match_details_id),
    ["cz0gjnl5ev8t", "cjengzxj4e0t", "cpqw34l8xrnt"]
  );
  assert.equal(entries[2].match.score_status, "36");
  assert.equal(entries[2].match.home_score, 0);
  assert.equal(entries[2].match.away_score, 1);
});

test("buildLiveActivityEntriesForUser dedupes canonical and monitored copies of the same fixture", () => {
  const nowMs = Date.parse("2026-03-14T20:44:07Z");
  const user = liveActivityUser(2, {
    englishPremierLeagueTeamsOnly: true,
  });

  const monitoredEntries = [
    {
      matchId: "cpqw34l8xrnt",
      state: {
        lastState: {
          match_details_id: "cpqw34l8xrnt",
          date: "2026-03-14",
          time: "20:00",
          league: "Premier League",
          home_team: "West Ham United",
          away_team: "Manchester City",
          home_score: 1,
          away_score: 1,
          score_status: "43",
          updated_at: "2026-03-14T20:43:50Z",
        },
        history: [
          {
            timestampMs: nowMs - 3 * 60 * 1000,
            match: {
              match_details_id: "cpqw34l8xrnt",
              date: "2026-03-14",
              time: "20:00",
              league: "Premier League",
              home_team: "West Ham United",
              away_team: "Manchester City",
              home_score: 0,
              away_score: 0,
              score_status: "41",
            },
          },
        ],
      },
      match: {
        match_details_id: "cpqw34l8xrnt",
        date: "2026-03-14",
        time: "20:00",
        league: "Premier League",
        home_team: "West Ham United",
        away_team: "Manchester City",
        home_score: 1,
        away_score: 1,
        score_status: "43",
        updated_at: "2026-03-14T20:43:50Z",
      },
    },
    {
      matchId: "cz0gjnl5ev8t",
      state: {
        lastState: {
          match_details_id: "cz0gjnl5ev8t",
          date: "2026-03-14",
          time: "17:30",
          league: "Premier League",
          home_team: "Arsenal",
          away_team: "Everton",
          home_score: 2,
          away_score: 0,
          score_status: "FT",
          updated_at: "2026-03-14T19:33:00Z",
        },
        finishedAtMs: nowMs - 70 * 60 * 1000,
      },
      match: {
        match_details_id: "cz0gjnl5ev8t",
        date: "2026-03-14",
        time: "17:30",
        league: "Premier League",
        home_team: "Arsenal",
        away_team: "Everton",
        home_score: 2,
        away_score: 0,
        score_status: "FT",
        updated_at: "2026-03-14T19:33:00Z",
      },
    },
  ];

  const operationalMatches = [
    {
      date: "2026-03-14",
      time: "17:30",
      league: "Premier League",
      home_team: "Arsenal",
      away_team: "Everton",
      home_score: 2,
      away_score: 0,
      score_status: "FT",
      tv_channels: ["TNT Sports 1"],
    },
    {
      date: "2026-03-14",
      time: "20:00",
      league: "Premier League",
      home_team: "West Ham United",
      away_team: "Manchester City",
      home_score: null,
      away_score: null,
      score_status: null,
      tv_channels: ["TNT Sports 1"],
    },
  ];

  const entries = __testHooks.buildLiveActivityEntriesForUser(
    user,
    monitoredEntries,
    operationalMatches,
    nowMs
  );

  assert.deepStrictEqual(
    entries.map((entry) => entry.match.home_team),
    ["Arsenal", "West Ham United"]
  );
  assert.deepStrictEqual(
    entries.map((entry) => entry.match.match_details_id),
    ["cz0gjnl5ev8t", "cpqw34l8xrnt"]
  );
  assert.equal(entries[1].match.score_status, "43");
  assert.equal(entries[1].match.home_score, 1);
  assert.equal(entries[1].match.away_score, 1);
});

test("mergeCanonicalLiveActivityMatch keeps fresher live state for active matches", () => {
  const merged = __testHooks.mergeCanonicalLiveActivityMatch(
    {
      match_details_id: "clive123",
      date: "2026-03-10",
      time: "19:45",
      league: "Premier League",
      home_team: "Arsenal",
      away_team: "Chelsea",
      home_score: 0,
      away_score: 0,
      score_status: "12",
      tv_channels: ["Sky Sports Main Event"],
    },
    {
      match_details_id: "clive123",
      date: "2026-03-10",
      time: "19:45",
      league: "Premier League",
      home_team: "Arsenal",
      away_team: "Chelsea",
      home_score: 1,
      away_score: 0,
      score_status: "13",
      tv_channels: ["Sky Sports Main Event"],
    }
  );

  assert.equal(merged.score_status, "13");
  assert.equal(merged.home_score, 1);
  assert.equal(merged.away_score, 0);
});

test("mergeCanonicalLiveActivityMatch prefers more advanced canonical state when monitor regresses", () => {
  const merged = __testHooks.mergeCanonicalLiveActivityMatch(
    {
      match_details_id: "c5yvwz1d5l2t",
      date: "2026-03-11",
      time: "19:45",
      league: "UEFA Champions League",
      home_team: "Bayer Leverkusen",
      away_team: "Arsenal",
      home_score: 1,
      away_score: 0,
      score_status: "85",
      home_goal_scorers: [
        {
          player: "Victor Boniface",
          goal_times: ["60'"],
          own_goal_times: [],
        },
      ],
      away_goal_scorers: [],
      updated_at: "2026-03-11T19:27:00.000Z",
      tv_channels: ["TNT Sports 3"],
    },
    {
      match_details_id: "c5yvwz1d5l2t",
      date: "2026-03-11",
      time: "19:45",
      league: "UEFA Champions League",
      home_team: "Bayer Leverkusen",
      away_team: "Arsenal",
      home_score: 0,
      away_score: 0,
      score_status: "47",
      home_goal_scorers: [],
      away_goal_scorers: [],
      updated_at: "2026-03-11T18:49:00.000Z",
      tv_channels: ["TNT Sports 3"],
    }
  );

  assert.equal(merged.score_status, "85");
  assert.equal(merged.home_score, 1);
  assert.equal(merged.away_score, 0);
  assert.deepStrictEqual(merged.home_goal_scorers, [
    {
      player: "Victor Boniface",
      goal_times: ["60'"],
      own_goal_times: [],
    },
  ]);
});

test("buildLiveActivityContentState canonicalizes TV channels for logo-friendly payloads", () => {
  const contentState = __testHooks.buildLiveActivityContentState(
    "single_finished",
    [
      {
        match_details_id: "cexample789",
        date: "2026-03-10",
        time: "19:45",
        league: "UEFA Champions League",
        home_team: "Newcastle United",
        away_team: "Barcelona",
        home_score: 1,
        away_score: 1,
        score_status: "FT",
        tv_channels: ["Amazon Prime Video", "TNT Sports 1", "Amazon Prime Video"],
      },
    ],
    2,
    Date.now()
  );

  assert.deepStrictEqual(contentState.matches[0].tvChannels, ["Amazon", "TNT Sports"]);
});

test("buildLiveActivityPresentationForUser clears delayed aggregate when current snapshot explicitly clears it", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 8 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(),
    [
      {
        state: {
          lastState: {
            match_details_id: "ce8nq755jqdt",
            date: kickoff.date,
            time: kickoff.time,
            league: "Bundesliga",
            home_team: "Bayern Munich",
            away_team: "Borussia M'gladbach",
            home_score: 0,
            away_score: 0,
            score_status: "8",
            aggregate_home_score: null,
            aggregate_away_score: null,
            updated_at: new Date(nowMs).toISOString(),
          },
          history: [
            {
              timestampMs: nowMs - 6 * 60 * 1000,
              match: {
                match_details_id: "ce8nq755jqdt",
                date: kickoff.date,
                time: kickoff.time,
                league: "Bundesliga",
                home_team: "Bayern Munich",
                away_team: "Borussia M'gladbach",
                home_score: 0,
                away_score: 0,
                score_status: null,
                aggregate_home_score: 0,
                aggregate_away_score: 0,
              },
            },
          ],
        },
        match: {
          match_details_id: "ce8nq755jqdt",
          date: kickoff.date,
          time: kickoff.time,
          league: "Bundesliga",
          home_team: "Bayern Munich",
          away_team: "Borussia M'gladbach",
          home_score: 0,
          away_score: 0,
          score_status: "8",
          aggregate_home_score: null,
          aggregate_away_score: null,
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].score_status, "3");
  assert.equal(presentation.matches[0].aggregate_home_score, null);
  assert.equal(presentation.matches[0].aggregate_away_score, null);
});

test("buildLiveActivityPresentationForUser suppresses zero aggregate for upcoming live activity entries", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs + 10 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(),
    [
      {
        state: null,
        match: {
          match_details_id: "ce8nq755jqdt",
          date: kickoff.date,
          time: kickoff.time,
          league: "Bundesliga",
          home_team: "Bayern Munich",
          away_team: "Borussia M'gladbach",
          home_score: null,
          away_score: null,
          score_status: null,
          aggregate_home_score: 0,
          aggregate_away_score: 0,
          updated_at: new Date(nowMs).toISOString(),
        },
      },
      {
        state: null,
        match: {
          match_details_id: "c14mvd1104xt",
          date: kickoff.date,
          time: kickoff.time,
          league: "FA Cup",
          home_team: "Wolves",
          away_team: "Liverpool",
          home_score: null,
          away_score: null,
          score_status: null,
          aggregate_home_score: 0,
          aggregate_away_score: 0,
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "multi_upcoming");
  assert.equal(presentation.matches.length, 2);
  assert.equal(presentation.matches[0].aggregate_home_score, null);
  assert.equal(presentation.matches[0].aggregate_away_score, null);
  assert.equal(presentation.matches[1].aggregate_home_score, null);
  assert.equal(presentation.matches[1].aggregate_away_score, null);
});

test("buildLiveActivityPresentationForUser derives delayed live score from goal timeline up to delayed minute", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 23 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(),
    [
      {
        state: {
          lastState: {
            match_details_id: "c1mj8v11py9t",
            date: kickoff.date,
            time: kickoff.time,
            league: "Serie A",
            home_team: "Napoli",
            away_team: "Torino",
            home_score: 1,
            away_score: 0,
            score_status: "23",
            home_goal_scorers: [
              {
                player: "Alisson Santos",
                goal_times: ["7'"],
                own_goal_times: [],
              },
            ],
            away_goal_scorers: [],
            updated_at: new Date(nowMs).toISOString(),
          },
          history: [
            {
              timestampMs: nowMs - 6 * 60 * 1000,
              match: {
                match_details_id: "c1mj8v11py9t",
                date: kickoff.date,
                time: kickoff.time,
                league: "Serie A",
                home_team: "Napoli",
                away_team: "Torino",
                home_score: 0,
                away_score: 0,
                score_status: "18",
              },
            },
          ],
        },
        match: {
          match_details_id: "c1mj8v11py9t",
          date: kickoff.date,
          time: kickoff.time,
          league: "Serie A",
          home_team: "Napoli",
          away_team: "Torino",
          home_score: 1,
          away_score: 0,
          score_status: "23",
          home_goal_scorers: [
            {
              player: "Alisson Santos",
              goal_times: ["7'"],
              own_goal_times: [],
            },
          ],
          away_goal_scorers: [],
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].score_status, "18");
  assert.equal(presentation.matches[0].home_score, 1);
  assert.equal(presentation.matches[0].away_score, 0);
});

test("buildLiveActivityPresentationForUser derives delayed live minute from current status when delayed snapshot status is missing", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 23 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(),
    [
      {
        state: {
          lastState: {
            match_details_id: "c1mj8v11py9t",
            date: kickoff.date,
            time: kickoff.time,
            league: "Serie A",
            home_team: "Napoli",
            away_team: "Torino",
            home_score: 1,
            away_score: 0,
            score_status: "23",
            home_goal_scorers: [
              {
                player: "Alisson Santos",
                goal_times: ["7'"],
                own_goal_times: [],
              },
            ],
            away_goal_scorers: [],
            updated_at: new Date(nowMs).toISOString(),
          },
          history: [
            {
              timestampMs: nowMs - 6 * 60 * 1000,
              match: {
                match_details_id: "c1mj8v11py9t",
                date: kickoff.date,
                time: kickoff.time,
                league: "Serie A",
                home_team: "Napoli",
                away_team: "Torino",
                home_score: 0,
                away_score: 0,
                score_status: null,
              },
            },
          ],
        },
        match: {
          match_details_id: "c1mj8v11py9t",
          date: kickoff.date,
          time: kickoff.time,
          league: "Serie A",
          home_team: "Napoli",
          away_team: "Torino",
          home_score: 1,
          away_score: 0,
          score_status: "23",
          home_goal_scorers: [
            {
              player: "Alisson Santos",
              goal_times: ["7'"],
              own_goal_times: [],
            },
          ],
          away_goal_scorers: [],
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].score_status, "18");
  assert.equal(presentation.matches[0].home_score, 1);
  assert.equal(presentation.matches[0].away_score, 0);
});

test("buildLiveActivityPresentationForUser keeps live match visible during restart before full delay buffer exists", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 23 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(),
    [
      {
        state: {
          lastState: {
            match_details_id: "c1mj8v11py9t",
            date: kickoff.date,
            time: kickoff.time,
            league: "Serie A",
            home_team: "Napoli",
            away_team: "Torino",
            home_score: 1,
            away_score: 0,
            score_status: "23",
            home_goal_scorers: [
              {
                player: "Alisson Santos",
                goal_times: ["7'"],
                own_goal_times: [],
              },
            ],
            away_goal_scorers: [],
            updated_at: new Date(nowMs).toISOString(),
          },
          history: [
            {
              timestampMs: nowMs - 60 * 1000,
              match: {
                match_details_id: "c1mj8v11py9t",
                date: kickoff.date,
                time: kickoff.time,
                league: "Serie A",
                home_team: "Napoli",
                away_team: "Torino",
                home_score: 1,
                away_score: 0,
                score_status: "23",
              },
            },
          ],
        },
        match: {
          match_details_id: "c1mj8v11py9t",
          date: kickoff.date,
          time: kickoff.time,
          league: "Serie A",
          home_team: "Napoli",
          away_team: "Torino",
          home_score: 1,
          away_score: 0,
          score_status: "23",
          home_goal_scorers: [
            {
              player: "Alisson Santos",
              goal_times: ["7'"],
              own_goal_times: [],
            },
          ],
          away_goal_scorers: [],
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].score_status, "23");
  assert.equal(presentation.matches[0].home_score, 1);
  assert.equal(presentation.matches[0].away_score, 0);
});

test("buildLiveActivityPresentationForUser uses notification delay when no dedicated live activity delay is configured", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 23 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    { preferences: { notificationDelayMinutes: 5 } },
    [
      {
        state: {
          lastState: {
            match_details_id: "ce8nq755jqdt",
            date: kickoff.date,
            time: kickoff.time,
            league: "Bundesliga",
            home_team: "Bayern Munich",
            away_team: "Borussia M'gladbach",
            home_score: 4,
            away_score: 0,
            score_status: "86",
            updated_at: new Date(nowMs).toISOString(),
          },
          history: [
            {
              timestampMs: nowMs - 6 * 60 * 1000,
              match: {
                match_details_id: "ce8nq755jqdt",
                date: kickoff.date,
                time: kickoff.time,
                league: "Bundesliga",
                home_team: "Bayern Munich",
                away_team: "Borussia M'gladbach",
                home_score: 3,
                away_score: 0,
                score_status: "81",
              },
            },
          ],
        },
        match: {
          match_details_id: "ce8nq755jqdt",
          date: kickoff.date,
          time: kickoff.time,
          league: "Bundesliga",
          home_team: "Bayern Munich",
          away_team: "Borussia M'gladbach",
          home_score: 4,
          away_score: 0,
          score_status: "86",
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.delayMinutes, 5);
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].score_status, "81");
  assert.equal(presentation.matches[0].home_score, 3);
  assert.equal(presentation.matches[0].away_score, 0);
});

test("calculateFantasyCurrentScore prefers synced effective contributions", () => {
  assert.equal(
    __testHooks.calculateFantasyCurrentScore({
      managerEntryID: 6653695,
      squad: {
        managerEntryID: 6653695,
        gameweekID: 29,
        gameweekTitle: "GW29",
        effectiveContributions: [
          { elementID: 1, displayName: "Saka", teamName: "Arsenal", points: 14 },
          { elementID: 2, displayName: "Palmer", teamName: "Chelsea", points: 15 },
        ],
        resolvedCurrentScore: 0,
      },
    }),
    29
  );
});

test("buildLiveActivityPresentationForUser includes synced fantasy score when available", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs + 10 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUserWithFantasyScore(29, 0),
    [
      {
        state: null,
        match: {
          match_details_id: "ff-upcoming",
          date: kickoff.date,
          time: kickoff.time,
          league: "Premier League",
          home_team: "Arsenal",
          away_team: "Chelsea",
          home_score: null,
          away_score: null,
          score_status: null,
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_upcoming");
  assert.equal(presentation.fantasyCurrentScore, 29);

  const contentState = __testHooks.buildLiveActivityContentState(
    presentation.mode,
    presentation.matches,
    presentation.delayMinutes,
    nowMs,
    presentation.fantasyCurrentScore
  );

  assert.equal(contentState.fantasyCurrentScore, 29);
  assert.notEqual(
    __testHooks.buildLiveActivityScoreHash(contentState),
    __testHooks.buildLiveActivityScoreHash({
      ...contentState,
      fantasyCurrentScore: 28,
    })
  );
});

test("buildLiveActivityPresentationForUser ignores stale delayed snapshots and reconstructs from current timeline", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 85 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(2),
    [
      {
        state: {
          lastState: {
            match_details_id: "c5yvwz1d5l2t",
            date: kickoff.date,
            time: kickoff.time,
            league: "UEFA Champions League",
            home_team: "Bayer Leverkusen",
            away_team: "Arsenal",
            home_score: 0,
            away_score: 0,
            score_status: "47",
            updated_at: new Date(nowMs - 38 * 60 * 1000).toISOString(),
          },
          history: [
            {
              timestampMs: nowMs - 38 * 60 * 1000,
              match: {
                match_details_id: "c5yvwz1d5l2t",
                date: kickoff.date,
                time: kickoff.time,
                league: "UEFA Champions League",
                home_team: "Bayer Leverkusen",
                away_team: "Arsenal",
                home_score: 0,
                away_score: 0,
                score_status: "47",
              },
            },
          ],
        },
        match: {
          match_details_id: "c5yvwz1d5l2t",
          date: kickoff.date,
          time: kickoff.time,
          league: "UEFA Champions League",
          home_team: "Bayer Leverkusen",
          away_team: "Arsenal",
          home_score: 1,
          away_score: 0,
          score_status: "85",
          home_goal_scorers: [
            {
              player: "Victor Boniface",
              goal_times: ["60'"],
              own_goal_times: [],
            },
          ],
          away_goal_scorers: [],
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].score_status, "83");
  assert.equal(presentation.matches[0].home_score, 1);
  assert.equal(presentation.matches[0].away_score, 0);
});

test("buildLiveActivityPresentationForUser uses delayed snapshot goal timeline when current scorer arrays are missing", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 92 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(2),
    [
      {
        state: {
          lastState: {
            match_details_id: "c5yvwz1d5l2t",
            date: kickoff.date,
            time: kickoff.time,
            league: "UEFA Champions League",
            home_team: "Bayer Leverkusen",
            away_team: "Arsenal",
            home_score: 1,
            away_score: 1,
            score_status: "92",
            home_goal_scorers: [],
            away_goal_scorers: [],
            updated_at: new Date(nowMs).toISOString(),
          },
          history: [
            {
              timestampMs: nowMs - 3 * 60 * 1000,
              match: {
                match_details_id: "c5yvwz1d5l2t",
                date: kickoff.date,
                time: kickoff.time,
                league: "UEFA Champions League",
                home_team: "Bayer Leverkusen",
                away_team: "Arsenal",
                home_score: 1,
                away_score: 1,
                score_status: "90",
                home_goal_scorers: [
                  {
                    player: "Victor Boniface",
                    goal_times: ["60'"],
                    own_goal_times: [],
                  },
                ],
                away_goal_scorers: [
                  {
                    player: "Bukayo Saka",
                    goal_times: ["88'"],
                    own_goal_times: [],
                  },
                ],
              },
            },
          ],
        },
        match: {
          match_details_id: "c5yvwz1d5l2t",
          date: kickoff.date,
          time: kickoff.time,
          league: "UEFA Champions League",
          home_team: "Bayer Leverkusen",
          away_team: "Arsenal",
          home_score: 1,
          away_score: 1,
          score_status: "92",
          home_goal_scorers: [],
          away_goal_scorers: [],
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].score_status, "90");
  assert.equal(presentation.matches[0].home_score, 1);
  assert.equal(presentation.matches[0].away_score, 1);
});

test("buildLiveActivityPresentationForUser preserves delayed scores when current scorer arrays lag behind history", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 95 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    { preferences: { notificationDelayMinutes: 5 } },
    [
      {
        state: {
          lastState: {
            match_details_id: "ce8nq755jqdt",
            date: kickoff.date,
            time: kickoff.time,
            league: "Bundesliga",
            home_team: "Bayern Munich",
            away_team: "Borussia M'gladbach",
            home_score: 4,
            away_score: 1,
            score_status: "90+4",
            updated_at: new Date(nowMs).toISOString(),
          },
          history: [
            {
              timestampMs: nowMs - 7 * 60 * 1000,
              match: {
                match_details_id: "ce8nq755jqdt",
                date: kickoff.date,
                time: kickoff.time,
                league: "Bundesliga",
                home_team: "Bayern Munich",
                away_team: "Borussia M'gladbach",
                home_score: 4,
                away_score: 0,
                score_status: "87",
              },
            },
            {
              timestampMs: nowMs - 5 * 60 * 1000,
              match: {
                match_details_id: "ce8nq755jqdt",
                date: kickoff.date,
                time: kickoff.time,
                league: "Bundesliga",
                home_team: "Bayern Munich",
                away_team: "Borussia M'gladbach",
                home_score: 3,
                away_score: 1,
                score_status: "89",
              },
            },
          ],
        },
        match: {
          match_details_id: "ce8nq755jqdt",
          date: kickoff.date,
          time: kickoff.time,
          league: "Bundesliga",
          home_team: "Bayern Munich",
          away_team: "Borussia M'gladbach",
          home_score: 4,
          away_score: 1,
          score_status: "90+4",
          home_goal_scorers: [
            { player: "L. Diaz", goal_times: ["33'"], own_goal_times: [] },
            { player: "K. Laimer", goal_times: ["45+1'"], own_goal_times: [] },
            { player: "J. Musiala", goal_times: ["57'"], own_goal_times: [] },
          ],
          away_goal_scorers: [
            { player: "W. Mohya", goal_times: ["89'"], own_goal_times: [] },
          ],
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.delayMinutes, 5);
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].score_status, "89");
  assert.equal(presentation.matches[0].home_score, 4);
  assert.equal(presentation.matches[0].away_score, 1);
});

test("buildLiveActivityPresentationForUser keeps delayed minute and score aligned when timeline is complete", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 80 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    { preferences: { notificationDelayMinutes: 5 } },
    [
      {
        state: {
          lastState: {
            match_details_id: "c14mvd1104xt",
            date: kickoff.date,
            time: kickoff.time,
            league: "FA Cup",
            home_team: "Wolverhampton Wanderers",
            away_team: "Liverpool",
            home_score: 0,
            away_score: 3,
            score_status: "77",
            updated_at: new Date(nowMs).toISOString(),
          },
          history: [
            {
              timestampMs: nowMs - 5 * 60 * 1000,
              match: {
                match_details_id: "c14mvd1104xt",
                date: kickoff.date,
                time: kickoff.time,
                league: "FA Cup",
                home_team: "Wolverhampton Wanderers",
                away_team: "Liverpool",
                home_score: 0,
                away_score: 3,
                score_status: "74",
              },
            },
          ],
        },
        match: {
          match_details_id: "c14mvd1104xt",
          date: kickoff.date,
          time: kickoff.time,
          league: "FA Cup",
          home_team: "Wolverhampton Wanderers",
          away_team: "Liverpool",
          home_score: 0,
          away_score: 3,
          score_status: "77",
          home_goal_scorers: [],
          away_goal_scorers: [
            { player: "A. Robertson", goal_times: ["51'"], own_goal_times: [] },
            { player: "M. Salah", goal_times: ["53'"], own_goal_times: [] },
            { player: "C. Jones", goal_times: ["74'"], own_goal_times: [] },
          ],
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.delayMinutes, 5);
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].score_status, "74");
  assert.equal(presentation.matches[0].home_score, 0);
  assert.equal(presentation.matches[0].away_score, 3);
});

test("compareLiveActivityMatches sorts later kickoffs first", () => {
  const laterKickoffMatch = {
    match_details_id: "later",
    league: "Premier League",
    home_team: "West Ham United",
    away_team: "Manchester City",
    home_team_score: 1600,
    away_team_score: 1940,
    total_team_score: 3540,
    date: "2026-03-14",
    time: "20:00",
  };
  const earlierKickoffMatch = {
    match_details_id: "earlier",
    league: "Premier League",
    home_team: "Arsenal",
    away_team: "Everton",
    home_team_score: 1900,
    away_team_score: 1650,
    total_team_score: 3550,
    date: "2026-03-14",
    time: "17:30",
  };

  const sorted = [earlierKickoffMatch, laterKickoffMatch].sort(__testHooks.compareLiveActivityMatches);
  assert.equal(sorted[0].match_details_id, "later");
});

test("compareLiveActivityMatches sorts higher total team score first for identical kickoffs", () => {
  const highScoreMatch = {
    match_details_id: "high",
    league: "Championship",
    home_team: "Wolves",
    away_team: "Liverpool",
    home_team_score: 1680,
    away_team_score: 1961,
    total_team_score: 3641,
    date: "2026-03-06",
    time: "20:00",
  };
  const lowScoreMatch = {
    match_details_id: "low",
    league: "Championship",
    home_team: "Norwich City",
    away_team: "Sheffield Wednesday",
    home_team_score: 1442,
    away_team_score: 1413,
    total_team_score: 2855,
    date: "2026-03-06",
    time: "20:00",
  };

  const sorted = [lowScoreMatch, highScoreMatch].sort(__testHooks.compareLiveActivityMatches);
  assert.equal(sorted[0].match_details_id, "high");
});

test("buildLiveActivityPresentationForUser orders mixed live and full-time matches by latest kickoff first", () => {
  const nowMs = Date.now();
  const liveKickoff = formatLocalDateTimeParts(nowMs - 3 * 60 * 60 * 1000);
  const finishedKickoff = formatLocalDateTimeParts(nowMs - 55 * 60 * 1000);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(0),
    [
      {
        state: null,
        match: {
          match_details_id: "finished-first",
          date: finishedKickoff.date,
          time: finishedKickoff.time,
          league: "La Liga",
          home_team: "Real Madrid",
          away_team: "Barcelona",
          home_score: 2,
          away_score: 1,
          score_status: "FT",
          updated_at: new Date(nowMs - 2 * 60 * 60 * 1000).toISOString(),
        },
      },
      {
        state: {
          lastState: {
            match_details_id: "live-now",
            date: liveKickoff.date,
            time: liveKickoff.time,
            league: "Premier League",
            home_team: "Liverpool",
            away_team: "Chelsea",
            home_score: 1,
            away_score: 0,
            score_status: "67",
          },
          history: [],
        },
        match: {
          match_details_id: "live-now",
          date: liveKickoff.date,
          time: liveKickoff.time,
          league: "Premier League",
          home_team: "Liverpool",
          away_team: "Chelsea",
          home_score: 1,
          away_score: 0,
          score_status: "67",
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "multi_live");
  assert.deepEqual(
    presentation.matches.map((match) => match.match_details_id),
    ["finished-first", "live-now"]
  );
});

test("buildLiveActivityPresentationForUser prefers recently kicked off fixtures over retained full-time matches", () => {
  const nowMs = Date.now();
  const recentKickoff = formatLocalDateTimeParts(nowMs - 3 * 60 * 1000);
  const finishedKickoff = formatLocalDateTimeParts(nowMs - 2 * 60 * 60 * 1000);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(0),
    [
      {
        state: {
          finishedAtMs: nowMs - 30 * 60 * 1000,
          lastState: {
            match_details_id: "finished-first",
            date: finishedKickoff.date,
            time: finishedKickoff.time,
            league: "Premier League",
            home_team: "Sunderland",
            away_team: "Brighton & Hove Albion",
            home_score: 0,
            away_score: 1,
            score_status: "FT",
          },
        },
        match: {
          match_details_id: "finished-first",
          date: finishedKickoff.date,
          time: finishedKickoff.time,
          league: "Premier League",
          home_team: "Sunderland",
          away_team: "Brighton & Hove Albion",
          home_score: 0,
          away_score: 1,
          score_status: "FT",
        },
      },
      {
        state: null,
        match: {
          match_details_id: "recent-kickoff",
          date: recentKickoff.date,
          time: recentKickoff.time,
          league: "Premier League",
          home_team: "Chelsea",
          away_team: "Newcastle United",
          home_score: 0,
          away_score: 0,
          score_status: null,
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_upcoming");
  assert.deepEqual(
    presentation.matches.map((match) => match.match_details_id),
    ["recent-kickoff"]
  );
  assert.equal(presentation.matches[0].home_score, null);
  assert.equal(presentation.matches[0].away_score, null);
  assert.equal(presentation.matches[0].score_status, null);
});

test("buildLiveActivityPresentationForUser keeps recent full-time matches visible for 8 hours", () => {
  const nowMs = Date.now();
  const kickoff = formatLocalDateTimeParts(nowMs - 3 * 60 * 60 * 1000);

  const withinRetention = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(0),
    [
      {
        state: {
          finishedAtMs: nowMs - 7 * 60 * 60 * 1000,
          lastState: {
            match_details_id: "recent-ft",
            date: kickoff.date,
            time: kickoff.time,
            league: "Premier League",
            home_team: "Arsenal",
            away_team: "Tottenham Hotspur",
            home_score: 2,
            away_score: 2,
            score_status: "FT",
          },
        },
        match: {
          match_details_id: "recent-ft",
          date: kickoff.date,
          time: kickoff.time,
          league: "Premier League",
          home_team: "Arsenal",
          away_team: "Tottenham Hotspur",
          home_score: 2,
          away_score: 2,
          score_status: "FT",
        },
      },
    ],
    nowMs
  );

  assert.equal(withinRetention.mode, "single_finished");
  assert.equal(withinRetention.matches.length, 1);
  assert.equal(withinRetention.matches[0].match_details_id, "recent-ft");

  const expired = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(0),
    [
      {
        state: {
          finishedAtMs: nowMs - 8 * 60 * 60 * 1000 - 1000,
          lastState: {
            match_details_id: "expired-ft",
            date: kickoff.date,
            time: kickoff.time,
            league: "Premier League",
            home_team: "Arsenal",
            away_team: "Tottenham Hotspur",
            home_score: 1,
            away_score: 0,
            score_status: "FT",
          },
        },
        match: {
          match_details_id: "expired-ft",
          date: kickoff.date,
          time: kickoff.time,
          league: "Premier League",
          home_team: "Arsenal",
          away_team: "Tottenham Hotspur",
          home_score: 1,
          away_score: 0,
          score_status: "FT",
        },
      },
    ],
    nowMs
  );

  assert.equal(expired.mode, null);
  assert.equal(expired.matches.length, 0);
});

test("buildLiveActivityPresentationForUser caps live activity payloads to 8 matches", () => {
  const nowMs = Date.now();
  const kickoff = formatLocalDateTimeParts(nowMs - 20 * 60 * 1000);

  const entries = Array.from({ length: 10 }, (_, index) => {
    const id = index + 1;
    return {
      state: {
        lastState: {
          match_details_id: `live-${id}`,
          date: kickoff.date,
          time: kickoff.time,
          league: "Premier League",
          home_team: `Home ${id}`,
          away_team: `Away ${id}`,
          home_score: id % 3,
          away_score: id % 2,
          score_status: String(10 + id),
        },
        history: [],
      },
      match: {
        match_details_id: `live-${id}`,
        date: kickoff.date,
        time: kickoff.time,
        league: "Premier League",
        home_team: `Home ${id}`,
        away_team: `Away ${id}`,
        home_score: id % 3,
        away_score: id % 2,
        score_status: String(10 + id),
        updated_at: new Date(nowMs).toISOString(),
      },
    };
  });

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(0),
    entries,
    nowMs
  );

  assert.equal(presentation.mode, "multi_live");
  assert.equal(presentation.matches.length, 8);
});

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

test("suppresses aggregate 0-0 in score update notifications", () => {
  const oldMatch = {
    home_team: "Wolves",
    away_team: "Aston Villa",
    home_score: 1,
    away_score: 0,
    score_status: "70'",
  };

  const newMatch = {
    ...oldMatch,
    home_score: 2,
    away_score: 0,
    score_status: "87'",
    aggregate_home_score: 0,
    aggregate_away_score: 0,
  };

  const event = __testHooks.buildScoreChangeEvent(oldMatch, newMatch);
  assert.ok(event);
  assert.equal(event.body, "Wolves 2 - 0 Aston Villa (87')");
});

test("suppresses aggregate 0-0 in full-time notifications", () => {
  const monitorState = newMonitorState();

  const oldMatch = {
    home_team: "Burnley",
    away_team: "AFC Bournemouth",
    score_status: "90'",
    home_score: 0,
    away_score: 0,
    home_goal_scorers: [],
    away_goal_scorers: [],
    aggregate_home_score: 0,
    aggregate_away_score: 0,
  };

  const newMatch = {
    ...oldMatch,
    score_status: "FT",
  };

  const events = __testHooks.buildMatchEvents(oldMatch, newMatch, monitorState, Date.now());
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "fulltime");
  assert.equal(events[0].body, "Burnley 0 - 0 AFC Bournemouth");
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

test("emits goal when score delta appears before timeline details", () => {
  const monitorState = newMonitorState();
  const snap0 = {
    home_team: "Newcastle United",
    away_team: "Manchester City",
    score_status: "37'",
    home_score: 1,
    away_score: 0,
    home_goal_scorers: [{ player: "H. Barnes", goal_times: ["18'"] }],
    away_goal_scorers: [],
    home_assists: [{ player: "S. Tonali", assist_times: ["18'"] }],
    away_assists: [],
  };

  const snap1 = {
    ...snap0,
    score_status: "40'",
    home_score: 1,
    away_score: 1,
  };

  const poll1Goals = __testHooks
    .buildMatchEvents(snap0, snap1, monitorState, Date.now())
    .filter((event) => event.type === "goal");
  assert.equal(poll1Goals.length, 0);

  const snap2 = {
    ...snap1,
    score_status: "HT",
    away_goal_scorers: [{ player: "Savinho", goal_times: ["39'"] }],
    away_assists: [{ player: "J. Doku", assist_times: ["39'"] }],
  };

  const poll2Goals = __testHooks
    .buildMatchEvents(snap1, snap2, monitorState, Date.now())
    .filter((event) => event.type === "goal");
  assert.equal(poll2Goals.length, 1);
  assert.equal(poll2Goals[0].title, "Goal 39'");
  assert.equal(
    poll2Goals[0].body,
    "Newcastle United 1 - 1 Manchester City (Savinho, assist: J. Doku)"
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

test("evaluateUserNotificationDecision blocks non-Premier League matches when EPL-only filter is enabled", () => {
  const decision = __testHooks.evaluateUserNotificationDecision(
    {
      apnsToken: "apns-token",
      preferences: {
        notificationsEnabled: true,
        notificationDelayMinutes: 2,
        notificationEventTypes: ["goal"],
        englishPremierLeagueTeamsOnly: true,
      },
    },
    {
      home_team: "Lazio",
      away_team: "Sassuolo",
      league: "Serie A",
      tv_channels: [],
    },
    {
      type: "goal",
    }
  );

  assert.deepStrictEqual(decision, {
    shouldNotify: false,
    reason: "premier_league_team_filter",
    delayMinutes: 2,
  });
});

test("evaluateUserNotificationDecision allows Premier League matches when EPL-only filter is enabled", () => {
  const decision = __testHooks.evaluateUserNotificationDecision(
    {
      apnsToken: "apns-token",
      preferences: {
        notificationsEnabled: true,
        notificationDelayMinutes: 0,
        notificationEventTypes: ["goal"],
        englishPremierLeagueTeamsOnly: true,
      },
    },
    {
      home_team: "West Ham United",
      away_team: "Brentford",
      league: "Premier League",
      tv_channels: [],
    },
    {
      type: "goal",
    }
  );

  assert.equal(decision.shouldNotify, true);
  assert.equal(decision.reason, "eligible");
});

test("evaluateUserNotificationDecision treats confirmed VAR reversals as delayed goal notifications", () => {
  const decision = __testHooks.evaluateUserNotificationDecision(
    {
      apnsToken: "apns-token",
      preferences: {
        notificationsEnabled: true,
        notificationDelayMinutes: 3,
        notificationEventTypes: ["goal"],
      },
    },
    {
      home_team: "Leeds United",
      away_team: "Norwich City",
      league: "FA Cup",
      tv_channels: [],
    },
    {
      type: "goal",
      disallowedByVar: true,
      goalTime: "19'",
    }
  );

  assert.deepStrictEqual(decision, {
    shouldNotify: true,
    reason: "eligible",
    delayMinutes: 3,
  });
});
