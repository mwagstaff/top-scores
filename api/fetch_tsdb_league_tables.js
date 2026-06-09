"use strict";

const { getLeagueTable } = require("./thesportsdb_client");

// ---------------------------------------------------------------------------
// Parse helpers
// ---------------------------------------------------------------------------

function toInt(value, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) ? Math.trunc(n) : fallback;
}

function parseFormString(strForm) {
  if (!strForm) return [];
  return String(strForm)
    .toUpperCase()
    .split("")
    .filter((c) => c === "W" || c === "D" || c === "L")
    .slice(-5);
}

function parseTsdbLeagueTableRow(entry) {
  const position = toInt(entry && entry.intRank, 0);
  const team = String((entry && entry.strTeam) || "").trim();
  if (!position || !team) return null;

  return {
    position,
    team,
    played: toInt(entry.intPlayed),
    won: toInt(entry.intWin),
    drawn: toInt(entry.intDraw),
    lost: toInt(entry.intLoss),
    goals_for: toInt(entry.intGoalsFor),
    goals_against: toInt(entry.intGoalsAgainst),
    goal_difference: toInt(entry.intGoalDifference),
    points: toInt(entry.intPoints),
    form: parseFormString(entry.strForm),
    rank_status: String((entry && entry.strDescription) || "").trim() || null,
  };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Parses a TSDB v1 /lookuptable response into our internal table shape.
 * Returns null if the response contains no usable rows (e.g. cup competitions).
 */
function parseTsdbLeagueTableResponse(data, idLeague, internalName) {
  const entries = Array.isArray(data && data.table) ? data.table : [];
  if (entries.length === 0) return null;

  const firstEntry = entries[0] || {};
  const rawName = String(firstEntry.strLeague || "").trim();
  const leagueName = internalName || rawName || String(idLeague);
  const season = String(firstEntry.strSeason || "").trim() || null;

  const rows = entries
    .map(parseTsdbLeagueTableRow)
    .filter(Boolean)
    .sort((a, b) => a.position - b.position);

  if (rows.length === 0) return null;

  return {
    league_id: String(idLeague),
    league_name: leagueName,
    stage_name: null,
    season,
    source_url: `https://www.thesportsdb.com/api/v1/json/123/lookuptable.php?l=${idLeague}`,
    updated_at: null,
    groups: [],
    rows,
  };
}

/**
 * Fetches and parses the league table for one TSDB league ID.
 * Returns null for leagues that have no table (cups, friendlies, etc.).
 */
async function fetchTsdbLeagueTable(idLeague, internalName, options = {}) {
  const data = await getLeagueTable(String(idLeague), {
    initiator: options.initiator || "scraper",
    trigger: options.trigger,
    reason: options.reason || `tsdb_league_table:${idLeague}`,
  });
  if (!data || !Array.isArray(data.table) || data.table.length === 0) return null;
  return parseTsdbLeagueTableResponse(data, idLeague, internalName);
}

module.exports = {
  fetchTsdbLeagueTable,
  parseTsdbLeagueTableResponse,
};
