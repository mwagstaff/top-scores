const MAJOR_CLUB_DERBIES = require("./major_club_derbies.json");

const MAJOR_UEFA_CLUB_COMPETITIONS = new Set([
  "uefa champions league",
  "uefa europa league",
  "uefa conference league",
]);

function normalizeMajorGameText(value) {
  return String(value || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/&/g, " and ")
    .replace(/['’]/g, "")
    .replace(/[._]/g, " ")
    .replace(/[‐‑‒–—]/g, "-")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function normalizeTeam(value) {
  return normalizeMajorGameText(value)
    .replace(/\bfc\b/g, "")
    .replace(/\bcf\b/g, "")
    .replace(/\bthe\b/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeCompetition(value) {
  return normalizeMajorGameText(value)
    .replace(/\b(?:quarter|semi)-?finals?.*$/i, "")
    .replace(/\bfinal\b.*$/i, "")
    .replace(/\s+/g, " ")
    .trim();
}

function majorGameDescriptor(match) {
  return [
    match && match.league,
    match && match.league_subcategory,
    match && match.display_league,
  ]
    .map(normalizeMajorGameText)
    .filter(Boolean)
    .join(" ")
    .trim();
}

function matchIsMajorUefaClubKnockoutFixture(match) {
  if (!match) return false;

  const normalizedLeague = normalizeCompetition(match.league);
  const descriptor = majorGameDescriptor(match);
  const isMajorUefaCompetition = Array.from(MAJOR_UEFA_CLUB_COMPETITIONS).some(
    (competition) => normalizedLeague === competition || normalizedLeague.startsWith(`${competition} `)
  );

  if (!isMajorUefaCompetition || !descriptor) {
    return false;
  }

  return /\b(?:quarter(?:\s*-\s*|\s)?finals?|semi(?:\s*-\s*|\s)?finals?|final)\b/i.test(descriptor);
}

function matchIsPromotionPlayoff(match) {
  if (!match) return false;
  return majorGameDescriptor(match).includes("promotion play-offs");
}

function normalizeDerbyPair(entry) {
  const teams = entry && Array.isArray(entry.teams) ? entry.teams : [];
  if (teams.length !== 2) return null;

  const home = normalizeTeam(teams[0]);
  const away = normalizeTeam(teams[1]);
  if (!home || !away) return null;

  return { home, away };
}

const NORMALIZED_MAJOR_CLUB_DERBIES = MAJOR_CLUB_DERBIES.map(normalizeDerbyPair).filter(Boolean);

function matchIsMajorClubDerby(match) {
  if (!match) return false;

  const home = normalizeTeam(match.home_team || match.homeTeam);
  const away = normalizeTeam(match.away_team || match.awayTeam);
  if (!home || !away) return false;

  return NORMALIZED_MAJOR_CLUB_DERBIES.some(
    (derby) =>
      (home === derby.home && away === derby.away) ||
      (home === derby.away && away === derby.home)
  );
}

function matchIsMajorGameOfInterest(match) {
  return (
    matchIsMajorUefaClubKnockoutFixture(match) ||
    matchIsPromotionPlayoff(match) ||
    matchIsMajorClubDerby(match)
  );
}

module.exports = {
  MAJOR_CLUB_DERBIES,
  matchIsMajorClubDerby,
  matchIsMajorGameOfInterest,
  matchIsMajorUefaClubKnockoutFixture,
  matchIsPromotionPlayoff,
};
