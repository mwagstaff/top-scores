"use strict";

const { getLeagueTeams } = require("./thesportsdb_client");
const { TSDB_TRACKED_LEAGUE_IDS } = require("./thesportsdb_leagues");

/**
 * Normalise a TSDB colour value (strColour1/strColour2) to a `#RRGGBB` hex
 * string, or null when absent/invalid. TSDB returns values like "#0000FF",
 * "0000FF", "" or null.
 */
function normalizeHexColor(value) {
  const trimmed = String(value || "").trim();
  if (!trimmed) return null;
  const withHash = trimmed.startsWith("#") ? trimmed : `#${trimmed}`;
  return /^#[0-9A-Fa-f]{6}$/.test(withHash) ? withHash.toUpperCase() : null;
}

/**
 * Fetch badge metadata for every team across all tracked leagues.
 *
 * Returns a Map keyed by idTeam (string) with values:
 *   { idTeam, name, badgeUrl, primaryColor, secondaryColor, leagueIds: [idLeague, ...] }
 *
 * Teams that appear in multiple leagues are deduplicated; their leagueIds list
 * accumulates every league they're seen in.
 */
async function fetchTeamBadges(options = {}) {
  const trigger = options.trigger || "scheduled";
  const byTeamId = new Map();

  for (const idLeague of TSDB_TRACKED_LEAGUE_IDS) {
    let data;
    try {
      data = await getLeagueTeams(idLeague, {
        initiator: "badges_collector",
        reason: "team_badges_fetch",
        trigger,
      });
    } catch (err) {
      console.warn(
        `[TeamBadges] Failed to fetch league ${idLeague}:`,
        err.message || err
      );
      continue;
    }

    const teams = Array.isArray(data && data.list) ? data.list : [];
    for (const team of teams) {
      const idTeam = String(team.idTeam || "").trim();
      if (!idTeam) continue;

      const badgeUrl = String(team.strBadge || "").trim() || null;
      if (!badgeUrl) continue;

      if (byTeamId.has(idTeam)) {
        byTeamId.get(idTeam).leagueIds.push(idLeague);
      } else {
        byTeamId.set(idTeam, {
          idTeam,
          name: String(team.strTeam || "").trim(),
          badgeUrl,
          primaryColor: normalizeHexColor(team.strColour1),
          secondaryColor: normalizeHexColor(team.strColour2),
          leagueIds: [idLeague],
        });
      }
    }
  }

  return byTeamId;
}

/**
 * Serialise the badge map to the plain object stored in the operational
 * dataset and returned by the /teams/badges endpoint.
 *
 * Shape: { "<idTeam>": { name, badge_url, color_primary, color_secondary }, ... }
 */
function badgeMapToPayload(byTeamId) {
  const teams = {};
  for (const [idTeam, entry] of byTeamId) {
    teams[idTeam] = {
      name: entry.name,
      badge_url: entry.badgeUrl,
      color_primary: entry.primaryColor ?? null,
      color_secondary: entry.secondaryColor ?? null,
    };
  }
  return teams;
}

module.exports = { fetchTeamBadges, badgeMapToPayload, normalizeHexColor };
