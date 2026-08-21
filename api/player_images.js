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

function matchDetailsWithBsdPlayerImages(payload) {
  const lineups = payload && payload.team_lineups;
  if (!lineups || typeof lineups !== "object") return payload;

  const rewritePlayer = (player) => {
    if (!player || typeof player !== "object") return player;
    const playerId =
      normalizeNumericPlayerId(player.id_player) ||
      normalizeNumericPlayerId(player.bsd_player_id);
    return {
      ...player,
      ...(playerId ? { id_player: playerId, bsd_player_id: playerId } : {}),
      cutout_url: bsdPlayerImageUrl(playerId),
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

function playerDetailsWithBsdImage(payload, playerId) {
  if (!payload || typeof payload !== "object") return payload;
  const id = normalizeNumericPlayerId(payload.bsd_player_id) || normalizeNumericPlayerId(playerId);
  return {
    ...payload,
    ...(id ? { bsd_player_id: id } : {}),
    cutout_url: bsdPlayerImageUrl(id),
    thumb_url: null,
    render_url: null,
  };
}

module.exports = {
  BSD_PLAYER_IMAGE_BASE_URL,
  bsdPlayerImageUrl,
  matchDetailsWithBsdPlayerImages,
  normalizeNumericPlayerId,
  playerDetailsWithBsdImage,
};
