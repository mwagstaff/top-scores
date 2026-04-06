const fs = require("fs");
const path = require("path");

const COMPETITION_WEIGHTS_PATH = path.resolve(__dirname, "./competition_weights.json");

function loadCompetitionWeightsConfig() {
  try {
    const raw = fs.readFileSync(COMPETITION_WEIGHTS_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("Competition weights config must be a JSON object map.");
    }

    const normalized = {};
    Object.entries(parsed).forEach(([name, value]) => {
      if (typeof name !== "string" || !name.trim()) return;
      const weight = Number(value);
      if (!Number.isFinite(weight)) return;
      normalized[name.trim()] = weight;
    });
    return normalized;
  } catch (error) {
    console.error("[config] Failed to load competition weights config:", error);
    return {};
  }
}

const DEFAULT_COMPETITION_WEIGHTS = loadCompetitionWeightsConfig();
const DEFAULT_COMPETITION_ALLOWLIST = Object.keys(DEFAULT_COMPETITION_WEIGHTS);
const COMPETITION_WEIGHTS_UPDATED_AT = (() => {
  try {
    return fs.statSync(COMPETITION_WEIGHTS_PATH).mtime.toISOString();
  } catch (_error) {
    return null;
  }
})();

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
  COMPETITION_WEIGHTS_PATH,
  DEFAULT_COMPETITION_WEIGHTS,
  COMPETITION_WEIGHTS_UPDATED_AT,
  DEFAULT_COMPETITION_ALLOWLIST,
  TEAM_RANKING_SOURCE_MERGED,
  TEAM_RANKING_SOURCE_CLUBELO,
  TEAM_RANKING_SOURCE_FOOTBALLDATABASE,
  TEAM_RANKING_SOURCE_NATIONAL_ELO,
  normalizeTeamRankingSource,
  loadCompetitionWeightsConfig,
  SERVER_CONFIG,
};
