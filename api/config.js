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

function parseCsvEnv(value) {
  if (!value) return [];
  return String(value)
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function normalizeTeamRankingSource(value) {
  const normalized = String(value || "")
    .trim()
    .toLowerCase();
  if (!normalized) return null;
  if (["clubelo", "club_elo", "club-elo"].includes(normalized)) {
    return TEAM_RANKING_SOURCE_CLUBELO;
  }
  if (
    ["footballdatabase", "football_database", "football-database", "fdb"].includes(normalized)
  ) {
    return TEAM_RANKING_SOURCE_FOOTBALLDATABASE;
  }
  return null;
}

const envCompetitionAllowlist = parseCsvEnv(process.env.COMPETITION_ALLOWLIST);
const envTeamRankingDefaultSource = normalizeTeamRankingSource(
  process.env.TEAM_RANKING_DEFAULT_SOURCE
);

const SERVER_CONFIG = {
  competitionAllowlist:
    envCompetitionAllowlist.length > 0
      ? envCompetitionAllowlist
      : DEFAULT_COMPETITION_ALLOWLIST,
  teamRankingDefaultSource:
    envTeamRankingDefaultSource || TEAM_RANKING_SOURCE_CLUBELO,
};

module.exports = {
  DEFAULT_COMPETITION_ALLOWLIST,
  TEAM_RANKING_SOURCE_CLUBELO,
  TEAM_RANKING_SOURCE_FOOTBALLDATABASE,
  normalizeTeamRankingSource,
  SERVER_CONFIG,
};
