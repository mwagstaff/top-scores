"use strict";

const BSD_PLAYER_IMAGE_BASE_URL = "https://sports.bzzoiro.com/img/player";

function normalizeNumericPlayerId(value) {
  const id = String(value == null ? "" : value).trim();
  return /^\d+$/.test(id) ? id : null;
}

function bsdPlayerImageUrl(playerId) {
  const id = normalizeNumericPlayerId(playerId);
  return id ? `${BSD_PLAYER_IMAGE_BASE_URL}/${id}/` : null;
}

function bsdPlayerIdByTsdbId(mapDocs = []) {
  const byTsdbId = new Map();
  (Array.isArray(mapDocs) ? mapDocs : []).forEach((doc) => {
    const bsdPlayerId = normalizeNumericPlayerId(doc && doc._id);
    const tsdbPlayerId = normalizeNumericPlayerId(
      doc && doc.payload && doc.payload.tsdb_player_id
    );
    if (bsdPlayerId && tsdbPlayerId && !byTsdbId.has(tsdbPlayerId)) {
      byTsdbId.set(tsdbPlayerId, bsdPlayerId);
    }
  });
  return byTsdbId;
}

function collectMatchLineupTsdbPlayerIds(payload) {
  const ids = new Set();
  const addPlayer = (player) => {
    if (!player || normalizeNumericPlayerId(player.bsd_player_id)) return;
    const id = normalizeNumericPlayerId(player.id_player);
    if (id) ids.add(id);
  };
  const lineups = payload && payload.team_lineups;
  [lineups && lineups.home, lineups && lineups.away].filter(Boolean).forEach((side) => {
    (Array.isArray(side.starting_lineup) ? side.starting_lineup : []).forEach(addPlayer);
    (Array.isArray(side.substitutes) ? side.substitutes : []).forEach(addPlayer);
    (Array.isArray(side.substitutions) ? side.substitutions : []).forEach((substitution) => {
      addPlayer(substitution && substitution.player_off);
      addPlayer(substitution && substitution.player_on);
    });
  });
  return [...ids];
}

function matchDetailsWithBsdPlayerImages(payload, mapDocs = []) {
  const lineups = payload && payload.team_lineups;
  if (!lineups || typeof lineups !== "object") return payload;
  const bsdIdByTsdbId = bsdPlayerIdByTsdbId(mapDocs);

  const rewritePlayer = (player) => {
    if (!player || typeof player !== "object") return player;
    const tsdbPlayerId = normalizeNumericPlayerId(player.id_player);
    const bsdPlayerId =
      normalizeNumericPlayerId(player.bsd_player_id) ||
      (tsdbPlayerId ? bsdIdByTsdbId.get(tsdbPlayerId) : null);
    return {
      ...player,
      ...(bsdPlayerId ? { bsd_player_id: bsdPlayerId } : {}),
      cutout_url: bsdPlayerImageUrl(bsdPlayerId),
    };
  };

  const rewriteSide = (side) => {
    if (!side || typeof side !== "object") return side;
    return {
      ...side,
      starting_lineup: (Array.isArray(side.starting_lineup) ? side.starting_lineup : []).map(rewritePlayer),
      substitutes: (Array.isArray(side.substitutes) ? side.substitutes : []).map(rewritePlayer),
      substitutions: (Array.isArray(side.substitutions) ? side.substitutions : []).map((substitution) => ({
        ...substitution,
        player_off: rewritePlayer(substitution && substitution.player_off),
        player_on: rewritePlayer(substitution && substitution.player_on),
      })),
    };
  };

  return {
    ...payload,
    team_lineups: {
      ...lineups,
      home: rewriteSide(lineups.home),
      away: rewriteSide(lineups.away),
    },
  };
}

function playerDetailsWithBsdImage(payload, tsdbPlayerId, mapDocs = []) {
  if (!payload || typeof payload !== "object") return payload;
  const bsdId =
    normalizeNumericPlayerId(payload.bsd_player_id) ||
    bsdPlayerIdByTsdbId(mapDocs).get(normalizeNumericPlayerId(tsdbPlayerId));
  return {
    ...payload,
    ...(bsdId ? { bsd_player_id: bsdId } : {}),
    cutout_url: bsdPlayerImageUrl(bsdId),
    thumb_url: null,
    render_url: null,
  };
}

module.exports = {
  BSD_PLAYER_IMAGE_BASE_URL,
  bsdPlayerIdByTsdbId,
  bsdPlayerImageUrl,
  collectMatchLineupTsdbPlayerIds,
  matchDetailsWithBsdPlayerImages,
  normalizeNumericPlayerId,
  playerDetailsWithBsdImage,
};
