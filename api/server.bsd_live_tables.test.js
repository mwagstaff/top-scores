"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { __private } = require("./server");
const {
  applyLiveResultsToBsdTable,
  bsdMatchesForTable,
  withNormalizedTableLeagueName,
} = __private;

function row(position, team, opts = {}) {
  return {
    position,
    team,
    played: opts.played ?? 1,
    won: opts.won ?? 0,
    drawn: opts.drawn ?? 0,
    lost: opts.lost ?? 0,
    goals_for: opts.goals_for ?? 0,
    goals_against: opts.goals_against ?? 0,
    goal_difference: opts.goal_difference ?? 0,
    points: opts.points ?? 0,
    form: [],
    rank_status: null,
  };
}

function flatTable(rows) {
  return {
    league_id: "1",
    league_name: "Premier League",
    stage_name: null,
    season: "2025/26",
    updated_at: "2026-06-01T00:00:00.000Z",
    realtime: false,
    groups: [],
    rows,
  };
}

// Alpha 1st (3pts, +2), Bravo 2nd (0pts, -2).
function twoTeamTable() {
  return flatTable([
    row(1, "Alpha", { won: 1, goals_for: 2, goals_against: 0, goal_difference: 2, points: 3 }),
    row(2, "Bravo", { lost: 1, goals_for: 0, goals_against: 2, goal_difference: -2, points: 0 }),
  ]);
}

test("applyLiveResultsToBsdTable: in-progress result flips positions, sets live + previous_position + realtime", () => {
  const base = twoTeamTable();
  // Bravo beating Alpha 3-0 live: both reach 3 pts, Bravo wins on GD.
  const matches = [
    { league: "Premier League", home_team: "Bravo", away_team: "Alpha", home_score: 3, away_score: 0, score_status: "55'" },
  ];
  const result = applyLiveResultsToBsdTable(base, matches);

  assert.equal(result.realtime, true);
  const bravo = result.rows.find((r) => r.team === "Bravo");
  const alpha = result.rows.find((r) => r.team === "Alpha");

  assert.equal(bravo.position, 1);
  assert.equal(bravo.previous_position, 2); // moved up
  assert.equal(bravo.points, 3);
  assert.equal(bravo.played, 2);
  assert.equal(bravo.goal_difference, 1);
  assert.equal(bravo.live, true);

  assert.equal(alpha.position, 2);
  assert.equal(alpha.previous_position, 1); // moved down
  assert.equal(alpha.live, true);
});

test("applyLiveResultsToBsdTable: a team not in a live match is left untouched (no double counting)", () => {
  // Alpha is not playing; only Bravo vs a non-table team would be irrelevant.
  // Here nothing live involves the table, so the table is returned unchanged.
  const base = twoTeamTable();
  const matches = [
    { league: "Premier League", home_team: "Someone", away_team: "Else", home_score: 1, away_score: 0, score_status: "30'" },
  ];
  const result = applyLiveResultsToBsdTable(base, matches);
  assert.equal(result, base); // identity — no applicable live match
});

test("applyLiveResultsToBsdTable: finished matches are NOT overlaid (left to the baseline standings)", () => {
  const base = twoTeamTable();
  const matches = [
    { league: "Premier League", home_team: "Bravo", away_team: "Alpha", home_score: 3, away_score: 0, score_status: "FT" },
  ];
  const result = applyLiveResultsToBsdTable(base, matches);
  assert.equal(result, base); // unchanged — finished games already in the table
});

test("applyLiveResultsToBsdTable: no live matches leaves the table untouched", () => {
  const base = twoTeamTable();
  const matches = [
    { league: "Premier League", home_team: "Alpha", away_team: "Bravo", home_score: null, away_score: null, score_status: null },
  ];
  const result = applyLiveResultsToBsdTable(base, matches);
  assert.equal(result, base);
});

test("applyLiveResultsToBsdTable: applies within each group independently", () => {
  const base = {
    league_id: "27",
    league_name: "FIFA World Cup 2026",
    stage_name: null,
    season: "2026",
    updated_at: "2026-06-01T00:00:00.000Z",
    realtime: false,
    rows: [],
    groups: [
      {
        name: "Group A",
        rows: [
          row(1, "Mexico", { won: 1, goals_for: 2, goals_against: 0, goal_difference: 2, points: 3 }),
          row(2, "Canada", { lost: 1, goals_for: 0, goals_against: 2, goal_difference: -2, points: 0 }),
        ],
      },
      {
        name: "Group B",
        rows: [
          row(1, "Spain", { won: 1, goals_for: 1, goals_against: 0, goal_difference: 1, points: 3 }),
          row(2, "Brazil", { lost: 1, goals_for: 0, goals_against: 1, goal_difference: -1, points: 0 }),
        ],
      },
    ],
  };
  // Live only in Group A (Canada 4-0 Mexico).
  const matches = [
    { league: "FIFA World Cup 2026", home_team: "Canada", away_team: "Mexico", home_score: 4, away_score: 0, score_status: "70'" },
  ];
  const result = applyLiveResultsToBsdTable(base, matches);
  assert.equal(result.realtime, true);

  const groupA = result.groups.find((g) => g.name === "Group A");
  const canada = groupA.rows.find((r) => r.team === "Canada");
  assert.equal(canada.position, 1);
  assert.equal(canada.previous_position, 2);
  assert.equal(canada.live, true);

  // Group B untouched (returned as-is, no realtime fields injected).
  const groupB = result.groups.find((g) => g.name === "Group B");
  assert.equal(groupB.rows[0].previous_position, undefined);
  assert.equal(groupB.rows[0].live, undefined);
});

test("bsdMatchesForTable: filters matches by canonical league name", () => {
  const table = { league_name: "Premier League" };
  const matches = [
    { league: "Premier League", home_team: "A" },
    { league: "FIFA World Cup 2026", home_team: "B" },
  ];
  const filtered = bsdMatchesForTable(table, matches);
  assert.equal(filtered.length, 1);
  assert.equal(filtered[0].home_team, "A");
});

test("withNormalizedTableLeagueName: aliases TSDB's bare 'FIFA World Cup' to match.league's 'FIFA World Cup 2026'", () => {
  const table = { league_id: "4429", league_name: "FIFA World Cup", rows: [] };
  const normalized = withNormalizedTableLeagueName(table);
  assert.equal(normalized.league_name, "FIFA World Cup 2026");
  assert.notEqual(normalized, table); // returns a copy when changed
});

test("withNormalizedTableLeagueName: leaves an already-correct name untouched (same reference)", () => {
  const table = { league_id: "1", league_name: "Premier League", rows: [] };
  const normalized = withNormalizedTableLeagueName(table);
  assert.equal(normalized, table);
});

test("withNormalizedTableLeagueName: passes through a table with no league_name", () => {
  const table = { league_id: "1", league_name: null, rows: [] };
  assert.equal(withNormalizedTableLeagueName(table), table);
});
