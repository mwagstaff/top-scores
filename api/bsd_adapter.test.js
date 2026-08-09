"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");

const { bsdEventToCanonicalMatch, __private } = require("./bsd_adapter");
const {
  mapBsdStatus,
  parseBsdIncidents,
  buildBsdTeamLineups,
  isPlaceholderTeam,
  bsdMinute,
  bsdBroadcastChannels,
  isCurrentSeasonEvent,
  enrichBsdLineupPhotos,
  parseBsdFormString,
  bsdStandingsPayloadToTable,
  bsdPredictionFixtureToCanonical,
  bsdPredictionsPayloadToLeague,
  extractBsdPeriodSummary,
  buildCurrentBsdEventsFilter,
  currentSeasonByLeagueFromDocs,
} = __private;

test("current-season Mongo filter scopes BSD events before payloads are loaded", () => {
  const seasons = currentSeasonByLeagueFromDocs([
    { _id: "27", payload: { id: 27, current_season: { id: 2026 } } },
  ]);
  const filter = buildCurrentBsdEventsFilter(seasons);
  const serialized = JSON.stringify(filter);
  assert.match(serialized, /payload\.season_id/);
  assert.match(serialized, /2026/);
  assert.match(serialized, /finished/);
  assert.match(serialized, /league_id/);
});

const HELPER_DIR = path.resolve(__dirname, "../.helper_files/bsd_api");
function loadHelper(name) {
  return JSON.parse(fs.readFileSync(path.join(HELPER_DIR, name), "utf8"));
}

// ---------------------------------------------------------------------------
// Status mapping
// ---------------------------------------------------------------------------

test("mapBsdStatus: notstarted → null", () => {
  assert.equal(mapBsdStatus({ status: "notstarted" }), null);
  assert.equal(mapBsdStatus({ status: "" }), null);
});

test("mapBsdStatus: finished → FT, with pens/ET escalation", () => {
  assert.equal(mapBsdStatus({ status: "finished", period: "FT" }), "FT");
  assert.equal(mapBsdStatus({ status: "finished", penalty_shootout: { home: 4, away: 3 } }), "AET");
  assert.equal(mapBsdStatus({ status: "finished", extra_time_score: "1-1" }), "AET");
});

test("mapBsdStatus: in-progress → minute / HT / LIVE", () => {
  assert.equal(mapBsdStatus({ status: "inprogress", period: "2nd_half", current_minute: 64 }), "64");
  assert.equal(mapBsdStatus({ status: "inprogress", period: "halftime" }), "HT");
  assert.equal(mapBsdStatus({ status: "halftime" }), "HT");
  assert.equal(mapBsdStatus({ status: "inprogress", current_minute: null }), "LIVE");
});

test("mapBsdStatus: future scoreless started event remains upcoming", () => {
  assert.equal(
    mapBsdStatus({
      status: "started",
      period: "",
      current_minute: null,
      home_score: null,
      away_score: null,
      event_date: "2999-07-01T01:00:00Z",
    }),
    null
  );
});

test("mapBsdStatus: postponed/abandoned → POSTPONED", () => {
  assert.equal(mapBsdStatus({ status: "postponed" }), "POSTPONED");
  assert.equal(mapBsdStatus({ status: "abandoned" }), "POSTPONED");
});

// ---------------------------------------------------------------------------
// Minute formatting
// ---------------------------------------------------------------------------

test("bsdMinute formats base and added time, drops 0/empty", () => {
  assert.equal(bsdMinute(45, null), "45'");
  assert.equal(bsdMinute(45, 6), "45+6'");
  assert.equal(bsdMinute(0, null), null);
  assert.equal(bsdMinute(null, null), null);
});

// ---------------------------------------------------------------------------
// Placeholder detection
// ---------------------------------------------------------------------------

test("isPlaceholderTeam flags knockout slots, keeps real teams", () => {
  ["W101", "L33", "1A", "2B", "H2", "G1", "3D/3E/3I", ""].forEach((n) =>
    assert.equal(isPlaceholderTeam(n), true, `${n} should be placeholder`)
  );
  ["USA", "Uruguay", "Cabo Verde", "Bosnia & Herzegovina", "Türkiye"].forEach((n) =>
    assert.equal(isPlaceholderTeam(n), false, `${n} should be real`)
  );
});

// ---------------------------------------------------------------------------
// Incidents → scorers / cards / assists / VAR (CLAUDE.md example shapes)
// ---------------------------------------------------------------------------

test("parseBsdIncidents: goal with assist, cards, VAR", () => {
  const incidents = [
    { type: "goal", assist: "M. Araújo", minute: 45, player: "A. Canobbio", is_home: true, goal_type: "regular", added_time: 6 },
    { type: "goal", minute: 70, player: "X. Own", is_home: true, goal_type: "own_goal" },
    { type: "card", minute: 33, player: "S. Ezatolahi", is_home: false, card_type: "yellow" },
    { type: "card", minute: 67, player: "N. Ngoy", is_home: true, card_type: "red" },
    { type: "varDecision", minute: 25, player: "M. Taremi", is_home: false, decision: "goalAwarded", confirmed: false },
  ];
  const r = parseBsdIncidents(incidents);
  assert.deepEqual(r.home_goal_scorers, [{ player: "A. Canobbio", goal_times: ["45+6'"] }]);
  assert.deepEqual(r.home_assists, [{ player: "M. Araújo", assist_times: ["45+6'"] }]);
  // Own goal by home player is credited to the away side's own_goal_times.
  assert.deepEqual(r.away_goal_scorers, [{ player: "X. Own", own_goal_times: ["70'"] }]);
  assert.deepEqual(r.away_yellow_cards, [{ player: "S. Ezatolahi", yellow_card_times: ["33'"] }]);
  assert.deepEqual(r.home_red_cards, [{ player: "N. Ngoy", red_card_times: ["67'"] }]);
  assert.equal(r.away_var_events.length, 1);
  // confirmed:false means the goal-award decision did NOT stand — disallowed.
  assert.equal(r.away_var_events[0].detail, "VAR: Goal disallowed");
});

test("parseBsdIncidents: preserves manager card names outside the match timeline", () => {
  const incidents = [
    { type: "card", minute: -5, player: "J. Nagelsmann", is_home: true, card_type: "yellow", player_id: null, is_manager: true },
    { type: "card", minute: -5, player: "G. Alfaro", is_home: false, card_type: "yellow", player_id: null, is_manager: true },
  ];

  const r = parseBsdIncidents(incidents);

  assert.deepEqual(r.home_yellow_cards, [{ player: "J. Nagelsmann", yellow_card_times: ["-5'"] }]);
  assert.deepEqual(r.away_yellow_cards, [{ player: "G. Alfaro", yellow_card_times: ["-5'"] }]);
});

test("isDisallowedGoalVarDecision: true only for a goal decision that did not stand", () => {
  const { isDisallowedGoalVarDecision } = __private;
  assert.equal(isDisallowedGoalVarDecision("goalAwarded", false), true);
  // Confirmed goal award, non-goal reviews, and missing/ambiguous confirmed
  // state are all noise — never surfaced.
  assert.equal(isDisallowedGoalVarDecision("goalAwarded", true), false);
  assert.equal(isDisallowedGoalVarDecision("penaltyAwarded", false), false);
  assert.equal(isDisallowedGoalVarDecision("redCard", false), false);
  assert.equal(isDisallowedGoalVarDecision("offsideCheck", false), false);
  assert.equal(isDisallowedGoalVarDecision("goalAwarded", undefined), false);
  assert.equal(isDisallowedGoalVarDecision("", false), false);
});

test("parseBsdIncidents: drops confirmed goal-award and non-goal VAR decisions entirely", () => {
  const incidents = [
    // Goal-award decision that stood on review — not noteworthy, no event.
    { type: "varDecision", minute: 12, player: "A", is_home: true, decision: "goalAwarded", confirmed: true },
    // Non-goal review — not what the user wants to see/be notified about.
    { type: "varDecision", minute: 30, player: "B", is_home: false, decision: "redCard", confirmed: false },
    { type: "varDecision", minute: 55, player: "C", is_home: true, decision: "offsideCheck", confirmed: false },
  ];
  const r = parseBsdIncidents(incidents);
  assert.deepEqual(r.home_var_events, []);
  assert.deepEqual(r.away_var_events, []);
});

test("parseBsdIncidents: real helper fixture parses without throwing", () => {
  const doc = loadHelper("events_id_incidents.json");
  const r = parseBsdIncidents(doc.incidents);
  // Belgium v Iran fixture: a red card and a yellow card are present.
  assert.ok(r.home_red_cards.length + r.away_red_cards.length >= 1);
  assert.ok(r.home_yellow_cards.length + r.away_yellow_cards.length >= 1);
});

test("extractBsdPeriodSummary: reads final AET and penalty scores from period incidents", () => {
  const summary = extractBsdPeriodSummary([
    { text: "PEN", type: "period", minute: 999, is_live: false, away_score: 4, home_score: 3 },
    { text: "ET", type: "period", minute: 120, is_live: false, away_score: 1, home_score: 1 },
    { text: "FT", type: "period", minute: 90, is_live: false, away_score: 1, home_score: 1 },
  ]);
  assert.deepEqual(summary.penaltyShootout, { home: 3, away: 4 });
  assert.deepEqual(summary.extraTimeScore, { home: 1, away: 1 });
  assert.deepEqual(summary.fullTimeScore, { home: 1, away: 1 });
});

// ---------------------------------------------------------------------------
// Lineups (real helper fixture)
// ---------------------------------------------------------------------------

test("buildBsdTeamLineups: maps formation, starters, subs, grid positions", () => {
  const doc = loadHelper("events_id_lineups.json");
  const incidents = loadHelper("events_id_incidents.json").incidents;
  const lineups = buildBsdTeamLineups(doc, incidents);
  assert.ok(lineups.home, "home lineup present");
  assert.equal(typeof lineups.home.formation, "string");
  assert.ok(lineups.home.starting_lineup.length >= 11);
  const gk = lineups.home.starting_lineup.find((p) => p.position_category === "goalkeeper");
  assert.ok(gk, "goalkeeper category mapped");
  // assignFormationGridPositions attaches grid metadata.
  assert.ok(Number.isInteger(lineups.home.starting_lineup[0].formation_row_index));
  assert.ok(Array.isArray(lineups.home.substitutions));
});

// ---------------------------------------------------------------------------
// Event → canonical match (identity gate)
// ---------------------------------------------------------------------------

test("bsdEventToCanonicalMatch: canonicalises names, league, zoned date, status", () => {
  const event = {
    id: 8325,
    league_id: 27,
    league_name: "World Cup 2026",
    home_team: "Cabo Verde",
    away_team: "Uruguay",
    home_team_id: 476,
    away_team_id: 480,
    home_score: 1,
    away_score: 2,
    status: "finished",
    period: "FT",
    event_date: "2026-06-21T19:00:00Z",
  };
  const m = bsdEventToCanonicalMatch(event);
  assert.equal(m.home_team, "Cape Verde"); // alias-normalised to TSDB spelling
  assert.equal(m.away_team, "Uruguay");
  assert.equal(m.league, "FIFA World Cup 2026"); // matches what TSDB emits
  assert.equal(m.score_status, "FT");
  assert.equal(m.home_score, 1);
  assert.equal(m.away_score, 2);
  assert.equal(m.match_details_id, "8325");
  assert.equal(m.has_bsd_source, true);
  // 19:00Z in June → 20:00 Europe/London (BST), so the composite id matches TSDB.
  assert.equal(m.date, "2026-06-21");
  assert.equal(m.time, "20:00");
  const compositeId = `${m.date}|${m.time}|${m.league}|${m.home_team}|${m.away_team}`;
  assert.equal(compositeId, "2026-06-21|20:00|FIFA World Cup 2026|Cape Verde|Uruguay");
});

test("bsdEventToCanonicalMatch: surfaces BSD last_updated as updated_at", () => {
  // The Live Activity stale-live heuristic needs updated_at to keep a match
  // that's genuinely still in progress past kickoff+2h (extra time, heavy
  // stoppage) on the widget.
  const base = {
    id: 8375,
    league_id: 27,
    home_team: "Canada",
    away_team: "Morocco",
    home_score: 0,
    away_score: 3,
    status: "inprogress",
    period: "2nd_half",
    current_minute: 98,
    event_date: "2026-07-04T17:00:00Z",
  };
  const withTimestamp = bsdEventToCanonicalMatch({
    ...base,
    last_updated: "2026-07-04T19:04:25Z",
  });
  assert.equal(withTimestamp.updated_at, "2026-07-04T19:04:25Z");

  const withoutTimestamp = bsdEventToCanonicalMatch(base);
  assert.equal(withoutTimestamp.updated_at, null);
});

test("bsdEventToCanonicalMatch: surfaces round_name as league_subcategory", () => {
  const event = {
    id: 8359,
    league_id: 27,
    league_name: "World Cup 2026",
    home_team: "South Africa",
    away_team: "Canada",
    status: "notstarted",
    event_date: "2026-06-28T19:00:00Z",
    round_name: "Round of 32",
  };
  const m = bsdEventToCanonicalMatch(event);
  // league stays bare — normalizeMatchRecord() strips "League: <stage>" suffixes
  // on the server, so the stage must travel as its own field (matching the
  // TSDB/BBC pipeline's league_subcategory convention) rather than embedded text.
  assert.equal(m.league, "FIFA World Cup 2026");
  assert.equal(m.league_subcategory, "Round of 32");
});

test("bsdEventToCanonicalMatch: undetermined knockout slots surface as TBC rather than being dropped", () => {
  const m = bsdEventToCanonicalMatch({
    id: 8390,
    league_id: 27,
    home_team: "W101",
    away_team: "W102",
    status: "notstarted",
    round_name: "Final",
    event_date: "2026-07-19T19:00:00Z",
  });
  assert.ok(m);
  assert.equal(m.home_team, "TBC");
  assert.equal(m.away_team, "TBC");
  assert.equal(m.league_subcategory, "Final");
});

test("bsdEventToCanonicalMatch: detail includes scorers + lineups", () => {
  const event = {
    id: 8317, league_id: 27, home_team: "Scotland", away_team: "Morocco",
    home_score: 0, away_score: 1, status: "finished", event_date: "2026-06-19T19:00:00Z",
  };
  const m = bsdEventToCanonicalMatch(event, {
    detail: true,
    incidentsPayload: loadHelper("events_id_incidents.json"),
    lineupsPayload: loadHelper("events_id_lineups.json"),
  });
  assert.ok(m.team_lineups, "team_lineups attached in detail mode");
  assert.ok(Array.isArray(m.home_goal_scorers));
});

test("bsdEventToCanonicalMatch: penalty_shootout maps to penalty_result", () => {
  const event = {
    id: 206718, league_id: 7, home_team: "Paris Saint-Germain", away_team: "Arsenal",
    home_score: 1, away_score: 1, status: "finished", event_date: "2026-05-30T16:00:00Z",
    penalty_shootout: { home: 4, away: 3 },
  };
  const m = bsdEventToCanonicalMatch(event);
  assert.equal(m.score_status, "AET");
  assert.equal(m.penalty_result, "Paris Saint-Germain win 4 - 3 on penalties");
});

test("bsdEventToCanonicalMatch: final penalty period incident keeps AET score and winner", () => {
  const event = {
    id: 8361, league_id: 27, home_team: "Germany", away_team: "Paraguay",
    home_score: 3, away_score: 4, status: "started", current_minute: 121,
    event_date: "2026-06-29T19:00:00Z",
  };
  const m = bsdEventToCanonicalMatch(event, {
    incidentsPayload: {
      event_id: 8361,
      incidents: [
        { text: "PEN", type: "period", minute: 999, is_live: false, away_score: 4, home_score: 3 },
        { text: "ET", type: "period", minute: 120, is_live: false, away_score: 1, home_score: 1 },
      ],
    },
  });
  assert.equal(m.score_status, "AET");
  assert.equal(m.home_score, 1);
  assert.equal(m.away_score, 1);
  assert.equal(m.penalty_result, "Paraguay win 4 - 3 on penalties");
});

test("bsdEventToCanonicalMatch: no penalty_shootout → penalty_result is null", () => {
  const event = {
    id: 1, league_id: 1, home_team: "Arsenal", away_team: "Chelsea",
    home_score: 2, away_score: 1, status: "finished", event_date: "2026-05-30T16:00:00Z",
  };
  const m = bsdEventToCanonicalMatch(event);
  assert.equal(m.penalty_result, null);
});

test("bsdEventToCanonicalMatch: extra time goals are added to the regular-time score (no shootout)", () => {
  // Match 8373: Argentina 1-1 Cabo Verde after 90, then 2-1 in extra time → 3-2 final.
  const event = {
    id: 8373, league_id: 27, home_team: "Argentina", away_team: "Cabo Verde",
    home_score: 1, away_score: 1, status: "finished", period: "extra_time",
    event_date: "2026-07-03T22:00:00Z",
    extra_time_score: { home: 2, away: 1 },
  };
  const m = bsdEventToCanonicalMatch(event);
  assert.equal(m.home_score, 3);
  assert.equal(m.away_score, 2);
  assert.equal(m.score_status, "AET");
});

// ---------------------------------------------------------------------------
// TV broadcasts join
// ---------------------------------------------------------------------------

test("bsdBroadcastChannels: maps to structured GB TvChannel objects, dedupes", () => {
  const channels = bsdBroadcastChannels({
    event_id: "363",
    channels: [
      { channel_name: "NOW TV UK" },
      { channel_name: "Sky Sports Premier League" },
      { channel_name: "sky sports premier league" }, // dup (case-insensitive)
      { channel_name: "" }, // dropped
    ],
  });
  assert.deepEqual(channels, [
    { name: "NOW TV UK", country: "United Kingdom", countryCode: "GB", logo: null },
    { name: "Sky Sports Premier League", country: "United Kingdom", countryCode: "GB", logo: null },
  ]);
});

test("bsdBroadcastChannels: empty / missing payload → []", () => {
  assert.deepEqual(bsdBroadcastChannels(null), []);
  assert.deepEqual(bsdBroadcastChannels({}), []);
  assert.deepEqual(bsdBroadcastChannels({ channels: [] }), []);
});

test("bsdEventToCanonicalMatch: joins channels via channelsByEventId map", () => {
  const event = {
    id: 363, league_id: 1, league_name: "Premier League",
    home_team: "West Ham United", away_team: "Arsenal",
    status: "notstarted", event_date: "2026-05-10T15:30:00Z",
  };
  const channelsByEventId = new Map([
    ["363", [{ name: "NOW TV UK", country: "United Kingdom", countryCode: "GB", logo: null }]],
  ]);
  const m = bsdEventToCanonicalMatch(event, { channelsByEventId });
  assert.deepEqual(m.tv_channels, [
    { name: "NOW TV UK", country: "United Kingdom", countryCode: "GB", logo: null },
  ]);
});

test("bsdEventToCanonicalMatch: joins channels via broadcastsPayload (detail)", () => {
  const event = {
    id: 9835, league_id: 36, league_name: "Liga F",
    home_team: "Real Madrid", away_team: "Club Atlético de Madrid",
    status: "notstarted", event_date: "2026-05-10T15:00:00Z",
  };
  const m = bsdEventToCanonicalMatch(event, {
    broadcastsPayload: { event_id: "9835", channels: [{ channel_name: "DAZN UK" }] },
  });
  assert.equal(m.tv_channels.length, 1);
  assert.equal(m.tv_channels[0].name, "DAZN UK");
  assert.equal(m.tv_channels[0].countryCode, "GB");
});

test("bsdEventToCanonicalMatch: no broadcasts → tv_channels is []", () => {
  const event = {
    id: 7, league_id: 1, home_team: "Liverpool", away_team: "Everton",
    status: "notstarted", event_date: "2026-05-11T12:00:00Z",
  };
  assert.deepEqual(bsdEventToCanonicalMatch(event).tv_channels, []);
});

// ---------------------------------------------------------------------------
// Season filtering
// ---------------------------------------------------------------------------

test("isCurrentSeasonEvent: keeps current + live (no season), drops historical finished results", () => {
  const seasonByLeague = new Map([["27", 188]]);
  const finished = { league_id: 27, status: "finished" };
  assert.equal(isCurrentSeasonEvent({ ...finished, season_id: 188 }, seasonByLeague), true);
  assert.equal(isCurrentSeasonEvent({ ...finished, season_id: 189 }, seasonByLeague), false);
  assert.equal(isCurrentSeasonEvent({ ...finished, season_id: null }, seasonByLeague), true);
});

test("isCurrentSeasonEvent: never excludes non-finished events, even from a stale season_id", () => {
  // bsd_leagues' current_season lags the real fixture calendar around a
  // season turnover — next season's notstarted fixtures must still surface.
  const seasonByLeague = new Map([["1", 337]]);
  assert.equal(
    isCurrentSeasonEvent({ league_id: 1, season_id: 1058, status: "notstarted" }, seasonByLeague),
    true
  );
  assert.equal(
    isCurrentSeasonEvent({ league_id: 1, season_id: 1058, status: "inprogress" }, seasonByLeague),
    true
  );
});

// ---------------------------------------------------------------------------
// enrichBsdLineupPhotos
//
// Mongo is unconfigured in this test environment (no MONGODB_URI_TOP_SCORES),
// so getBsdRecords always returns []. These tests confirm the function
// degrades gracefully (no-op, never throws) rather than exercising the real
// id-swap/photo behaviour, which is validated against live production data
// (see project notes) since it requires a real bsd_tsdb_player_map.
// ---------------------------------------------------------------------------

test("enrichBsdLineupPhotos: no-op when match has no team_lineups", async () => {
  const match = { id: "1", home_team: "A", away_team: "B" };
  const result = await enrichBsdLineupPhotos(match);
  assert.equal(result, match);
});

test("enrichBsdLineupPhotos: returns match unchanged when the map is empty (no Mongo)", async () => {
  const match = {
    id: "1",
    team_lineups: {
      home: { starting_lineup: [{ id_player: "595", name: "Vinícius Jr.", cutout_url: null }], substitutes: [] },
      away: { starting_lineup: [], substitutes: [] },
    },
  };
  const result = await enrichBsdLineupPhotos(match);
  assert.equal(result.team_lineups.home.starting_lineup[0].id_player, "595");
  assert.equal(result.team_lineups.home.starting_lineup[0].cutout_url, null);
});

// ---------------------------------------------------------------------------
// Standings
// ---------------------------------------------------------------------------

test("parseBsdFormString: uppercases, filters to W/D/L, keeps last 5 newest-first", () => {
  assert.deepEqual(parseBsdFormString("WWWWL"), ["L", "W", "W", "W", "W"]);
  assert.deepEqual(parseBsdFormString("wdlwdlw"), ["W", "L", "D", "W", "L"]);
  assert.deepEqual(parseBsdFormString(""), []);
  assert.deepEqual(parseBsdFormString(null), []);
});

test("bsdStandingsPayloadToTable: flat (English Premier League) maps rows, league name from map", () => {
  const payload = loadHelper("leagues_id_standings_english_premier_league.json");
  const table = bsdStandingsPayloadToTable(payload, { leagueId: "1", updatedAt: "2026-06-01T00:00:00.000Z" });
  assert.equal(table.league_id, "1");
  assert.equal(table.league_name, "Premier League");
  assert.equal(table.season, "Premier League 25/26");
  assert.equal(table.updated_at, "2026-06-01T00:00:00.000Z");
  assert.equal(table.groups.length, 0);
  assert.equal(table.rows.length, 20);
  assert.equal(table.realtime, false);

  const top = table.rows[0];
  assert.equal(top.position, 1);
  assert.equal(top.team, "Arsenal");
  assert.equal(top.points, 85);
  assert.equal(top.goal_difference, 44);
  assert.deepEqual(top.form, ["W", "W", "W", "W", "W"]);
  // The clean baseline carries no live/realtime fields — those are added by the
  // in-progress overlay at serving time.
  assert.equal("live" in top, false);
  assert.equal("bsd_live" in top, false);
});

test("bsdStandingsPayloadToTable: grouped (World Cup) builds groups[] sorted A-L, no top-level rows", () => {
  const payload = loadHelper("leagues_id_standings_world_cup.json");
  const table = bsdStandingsPayloadToTable(payload, { leagueId: "27" });
  assert.equal(table.league_id, "27");
  assert.equal(table.league_name, "FIFA World Cup 2026");
  assert.equal(table.rows.length, 0);
  assert.ok(table.groups.length > 0);
  assert.deepEqual(
    table.groups.map((g) => g.name),
    [...table.groups.map((g) => g.name)].sort()
  );

  const groupA = table.groups.find((g) => g.name === "Group A");
  assert.ok(groupA);
  assert.equal(groupA.rows[0].team, "Mexico");
  assert.equal(groupA.rows[0].points, 9);
});

test("bsdStandingsPayloadToTable: falls back to leagueNameById, then the raw id, when unmapped", () => {
  const payload = { league_id: 99, season: { name: "Test League" }, grouped: false, standings: [] };
  const withMap = bsdStandingsPayloadToTable(payload, {
    leagueId: "99",
    leagueNameById: new Map([["99", "Some League"]]),
  });
  assert.equal(withMap.league_name, "Some League");

  const withoutMap = bsdStandingsPayloadToTable(payload, { leagueId: "99" });
  assert.equal(withoutMap.league_name, "99");
});

test("bsdStandingsPayloadToTable: returns null for missing/malformed payload", () => {
  assert.equal(bsdStandingsPayloadToTable(null, { leagueId: "1" }), null);
  assert.equal(bsdStandingsPayloadToTable({ league_id: 1, grouped: false }, { leagueId: "1" }), null);
});

// ---------------------------------------------------------------------------
// Predictions
// ---------------------------------------------------------------------------

test("bsdPredictionFixtureToCanonical: canonicalises names and zones the kickoff, drops recommendations/model", () => {
  const payload = loadHelper("predictions_world_cup.json");
  const item = payload.results.find((r) => r.event.id === 8354);
  const fixture = bsdPredictionFixtureToCanonical(item);

  assert.equal(fixture.event_id, "8354");
  assert.equal(fixture.home_team, "Panama");
  assert.equal(fixture.away_team, "England");
  assert.equal(fixture.date, "2026-06-27");
  assert.equal(fixture.time, "22:00");
  assert.deepEqual(fixture.markets, item.markets);
  assert.equal("recommendations" in fixture, false);
  assert.equal("model" in fixture, false);
});

test("bsdPredictionFixtureToCanonical: returns null without an event id", () => {
  assert.equal(bsdPredictionFixtureToCanonical({ markets: {} }), null);
  assert.equal(bsdPredictionFixtureToCanonical(null), null);
});

test("bsdPredictionsPayloadToLeague: maps fixtures, league name from BSD_LEAGUE_NAME_MAP", () => {
  const payload = loadHelper("predictions_world_cup.json").results;
  const league = bsdPredictionsPayloadToLeague(payload, {
    leagueId: "27",
    updatedAt: "2026-06-27T12:00:00.000Z",
  });

  assert.equal(league.league_id, "27");
  assert.equal(league.league_name, "FIFA World Cup 2026");
  assert.equal(league.updated_at, "2026-06-27T12:00:00.000Z");
  assert.equal(league.fixtures.length, payload.length);
  assert.ok(league.fixtures.every((f) => f.event_id && f.markets));
});

test("bsdPredictionsPayloadToLeague: falls back to leagueNameById, then the raw id, when unmapped", () => {
  const leagueNameById = new Map([["999", "Some Cup"]]);
  assert.equal(
    bsdPredictionsPayloadToLeague([], { leagueId: "999", leagueNameById }).league_name,
    "Some Cup"
  );
  assert.equal(
    bsdPredictionsPayloadToLeague([], { leagueId: "12345" }).league_name,
    "12345"
  );
});

test("bsdPredictionsPayloadToLeague: returns null for a non-array payload or missing leagueId", () => {
  assert.equal(bsdPredictionsPayloadToLeague(null, { leagueId: "27" }), null);
  assert.equal(bsdPredictionsPayloadToLeague([], {}), null);
});
