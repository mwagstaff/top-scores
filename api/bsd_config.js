"use strict";

// ---------------------------------------------------------------------------
// BSD evaluation config.
//
// BSD_LEAGUE_ALLOWLIST is a CSV of BSD league ids to ingest. Defaults to the
// World Cup 2026 (id 27), English Premier League (id 1), plus the other
// domestic/cup/qualifying competitions mapped in BSD_LEAGUE_NAME_MAP
// (bsd_adapter.js).
// ---------------------------------------------------------------------------

const DEFAULT_BSD_LEAGUE_ALLOWLIST = [
  "27", "1",
  "40", "12", "86", "87", "39", "7", "8", "90", "64", "58", "6", "5", "43", "44", "31", "42",
  "4", "10", "62", "63", "13", "59", "41", "3",
];

function parseCsvEnv(value) {
  if (!value) return [];
  return String(value)
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

const envAllowlist = parseCsvEnv(process.env.BSD_LEAGUE_ALLOWLIST);

const BSD_LEAGUE_ALLOWLIST =
  envAllowlist.length > 0 ? envAllowlist : DEFAULT_BSD_LEAGUE_ALLOWLIST;

module.exports = {
  DEFAULT_BSD_LEAGUE_ALLOWLIST,
  BSD_LEAGUE_ALLOWLIST,
  parseCsvEnv,
};
