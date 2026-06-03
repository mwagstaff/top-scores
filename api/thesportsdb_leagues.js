"use strict";

// ---------------------------------------------------------------------------
// TheSportsDB league allowlist
//
// "Core leagues first" per the migration plan. Each entry provides:
//   id            – TheSportsDB idLeague
//   name          – canonical name used internally (matches our normalizeLeagueName output)
//   tsdbName      – exact strLeague as TheSportsDB returns it (for inbound mapping)
//   seasons       – how many past seasons to include when building the schedule cache
//                  (current season + this many prior seasons for historical results)
//   seasonFormat  – optional, one of:
//                  "year-year" (default) → "2025-2026"
//                  "year"               → "2026"  (for tournaments with a single calendar year)
// ---------------------------------------------------------------------------

const TSDB_LEAGUE_ALLOWLIST = [
  // --- English ---
  {
    id: "4328",
    name: "Premier League",
    tsdbName: "English Premier League",
    seasons: 1,
  },
  {
    id: "4329",
    name: "Championship",
    tsdbName: "English League Championship",
    seasons: 1,
  },
  // --- Scottish ---
  {
    id: "4330",
    name: "Scottish Premiership",
    tsdbName: "Scottish Premier League",
    seasons: 1,
  },
  // --- German ---
  {
    id: "4331",
    name: "Bundesliga",
    tsdbName: "German Bundesliga",
    seasons: 1,
  },
  // --- Italian ---
  {
    id: "4332",
    name: "Serie A",
    tsdbName: "Italian Serie A",
    seasons: 1,
  },
  // --- French ---
  {
    id: "4334",
    name: "Ligue 1",
    tsdbName: "French Ligue 1",
    seasons: 1,
  },
  // --- Spanish ---
  {
    id: "4335",
    name: "La Liga",
    tsdbName: "Spanish La Liga",
    seasons: 1,
  },
  // --- European cups ---
  {
    id: "4480",
    name: "UEFA Champions League",
    tsdbName: "UEFA Champions League",
    seasons: 1,
  },
  {
    id: "4481",
    name: "UEFA Europa League",
    tsdbName: "UEFA Europa League",
    seasons: 1,
  },
  {
    id: "5071",
    name: "UEFA Conference League",
    tsdbName: "UEFA Conference League",
    seasons: 1,
  },
  // --- International tournaments ---
  // FIFA World Cup 2026 — single-year season format ("2026").
  // idLeague 4429 is the master FIFA World Cup league on TheSportsDB.
  // Group-stage matches have strLeague like "FIFA World Cup 2026 Group A";
  // the schedule API returns all rounds under this league ID.
  // VERIFY: GET /search/league/FIFA%20World%20Cup to confirm idLeague before deploy.
  {
    id: "4429",
    name: "FIFA World Cup",
    tsdbName: "FIFA World Cup",
    seasons: 0,
    seasonFormat: "year",
  },
];

// Map from TheSportsDB strLeague → our internal league name.
// Built once at module load from the allowlist above.
const TSDB_LEAGUE_NAME_MAP = new Map(
  TSDB_LEAGUE_ALLOWLIST.map((entry) => [
    entry.tsdbName.toLowerCase(),
    entry.name,
  ])
);

// Supplement the name map with prefix-match patterns for competitions whose
// strLeague varies by round/group (e.g. "FIFA World Cup 2026 Group A").
// Keys are lowercased prefix strings; checked in resolveLeagueNameWithPrefix.
const TSDB_LEAGUE_NAME_PREFIX_MAP = [
  { prefix: "fifa world cup", name: "FIFA World Cup" },
];

// Set of internal league names for fast membership checks.
const TSDB_ALLOWED_LEAGUE_NAMES = new Set(
  TSDB_LEAGUE_ALLOWLIST.map((entry) => entry.name.toLowerCase())
);

// Set of allowlisted SportsDB league IDs for fast membership checks.
const TSDB_ALLOWED_LEAGUE_IDS = new Set(
  TSDB_LEAGUE_ALLOWLIST.map((entry) => String(entry.id))
);

// EPL league ID (used for premier_league_teams feed).
const TSDB_EPL_LEAGUE_ID = "4328";

// Two-legged competition IDs — used for aggregate score computation.
const TSDB_TWO_LEGGED_LEAGUE_IDS = new Set(["4480", "4481", "5071"]);

/**
 * Maps a TheSportsDB strLeague value to our canonical internal league name.
 * Tries an exact match first, then a prefix match (for group/round variants).
 * Returns null if the league is not in the allowlist.
 */
function mapTsdbLeagueName(tsdbLeagueName) {
  if (!tsdbLeagueName) return null;
  const lower = tsdbLeagueName.toLowerCase();
  const exact = TSDB_LEAGUE_NAME_MAP.get(lower);
  if (exact) return exact;
  for (const entry of TSDB_LEAGUE_NAME_PREFIX_MAP) {
    if (lower.startsWith(entry.prefix)) return entry.name;
  }
  return null;
}

/**
 * Returns true if the given idLeague is in the core allowlist.
 */
function isAllowedTsdbLeagueId(idLeague) {
  return TSDB_ALLOWED_LEAGUE_IDS.has(String(idLeague || ""));
}

/**
 * Returns the current and previous season strings for a given league entry.
 *
 * Default format ("year-year"): "2025-2026"
 * Single-year format ("year"):  "2026"  — used for tournaments like FIFA World Cup
 *
 * Includes the current season plus `entry.seasons` prior seasons.
 */
function leagueSeasons(entry, nowMs = Date.now()) {
  const year = new Date(nowMs).getUTCFullYear();

  if (entry.seasonFormat === "year") {
    const seasons = [];
    for (let i = 0; i <= (entry.seasons || 0); i += 1) {
      seasons.push(String(year - i));
    }
    return seasons;
  }

  // Football seasons typically start in the second half of the calendar year.
  // Use July 1 as the cutover to determine the current season start year.
  const seasonStartYear =
    new Date(nowMs).getUTCMonth() >= 6 ? year : year - 1;

  const seasons = [];
  for (let i = 0; i <= (entry.seasons || 0); i += 1) {
    const start = seasonStartYear - i;
    seasons.push(`${start}-${start + 1}`);
  }
  return seasons;
}

module.exports = {
  TSDB_LEAGUE_ALLOWLIST,
  TSDB_LEAGUE_NAME_MAP,
  TSDB_LEAGUE_NAME_PREFIX_MAP,
  TSDB_ALLOWED_LEAGUE_NAMES,
  TSDB_ALLOWED_LEAGUE_IDS,
  TSDB_EPL_LEAGUE_ID,
  TSDB_TWO_LEGGED_LEAGUE_IDS,
  mapTsdbLeagueName,
  isAllowedTsdbLeagueId,
  leagueSeasons,
};
