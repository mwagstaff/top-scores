const DEFAULT_COMPETITION_ALLOWLIST = [
  "Bundesliga",
  "Carabao Cup",
  "Championship",
  "Copa del Rey",
  "FA Cup",
  "FIFA World Cup 2026",
  "International Friendly",
  "La Liga",
  "Premier League",
  "Scottish Premiership",
  "Serie A",
  "UEFA Champions League",
  "UEFA Conference League",
  "UEFA Europa League",
  "UEFA Super Cup",
];

const TEAM_RANKING_SOURCE_CLUBELO = "clubelo";
const TEAM_RANKING_SOURCE_FOOTBALLDATABASE = "footballdatabase";
const TEAM_RANKING_SOURCE_NATIONAL_ELO = "nationalelo";
const TEAM_RANKING_SOURCE_MERGED = "merged";

function parseCsvEnv(value) {
  if (!value) return [];
  return String(value)
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function parseNumberEnv(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function normalizeTeamRankingSource(value) {
  const normalized = String(value || "")
    .trim()
    .toLowerCase();
  if (!normalized) return null;
  if (["merged", "both", "combined", "all"].includes(normalized)) {
    return TEAM_RANKING_SOURCE_MERGED;
  }
  if (["clubelo", "club_elo", "club-elo"].includes(normalized)) {
    return TEAM_RANKING_SOURCE_CLUBELO;
  }
  if (
    ["footballdatabase", "football_database", "football-database", "fdb"].includes(normalized)
  ) {
    return TEAM_RANKING_SOURCE_FOOTBALLDATABASE;
  }
  if (["nationalelo", "national_elo", "national-elo", "national"].includes(normalized)) {
    return TEAM_RANKING_SOURCE_NATIONAL_ELO;
  }
  return null;
}

const envCompetitionAllowlist = parseCsvEnv(process.env.COMPETITION_ALLOWLIST);
const envTeamRankingDefaultSource = normalizeTeamRankingSource(
  process.env.TEAM_RANKING_DEFAULT_SOURCE
);
const envTeamRankingDefaultElo = parseNumberEnv(process.env.TEAM_RANKING_DEFAULT_ELO, 1000);

const SERVER_CONFIG = {
  competitionAllowlist:
    envCompetitionAllowlist.length > 0
      ? envCompetitionAllowlist
      : DEFAULT_COMPETITION_ALLOWLIST,
  teamRankingDefaultSource:
    envTeamRankingDefaultSource || TEAM_RANKING_SOURCE_MERGED,
  teamRankingDefaultElo: envTeamRankingDefaultElo,
};

module.exports = {
  DEFAULT_COMPETITION_ALLOWLIST,
  TEAM_RANKING_SOURCE_MERGED,
  TEAM_RANKING_SOURCE_CLUBELO,
  TEAM_RANKING_SOURCE_FOOTBALLDATABASE,
  TEAM_RANKING_SOURCE_NATIONAL_ELO,
  normalizeTeamRankingSource,
  SERVER_CONFIG,
};
