#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// BSD <-> TSDB id mapping layer.
//
// BSD line-ups (bsd_lineups) carry no player photos; TSDB has them. We build a
// persistent map from BSD player id -> TSDB player id (+ snapshotted photo) by
// pairing the two providers' line-ups for the SAME fixture.
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
  getMatchLineupCache,
  getAllOperationalMatchDetails,
  upsertBsdRecords,
} = require("./mongo_client");

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
async function buildCompositeToTsdbEventId() {
  const details = await getAllOperationalMatchDetails();
  const records = (details && details.records) || {};
  const map = new Map();
  Object.entries(records).forEach(([id, payload]) => {
    const key = compositeKey(payload);
    if (key) map.set(key, id);
  });
  return map;
}

async function buildPlayerMap() {
  const [bsdLineups, bsdEvents, leagueNameById, compositeToTsdb] = await Promise.all([
    getBsdRecords("bsd_lineups"),
    getBsdRecords("bsd_events"),
    buildLeagueNameById(),
    buildCompositeToTsdbEventId(),
  ]);

  const eventById = new Map(bsdEvents.map((doc) => [String(doc._id), doc.payload]));

  let fixturesPaired = 0;
  let mappingsTotal = 0;
  const allMappings = [];

  for (const lineupDoc of bsdLineups) {
    const bsdEventId = String(lineupDoc._id);
    const event = eventById.get(bsdEventId);
    if (!event) continue;
    const canonical = bsdEventToCanonicalMatch(event, { leagueNameById });
    if (!canonical) continue;
    const tsdbEventId = compositeToTsdb.get(compositeKey(canonical));
    if (!tsdbEventId) continue;

    // eslint-disable-next-line no-await-in-loop
    const tsdbLineup = await getMatchLineupCache(tsdbEventId);
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
  console.log(`[bsd-map] player map: ${mappingsTotal} mappings across ${fixturesPaired} fixtures`);
  return { fixturesPaired, mappingsTotal };
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

async function buildBsdTsdbMaps() {
  const team = await buildTeamMap();
  const player = await buildPlayerMap();
  return { ...team, ...player };
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
