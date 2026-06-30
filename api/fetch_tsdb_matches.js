#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

const {
  getLivescores,
  getEvent,
  getEventTimeline,
  getEventLineup,
  getTeam,
  getPlayer,
  getLeagueSchedule,
  getLeagueTeams,
  setRequestObserver,
} = require("./thesportsdb_client");

const {
  TSDB_LEAGUE_ALLOWLIST,
  TSDB_EPL_LEAGUE_ID,
  TSDB_TWO_LEGGED_LEAGUE_IDS,
  mapTsdbLeagueName,
  leagueSeasons,
} = require("./thesportsdb_leagues");
const { utcDateTimeToZonedDateTime } = require("./match_time");
const {
  getMatchLineupCache,
  upsertMatchLineupCache,
  getMatchTimelineCache,
  upsertMatchTimelineCache,
  getTeamCache,
  upsertTeamCache,
  getPlayerCaches,
  upsertPlayerCache,
} = require("./mongo_client");

const TSDB_LINEUP_FUTURE_REFRESH_MS = 6 * 60 * 60 * 1000;
const TSDB_LINEUP_TODAY_REFRESH_MS = 30 * 60 * 1000;
const TSDB_TIMELINE_IN_PROGRESS_REFRESH_MS = 30 * 1000;
const TSDB_TIMELINE_EMPTY_RETRY_MS = 2 * 60 * 1000;
const TSDB_ENTITY_REFRESH_MS = 24 * 60 * 60 * 1000;
const TSDB_ENTITY_WARM_CONCURRENCY = 3;

// ---------------------------------------------------------------------------
// Status mapping
// ---------------------------------------------------------------------------
// Maps TheSportsDB strStatus + strProgress to the internal score_status field
// used throughout the codebase.
//
// Internal values: null (not started), "HT", "FT", "AET", "Pens",
//   "POSTPONED", or a minute string like "45", "45+2", "67".

function mapTsdbStatus(strStatus, strProgress) {
  if (!strStatus) return null;
  const s = String(strStatus).trim().toUpperCase();

  switch (s) {
    case "NS": return null;           // not started
    case "HT": return "HT";
    case "FT": return "FT";
    case "AET": return "AET";
    case "PEN": return "Pens";
    case "POSTPONED": return "POSTPONED";
    case "CANCELLED": return "POSTPONED";
    case "ABANDONED": return "POSTPONED";
    case "VOID": return "POSTPONED";
    default:
      // In-progress: strProgress gives the current minute.
      // "1H", "2H", "ET" → use strProgress if available, otherwise keep
      // the match live so a missing minute cannot look like pre-match state.
      if (s === "1H" || s === "2H" || s === "ET" || s === "INPLAY") {
        const progress = String(strProgress || "").trim();
        return progress || (s === "ET" ? "ET" : "LIVE");
      }
      return null;
  }
}

// ---------------------------------------------------------------------------
// League name helper
// ---------------------------------------------------------------------------

function resolveLeagueName(tsdbLeagueName) {
  return mapTsdbLeagueName(tsdbLeagueName) || String(tsdbLeagueName || "").trim() || null;
}

// ---------------------------------------------------------------------------
// Timeline → event fields
// ---------------------------------------------------------------------------
//
// SportsDB timeline entry shape:
//   { idTimeline, idEvent, strTimeline, strTimelineDetail, strHome,
//     strPlayer, strAssist, intTime, idTeam, strTeam, strPeriod, ... }
//
// strTimeline values: "Goal", "Card", "subst"
// strTimelineDetail values: "Normal Goal", "Own Goal", "Penalty",
//   "Missed Penalty", "Yellow Card", "Red Card", "Yellow-Red Card",
//   "Substitution 1" … "Substitution N"

// Penalty shootout kicks appear at intTime >= 120 when strStatus is "PEN".
// Regular in-play penalties appear earlier.
function isShootoutKick(entry, matchStatus) {
  return (
    String(matchStatus || "").toUpperCase() === "PENS" &&
    Number(entry.intTime || 0) >= 120
  );
}

// Format a minute as "67'" or "45+2'" etc.
function formatMinute(intTime) {
  const t = String(intTime || "").trim();
  if (!t || t === "0") return null;
  return t.includes("+") ? `${t}'` : `${t}'`;
}

// Returns true for entries that are own goals.
function isOwnGoal(entry) {
  const detail = String(entry.strTimelineDetail || "").toLowerCase();
  return detail === "own goal" || detail.includes("own goal");
}

// Returns true for penalty-related goals (in-play AND shootout).
function isPenaltyGoal(entry) {
  const detail = String(entry.strTimelineDetail || "").toLowerCase();
  return detail === "penalty" || detail === "missed penalty";
}

// Returns true for a missed penalty kick (shootout or in-play).
function isMissedPenalty(entry) {
  return String(entry.strTimelineDetail || "").toLowerCase() === "missed penalty";
}

// True only for a VAR detail describing a goal that was overturned on review
// (e.g. "Goal Disallowed"). Excludes confirmed goal-awards and any non-goal
// VAR review (penalty/card checks, offside checks, etc.) — those are noise
// the user doesn't want in Match Events or notifications. TSDB's timeline has
// no structured confirmed/decision field (unlike BSD's varDecision incidents),
// so this infers intent from the free-text detail string.
function isDisallowedGoalVarDetail(detail) {
  const text = String(detail || "");
  return /goal/i.test(text) && /disallow|not award|overturn|cancel|void/i.test(text);
}

/**
 * Parse the goal scorers, assists, red cards, and yellow cards from a
 * timeline array. Also derives penalty_result for PEN matches.
 *
 * @param {Array} timeline   – raw SportsDB lookup array
 * @param {string} homeTeamId – idTeam for the home side
 * @param {string} matchStatus – resolved internal score_status (e.g. "Pens")
 * @returns {object} – { home_goal_scorers, away_goal_scorers,
 *                       home_assists, away_assists,
 *                       home_yellow_cards, away_yellow_cards,
 *                       home_red_cards, away_red_cards,
 *                       home_var_events, away_var_events,
 *                       penalty_result }
 */
function parseTimelineEvents(timeline, homeTeamId, matchStatus) {
  const result = {
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
    home_yellow_cards: [],
    away_yellow_cards: [],
    home_red_cards: [],
    away_red_cards: [],
    home_var_events: [],
    away_var_events: [],
    penalty_result: null,
  };

  if (!Array.isArray(timeline) || timeline.length === 0) return result;

  const isPenMatch = String(matchStatus || "").toUpperCase() === "PENS";

  // --- Accumulators keyed by player name ---
  const homeGoals = new Map();  // player → { player, goal_times, own_goal_times }
  const awayGoals = new Map();
  const homeAssists = new Map();
  const awayAssists = new Map();
  const homeYellow = new Map(); // player → { player, yellow_card_times }
  const awayYellow = new Map();
  const homeRed = new Map();   // player → { player, red_card_times }
  const awayRed = new Map();

  // Penalty shootout counters.
  let homePenScored = 0;
  let awayPenScored = 0;

  function isHome(entry) {
    // strHome is "Yes" / "No". Fall back to idTeam comparison if available.
    if (homeTeamId && entry.idTeam) {
      return String(entry.idTeam) === String(homeTeamId);
    }
    return String(entry.strHome || "").toLowerCase() === "yes";
  }

  function addGoalTime(map, player, time, isOwn) {
    if (!player || !time) return;
    const existing = map.get(player) || { player, goal_times: [], own_goal_times: [] };
    if (isOwn) {
      if (!existing.own_goal_times.includes(time)) existing.own_goal_times.push(time);
    } else {
      if (!existing.goal_times.includes(time)) existing.goal_times.push(time);
    }
    map.set(player, existing);
  }

  function addAssistTime(map, player, time) {
    if (!player || !time) return;
    const existing = map.get(player) || { player, assist_times: [] };
    if (!existing.assist_times.includes(time)) existing.assist_times.push(time);
    map.set(player, existing);
  }

  function addCardTime(map, player, time) {
    if (!player || !time) return;
    const field = map === homeYellow || map === awayYellow
      ? "yellow_card_times"
      : "red_card_times";
    const existing = map.get(player) || { player, [field]: [] };
    if (!existing[field].includes(time)) existing[field].push(time);
    map.set(player, existing);
  }

  timeline.forEach((entry) => {
    const type = String(entry.strTimeline || "").toLowerCase();
    const player = String(entry.strPlayer || "").trim() || null;
    const assist = String(entry.strAssist || "").trim() || null;
    const minute = formatMinute(entry.intTime);
    const home = isHome(entry);

    if (type === "goal") {
      const own = isOwnGoal(entry);
      const shootout = isShootoutKick(entry, matchStatus);

      if (shootout) {
        // Penalty shootout — count scored kicks; don't add to regular scorers.
        if (!isMissedPenalty(entry)) {
          if (home) homePenScored += 1;
          else awayPenScored += 1;
        }
        return;
      }

      if (isMissedPenalty(entry)) return; // missed in-play penalty — no goal recorded

      const goalMap = home ? homeGoals : awayGoals;
      const assistMap = home ? homeAssists : awayAssists;

      // Own goal — attributed to the scoring team's OWN map as an own goal.
      // But an OG scored by a home player benefits the away side, so we
      // record it on the away scorers map (matching BBC convention).
      if (own) {
        addGoalTime(home ? awayGoals : homeGoals, player, minute, true);
      } else {
        addGoalTime(goalMap, player, minute, false);
      }

      if (assist && !own) {
        addAssistTime(assistMap, assist, minute);
      }
    } else if (type === "card") {
      const detail = String(entry.strTimelineDetail || "").toLowerCase();
      if (detail.includes("red") && !detail.includes("yellow-red")) {
        addCardTime(home ? homeRed : awayRed, player, minute);
      } else if (detail.includes("yellow-red") || detail.includes("second yellow")) {
        // Second yellow = red card outcome.
        addCardTime(home ? homeRed : awayRed, player, minute);
      } else if (detail.includes("yellow")) {
        addCardTime(home ? homeYellow : awayYellow, player, minute);
      }
    } else if (type === "var") {
      const detail = String(entry.strTimelineDetail || "").trim() || null;
      // Mirrors the BSD adapter's restriction: only a disallowed goal is
      // notification/display-worthy; other VAR reviews (confirmed goals,
      // penalty/card checks, offside checks) are noise. TSDB's timeline has
      // no structured confirmed/decision field, so this infers intent from
      // the detail text rather than a structured flag.
      if (detail && isDisallowedGoalVarDetail(detail)) {
        const varEvent = { player, minute, detail };
        const cutout = String(entry.strCutout || "").trim();
        if (cutout) varEvent.cutout_url = cutout;
        const idPlayer = String(entry.idPlayer || "").trim();
        if (idPlayer && idPlayer !== "0") varEvent.id_player = idPlayer;
        (home ? result.home_var_events : result.away_var_events).push(varEvent);
      }
    }
    // "subst" entries are part of the lineup — handled separately.
  });

  // Materialise accumulators, filtering empty arrays.
  function materialiseGoals(map) {
    return Array.from(map.values()).map((e) => {
      const out = { player: e.player };
      if (e.goal_times && e.goal_times.length) out.goal_times = e.goal_times;
      if (e.own_goal_times && e.own_goal_times.length) out.own_goal_times = e.own_goal_times;
      return out;
    });
  }

  function materialiseAssists(map) {
    return Array.from(map.values()).filter((e) => e.assist_times && e.assist_times.length);
  }

  function materialiseCards(map, field) {
    return Array.from(map.values()).filter((e) => e[field] && e[field].length);
  }

  result.home_goal_scorers = materialiseGoals(homeGoals);
  result.away_goal_scorers = materialiseGoals(awayGoals);
  result.home_assists = materialiseAssists(homeAssists);
  result.away_assists = materialiseAssists(awayAssists);
  result.home_yellow_cards = materialiseCards(homeYellow, "yellow_card_times");
  result.away_yellow_cards = materialiseCards(awayYellow, "yellow_card_times");
  result.home_red_cards = materialiseCards(homeRed, "red_card_times");
  result.away_red_cards = materialiseCards(awayRed, "red_card_times");

  if (isPenMatch && (homePenScored > 0 || awayPenScored > 0)) {
    result.penalty_result = `${homePenScored}-${awayPenScored}`;
  }

  return result;
}

// ---------------------------------------------------------------------------
// Lineup extraction
// ---------------------------------------------------------------------------
//
// SportsDB lineup entry:
//   { strPlayer, intSquadNumber, strPosition, strPositionShort, strFormation,
//     strHome, strSubstitute, idTeam, strTeam, strCutout, ... }

// Maps strPosition string → position_category.
function positionCategory(strPosition) {
  const pos = String(strPosition || "").toLowerCase();
  if (pos.includes("goal")) return "goalkeeper";
  if (
    pos.includes("back") || pos.includes("defend") ||
    pos.includes("centre-b") || pos.includes("sweeper") || pos.includes("libero")
  ) return "defender";
  if (pos.includes("mid")) return "midfielder";
  if (
    pos.includes("forward") || pos.includes("winger") ||
    pos.includes("striker") || pos.includes("attac") || pos.includes("centre-f")
  ) return "attacker";
  // Fall back to strPositionShort single-character code.
  return null;
}

// positionCategoryFromShort maps the single-char strPositionShort (G/D/M/F) as
// a fallback when strPosition doesn't give enough detail.
function positionCategoryFromShort(strPositionShort, strPosition) {
  switch (String(strPositionShort || "").toUpperCase()) {
    case "G": return "goalkeeper";
    case "D": return "defender";
    case "M": return "midfielder";
    case "F": return "attacker";
    default: {
      const cat = positionCategory(strPosition);
      return cat || null;
    }
  }
}

// Derives a formation string ("4-3-3") from the count of D/M/F starters when
// strFormation is not provided by the API.
function deriveFormationString(starters) {
  let d = 0, m = 0, f = 0;
  starters.forEach((p) => {
    if (p.position_category === "defender") d += 1;
    else if (p.position_category === "midfielder") m += 1;
    else if (p.position_category === "attacker") f += 1;
  });
  // Only emit a formation if outfield rows sum to 10 (normal lineup).
  const gk = starters.filter((p) => p.position_category === "goalkeeper").length;
  if (gk === 1 && d + m + f === 10) {
    const parts = [d];
    if (m > 0) parts.push(m);
    if (f > 0) parts.push(f);
    return parts.join("-");
  }
  return null;
}

// Parses a formation string ("4-3-3") into row sizes, prepending 1 for the GK.
// Returns [1, 4, 3, 3] for "4-3-3".
function parseFormationRows(formationStr) {
  if (!formationStr) return null;
  const parts = String(formationStr)
    .trim()
    .replace(/\s+/g, "-")
    .split("-")
    .map((n) => parseInt(n, 10))
    .filter((n) => Number.isFinite(n) && n > 0);
  if (parts.length < 2) return null;
  return [1, ...parts];
}

function normalizeFormationForRoleRows(formationStr) {
  const rows = parseFormationRows(formationStr);
  if (!rows || rows.length < 3) return null;
  const outfieldRows = rows.slice(1);
  const defenders = outfieldRows[0];
  const attackers = outfieldRows[outfieldRows.length - 1];
  const midfielders = outfieldRows
    .slice(1, -1)
    .reduce((total, value) => total + value, 0);
  const parts = [defenders];
  if (midfielders > 0) parts.push(midfielders);
  if (attackers > 0) parts.push(attackers);
  return parts.join("-");
}

function resolveLineupFormation(apiFormation, starters) {
  const derivedFormation = deriveFormationString(starters);
  if (!apiFormation) return derivedFormation;
  if (!derivedFormation) return apiFormation;
  const normalizedApiFormation = normalizeFormationForRoleRows(apiFormation);
  return normalizedApiFormation === derivedFormation ? apiFormation : derivedFormation;
}

// Assigns formation_row_index, formation_slot_index, formation_row_size to each
// starter based on their position category and the parsed row sizes.
function positionSideHint(position) {
  const normalized = String(position || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
  if (/\bleft\b/.test(normalized)) return "left";
  if (/\bright\b/.test(normalized)) return "right";
  if (/\b(centre|center|central)\b/.test(normalized)) return "centre";
  return null;
}

function preferredSlotsForHint(hint, rowSize, side) {
  if (!hint || rowSize <= 0) return [];
  const slots = Array.from({ length: rowSize }, (_, index) => index);
  const middle = Math.floor(rowSize / 2);
  const centreSlots = rowSize % 2 === 1
    ? [middle]
    : (rowSize >= 4 ? [middle - 1, middle] : []);
  const screenLeftSlots = slots.filter((slot) => slot < middle);
  const screenRightSlots = slots.filter((slot) => slot >= rowSize - middle);
  if (hint === "centre") return centreSlots;

  const screenLeftPreferredSlots = screenLeftSlots;
  const screenRightPreferredSlots = rowSize === 4 ? [...screenRightSlots].reverse() : screenRightSlots;
  const logicalLeftSlots = side === "home" ? screenRightPreferredSlots : screenLeftPreferredSlots;
  const logicalRightSlots = side === "home" ? screenLeftPreferredSlots : screenRightPreferredSlots;
  return hint === "left" ? logicalLeftSlots : logicalRightSlots;
}

function assignSideAwareRowSlots(rowPlayers, side) {
  const rowSize = rowPlayers.length;
  if (rowSize <= 1) return rowPlayers;

  const assignment = Array(rowSize).fill(null);
  const assigned = new Set();
  const groups = { left: [], right: [], centre: [] };
  rowPlayers.forEach((player) => {
    const hint = positionSideHint(player.position);
    if (hint && groups[hint]) groups[hint].push(player);
  });

  ["right", "left", "centre"].forEach((hint) => {
    const players = groups[hint];
    if (players.length === 0) return;
    const slots = preferredSlotsForHint(hint, rowSize, side);
    if (players.length > slots.length) return;
    players.forEach((player, index) => {
      const slot = slots[index];
      if (Number.isInteger(slot) && assignment[slot] === null) {
        assignment[slot] = player;
        assigned.add(player);
      }
    });
  });

  const unassigned = rowPlayers.filter((player) => !assigned.has(player));
  let cursor = 0;
  for (let slot = 0; slot < rowSize; slot++) {
    if (assignment[slot] !== null) continue;
    assignment[slot] = unassigned[cursor];
    cursor += 1;
  }
  return assignment.filter(Boolean);
}

function assignFormationGridPositions(starters, formationStr, options = {}) {
  const ROLE_ORDER = { goalkeeper: 0, defender: 1, midfielder: 2, attacker: 3 };
  const side = options.side === "away" ? "away" : "home";

  // Sort by role first, then squad number within role.
  const sorted = [...starters].sort((a, b) => {
    const aRole = ROLE_ORDER[a.position_category] ?? 4;
    const bRole = ROLE_ORDER[b.position_category] ?? 4;
    if (aRole !== bRole) return aRole - bRole;
    return (a.number ?? 99) - (b.number ?? 99);
  });

  const rows = parseFormationRows(formationStr);
  const result = [];

  if (!rows) {
    // No formation available — place all players in a single row as fallback.
    sorted.forEach((p, i) => {
      result.push({
        ...p,
        formation_row_index: 0,
        formation_slot_index: i,
        formation_row_size: sorted.length,
      });
    });
    return result;
  }

  // Distribute sorted players across rows in order.
  let cursor = 0;
  for (let rowIdx = 0; rowIdx < rows.length && cursor < sorted.length; rowIdx++) {
    const rowSize = rows[rowIdx];
    const rowPlayers = sorted.slice(cursor, cursor + rowSize);
    const orderedRowPlayers = rowIdx === 0 ? rowPlayers : assignSideAwareRowSlots(rowPlayers, side);
    orderedRowPlayers.forEach((p, slotIdx) => {
      result.push({
        ...p,
        formation_row_index: rowIdx,
        formation_slot_index: slotIdx,
        formation_row_size: orderedRowPlayers.length,
      });
    });
    cursor += rowPlayers.length;
  }
  // Any overflow (formation doesn't sum to 11) appended to an extra row.
  if (cursor < sorted.length) {
    const overflow = sorted.slice(cursor);
    overflow.forEach((p, slotIdx) => {
      result.push({
        ...p,
        formation_row_index: rows.length,
        formation_slot_index: slotIdx,
        formation_row_size: overflow.length,
      });
    });
  }

  return result;
}

function lineupPlayerPositionFromLookup(entry, playerPositionsById) {
  const playerId = String(entry && entry.idPlayer ? entry.idPlayer : "").trim();
  const enrichedPosition = playerId && playerPositionsById
    ? String(playerPositionsById[playerId] || "").trim()
    : "";
  return enrichedPosition || String(entry && entry.strPosition ? entry.strPosition : "").trim() || null;
}

function playerPositionFromCacheRecord(record) {
  if (!record || typeof record !== "object") return null;
  const payload = record.payload && typeof record.payload === "object" ? record.payload : record;
  return String(payload.strPosition || "").trim() || null;
}

async function buildLineupPlayerPositionLookup(lineupEntries) {
  if (!Array.isArray(lineupEntries) || lineupEntries.length === 0) return {};
  const playerIds = [
    ...new Set(
      lineupEntries
        .map((entry) => String(entry && entry.idPlayer ? entry.idPlayer : "").trim())
        .filter((id) => /^\d+$/.test(id))
    ),
  ];
  if (playerIds.length === 0) return {};
  const cachedPlayers = await getPlayerCaches(playerIds).catch(() => ({}));
  return Object.fromEntries(
    playerIds
      .map((playerId) => [playerId, playerPositionFromCacheRecord(cachedPlayers[playerId])])
      .filter(([, position]) => Boolean(position))
  );
}

function parseLineups(lineupEntries, homeTeamId, options = {}) {
  if (!Array.isArray(lineupEntries) || lineupEntries.length === 0) return null;
  const playerPositionsById = options.playerPositionsById || {};

  function isHome(entry) {
    const homeFlag = String(entry.strHome || "").trim().toLowerCase();
    if (homeFlag === "yes") return true;
    if (homeFlag === "no") return false;
    return null;
  }

  const homeStarters = [];
  const homeSubstitutes = [];
  const awayStarters = [];
  const awaySubstitutes = [];
  let homeFormation = null;
  let awayFormation = null;

  lineupEntries.forEach((entry) => {
    const player = String(entry.strPlayer || "").trim();
    if (!player) return;

    const number = Number(entry.intSquadNumber);
    const isSub = String(entry.strSubstitute || "").toLowerCase() === "yes";
    const home = isHome(entry);
    if (home === null) return;

    const formation = String(entry.strFormation || "").trim() || null;
    if (formation) {
      if (home && !homeFormation) homeFormation = formation;
      if (!home && !awayFormation) awayFormation = formation;
    }

    const position = lineupPlayerPositionFromLookup(entry, playerPositionsById);
    const player_entry = {
      number: Number.isFinite(number) ? number : null,
      name: player,
      id_player: String(entry.idPlayer || "").trim() || null,
      position_category: positionCategoryFromShort(entry.strPositionShort, entry.strPosition || position),
      position,
      position_short: String(entry.strPositionShort || "").trim() || null,
      cutout_url: String(entry.strCutout || "").trim() || null,
    };

    if (home) {
      if (isSub) homeSubstitutes.push(player_entry);
      else homeStarters.push(player_entry);
    } else {
      if (isSub) awaySubstitutes.push(player_entry);
      else awayStarters.push(player_entry);
    }
  });

  if (homeStarters.length === 0 && awayStarters.length === 0) return null;

  // Derive formation string from position counts when the API doesn't supply it.
  const resolvedHomeFormation = resolveLineupFormation(homeFormation, homeStarters);
  const resolvedAwayFormation = resolveLineupFormation(awayFormation, awayStarters);

  const lineups = {};
  if (homeStarters.length > 0 || homeSubstitutes.length > 0) {
    lineups.home = {
      formation: resolvedHomeFormation,
      starting_lineup: assignFormationGridPositions(homeStarters, resolvedHomeFormation, { side: "home" }),
      substitutes: homeSubstitutes,
    };
  }
  if (awayStarters.length > 0 || awaySubstitutes.length > 0) {
    lineups.away = {
      formation: resolvedAwayFormation,
      starting_lineup: assignFormationGridPositions(awayStarters, resolvedAwayFormation, { side: "away" }),
      substitutes: awaySubstitutes,
    };
  }

  return Object.keys(lineups).length > 0 ? lineups : null;
}

// ---------------------------------------------------------------------------
// Aggregate score computation
// ---------------------------------------------------------------------------
//
// SportsDB doesn't expose aggregate scores. For two-legged ties we compute
// aggregate by finding the reverse fixture in our schedule cache.
//
// scheduleCache: flat array of match objects with { id, home_team, away_team,
//   home_score, away_score, date, league }

function computeAggregateFromSchedule(event, scheduleCache) {
  if (!Array.isArray(scheduleCache) || scheduleCache.length === 0) return null;

  const homeTeam = String(event.home_team || "").trim().toLowerCase();
  const awayTeam = String(event.away_team || "").trim().toLowerCase();
  const eventDate = String(event.date || "").trim();
  const leagueId = String(event.idLeague || "").trim();

  // Only attempt aggregate computation for two-legged competitions.
  if (!TSDB_TWO_LEGGED_LEAGUE_IDS.has(leagueId)) return null;

  // Find the reverse fixture (same teams, opposite sides) earlier this season.
  const firstLeg = scheduleCache.find((m) => {
    const mHome = String(m.home_team || "").trim().toLowerCase();
    const mAway = String(m.away_team || "").trim().toLowerCase();
    const mDate = String(m.date || "").trim();
    return (
      mHome === awayTeam &&
      mAway === homeTeam &&
      mDate < eventDate &&
      (m.home_score !== null && m.home_score !== undefined) &&
      (m.away_score !== null && m.away_score !== undefined)
    );
  });

  if (!firstLeg) return null;

  const leg1Home = Number(firstLeg.home_score);
  const leg1Away = Number(firstLeg.away_score);
  const leg2Home = Number(event.home_score);
  const leg2Away = Number(event.away_score);

  if (!Number.isFinite(leg1Home) || !Number.isFinite(leg1Away) ||
      !Number.isFinite(leg2Home) || !Number.isFinite(leg2Away)) {
    return null;
  }

  // Aggregate is from the perspective of the SECOND leg's home team:
  // their total = their home goals (leg 2) + their away goals (leg 1 away score).
  return {
    aggregate_home_score: leg2Home + leg1Away,
    aggregate_away_score: leg2Away + leg1Home,
  };
}

// ---------------------------------------------------------------------------
// Shared time helpers
// ---------------------------------------------------------------------------

const TSDB_DISPLAY_TIME_ZONE =
  process.env.TSDB_DISPLAY_TIME_ZONE || process.env.MATCH_DISPLAY_TIME_ZONE || "Europe/London";

function stripSeconds(timeStr) {
  // "22:00:00" → "22:00"
  if (!timeStr) return null;
  const match = String(timeStr).match(/^(\d{1,2}:\d{2})/);
  return match ? match[1] : null;
}

function normalizeTsdbKickoffDateTime(event, options = {}) {
  const source = event && typeof event === "object" ? event : {};
  const date = String(source.dateEvent || source.date || "").trim() || null;
  const timeField = options.timeField || "strTime";
  const rawTime = source[timeField] || source.strTime || null;
  const time = stripSeconds(rawTime);

  if (!date || !time) {
    return { date, time };
  }

  return utcDateTimeToZonedDateTime(date, time, TSDB_DISPLAY_TIME_ZONE);
}

// ---------------------------------------------------------------------------
// Public API: fetchTsdbLivescores
// Replaces fetchBbcFixtures — returns an array of live match objects in the
// internal model.
// ---------------------------------------------------------------------------

async function fetchTsdbLivescores(options = {}) {
  const resp = await getLivescores({
    initiator: options.initiator || "scraper",
    reason: options.reason || "tsdb_livescore_poll",
    trigger: options.trigger,
  });

  const entries = Array.isArray(resp && resp.livescore) ? resp.livescore : [];

  return entries
    .map((e) => {
      const kickoff = normalizeTsdbKickoffDateTime(e, { timeField: "strEventTime" });
      const scoreStatus = mapTsdbStatus(e.strStatus, e.strProgress);
      // Use the allowlist name if the league is in our schedule set, otherwise
      // use the raw SportsDB name so matches from other competitions (e.g.
      // International Friendlies, World Cup qualifying) are included with a
      // recognisable league label. The competition-level filter in server.js
      // (filterMatchesByCompetition) decides what actually surfaces to the app.
      const league = resolveLeagueName(e.strLeague) || String(e.strLeague || "").trim() || null;
      return {
        id: String(e.idEvent),
        match_details_id: String(e.idEvent),
        home_team: String(e.strHomeTeam || "").trim(),
        away_team: String(e.strAwayTeam || "").trim(),
        home_team_id: String(e.idHomeTeam || "").trim() || null,
        away_team_id: String(e.idAwayTeam || "").trim() || null,
        home_score: e.intHomeScore !== null && e.intHomeScore !== undefined
          ? Number(e.intHomeScore) : null,
        away_score: e.intAwayScore !== null && e.intAwayScore !== undefined
          ? Number(e.intAwayScore) : null,
        score_status: scoreStatus,
        match_time: scoreStatus,
        date: kickoff.date,
        time: kickoff.time,
        league,
        details_url: null,
        has_tsdb_source: true,
        // These are populated by the match-details poll, not livescores.
        home_goal_scorers: [],
        away_goal_scorers: [],
        home_assists: [],
        away_assists: [],
        home_yellow_cards: [],
        away_yellow_cards: [],
        home_red_cards: [],
        away_red_cards: [],
      };
    });
}

// ---------------------------------------------------------------------------
// Substitution extraction from timeline
// ---------------------------------------------------------------------------
//
// The SportsDB lineup endpoint only returns the starting XI — bench players are
// not included. Actual substitutions are in the event_timeline as "subst" entries:
//   { strTimeline: "subst", strPlayer: <off>, strAssist: <on>, intTime: <min>,
//     strHome: "Yes"/"No", idTeam, strTeam }
//
// We cross-reference with the starters list to look up the squad number for the
// player going off. The player coming on has no number (not in lineup endpoint).

function extractSubstitutionsFromTimeline(
  timeline,
  homeStarters,
  awayStarters,
  homeTeamId,
  homeSubstitutes = [],
  awaySubstitutes = []
) {
  if (!Array.isArray(timeline)) return { home: [], away: [] };

  // Build a name→number lookup from starters (both sides).
  function buildNameLookup(players) {
    const map = new Map();
    (players || []).forEach((p) => {
      if (p.name) map.set(p.name.toLowerCase(), p.number ?? null);
    });
    return map;
  }
  const homeLookup = buildNameLookup(homeStarters);
  const awayLookup = buildNameLookup(awayStarters);
  const homeBenchLookup = buildPlayerLookup(homeSubstitutes);
  const awayBenchLookup = buildPlayerLookup(awaySubstitutes);

  const home = [];
  const away = [];

  function isHome(entry) {
    if (homeTeamId && entry.idTeam) return String(entry.idTeam) === String(homeTeamId);
    return String(entry.strHome || "").toLowerCase() === "yes";
  }

  timeline.forEach((entry) => {
    if (String(entry.strTimeline || "").toLowerCase() !== "subst") return;

    const playerOff = String(entry.strPlayer || "").trim() || null;
    const playerOn  = String(entry.strAssist  || "").trim() || null;
    if (!playerOn) return; // must at least know who came on

    const minute = formatMinute(entry.intTime);
    if (!minute) return;

    const h = isHome(entry);
    const lookup = h ? homeLookup : awayLookup;
    const benchLookup = h ? homeBenchLookup : awayBenchLookup;
    const offNumber = playerOff ? (lookup.get(playerOff.toLowerCase()) ?? null) : null;
    const resolvedPlayerOn = resolvePlayerFromLookup(playerOn, benchLookup) || { number: null, name: playerOn };

    const subEvent = {
      minute,
      player_off: playerOff ? { number: offNumber, name: playerOff } : null,
      player_on: resolvedPlayerOn,
    };

    if (h) home.push(subEvent);
    else away.push(subEvent);
  });

  // Sort by minute ascending.
  const byMinute = (a, b) => {
    const aVal = Number(String(a.minute).replace(/[^0-9]/g, "")) || 0;
    const bVal = Number(String(b.minute).replace(/[^0-9]/g, "")) || 0;
    return aVal - bVal;
  };
  home.sort(byMinute);
  away.sort(byMinute);

  return { home, away };
}

function buildPlayerLookup(players) {
  return (Array.isArray(players) ? players : [])
    .filter((player) => player && typeof player === "object" && String(player.name || "").trim())
    .map((player) => ({
      player,
      lookup: playerNameLookup(player.name),
    }));
}

function resolvePlayerFromLookup(name, candidates) {
  const lookup = playerNameLookup(name);
  let best = null;
  candidates.forEach((candidate) => {
    const score = playerNameMatchScore(lookup, candidate.lookup);
    if (score <= 0) return;
    if (!best || score > best.score) {
      best = { player: candidate.player, score };
    }
  });
  return best ? { ...best.player } : null;
}

function playerNameLookup(name) {
  const tokens = String(name || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/\(c\)/gi, "")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean);
  const first = tokens[0] || "";
  const last = tokens[tokens.length - 1] || "";
  return {
    full: tokens.join(" "),
    initialAndLast: first && last ? `${first[0]} ${last}` : tokens.join(" "),
    last,
  };
}

function playerNameMatchScore(left, right) {
  if (!left.full || !right.full) return 0;
  if (left.full === right.full) return 4;
  if (left.initialAndLast && left.initialAndLast === right.initialAndLast) return 3;
  if (left.last && left.last === right.last) return 2;
  if (left.full.length >= 3 && right.full.endsWith(` ${left.full}`)) return 1;
  if (right.full.length >= 3 && left.full.endsWith(` ${right.full}`)) return 1;
  return 0;
}

// ---------------------------------------------------------------------------
// Public API: fetchTsdbLeagueSchedule
// Returns all fixtures/results for a single league+season.
// ---------------------------------------------------------------------------

async function fetchTsdbLeagueSchedule(idLeague, season, options = {}) {
  const resp = await getLeagueSchedule(idLeague, season, {
    initiator: options.initiator || "scraper",
    reason: options.reason || "tsdb_league_schedule_fetch",
    trigger: options.trigger,
  });

  const entries = Array.isArray(resp && resp.schedule) ? resp.schedule : [];

  const leagueEntry = TSDB_LEAGUE_ALLOWLIST.find((l) => l.id === String(idLeague));
  const leagueName = leagueEntry ? leagueEntry.name : null;

  const validEntries = entries.filter((e) => {
    const id = String(e.idEvent || "").trim();
    return /^\d+$/.test(id) && id !== "0";
  });

  return validEntries.map((e) => {
    const kickoff = normalizeTsdbKickoffDateTime(e);
    const scoreStatus = mapTsdbStatus(e.strStatus, e.strProgress);
    const league = leagueName || resolveLeagueName(e.strLeague);
    const homeScore = (e.intHomeScore !== null && e.intHomeScore !== undefined && e.intHomeScore !== "")
      ? Number(e.intHomeScore) : null;
    const awayScore = (e.intAwayScore !== null && e.intAwayScore !== undefined && e.intAwayScore !== "")
      ? Number(e.intAwayScore) : null;

    return {
      id: String(e.idEvent),
      date: kickoff.date,
      time: kickoff.time,
      league,
      home_team: String(e.strHomeTeam || "").trim(),
      away_team: String(e.strAwayTeam || "").trim(),
      home_team_id: String(e.idHomeTeam || "").trim() || null,
      away_team_id: String(e.idAwayTeam || "").trim() || null,
      home_score: homeScore,
      away_score: awayScore,
      score_status: scoreStatus,
      details_url: null,
      has_tsdb_source: true,
      tv_channels: [],
    };
  });
}

// ---------------------------------------------------------------------------
// Public API: fetchTsdbAllLeagueSchedules
// Replaces fetchBbcScoresFixturesByDateRange — fetches current+prior season
// for each allowlisted league and returns a flat deduplicated match array.
// ---------------------------------------------------------------------------

async function fetchTsdbAllLeagueSchedules(options = {}) {
  const nowMs = options.nowMs || Date.now();
  const allMatches = new Map(); // idEvent → match object

  // Fetch leagues serially to stay inside the rate budget. The token-bucket
  // in thesportsdb_client handles the per-call throttling.
  for (const leagueEntry of TSDB_LEAGUE_ALLOWLIST) {
    const seasons = leagueSeasons(leagueEntry, nowMs);
    for (const season of seasons) {
      let matches;
      try {
        // eslint-disable-next-line no-await-in-loop
        matches = await fetchTsdbLeagueSchedule(leagueEntry.id, season, {
          initiator: options.initiator || "scraper",
          reason: options.reason || "tsdb_all_leagues_schedule_fetch",
          trigger: options.trigger,
        });
      } catch (err) {
        console.warn(
          `[TSDB] Schedule fetch failed for league=${leagueEntry.id} season=${season}: ${err.message || err}`
        );
        continue;
      }

      matches.forEach((m) => {
        if (!m.id || !/^\d+$/.test(m.id) || m.id === "0") return;
        // Later (earlier calendar) seasons don't overwrite fresher data.
        if (!allMatches.has(m.id)) {
          allMatches.set(m.id, m);
        }
      });

      if (typeof options.onProgress === "function") {
        try {
          options.onProgress({ leagueId: leagueEntry.id, season, count: matches.length });
        } catch (_) { /* swallow */ }
      }
    }
  }

  return Array.from(allMatches.values());
}

function isFinishedScoreStatus(scoreStatus) {
  const token = String(scoreStatus || "").trim().toUpperCase();
  return ["FT", "AET", "PENS", "POSTPONED"].includes(token);
}

function isInProgressScoreStatus(scoreStatus) {
  if (!scoreStatus) return false;
  if (isFinishedScoreStatus(scoreStatus)) return false;
  return true;
}

function currentUkDateString(nowMs = Date.now()) {
  try {
    return new Intl.DateTimeFormat("en-CA", {
      timeZone: "Europe/London",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(new Date(nowMs));
  } catch (_err) {
    return new Date(nowMs).toISOString().slice(0, 10);
  }
}

function lineupPayloadHasEntries(payload) {
  return Boolean(
    payload &&
    typeof payload === "object" &&
    Array.isArray(payload.lookup) &&
    payload.lookup.length > 0
  );
}

function timelinePayloadHasEntries(payload) {
  return Boolean(
    payload &&
    typeof payload === "object" &&
    Array.isArray(payload.lookup) &&
    payload.lookup.length > 0
  );
}

function matchLineupCacheFresh(record, nowMs = Date.now()) {
  if (!record || typeof record !== "object") return false;
  if (record.final === true) return lineupPayloadHasEntries(record.payload);
  const nextRefreshAtMs = Number(record.next_refresh_at_ms);
  return Number.isFinite(nextRefreshAtMs) && nextRefreshAtMs > nowMs;
}

function matchTimelineCacheFresh(record, nowMs = Date.now()) {
  if (!record || typeof record !== "object") return false;
  if (record.final === true) return timelinePayloadHasEntries(record.payload);
  const nextRefreshAtMs = Number(record.next_refresh_at_ms);
  return Number.isFinite(nextRefreshAtMs) && nextRefreshAtMs > nowMs;
}

function entityCacheFresh(record, nowMs = Date.now()) {
  if (!record || typeof record !== "object") return false;
  const updatedAtMs = Number(record.updated_at_ms);
  return Number.isFinite(updatedAtMs) && nowMs - updatedAtMs < TSDB_ENTITY_REFRESH_MS;
}

function matchLineupCacheMetadata(scoreStatus, kickoffDate, nowMs = Date.now()) {
  const finished = isFinishedScoreStatus(scoreStatus);
  const inProgress = isInProgressScoreStatus(scoreStatus);
  if (finished || inProgress) {
    return {
      final: true,
      next_refresh_at_ms: null,
      source: "tsdb_event_lineup",
    };
  }
  const refreshMs =
    kickoffDate && kickoffDate === currentUkDateString(nowMs)
      ? TSDB_LINEUP_TODAY_REFRESH_MS
      : TSDB_LINEUP_FUTURE_REFRESH_MS;
  return {
    final: false,
    next_refresh_at_ms: nowMs + refreshMs,
    source: "tsdb_event_lineup",
  };
}

function matchTimelineCacheMetadata(scoreStatus, nowMs = Date.now()) {
  const finished = isFinishedScoreStatus(scoreStatus);
  if (finished) {
    return {
      final: true,
      next_refresh_at_ms: null,
      source: "tsdb_event_timeline",
    };
  }
  return {
    final: false,
    next_refresh_at_ms: isInProgressScoreStatus(scoreStatus)
      ? nowMs + TSDB_TIMELINE_IN_PROGRESS_REFRESH_MS
      : nowMs + TSDB_LINEUP_TODAY_REFRESH_MS,
    source: "tsdb_event_timeline",
  };
}

async function cachedOrFetchMatchLineup(idEvent, context = {}, reqOpts = {}) {
  const nowMs = Number.isFinite(Number(context.nowMs)) ? Number(context.nowMs) : Date.now();
  const scoreStatus = context.scoreStatus || null;
  const kickoffDate = context.kickoffDate || null;
  const forceRefresh = context.forceRefresh === true;
  const cached = forceRefresh ? null : await getMatchLineupCache(idEvent).catch(() => null);
  if (!forceRefresh && cached && matchLineupCacheFresh(cached, nowMs)) {
    return cached.payload || null;
  }

  const response = await getEventLineup(idEvent, {
    ...reqOpts,
    reason: "tsdb_lineup_lookup",
  });
  const metadata = matchLineupCacheMetadata(scoreStatus, kickoffDate, nowMs);
  if (!lineupPayloadHasEntries(response)) {
    metadata.final = false;
    metadata.next_refresh_at_ms = nowMs + TSDB_LINEUP_TODAY_REFRESH_MS;
  }
  await upsertMatchLineupCache(
    idEvent,
    response,
    metadata
  ).catch((error) => {
    console.warn(`[TSDB] Failed to cache lineup for event=${idEvent}:`, error.message || error);
  });
  return response;
}

async function cachedOrFetchMatchTimeline(idEvent, context = {}, reqOpts = {}) {
  const nowMs = Number.isFinite(Number(context.nowMs)) ? Number(context.nowMs) : Date.now();
  const scoreStatus = context.scoreStatus || null;
  const cached = await getMatchTimelineCache(idEvent).catch(() => null);
  if (cached && matchTimelineCacheFresh(cached, nowMs)) {
    return cached.payload || null;
  }

  const response = await getEventTimeline(idEvent, {
    ...reqOpts,
    reason: "tsdb_timeline_lookup",
  });
  const metadata = matchTimelineCacheMetadata(scoreStatus, nowMs);
  if (!timelinePayloadHasEntries(response)) {
    metadata.final = false;
    metadata.next_refresh_at_ms = nowMs + TSDB_TIMELINE_EMPTY_RETRY_MS;
  }
  await upsertMatchTimelineCache(
    idEvent,
    response,
    metadata
  ).catch((error) => {
    console.warn(`[TSDB] Failed to cache timeline for event=${idEvent}:`, error.message || error);
  });
  return response;
}

async function mapWithConcurrency(items, concurrency, worker) {
  if (!Array.isArray(items) || items.length === 0) return;
  const limit = Math.max(1, Number(concurrency) || 1);
  let cursor = 0;
  async function runWorker() {
    while (cursor < items.length) {
      const index = cursor;
      cursor += 1;
      // eslint-disable-next-line no-await-in-loop
      await worker(items[index], index);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, () => runWorker())
  );
}

async function warmTsdbEntityCaches(event, lineupEntries, reqOpts = {}) {
  const nowMs = Date.now();
  const teamIds = [
    String(event && event.idHomeTeam ? event.idHomeTeam : "").trim(),
    String(event && event.idAwayTeam ? event.idAwayTeam : "").trim(),
  ].filter((id) => /^\d+$/.test(id));
  const playerIds = Array.isArray(lineupEntries)
    ? [
        ...new Set(
          lineupEntries
            .map((entry) => String(entry && entry.idPlayer ? entry.idPlayer : "").trim())
            .filter((id) => /^\d+$/.test(id))
        ),
      ]
    : [];

  await mapWithConcurrency(teamIds, TSDB_ENTITY_WARM_CONCURRENCY, async (teamId) => {
    const cached = await getTeamCache(teamId).catch(() => null);
    if (entityCacheFresh(cached, nowMs)) return;
    const response = await getTeam(teamId, {
      ...reqOpts,
      reason: "tsdb_team_cache_warm",
    });
    const teams = Array.isArray(response && response.lookup) ? response.lookup : [];
    if (teams[0]) {
      await upsertTeamCache(teamId, teams[0], {
        next_refresh_at_ms: nowMs + TSDB_ENTITY_REFRESH_MS,
        source: "tsdb_team",
      }).catch(() => {});
    }
  });

  const cachedPlayers = await getPlayerCaches(playerIds).catch(() => ({}));
  const stalePlayerIds = playerIds.filter((playerId) => !entityCacheFresh(cachedPlayers[playerId], nowMs));
  await mapWithConcurrency(stalePlayerIds, TSDB_ENTITY_WARM_CONCURRENCY, async (playerId) => {
    const response = await getPlayer(playerId, {
      ...reqOpts,
      reason: "tsdb_player_cache_warm",
    });
    const players = Array.isArray(response && response.lookup) ? response.lookup : [];
    if (players[0]) {
      await upsertPlayerCache(playerId, players[0], {
        next_refresh_at_ms: nowMs + TSDB_ENTITY_REFRESH_MS,
        source: "tsdb_player",
      }).catch(() => {});
    }
  });
}

// ---------------------------------------------------------------------------
// Public API: fetchTsdbMatchDetails
// Replaces fetchBbcMatchByDetailsUrl — fetches rich details for one event.
// The caller passes the SportsDB idEvent (stored in payload.id).
// ---------------------------------------------------------------------------

async function fetchTsdbMatchDetails(idEvent, options = {}) {
  const reqOpts = {
    initiator: options.initiator || "scraper",
    trigger: options.trigger,
  };

  const eventResp = await getEvent(idEvent, { ...reqOpts, reason: "tsdb_event_lookup" });
  const event = Array.isArray(eventResp && eventResp.lookup) ? eventResp.lookup[0] : null;
  if (!event) return null;

  const scoreStatus = mapTsdbStatus(event.strStatus, event.strProgress);
  const kickoff = normalizeTsdbKickoffDateTime(event);
  const [timelineResp, lineupResp] = await Promise.all([
    cachedOrFetchMatchTimeline(
      idEvent,
      { scoreStatus, nowMs: options.nowMs },
      reqOpts
    ),
    cachedOrFetchMatchLineup(
      idEvent,
      {
        scoreStatus,
        kickoffDate: kickoff.date,
        nowMs: options.nowMs,
        forceRefresh: options.forceLineupRefresh === true,
      },
      reqOpts
    ),
  ]);

  const timeline = Array.isArray(timelineResp && timelineResp.lookup)
    ? timelineResp.lookup
    : [];
  const lineupEntries = Array.isArray(lineupResp && lineupResp.lookup)
    ? lineupResp.lookup
    : [];

  const league = resolveLeagueName(event.strLeague);

  const timelineEvents = parseTimelineEvents(
    timeline,
    event.idHomeTeam,
    scoreStatus
  );
  const playerPositionsById = await buildLineupPlayerPositionLookup(lineupEntries);
  const teamLineups = parseLineups(lineupEntries, event.idHomeTeam, { playerPositionsById });

  // Populate substitutions from the timeline (SportsDB lineup endpoint only
  // returns starting XI — bench players are not included).
  if (teamLineups) {
    const subs = extractSubstitutionsFromTimeline(
      timeline,
      teamLineups.home ? teamLineups.home.starting_lineup : [],
      teamLineups.away ? teamLineups.away.starting_lineup : [],
      event.idHomeTeam,
      teamLineups.home ? teamLineups.home.substitutes : [],
      teamLineups.away ? teamLineups.away.substitutes : []
    );
    if (teamLineups.home) teamLineups.home.substitutions = subs.home;
    if (teamLineups.away) teamLineups.away.substitutions = subs.away;
  }

  const homeScore = (event.intHomeScore !== null && event.intHomeScore !== undefined && event.intHomeScore !== "")
    ? Number(event.intHomeScore) : null;
  const awayScore = (event.intAwayScore !== null && event.intAwayScore !== undefined && event.intAwayScore !== "")
    ? Number(event.intAwayScore) : null;

  const result = {
    id: String(idEvent),
    match_details_id: String(idEvent),
    details_url: null,
    date: kickoff.date,
    time: kickoff.time,
    league,
    home_team: String(event.strHomeTeam || "").trim(),
    away_team: String(event.strAwayTeam || "").trim(),
    home_team_id: String(event.idHomeTeam || "").trim() || null,
    away_team_id: String(event.idAwayTeam || "").trim() || null,
    home_score: homeScore,
    away_score: awayScore,
    aggregate_home_score: null,
    aggregate_away_score: null,
    score_status: scoreStatus,
    has_tsdb_source: true,
    ...timelineEvents,
  };

  // Aggregate from schedule cache (if provided via options).
  if (Array.isArray(options.scheduleCache) && options.scheduleCache.length > 0) {
    const agg = computeAggregateFromSchedule(
      { ...event, home_team: result.home_team, away_team: result.away_team, date: result.date },
      options.scheduleCache
    );
    if (agg) {
      result.aggregate_home_score = agg.aggregate_home_score;
      result.aggregate_away_score = agg.aggregate_away_score;
    }
  }

  if (teamLineups) {
    result.team_lineups = teamLineups;
    void warmTsdbEntityCaches(event, lineupEntries, {
      ...reqOpts,
      trigger: reqOpts.trigger || "match_details_entity_warm",
    }).catch((error) => {
      console.warn(`[TSDB] Failed to warm team/player caches for event=${idEvent}:`, error.message || error);
    });
  }

  return result;
}

async function refreshTsdbSupplementalCachesForMatch(match, options = {}) {
  if (!match || typeof match !== "object") return null;
  const idEvent = String(match.id || match.match_details_id || "").trim();
  if (!/^\d+$/.test(idEvent)) return null;
  const reqOpts = {
    initiator: options.initiator || "scraper",
    trigger: options.trigger || "tsdb_supplemental_cache_refresh",
  };
  const scoreStatus = match.score_status || match.match_time || null;
  const kickoffDate = String(match.date || "").trim() || null;
  const [timelineResp, lineupResp] = await Promise.all([
    cachedOrFetchMatchTimeline(
      idEvent,
      { scoreStatus, nowMs: options.nowMs },
      reqOpts
    ),
    cachedOrFetchMatchLineup(
      idEvent,
      {
        scoreStatus,
        kickoffDate,
        nowMs: options.nowMs,
        forceRefresh: options.forceLineupRefresh === true,
      },
      reqOpts
    ),
  ]);
  const timeline = Array.isArray(timelineResp && timelineResp.lookup)
    ? timelineResp.lookup
    : [];
  const lineupEntries = Array.isArray(lineupResp && lineupResp.lookup)
    ? lineupResp.lookup
    : [];
  if (lineupEntries.length > 0) {
    void warmTsdbEntityCaches({}, lineupEntries, reqOpts).catch((error) => {
      console.warn(`[TSDB] Failed to warm player caches for event=${idEvent}:`, error.message || error);
    });
  }
  return {
    id: idEvent,
    lineup_count: lineupEntries.length,
    timeline_count: timeline.length,
  };
}

// ---------------------------------------------------------------------------
// Public API: fetchTsdbLeagueTeams
// Replaces fetchPremierLeagueTeams — returns an array of team name strings.
// ---------------------------------------------------------------------------

async function fetchTsdbLeagueTeams(idLeague, options = {}) {
  const resp = await getLeagueTeams(idLeague, {
    initiator: options.initiator || "scraper",
    reason: options.reason || "tsdb_league_teams_fetch",
    trigger: options.trigger,
  });

  const teams = Array.isArray(resp && resp.teams) ? resp.teams : [];
  return teams
    .map((t) => String(t.strTeam || "").trim())
    .filter(Boolean);
}

// Convenience: fetch EPL teams (direct replacement for fetchPremierLeagueTeams).
function fetchTsdbPremierLeagueTeams(options = {}) {
  return fetchTsdbLeagueTeams(TSDB_EPL_LEAGUE_ID, options);
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

module.exports = {
  // Observer passthrough — wire to the same handler as BBC observers.
  setTsdbRequestObserver: setRequestObserver,

  // Data fetchers
  fetchTsdbLivescores,
  fetchTsdbLeagueSchedule,
  fetchTsdbAllLeagueSchedules,
  fetchTsdbMatchDetails,
  refreshTsdbSupplementalCachesForMatch,
  fetchTsdbLeagueTeams,
  fetchTsdbPremierLeagueTeams,

  // Helpers (exposed for tests)
  __private: {
    mapTsdbStatus,
    parseTimelineEvents,
    isDisallowedGoalVarDetail,
    parseLineups,
    assignFormationGridPositions,
    positionSideHint,
    preferredSlotsForHint,
    extractSubstitutionsFromTimeline,
    computeAggregateFromSchedule,
    resolveLeagueName,
    stripSeconds,
    normalizeTsdbKickoffDateTime,
    lineupPayloadHasEntries,
    matchLineupCacheFresh,
    timelinePayloadHasEntries,
    matchTimelineCacheFresh,
  },
};
