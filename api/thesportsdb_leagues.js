"use strict";

// =============================================================================
// Tracked league IDs
// =============================================================================
// Add or remove a TheSportsDB idLeague here to control which leagues the server
// collects live scores and match data for. That's the only change needed for
// the common case.
//
// To customise a league's internal short name or season format, add an entry
// to LEAGUE_OVERRIDES below.

const TSDB_TRACKED_LEAGUE_IDS = [
  // ── English ────────────────────────────────────────────────────────────────
  "4328", // English Premier League
  "4329", // English League Championship
  "4396", // English League 1
  "4397", // English League 2
  "4590", // English National League
  "4482", // FA Cup
  "4570", // EFL Cup
  "4571", // FA Community Shield
  "4847", // EFL Trophy
  "5647", // English Premier League Summer Series

  // ── Scottish ───────────────────────────────────────────────────────────────
  "4330", // Scottish Premier League
  "4723", // Scottish FA Cup

  // ── German ─────────────────────────────────────────────────────────────────
  "4331", // German Bundesliga
  "4485", // DFB-Pokal
  "4903", // German Super Cup

  // ── Italian ────────────────────────────────────────────────────────────────
  "4332", // Italian Serie A
  "4506", // Coppa Italia
  "4507", // Supercoppa Italiana

  // ── French ─────────────────────────────────────────────────────────────────
  "4334", // French Ligue 1
  "4484", // Coupe de France
  "4504", // Coupe de la Ligue

  // ── Spanish ────────────────────────────────────────────────────────────────
  "4335", // Spanish La Liga
  "4483", // Copa del Rey

  // ── Dutch / Portuguese / Turkish ───────────────────────────────────────────
  "4337", // Dutch Eredivisie
  "4344", // Portuguese Primeira Liga
  "4339", // Turkish Super Lig

  // ── European club competitions ─────────────────────────────────────────────
  "4480", // UEFA Champions League
  "4481", // UEFA Europa League
  "5071", // UEFA Conference League
  "4512", // UEFA Super Cup
  "4523", // European Cup            (historical)
  "4524", // UEFA Cup                (historical)
  "4503", // FIFA Club World Cup
  "5648", // Emirates Cup
  "4505", // International Champions Cup

  // ── International tournaments ──────────────────────────────────────────────
  "4429", // FIFA World Cup
  "4502", // UEFA European Championships
  "4490", // UEFA Nations League
  "4496", // African Cup of Nations
  "4499", // Copa America
  "4498", // Confederations Cup
  "5039", // Olympics Soccer

  // ── World Cup / EURO qualifying ────────────────────────────────────────────
  "5513", // World Cup Qualifying AFC
  "5514", // World Cup Qualifying CAF
  "5515", // World Cup Qualifying CONMEBOL
  "5516", // World Cup Qualifying CONCACAF
  "5517", // World Cup Qualifying OFC
  "5518", // World Cup Qualifying UEFA
  "5519", // UEFA European Championships Qualifying

  // ── Friendlies ─────────────────────────────────────────────────────────────
  "4562", // International Friendlies
  "4569", // Club Friendlies
];

// =============================================================================
// Per-league overrides
// =============================================================================
// Only add an entry here if a league needs non-default behaviour.
//
// Fields (all optional):
//   name         – internal short name used in match payloads.
//                  Defaults to the TSDB strLeague value (e.g. "English Premier League").
//   tsdbName     – exact TSDB strLeague string, required when `name` differs so the
//                  inbound name-mapping works.  Defaults to `name`.
//   seasons      – prior seasons to include in the schedule cache (default: 1).
//   seasonFormat – "year-year" (default) or "year" for single-calendar-year tournaments.
//   prefixMatch  – true → also match strLeague values that *start with* `name`
//                  (e.g. "FIFA World Cup 2026 Group A" → "FIFA World Cup").

const LEAGUE_OVERRIDES = {
  // Short internal names for the top domestic leagues
  "4328": { name: "Premier League",      tsdbName: "English Premier League" },
  "4329": { name: "Championship",        tsdbName: "English League Championship" },
  "4330": { name: "Scottish Premiership", tsdbName: "Scottish Premier League" },
  "4331": { name: "Bundesliga",          tsdbName: "German Bundesliga" },
  "4332": { name: "Serie A",             tsdbName: "Italian Serie A" },
  "4334": { name: "Ligue 1",             tsdbName: "French Ligue 1" },
  "4335": { name: "La Liga",             tsdbName: "Spanish La Liga" },

  // Friendlies / short tournament names
  "4562": { name: "International Friendly", tsdbName: "International Friendlies",
            seasonFormat: "year", seasons: 0 },

  // Single-year international tournaments
  "4429": { name: "FIFA World Cup", tsdbName: "FIFA World Cup", seasonFormat: "year", seasons: 0, prefixMatch: true },
  "4502": { seasonFormat: "year", seasons: 0 },
  "4496": { seasonFormat: "year", seasons: 0 },
  "4499": { seasonFormat: "year", seasons: 0 },
  "4498": { seasonFormat: "year", seasons: 0 },
  "5039": { seasonFormat: "year", seasons: 0 },
  "4503": { seasonFormat: "year", seasons: 0 },

  // Annual super cups / one-off matches
  "4512": { seasonFormat: "year", seasons: 0 },
  "4507": { seasonFormat: "year", seasons: 0 },
  "4903": { seasonFormat: "year", seasons: 0 },
  "4571": { seasonFormat: "year", seasons: 0 },

  // Pre-season tournaments
  "5647": { seasonFormat: "year", seasons: 0 },
  "5648": { seasonFormat: "year", seasons: 0 },
  "4505": { seasonFormat: "year", seasons: 0 },
  "4569": { seasonFormat: "year", seasons: 0 },

  // Historical competitions — no prior seasons needed
  "4523": { seasons: 0 },
  "4524": { seasons: 0 },
};

// =============================================================================
// Derived structures — do not edit below this line
// =============================================================================

const DEFAULT_SEASONS = 1;
const DEFAULT_SEASON_FORMAT = "year-year";

// Build the full allowlist by merging the ID list with overrides.
const TSDB_LEAGUE_ALLOWLIST = TSDB_TRACKED_LEAGUE_IDS.map((id) => {
  const ov = LEAGUE_OVERRIDES[id] || {};
  const name = ov.name || null; // null = use TSDB strLeague at runtime
  const tsdbName = ov.tsdbName || ov.name || null;
  return {
    id,
    name,
    tsdbName,
    seasons: ov.seasons !== undefined ? ov.seasons : DEFAULT_SEASONS,
    seasonFormat: ov.seasonFormat || DEFAULT_SEASON_FORMAT,
    prefixMatch: ov.prefixMatch || false,
  };
});

// Map from TheSportsDB strLeague (lower) → our internal league name.
// Only populated for leagues that have an explicit name override; all others
// fall back to returning the TSDB strLeague value directly.
const TSDB_LEAGUE_NAME_MAP = new Map(
  TSDB_LEAGUE_ALLOWLIST
    .filter((entry) => entry.tsdbName && entry.name)
    .map((entry) => [entry.tsdbName.toLowerCase(), entry.name])
);

// Prefix-match patterns for competitions whose strLeague varies by round/group.
const TSDB_LEAGUE_NAME_PREFIX_MAP = TSDB_LEAGUE_ALLOWLIST
  .filter((entry) => entry.prefixMatch && entry.name)
  .map((entry) => ({ prefix: entry.name.toLowerCase(), name: entry.name }));

// Set of internal league names for fast membership checks.
const TSDB_ALLOWED_LEAGUE_NAMES = new Set(
  TSDB_LEAGUE_ALLOWLIST
    .map((entry) => (entry.name || entry.tsdbName || "").toLowerCase())
    .filter(Boolean)
);

// Set of allowlisted SportsDB league IDs for fast membership checks.
const TSDB_ALLOWED_LEAGUE_IDS = new Set(
  TSDB_LEAGUE_ALLOWLIST.map((entry) => String(entry.id))
);

// EPL league ID (used for premier_league_teams feed).
const TSDB_EPL_LEAGUE_ID = "4328";

// Two-legged competition IDs — used for aggregate score computation.
const TSDB_TWO_LEGGED_LEAGUE_IDS = new Set(["4480", "4481", "5071"]);

// Reverse lookup: internal league name (lower) → TSDB league ID string.
// Covers all entries that have an explicit name override; unmapped leagues
// (where the internal name equals the TSDB strLeague) are looked up by
// tsdbName (or the strLeague itself). Used for debug tooling only.
const TSDB_LEAGUE_ID_BY_NAME = new Map(
  TSDB_LEAGUE_ALLOWLIST.flatMap((entry) => {
    const id = String(entry.id);
    const pairs = [];
    if (entry.name)     pairs.push([entry.name.toLowerCase(), id]);
    if (entry.tsdbName) pairs.push([entry.tsdbName.toLowerCase(), id]);
    return pairs;
  })
);

/**
 * Maps a TheSportsDB strLeague value to our canonical internal league name.
 * Tries an exact match first, then a prefix match (for group/round variants).
 * Returns the original strLeague if no mapping is configured (acceptable for
 * leagues that use the TSDB name directly as the internal name).
 */
function mapTsdbLeagueName(tsdbLeagueName) {
  if (!tsdbLeagueName) return null;
  const lower = tsdbLeagueName.toLowerCase();
  const exact = TSDB_LEAGUE_NAME_MAP.get(lower);
  if (exact) return exact;
  for (const entry of TSDB_LEAGUE_NAME_PREFIX_MAP) {
    if (lower.startsWith(entry.prefix)) return entry.name;
  }
  return tsdbLeagueName;
}

/**
 * Returns true if the given idLeague is in the tracked allowlist.
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
  TSDB_TRACKED_LEAGUE_IDS,
  TSDB_LEAGUE_ALLOWLIST,
  TSDB_LEAGUE_NAME_MAP,
  TSDB_LEAGUE_ID_BY_NAME,
  TSDB_LEAGUE_NAME_PREFIX_MAP,
  TSDB_ALLOWED_LEAGUE_NAMES,
  TSDB_ALLOWED_LEAGUE_IDS,
  TSDB_EPL_LEAGUE_ID,
  TSDB_TWO_LEGGED_LEAGUE_IDS,
  mapTsdbLeagueName,
  isAllowedTsdbLeagueId,
  leagueSeasons,
};
