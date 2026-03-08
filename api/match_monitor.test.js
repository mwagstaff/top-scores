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

test("shouldSkipLiveActivityUpdate bypasses payload dedupe when forceDispatch is enabled", () => {
  const state = {
    lastPayloadHash: "abc123",
    lastMode: "multi_live",
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

test("compareLiveActivityMatches sorts higher total team score first", () => {
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
    league: "Premier League",
    home_team: "Norwich City",
    away_team: "Sheffield Wednesday",
    home_team_score: 1442,
    away_team_score: 1413,
    total_team_score: 2855,
    date: "2026-03-06",
    time: "19:45",
  };

  const sorted = [lowScoreMatch, highScoreMatch].sort(__testHooks.compareLiveActivityMatches);
  assert.equal(sorted[0].match_details_id, "high");
});

test("buildLiveActivityPresentationForUser keeps live matches ahead of full-time matches", () => {
  const nowMs = Date.now();
  const liveKickoff = formatLocalDateTimeParts(nowMs - 55 * 60 * 1000);
  const finishedKickoff = formatLocalDateTimeParts(nowMs - 3 * 60 * 60 * 1000);

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

test("compareLiveActivityMatches prioritizes premier league involvement buckets", () => {
  const bothPremierLeague = {
    match_details_id: "both-epl",
    league: "UEFA Champions League",
    home_team: "Liverpool",
    away_team: "Chelsea",
    home_team_score: 1500,
    away_team_score: 1500,
    total_team_score: 3000,
    score_status: "45",
    date: "2026-03-06",
    time: "20:00",
  };
  const onePremierLeague = {
    match_details_id: "one-epl",
    league: "UEFA Champions League",
    home_team: "Liverpool",
    away_team: "Real Madrid",
    home_team_score: 1900,
    away_team_score: 1900,
    total_team_score: 3800,
    score_status: "45",
    date: "2026-03-06",
    time: "20:00",
  };
  const noPremierLeague = {
    match_details_id: "no-epl",
    league: "UEFA Champions League",
    home_team: "Real Madrid",
    away_team: "Barcelona",
    home_team_score: 2000,
    away_team_score: 2000,
    total_team_score: 4000,
    score_status: "45",
    date: "2026-03-06",
    time: "20:00",
  };

  const sorted = [noPremierLeague, onePremierLeague, bothPremierLeague].sort(
    __testHooks.compareLiveActivityMatches
  );

  assert.deepEqual(
    sorted.map((match) => match.match_details_id),
    ["both-epl", "one-epl", "no-epl"]
  );
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

test("suppresses aggregate 0-0 in notifications when live score is non-zero", () => {
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
