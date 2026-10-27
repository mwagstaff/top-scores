"use strict";

const mappings = require("./opta_team_mappings.json");
const { OPTA_SOURCE } = require("./fetch_opta_rankings");

// Preserve every word and reserve/youth suffix; the legacy canonical aliases are
// too broad for a worldwide catalogue (e.g. Inter Club d'Escaldes != Inter Milan).
function optaNameKey(name) {
  return String(name || "").normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
    .toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
}
const mappedIds = new Map(Object.entries(mappings).map(([name, id]) => [optaNameKey(name), id]));

function buildOptaIndex(teams) {
  const byId = new Map();
  const byName = new Map();
  const byAlias = new Map();
  const add = (index, name, team) => {
    const key = optaNameKey(name);
    if (!key) return;
    if (!index.has(key)) index.set(key, new Map());
    index.get(key).set(team.OptaId, team);
  };
  for (const team of teams) {
    if (team.Source !== OPTA_SOURCE) continue;
    byId.set(team.OptaId, team);
    add(byName, team.Club, team);
    for (const alias of team.OptaAliases || []) add(byAlias, alias, team);
  }
  return { byId, byName, byAlias };
}

function findOptaMatch(name, index) {
  const key = optaNameKey(name);
  const id = mappedIds.get(key);
  if (id) {
    const team = index.byId.get(id) || null;
    return { team, accepted: Boolean(team), confidence: team ? 1 : 0, method: "opta_explicit_id" };
  }
  // An ambiguous primary name must not fall through to a weaker alias.
  const candidates = index.byName.get(key) || index.byAlias.get(key);
  const team = candidates?.size === 1 ? candidates.values().next().value : null;
  return { team, accepted: Boolean(team), confidence: team ? 1 : 0,
    method: team ? "opta_exact" : candidates ? "opta_ambiguous" : "opta_unmatched" };
}

module.exports = { optaNameKey, buildOptaIndex, findOptaMatch };
