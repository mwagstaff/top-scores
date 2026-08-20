#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// BSD <-> TSDB id mapping layer.
//
// We build a persistent map from BSD player id -> TSDB player id by pairing the
// two providers' line-ups for the SAME fixture. TSDB photo snapshots remain in
// the map temporarily so PLAYER_IMAGE_SOURCE=tsdb is a safe rollback path.
//
// The authoritative join is (side, jersey number): within one fixture, the two
// line-ups agree on squad numbers even when names are formatted very
// differently ("Vinícius Jr." vs "Vinícius Júnior", "Alisson" vs "Alisson
// Becker"). Names are used only as a CONTRADICTION guard — we reject a
// same-number pairing only when the BSD name clearly points to a
// different-numbered TSDB player (i.e. the numbers look shuffled), so we never
// attach the wrong player's face (strict mode).
//
// Also builds a lightweight BSD team id -> TSDB team id map (by canonical name).
// ---------------------------------------------------------------------------

const { canonicalTeamName } = require("./team_identity");
const { playerNamesMatchScore } = require("./player_name_match");
const { bsdEventToCanonicalMatch } = require("./bsd_adapter");
const {
  getBsdRecords,
  getMatchLineupCaches,
  getOperationalDataset,
  getOperationalMatchDetailsByDates,
  saveOperationalDataset,
  upsertBsdRecords,
  closeMongoConnection,
} = require("./mongo_client");

const PLAYER_MAP_STATE_DATASET = "bsd_player_map_state";
const INITIAL_LOOKBACK_DAYS = Number(process.env.BSD_MAP_INITIAL_LOOKBACK_DAYS || 14);

// A name match this strong at a DIFFERENT number means the squad numbers are
// misaligned between the two sources — reject rather than risk a wrong face.
const CONTRADICTION_NAME_SCORE = 3;

function compositeKey(match) {
  if (!match) return null;
  return [match.date, match.time, match.league, match.home_team, match.away_team].join("|");
}

// Pairs one side's BSD players against the matching TSDB lineup entries.
// `tsdbEntries` are the raw TSDB lineup rows for this side (strPlayer,
// intSquadNumber, idPlayer, strCutout/strThumb/strRender).
function pairSide(bsdPlayers, tsdbEntries) {
  const mappings = [];
  if (!Array.isArray(bsdPlayers) || !Array.isArray(tsdbEntries)) return mappings;

  const byNumber = new Map();
  tsdbEntries.forEach((entry) => {
    const num = String(entry.intSquadNumber || "").trim();
    if (num) byNumber.set(num, entry);
  });

  bsdPlayers.forEach((bsdPlayer) => {
    const bsdId = bsdPlayer && bsdPlayer.id != null ? String(bsdPlayer.id) : null;
    const number = String(bsdPlayer && bsdPlayer.jersey_number != null ? bsdPlayer.jersey_number : "").trim();
    const bsdName = String(bsdPlayer && bsdPlayer.name ? bsdPlayer.name : "").trim();
    if (!bsdId || !number) return;

    const candidate = byNumber.get(number);
    if (!candidate) return; // no same-number TSDB player

    const candidateScore = playerNamesMatchScore(bsdName, candidate.strPlayer);

    // Contradiction guard: does the BSD name match some OTHER-numbered TSDB
    // player more strongly? If so the numbers look shuffled — skip (no photo).
    let bestOtherScore = 0;
    tsdbEntries.forEach((entry) => {
      if (entry === candidate) return;
      const score = playerNamesMatchScore(bsdName, entry.strPlayer);
      if (score > bestOtherScore) bestOtherScore = score;
    });
    if (bestOtherScore >= CONTRADICTION_NAME_SCORE && bestOtherScore > candidateScore) return;

    const tsdbPlayerId = String(candidate.idPlayer || "").trim();
    if (!tsdbPlayerId || tsdbPlayerId === "0") return;

    mappings.push({
      id: bsdId,
      payload: {
        tsdb_player_id: tsdbPlayerId,
        name: String(candidate.strPlayer || "").trim() || null,
        cutout_url: String(candidate.strCutout || "").trim() || null,
        thumb_url: String(candidate.strThumb || "").trim() || null,
        render_url: String(candidate.strRender || "").trim() || null,
      },
      extra: { confidence: candidateScore, jersey_number: number },
    });
  });

  return mappings;
}

// Builds player mappings for a single fixture from the BSD lineup payload and
// the raw TSDB lineup entries (the `payload.lookup` array of match_lineups).
function buildFixturePlayerMappings(bsdLineupPayload, tsdbEntries) {
  const lineups = bsdLineupPayload && bsdLineupPayload.lineups;
  if (!lineups || !Array.isArray(tsdbEntries)) return [];
  const homeTsdb = tsdbEntries.filter((e) => String(e.strHome || "").toLowerCase() === "yes");
  const awayTsdb = tsdbEntries.filter((e) => String(e.strHome || "").toLowerCase() === "no");
  return [
    ...pairSide(lineups.home && lineups.home.players, homeTsdb),
    ...pairSide(lineups.away && lineups.away.players, awayTsdb),
  ];
}

// ---------------------------------------------------------------------------
// Orchestration (reads Mongo, writes the maps)
// ---------------------------------------------------------------------------

async function buildLeagueNameById() {
  const leagues = await getBsdRecords("bsd_leagues");
  const map = new Map();
  leagues.forEach((doc) => {
    const p = doc.payload || {};
    if (p.id != null && p.name) map.set(String(p.id), String(p.name));
  });
  return map;
}

// composite-key -> TSDB match_details_id, from the operational `matches` store.
async function buildCompositeToTsdbEventId(dates) {
  const records = await getOperationalMatchDetailsByDates(dates);
  const map = new Map();
  Object.entries(records).forEach(([id, payload]) => {
    const key = compositeKey(payload);
    if (key) map.set(key, id);
  });
  return map;
}

async function playerMapWatermark(options = {}) {
  if (options.full === true) return null;
  const state = await getOperationalDataset(PLAYER_MAP_STATE_DATASET);
  const stored = state && state.payload ? state.payload.last_lineup_updated_at : null;
  if (stored) return String(stored);

  const existingMap = await getBsdRecords(
    "bsd_tsdb_player_map",
    {},
    { projection: { updated_at: 1 }, sort: { updated_at: -1 }, limit: 1 }
  );
  if (existingMap[0] && existingMap[0].updated_at) return String(existingMap[0].updated_at);

  const lookbackMs = Math.max(1, INITIAL_LOOKBACK_DAYS) * 24 * 60 * 60 * 1000;
  return new Date(Date.now() - lookbackMs).toISOString();
}

async function buildPlayerMap(options = {}) {
  const queryStartedAt = new Date().toISOString();
  const watermark = await playerMapWatermark(options);
  const bsdLineups = await getBsdRecords(
    "bsd_lineups",
    watermark ? { updated_at: { $gt: watermark } } : {},
    { sort: { updated_at: 1 } }
  );
  if (bsdLineups.length === 0) {
    await saveOperationalDataset({
      name: PLAYER_MAP_STATE_DATASET,
      updated_at: queryStartedAt,
      source: "bsd_player_map",
      payload: { last_lineup_updated_at: queryStartedAt },
    });
    return { fixturesPaired: 0, mappingsTotal: 0, lineupsScanned: 0 };
  }

  const eventIds = bsdLineups.map((doc) => String(doc._id));
  const [bsdEvents, leagueNameById] = await Promise.all([
    getBsdRecords("bsd_events", { _id: { $in: eventIds } }),
    buildLeagueNameById(),
  ]);

  const canonicalByEventId = new Map();
  const matchDates = new Set();
  bsdEvents.forEach((doc) => {
    const canonical = bsdEventToCanonicalMatch(doc.payload, { leagueNameById });
    if (!canonical) return;
    canonicalByEventId.set(String(doc._id), canonical);
    if (canonical.date) matchDates.add(canonical.date);
  });
  const compositeToTsdb = await buildCompositeToTsdbEventId([...matchDates]);
  const tsdbIdByEventId = new Map();
  canonicalByEventId.forEach((canonical, eventId) => {
    const tsdbId = compositeToTsdb.get(compositeKey(canonical));
    if (tsdbId) tsdbIdByEventId.set(eventId, tsdbId);
  });
  const tsdbLineupsById = await getMatchLineupCaches([...tsdbIdByEventId.values()]);

  let fixturesPaired = 0;
  let mappingsTotal = 0;
  const allMappings = [];

  for (const lineupDoc of bsdLineups) {
    const bsdEventId = String(lineupDoc._id);
    const canonical = canonicalByEventId.get(bsdEventId);
    if (!canonical) continue;
    const tsdbEventId = tsdbIdByEventId.get(bsdEventId);
    if (!tsdbEventId) continue;

    const tsdbLineup = tsdbLineupsById[String(tsdbEventId)] || null;
    const entries =
      tsdbLineup && tsdbLineup.payload && Array.isArray(tsdbLineup.payload.lookup)
        ? tsdbLineup.payload.lookup
        : [];
    if (entries.length === 0) continue;

    const mappings = buildFixturePlayerMappings(lineupDoc.payload, entries);
    if (mappings.length > 0) {
      allMappings.push(...mappings);
      fixturesPaired += 1;
      mappingsTotal += mappings.length;
    }
  }

  if (allMappings.length > 0) {
    await upsertBsdRecords("bsd_tsdb_player_map", allMappings);
  }
  const newestLineupUpdatedAt = bsdLineups.reduce(
    (latest, doc) => (doc.updated_at && (!latest || doc.updated_at > latest) ? doc.updated_at : latest),
    watermark || null
  );
  await saveOperationalDataset({
    name: PLAYER_MAP_STATE_DATASET,
    updated_at: queryStartedAt,
    source: "bsd_player_map",
    payload: { last_lineup_updated_at: newestLineupUpdatedAt || queryStartedAt },
  });
  console.log(
    `[bsd-map] player map: ${mappingsTotal} mappings across ${fixturesPaired} fixtures ` +
      `(${bsdLineups.length} changed lineups)`
  );
  return { fixturesPaired, mappingsTotal, lineupsScanned: bsdLineups.length };
}

async function buildTeamMap() {
  // Match by canonical name: BSD teams against the TSDB team cache.
  const [bsdTeams, tsdbTeams] = await Promise.all([
    getBsdRecords("bsd_teams"),
    getBsdRecords("tsdb_teams"), // generic id-keyed reader over the TSDB team cache
  ]);

  const tsdbByCanonical = new Map();
  tsdbTeams.forEach((doc) => {
    const name = doc && doc.payload && doc.payload.strTeam ? doc.payload.strTeam : null;
    const id = doc && doc.payload && doc.payload.idTeam ? String(doc.payload.idTeam) : String(doc._id);
    if (!name) return;
    const key = canonicalTeamName(name) || name;
    if (!tsdbByCanonical.has(key)) tsdbByCanonical.set(key, { id, name });
  });

  const records = [];
  bsdTeams.forEach((doc) => {
    const p = doc.payload || {};
    const bsdId = p.id != null ? String(p.id) : String(doc._id);
    const name = p.name || null;
    if (!name) return;
    const key = canonicalTeamName(name) || name;
    const tsdb = tsdbByCanonical.get(key);
    if (!tsdb) return;
    records.push({
      id: bsdId,
      payload: { tsdb_team_id: tsdb.id, name: tsdb.name, canonical: key },
      extra: {},
    });
  });

  if (records.length > 0) await upsertBsdRecords("bsd_tsdb_team_map", records);
  console.log(`[bsd-map] team map: ${records.length} teams mapped`);
  return { teamsMapped: records.length };
}

async function buildBsdTsdbMaps(options = {}) {
  const team = await buildTeamMap();
  const player = await buildPlayerMap(options);
  return { ...team, ...player };
}

if (require.main === module) {
  buildBsdTsdbMaps({ full: process.argv.includes("--full") })
    .catch((error) => {
      console.error("[bsd-map] rebuild failed:", error.message || error);
      process.exitCode = 1;
    })
    .finally(() => closeMongoConnection().catch(() => {}));
}

module.exports = {
  buildBsdTsdbMaps,
  buildPlayerMap,
  buildTeamMap,
  // exposed for tests
  __private: {
    pairSide,
    buildFixturePlayerMappings,
    compositeKey,
    CONTRADICTION_NAME_SCORE,
  },
};
