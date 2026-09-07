"use strict";

const { normalizePlayer, normalizeTeam, normalizeCompetition, createColourResolver } = require("./reference_model");

const time = "2026-09-07T06:00:00.000Z";
const rawPlayer = (id = 363, rating = 78) => ({
  id, name: id === 363 ? "Joe Rodon" : `Player ${id}`, short_name: "J. Rodon", rating,
  attributes: { attacking: 5, technical: 12, tactical: 14, defending: 15, creativity: null, position: "Centre Back" },
  current_team_id: 19, national_team_id: 727, market_value_eur: 18000000,
  jersey_number: 6, position: "D", nationality: "Wales", date_of_birth: "1997-10-22", preferred_foot: "R",
});
const rawLeague = (id = 1) => ({ id, name: `Competition ${id}`, current_season: { id: 100 + id, name: "2026/27", year: 2026 }, country: "England", is_women: false, is_active: true });
const rawTeam = (id = 19) => ({ id, name: id === 19 ? "Leeds United" : "Wales", short_name: id === 19 ? "Leeds" : "Wales", country: id === 19 ? "England" : "Wales" });
function dataset() {
  const colours = createColourResolver({ teams: [{ name: "Leeds United", primary: "#ffffff", secondary: "#ffff00" }] });
  const player = normalizePlayer(rawPlayer(), time);
  const record = { team: normalizeTeam(rawTeam(), time, colours), squad: { team_id: "19", status: "available", count: 1, updated_at: time, players: [{ player_id: "363", jersey_number: 6, player }] } };
  return {
    manifests: [{ competition: normalizeCompetition(rawLeague(), time), snapshot_id: "snapshot-1", published_at: time, team_count: 1, player_count: 1 }],
    rows: [{ snapshot_id: "snapshot-1", payload: record }],
    statuses: [{ _id: "1", payload: { attempted_at: time, status: "succeeded" } }],
  };
}
function memoryStore(initial = { manifests: [], rows: [], statuses: [] }) {
  const state = structuredClone(initial);
  const sources = [];
  let owner = null;
  return {
    state, sources,
    async ensureIndexes() {},
    async acquireLease(value) { if (owner) return false; owner = value; return true; },
    async renewLease(value) { return owner === value; },
    async releaseLease(value) { if (owner === value) owner = null; },
    async load() {
      const active = new Set(state.manifests.map((value) => value.snapshot_id));
      return structuredClone({ ...state, rows: state.rows.filter((row) => active.has(row.snapshot_id)) });
    },
    async saveSources(collection, records) { sources.push({ collection, records: structuredClone(records) }); },
    async publish(manifest, records) {
      state.rows.push(...records.map((payload) => ({ snapshot_id: manifest.snapshot_id, payload: structuredClone(payload) })));
      state.manifests = state.manifests.filter((value) => value.competition.id !== manifest.competition.id);
      state.manifests.push(structuredClone(manifest));
    },
    async recordAttempt(id, payload) {
      state.statuses = state.statuses.filter((value) => value._id !== String(id));
      state.statuses.push({ _id: String(id), payload: structuredClone(payload) });
    },
    async prune() {},
  };
}

module.exports = { time, rawPlayer, rawLeague, rawTeam, dataset, memoryStore };
