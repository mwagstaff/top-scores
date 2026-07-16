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

// Match date/time fields are Europe/London wall-clock, so format them in that
// zone explicitly — keeps these tests correct on any host timezone.
const londonDateTimeFormatter = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/London",
  hourCycle: "h23",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
});

function formatLocalDateTimeParts(timestampMs) {
  const parts = {};
  londonDateTimeFormatter.formatToParts(new Date(timestampMs)).forEach((part) => {
    parts[part.type] = part.value;
  });
  return {
    date: `${parts.year}-${parts.month}-${parts.day}`,
    time: `${parts.hour}:${parts.minute}`,
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

test("parseMatchDateTimeMs treats match date/time as Europe/London wall-clock", () => {
  // 18:00 London on a BST date is 17:00 UTC — the naive host-local parse on the
  // UTC production server made this 18:00 UTC, so every kickoff looked an hour
  // late and live scores were spoiler-suppressed for the first hour of a match.
  assert.equal(
    __testHooks.parseMatchDateTimeMs({ date: "2026-07-04", time: "18:00" }),
    Date.parse("2026-07-04T17:00:00Z")
  );
  // GMT date: London matches UTC.
  assert.equal(
    __testHooks.parseMatchDateTimeMs({ date: "2026-01-10", time: "15:00" }),
    Date.parse("2026-01-10T15:00:00Z")
  );
});

test("parseMatchDateTimeMs is independent of the host timezone", () => {
  // The production server runs UTC while this suite typically runs in
  // Europe/London, so re-run the BST conversion in a UTC child process.
  const { execFileSync } = require("node:child_process");
  const output = execFileSync(
    process.execPath,
    [
      "-e",
      `const { __testHooks } = require(${JSON.stringify(require.resolve("./match_monitor"))});
       console.log(__testHooks.parseMatchDateTimeMs({ date: "2026-07-04", time: "18:00" }));`,
    ],
    { env: { ...process.env, TZ: "UTC" }, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
  );
  assert.equal(Number(output.trim()), Date.parse("2026-07-04T17:00:00Z"));
});

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

test("penalty shootout progress tallies are treated as live match status", () => {
  assert.equal(__testHooks.isLiveMatchStatus("P 0-0"), true);
  assert.equal(__testHooks.isPenaltyShootoutStatus("P 0-0"), true);
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
  const nowMs = Date.parse("2026-03-13T12:01:00.000Z");
  const state = {
    lastPayloadHash: "abc123",
    lastScoreHash: "score123",
    lastMode: "multi_live",
    lastDispatchAt: "2026-03-13T12:00:00.000Z",
  };

  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(
      state,
      "abc123",
      "multi_live",
      false,
      { nowMs }
    ),
    true
  );
  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(
      state,
      "abc123",
      "multi_live",
      true,
      { nowMs }
    ),
    false
  );
});

test("buildLiveActivityPayloadHash ignores generatedAtEpochSeconds", () => {
  const baseline = {
    mode: "multi_live",
    generatedAtEpochSeconds: 100,
    delayMinutes: 0,
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

test("shouldSkipLiveActivityUpdate suppresses passive static upcoming mode churn", () => {
  const state = {
    lastPayloadHash: "single-payload",
    lastScoreHash: "single-score",
    lastMode: "single_upcoming",
    lastDispatchAt: "2026-04-28T08:27:17.000Z",
  };

  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "multi-payload", "multi_upcoming", false, {
      scoreHash: "multi-score",
      nowMs: Date.parse("2026-04-28T08:29:15.000Z"),
      trigger: "preferences_and_fantasy_sync",
    }),
    true
  );

  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "multi-payload", "multi_upcoming", false, {
      scoreHash: "multi-score",
      nowMs: Date.parse("2026-04-28T08:29:15.000Z"),
      trigger: "app_foreground",
    }),
    false
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

test("shouldSkipLiveActivityUpdate suppresses live score changes during the startup quiet window", () => {
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
    true
  );
  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "new-payload", "multi_live", false, {
      scoreHash: "score456",
      nowMs: Date.parse("2026-03-13T12:01:01.000Z"),
    }),
    false
  );
});

test("shouldSkipLiveActivityUpdate suppresses upcoming-mode churn before heartbeat window", () => {
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
    true
  );
  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "new-payload", "multi_upcoming", false, {
      scoreHash: "score123",
      nowMs: Date.parse("2026-03-13T12:25:10.000Z"),
    }),
    true
  );
  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "new-payload", "multi_upcoming", false, {
      scoreHash: "score123",
      nowMs: Date.parse("2026-03-13T15:55:10.000Z"),
    }),
    false
  );
});

test("shouldSkipLiveActivityUpdate suppresses finished-mode churn before heartbeat window", () => {
  const state = {
    lastPayloadHash: "old-payload",
    lastScoreHash: "score123",
    lastMode: "multi_finished",
    lastDispatchAt: "2026-03-13T12:00:00.000Z",
  };

  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "new-payload", "multi_finished", false, {
      scoreHash: "score123",
      nowMs: Date.parse("2026-03-13T12:00:15.000Z"),
    }),
    true
  );
  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "new-payload", "multi_finished", false, {
      scoreHash: "score123",
      nowMs: Date.parse("2026-03-13T12:25:10.000Z"),
    }),
    true
  );
  assert.equal(
    __testHooks.shouldSkipLiveActivityUpdate(state, "new-payload", "multi_finished", false, {
      scoreHash: "score123",
      nowMs: Date.parse("2026-03-13T15:55:10.000Z"),
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
    __testHooks.shouldPreserveExistingLiveActivityOnEmpty(
      "activity-token-123",
      {
        preserveExistingOnEmpty: false,
      },
      {
        lastMode: "single_upcoming",
      }
    ),
    true
  );
  assert.equal(
    __testHooks.shouldPreserveExistingLiveActivityOnEmpty(
      "activity-token-123",
      {
        preserveExistingOnEmpty: false,
      },
      {
        lastMode: "multi_live",
      }
    ),
    false
  );
  assert.equal(
    __testHooks.shouldPreserveExistingLiveActivityOnEmpty("", {
      preserveExistingOnEmpty: true,
    }),
    false
  );
});

test("liveActivityTokenlessCurrentActivityIsBlocking waits for a fresh activity token", () => {
  const nowMs = Date.parse("2026-04-25T10:08:30.000Z");
  assert.equal(
    __testHooks.liveActivityTokenlessCurrentActivityIsBlocking(
      {
        currentActivityId: "41DF902B-11B3-4387-93B4-21335F7DDEA3",
        currentActivityPushToken: null,
        lastStartAt: "2026-04-25T10:08:04.000Z",
      },
      nowMs
    ),
    true
  );
  assert.equal(
    __testHooks.liveActivityTokenlessCurrentActivityIsBlocking(
      {
        currentActivityId: "41DF902B-11B3-4387-93B4-21335F7DDEA3",
        currentActivityPushToken: "802bd62c3f4d",
        lastStartAt: "2026-04-25T10:08:04.000Z",
      },
      nowMs
    ),
    false
  );
  assert.equal(
    __testHooks.liveActivityTokenlessCurrentActivityIsBlocking(
      {
        currentActivityId: "41DF902B-11B3-4387-93B4-21335F7DDEA3",
        currentActivityPushToken: null,
        lastStartAt: "2026-04-25T10:05:00.000Z",
      },
      nowMs
    ),
    false
  );
});

test("liveActivityRecentDismissalCooldownIsBlocking suppresses quiet push-to-start churn", () => {
  const nowMs = Date.parse("2026-04-25T10:48:30.000Z");
  assert.equal(
    __testHooks.liveActivityRecentDismissalCooldownIsBlocking(
      {
        lastEndedAt: "2026-04-25T10:47:45.000Z",
      },
      "multi_upcoming",
      nowMs
    ),
    true
  );
  assert.equal(
    __testHooks.liveActivityRecentDismissalCooldownIsBlocking(
      {
        lastEndedAt: "2026-04-25T10:47:45.000Z",
      },
      "multi_live",
      nowMs
    ),
    false
  );
  assert.equal(
    __testHooks.liveActivityRecentDismissalCooldownIsBlocking(
      {
        lastEndedAt: "2026-04-25T10:30:00.000Z",
      },
      "multi_upcoming",
      nowMs
    ),
    false
  );
});

test("liveActivityPendingStartMaxMsForMode follows stale window by mode", () => {
  assert.equal(
    __testHooks.liveActivityPendingStartMaxMsForMode("single_upcoming"),
    4 * 60 * 60 * 1000
  );
  assert.equal(
    __testHooks.liveActivityPendingStartMaxMsForMode("multi_finished"),
    4 * 60 * 60 * 1000
  );
  assert.equal(
    __testHooks.liveActivityPendingStartMaxMsForMode("multi_live"),
    30 * 60 * 1000
  );
});

test("buildLiveActivityPresentationForUser keeps a high-minute live match long after kickoff", () => {
  // BSD reliably reports full time, so a match deep in stoppage/extra time
  // 130+ minutes after kickoff is genuinely still in progress — there is no
  // stale-live heuristic second-guessing the feed (that was a hangover from
  // the BBC/TSDB days).
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

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].match_details_id, "c4gq92l5de2t");
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

test("shouldAllowInactiveLiveActivityEvaluation allows forced or targeted reconcile runs", () => {
  assert.equal(__testHooks.shouldAllowInactiveLiveActivityEvaluation({}), false);
  assert.equal(
    __testHooks.shouldAllowInactiveLiveActivityEvaluation({ forceDispatch: true }),
    true
  );
  assert.equal(
    __testHooks.shouldAllowInactiveLiveActivityEvaluation({
      userDeviceToken: "BF4D495F-E69A-4E7D-B47D-09930684A323",
    }),
    true
  );
});

test("hasImminentUpcomingLiveActivityMatch allows late-night fixtures close to kickoff", () => {
  const nowMs = Date.parse("2026-07-01T00:42:00Z");

  assert.equal(
    __testHooks.hasImminentUpcomingLiveActivityMatch(
      [
        {
          date: "2026-07-01",
          time: "02:00",
          home_team: "Mexico",
          away_team: "Ecuador",
          score_status: null,
        },
      ],
      nowMs
    ),
    true
  );

  assert.equal(
    __testHooks.hasImminentUpcomingLiveActivityMatch(
      [
        {
          date: "2026-07-01",
          time: "17:00",
          home_team: "England",
          away_team: "DR Congo",
          score_status: null,
        },
      ],
      nowMs
    ),
    false
  );
});

test("filterCanonicalLiveActivityMatchesForUser keeps major UEFA knockout fixtures when EPL-only is expanded", () => {
  const nowMs = Date.parse("2026-04-07T19:05:00Z");

  const filtered = __testHooks.filterCanonicalLiveActivityMatchesForUser(
    [
      {
        date: "2026-04-07",
        time: "19:00",
        league: "UEFA Champions League",
        league_subcategory: "Quarter-finals",
        home_team: "Real Madrid",
        away_team: "Bayern Munich",
        tv_channels: [],
      },
      {
        date: "2026-04-07",
        time: "19:00",
        league: "La Liga",
        home_team: "Real Sociedad",
        away_team: "Valencia",
        tv_channels: [],
      },
    ],
    liveActivityUser(0, {
      competitionFilterEnabled: true,
      englishPremierLeagueTeamsOnly: true,
      majorUEFAClubGamesEnabled: true,
    }),
    nowMs
  );

  assert.deepEqual(
    filtered.map((match) => `${match.home_team}|${match.away_team}`),
    ["Real Madrid|Bayern Munich"]
  );
});

test("filterCanonicalLiveActivityMatchesForUser keeps major UEFA knockout fixtures with spaced dash subcategory", () => {
  const nowMs = Date.parse("2026-04-07T19:05:00Z");

  const filtered = __testHooks.filterCanonicalLiveActivityMatchesForUser(
    [
      {
        date: "2026-04-07",
        time: "20:00",
        league: "UEFA Champions League",
        league_subcategory: "Quarter - finals",
        home_team: "Real Madrid",
        away_team: "Bayern Munich",
        tv_channels: ["TNT Sports"],
      },
    ],
    liveActivityUser(0, {
      competitionFilterEnabled: true,
      englishPremierLeagueTeamsOnly: true,
      majorUEFAClubGamesEnabled: true,
    }),
    nowMs
  );

  assert.deepEqual(
    filtered.map((match) => `${match.home_team}|${match.away_team}`),
    ["Real Madrid|Bayern Munich"]
  );
});

test("filterCanonicalLiveActivityMatchesForUser keeps major tournament fixtures under EPL-only when the major tournaments filter is enabled", () => {
  const nowMs = Date.parse("2026-07-04T18:55:00Z");

  const matches = [
    {
      date: "2026-07-04",
      time: "18:00",
      league: "FIFA World Cup 2026",
      league_subcategory: "Round of 16",
      home_team: "Canada",
      away_team: "Morocco",
      score_status: "92",
      tv_channels: ["ITV"],
    },
    {
      // Qualifiers are excluded from the major-tournament allowance.
      date: "2026-07-04",
      time: "19:00",
      league: "FIFA World Cup 2026 Qualifying",
      home_team: "Moldova",
      away_team: "Malta",
      tv_channels: [],
    },
    {
      // A non-major league without an EPL team stays excluded.
      date: "2026-07-04",
      time: "19:00",
      league: "La Liga",
      home_team: "Getafe",
      away_team: "Osasuna",
      tv_channels: [],
    },
  ];

  const filtered = __testHooks.filterCanonicalLiveActivityMatchesForUser(
    matches,
    liveActivityUser(0, {
      englishPremierLeagueTeamsOnly: true,
      majorUEFAClubGamesEnabled: true,
      majorTournamentsFilterEnabled: true,
    }),
    nowMs
  );

  assert.deepEqual(
    filtered.map((match) => `${match.home_team}|${match.away_team}`),
    ["Canada|Morocco"]
  );

  const eligibility = __testHooks.isEligibleForLiveActivityByPreferences(
    liveActivityUser(0, {
      englishPremierLeagueTeamsOnly: true,
      majorTournamentsFilterEnabled: true,
    }),
    matches[0]
  );
  assert.equal(eligibility.eligible, true);
});

test("filterCanonicalLiveActivityMatchesForUser keeps home nations fixtures under EPL-only when the home nations filter is enabled", () => {
  const nowMs = Date.parse("2026-07-04T18:55:00Z");

  const filtered = __testHooks.filterCanonicalLiveActivityMatchesForUser(
    [
      {
        date: "2026-07-04",
        time: "20:00",
        league: "International Friendlies",
        home_team: "Scotland",
        away_team: "Norway",
        tv_channels: [],
      },
    ],
    liveActivityUser(0, {
      englishPremierLeagueTeamsOnly: true,
      homeNationsFilterEnabled: true,
    }),
    nowMs
  );

  assert.deepEqual(
    filtered.map((match) => `${match.home_team}|${match.away_team}`),
    ["Scotland|Norway"]
  );
});

test("filterCanonicalLiveActivityMatchesForUser keeps promotion play-off fixtures when EPL-only is expanded", () => {
  const nowMs = Date.parse("2026-05-09T11:05:00Z");

  const filtered = __testHooks.filterCanonicalLiveActivityMatchesForUser(
    [
      {
        date: "2026-05-09",
        time: "12:30",
        league: "Championship",
        league_subcategory: "Promotion Play-offs - Semi-finals",
        home_team: "Middlesbrough",
        away_team: "Southampton",
        tv_channels: ["Sky Sports"],
      },
    ],
    liveActivityUser(0, {
      competitionFilterEnabled: true,
      englishPremierLeagueTeamsOnly: true,
      majorUEFAClubGamesEnabled: true,
    }),
    nowMs
  );

  assert.deepEqual(
    filtered.map((match) => `${match.home_team}|${match.away_team}`),
    ["Middlesbrough|Southampton"]
  );
});

test("filterCanonicalLiveActivityMatchesForUser keeps configured major derbies in reverse order", () => {
  const nowMs = Date.parse("2026-05-09T11:05:00Z");

  const filtered = __testHooks.filterCanonicalLiveActivityMatchesForUser(
    [
      {
        date: "2026-05-09",
        time: "12:30",
        league: "Scottish Premiership",
        home_team: "Rangers",
        away_team: "Celtic",
        tv_channels: [],
      },
    ],
    liveActivityUser(0, {
      competitionFilterEnabled: true,
      englishPremierLeagueTeamsOnly: true,
      majorUEFAClubGamesEnabled: true,
    }),
    nowMs
  );

  assert.deepEqual(
    filtered.map((match) => `${match.home_team}|${match.away_team}`),
    ["Rangers|Celtic"]
  );
});

test("filterCanonicalLiveActivityMatchesForUser canonicalizes selected league names for fallback fixtures", () => {
  const nowMs = Date.parse("2026-04-07T19:05:00Z");

  const filtered = __testHooks.filterCanonicalLiveActivityMatchesForUser(
    [
      {
        date: "2026-04-07",
        time: "20:00",
        league: "UEFA Champions League Quarter-Final 1st Leg",
        league_subcategory: "Quarter-finals",
        home_team: "Real Madrid",
        away_team: "Bayern Munich",
        tv_channels: ["TNT Sports TBC"],
      },
    ],
    liveActivityUser(0, {
      competitionFilterEnabled: true,
      selectedLeagues: ["UEFA Champions League"],
      englishPremierLeagueTeamsOnly: true,
      majorUEFAClubGamesEnabled: true,
    }),
    nowMs
  );

  assert.deepEqual(
    filtered.map((match) => `${match.home_team}|${match.away_team}`),
    ["Real Madrid|Bayern Munich"]
  );
});

test("filterCanonicalLiveActivityMatchesForUser keeps a match that kicked off yesterday and is still live", () => {
  const nowMs = Date.parse("2026-07-04T00:03:00Z");

  const filtered = __testHooks.filterCanonicalLiveActivityMatchesForUser(
    [
      {
        date: "2026-07-03",
        time: "23:00",
        league: "FIFA World Cup 2026",
        home_team: "Argentina",
        away_team: "Cape Verde",
        score_status: "45",
        tv_channels: [],
      },
      {
        date: "2026-07-03",
        time: "20:00",
        league: "FIFA World Cup 2026",
        home_team: "Portugal",
        away_team: "Croatia",
        score_status: "FT",
        tv_channels: [],
      },
    ],
    liveActivityUser(0),
    nowMs
  );

  assert.deepEqual(
    filtered.map((match) => `${match.home_team}|${match.away_team}`),
    ["Argentina|Cape Verde"]
  );
});

test("buildLiveActivityPresentationForUser keeps major UEFA knockout fixtures when EPL-only is expanded", () => {
  const nowMs = Date.parse("2026-04-07T18:05:00Z");

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(0, {
      englishPremierLeagueTeamsOnly: true,
      majorUEFAClubGamesEnabled: true,
    }),
    [
      {
        state: null,
        match: {
          match_details_id: "c9d4g9g3vzyt",
          date: "2026-04-07",
          time: "19:00",
          league: "UEFA Champions League",
          league_subcategory: "Quarter-finals",
          home_team: "Real Madrid",
          away_team: "Bayern Munich",
          home_score: null,
          away_score: null,
          score_status: null,
          tv_channels: [],
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_upcoming");
  assert.deepEqual(
    presentation.matches.map((match) => `${match.home_team}|${match.away_team}`),
    ["Real Madrid|Bayern Munich"]
  );
});

test("buildLiveActivityPresentationForUser keeps fallback UEFA fixtures when selected leagues use canonical names", () => {
  const nowMs = Date.parse("2026-04-07T20:18:00+01:00");

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(2, {
      competitionFilterEnabled: true,
      selectedLeagues: ["UEFA Champions League"],
      englishPremierLeagueTeamsOnly: true,
      majorUEFAClubGamesEnabled: true,
    }),
    [
      {
        state: {
          finishedAtMs: nowMs - 60 * 1000,
        },
        match: {
          match_details_id: "clyx8k8pn8dt",
          date: "2026-04-07",
          time: "19:00",
          league: "UEFA Champions League",
          league_subcategory: "Quarter-finals",
          home_team: "Sporting CP",
          away_team: "Arsenal",
          home_score: 0,
          away_score: 1,
          score_status: "FT",
          tv_channels: ["Amazon Prime Video"],
        },
      },
      {
        state: null,
        match: {
          match_details_id: null,
          date: "2026-04-07",
          time: "20:00",
          league: "UEFA Champions League Quarter-Final 1st Leg",
          league_subcategory: "Quarter-finals",
          home_team: "Real Madrid",
          away_team: "Bayern Munich",
          home_score: null,
          away_score: null,
          score_status: null,
          tv_channels: ["TNT Sports TBC"],
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_upcoming");
  assert.deepEqual(
    presentation.matches.map((match) => `${match.home_team}|${match.away_team}`),
    ["Real Madrid|Bayern Munich"]
  );
});

test("buildLiveActivityOperationalMatches supplements canonical gaps with fallback fixtures", () => {
  const matches = __testHooks.buildLiveActivityOperationalMatches(
    {},
    [
      {
        date: "2026-04-07",
        time: "19:00",
        league: "UEFA Champions League",
        league_subcategory: "Quarter-finals",
        home_team: "Real Madrid",
        away_team: "Bayern Munich",
        tv_channels: [],
      },
    ]
  );

  assert.equal(matches.length, 1);
  assert.equal(matches[0].home_team, "Real Madrid");
  assert.equal(matches[0].away_team, "Bayern Munich");
  assert.equal(matches[0].league_subcategory, "Quarter-finals");
});

test("buildLiveActivityOperationalMatches collapses alias fallback fixtures onto canonical BBC matches", () => {
  const matches = __testHooks.buildLiveActivityOperationalMatches(
    {
      cn782mn6edyt: {
        id: "cn782mn6edyt",
        date: "2026-04-08",
        time: "17:45",
        league: "UEFA Europa League",
        league_subcategory: "Quarter-finals",
        home_team: "Sporting Braga",
        away_team: "Real Betis",
        tv_channels: ["TNT Sports", "HBO Max"],
      },
      cx2d3yr7l1jt: {
        id: "cx2d3yr7l1jt",
        date: "2026-04-08",
        time: "20:00",
        league: "UEFA Champions League",
        league_subcategory: "Quarter-finals",
        home_team: "Paris Saint-Germain",
        away_team: "Liverpool",
        tv_channels: ["TNT Sports", "HBO Max"],
      },
    },
    [
      {
        date: "2026-04-08",
        time: "17:45",
        league: "UEFA Europa League Quarter-Final 1st Leg",
        home_team: "SC Braga",
        away_team: "Real Betis",
        tv_channels: ["TNT Sports 4", "HBO Max"],
      },
      {
        date: "2026-04-08",
        time: "20:00",
        league: "UEFA Champions League Quarter-Final 1st Leg",
        home_team: "PSG",
        away_team: "Liverpool",
        tv_channels: ["TNT Sports 1", "HBO Max"],
      },
    ]
  );

  assert.equal(matches.length, 2);

  const bragaMatch = matches.find((match) => match.match_details_id === "cn782mn6edyt");
  assert.ok(bragaMatch);
  assert.equal(bragaMatch.home_team, "Sporting Braga");
  assert.equal(bragaMatch.away_team, "Real Betis");

  const psgMatch = matches.find((match) => match.match_details_id === "cx2d3yr7l1jt");
  assert.ok(psgMatch);
  assert.equal(psgMatch.home_team, "Paris Saint-Germain");
  assert.equal(psgMatch.away_team, "Liverpool");
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

test("buildLiveActivityPresentationForUser excludes postponed fixtures from upcoming live activities", () => {
  const nowMs = Date.parse("2026-03-21T09:00:00Z");

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(0),
    [
      {
        state: null,
        match: {
          match_details_id: "postponed-city-palace",
          date: "2026-03-21",
          time: "12:30",
          league: "Premier League",
          home_team: "Manchester City",
          away_team: "Crystal Palace",
          home_score: null,
          away_score: null,
          score_status: "POSTPONED",
          tv_channels: ["TNT Sports 1"],
        },
      },
      {
        state: null,
        match: {
          match_details_id: "arsenal-chelsea",
          date: "2026-03-21",
          time: "17:30",
          league: "Premier League",
          home_team: "Arsenal",
          away_team: "Chelsea",
          home_score: null,
          away_score: null,
          score_status: null,
          tv_channels: ["Sky Sports Main Event"],
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_upcoming");
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].match_details_id, "arsenal-chelsea");
});

test("buildLiveActivityEntriesForUser drops postponed canonical fixtures", () => {
  const nowMs = Date.parse("2026-03-21T09:00:00Z");

  const entries = __testHooks.buildLiveActivityEntriesForUser(
    liveActivityUser(0),
    [],
    [
      {
        match_details_id: "postponed-city-palace",
        date: "2026-03-21",
        time: "12:30",
        league: "Premier League",
        home_team: "Manchester City",
        away_team: "Crystal Palace",
        home_score: null,
        away_score: null,
        score_status: "POSTPONED",
        tv_channels: ["TNT Sports 1"],
      },
      {
        match_details_id: "arsenal-chelsea",
        date: "2026-03-21",
        time: "17:30",
        league: "Premier League",
        home_team: "Arsenal",
        away_team: "Chelsea",
        home_score: null,
        away_score: null,
        score_status: null,
        tv_channels: ["Sky Sports Main Event"],
      },
    ],
    nowMs
  );

  assert.equal(entries.length, 1);
  assert.equal(entries[0].match.match_details_id, "arsenal-chelsea");
});

test("buildLiveActivityEntriesForUser excludes retained previous-day matches after midnight rollover", () => {
  const nowMs = Date.parse("2026-03-22T00:24:00Z");

  const entries = __testHooks.buildLiveActivityEntriesForUser(
    liveActivityUser(0),
    [
      {
        matchId: "leeds-brentford-ft",
        state: {
          finishedAtMs: Date.parse("2026-03-21T22:05:00Z"),
          lastState: {
            match_details_id: "leeds-brentford-ft",
            date: "2026-03-21",
            time: "20:00",
            league: "Premier League",
            home_team: "Leeds United",
            away_team: "Brentford",
            home_score: 1,
            away_score: 0,
            score_status: "FT",
            updated_at: "2026-03-21T22:05:00Z",
          },
        },
        match: {
          match_details_id: "leeds-brentford-ft",
          date: "2026-03-21",
          time: "20:00",
          league: "Premier League",
          home_team: "Leeds United",
          away_team: "Brentford",
          home_score: 1,
          away_score: 0,
          score_status: "FT",
          updated_at: "2026-03-21T22:05:00Z",
        },
      },
    ],
    [
      {
        match_details_id: "newcastle-sunderland",
        date: "2026-03-22",
        time: "12:00",
        league: "Premier League",
        home_team: "Newcastle United",
        away_team: "Sunderland",
        home_score: null,
        away_score: null,
        score_status: null,
        tv_channels: ["Sky Sports Main Event"],
      },
      {
        match_details_id: "arsenal-city",
        date: "2026-03-22",
        time: "17:30",
        league: "Premier League",
        home_team: "Arsenal",
        away_team: "Manchester City",
        home_score: null,
        away_score: null,
        score_status: null,
        tv_channels: ["Sky Sports Premier League"],
      },
    ],
    nowMs
  );

  assert.deepEqual(
    entries.map((entry) => entry.match.match_details_id),
    ["newcastle-sunderland", "arsenal-city"]
  );
});

test("buildLiveActivityEntriesForUser keeps a still-live previous-day match alongside today's upcoming fixtures", () => {
  const nowMs = Date.parse("2026-07-04T00:03:00Z");

  const entries = __testHooks.buildLiveActivityEntriesForUser(
    liveActivityUser(0),
    [],
    [
      {
        match_details_id: "argentina-capeverde",
        date: "2026-07-03",
        time: "23:00",
        league: "FIFA World Cup 2026",
        home_team: "Argentina",
        away_team: "Cape Verde",
        home_score: 1,
        away_score: 0,
        score_status: "45",
        tv_channels: ["Sky Sport"],
      },
      {
        match_details_id: "colombia-ghana",
        date: "2026-07-04",
        time: "02:30",
        league: "FIFA World Cup 2026",
        home_team: "Colombia",
        away_team: "Ghana",
        home_score: null,
        away_score: null,
        score_status: null,
        tv_channels: ["ITV"],
      },
    ],
    nowMs
  );

  assert.deepEqual(
    entries.map((entry) => entry.match.match_details_id),
    ["argentina-capeverde", "colombia-ghana"]
  );
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

test("buildLiveActivityEntriesForUser collapses duplicate live activity fixtures when feed metadata drifts", () => {
  const nowMs = Date.parse("2026-03-15T16:50:00Z");
  const user = liveActivityUser(2, {
    englishPremierLeagueTeamsOnly: true,
  });

  const monitoredEntries = [
    {
      matchId: "legacy-liv-tot",
      state: {
        lastState: {
          match_details_id: "legacy-liv-tot",
          date: "2026-03-15",
          time: "16:30",
          league: "Premier League",
          home_team: "Liverpool",
          away_team: "Tottenham Hotspur",
          home_score: 1,
          away_score: 0,
          score_status: "26",
          updated_at: "2026-03-15T16:26:30Z",
        },
        history: [
          {
            timestampMs: nowMs - 20 * 60 * 1000,
            match: {
              match_details_id: "legacy-liv-tot",
              date: "2026-03-15",
              time: "16:30",
              league: "Premier League",
              home_team: "Liverpool",
              away_team: "Tottenham Hotspur",
              home_score: 1,
              away_score: 0,
              score_status: "26",
            },
          },
        ],
      },
      match: {
        match_details_id: "legacy-liv-tot",
        date: "2026-03-15",
        time: "16:30",
        league: "Premier League",
        home_team: "Liverpool",
        away_team: "Tottenham Hotspur",
        home_score: 1,
        away_score: 0,
        score_status: "26",
        updated_at: "2026-03-15T16:26:30Z",
      },
    },
  ];

  const operationalMatches = [
    {
      match_details_id: "canonical-liv-tot",
      date: "2026-03-15",
      time: "16:29",
      league: "Premier League",
      home_team: "Liverpool",
      away_team: "Tottenham Hotspur",
      home_score: 1,
      away_score: 0,
      score_status: "HT",
      updated_at: "2026-03-15T16:46:00Z",
      tv_channels: ["Sky Sports Premier League"],
    },
  ];

  const entries = __testHooks.buildLiveActivityEntriesForUser(
    user,
    monitoredEntries,
    operationalMatches,
    nowMs
  );

  assert.equal(entries.length, 1);
  assert.equal(entries[0].match.home_team, "Liverpool");
  assert.equal(entries[0].match.away_team, "Tottenham Hotspur");
  assert.equal(entries[0].match.score_status, "HT");
  assert.equal(entries[0].state.history.length, 1);
});

test("mergeCanonicalLiveActivityMatch keeps canonical state for active matches", () => {
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

  assert.equal(merged.score_status, "12");
  assert.equal(merged.home_score, 0);
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

test("mergeCanonicalLiveActivityMatch keeps canonical finished snapshot even when monitor differs", () => {
  const merged = __testHooks.mergeCanonicalLiveActivityMatch(
    {
      match_details_id: "c8r1zve354lt",
      date: "2026-03-19",
      time: "17:45",
      league: "Premier League",
      home_team: "Aston Villa",
      away_team: "LOSC Lille",
      home_score: 2,
      away_score: 0,
      score_status: "FT",
      updated_at: "2026-03-19T19:40:00.000Z",
      tv_channels: ["TNT Sports 1"],
    },
    {
      match_details_id: "c8r1zve354lt",
      date: "2026-03-19",
      time: "17:45",
      league: "Premier League",
      home_team: "Aston Villa",
      away_team: "LOSC Lille",
      home_score: 1,
      away_score: 0,
      score_status: "FT",
      updated_at: "2026-03-19T19:44:00.000Z",
      tv_channels: ["TNT Sports 1"],
    }
  );

  assert.equal(merged.score_status, "FT");
  assert.equal(merged.home_score, 2);
  assert.equal(merged.away_score, 0);
});

test("mergeCanonicalLiveActivityMatch prefers resolved penalty result over transient shootout tally", () => {
  const merged = __testHooks.mergeCanonicalLiveActivityMatch(
    {
      match_details_id: "c75k3rv779xt",
      date: "2026-04-05",
      time: "15:30",
      league: "FA Cup",
      home_team: "West Ham United",
      away_team: "Leeds United",
      home_score: 2,
      away_score: 2,
      score_status: "AET",
      penalty_result: "Leeds United win 4 - 2 on penalties",
      updated_at: "2026-04-05T18:47:00.000Z",
      tv_channels: ["TNT Sports 1"],
    },
    {
      match_details_id: "c75k3rv779xt",
      date: "2026-04-05",
      time: "15:30",
      league: "FA Cup",
      home_team: "West Ham United",
      away_team: "Leeds United",
      home_score: 3,
      away_score: 2,
      score_status: "PENS",
      updated_at: "2026-04-05T18:46:00.000Z",
      tv_channels: ["TNT Sports 1"],
    }
  );

  assert.equal(merged.home_score, 2);
  assert.equal(merged.away_score, 2);
  assert.equal(merged.score_status, "AET");
  assert.equal(merged.penalty_result, "Leeds United win 4 - 2 on penalties");
});

test("combineLiveActivityOperationalMatches prefers BSD penalty result over stale fallback duplicate", () => {
  const matches = __testHooks.combineLiveActivityOperationalMatches(
    [
      {
        match_details_id: "8362",
        date: "2026-06-30",
        time: "02:00",
        league: "FIFA World Cup 2026",
        league_subcategory: "Round of 32",
        home_team: "Netherlands",
        away_team: "Morocco",
        home_score: 1,
        away_score: 1,
        score_status: "AET",
        penalty_result: "Morocco win 3 - 2 on penalties",
        updated_at: "2026-06-30T22:10:00.000Z",
        tv_channels: ["ITV"],
      },
    ],
    [
      {
        match_details_id: "2499836",
        date: "2026-06-30",
        time: "02:00",
        league: "FIFA World Cup 2026",
        league_subcategory: "Round of 32",
        home_team: "Netherlands",
        away_team: "Morocco",
        home_score: null,
        away_score: null,
        score_status: null,
        tv_channels: ["ITV"],
      },
    ]
  );

  assert.equal(matches.length, 1);
  assert.equal(matches[0].match_details_id, "8362");
  assert.equal(matches[0].home_score, 1);
  assert.equal(matches[0].away_score, 1);
  assert.equal(matches[0].score_status, "AET");
  assert.equal(matches[0].penalty_result, "Morocco win 3 - 2 on penalties");
});

test("buildLiveActivityContentState sends penalty shootout score in home-away order", () => {
  const contentState = __testHooks.buildLiveActivityContentState(
    "multi_live",
    [
      {
        match_details_id: "8362",
        date: "2026-06-30",
        time: "02:00",
        league: "FIFA World Cup 2026",
        league_subcategory: "Round of 32",
        home_team: "Netherlands",
        away_team: "Morocco",
        home_score: 1,
        away_score: 1,
        score_status: "AET",
        penalty_result: "Morocco win 3 - 2 on penalties",
        tv_channels: ["ITV"],
      },
    ],
    2,
    Date.parse("2026-06-30T22:31:00Z")
  );

  assert.equal(contentState.matches[0].matchId, "8362");
  assert.equal(contentState.matches[0].homeScore, 1);
  assert.equal(contentState.matches[0].awayScore, 1);
  assert.equal(contentState.matches[0].matchTime, "AET");
  assert.equal(contentState.matches[0].penaltyWinner, "away");
  assert.equal(contentState.matches[0].penaltyResult, "P 2-3");
});

test("buildLiveActivityContentState clears pre-kickoff live status and uses primary canonical TV logo", () => {
  const contentState = __testHooks.buildLiveActivityContentState(
    "multi_live",
    [
      {
        match_details_id: "8365",
        date: "2026-07-01",
        time: "02:00",
        league: "FIFA World Cup 2026",
        league_subcategory: "Round of 32",
        home_team: "Mexico",
        away_team: "Ecuador",
        home_score: 0,
        away_score: 0,
        score_status: "LIVE",
        tv_channels: ["ITV", "DAZN"],
      },
    ],
    2,
    Date.parse("2026-07-01T00:31:00Z")
  );

  assert.equal(contentState.matches[0].homeScore, undefined);
  assert.equal(contentState.matches[0].awayScore, undefined);
  assert.equal(contentState.matches[0].matchTime, undefined);
  assert.deepStrictEqual(contentState.matches[0].tvChannels, ["ITV"]);
  assert.equal(contentState.matches[0].tvLogoKey, "itv");
});

test("buildLiveActivityContentState localizes kickoff times for the device time zone", () => {
  const contentState = __testHooks.buildLiveActivityContentState(
    "single_upcoming",
    [
      {
        match_details_id: "france-spain",
        date: "2026-07-14",
        time: "20:00",
        league: "FIFA World Cup 2026",
        home_team: "France",
        away_team: "Spain",
      },
    ],
    0,
    Date.parse("2026-07-14T12:00:00Z"),
    null,
    "Europe/Vienna"
  );

  assert.equal(contentState.matches[0].date, "2026-07-14");
  assert.equal(contentState.matches[0].time, "21:00");
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

  assert.deepStrictEqual(contentState.matches[0].tvChannels, ["Amazon"]);
  assert.equal(contentState.matches[0].tvLogoKey, "amazon");
  assert.equal(contentState.matches[0].homeLogoKey, "Newcastle United");
  assert.equal(contentState.matches[0].awayLogoKey, "Barcelona");
});

test("buildLiveActivityContentState prefers a recognized broadcaster over an unrecognized one listed first", () => {
  const contentState = __testHooks.buildLiveActivityContentState(
    "single_upcoming",
    [
      {
        match_details_id: "2503636",
        date: "2026-07-02",
        time: "20:00",
        league: "FIFA World Cup 2026",
        league_subcategory: "Round of 32",
        home_team: "Spain",
        away_team: "Austria",
        tv_channels: ["CT Sport", "ERT 2 GR", "NPO 1", "BBC One", "TVP Sport"],
      },
    ],
    2,
    Date.now()
  );

  assert.deepStrictEqual(contentState.matches[0].tvChannels, ["BBC"]);
  assert.equal(contentState.matches[0].tvLogoKey, "bbc");
});

test("buildLiveActivityContentState falls back to the first channel when none are recognized broadcasters", () => {
  const contentState = __testHooks.buildLiveActivityContentState(
    "single_upcoming",
    [
      {
        match_details_id: "2503637",
        date: "2026-07-02",
        time: "20:00",
        league: "FIFA World Cup 2026",
        league_subcategory: "Round of 32",
        home_team: "Portugal",
        away_team: "Croatia",
        tv_channels: ["CT Sport", "ERT 2 GR", "NPO 1"],
      },
    ],
    2,
    Date.now()
  );

  assert.deepStrictEqual(contentState.matches[0].tvChannels, ["CT Sport"]);
  assert.equal(contentState.matches[0].tvLogoKey, undefined);
});

test("buildLiveActivityContentState sends provided short names as display-ready team names", () => {
  const contentState = __testHooks.buildLiveActivityContentState(
    "multi_live",
    [
      {
        match_details_id: "cshortname123",
        date: "2026-04-22",
        time: "19:45",
        league: "La Liga",
        home_team: "Real Sociedad",
        away_team: "Atletico Madrid",
        home_short_name: "Sociedad",
        away_short_name: "Atletico",
        home_score: 1,
        away_score: 0,
        score_status: "55",
        tv_channels: ["LaLigaTV"],
      },
    ],
    0,
    Date.parse("2026-04-22T18:56:00Z")
  );

  assert.equal(contentState.matches[0].homeTeam, "Sociedad");
  assert.equal(contentState.matches[0].awayTeam, "Atletico");
  assert.equal(contentState.matches[0].homeShortName, undefined);
  assert.equal(contentState.matches[0].awayShortName, undefined);
});

test("buildLiveActivityContentState resolves actual fixture team logo keys from long names", () => {
  const contentState = __testHooks.buildLiveActivityContentState(
    "multi_upcoming",
    [
      {
        match_details_id: "cj60j38yk0gt",
        date: "2026-04-28",
        time: "20:00",
        league: "Champions League",
        home_team: "Paris Saint-Germain",
        away_team: "Bayern Munich",
        home_short_name: "PSG",
        away_short_name: "Bayern",
        tv_channels: ["Amazon"],
      },
      {
        match_details_id: "c5ywn6r7j59t",
        date: "2026-04-28",
        time: "19:45",
        league: "League One",
        home_team: "Northampton Town",
        away_team: "Barnsley",
        tv_channels: ["Sky Sports"],
      },
      {
        match_details_id: "cz78xd9l4pvt",
        date: "2026-04-28",
        time: "19:45",
        league: "League One",
        home_team: "Peterborough United",
        away_team: "Mansfield Town",
        tv_channels: ["Sky Sports"],
      },
    ],
    2,
    Date.parse("2026-04-28T13:15:00Z")
  );

  assert.equal(contentState.matches[0].homeLogoKey, "Paris Saint-Germain");
  assert.equal(contentState.matches[0].awayLogoKey, "Bayern Munich");
  assert.equal(contentState.matches[0].homeTeam, "PSG");
  assert.equal(contentState.matches[0].awayTeam, "Bayern");
  assert.equal(contentState.matches[1].homeLogoKey, "Northampton");
  assert.equal(contentState.matches[1].awayLogoKey, "Barnsley");
  assert.equal(contentState.matches[1].homeTeam, "Northampton");
  assert.equal(contentState.matches[1].awayTeam, "Barnsley");
  assert.equal(contentState.matches[2].homeLogoKey, "Peterborough");
  assert.equal(contentState.matches[2].awayLogoKey, "Mansfield");
  assert.equal(contentState.matches[2].homeTeam, "Peterborough");
  assert.equal(contentState.matches[2].awayTeam, "Mansfield");
});

test("buildLiveActivityContentState resolves a hyphenated full name to its logo asset via the static short-name fallback", () => {
  const contentState = __testHooks.buildLiveActivityContentState(
    "single_finished",
    [
      {
        match_details_id: "8368",
        date: "2026-07-02",
        time: "01:00",
        league: "FIFA World Cup 2026",
        home_team: "USA",
        away_team: "Bosnia-Herzegovina",
        home_score: 2,
        away_score: 0,
        score_status: "FT",
        tv_channels: ["ITV"],
      },
    ],
    2,
    Date.now()
  );

  // "Bosnia-Herzegovina" has no exact team_logo_assets entry and no BSD/TSDB
  // short name of its own — without the static team_short_names.json fallback
  // this resolves to null and the widget falls back to a "B" letter circle.
  assert.equal(contentState.matches[0].awayLogoKey, "Bosnia");
});

test("buildLiveActivityContentState falls back to team aliases as display-ready team names", () => {
  const contentState = __testHooks.buildLiveActivityContentState(
    "multi_upcoming",
    [
      {
        match_details_id: "csalford123",
        date: "2026-04-23",
        time: "20:00",
        league: "League Two",
        home_team: "Salford City",
        away_team: "Bromley",
        home_score: null,
        away_score: null,
        score_status: null,
        tv_channels: ["Sky Sports"],
      },
    ],
    0,
    Date.parse("2026-04-23T10:00:00Z")
  );

  assert.equal(contentState.matches[0].homeTeam, "Salford");
  assert.equal(contentState.matches[0].homeShortName, undefined);
  assert.equal(contentState.matches[0].awayShortName, undefined);
});

test("buildLiveActivityContentState uses display aliases as Premier League team names", () => {
  const contentState = __testHooks.buildLiveActivityContentState(
    "multi_upcoming",
    [
      {
        match_details_id: "cwestham123",
        date: "2026-04-25",
        time: "12:30",
        league: "Premier League",
        home_team: "West Ham United",
        away_team: "Everton",
        home_score: null,
        away_score: null,
        score_status: null,
      },
      {
        match_details_id: "cwolves123",
        date: "2026-04-25",
        time: "15:00",
        league: "Premier League",
        home_team: "Wolverhampton Wanderers",
        away_team: "Tottenham Hotspur",
        home_score: null,
        away_score: null,
        score_status: null,
      },
      {
        match_details_id: "castonvilla123",
        date: "2026-04-25",
        time: "12:30",
        league: "Premier League",
        home_team: "Aston Villa",
        away_team: "Crystal Palace",
        home_score: null,
        away_score: null,
        score_status: null,
      },
    ],
    0,
    Date.parse("2026-04-25T10:00:00Z")
  );

  assert.equal(contentState.matches[0].homeTeam, "West Ham");
  assert.equal(contentState.matches[0].homeShortName, undefined);
  assert.equal(contentState.matches[0].awayShortName, undefined);
  assert.equal(contentState.matches[1].homeTeam, "Wolves");
  assert.equal(contentState.matches[1].awayTeam, "Spurs");
  assert.equal(contentState.matches[1].homeShortName, undefined);
  assert.equal(contentState.matches[1].awayShortName, undefined);
  assert.equal(contentState.matches[2].homeShortName, undefined);
  assert.equal(contentState.matches[2].awayShortName, undefined);
});

test("buildLiveActivityContentState de-dupes duplicate match ids and keeps the freshest snapshot", () => {
  const contentState = __testHooks.buildLiveActivityContentState(
    "multi_live",
    [
      {
        match_details_id: "c8r1zve354lt",
        date: "2026-03-19",
        time: "17:45",
        league: "Premier League",
        home_team: "Nottingham Forest",
        away_team: "Brentford",
        home_score: 0,
        away_score: 0,
        score_status: "17",
        updated_at: "2026-03-19T17:17:00Z",
        tv_channels: ["Sky Sports Main Event"],
      },
      {
        match_details_id: "c8r1zve354lt",
        date: "2026-03-19",
        time: "17:45",
        league: "Premier League",
        home_team: "Nottingham Forest",
        away_team: "Brentford",
        home_score: 1,
        away_score: 0,
        score_status: "54",
        updated_at: "2026-03-19T17:54:00Z",
        tv_channels: ["TNT Sports 1", "Sky Sports Main Event"],
      },
    ],
    2,
    Date.parse("2026-03-19T17:56:00Z")
  );

  assert.equal(contentState.matches.length, 1);
  assert.equal(contentState.matches[0].matchId, "c8r1zve354lt");
  assert.equal(contentState.matches[0].homeScore, 1);
  assert.equal(contentState.matches[0].awayScore, 0);
  assert.equal(contentState.matches[0].matchTime, "54'");
  assert.deepStrictEqual(contentState.matches[0].tvChannels, ["TNT Sports"]);
});

test("buildLiveActivityContentState carries the penalty winner side for widget score rendering", () => {
  const contentState = __testHooks.buildLiveActivityContentState(
    "single_finished",
    [
      {
        match_details_id: "c75k3rv779xt",
        date: "2026-04-05",
        time: "15:30",
        league: "FA Cup",
        home_team: "West Ham United",
        away_team: "Leeds United",
        home_score: 2,
        away_score: 2,
        score_status: "AET",
        penalty_result: "Leeds United win 4 - 2 on penalties",
      },
    ],
    0,
    Date.parse("2026-04-05T19:48:00Z")
  );

  assert.equal(contentState.matches[0].penaltyWinner, "away");
});

test("buildLiveActivityScoreHash changes when a penalties winner is added to a drawn scoreline", () => {
  const baseState = __testHooks.buildLiveActivityContentState(
    "multi_live",
    [
      {
        match_details_id: "c75k3rv779xt",
        date: "2026-04-05",
        time: "15:30",
        league: "FA Cup",
        home_team: "West Ham United",
        away_team: "Leeds United",
        home_score: 2,
        away_score: 2,
        score_status: "AET",
      },
    ],
    0,
    Date.parse("2026-04-05T19:48:00Z")
  );
  const penaltiesState = __testHooks.buildLiveActivityContentState(
    "multi_live",
    [
      {
        match_details_id: "c75k3rv779xt",
        date: "2026-04-05",
        time: "15:30",
        league: "FA Cup",
        home_team: "West Ham United",
        away_team: "Leeds United",
        home_score: 2,
        away_score: 2,
        score_status: "AET",
        penalty_result: "Leeds United win 4 - 2 on penalties",
      },
    ],
    0,
    Date.parse("2026-04-05T19:49:00Z")
  );

  assert.notEqual(
    __testHooks.buildLiveActivityScoreHash(baseState),
    __testHooks.buildLiveActivityScoreHash(penaltiesState)
  );
});

test("combineLiveActivityOperationalMatches keeps recent finished matches alongside merged live matches", () => {
  const matches = __testHooks.combineLiveActivityOperationalMatches(
    [
      {
        match_details_id: "ce3g62vw192t",
        date: "2026-03-19",
        time: "20:00",
        league: "Premier League",
        home_team: "Liverpool",
        away_team: "Chelsea",
        home_score: 1,
        away_score: 0,
        score_status: "67",
        updated_at: "2026-03-19T21:07:00Z",
      },
    ],
    [
      {
        match_details_id: "c8r1zve354lt",
        date: "2026-03-19",
        time: "17:45",
        league: "Premier League",
        home_team: "Nottingham Forest",
        away_team: "Brentford",
        home_score: 1,
        away_score: 0,
        score_status: "FT",
        updated_at: "2026-03-19T19:42:00Z",
      },
    ]
  );

  assert.deepStrictEqual(
    matches.map((match) => match.match_details_id),
    ["ce3g62vw192t", "c8r1zve354lt"]
  );
});

test("combineLiveActivityOperationalMatches prefers newer corrected finished score over stale higher score", () => {
  const matches = __testHooks.combineLiveActivityOperationalMatches(
    [
      {
        match_details_id: "c8r1zve354lt",
        date: "2026-03-19",
        time: "17:45",
        league: "Premier League",
        home_team: "Aston Villa",
        away_team: "LOSC Lille",
        home_score: 2,
        away_score: 0,
        score_status: "FT",
        updated_at: "2026-03-19T19:40:00Z",
      },
    ],
    [
      {
        match_details_id: "c8r1zve354lt",
        date: "2026-03-19",
        time: "17:45",
        league: "Premier League",
        home_team: "Aston Villa",
        away_team: "LOSC Lille",
        home_score: 1,
        away_score: 0,
        score_status: "FT",
        updated_at: "2026-03-19T19:44:00Z",
      },
    ]
  );

  assert.equal(matches.length, 1);
  assert.equal(matches[0].home_score, 1);
  assert.equal(matches[0].away_score, 0);
});

test("enrichLiveActivityOperationalMatches restores missing match id and finished state from details", () => {
  const matches = __testHooks.enrichLiveActivityOperationalMatches(
    [
      {
        date: "2026-03-19",
        time: "17:45",
        league: "UEFA Europa League",
        league_subcategory: "Last 16",
        home_team: "FC Midtjylland",
        away_team: "Nottingham Forest",
        home_score: 0,
        away_score: 0,
        aggregate_home_score: 0,
        aggregate_away_score: 0,
        score_status: null,
        tv_channels: ["TNT Sports"],
      },
    ],
    {
      cmidtforest: {
        id: "cmidtforest",
        date: "2026-03-19",
        time: "17:45",
        league: "UEFA Europa League",
        league_subcategory: "Last 16",
        home_team: "Midtjylland",
        away_team: "Nottingham Forest",
        home_score: 1,
        away_score: 2,
        aggregate_home_score: 2,
        aggregate_away_score: 2,
        score_status: "AET",
        penalty_result: "Nottingham Forest win 3 - 0 on penalties",
        updated_at: "2026-03-19T20:38:00Z",
      },
    }
  );

  assert.equal(matches.length, 1);
  assert.equal(matches[0].match_details_id, "cmidtforest");
  assert.equal(matches[0].home_score, 1);
  assert.equal(matches[0].away_score, 2);
  assert.equal(matches[0].aggregate_home_score, 2);
  assert.equal(matches[0].aggregate_away_score, 2);
  assert.equal(matches[0].score_status, "AET");
  assert.equal(matches[0].penalty_result, "Nottingham Forest win 3 - 0 on penalties");
});

test("enrichLiveActivityOperationalMatches prefers canonical TV channels with supported logos", () => {
  const matches = __testHooks.enrichLiveActivityOperationalMatches(
    [
      {
        match_details_id: "2503391",
        date: "2026-07-01",
        time: "17:00",
        league: "FIFA World Cup 2026",
        league_subcategory: "Round of 32",
        home_team: "England",
        away_team: "DR Congo",
        home_score: null,
        away_score: null,
        score_status: null,
        tv_channels: ["Arena Sport 1 Premium RS"],
      },
    ],
    {
      "8366": {
        id: "8366",
        date: "2026-07-01",
        time: "17:00",
        league: "FIFA World Cup 2026",
        league_subcategory: "Round of 32",
        home_team: "England",
        away_team: "DR Congo",
        home_score: null,
        away_score: null,
        score_status: null,
        tv_channels: [
          { name: "BBC iPlayer", country: "United Kingdom", countryCode: "GB" },
          { name: "BBC One", country: "United Kingdom", countryCode: "GB" },
          { name: "BBC Sport Web", country: "United Kingdom", countryCode: "GB" },
        ],
      },
    }
  );

  assert.equal(matches.length, 1);
  assert.equal(matches[0].match_details_id, "8366");
  assert.deepStrictEqual(matches[0].tv_channels, ["BBC"]);

  const contentState = __testHooks.buildLiveActivityContentState(
    "multi_upcoming",
    matches,
    2,
    Date.parse("2026-07-01T00:42:00Z")
  );

  assert.deepStrictEqual(contentState.matches[0].tvChannels, ["BBC"]);
  assert.equal(contentState.matches[0].tvLogoKey, "bbc");
});

test("combineLiveActivityOperationalMatches keeps public-list TV logos over legacy fallback rows", () => {
  const publicMatches = [
    {
      match_details_id: "8366",
      date: "2026-07-01",
      time: "17:00",
      league: "FIFA World Cup 2026",
      league_subcategory: "Round of 32",
      home_team: "England",
      away_team: "DR Congo",
      home_score: null,
      away_score: null,
      score_status: null,
      tv_channels: [{ name: "BBC iPlayer", country: "United Kingdom", countryCode: "GB" }],
    },
    {
      match_details_id: "8367",
      date: "2026-07-01",
      time: "21:00",
      league: "FIFA World Cup 2026",
      league_subcategory: "Round of 32",
      home_team: "Belgium",
      away_team: "Senegal",
      home_score: null,
      away_score: null,
      score_status: null,
      tv_channels: [{ name: "ITV", country: "United Kingdom", countryCode: "GB" }],
    },
  ];
  const legacyFallbackMatches = [
    {
      match_details_id: "2503391",
      date: "2026-07-01",
      time: "17:00",
      league: "FIFA World Cup 2026",
      league_subcategory: "Round of 32",
      home_team: "England",
      away_team: "DR Congo",
      home_score: null,
      away_score: null,
      score_status: null,
      tv_channels: ["Arena Sport 1 Premium RS"],
    },
    {
      match_details_id: "2503392",
      date: "2026-07-01",
      time: "21:00",
      league: "FIFA World Cup 2026",
      league_subcategory: "Round of 32",
      home_team: "Belgium",
      away_team: "Senegal",
      home_score: null,
      away_score: null,
      score_status: null,
      tv_channels: ["Arena Sport 1 Premium RS", "C More Sport 1 FI", "DAZN Italy", "ITV"],
    },
  ];

  const matches = __testHooks.combineLiveActivityOperationalMatches(
    publicMatches,
    legacyFallbackMatches
  );
  const contentState = __testHooks.buildLiveActivityContentState(
    "multi_upcoming",
    matches,
    2,
    Date.parse("2026-07-01T10:10:36Z")
  );

  assert.deepStrictEqual(
    contentState.matches.map((match) => ({
      homeTeam: match.homeTeam,
      awayTeam: match.awayTeam,
      tvChannels: match.tvChannels,
      tvLogoKey: match.tvLogoKey,
    })),
    [
      { homeTeam: "England", awayTeam: "DR Congo", tvChannels: ["BBC"], tvLogoKey: "bbc" },
      { homeTeam: "Belgium", awayTeam: "Senegal", tvChannels: ["ITV"], tvLogoKey: "itv" },
    ]
  );
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

test("buildLiveActivityPresentationForUser preserves explicit zero aggregate for upcoming live activity entries", () => {
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
  assert.equal(presentation.matches[0].aggregate_home_score, 0);
  assert.equal(presentation.matches[0].aggregate_away_score, 0);
  assert.equal(presentation.matches[1].aggregate_home_score, 0);
  assert.equal(presentation.matches[1].aggregate_away_score, 0);
});

test("buildLiveActivityPresentationForUser preserves explicit zero aggregate for upcoming knockout ties", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs + 10 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(),
    [
      {
        state: null,
        match: {
          match_details_id: "c5yqnegjv2xt",
          date: kickoff.date,
          time: kickoff.time,
          league: "UEFA Conference League",
          league_subcategory: "Last 16",
          home_team: "AEK Larnaca",
          away_team: "Crystal Palace",
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

  assert.equal(presentation.mode, "single_upcoming");
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].aggregate_home_score, 0);
  assert.equal(presentation.matches[0].aggregate_away_score, 0);
});

test("buildLiveActivityPresentationForUser suppresses stale pre-kickoff zero scores", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs + 10 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(),
    [
      {
        state: null,
        match: {
          match_details_id: "cj6d3kd99ekt",
          date: kickoff.date,
          time: kickoff.time,
          league: "Premier League",
          home_team: "Crystal Palace",
          away_team: "Leeds United",
          home_score: 0,
          away_score: 0,
          score_status: null,
          aggregate_home_score: 0,
          aggregate_away_score: 0,
          tv_channels: ["Sky Sports Cricket"],
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_upcoming");
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].home_score, null);
  assert.equal(presentation.matches[0].away_score, null);
  assert.equal(presentation.matches[0].aggregate_home_score, 0);
  assert.equal(presentation.matches[0].aggregate_away_score, 0);
  assert.equal(presentation.matches[0].score_status, null);
});

test("sanitizePreKickoffScoresForLiveActivity preserves live 0-0 scores once status is live", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 8 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const sanitized = __testHooks.sanitizePreKickoffScoresForLiveActivity(
    {
      match_details_id: "live_zero_zero",
      date: kickoff.date,
      time: kickoff.time,
      league: "Premier League",
      home_team: "Arsenal",
      away_team: "Chelsea",
      home_score: 0,
      away_score: 0,
      score_status: "8",
      updated_at: new Date(nowMs).toISOString(),
    },
    nowMs,
    "test"
  );

  assert.equal(sanitized.home_score, 0);
  assert.equal(sanitized.away_score, 0);
  assert.equal(sanitized.score_status, "8");
});

test("sanitizePreKickoffScoresForLiveActivity preserves non-zero aggregate for upcoming fixtures", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs + 3 * 60 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const sanitized = __testHooks.sanitizePreKickoffScoresForLiveActivity(
    {
      match_details_id: "aggregate_fixture",
      date: kickoff.date,
      time: kickoff.time,
      league: "UEFA Europa League",
      league_subcategory: "Last 16",
      home_team: "Midtjylland",
      away_team: "Nottingham Forest",
      home_score: null,
      away_score: null,
      aggregate_home_score: 1,
      aggregate_away_score: 0,
      score_status: null,
      updated_at: new Date(nowMs).toISOString(),
    },
    nowMs,
    "test"
  );

  assert.equal(sanitized.home_score, null);
  assert.equal(sanitized.away_score, null);
  assert.equal(sanitized.aggregate_home_score, 1);
  assert.equal(sanitized.aggregate_away_score, 0);
  assert.equal(sanitized.score_status, null);
});

test("buildLiveActivityContentState preserves known zero aggregate when first-leg score is explicit", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs + 2 * 60 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const contentState = __testHooks.buildLiveActivityContentState(
    "single_upcoming",
    [
      {
        match_details_id: "c5yqnegjv2xt",
        date: kickoff.date,
        time: kickoff.time,
        league: "UEFA Conference League",
        league_subcategory: "Last 16",
        home_team: "AEK Larnaca",
        away_team: "Crystal Palace",
        home_score: null,
        away_score: null,
        aggregate_home_score: 0,
        aggregate_away_score: 0,
        first_leg_home_score: 0,
        first_leg_away_score: 0,
        score_status: null,
      },
    ],
    0,
    nowMs
  );

  assert.equal(contentState.matches[0].aggregateHomeScore, undefined);
  assert.equal(contentState.matches[0].aggregateAwayScore, undefined);
  assert.equal(contentState.matches[0].firstLegHomeScore, 0);
  assert.equal(contentState.matches[0].firstLegAwayScore, 0);
});

test("buildLiveActivityContentState derives aggregate from first-leg score when aggregate is missing", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs + 2 * 60 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const contentState = __testHooks.buildLiveActivityContentState(
    "single_upcoming",
    [
      {
        match_details_id: "c5yqnegjv2xt",
        date: kickoff.date,
        time: kickoff.time,
        league: "UEFA Conference League",
        league_subcategory: "Last 16",
        home_team: "AEK Larnaca",
        away_team: "Crystal Palace",
        home_score: null,
        away_score: null,
        aggregate_home_score: null,
        aggregate_away_score: null,
        first_leg_home_score: 0,
        first_leg_away_score: 0,
        score_status: null,
      },
    ],
    0,
    nowMs
  );

  assert.equal(contentState.matches[0].aggregateHomeScore, undefined);
  assert.equal(contentState.matches[0].aggregateAwayScore, undefined);
  assert.equal(contentState.matches[0].firstLegHomeScore, 0);
  assert.equal(contentState.matches[0].firstLegAwayScore, 0);
});

test("buildLiveActivityContentState prefers computed second-leg aggregate over stale explicit aggregate", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 16 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const contentState = __testHooks.buildLiveActivityContentState(
    "single_live",
    [
      {
        match_details_id: "c6x8p4q7v1zt",
        date: kickoff.date,
        time: kickoff.time,
        league: "UEFA Champions League",
        league_subcategory: "Quarter-final",
        home_team: "Aston Villa",
        away_team: "Bologna",
        home_score: 1,
        away_score: 0,
        aggregate_home_score: 3,
        aggregate_away_score: 1,
        first_leg_home_score: 3,
        first_leg_away_score: 1,
        score_status: "16'",
      },
    ],
    0,
    nowMs
  );

  assert.equal(contentState.matches[0].aggregateHomeScore, undefined);
  assert.equal(contentState.matches[0].aggregateAwayScore, undefined);
  assert.equal(contentState.matches[0].firstLegHomeScore, 3);
  assert.equal(contentState.matches[0].firstLegAwayScore, 1);
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

test("buildLiveActivityPresentationForUser normalizes stale stoppage-time snapshots to the configured delayed minute", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 55 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(2),
    [
      {
        state: {
          lastState: {
            match_details_id: "c05vqzv88jnt",
            date: kickoff.date,
            time: kickoff.time,
            league: "Premier League",
            home_team: "Liverpool",
            away_team: "Tottenham Hotspur",
            home_score: 1,
            away_score: 0,
            score_status: "50",
            home_goal_scorers: [
              {
                player: "Dominik Szoboszlai",
                goal_times: ["18'"],
                own_goal_times: [],
              },
            ],
            away_goal_scorers: [],
            updated_at: new Date(nowMs).toISOString(),
          },
          history: [
            {
              timestampMs: nowMs - 2 * 60 * 1000 - 5 * 1000,
              match: {
                match_details_id: "c05vqzv88jnt",
                date: kickoff.date,
                time: kickoff.time,
                league: "Premier League",
                home_team: "Liverpool",
                away_team: "Tottenham Hotspur",
                home_score: 1,
                away_score: 0,
                score_status: "45+4",
                home_goal_scorers: [
                  {
                    player: "Dominik Szoboszlai",
                    goal_times: ["18'"],
                    own_goal_times: [],
                  },
                ],
                away_goal_scorers: [],
              },
            },
          ],
        },
        match: {
          match_details_id: "c05vqzv88jnt",
          date: kickoff.date,
          time: kickoff.time,
          league: "Premier League",
          home_team: "Liverpool",
          away_team: "Tottenham Hotspur",
          home_score: 1,
          away_score: 0,
          score_status: "50",
          home_goal_scorers: [
            {
              player: "Dominik Szoboszlai",
              goal_times: ["18'"],
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
  assert.equal(presentation.matches[0].score_status, "48");
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

test("buildLiveActivityPresentationForUser prefers Redis delayed snapshot over stale local delay reconstruction", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 95 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(2),
    [
      {
        matchId: "c-bournemouth-manutd",
        state: {
          lastState: {
            match_details_id: "c-bournemouth-manutd",
            date: kickoff.date,
            time: kickoff.time,
            league: "Premier League",
            home_team: "AFC Bournemouth",
            away_team: "Manchester United",
            home_score: 2,
            away_score: 2,
            score_status: "90+6",
            home_goal_scorers: [
              {
                player: "Ryan Christie",
                goal_times: ["67'"],
                own_goal_times: [],
              },
            ],
            away_goal_scorers: [
              {
                player: "Bruno Fernandes",
                goal_times: ["61'"],
                own_goal_times: [],
              },
            ],
            updated_at: new Date(nowMs).toISOString(),
          },
          history: [
            {
              timestampMs: nowMs - 60 * 1000,
              match: {
                match_details_id: "c-bournemouth-manutd",
                date: kickoff.date,
                time: kickoff.time,
                league: "Premier League",
                home_team: "AFC Bournemouth",
                away_team: "Manchester United",
                home_score: 1,
                away_score: 1,
                score_status: "90+4",
                home_goal_scorers: [
                  {
                    player: "Ryan Christie",
                    goal_times: ["67'"],
                    own_goal_times: [],
                  },
                ],
                away_goal_scorers: [
                  {
                    player: "Bruno Fernandes",
                    goal_times: ["61'"],
                    own_goal_times: [],
                  },
                ],
              },
            },
          ],
        },
        match: {
          match_details_id: "c-bournemouth-manutd",
          date: kickoff.date,
          time: kickoff.time,
          league: "Premier League",
          home_team: "AFC Bournemouth",
          away_team: "Manchester United",
          home_score: 2,
          away_score: 2,
          score_status: "90+6",
          home_goal_scorers: [
            {
              player: "Ryan Christie",
              goal_times: ["67'"],
              own_goal_times: [],
            },
          ],
          away_goal_scorers: [
            {
              player: "Bruno Fernandes",
              goal_times: ["61'"],
              own_goal_times: [],
            },
          ],
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs,
    {
      delayedSnapshotsByMatchId: {
        "c-bournemouth-manutd": {
          match_details_id: "c-bournemouth-manutd",
          date: kickoff.date,
          time: kickoff.time,
          league: "Premier League",
          home_team: "AFC Bournemouth",
          away_team: "Manchester United",
          home_score: 2,
          away_score: 2,
          score_status: "90+4",
          home_goal_scorers: [
            {
              player: "Ryan Christie",
              goal_times: ["67'", "81'"],
              own_goal_times: [],
            },
          ],
          away_goal_scorers: [
            {
              player: "Bruno Fernandes",
              goal_times: ["61'"],
              own_goal_times: ["71'"],
            },
          ],
        },
      },
    }
  );

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].score_status, "90+4");
  assert.equal(presentation.matches[0].home_score, 2);
  assert.equal(presentation.matches[0].away_score, 2);
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

test("calculateFantasyCurrentScore recomputes from server live data for zero-minute live auto-subs", () => {
  __testHooks.resetFantasyScoreContext();
  try {
    __testHooks.setFantasyScoreContext({
      bootstrap: {
        elements: [
          { id: 1, team: 1, status: "a" },
          { id: 2, team: 1, status: "a" },
          { id: 3, team: 1, status: "a" },
          { id: 4, team: 1, status: "a" },
          { id: 5, team: 1, status: "a" },
          { id: 6, team: 1, status: "a" },
          { id: 7, team: 1, status: "a" },
          { id: 8, team: 1, status: "a" },
          { id: 9, team: 1, status: "a" },
          { id: 10, team: 2, status: "a" },
          { id: 11, team: 3, status: "a" },
          { id: 12, team: 4, status: "a" },
          { id: 13, team: 5, status: "a" },
          { id: 14, team: 5, status: "a" },
          { id: 15, team: 5, status: "a" },
        ],
        teams: [
          { id: 1, name: "Arsenal" },
          { id: 2, name: "Liverpool" },
          { id: 3, name: "Manchester City" },
          { id: 4, name: "Burnley" },
          { id: 5, name: "Leeds United" },
          { id: 6, name: "Tottenham Hotspur" },
        ],
        events: [{ id: 30, is_current: true }],
      },
      fixtures: [
        { id: 101, event: 30, team_h: 1, team_a: 3, started: true, finished: true, finished_provisional: true },
        { id: 102, event: 30, team_h: 4, team_a: 5, started: true, finished: true, finished_provisional: true },
        { id: 103, event: 30, team_h: 2, team_a: 6, started: true, finished: false, finished_provisional: false },
      ],
      live: {
        elements: [
          { id: 1, stats: { total_points: 2, minutes: 90 } },
          { id: 2, stats: { total_points: 9, minutes: 90 } },
          { id: 3, stats: { total_points: 10, minutes: 90 } },
          { id: 4, stats: { total_points: 2, minutes: 90 } },
          { id: 5, stats: { total_points: 2, minutes: 90 } },
          { id: 6, stats: { total_points: 1, minutes: 90 } },
          { id: 7, stats: { total_points: 6, minutes: 90 } },
          { id: 8, stats: { total_points: 3, minutes: 90 } },
          { id: 9, stats: { total_points: 4, minutes: 90 } },
          { id: 10, stats: { total_points: 0, minutes: 0 } },
          { id: 11, stats: { total_points: 1, minutes: 90 } },
          { id: 12, stats: { total_points: 0, minutes: 0 } },
          { id: 13, stats: { total_points: 8, minutes: 90 } },
          { id: 14, stats: { total_points: 0, minutes: 0 } },
          { id: 15, stats: { total_points: 0, minutes: 0 } },
        ],
      },
    });

    const score = __testHooks.calculateFantasyCurrentScore({
      managerEntryID: 6653695,
      squad: {
        managerEntryID: 6653695,
        gameweekID: 30,
        gameweekTitle: "GW30",
        resolvedCurrentScore: 40,
        effectiveContributions: [
          { elementID: 1, displayName: "Keeper A", teamName: "Arsenal", points: 40 },
        ],
        players: [
          { elementID: 1, pickPosition: 1, positionType: 1, displayName: "Keeper A", teamName: "Arsenal", multiplier: 1, isStarter: true },
          { elementID: 2, pickPosition: 2, positionType: 2, displayName: "Def A", teamName: "Arsenal", multiplier: 1, isStarter: true },
          { elementID: 3, pickPosition: 3, positionType: 2, displayName: "Def B", teamName: "Arsenal", multiplier: 1, isStarter: true },
          { elementID: 4, pickPosition: 4, positionType: 2, displayName: "Def C", teamName: "Arsenal", multiplier: 1, isStarter: true },
          { elementID: 5, pickPosition: 5, positionType: 3, displayName: "Mid A", teamName: "Arsenal", multiplier: 1, isStarter: true },
          { elementID: 6, pickPosition: 6, positionType: 3, displayName: "Mid B", teamName: "Arsenal", multiplier: 1, isStarter: true },
          { elementID: 7, pickPosition: 7, positionType: 3, displayName: "Mid C", teamName: "Arsenal", multiplier: 1, isStarter: true },
          { elementID: 8, pickPosition: 8, positionType: 3, displayName: "Mid D", teamName: "Arsenal", multiplier: 1, isStarter: true },
          { elementID: 9, pickPosition: 9, positionType: 3, displayName: "Mid E", teamName: "Arsenal", multiplier: 1, isStarter: true },
          { elementID: 10, pickPosition: 10, positionType: 4, displayName: "Fwd A", teamName: "Liverpool", multiplier: 1, isStarter: true },
          { elementID: 11, pickPosition: 11, positionType: 4, displayName: "Fwd B", teamName: "Manchester City", multiplier: 1, isStarter: true },
          { elementID: 12, pickPosition: 12, positionType: 1, displayName: "Bench Gk", teamName: "Burnley", multiplier: 0, isStarter: false },
          { elementID: 13, pickPosition: 13, positionType: 2, displayName: "Bench Def", teamName: "Leeds United", multiplier: 0, isStarter: false },
          { elementID: 14, pickPosition: 14, positionType: 3, displayName: "Bench Mid", teamName: "Leeds United", multiplier: 0, isStarter: false },
          { elementID: 15, pickPosition: 15, positionType: 4, displayName: "Bench Fwd", teamName: "Leeds United", multiplier: 0, isStarter: false },
        ],
      },
    });

    assert.equal(score, 48);
  } finally {
    __testHooks.resetFantasyScoreContext();
  }
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

test("buildLiveActivityPresentationForUser omits fantasy score when no fantasy team is connected", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs + 10 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    {
      preferences: { liveActivityDelayMinutes: 0 },
      fantasy: {
        squad: {
          resolvedCurrentScore: 40,
          effectiveContributions: [
            { elementID: 1, displayName: "Saka", teamName: "Arsenal", points: 40 },
          ],
        },
      },
    },
    [
      {
        state: null,
        match: {
          match_details_id: "ff-upcoming-no-team",
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
  assert.equal(presentation.fantasyCurrentScore, null);
});

test("buildLiveActivityContentState preserves null fantasy score instead of coercing it to zero", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs + 10 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const contentState = __testHooks.buildLiveActivityContentState(
    "single_upcoming",
    [
      {
        match_details_id: "ff-null",
        date: kickoff.date,
        time: kickoff.time,
        league: "Premier League",
        home_team: "Arsenal",
        away_team: "Chelsea",
        home_score: null,
        away_score: null,
        score_status: null,
        tv_channels: [],
      },
    ],
    2,
    nowMs,
    null
  );

  assert.equal(contentState.fantasyCurrentScore, undefined);
  const parsedHash = JSON.parse(JSON.stringify({
    fantasyCurrentScore: contentState.fantasyCurrentScore,
  }));
  assert.equal(Object.prototype.hasOwnProperty.call(parsedHash, "fantasyCurrentScore"), false);
});

test("buildLiveActivityPresentationForUser can include later upcoming fixtures for app foreground display", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs + 2 * 60 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const withoutForegroundOverride = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(0),
    [
      {
        state: null,
        match: {
          match_details_id: "future-upcoming",
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

  assert.equal(withoutForegroundOverride.mode, "single_upcoming");
  assert.equal(withoutForegroundOverride.matches.length, 1);
  assert.equal(withoutForegroundOverride.matches[0].match_details_id, "future-upcoming");

  const withForegroundOverride = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(0),
    [
      {
        state: null,
        match: {
          match_details_id: "future-upcoming",
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
    nowMs,
    { allowAllUpcoming: true }
  );

  assert.equal(withForegroundOverride.mode, "single_upcoming");
  assert.equal(withForegroundOverride.matches.length, 1);
  assert.equal(withForegroundOverride.matches[0].match_details_id, "future-upcoming");
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

test("buildLiveActivityPresentationForUser hides scores when full delay buffer exists but delayed snapshot is missing", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 85 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(2),
    [
      {
        matchId: "c-delayed-missing",
        state: {
          lastState: {
            match_details_id: "c-delayed-missing",
            date: kickoff.date,
            time: kickoff.time,
            league: "Premier League",
            home_team: "Arsenal",
            away_team: "Chelsea",
            home_score: 1,
            away_score: 0,
            score_status: "55",
            updated_at: new Date(nowMs - 10 * 60 * 1000).toISOString(),
          },
          history: [
            {
              timestampMs: nowMs - 10 * 60 * 1000,
              match: {
                match_details_id: "c-delayed-missing",
                date: kickoff.date,
                time: kickoff.time,
                league: "Premier League",
                home_team: "Arsenal",
                away_team: "Chelsea",
                home_score: 1,
                away_score: 0,
                score_status: "55",
              },
            },
            {
              timestampMs: kickoffMs - 60 * 1000,
              match: {
                match_details_id: "c-delayed-missing",
                date: kickoff.date,
                time: kickoff.time,
                league: "Premier League",
                home_team: "Arsenal",
                away_team: "Chelsea",
                home_score: 0,
                away_score: 0,
                score_status: null,
              },
            },
          ],
        },
        match: {
          match_details_id: "c-delayed-missing",
          date: kickoff.date,
          time: kickoff.time,
          league: "Premier League",
          home_team: "Arsenal",
          away_team: "Chelsea",
          home_score: 1,
          away_score: 0,
          score_status: "55",
          updated_at: new Date(nowMs - 10 * 60 * 1000).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].home_score, null);
  assert.equal(presentation.matches[0].away_score, null);
  assert.equal(presentation.matches[0].score_status, "53");
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

test("buildLiveActivityPresentationForUser trusts the latest eligible delayed snapshot's own score as-is", () => {
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
  // The "89" history entry is the latest one at or before the delay target —
  // BSD is a single authoritative source, so its score (3-1) is used as-is,
  // even though an earlier entry momentarily had a higher home score (4-0).
  assert.equal(presentation.matches[0].score_status, "89");
  assert.equal(presentation.matches[0].home_score, 3);
  assert.equal(presentation.matches[0].away_score, 1);
});

test("buildLiveActivityPresentationForUser falls back to the computed delayed minute when the snapshot's minute is ahead of the current minute", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 95 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    { preferences: { notificationDelayMinutes: 2 } },
    [
      {
        state: {
          lastState: {
            match_details_id: "argentina-capeverde",
            date: kickoff.date,
            time: kickoff.time,
            league: "FIFA World Cup 2026",
            home_team: "Argentina",
            away_team: "Cape Verde",
            home_score: 2,
            away_score: 1,
            score_status: "90+3",
            updated_at: new Date(nowMs).toISOString(),
          },
          history: [
            {
              // A previously-announced (and later revised down) added-time value
              // was captured here, leaving this snapshot's own minute (97) ahead
              // of the current match minute (93) even though it's chronologically
              // the delayed one — the delayed minute must never outrun "now".
              timestampMs: nowMs - 2 * 60 * 1000,
              match: {
                match_details_id: "argentina-capeverde",
                date: kickoff.date,
                time: kickoff.time,
                league: "FIFA World Cup 2026",
                home_team: "Argentina",
                away_team: "Cape Verde",
                home_score: 2,
                away_score: 1,
                score_status: "90+7",
              },
            },
          ],
        },
        match: {
          match_details_id: "argentina-capeverde",
          date: kickoff.date,
          time: kickoff.time,
          league: "FIFA World Cup 2026",
          home_team: "Argentina",
          away_team: "Cape Verde",
          home_score: 2,
          away_score: 1,
          score_status: "90+3",
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.matches.length, 1);
  // Computed fallback: currentMinute (93) - delayMinutes (2) = 91, not the
  // untrustworthy snapshot minute of 97.
  assert.equal(presentation.matches[0].score_status, "91");
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

test("buildLiveActivityPresentationForUser avoids stale delayed score regression in stoppage time", () => {
  const nowMs = Date.now();
  const kickoffMs = nowMs - 94 * 60 * 1000;
  const kickoff = formatLocalDateTimeParts(kickoffMs);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    { preferences: { notificationDelayMinutes: 2 } },
    [
      {
        state: {
          lastState: {
            match_details_id: "forest-villa",
            date: kickoff.date,
            time: kickoff.time,
            league: "UEFA Europa League",
            home_team: "Forest",
            away_team: "Aston Villa",
            home_score: 1,
            away_score: 0,
            score_status: "90+4",
            home_goal_scorers: [],
            away_goal_scorers: [],
            updated_at: new Date(nowMs).toISOString(),
          },
          history: [
            {
              timestampMs: nowMs - 2 * 60 * 1000,
              match: {
                match_details_id: "forest-villa",
                date: kickoff.date,
                time: kickoff.time,
                league: "UEFA Europa League",
                home_team: "Forest",
                away_team: "Aston Villa",
                home_score: 0,
                away_score: 0,
                score_status: "90+2",
                home_goal_scorers: [],
                away_goal_scorers: [],
              },
            },
          ],
        },
        match: {
          match_details_id: "forest-villa",
          date: kickoff.date,
          time: kickoff.time,
          league: "UEFA Europa League",
          home_team: "Forest",
          away_team: "Aston Villa",
          home_score: 1,
          away_score: 0,
          score_status: "90+4",
          home_goal_scorers: [],
          away_goal_scorers: [],
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "single_live");
  assert.equal(presentation.delayMinutes, 2);
  assert.equal(presentation.matches.length, 1);
  assert.equal(presentation.matches[0].score_status, "90+2");
  assert.equal(presentation.matches[0].home_score, 1);
  assert.equal(presentation.matches[0].away_score, 0);
});

test("compareLiveActivityMatches sorts earlier kickoffs first", () => {
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

  const sorted = [laterKickoffMatch, earlierKickoffMatch].sort(__testHooks.compareLiveActivityMatches);
  assert.equal(sorted[0].match_details_id, "earlier");
});

test("compareLiveActivityMatches sorts in-progress matches ahead of finished ones regardless of kickoff time or competition weight", () => {
  const finishedEarlierKickoffHigherWeight = {
    match_details_id: "8374",
    league: "FIFA World Cup 2026",
    home_team: "Colombia",
    away_team: "Ghana",
    date: "2026-07-04",
    time: "02:30",
    score_status: "FT",
  };
  const liveLaterKickoffLowerWeight = {
    match_details_id: "8381",
    league: "Championship",
    home_team: "Middlesbrough",
    away_team: "Southampton",
    date: "2026-07-04",
    time: "18:00",
    score_status: "63",
  };

  const sorted = [finishedEarlierKickoffHigherWeight, liveLaterKickoffLowerWeight].sort(
    __testHooks.compareLiveActivityMatches
  );
  assert.equal(sorted[0].match_details_id, "8381");
});

test("compareUpcomingLiveActivityMatches sorts earlier kickoffs first", () => {
  const laterKickoffMatch = {
    match_details_id: "later",
    league: "Premier League",
    home_team: "Liverpool",
    away_team: "Tottenham Hotspur",
    home_team_score: 1961,
    away_team_score: 1835,
    total_team_score: 3796,
    date: "2026-03-15",
    time: "16:30",
  };
  const earlierKickoffMatch = {
    match_details_id: "earlier",
    league: "Premier League",
    home_team: "Crystal Palace",
    away_team: "Leeds United",
    home_team_score: 1682,
    away_team_score: 1642,
    total_team_score: 3324,
    date: "2026-03-15",
    time: "14:00",
  };

  const sorted = [laterKickoffMatch, earlierKickoffMatch].sort(
    __testHooks.compareUpcomingLiveActivityMatches
  );
  assert.equal(sorted[0].match_details_id, "earlier");
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

test("compareUpcomingLiveActivityMatches sorts higher total team score first for identical kickoffs", () => {
  const highScoreMatch = {
    match_details_id: "high",
    league: "Premier League",
    home_team: "Liverpool",
    away_team: "Tottenham Hotspur",
    home_team_score: 1961,
    away_team_score: 1835,
    total_team_score: 3796,
    date: "2026-03-15",
    time: "14:00",
  };
  const lowScoreMatch = {
    match_details_id: "low",
    league: "Premier League",
    home_team: "Crystal Palace",
    away_team: "Leeds United",
    home_team_score: 1682,
    away_team_score: 1642,
    total_team_score: 3324,
    date: "2026-03-15",
    time: "14:00",
  };

  const sorted = [lowScoreMatch, highScoreMatch].sort(
    __testHooks.compareUpcomingLiveActivityMatches
  );
  assert.equal(sorted[0].match_details_id, "high");
});

test("buildLiveActivityPresentationForUser sorts upcoming matches within a competition by kickoff then total team score", () => {
  const nowMs = Date.now();
  const firstKickoff = formatLocalDateTimeParts(nowMs + 10 * 60 * 1000);
  const secondKickoff = formatLocalDateTimeParts(nowMs + 12 * 60 * 1000);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(),
    [
      {
        state: null,
        match: {
          match_details_id: "c05vqzv88jnt",
          date: secondKickoff.date,
          time: secondKickoff.time,
          league: "Premier League",
          home_team: "Liverpool",
          away_team: "Tottenham Hotspur",
          home_score: null,
          away_score: null,
          score_status: null,
          home_team_score: 1961,
          away_team_score: 1835,
          total_team_score: 3796,
          updated_at: new Date(nowMs).toISOString(),
        },
      },
      {
        state: null,
        match: {
          match_details_id: "cj6d3kd99ekt",
          date: firstKickoff.date,
          time: firstKickoff.time,
          league: "Premier League",
          home_team: "Crystal Palace",
          away_team: "Leeds United",
          home_score: null,
          away_score: null,
          score_status: null,
          home_team_score: 1682,
          away_team_score: 1642,
          total_team_score: 3324,
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "multi_upcoming");
  assert.equal(presentation.matches[0].match_details_id, "cj6d3kd99ekt");
  assert.equal(presentation.matches[1].match_details_id, "c05vqzv88jnt");
});

test("buildLiveActivityPresentationForUser orders upcoming matches by competition weight before later lower-weight kickoffs", () => {
  const nowMs = Date.now();
  const laLigaEarly = formatLocalDateTimeParts(nowMs + 2 * 60 * 60 * 1000);
  const laLigaMid = formatLocalDateTimeParts(nowMs + 3 * 60 * 60 * 1000);
  const leagueTwo = formatLocalDateTimeParts(nowMs + 4 * 60 * 60 * 1000);
  const laLigaLate = formatLocalDateTimeParts(nowMs + 4.5 * 60 * 60 * 1000);

  const presentation = __testHooks.buildLiveActivityPresentationForUser(
    liveActivityUser(),
    [
      {
        state: null,
        match: {
          match_details_id: "la-liga-early",
          date: laLigaEarly.date,
          time: laLigaEarly.time,
          league: "La Liga",
          home_team: "Levante",
          away_team: "Sevilla",
          home_score: null,
          away_score: null,
          score_status: null,
          updated_at: new Date(nowMs).toISOString(),
        },
      },
      {
        state: null,
        match: {
          match_details_id: "la-liga-mid",
          date: laLigaMid.date,
          time: laLigaMid.time,
          league: "La Liga",
          home_team: "Rayo Vallecano",
          away_team: "Espanyol",
          home_score: null,
          away_score: null,
          score_status: null,
          updated_at: new Date(nowMs).toISOString(),
        },
      },
      {
        state: null,
        match: {
          match_details_id: "league-two",
          date: leagueTwo.date,
          time: leagueTwo.time,
          league: "League Two",
          home_team: "Salford City",
          away_team: "Bromley",
          home_score: null,
          away_score: null,
          score_status: null,
          updated_at: new Date(nowMs).toISOString(),
        },
      },
      {
        state: null,
        match: {
          match_details_id: "la-liga-late",
          date: laLigaLate.date,
          time: laLigaLate.time,
          league: "La Liga",
          home_team: "Real Oviedo",
          away_team: "Villarreal",
          home_score: null,
          away_score: null,
          score_status: null,
          updated_at: new Date(nowMs).toISOString(),
        },
      },
    ],
    nowMs
  );

  assert.equal(presentation.mode, "multi_upcoming");
  assert.deepEqual(
    presentation.matches.map((match) => match.match_details_id),
    ["la-liga-early", "la-liga-mid", "la-liga-late", "league-two"]
  );
});

test("buildLiveActivityPresentationForUser orders mixed live and full-time matches by earliest kickoff first", () => {
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
    ["live-now", "finished-first"]
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

test("buildLiveActivityPresentationForUser caps live activity payloads to 6 matches", () => {
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
  assert.equal(presentation.matches.length, 6);
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

test("buildMatchEvents flags a goal-disallowed VAR entry as goalRelated", () => {
  const monitorState = newMonitorState();

  const oldMatch = {
    home_team: "Scotland",
    away_team: "Brazil",
    score_status: "22",
    home_score: 0,
    away_score: 0,
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_var_events: [],
    away_var_events: [],
  };

  const newMatch = {
    ...oldMatch,
    away_var_events: [{ player: "Vinícius Jr.", minute: "22'", detail: "VAR: Goal disallowed" }],
  };

  const events = __testHooks.buildMatchEvents(oldMatch, newMatch, monitorState, Date.now());
  const varEvent = events.find((event) => event.type === "var");

  assert.ok(varEvent, "expected a var event to be emitted");
  assert.equal(varEvent.goalRelated, true);
  assert.equal(varEvent.detail, "VAR: Goal disallowed");
});

test("buildMatchEvents does not flag a non-goal VAR entry as goalRelated", () => {
  const monitorState = newMonitorState();

  const oldMatch = {
    home_team: "Scotland",
    away_team: "Brazil",
    score_status: "30",
    home_score: 0,
    away_score: 1,
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_var_events: [],
    away_var_events: [],
  };

  const newMatch = {
    ...oldMatch,
    away_var_events: [{ player: "Vinícius Jr.", minute: "30'", detail: "VAR: Offside Check" }],
  };

  const events = __testHooks.buildMatchEvents(oldMatch, newMatch, monitorState, Date.now());
  const varEvent = events.find((event) => event.type === "var");

  assert.ok(varEvent, "expected a var event to be emitted");
  assert.equal(varEvent.goalRelated, false);
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

test("backfilled goals use existing scorer timeline when current score regresses", () => {
  const monitorState = newMonitorState({
    unresolvedGoalCount: 3,
  });

  const observedHtScore = {
    home_team: "Germany",
    away_team: "Curaçao",
    score_status: "HT",
    home_score: 3,
    away_score: 1,
    home_goal_scorers: [
      {
        player: "Felix Nmecha",
        goal_times: ["6'"],
      },
    ],
    away_goal_scorers: [],
    home_assists: [
      {
        player: "Florian Wirtz",
        assist_times: ["6'"],
      },
    ],
    away_assists: [],
  };

  __testHooks.buildMatchEvents(
    { ...observedHtScore, home_score: 2, away_score: 1 },
    observedHtScore,
    monitorState,
    Date.now()
  );

  const staleScore = {
    ...observedHtScore,
    home_score: 2,
    away_score: 1,
  };

  const newMatch = {
    ...staleScore,
    home_score: 2,
    away_score: 1,
    home_goal_scorers: [
      ...staleScore.home_goal_scorers,
      {
        player: "Nico Schlotterbeck",
        goal_times: ["38'"],
      },
      {
        player: "Kai Havertz",
        goal_times: ["45'"],
      },
    ],
    away_goal_scorers: [
      {
        player: "Livano Comenencia",
        goal_times: ["21'"],
      },
    ],
    home_assists: [
      ...staleScore.home_assists,
      {
        player: "Nathaniel Brown",
        assist_times: ["38'"],
      },
    ],
  };

  const events = __testHooks
    .buildMatchEvents(staleScore, newMatch, monitorState, Date.now())
    .filter((event) => event.type === "goal");

  assert.equal(events.length, 3);
  assert.equal(events[0].body, "Germany 1 - 1 Curaçao (Livano Comenencia)");
  assert.equal(events[1].body, "Germany 2 - 1 Curaçao (Nico Schlotterbeck, assist: Nathaniel Brown)");
  assert.equal(events[2].body, "Germany 3 - 1 Curaçao (Kai Havertz)");
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

test("derives second-leg aggregate in goal notification body when explicit aggregate is stale", () => {
  const monitorState = newMonitorState();

  const oldMatch = {
    home_team: "Aston Villa",
    away_team: "Bologna",
    score_status: "10'",
    home_score: 0,
    away_score: 0,
    aggregate_home_score: 3,
    aggregate_away_score: 1,
    first_leg_home_score: 3,
    first_leg_away_score: 1,
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
  };

  const newMatch = {
    ...oldMatch,
    score_status: "16'",
    home_score: 1,
    away_score: 0,
    home_goal_scorers: [{ player: "O. Watkins", goal_times: ["16'"] }],
  };

  const goals = __testHooks
    .buildMatchEvents(oldMatch, newMatch, monitorState, Date.now())
    .filter((event) => event.type === "goal");

  assert.equal(goals.length, 1);
  assert.equal(goals[0].body, "Aston Villa 1 - 0 Bologna (agg: 4-1) (O. Watkins)");
});

test("includes explicit aggregate 0-0 in score update notifications", () => {
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
  assert.equal(event.body, "Wolves 2 - 0 Aston Villa (agg: 0-0) (87')");
});

test("includes explicit aggregate 0-0 in full-time notifications", () => {
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
  assert.equal(events[0].body, "Burnley 0 - 0 AFC Bournemouth (agg: 0-0)");
});

test("includes penalty result in AET full-time notifications", () => {
  const monitorState = newMonitorState();

  const oldMatch = {
    home_team: "Midtjylland",
    away_team: "Nottingham Forest",
    score_status: "119'",
    home_score: 1,
    away_score: 2,
    home_goal_scorers: [],
    away_goal_scorers: [],
    aggregate_home_score: 2,
    aggregate_away_score: 2,
  };

  const newMatch = {
    ...oldMatch,
    score_status: "AET",
    penalty_result: "Nottingham Forest win 3 - 0 on penalties",
  };

  const events = __testHooks.buildMatchEvents(oldMatch, newMatch, monitorState, Date.now());
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "fulltime");
  assert.equal(events[0].title, "FT");
  assert.equal(
    events[0].body,
    "Nottingham Forest beat Midtjylland 3-0 on penalties (1-2 AET)"
  );
});

test("does not duplicate penalty wording in penalty-shootout full-time notifications", () => {
  const monitorState = newMonitorState();

  const oldMatch = {
    home_team: "West Ham United",
    away_team: "Brentford",
    score_status: "AET",
    home_score: 2,
    away_score: 2,
    home_goal_scorers: [],
    away_goal_scorers: [],
  };

  const newMatch = {
    ...oldMatch,
    score_status: "PENS",
    penalty_result: "West Ham United win 5 - 3 on penalties",
  };

  const events = __testHooks.buildMatchEvents(oldMatch, newMatch, monitorState, Date.now());
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "fulltime");
  assert.equal(events[0].title, "FT");
  assert.equal(
    events[0].body,
    "West Ham United beat Brentford 5-3 on penalties (2-2 AET)"
  );
});

test("formats away shootout winner final notification with AET score", () => {
  const monitorState = newMonitorState();

  const oldMatch = {
    home_team: "Germany",
    away_team: "Paraguay",
    score_status: "121'",
    home_score: 1,
    away_score: 1,
    home_goal_scorers: [],
    away_goal_scorers: [],
  };

  const newMatch = {
    ...oldMatch,
    score_status: "AET",
    penalty_result: "Paraguay win 4 - 3 on penalties",
  };

  const events = __testHooks.buildMatchEvents(oldMatch, newMatch, monitorState, Date.now());
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "fulltime");
  assert.equal(events[0].title, "FT");
  assert.equal(events[0].body, "Paraguay beat Germany 4-3 on penalties (1-1 AET)");
});

test("keeps unresolved penalty shootouts relevant until the result is confirmed", () => {
  assert.equal(
    __testHooks.isMatchRelevant({
      date: "2026-04-05",
      time: "18:30",
      home_team: "West Ham United",
      away_team: "Leeds United",
      score_status: "PENS",
      home_score: 3,
      away_score: 2,
    }),
    true
  );

  assert.equal(
    __testHooks.isMatchRelevant({
      date: "2026-04-05",
      time: "18:30",
      home_team: "West Ham United",
      away_team: "Leeds United",
      score_status: "PENS",
      home_score: 2,
      away_score: 2,
      penalty_result: "Leeds United win 4 - 2 on penalties",
    }),
    false
  );
});

test("does not emit full-time for penalty shootouts until the result is confirmed", () => {
  const monitorState = newMonitorState();

  const oldMatch = {
    home_team: "West Ham United",
    away_team: "Leeds United",
    score_status: "AET",
    home_score: 2,
    away_score: 2,
    home_goal_scorers: [],
    away_goal_scorers: [],
  };

  const newMatch = {
    ...oldMatch,
    score_status: "PENS",
    home_score: 3,
    away_score: 2,
  };

  const events = __testHooks.buildMatchEvents(oldMatch, newMatch, monitorState, Date.now());
  assert.deepStrictEqual(events, []);
});

test("keeps tied AET unresolved until penalty result is confirmed", () => {
  const monitorState = newMonitorState();

  const oldMatch = {
    home_team: "Germany",
    away_team: "Paraguay",
    score_status: "119'",
    home_score: 1,
    away_score: 1,
    home_goal_scorers: [],
    away_goal_scorers: [],
  };

  const newMatch = {
    ...oldMatch,
    score_status: "AET",
  };

  assert.equal(__testHooks.isUnresolvedTiedAetMatch(newMatch), true);
  const events = __testHooks.buildMatchEvents(oldMatch, newMatch, monitorState, Date.now());
  assert.deepStrictEqual(events, []);
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

test("buildScoreChangeEvent derives second-leg aggregate when explicit aggregate is stale", () => {
  const oldMatch = {
    home_team: "Aston Villa",
    away_team: "Bologna",
    home_score: 0,
    away_score: 0,
    score_status: "10'",
    aggregate_home_score: 3,
    aggregate_away_score: 1,
    first_leg_home_score: 3,
    first_leg_away_score: 1,
    home_goal_scorers: [],
    away_goal_scorers: [],
  };

  const newMatch = {
    ...oldMatch,
    home_score: 1,
    away_score: 0,
    score_status: "16'",
  };

  const event = __testHooks.buildScoreChangeEvent(oldMatch, newMatch);
  assert.ok(event);
  assert.equal(event.body, "Aston Villa 1 - 0 Bologna (agg: 4-1) (16')");
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

test("shows correct scoreline when score jumps 2 but only 1 timeline goal arrives first", () => {
  // Regression: score jumped 0→2 but only one timeline goal was available.
  // First notification must show 1-0, not 2-0.
  const monitorState = newMonitorState();
  const snap0 = {
    home_team: "Portugal",
    away_team: "DR Congo",
    score_status: "5'",
    home_score: 0,
    away_score: 0,
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
  };

  // Score jumps to 2-0 but timeline only has one goal (João Neves, 6')
  const snap1 = {
    ...snap0,
    score_status: "8'",
    home_score: 2,
    away_score: 0,
    home_goal_scorers: [{ player: "João Neves", goal_times: ["6'"] }],
  };

  const poll1Goals = __testHooks
    .buildMatchEvents(snap0, snap1, monitorState, Date.now())
    .filter((event) => event.type === "goal");
  assert.equal(poll1Goals.length, 1);
  assert.equal(poll1Goals[0].title, "Goal 6'");
  assert.equal(poll1Goals[0].body, "Portugal 1 - 0 DR Congo (João Neves)");

  // Next poll: score unchanged but second goal arrives in timeline
  const snap2 = {
    ...snap1,
    score_status: "12'",
    home_goal_scorers: [
      { player: "João Neves", goal_times: ["6'"] },
      { player: "R. Leão", goal_times: ["9'"] },
    ],
  };

  const poll2Goals = __testHooks
    .buildMatchEvents(snap1, snap2, monitorState, Date.now())
    .filter((event) => event.type === "goal");
  assert.equal(poll2Goals.length, 1);
  assert.equal(poll2Goals[0].title, "Goal 9'");
  assert.equal(poll2Goals[0].body, "Portugal 2 - 0 DR Congo (R. Leão)");
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

test("evaluateUserNotificationDecision allows a goal-related VAR decision under the goal preference", () => {
  const decision = __testHooks.evaluateUserNotificationDecision(
    {
      apnsToken: "apns-token",
      preferences: {
        notificationsEnabled: true,
        notificationDelayMinutes: 0,
        notificationEventTypes: ["goal"],
      },
    },
    {
      home_team: "Scotland",
      away_team: "Brazil",
      league: "FIFA World Cup 2026",
      tv_channels: [],
    },
    {
      type: "var",
      goalRelated: true,
      detail: "VAR: Goal disallowed",
    }
  );

  assert.equal(decision.shouldNotify, true);
  assert.equal(decision.reason, "eligible");
});

test("evaluateUserNotificationDecision filters out a non-goal VAR decision without the var preference", () => {
  const decision = __testHooks.evaluateUserNotificationDecision(
    {
      apnsToken: "apns-token",
      preferences: {
        notificationsEnabled: true,
        notificationDelayMinutes: 0,
        notificationEventTypes: ["goal"],
      },
    },
    {
      home_team: "Scotland",
      away_team: "Brazil",
      league: "FIFA World Cup 2026",
      tv_channels: [],
    },
    {
      type: "var",
      goalRelated: false,
      detail: "VAR: Offside Check",
    }
  );

  assert.equal(decision.shouldNotify, false);
  assert.equal(decision.reason, "event_type_filtered_out");
});

test("evaluateFantasyDeadlineReminderDecision requires a connected fantasy team", () => {
  const decision = __testHooks.evaluateFantasyDeadlineReminderDecision(
    {
      apnsToken: "apns-token",
      deviceToken: "device-token",
      preferences: {
        notificationsEnabled: true,
        fantasyDeadlineRemindersEnabled: true,
      },
      fantasy: null,
    },
    {
      id: 31,
      name: "Gameweek 31",
      deadline_time: "2026-03-21T11:00:00Z",
    },
    Date.parse("2026-03-20T10:59:00Z")
  );

  assert.deepStrictEqual(decision, {
    shouldSchedule: false,
    reason: "missing_fantasy_team",
  });
});

test("formatFantasyDeadlineReminderTime uses synced timezone and tomorrow wording", () => {
  const formatted = __testHooks.formatFantasyDeadlineReminderTime(
    Date.parse("2026-03-20T18:30:00Z"),
    {
      preferences: {
        deviceLocale: "en-GB",
        deviceTimeZone: "Europe/London",
      },
    },
    Date.parse("2026-03-19T18:29:00Z")
  );

  assert.equal(formatted, "18:30 tomorrow");
});

test("buildFantasyDeadlineReminderBodyFromRecord uses actual send day wording", () => {
  const body = __testHooks.buildFantasyDeadlineReminderBodyFromRecord(
    {
      body: "Reminder: Fantasy Football deadline due soon (18:30 tomorrow)",
      deadline_time_ms: Date.parse("2026-03-20T18:30:00Z"),
      device_time_zone: "Europe/London",
      device_locale: "en-GB",
    },
    Date.parse("2026-03-20T15:32:00Z")
  );

  assert.equal(body, "Reminder: Fantasy Football deadline due soon (18:30 today)");
});

test("dedupePushNotificationUsers collapses duplicate APNS targets to the freshest record", () => {
  const deduped = __testHooks.dedupePushNotificationUsers([
    {
      deviceToken: "older-device",
      apnsToken: "shared-apns-token",
      updatedAt: "2026-03-19T10:00:00.000Z",
      preferences: {
        notificationsEnabled: true,
      },
    },
    {
      deviceToken: "newer-device",
      apnsToken: "shared-apns-token",
      updatedAt: "2026-03-19T10:05:00.000Z",
      preferences: {
        notificationsEnabled: false,
      },
    },
  ]);

  assert.equal(deduped.length, 1);
  assert.equal(deduped[0].deviceToken, "newer-device");
  assert.equal(deduped[0].preferences.notificationsEnabled, false);
});

test("dedupeFantasyDeadlineReminderUsers collapses duplicate APNS targets to the freshest record", () => {
  const deduped = __testHooks.dedupeFantasyDeadlineReminderUsers(
    [
      {
        deviceToken: "older-device",
        apnsToken: "shared-apns-token",
        updatedAt: "2026-03-19T10:00:00.000Z",
        preferences: {
          notificationsEnabled: true,
          fantasyDeadlineRemindersEnabled: true,
        },
        fantasy: {
          managerEntryID: 123,
        },
      },
      {
        deviceToken: "newer-device",
        apnsToken: "shared-apns-token",
        updatedAt: "2026-03-19T10:05:00.000Z",
        preferences: {
          notificationsEnabled: true,
          fantasyDeadlineRemindersEnabled: true,
          deviceTimeZone: "Europe/London",
          deviceLocale: "en-GB",
        },
        fantasy: {
          managerEntryID: 456,
        },
      },
    ],
    {
      id: 31,
      name: "Gameweek 31",
      deadline_time: "2026-03-21T18:30:00Z",
    },
    Date.parse("2026-03-20T18:29:00Z")
  );

  assert.equal(deduped.length, 1);
  assert.equal(deduped[0].user.deviceToken, "newer-device");
  assert.equal(deduped[0].record.dedupe_basis, "apns_token");
});
