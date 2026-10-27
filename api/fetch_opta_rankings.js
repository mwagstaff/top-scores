"use strict";

const DEFAULT_OPTA_URL = "https://dataviz.theanalyst.com/opta-power-rankings/index.js";
const OPTA_SOURCE = "Opta Power Rankings";
const OPTA_SCORE_MODEL = "opta-compat-v1";
const PREMIER_LEAGUE_ID = "2kwbbcootiqqgmrzs6o5inle5";
const HOME_COUNTRIES = { England: "ENG", Scotland: "SCO", Wales: "WAL", "Northern Ireland": "NIR", Ireland: "IRL", "Republic of Ireland": "IRL" };

// A fixed approximation calibrated against the October 2026 Club Elo overlap.
// This is a compatibility score for existing consumers, NOT an Elo rating.
function compatibilityScore(rating) {
  return Math.round(Math.max(0, 21 * rating - 85) * 100) / 100;
}

function parseOptaRankings(script, { minRows = 10000, now = Date.now() } = {}) {
  const dates = [...script.matchAll(/(?:const\s+|,)([$\w]+)\s*=\s*"([A-Z][a-z]{2} \d{1,2}, \d{4})"\s*,\s*[$\w]+\s*=\s*\{lastUpdated:\1\}/g)];
  if (dates.length !== 1) throw new Error("Opta publication date missing or ambiguous");
  const published = Date.parse(`${dates[0][2]} 00:00:00 GMT`);
  if (!Number.isFinite(published) || published > now + 86400000 || now - published > 7 * 86400000) {
    throw new Error("Opta publication date is stale or invalid");
  }
  const date = new Date(published).toISOString().slice(0, 10);
  const candidates = [];
  // Parse data literals only; never execute the downloaded JavaScript.
  for (const match of script.matchAll(/JSON\.parse\(`(\[\{"rank".*?\])`\)/gs)) {
    const rows = JSON.parse(match[1]);
    // The men's Premier League identifier disambiguates the women's dataset.
    if (rows.some((row) => row.leagueId === PREMIER_LEAGUE_ID)) candidates.push(rows);
  }
  if (candidates.length !== 1) throw new Error("Opta men's rankings missing or ambiguous");
  const seen = new Set();
  const teams = [];
  for (const row of candidates[0]) {
    if (typeof row.contestantId !== "string" || !row.contestantId || seen.has(row.contestantId)) {
      throw new Error("Invalid or duplicate Opta contestant ID");
    }
    seen.add(row.contestantId);
    if (typeof row.currentRating !== "number" || !Number.isFinite(row.currentRating) || row.currentRating < 0 || row.currentRating > 100 || !Number.isInteger(row.rank) || row.rank < 1) {
      throw new Error("Invalid Opta rating or rank");
    }
    const name = String(row.contestantName || "").trim();
    if (!name) continue; // Opta itself omits unnamed contestants from the dashboard.
    teams.push({
      Name: name, Club: name, Rank: row.rank,
      Country: HOME_COUNTRIES[row.country] || row.country || null,
      Level: null, Elo: compatibilityScore(row.currentRating), From: date, To: date,
      Source: OPTA_SOURCE, RatingModel: OPTA_SCORE_MODEL,
      OptaRating: row.currentRating, OptaId: row.contestantId,
      OptaAliases: [...new Set([name, row.contestantShortName, row.contestantClubName].filter(Boolean))],
      OptaLeague: row.league || null,
    });
  }
  if (teams.length < minRows) throw new Error(`Opta dataset too small: ${teams.length} < ${minRows}`);
  return { teams, date };
}

async function fetchOptaRankings({ url = DEFAULT_OPTA_URL, minRows = 10000, now = Date.now(), fetchImpl = fetch } = {}) {
  const response = await fetchImpl(url, { signal: AbortSignal.timeout(45000) });
  if (!response.ok) throw new Error(`Opta HTTP ${response.status}`);
  const maxBytes = 40 * 1024 * 1024;
  const chunks = [];
  let byteLength = 0;
  for await (const chunk of response.body) {
    byteLength += chunk.length;
    if (byteLength > maxBytes) throw new Error("Opta response exceeds 40 MiB");
    chunks.push(Buffer.from(chunk));
  }
  const result = parseOptaRankings(Buffer.concat(chunks).toString("utf8"), { minRows, now });
  return { ...result, url, byteLength, contentType: response.headers.get("content-type") };
}

module.exports = { DEFAULT_OPTA_URL, OPTA_SOURCE, OPTA_SCORE_MODEL, compatibilityScore, parseOptaRankings, fetchOptaRankings };
