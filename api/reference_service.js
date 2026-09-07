"use strict";

const { createHash } = require("crypto");
const { BSD_LEAGUE_ALLOWLIST } = require("./bsd_config");
const { createReferenceStore } = require("./reference_store");
const { DAY_MS } = require("./reference_model");

function apiError(status, code, message) { return Object.assign(new Error(message), { status, code }); }
function buildCatalogue({ manifests, rows, statuses }, competitionIds) {
  const competitions = new Map();
  const teams = new Map();
  const players = new Map();
  const bySnapshot = new Map();
  for (const row of rows) {
    if (!bySnapshot.has(row.snapshot_id)) bySnapshot.set(row.snapshot_id, []);
    bySnapshot.get(row.snapshot_id).push(row.payload);
  }
  for (const manifest of manifests) {
    const records = bySnapshot.get(manifest.snapshot_id) || [];
    if (records.length !== manifest.team_count || new Set(records.map((row) => row.team.id)).size !== records.length) {
      throw new Error(`Incomplete saved snapshot for competition ${manifest.competition.id}`);
    }
    records.sort((a, b) => a.team.id.localeCompare(b.team.id));
    competitions.set(manifest.competition.id, { ...manifest, records });
    for (const record of records) {
      const existing = teams.get(record.team.id);
      if (!existing || record.squad.updated_at > existing.squad.updated_at) teams.set(record.team.id, record);
      for (const entry of record.squad.players) {
        const previous = players.get(entry.player_id);
        if (!previous || entry.player.updated_at > previous.updated_at) players.set(entry.player_id, entry.player);
      }
    }
  }
  const version = createHash("sha256").update(JSON.stringify(manifests.map((m) => [m.competition.id, m.snapshot_id]).sort())).digest("hex").slice(0, 24);
  return { competitions, teams, players, version, competitionIds, statuses: new Map(statuses.map((row) => [row._id, row.payload])) };
}

function createReferenceService({ store = createReferenceStore(), competitionIds = BSD_LEAGUE_ALLOWLIST, now = Date.now, cacheMs = 60_000 } = {}) {
  const ids = [...new Set(competitionIds.map(String))];
  let cached = null;
  let loadedAt = -Infinity;
  let pending = null;
  let unavailable = false;
  function reload() {
    if (pending) return pending;
    pending = store.load(ids).then((value) => {
      cached = buildCatalogue(value, ids);
      unavailable = false;
      return cached;
    }).catch((error) => {
      unavailable = true;
      if (!cached) throw apiError(503, "data_unavailable", "Reference data is temporarily unavailable.");
      console.warn(`[reference] keeping cached catalogue: ${error.message}`);
      return cached;
    }).finally(() => { loadedAt = now(); pending = null; });
    return pending;
  }
  async function catalogue() {
    if (!cached) return reload();
    if (now() - loadedAt >= cacheMs) void reload();
    return cached;
  }
  function metadata(catalogue, competition = null) {
    const dates = competition ? [competition.published_at] : [...catalogue.competitions.values()].map((value) => value.published_at);
    const oldest = dates.sort()[0] || null;
    return {
      catalogue_version: catalogue.version, snapshot_id: competition?.snapshot_id || null,
      updated_at: oldest, stale: unavailable || !oldest || now() - Date.parse(oldest) > 2 * DAY_MS,
    };
  }
  function coverage(catalogue) {
    return ids.map((competitionId) => {
      const value = catalogue.competitions.get(competitionId);
      const status = catalogue.statuses.get(competitionId);
      const records = value?.records || [];
      return {
        competition_id: competitionId, status: value ? "available" : "not_collected",
        snapshot_id: value?.snapshot_id || null, updated_at: value?.published_at || null,
        stale: value ? metadata(catalogue, value).stale : true,
        last_attempt_at: status?.attempted_at || null, last_attempt_status: status?.status || null,
        team_count: records.length, player_count: value?.player_count || 0,
        empty_squad_team_ids: records.filter((row) => row.squad.status === "empty").map((row) => row.team.id),
        placeholder_team_ids: records.filter((row) => row.team.is_placeholder).map((row) => row.team.id),
        missing_colour_team_ids: records.filter((row) => row.team.colours.is_fallback).map((row) => row.team.id),
        missing_rating_player_ids: [...new Set(records.flatMap((row) => row.squad.players.filter((entry) => entry.player.rating === null).map((entry) => entry.player_id)))].sort(),
      };
    });
  }
  function competition(catalogue, competitionId, seasonId) {
    if (!ids.includes(competitionId)) throw apiError(404, "not_found", "Competition is not covered by Top Scores.");
    const value = catalogue.competitions.get(competitionId);
    if (!value) throw apiError(503, "not_collected", "This competition has not completed its first reference refresh. See /coverage.");
    if (seasonId && seasonId !== value.competition.current_season.id) {
      throw apiError(400, "unsupported_season", "Only the published current season is available. Squads always describe current membership.");
    }
    return value;
  }
  return { catalogue, metadata, coverage, competition, reload };
}

module.exports = { createReferenceService, apiError, buildCatalogue };
