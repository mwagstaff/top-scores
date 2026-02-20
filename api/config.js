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

function parseCsvEnv(value) {
  if (!value) return [];
  return String(value)
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

const envCompetitionAllowlist = parseCsvEnv(process.env.COMPETITION_ALLOWLIST);

const SERVER_CONFIG = {
  competitionAllowlist:
    envCompetitionAllowlist.length > 0
      ? envCompetitionAllowlist
      : DEFAULT_COMPETITION_ALLOWLIST,
};

module.exports = {
  DEFAULT_COMPETITION_ALLOWLIST,
  SERVER_CONFIG,
};
