"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { __private } = require("./fetch_tsdb_matches");

const {
  mapTsdbStatus,
  parseTimelineEvents,
  parseLineups,
  computeAggregateFromSchedule,
  resolveLeagueName,
  stripSeconds,
} = __private;

// ---------------------------------------------------------------------------
// mapTsdbStatus
// ---------------------------------------------------------------------------

test("mapTsdbStatus: NS → null", () => {
  assert.equal(mapTsdbStatus("NS", null), null);
});

test("mapTsdbStatus: HT → HT", () => {
  assert.equal(mapTsdbStatus("HT", null), "HT");
});

test("mapTsdbStatus: FT → FT", () => {
  assert.equal(mapTsdbStatus("FT", null), "FT");
});

test("mapTsdbStatus: AET → AET", () => {
  assert.equal(mapTsdbStatus("AET", null), "AET");
});

test("mapTsdbStatus: PEN → Pens", () => {
  assert.equal(mapTsdbStatus("PEN", null), "Pens");
});

test("mapTsdbStatus: POSTPONED → POSTPONED", () => {
  assert.equal(mapTsdbStatus("POSTPONED", null), "POSTPONED");
});

test("mapTsdbStatus: CANCELLED → POSTPONED", () => {
  assert.equal(mapTsdbStatus("CANCELLED", null), "POSTPONED");
});

test("mapTsdbStatus: 1H with progress returns the minute", () => {
  assert.equal(mapTsdbStatus("1H", "23"), "23");
});

test("mapTsdbStatus: 2H with progress returns the minute", () => {
  assert.equal(mapTsdbStatus("2H", "67"), "67");
});

test("mapTsdbStatus: 2H with added-time progress", () => {
  assert.equal(mapTsdbStatus("2H", "45+2"), "45+2");
});

test("mapTsdbStatus: ET with progress returns the minute", () => {
  assert.equal(mapTsdbStatus("ET", "105"), "105");
});

test("mapTsdbStatus: 1H with no progress returns null", () => {
  assert.equal(mapTsdbStatus("1H", ""), null);
});

test("mapTsdbStatus: null input returns null", () => {
  assert.equal(mapTsdbStatus(null, null), null);
});

test("mapTsdbStatus: case-insensitive", () => {
  assert.equal(mapTsdbStatus("ft", null), "FT");
  assert.equal(mapTsdbStatus("ht", null), "HT");
});

// ---------------------------------------------------------------------------
// stripSeconds
// ---------------------------------------------------------------------------

test("stripSeconds: strips seconds from HH:MM:SS", () => {
  assert.equal(stripSeconds("22:00:00"), "22:00");
});

test("stripSeconds: already HH:MM returned as-is", () => {
  assert.equal(stripSeconds("22:00"), "22:00");
});

test("stripSeconds: null input returns null", () => {
  assert.equal(stripSeconds(null), null);
});

// ---------------------------------------------------------------------------
// resolveLeagueName
// ---------------------------------------------------------------------------

test("resolveLeagueName: English Premier League → Premier League", () => {
  assert.equal(resolveLeagueName("English Premier League"), "Premier League");
});

test("resolveLeagueName: English League Championship → Championship", () => {
  assert.equal(resolveLeagueName("English League Championship"), "Championship");
});

test("resolveLeagueName: unknown league returned as-is", () => {
  assert.equal(resolveLeagueName("Brazilian Serie B"), "Brazilian Serie B");
});

test("resolveLeagueName: null returns null", () => {
  assert.equal(resolveLeagueName(null), null);
});

// ---------------------------------------------------------------------------
// parseTimelineEvents — goals
// ---------------------------------------------------------------------------

function makeGoal(player, intTime, strHome, strTimelineDetail, assist) {
  return {
    strTimeline: "Goal",
    strTimelineDetail: strTimelineDetail || "Normal Goal",
    strPlayer: player,
    strAssist: assist || "",
    intTime: String(intTime),
    strHome,
    idTeam: null,
  };
}

test("parseTimelineEvents: home goal", () => {
  const timeline = [makeGoal("Salah", "23", "Yes")];
  const result = parseTimelineEvents(timeline, null, "FT");
  assert.equal(result.home_goal_scorers.length, 1);
  assert.equal(result.home_goal_scorers[0].player, "Salah");
  assert.deepEqual(result.home_goal_scorers[0].goal_times, ["23'"]);
  assert.equal(result.away_goal_scorers.length, 0);
});

test("parseTimelineEvents: away goal", () => {
  const timeline = [makeGoal("Haaland", "55", "No")];
  const result = parseTimelineEvents(timeline, null, "FT");
  assert.equal(result.away_goal_scorers.length, 1);
  assert.equal(result.away_goal_scorers[0].player, "Haaland");
  assert.deepEqual(result.away_goal_scorers[0].goal_times, ["55'"]);
});

test("parseTimelineEvents: multiple goals same player", () => {
  const timeline = [
    makeGoal("Kane", "10", "Yes"),
    makeGoal("Kane", "35", "Yes"),
  ];
  const result = parseTimelineEvents(timeline, null, "FT");
  assert.equal(result.home_goal_scorers.length, 1);
  assert.deepEqual(result.home_goal_scorers[0].goal_times, ["10'", "35'"]);
});

test("parseTimelineEvents: own goal attributed to opposite scorers map", () => {
  // A home player scores an own goal → credited to away scorers.
  const timeline = [makeGoal("Defender", "72", "Yes", "Own Goal")];
  const result = parseTimelineEvents(timeline, null, "FT");
  assert.equal(result.home_goal_scorers.length, 0);
  assert.equal(result.away_goal_scorers.length, 1);
  assert.ok(result.away_goal_scorers[0].own_goal_times);
  assert.deepEqual(result.away_goal_scorers[0].own_goal_times, ["72'"]);
});

test("parseTimelineEvents: missed penalty — no goal recorded", () => {
  const timeline = [makeGoal("Saka", "95", "No", "Missed Penalty")];
  const result = parseTimelineEvents(timeline, null, "Pens");
  assert.equal(result.home_goal_scorers.length, 0);
  assert.equal(result.away_goal_scorers.length, 0);
});

test("parseTimelineEvents: in-play penalty counts as regular goal", () => {
  const timeline = [makeGoal("Dembele", "65", "Yes", "Penalty")];
  const result = parseTimelineEvents(timeline, null, "FT");
  assert.equal(result.home_goal_scorers.length, 1);
  assert.deepEqual(result.home_goal_scorers[0].goal_times, ["65'"]);
});

test("parseTimelineEvents: assist attached to correct side", () => {
  const timeline = [makeGoal("Salah", "23", "Yes", "Normal Goal", "Alexander-Arnold")];
  const result = parseTimelineEvents(timeline, null, "FT");
  assert.equal(result.home_assists.length, 1);
  assert.equal(result.home_assists[0].player, "Alexander-Arnold");
  assert.deepEqual(result.home_assists[0].assist_times, ["23'"]);
  assert.equal(result.away_assists.length, 0);
});

// ---------------------------------------------------------------------------
// parseTimelineEvents — penalty shootout
// ---------------------------------------------------------------------------

test("parseTimelineEvents: shootout at minute 120 counts kicks when status is Pens", () => {
  const shootout = [
    { strTimeline: "Goal", strTimelineDetail: "Penalty", strHome: "Yes", strPlayer: "A", intTime: "120", idTeam: null },
    { strTimeline: "Goal", strTimelineDetail: "Penalty", strHome: "No",  strPlayer: "B", intTime: "120", idTeam: null },
    { strTimeline: "Goal", strTimelineDetail: "Penalty", strHome: "Yes", strPlayer: "C", intTime: "120", idTeam: null },
    { strTimeline: "Goal", strTimelineDetail: "Missed Penalty", strHome: "No", strPlayer: "D", intTime: "120", idTeam: null },
    { strTimeline: "Goal", strTimelineDetail: "Penalty", strHome: "No",  strPlayer: "E", intTime: "120", idTeam: null },
    { strTimeline: "Goal", strTimelineDetail: "Penalty", strHome: "Yes", strPlayer: "F", intTime: "120", idTeam: null },
    { strTimeline: "Goal", strTimelineDetail: "Missed Penalty", strHome: "Yes", strPlayer: "G", intTime: "120", idTeam: null },
    { strTimeline: "Goal", strTimelineDetail: "Penalty", strHome: "No",  strPlayer: "H", intTime: "120", idTeam: null },
  ];
  const result = parseTimelineEvents(shootout, null, "Pens");
  // Home scored A, C, F = 3; missed G. Away scored B, E, H = 3; missed D.
  assert.equal(result.penalty_result, "3-3");
  // Shootout kicks do not appear in goal scorers.
  assert.equal(result.home_goal_scorers.length, 0);
  assert.equal(result.away_goal_scorers.length, 0);
});

test("parseTimelineEvents: no penalty_result when status is FT", () => {
  const timeline = [
    { strTimeline: "Goal", strTimelineDetail: "Penalty", strHome: "Yes", strPlayer: "A", intTime: "120", idTeam: null },
  ];
  const result = parseTimelineEvents(timeline, null, "FT");
  assert.equal(result.penalty_result, null);
});

// ---------------------------------------------------------------------------
// parseTimelineEvents — cards
// ---------------------------------------------------------------------------

test("parseTimelineEvents: yellow card to home player", () => {
  const entry = { strTimeline: "Card", strTimelineDetail: "Yellow Card", strPlayer: "Rice", intTime: "34", strHome: "Yes", idTeam: null };
  const result = parseTimelineEvents([entry], null, "FT");
  assert.equal(result.home_yellow_cards.length, 1);
  assert.equal(result.home_yellow_cards[0].player, "Rice");
  assert.deepEqual(result.home_yellow_cards[0].yellow_card_times, ["34'"]);
});

test("parseTimelineEvents: red card to away player", () => {
  const entry = { strTimeline: "Card", strTimelineDetail: "Red Card", strPlayer: "Sanchez", intTime: "78", strHome: "No", idTeam: null };
  const result = parseTimelineEvents([entry], null, "FT");
  assert.equal(result.away_red_cards.length, 1);
  assert.equal(result.away_red_cards[0].player, "Sanchez");
});

test("parseTimelineEvents: yellow-red treated as red card", () => {
  const entry = { strTimeline: "Card", strTimelineDetail: "Yellow-Red Card", strPlayer: "X", intTime: "60", strHome: "Yes", idTeam: null };
  const result = parseTimelineEvents([entry], null, "FT");
  assert.equal(result.home_red_cards.length, 1);
  assert.equal(result.home_yellow_cards.length, 0);
});

// ---------------------------------------------------------------------------
// parseLineups
// ---------------------------------------------------------------------------

test("parseLineups: null on empty input", () => {
  assert.equal(parseLineups([], null), null);
  assert.equal(parseLineups(null, null), null);
});

test("parseLineups: separates home and away starters and subs", () => {
  const entries = [
    { strPlayer: "GK Home",   intSquadNumber: "1",  strHome: "Yes", strSubstitute: "No",  strPosition: "Goalkeeper",  strFormation: "4-3-3", idTeam: null },
    { strPlayer: "FW Home",   intSquadNumber: "9",  strHome: "Yes", strSubstitute: "No",  strPosition: "Centre-Forward", strFormation: "4-3-3", idTeam: null },
    { strPlayer: "SUB Home",  intSquadNumber: "20", strHome: "Yes", strSubstitute: "Yes", strPosition: "Midfielder", strFormation: "4-3-3", idTeam: null },
    { strPlayer: "GK Away",   intSquadNumber: "1",  strHome: "No",  strSubstitute: "No",  strPosition: "Goalkeeper",  strFormation: "4-4-2", idTeam: null },
    { strPlayer: "FW Away",   intSquadNumber: "11", strHome: "No",  strSubstitute: "No",  strPosition: "Forward", strFormation: "4-4-2", idTeam: null },
  ];
  const result = parseLineups(entries, null);
  assert.ok(result);
  assert.ok(result.home);
  assert.ok(result.away);
  assert.equal(result.home.formation, "4-3-3");
  assert.equal(result.away.formation, "4-4-2");
  assert.equal(result.home.starting_lineup.length, 2);
  assert.equal(result.home.substitutes.length, 1);
  assert.equal(result.away.starting_lineup.length, 2);
  assert.equal(result.away.substitutes.length, 0);
  assert.equal(result.home.starting_lineup[0].position_category, "goalkeeper");
  assert.equal(result.home.starting_lineup[1].position_category, "attacker");
  // Grid positions should be assigned.
  assert.ok(result.home.starting_lineup[0].formation_row_index !== undefined);
  assert.ok(result.home.starting_lineup[0].formation_slot_index !== undefined);
});

test("parseLineups: assigns formation grid positions from strFormation", () => {
  // 4-3-3: GK row0, 4 DEF row1, 3 MID row2, 3 FWD row3.
  const mkPlayer = (name, num, home, pos, posShort) => ({
    strPlayer: name, intSquadNumber: String(num), strHome: home ? "Yes" : "No",
    strSubstitute: "No", strPosition: pos, strPositionShort: posShort,
    strFormation: "4-3-3", idTeam: null,
  });
  const entries = [
    mkPlayer("GK", 1, true, "Goalkeeper", "G"),
    mkPlayer("D1", 2, true, "Right-Back", "D"),
    mkPlayer("D2", 3, true, "Centre-Back", "D"),
    mkPlayer("D3", 4, true, "Centre-Back", "D"),
    mkPlayer("D4", 5, true, "Left-Back", "D"),
    mkPlayer("M1", 6, true, "Central Midfield", "M"),
    mkPlayer("M2", 7, true, "Central Midfield", "M"),
    mkPlayer("M3", 8, true, "Defensive Midfield", "M"),
    mkPlayer("F1", 9, true, "Centre-Forward", "F"),
    mkPlayer("F2", 10, true, "Right Winger", "F"),
    mkPlayer("F3", 11, true, "Left Wing", "F"),
  ];
  const result = parseLineups(entries, null);
  assert.ok(result && result.home);
  const sl = result.home.starting_lineup;
  assert.equal(sl.length, 11);

  const gk = sl.find((p) => p.position_category === "goalkeeper");
  assert.equal(gk.formation_row_index, 0);
  assert.equal(gk.formation_row_size, 1);

  const defs = sl.filter((p) => p.position_category === "defender");
  assert.equal(defs.length, 4);
  defs.forEach((d) => {
    assert.equal(d.formation_row_index, 1);
    assert.equal(d.formation_row_size, 4);
  });

  const mids = sl.filter((p) => p.position_category === "midfielder");
  assert.equal(mids.length, 3);
  mids.forEach((m) => {
    assert.equal(m.formation_row_index, 2);
    assert.equal(m.formation_row_size, 3);
  });

  const fwds = sl.filter((p) => p.position_category === "attacker");
  assert.equal(fwds.length, 3);
  fwds.forEach((f) => {
    assert.equal(f.formation_row_index, 3);
    assert.equal(f.formation_row_size, 3);
  });
});

test("parseLineups: derives formation string when strFormation is null", () => {
  // 11 players with no strFormation — should derive "4-4-2" from position counts.
  const mkPlayer = (name, num, pos, posShort) => ({
    strPlayer: name, intSquadNumber: String(num), strHome: "Yes",
    strSubstitute: "No", strPosition: pos, strPositionShort: posShort,
    strFormation: null, idTeam: null,
  });
  const entries = [
    mkPlayer("GK", 1, "Goalkeeper", "G"),
    mkPlayer("D1", 2, "Right-Back", "D"), mkPlayer("D2", 3, "Centre-Back", "D"),
    mkPlayer("D3", 4, "Centre-Back", "D"), mkPlayer("D4", 5, "Left-Back", "D"),
    mkPlayer("M1", 6, "Central Midfield", "M"), mkPlayer("M2", 7, "Central Midfield", "M"),
    mkPlayer("M3", 8, "Left Midfield", "M"), mkPlayer("M4", 9, "Right Midfield", "M"),
    mkPlayer("F1", 10, "Centre-Forward", "F"), mkPlayer("F2", 11, "Left Wing", "F"),
  ];
  const result = parseLineups(entries, null);
  assert.ok(result && result.home);
  assert.equal(result.home.formation, "4-4-2");
  // Grid positions still assigned.
  const sl = result.home.starting_lineup;
  assert.equal(sl.length, 11);
  const gk = sl.find((p) => p.position_category === "goalkeeper");
  assert.equal(gk.formation_row_index, 0);
});

// ---------------------------------------------------------------------------
// extractSubstitutionsFromTimeline
// ---------------------------------------------------------------------------

const { extractSubstitutionsFromTimeline } = (() => {
  // Re-export via __private for testing.
  const mod = require("./fetch_tsdb_matches");
  return mod.__private;
})();

test("extractSubstitutionsFromTimeline: extracts home and away subs with minute", () => {
  const timeline = [
    { strTimeline: "subst", strPlayer: "Pablo Jesus", strAssist: "Callum Wilson",
      intTime: "46", strHome: "Yes", idTeam: null },
    { strTimeline: "subst", strPlayer: "Jaka Bijol", strAssist: "Daniel James",
      intTime: "70", strHome: "No", idTeam: null },
    { strTimeline: "Goal", strPlayer: "Salah", strAssist: "", intTime: "12",
      strHome: "Yes", idTeam: null }, // non-subst — should be ignored
  ];
  const homeStarters = [{ name: "Pablo Jesus", number: 9 }];
  const awayStarters  = [{ name: "Jaka Bijol",   number: 15 }];

  const result = extractSubstitutionsFromTimeline(timeline, homeStarters, awayStarters, null);

  assert.equal(result.home.length, 1);
  assert.equal(result.home[0].minute, "46'");
  assert.equal(result.home[0].player_off.name, "Pablo Jesus");
  assert.equal(result.home[0].player_off.number, 9);
  assert.equal(result.home[0].player_on.name, "Callum Wilson");
  assert.equal(result.home[0].player_on.number, null);

  assert.equal(result.away.length, 1);
  assert.equal(result.away[0].player_off.name, "Jaka Bijol");
  assert.equal(result.away[0].player_off.number, 15);
  assert.equal(result.away[0].player_on.name, "Daniel James");
});

test("extractSubstitutionsFromTimeline: sorts by minute", () => {
  const timeline = [
    { strTimeline: "subst", strPlayer: "A", strAssist: "B", intTime: "75", strHome: "Yes", idTeam: null },
    { strTimeline: "subst", strPlayer: "C", strAssist: "D", intTime: "46", strHome: "Yes", idTeam: null },
  ];
  const result = extractSubstitutionsFromTimeline(timeline, [], [], null);
  assert.equal(result.home[0].minute, "46'");
  assert.equal(result.home[1].minute, "75'");
});

test("extractSubstitutionsFromTimeline: empty timeline returns empty arrays", () => {
  const result = extractSubstitutionsFromTimeline([], [], [], null);
  assert.deepEqual(result, { home: [], away: [] });
});

// ---------------------------------------------------------------------------
// computeAggregateFromSchedule
// ---------------------------------------------------------------------------

test("computeAggregateFromSchedule: returns null for non-two-legged league", () => {
  const event = {
    home_team: "Arsenal",
    away_team: "Chelsea",
    date: "2026-04-20",
    idLeague: "4328", // EPL — not two-legged
  };
  const cache = [{ home_team: "Chelsea", away_team: "Arsenal", date: "2026-04-05", home_score: 1, away_score: 2 }];
  assert.equal(computeAggregateFromSchedule(event, cache), null);
});

test("computeAggregateFromSchedule: computes correct aggregate for UCL", () => {
  // Leg 2 (2nd leg): Arsenal (home) 1 - 1 PSG (away)
  // Leg 1 (1st leg): PSG (home) 2 - 0 Arsenal (away)
  const event = {
    home_team: "Arsenal",
    away_team: "PSG",
    date: "2026-04-20",
    home_score: 1,
    away_score: 1,
    idLeague: "4480", // UCL
  };
  const cache = [
    // First leg: PSG home, Arsenal away
    { home_team: "PSG", away_team: "Arsenal", date: "2026-04-05", home_score: 2, away_score: 0 },
  ];
  const agg = computeAggregateFromSchedule(event, cache);
  assert.ok(agg);
  // Arsenal aggregate: their leg2 home (1) + leg1 away (0) = 1
  // PSG aggregate: their leg2 away (1) + leg1 home (2) = 3
  assert.equal(agg.aggregate_home_score, 1);
  assert.equal(agg.aggregate_away_score, 3);
});

test("computeAggregateFromSchedule: returns null when no reverse fixture found", () => {
  const event = {
    home_team: "Arsenal",
    away_team: "PSG",
    date: "2026-04-20",
    home_score: 1,
    away_score: 1,
    idLeague: "4480",
  };
  const agg = computeAggregateFromSchedule(event, []);
  assert.equal(agg, null);
});

test("computeAggregateFromSchedule: ignores future fixtures as first leg", () => {
  const event = {
    home_team: "Arsenal",
    away_team: "PSG",
    date: "2026-04-05",
    home_score: 1,
    away_score: 1,
    idLeague: "4480",
  };
  const cache = [
    // Later date — this is the SECOND leg, not first.
    { home_team: "PSG", away_team: "Arsenal", date: "2026-04-20", home_score: 2, away_score: 0 },
  ];
  const agg = computeAggregateFromSchedule(event, cache);
  assert.equal(agg, null);
});
