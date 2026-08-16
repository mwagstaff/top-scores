"use strict";

const {
  canonicalTeamName,
  normalizeTeamIdentityName,
  teamIdentityNames,
} = require("./team_identity");

const LEGACY_PREFERRED_TEAM_IDS = new Set([
  "real-madrid",
  "barcelona",
  "celtic",
  "rangers",
  "bayern-munich",
  "borussia-dortmund",
  "inter",
  "ac-milan",
  "juventus",
  "paris-saint-germain",
  "marseille",
]);

// A club can appear in historical events from several tiers, but it can only
// belong to one domestic league in a pyramid for the active season. Cups and
// continental competitions remain additive.
const EXCLUSIVE_DOMESTIC_LEAGUE_GROUPS = [
  ["premier-league", "championship", "league-one", "league-two"],
  [
    "scottish-premiership",
    "scottish-championship",
    "scottish-league-one",
    "scottish-league-two",
  ],
];

const NON_MEMBERSHIP_MATCH_STATUSES = new Set([
  "abandoned",
  "canceled",
  "cancelled",
  "postponed",
]);

function normalizedSearchValue(value) {
  return normalizeTeamIdentityName(value)
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function stableSlug(value) {
  return normalizedSearchValue(value).replace(/\s+/g, "-");
}

function preferredStableTeamId(names) {
  const slugs = Array.from(
    new Set((Array.isArray(names) ? names : []).map(stableSlug).filter(Boolean))
  );
  return slugs.find((slug) => LEGACY_PREFERRED_TEAM_IDS.has(slug)) || slugs[0] || null;
}

function competitionLookup(competitions) {
  const lookup = new Map();
  (Array.isArray(competitions) ? competitions : []).forEach((competition) => {
    if (!competition || !competition.id) return;
    [competition.name, ...(Array.isArray(competition.aliases) ? competition.aliases : [])]
      .map(normalizedSearchValue)
      .filter(Boolean)
      .forEach((name) => lookup.set(name, competition));
  });
  return lookup;
}

function normalizedMatchDate(value) {
  const match = String(value || "").match(/^\d{4}-\d{2}-\d{2}/);
  return match ? match[0] : null;
}

function matchProvidesCompetitionMembership(match) {
  const status = String((match && (match.score_status || match.status)) || "")
    .trim()
    .toLowerCase();
  return !NON_MEMBERSHIP_MATCH_STATUSES.has(status);
}

function recordCompetitionActivity(entry, competitionID, matchDate) {
  const activity = entry.competitionActivity.get(competitionID) || {
    latestDate: null,
    matchCount: 0,
  };
  const normalizedDate = normalizedMatchDate(matchDate);
  if (normalizedDate && (!activity.latestDate || normalizedDate > activity.latestDate)) {
    activity.latestDate = normalizedDate;
  }
  activity.matchCount += 1;
  entry.competitionActivity.set(competitionID, activity);
}

function resolveCurrentDomesticLeagueMembership(entry, competitionByID) {
  EXCLUSIVE_DOMESTIC_LEAGUE_GROUPS.forEach((orderedLeagueIDs) => {
    const memberships = orderedLeagueIDs.filter((id) => entry.competitionIDs.has(id));
    if (memberships.length <= 1) return;

    memberships.sort((left, right) => {
      const leftIsAuthoritative = entry.authoritativeCompetitionIDs.has(left);
      const rightIsAuthoritative = entry.authoritativeCompetitionIDs.has(right);
      if (leftIsAuthoritative !== rightIsAuthoritative) {
        return leftIsAuthoritative ? -1 : 1;
      }
      const leftActivity = entry.competitionActivity.get(left) || {};
      const rightActivity = entry.competitionActivity.get(right) || {};
      const leftDate = leftActivity.latestDate || "";
      const rightDate = rightActivity.latestDate || "";
      if (leftDate !== rightDate) return rightDate.localeCompare(leftDate);
      if (leftActivity.matchCount !== rightActivity.matchCount) {
        return (rightActivity.matchCount || 0) - (leftActivity.matchCount || 0);
      }
      return orderedLeagueIDs.indexOf(left) - orderedLeagueIDs.indexOf(right);
    });

    memberships.slice(1).forEach((competitionID) => {
      entry.competitionIDs.delete(competitionID);
      const competition = competitionByID.get(competitionID);
      if (competition) entry.competitionNames.delete(String(competition.name));
    });
  });
}

function isPlaceholderTeamName(value) {
  const name = String(value || "").trim();
  if (!name || /^tbc$/i.test(name) || name.includes("/")) return true;
  if (/^[WL]\d+$/i.test(name)) return true;
  if (/^\d[A-Za-z]$/.test(name)) return true;
  return /^[A-Za-z]\d+$/.test(name) && name.length <= 3;
}

function buildTeamCatalog(matches, competitions, options = {}) {
  const competitionsByName = competitionLookup(competitions);
  const competitionByID = new Map(
    (Array.isArray(competitions) ? competitions : [])
      .filter((competition) => competition && competition.id)
      .map((competition) => [String(competition.id), competition])
  );
  const teamsByIdentity = new Map();

  const upsert = (rawName, sourceTeamId, competition, matchDate, authoritative = false) => {
    const trimmed = String(rawName || "").replace(/\s+/g, " ").trim();
    if (isPlaceholderTeamName(trimmed)) return;

    const canonicalName = canonicalTeamName(trimmed) || trimmed;
    const identityNames = Array.from(
      new Set([canonicalName, trimmed, ...teamIdentityNames(canonicalName)].filter(Boolean))
    );
    const identityKey = stableSlug(canonicalName);
    if (!identityKey) return;

    let entry = teamsByIdentity.get(identityKey);
    if (!entry) {
      entry = {
        id: preferredStableTeamId(identityNames) || identityKey,
        name: canonicalName,
        aliases: new Set(),
        competitionIDs: new Set(),
        competitionNames: new Set(),
        sourceTeamIDs: new Set(),
        competitionActivity: new Map(),
        authoritativeCompetitionIDs: new Set(),
      };
      teamsByIdentity.set(identityKey, entry);
    }

    identityNames.forEach((name) => {
      if (normalizedSearchValue(name) !== normalizedSearchValue(entry.name)) {
        entry.aliases.add(name);
      }
    });
    if (sourceTeamId !== undefined && sourceTeamId !== null && String(sourceTeamId).trim()) {
      entry.sourceTeamIDs.add(String(sourceTeamId).trim());
    }
    if (competition) {
      const competitionID = String(competition.id);
      entry.competitionIDs.add(competitionID);
      entry.competitionNames.add(String(competition.name));
      if (authoritative) {
        entry.authoritativeCompetitionIDs.add(competitionID);
      } else {
        recordCompetitionActivity(entry, competitionID, matchDate);
      }
    }
  };

  (Array.isArray(matches) ? matches : []).forEach((match) => {
    if (!match || typeof match !== "object") return;
    const competition = competitionsByName.get(normalizedSearchValue(match.league));
    if (!competition) return;
    const membershipCompetition = matchProvidesCompetitionMembership(match)
      ? competition
      : null;
    upsert(match.home_team, match.home_team_id, membershipCompetition, match.date);
    upsert(match.away_team, match.away_team_id, membershipCompetition, match.date);
  });

  const authoritativeCompetitionTeams =
    options.authoritativeCompetitionTeams &&
    typeof options.authoritativeCompetitionTeams === "object"
      ? options.authoritativeCompetitionTeams
      : {};
  Object.entries(authoritativeCompetitionTeams).forEach(([competitionID, teamNames]) => {
    const competition = competitionByID.get(String(competitionID));
    if (!competition || !Array.isArray(teamNames)) return;
    teamNames.forEach((teamName) => {
      upsert(teamName, null, competition, null, true);
    });
  });

  return Array.from(teamsByIdentity.values())
    .filter((entry) => entry.competitionIDs.size > 0)
    .map((entry) => {
      resolveCurrentDomesticLeagueMembership(entry, competitionByID);
      return {
        id: entry.id,
        name: entry.name,
        aliases: Array.from(entry.aliases).sort(compareInsensitive),
        competition_ids: Array.from(entry.competitionIDs).sort(compareInsensitive),
        competition_names: Array.from(entry.competitionNames).sort(compareInsensitive),
        source_team_ids: Array.from(entry.sourceTeamIDs).sort(compareInsensitive),
      };
    })
    .sort((left, right) => compareInsensitive(left.name, right.name));
}

function buildTeamCatalogIndex(teams) {
  const byID = new Map();
  (Array.isArray(teams) ? teams : []).forEach((team) => {
    if (!team || !team.id) return;
    const ids = new Set([
      String(team.id),
      stableSlug(team.name),
      ...(Array.isArray(team.aliases) ? team.aliases.map(stableSlug) : []),
    ]);
    ids.forEach((id) => {
      if (id && !byID.has(id)) byID.set(id, team);
    });
  });
  return byID;
}

function searchRank(team, query) {
  const normalizedQuery = normalizedSearchValue(query);
  const values = [team.name, ...(Array.isArray(team.aliases) ? team.aliases : [])]
    .map(normalizedSearchValue)
    .filter(Boolean);
  if (values.some((value) => value === normalizedQuery)) return 0;
  if (values.some((value) => value.startsWith(normalizedQuery))) return 1;
  if (values.some((value) => value.split(" ").some((token) => token.startsWith(normalizedQuery)))) {
    return 2;
  }
  if (values.some((value) => value.includes(normalizedQuery))) return 3;
  return null;
}

function filterTeamCatalog(teams, options = {}) {
  const query = normalizedSearchValue(options.query);
  const competitionID = String(options.competitionID || "").trim();
  const requestedIDs = new Set(
    (Array.isArray(options.ids) ? options.ids : [])
      .map((value) => String(value || "").trim())
      .filter(Boolean)
  );
  const index = buildTeamCatalogIndex(teams);

  let candidates;
  if (requestedIDs.size > 0) {
    candidates = Array.from(requestedIDs).map((id) => index.get(id)).filter(Boolean);
  } else {
    candidates = Array.isArray(teams) ? teams.slice() : [];
  }

  if (competitionID) {
    candidates = candidates.filter(
      (team) => Array.isArray(team.competition_ids) && team.competition_ids.includes(competitionID)
    );
  }

  if (query) {
    candidates = candidates
      .map((team) => ({ team, rank: searchRank(team, query) }))
      .filter((candidate) => candidate.rank !== null)
      .sort((left, right) => {
        if (left.rank !== right.rank) return left.rank - right.rank;
        return compareInsensitive(left.team.name, right.team.name);
      })
      .map((candidate) => candidate.team);
  } else {
    candidates.sort((left, right) => compareInsensitive(left.name, right.name));
  }

  const deduped = [];
  const seen = new Set();
  candidates.forEach((team) => {
    if (!team || seen.has(team.id)) return;
    seen.add(team.id);
    deduped.push(team);
  });
  return deduped;
}

function compareInsensitive(left, right) {
  return String(left || "").localeCompare(String(right || ""), undefined, {
    sensitivity: "base",
  });
}

module.exports = {
  buildTeamCatalog,
  buildTeamCatalogIndex,
  filterTeamCatalog,
  normalizedSearchValue,
  preferredStableTeamId,
  stableSlug,
};
