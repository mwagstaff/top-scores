const NOTIFICATION_RIVALRIES = Object.freeze({
  "el-clasico": ["barcelona", "real-madrid"],
  "old-firm": ["celtic", "rangers"],
  "der-klassiker": ["bayern-munich", "borussia-dortmund"],
  "derby-della-madonnina": ["inter", "ac-milan"],
  "le-classique": ["paris-saint-germain", "marseille"],
});

// Server-owned bindings let older apps keep their display selectors without
// ever using those names to decide whether a fixture belongs to a club.
function bsdTeamID(value) {
  const id = String(value ?? "").trim();
  return /^[1-9][0-9]*$/.test(id) ? id : null;
}

function slug(value) {
  return String(value || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .toLowerCase().replace(/&/g, " and ").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

function buildNotificationTeamRegistry(teams = []) {
  const primary = new Map();
  const aliases = new Map();
  const ids = new Set();
  const premierLeagueIDs = new Set();
  const add = (map, key, team) => {
    if (!key) return;
    const entries = map.get(key) || [];
    entries.push(team);
    map.set(key, entries);
  };
  for (const team of teams) {
    add(primary, team.id, team);
    for (const name of [team.name, ...(team.aliases || [])]) add(aliases, slug(name), team);
    const sourceIDs = [...new Set((team.source_team_ids || []).map(bsdTeamID).filter(Boolean))];
    sourceIDs.forEach((id) => ids.add(id));
    if (sourceIDs.length === 1 && (team.competition_ids || []).includes("premier-league")) {
      premierLeagueIDs.add(sourceIDs[0]);
    }
  }
  function resolve(selector) {
    if (selector.startsWith("bsd:")) {
      const id = bsdTeamID(selector.slice(4));
      return id && ids.has(id) ? { id } : { reason: "unknown_bsd_team_id" };
    }
    // Canonical catalogue selectors take precedence over search aliases.
    const entries = primary.get(selector) || aliases.get(slug(selector)) || [];
    if (entries.length === 0) return { reason: "unknown_legacy_team" };
    const candidates = new Set(entries.flatMap((team) => team.source_team_ids || []).map(bsdTeamID).filter(Boolean));
    if (entries.some((team) => !(team.source_team_ids || []).length) || candidates.size !== 1) {
      return { reason: "ambiguous_or_missing_bsd_team_id" };
    }
    return { id: [...candidates][0] };
  }
  return { resolve, premierLeagueIDs };
}

function selectedTeamSelectors(preferences = {}) {
  const options = [
    ...(Array.isArray(preferences.selectedNotificationViewOptionIDs) ? preferences.selectedNotificationViewOptionIDs : []),
    ...(Array.isArray(preferences.selectedFixtureViewOptionIDs) ? preferences.selectedFixtureViewOptionIDs : []),
    ...(Array.isArray(preferences.favouriteFixtureViewOptionIDs) ? preferences.favouriteFixtureViewOptionIDs : []),
  ];
  return [...new Set(options.flatMap((id) => {
    if (typeof id !== "string") return [];
    if (id.startsWith("team:")) return [id.slice(5)];
    if (id.startsWith("rivalry:")) return NOTIFICATION_RIVALRIES[id.slice(8)] || [];
    return [];
  }))].sort();
}

function migrateNotificationTeamSubscriptions(user, registry) {
  const previous = user.notificationTeamSubscriptions?.version === 1
    ? user.notificationTeamSubscriptions.bindings || {} : {};
  const bindings = {};
  const unresolved = {};
  for (const selector of selectedTeamSelectors(user.preferences)) {
    // A previously resolved subscription must not drift when names/catalogues change.
    const existingID = bsdTeamID(previous[selector]);
    const resolved = existingID ? { id: existingID } : registry.resolve(selector);
    if (resolved.id) bindings[selector] = resolved.id;
    else unresolved[selector] = resolved.reason;
  }
  return { version: 1, provider: "bsd", bindings, unresolved };
}

function matchHasBSDTeam(match, teamIDs) {
  return [match?.home_team_id, match?.away_team_id]
    .some((value) => { const id = bsdTeamID(value); return id && teamIDs.has(id); });
}

module.exports = { NOTIFICATION_RIVALRIES, bsdTeamID, buildNotificationTeamRegistry, migrateNotificationTeamSubscriptions, matchHasBSDTeam };
