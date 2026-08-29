#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// BSD → canonical match adapter.
//
// Projects the already-ingested `bsd_*` Mongo collections into the canonical
// match shape consumed by the API, website, iOS app, widgets, and monitor.
// ---------------------------------------------------------------------------

const { canonicalTeamName } = require("./team_identity");
const { utcDateTimeToZonedDateTime } = require("./match_time");
const { getBsdRecords } = require("./mongo_client");
const { BSD_LEAGUE_ALLOWLIST } = require("./bsd_config");
const { bsdPlayerImageUrl } = require("./player_images");
const SunCalc = require("suncalc");

// BSD league_id → canonical league name used by clients and preferences.
const BSD_LEAGUE_NAME_MAP = {
  "27": "FIFA World Cup 2026",
  "1": "Premier League",
  "12": "Championship",
  "86": "League One",
  "87": "League Two",
  "13": "Scottish Premiership",
  "5": "Bundesliga",
  "4": "Serie A",
  "6": "Ligue 1",
  "3": "La Liga",
  "10": "Dutch Eredivisie",
  "39": "FA Cup",
  "40": "EFL Cup",
  "43": "DFB-Pokal",
  "42": "Coppa Italia",
  "44": "Coupe de France",
  "41": "Copa del Rey",
  "7": "UEFA Champions League",
  "8": "UEFA Europa League",
  "83": "UEFA Conference League",
  "90": "UEFA Super Cup",
  "64": "UEFA Nations League",
  "31": "International Friendly",
  "58": "World Cup Qualifying UEFA",
  "59": "World Cup Qualifying CONMEBOL",
  "62": "World Cup Qualifying CONCACAF",
  "63": "World Cup Qualifying OFC",
};

// BSD serves a tiny placeholder for venues whose source image is missing.
// Keep verified replacements explicit so clients never render that placeholder.
const BSD_VENUE_IMAGE_OVERRIDES = {
  "198": "https://upload.wikimedia.org/wikipedia/commons/thumb/c/ce/Coventry_Building_Society_Arena_november_2025.jpg/1280px-Coventry_Building_Society_Arena_november_2025.jpg",
};

// BSD's standings endpoint can omit teams until they have played their first
// match of a new season. For domestic round-robin leagues, complete the table
// roster from BSD fixtures for the exact same league + season. Keep this list
// explicit so knockout competitions with an empty standings payload are not
// projected as fake league tables.
const BSD_FIXTURE_SEEDED_STANDINGS_TEAM_COUNTS = new Map([
  ["1", 20],  // Premier League
  ["12", 24], // Championship
  ["86", 24], // League One
  ["87", 24], // League Two
  ["13", 12], // Scottish Premiership
  ["5", 18],  // Bundesliga
  ["4", 20],  // Serie A
  ["6", 18],  // Ligue 1
  ["3", 20],  // La Liga
  ["10", 18], // Dutch Eredivisie
]);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Undetermined knockout slots ("W101", "L33", "1A", "H2", "3D/3E/3I") are not
// real teams and must not surface as fixtures until the team is decided.
function isPlaceholderTeam(name) {
  const n = String(name || "").trim();
  if (!n) return true;
  if (/^\d[A-Za-z](?:\/\d[A-Za-z])+$/i.test(n)) return true; // "3D/3E/3I" composite slot
  if (/^[WL]\d+$/i.test(n)) return true; // W101 / L33 (winner/loser of match N)
  if (/^\d[A-Za-z]$/.test(n)) return true; // 1A, 2B (group position)
  if (/^[A-Za-z]\d+$/.test(n) && n.length <= 3) return true; // H2, G1
  return false;
}

// Format a minute as "67'" or "45+6'".
function bsdMinute(minute, addedTime) {
  if (minute === null || minute === undefined || minute === "") return null;
  const base = String(minute).trim();
  if (!base || base === "0") return null;
  const added = Number(addedTime);
  if (Number.isFinite(added) && added > 0) return `${base}+${added}'`;
  return `${base}'`;
}

// BSD position code (G/D/M/F) → canonical category.
function bsdPositionCategory(position) {
  switch (String(position || "").trim().toUpperCase()) {
    case "G": return "goalkeeper";
    case "D": return "defender";
    case "M": return "midfielder";
    case "F": return "attacker";
    default: return null;
  }
}

function parseFormationRows(formation) {
  if (!formation) return null;
  const parts = String(formation)
    .trim()
    .replace(/\s+/g, "-")
    .split("-")
    .map((value) => Number.parseInt(value, 10))
    .filter((value) => Number.isFinite(value) && value > 0);
  return parts.length >= 2 ? [1, ...parts] : null;
}

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

  const screenRightPreferredSlots = rowSize === 4
    ? [...screenRightSlots].reverse()
    : screenRightSlots;
  const logicalLeftSlots = side === "home" ? screenRightPreferredSlots : screenLeftSlots;
  const logicalRightSlots = side === "home" ? screenLeftSlots : screenRightPreferredSlots;
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
    if (hint) groups[hint].push(player);
  });

  ["right", "left", "centre"].forEach((hint) => {
    const players = groups[hint];
    const slots = preferredSlotsForHint(hint, rowSize, side);
    if (players.length === 0 || players.length > slots.length) return;
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
  for (let slot = 0; slot < rowSize; slot += 1) {
    if (assignment[slot] !== null) continue;
    assignment[slot] = unassigned[cursor];
    cursor += 1;
  }
  return assignment.filter(Boolean);
}

function assignFormationGridPositions(starters, formation, options = {}) {
  const roleOrder = { goalkeeper: 0, defender: 1, midfielder: 2, attacker: 3 };
  const side = options.side === "away" ? "away" : "home";
  const sorted = [...starters].sort((left, right) => {
    const roleDifference =
      (roleOrder[left.position_category] ?? 4) - (roleOrder[right.position_category] ?? 4);
    return roleDifference || (left.number ?? 99) - (right.number ?? 99);
  });
  const rows = parseFormationRows(formation);
  if (!rows) {
    return sorted.map((player, index) => ({
      ...player,
      formation_row_index: 0,
      formation_slot_index: index,
      formation_row_size: sorted.length,
    }));
  }

  const result = [];
  let cursor = 0;
  for (let rowIndex = 0; rowIndex < rows.length && cursor < sorted.length; rowIndex += 1) {
    const players = sorted.slice(cursor, cursor + rows[rowIndex]);
    const ordered = rowIndex === 0 ? players : assignSideAwareRowSlots(players, side);
    ordered.forEach((player, slotIndex) => result.push({
      ...player,
      formation_row_index: rowIndex,
      formation_slot_index: slotIndex,
      formation_row_size: ordered.length,
    }));
    cursor += players.length;
  }
  if (cursor < sorted.length) {
    const overflow = sorted.slice(cursor);
    overflow.forEach((player, slotIndex) => result.push({
      ...player,
      formation_row_index: rows.length,
      formation_slot_index: slotIndex,
      formation_row_size: overflow.length,
    }));
  }
  return result;
}

// BSD's `decision` names what was under review (e.g. "goalAwarded");
// `confirmed` says whether that decision stood after review. Only a
// disallowed goal — a goal decision that did NOT stand — is surfaced as a VAR
// event; every other VAR review (confirmed goals, penalty/card checks,
// offside checks, etc.) is noise the user doesn't want in Match Events or
// notifications.
function isDisallowedGoalVarDecision(decision, confirmed) {
  return confirmed === false && /goal/i.test(String(decision || ""));
}

// Maps BSD status/period/current_minute to the internal score_status vocabulary:
// null | "HT" | "FT" | "AET" | "Pens" | "POSTPONED" | "ET" | "ET <minute>" | minute | "LIVE").
function mapBsdStatus(event, options = {}) {
  const status = String(event.status || "").trim().toLowerCase();
  const period = String(event.period || "").trim().toLowerCase();
  const periodSummary =
    options && options.periodSummary && typeof options.periodSummary === "object"
      ? options.periodSummary
      : null;
  const minute = event.current_minute;
  const minuteStr =
    minute !== null && minute !== undefined && minute !== "" && Number.isFinite(Number(minute))
      ? String(Number(minute))
      : null;
  const kickoffMs = Date.parse(String(event.event_date || ""));
  const isFutureScorelessKickoff =
    Number.isFinite(kickoffMs) &&
    kickoffMs > Date.now() &&
    toNumber(event.home_score) === null &&
    toNumber(event.away_score) === null;

  if (!status || status === "notstarted" || status === "not_started" || status === "ns") {
    return null;
  }
  if (isFutureScorelessKickoff && !minuteStr && !period) {
    return null;
  }
  if (["postponed", "cancelled", "canceled", "abandoned", "suspended", "interrupted", "void"].includes(status)) {
    return "POSTPONED";
  }
  if (periodSummary && periodSummary.penaltyShootout) {
    return "AET";
  }
  if (status === "finished" || status === "ft" || status === "aet" || period === "ft") {
    if (event.penalty_shootout != null) return "AET";
    if (event.extra_time_score != null) return "AET";
    if (periodSummary && periodSummary.extraTimeScore) return "AET";
    if (period.includes("extra")) return "AET";
    return "FT";
  }
  if (status === "halftime" || status === "ht" || period === "ht" || period === "halftime") {
    return "HT";
  }
  // In progress.
  if (period.includes("penal") || status.includes("penal")) return "Pens";
  if (period.includes("extra")) return minuteStr ? `ET ${minuteStr}` : "ET";
  if (["1st_half", "first_half", "1h"].includes(period) && Number(minute) > 45) {
    return `45+${Number(minute) - 45}`;
  }
  return minuteStr || "LIVE";
}

function parseScorePair(value) {
  const match = String(value || "").match(/(\d+)\s*-\s*(\d+)/);
  if (!match) return null;
  const home = Number(match[1]);
  const away = Number(match[2]);
  if (!Number.isFinite(home) || !Number.isFinite(away)) return null;
  return { home, away };
}

function extractBsdPeriodSummary(incidents) {
  const summary = {
    penaltyShootout: null,
    extraTimeScore: null,
    fullTimeScore: null,
  };
  (Array.isArray(incidents) ? incidents : []).forEach((inc) => {
    if (!inc || inc.type !== "period") return;
    const text = String(inc.text || "").trim().toUpperCase();
    const home = toNumber(inc.home_score);
    const away = toNumber(inc.away_score);
    if (!Number.isFinite(home) || !Number.isFinite(away)) return;
    const score = { home, away };
    if (text === "PEN" && inc.is_live === false) {
      summary.penaltyShootout = score;
    } else if (text === "ET") {
      summary.extraTimeScore = score;
    } else if (text === "FT") {
      summary.fullTimeScore = score;
    }
  });
  return summary;
}

function resolveBsdPenaltyShootout(event, periodSummary) {
  if (periodSummary && periodSummary.penaltyShootout) {
    return periodSummary.penaltyShootout;
  }
  const shootout = event && event.penalty_shootout;
  if (!shootout || typeof shootout !== "object") return null;
  const home = toNumber(shootout.home);
  const away = toNumber(shootout.away);
  if (!Number.isFinite(home) || !Number.isFinite(away)) return null;
  return { home, away };
}

// BSD's top-level home_score/away_score is the regular-time score; goals
// scored in extra time are reported separately in extra_time_score and must
// be added on to get the true final score (e.g. 1-1 after 90 + 2-1 in ET = 3-2).
function resolveBsdExtraTimeScore(event) {
  const extraTime = event && event.extra_time_score;
  if (extraTime == null) return null;
  if (typeof extraTime === "string") return parseScorePair(extraTime);
  if (typeof extraTime === "object") {
    const home = toNumber(extraTime.home);
    const away = toNumber(extraTime.away);
    if (!Number.isFinite(home) || !Number.isFinite(away)) return null;
    return { home, away };
  }
  return null;
}

function buildPenaltyResultText(homeTeam, awayTeam, shootout) {
  if (!shootout || !Number.isFinite(shootout.home) || !Number.isFinite(shootout.away)) {
    return null;
  }
  if (shootout.home === shootout.away) {
    return `${shootout.home}-${shootout.away}`;
  }
  const homeWins = shootout.home > shootout.away;
  const winner = homeWins ? homeTeam : awayTeam;
  const winnerScore = homeWins ? shootout.home : shootout.away;
  const loserScore = homeWins ? shootout.away : shootout.home;
  return `${winner} win ${winnerScore} - ${loserScore} on penalties`;
}

// ---------------------------------------------------------------------------
// Incidents → goal scorers / assists / cards / VAR
// ---------------------------------------------------------------------------

function parseBsdIncidents(incidents) {
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
  };
  if (!Array.isArray(incidents) || incidents.length === 0) return result;

  const homeGoals = new Map();
  const awayGoals = new Map();
  const homeAssists = new Map();
  const awayAssists = new Map();
  const homeYellow = new Map();
  const awayYellow = new Map();
  const homeRed = new Map();
  const awayRed = new Map();

  function addGoal(map, player, playerId, time, isOwn) {
    if (!player || !time) return;
    const key = playerId ? `id:${playerId}` : `name:${player}`;
    const existing = map.get(key) || {
      player,
      ...(playerId ? { id_player: playerId } : {}),
      goal_times: [],
      own_goal_times: [],
    };
    const bucket = isOwn ? existing.own_goal_times : existing.goal_times;
    if (!bucket.includes(time)) bucket.push(time);
    map.set(key, existing);
  }
  function addAssist(map, player, time) {
    if (!player || !time) return;
    const existing = map.get(player) || { player, assist_times: [] };
    if (!existing.assist_times.includes(time)) existing.assist_times.push(time);
    map.set(player, existing);
  }
  function addCard(map, player, playerId, time, field) {
    if (!player || !time) return;
    const key = playerId ? `id:${playerId}` : `name:${player}`;
    const existing = map.get(key) || {
      player,
      ...(playerId ? { id_player: playerId } : {}),
      [field]: [],
    };
    if (!existing[field].includes(time)) existing[field].push(time);
    map.set(key, existing);
  }

  incidents.forEach((inc) => {
    if (!inc || typeof inc !== "object") return;
    const home = inc.is_home === true;
    const minute = bsdMinute(inc.minute, inc.added_time);
    const player = String(inc.player || "").trim() || null;
    const playerId = /^\d+$/.test(String(inc.player_id ?? "").trim())
      ? String(inc.player_id).trim()
      : null;

    if (inc.type === "goal") {
      const own = String(inc.goal_type || "").toLowerCase().includes("own");
      const assist = String(inc.assist || "").trim() || null;
      if (own) {
        // BSD marks is_home as the side awarded the goal. Keep the scorer in
        // the opposing (player's actual) team array so lineup IDs resolve.
        addGoal(home ? awayGoals : homeGoals, player, playerId, minute, true);
      } else {
        addGoal(home ? homeGoals : awayGoals, player, playerId, minute, false);
        if (assist) addAssist(home ? homeAssists : awayAssists, assist, minute);
      }
    } else if (inc.type === "card") {
      const cardType = String(inc.card_type || "").toLowerCase();
      if (cardType.includes("red")) {
        addCard(home ? homeRed : awayRed, player, playerId, minute, "red_card_times");
      } else if (cardType.includes("yellow")) {
        addCard(home ? homeYellow : awayYellow, player, playerId, minute, "yellow_card_times");
      }
    } else if (inc.type === "varDecision") {
      if (isDisallowedGoalVarDecision(inc.decision, inc.confirmed)) {
        (home ? result.home_var_events : result.away_var_events).push({
          player,
          ...(playerId ? { id_player: playerId } : {}),
          minute,
          detail: "VAR: Goal disallowed",
        });
      }
    }
  });

  const materialiseGoals = (map) =>
    Array.from(map.values()).map((e) => {
      const out = {
        player: e.player,
        ...(e.id_player ? { id_player: e.id_player } : {}),
      };
      if (e.goal_times.length) out.goal_times = e.goal_times;
      if (e.own_goal_times.length) out.own_goal_times = e.own_goal_times;
      return out;
    });
  const materialiseAssists = (map) =>
    Array.from(map.values()).filter((e) => e.assist_times && e.assist_times.length);
  const materialiseCards = (map, field) =>
    Array.from(map.values()).filter((e) => e[field] && e[field].length);

  result.home_goal_scorers = materialiseGoals(homeGoals);
  result.away_goal_scorers = materialiseGoals(awayGoals);
  result.home_assists = materialiseAssists(homeAssists);
  result.away_assists = materialiseAssists(awayAssists);
  result.home_yellow_cards = materialiseCards(homeYellow, "yellow_card_times");
  result.away_yellow_cards = materialiseCards(awayYellow, "yellow_card_times");
  result.home_red_cards = materialiseCards(homeRed, "red_card_times");
  result.away_red_cards = materialiseCards(awayRed, "red_card_times");
  return result;
}

// ---------------------------------------------------------------------------
// Lineups
// ---------------------------------------------------------------------------

function bsdPlayerEntry(player) {
  if (!player || typeof player !== "object") return null;
  const name = String(player.name || player.short_name || "").trim();
  if (!name) return null;
  const number = Number(player.jersey_number);
  const position = String(player.position || "").trim() || null;
  const bsdPlayerId = player.id != null ? String(player.id) : null;
  return {
    number: Number.isFinite(number) ? number : null,
    name,
    id_player: bsdPlayerId,
    bsd_player_id: bsdPlayerId,
    position_category: bsdPositionCategory(position),
    position,
    position_short: position,
    cutout_url: bsdPlayerImageUrl(bsdPlayerId),
  };
}

function extractBsdSubstitutions(incidents, homeLineup, awayLineup) {
  const home = [];
  const away = [];
  const buildLookup = (lineup) => {
    const map = new Map();
    if (lineup) {
      [...(lineup.starting_lineup || []), ...(lineup.substitutes || [])].forEach((p) => {
        if (p && p.name) map.set(p.name.toLowerCase(), p.number ?? null);
      });
    }
    return map;
  };
  const homeLookup = buildLookup(homeLineup);
  const awayLookup = buildLookup(awayLineup);

  (Array.isArray(incidents) ? incidents : []).forEach((inc) => {
    if (!inc || inc.type !== "substitution") return;
    const minute = bsdMinute(inc.minute, inc.added_time);
    if (!minute) return;
    const playerOn = String(inc.player_in || "").trim() || null;
    const playerOff = String(inc.player_out || "").trim() || null;
    const playerOnId = /^\d+$/.test(String(inc.player_in_id ?? "").trim())
      ? String(inc.player_in_id).trim()
      : null;
    const playerOffId = /^\d+$/.test(String(inc.player_out_id ?? "").trim())
      ? String(inc.player_out_id).trim()
      : null;
    if (!playerOn) return;
    const home_ = inc.is_home === true;
    const lookup = home_ ? homeLookup : awayLookup;
    const subEvent = {
      minute,
      player_off: playerOff ? {
        number: lookup.get(playerOff.toLowerCase()) ?? null,
        name: playerOff,
        ...(playerOffId ? { id_player: playerOffId } : {}),
      } : null,
      player_on: {
        number: lookup.get(playerOn.toLowerCase()) ?? null,
        name: playerOn,
        ...(playerOnId ? { id_player: playerOnId } : {}),
      },
    };
    (home_ ? home : away).push(subEvent);
  });

  const byMinute = (a, b) =>
    (Number(String(a.minute).replace(/[^0-9]/g, "")) || 0) -
    (Number(String(b.minute).replace(/[^0-9]/g, "")) || 0);
  home.sort(byMinute);
  away.sort(byMinute);
  return { home, away };
}

function buildBsdTeamLineups(lineupsPayload, incidents, options = {}) {
  const lineups = lineupsPayload && lineupsPayload.lineups;
  if (!lineups || typeof lineups !== "object") return null;

  const out = {};
  ["home", "away"].forEach((side) => {
    const team = lineups[side];
    if (!team) return;
    const starters = (Array.isArray(team.players) ? team.players : [])
      .map((player) => bsdPlayerEntry(player))
      .filter(Boolean);
    const substitutes = (Array.isArray(team.substitutes) ? team.substitutes : [])
      .map((player) => bsdPlayerEntry(player))
      .filter(Boolean);
    if (starters.length === 0 && substitutes.length === 0) return;
    const formation = String(team.formation || "").trim() || null;
    out[side] = {
      formation,
      starting_lineup: assignFormationGridPositions(starters, formation, { side }),
      substitutes,
    };
  });

  if (Object.keys(out).length === 0) return null;

  const subs = extractBsdSubstitutions(incidents, out.home, out.away);
  if (out.home) out.home.substitutions = subs.home;
  if (out.away) out.away.substitutions = subs.away;
  return out;
}

// ---------------------------------------------------------------------------
// Event → canonical match
// ---------------------------------------------------------------------------

function canonicalLeagueName(event, leagueNameById) {
  const id = event.league_id != null ? String(event.league_id) : null;
  if (id && BSD_LEAGUE_NAME_MAP[id]) return BSD_LEAGUE_NAME_MAP[id];
  if (event.league_name) return String(event.league_name).trim();
  if (id && leagueNameById && leagueNameById.has(id)) return leagueNameById.get(id);
  return null;
}

// Splits a BSD ISO event_date into UTC date + time, then converts it through
// the shared match-time helper used by all clients.
function zonedKickoff(eventDate) {
  const ms = Date.parse(String(eventDate || ""));
  if (!Number.isFinite(ms)) return { date: null, time: null };
  const iso = new Date(ms).toISOString();
  return utcDateTimeToZonedDateTime(iso.slice(0, 10), iso.slice(11, 16));
}

function bsdVenueCoordinates(venue) {
  if (!venue || typeof venue !== "object") return null;
  const latitude = Number(venue && venue.latitude);
  const longitude = Number(venue && venue.longitude);
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;
  if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) return null;
  return { latitude, longitude };
}

function bsdVenueDetails(venueId, venue) {
  if (!venueId || !venue || typeof venue !== "object") return null;
  const name = String(venue.name || "").trim();
  if (!name) return null;

  const finiteNumber = (value) => {
    if (value === null || value === undefined || value === "") return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  };

  return {
    id: String(venueId),
    name,
    city: String(venue.city || "").trim() || null,
    country: String(venue.country || "").trim() || null,
    capacity: finiteNumber(venue.capacity),
    built_year: finiteNumber(venue.built_year),
    latitude: finiteNumber(venue.latitude),
    longitude: finiteNumber(venue.longitude),
    image_url: BSD_VENUE_IMAGE_OVERRIDES[String(venueId)]
      || `https://sports.bzzoiro.com/img/venue/${encodeURIComponent(String(venueId))}/`,
  };
}

// SunCalc returns the solar altitude in radians at the exact instant. The
// standard sunrise/sunset threshold is -0.833° (upper limb plus atmospheric
// refraction), keeping this independent of server/device time zones while also
// handling polar day/night without special date arithmetic.
function bsdKickoffLightContext(eventDate, venue) {
  const kickoff = new Date(String(eventDate || ""));
  if (!Number.isFinite(kickoff.getTime())) return null;
  const coordinates = bsdVenueCoordinates(venue);
  if (!coordinates) return null;
  const position = SunCalc.getPosition(kickoff, coordinates.latitude, coordinates.longitude);
  const sunsetAltitudeRadians = -0.833 * (Math.PI / 180);
  return Number.isFinite(position.altitude) && position.altitude >= sunsetAltitudeRadians
    ? "day"
    : "night";
}

function fallbackKickoffLightContext(kickoff) {
  const hour = Number(String(kickoff && kickoff.time ? kickoff.time : "").split(":")[0]);
  if (!Number.isFinite(hour)) return "night";
  return hour >= 6 && hour < 18 ? "day" : "night";
}

function toNumber(value) {
  return value !== null && value !== undefined && value !== "" ? Number(value) : null;
}

function bsdEventScoreIncludingExtraTime(event) {
  const home = toNumber(event && event.home_score);
  const away = toNumber(event && event.away_score);
  if (!Number.isFinite(home) || !Number.isFinite(away)) return null;
  const extraTime = resolveBsdExtraTimeScore(event);
  return {
    home: home + (extraTime ? extraTime.home : 0),
    away: away + (extraTime ? extraTime.away : 0),
  };
}

function applyBsdTwoLegAggregates(events, matches) {
  const eventsById = new Map(
    (Array.isArray(events) ? events : [])
      .filter((event) => event && event.id != null)
      .map((event) => [String(event.id), event])
  );
  const matchesById = new Map(
    (Array.isArray(matches) ? matches : [])
      .filter((match) => match && match.id != null)
      .map((match) => [String(match.id), match])
  );

  eventsById.forEach((event, eventId) => {
    const previousLegId = String(event.previous_leg_event_id || "").trim();
    if (!previousLegId || previousLegId === eventId) return;
    const previousLeg = eventsById.get(previousLegId);
    const match = matchesById.get(eventId);
    if (!previousLeg || !match) return;
    if (String(previousLeg.status || "").trim().toLowerCase() !== "finished") return;
    for (const field of ["league_id", "season_id", "round_number"]) {
      if (
        event[field] != null &&
        previousLeg[field] != null &&
        String(event[field]) !== String(previousLeg[field])
      ) {
        return;
      }
    }

    const currentHomeTeamId = String(event.home_team_id || "").trim();
    const currentAwayTeamId = String(event.away_team_id || "").trim();
    const previousHomeTeamId = String(previousLeg.home_team_id || "").trim();
    const previousAwayTeamId = String(previousLeg.away_team_id || "").trim();
    const previousScore = bsdEventScoreIncludingExtraTime(previousLeg);
    if (
      !currentHomeTeamId ||
      !currentAwayTeamId ||
      !previousScore
    ) {
      return;
    }

    let firstLegHomeScore;
    let firstLegAwayScore;
    if (
      currentHomeTeamId === previousHomeTeamId &&
      currentAwayTeamId === previousAwayTeamId
    ) {
      firstLegHomeScore = previousScore.home;
      firstLegAwayScore = previousScore.away;
    } else if (
      currentHomeTeamId === previousAwayTeamId &&
      currentAwayTeamId === previousHomeTeamId
    ) {
      firstLegHomeScore = previousScore.away;
      firstLegAwayScore = previousScore.home;
    } else {
      return;
    }

    const currentScore = bsdEventScoreIncludingExtraTime(event);
    match.first_leg_home_score = firstLegHomeScore;
    match.first_leg_away_score = firstLegAwayScore;
    match.aggregate_home_score = firstLegHomeScore + (
      currentScore ? currentScore.home : 0
    );
    match.aggregate_away_score = firstLegAwayScore + (
      currentScore ? currentScore.away : 0
    );
  });

  return matches;
}

// BSD broadcasts are fetched filtered to GB, so every channel is a UK listing.
// Project a bsd_broadcasts payload's channels into the structured TvChannel
// shape the clients expect ({ name, country, countryCode, logo }), matching
// the canonical channel payload. countryCode "GB" lets the clients' locale
// filter surface them; logo is null because clients resolve logos by name.
function bsdBroadcastChannels(broadcastsPayload) {
  const channels =
    broadcastsPayload && Array.isArray(broadcastsPayload.channels)
      ? broadcastsPayload.channels
      : [];
  const out = [];
  const seen = new Set();
  channels.forEach((c) => {
    const name = String((c && c.channel_name) || "").trim();
    if (!name) return;
    const key = name.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ name, country: "United Kingdom", countryCode: "GB", logo: null });
  });
  return out;
}

// ---------------------------------------------------------------------------
// Standings (league tables)
// ---------------------------------------------------------------------------

// BSD form strings are oldest-first ("WWWWL"); the clients render the form
// array left-to-right as most-recent-first, so take the last 5 results then
// reverse to put the newest result first.
function parseBsdFormString(form) {
  if (!form) return [];
  return String(form)
    .toUpperCase()
    .split("")
    .filter((c) => c === "W" || c === "D" || c === "L")
    .slice(-5)
    .reverse();
}

function bsdStandingsRowToCanonical(row) {
  return {
    position: toNumber(row && row.position) || 0,
    team: canonicalTeamName(row && row.team_name),
    played: toNumber(row && row.played) || 0,
    won: toNumber(row && row.won) || 0,
    drawn: toNumber(row && row.drawn) || 0,
    lost: toNumber(row && row.lost) || 0,
    goals_for: toNumber(row && row.gf) || 0,
    goals_against: toNumber(row && row.ga) || 0,
    goal_difference: toNumber(row && row.gd) || 0,
    points: toNumber(row && row.pts) || 0,
    form: parseBsdFormString(row && row.form),
    rank_status: null,
  };
}

function bsdStandingsZonesToCanonical(zones) {
  if (!Array.isArray(zones)) return [];

  return zones.reduce((out, zone) => {
    if (!zone || typeof zone !== "object") return out;
    const from = toNumber(zone.from);
    const to = toNumber(zone.to);
    const label = String(zone.label || "").trim();
    if (
      !Number.isInteger(from) ||
      !Number.isInteger(to) ||
      from < 1 ||
      to < from ||
      !label
    ) {
      return out;
    }

    out.push({
      key: String(zone.key || "").trim(),
      label,
      type: String(zone.type || "").trim(),
      from,
      to,
    });
    return out;
  }, []);
}

function bsdStandingsRowSort(left, right) {
  return (
    right.points - left.points ||
    right.goal_difference - left.goal_difference ||
    right.goals_for - left.goals_for ||
    left.team.localeCompare(right.team)
  );
}

function completeBsdStandingsRowsFromEvents(rows, events, { leagueId, seasonId } = {}) {
  const normalizedLeagueId = leagueId != null ? String(leagueId) : null;
  if (
    !normalizedLeagueId ||
    !BSD_FIXTURE_SEEDED_STANDINGS_TEAM_COUNTS.has(normalizedLeagueId)
  ) {
    return rows;
  }

  const sourceRows = Array.isArray(rows) ? rows : [];
  const completed = sourceRows.map((row) => ({ ...row }));
  const teamKeys = new Set(
    completed.map((row) => String(row.team || "").trim().toLowerCase()).filter(Boolean)
  );

  (Array.isArray(events) ? events : []).forEach((event) => {
    if (!event || String(event.league_id) !== normalizedLeagueId) return;
    if (seasonId != null && String(event.season_id) !== String(seasonId)) return;

    [event.home_team, event.away_team].forEach((rawTeam) => {
      if (isPlaceholderTeam(rawTeam)) return;
      const team = canonicalTeamName(rawTeam);
      const key = String(team || "").trim().toLowerCase();
      if (!key || teamKeys.has(key)) return;
      teamKeys.add(key);
      completed.push({
        position: 0,
        team,
        played: 0,
        won: 0,
        drawn: 0,
        lost: 0,
        goals_for: 0,
        goals_against: 0,
        goal_difference: 0,
        points: 0,
        form: [],
        rank_status: null,
      });
    });
  });

  if (completed.length === sourceRows.length) return rows;
  return completed
    .sort(bsdStandingsRowSort)
    .map((row, index) => ({ ...row, position: index + 1 }));
}

// Projects one bsd_standings payload (the raw /leagues/:id/standings response)
// into the canonical league-table shape consumed by the clients.
// `leagueId`/`updatedAt` come from the Mongo doc wrapper; `leagueNameById`
// resolves a human league name when BSD_LEAGUE_NAME_MAP has no entry.
function bsdStandingsPayloadToTable(
  payload,
  { leagueId, updatedAt, leagueNameById, events = [] } = {}
) {
  if (!payload) return null;
  const id = String(leagueId != null ? leagueId : payload.league_id);
  if (!id) return null;
  const leagueName =
    BSD_LEAGUE_NAME_MAP[id] ||
    (leagueNameById && leagueNameById.get(id)) ||
    id;
  const season = (payload.season && payload.season.name) || null;

  let groups = [];
  let rows = [];

  // BSD standings figures are pre-match (a result lands once BSD folds it in),
  // so this canonical table is a clean baseline of completed matches. The
  // server overlays in-progress match results on top (see
  // applyLiveResultsToBsdTable), which owns the `realtime` flag and the
  // client-facing `live` / `previous_position`.
  if (payload.grouped && payload.groups && typeof payload.groups === "object") {
    groups = Object.keys(payload.groups)
      .sort()
      .map((name) => ({
        name,
        rows: (payload.groups[name] || []).map(bsdStandingsRowToCanonical),
      }));
  } else if (Array.isArray(payload.standings)) {
    rows = payload.standings.map(bsdStandingsRowToCanonical);
    rows = completeBsdStandingsRowsFromEvents(rows, events, {
      leagueId: id,
      seasonId: payload.season && payload.season.id,
    });
  } else {
    return null;
  }

  return {
    league_id: id,
    league_name: leagueName,
    stage_name: null,
    season,
    source_url: `https://sports.bzzoiro.com/api/v2/leagues/${id}/standings`,
    updated_at: updatedAt || null,
    realtime: false,
    zones: bsdStandingsZonesToCanonical(payload.zones),
    groups,
    rows,
  };
}

function buildBsdStandingsEventsFilter(standingsDocs) {
  const clauses = [];
  (Array.isArray(standingsDocs) ? standingsDocs : []).forEach((doc) => {
    const leagueId = doc && doc._id != null ? String(doc._id) : null;
    const payload = doc && doc.payload;
    const seasonId = payload && payload.season && payload.season.id;
    const expectedTeamCount = BSD_FIXTURE_SEEDED_STANDINGS_TEAM_COUNTS.get(leagueId);
    const standingsCount = Array.isArray(payload && payload.standings)
      ? payload.standings.length
      : 0;
    if (
      !leagueId ||
      seasonId == null ||
      !expectedTeamCount ||
      standingsCount >= expectedTeamCount
    ) {
      return;
    }
    clauses.push({
      $and: [
        {
          $or: [
            { league_id: { $in: mongoIds([leagueId]) } },
            { "payload.league_id": { $in: mongoIds([leagueId]) } },
          ],
        },
        {
          $or: [
            { season_id: { $in: mongoIds([seasonId]) } },
            { "payload.season_id": { $in: mongoIds([seasonId]) } },
          ],
        },
      ],
    });
  });
  return clauses.length > 0 ? { $or: clauses } : null;
}

function bsdStandingsEventFromDoc(doc) {
  const payload = doc && doc.payload ? doc.payload : {};
  return {
    league_id: doc && doc.league_id != null ? doc.league_id : payload.league_id,
    season_id: doc && doc.season_id != null ? doc.season_id : payload.season_id,
    home_team: doc && doc.home_team ? doc.home_team : payload.home_team,
    away_team: doc && doc.away_team ? doc.away_team : payload.away_team,
  };
}

// Projects every allowlisted bsd_standings doc into the canonical table list.
async function projectBsdStandings() {
  const [standingsDocs, leagues] = await Promise.all([
    getBsdRecords("bsd_standings"),
    getBsdRecords("bsd_leagues"),
  ]);
  const eventsFilter = buildBsdStandingsEventsFilter(standingsDocs);
  const eventDocs = eventsFilter
    ? await getBsdRecords("bsd_events", eventsFilter, {
        projection: {
          league_id: 1,
          season_id: 1,
          home_team: 1,
          away_team: 1,
          "payload.league_id": 1,
          "payload.season_id": 1,
          "payload.home_team": 1,
          "payload.away_team": 1,
        },
      })
    : [];
  const standingsEvents = eventDocs.map(bsdStandingsEventFromDoc);
  const leagueNameById = new Map();
  leagues.forEach((doc) => {
    const p = doc.payload || {};
    if (p.id != null && p.name) leagueNameById.set(String(p.id), String(p.name));
  });

  const allowlist = new Set(BSD_LEAGUE_ALLOWLIST.map(String));
  const out = [];
  standingsDocs.forEach((doc) => {
    const leagueId = doc && doc._id != null ? String(doc._id) : null;
    if (!leagueId || !allowlist.has(leagueId)) return;
    const table = bsdStandingsPayloadToTable(doc.payload, {
      leagueId,
      updatedAt: doc.updated_at,
      leagueNameById,
      events: standingsEvents,
    });
    if (table) out.push(table);
  });
  return out;
}

// Build the canonical match. `detail: true` includes scorers/cards/lineups
// (for the detail endpoint); the list projection omits the heavy detail.
function bsdEventToCanonicalMatch(event, options = {}) {
  if (!event || typeof event !== "object") return null;
  const homeRaw = String(event.home_team || "").trim();
  const awayRaw = String(event.away_team || "").trim();

  // Future knockout-round slots ("W101", "L33", "3D/3E/3I") aren't real teams
  // until earlier rounds decide them, but the fixture itself (date/time/round)
  // is already known — show it with "TBC" rather than hiding it entirely.
  const home_team = isPlaceholderTeam(homeRaw) ? "TBC" : canonicalTeamName(homeRaw) || homeRaw;
  const away_team = isPlaceholderTeam(awayRaw) ? "TBC" : canonicalTeamName(awayRaw) || awayRaw;
  const kickoff = zonedKickoff(event.event_date);
  const venueId = event.venue_id != null ? String(event.venue_id) : null;
  const venue = venueId && options.venuesById ? options.venuesById.get(venueId) : null;
  const lightContext = bsdKickoffLightContext(event.event_date, venue)
    || fallbackKickoffLightContext(kickoff);
  const league = canonicalLeagueName(event, options.leagueNameById);
  const leagueSubcategory = event.round_name ? String(event.round_name).trim() : null;
  const id = event.id != null ? String(event.id) : null;
  const incidents =
    options.incidentsPayload && Array.isArray(options.incidentsPayload.incidents)
      ? options.incidentsPayload.incidents
      : [];
  const periodSummary = extractBsdPeriodSummary(incidents);
  const shootout = resolveBsdPenaltyShootout(event, periodSummary);
  const scoreStatus = mapBsdStatus(event, { periodSummary });
  const normalTimeScore =
    shootout && (periodSummary.extraTimeScore || periodSummary.fullTimeScore)
      ? periodSummary.extraTimeScore || periodSummary.fullTimeScore
      : null;
  const extraTimeScore = resolveBsdExtraTimeScore(event);
  const regularHomeScore = toNumber(event.home_score);
  const regularAwayScore = toNumber(event.away_score);
  const finalHomeScore =
    extraTimeScore && Number.isFinite(regularHomeScore)
      ? regularHomeScore + extraTimeScore.home
      : regularHomeScore;
  const finalAwayScore =
    extraTimeScore && Number.isFinite(regularAwayScore)
      ? regularAwayScore + extraTimeScore.away
      : regularAwayScore;

  // TV channels join: list projection passes a pre-loaded channelsByEventId
  // Map; detail projection passes the single event's broadcastsPayload.
  let tvChannels = [];
  if (options.channelsByEventId instanceof Map && id) {
    tvChannels = options.channelsByEventId.get(id) || [];
  } else if (options.broadcastsPayload) {
    tvChannels = bsdBroadcastChannels(options.broadcastsPayload);
  }

  const match = {
    id,
    match_details_id: id,
    home_team,
    away_team,
    home_team_id: event.home_team_id != null ? String(event.home_team_id) : null,
    away_team_id: event.away_team_id != null ? String(event.away_team_id) : null,
    venue_id: venueId,
    kickoff_at: Number.isFinite(Date.parse(String(event.event_date || "")))
      ? new Date(event.event_date).toISOString()
      : null,
    light_context: lightContext,
    home_score: normalTimeScore ? normalTimeScore.home : finalHomeScore,
    away_score: normalTimeScore ? normalTimeScore.away : finalAwayScore,
    aggregate_home_score: null,
    aggregate_away_score: null,
    score_status: scoreStatus,
    match_time: scoreStatus,
    date: kickoff.date,
    time: kickoff.time,
    league,
    league_subcategory: leagueSubcategory,
    season_id:
      event.season_id != null && Number.isFinite(Number(event.season_id))
        ? Number(event.season_id)
        : null,
    round_number:
      event.round_number != null && Number.isFinite(Number(event.round_number))
        ? Number(event.round_number)
        : null,
    details_url: null,
    has_bsd_source: true,
    // BSD's own freshness timestamp — used e.g. to time finished-match
    // retention on the Live Activity widget.
    updated_at: event.last_updated ? String(event.last_updated) : null,
    tv_channels: tvChannels,
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_assists: [],
    away_assists: [],
    home_yellow_cards: [],
    away_yellow_cards: [],
    home_red_cards: [],
    away_red_cards: [],
    penalty_result: buildPenaltyResultText(home_team, away_team, shootout),
  };

  if (options.detail) {
    const venueDetails = bsdVenueDetails(venueId, venue);
    if (venueDetails) match.venue_details = venueDetails;
    Object.assign(match, parseBsdIncidents(incidents));
    const teamLineups = buildBsdTeamLineups(options.lineupsPayload, incidents, {
      playerImageSource: options.playerImageSource,
    });
    if (teamLineups) match.team_lineups = teamLineups;
  }

  return match;
}

// ---------------------------------------------------------------------------
// Predictions
// ---------------------------------------------------------------------------

// Projects one /predictions result item ({ event, markets, ... }) into the
// lean shape the app's prediction algorithm needs: just enough to join onto a
// canonical match (team names + zoned kickoff) plus the markets payload
// verbatim — recommendations/model/created_at aren't consumed, so they're
// dropped to keep the response small.
function bsdPredictionFixtureToCanonical(item) {
  if (!item || typeof item !== "object") return null;
  const event = item.event || {};
  const id = event.id != null ? String(event.id) : null;
  if (!id) return null;

  const homeRaw = String(event.home_team || "").trim();
  const awayRaw = String(event.away_team || "").trim();
  const home_team = canonicalTeamName(homeRaw) || homeRaw;
  const away_team = canonicalTeamName(awayRaw) || awayRaw;
  const kickoff = zonedKickoff(event.event_date);

  return {
    event_id: id,
    home_team,
    away_team,
    date: kickoff.date,
    time: kickoff.time,
    markets: item.markets || null,
  };
}

// Projects one bsd_predictions payload (the raw /predictions?league_id=:id
// results array) into the canonical predictions-for-league shape.
function bsdPredictionsPayloadToLeague(payload, { leagueId, updatedAt, leagueNameById } = {}) {
  if (!Array.isArray(payload)) return null;
  const id = String(leagueId != null ? leagueId : "");
  if (!id) return null;
  const leagueName = BSD_LEAGUE_NAME_MAP[id] || (leagueNameById && leagueNameById.get(id)) || id;
  const fixtures = payload.map(bsdPredictionFixtureToCanonical).filter(Boolean);

  return {
    league_id: id,
    league_name: leagueName,
    updated_at: updatedAt || null,
    fixtures,
  };
}

// Projects every allowlisted bsd_predictions doc into the canonical
// predictions-by-league list.
async function projectBsdPredictions() {
  const [predictionDocs, leagues] = await Promise.all([
    getBsdRecords("bsd_predictions"),
    getBsdRecords("bsd_leagues"),
  ]);
  const leagueNameById = new Map();
  leagues.forEach((doc) => {
    const p = doc.payload || {};
    if (p.id != null && p.name) leagueNameById.set(String(p.id), String(p.name));
  });

  const allowlist = new Set(BSD_LEAGUE_ALLOWLIST.map(String));
  const out = [];
  predictionDocs.forEach((doc) => {
    const leagueId = doc && doc._id != null ? String(doc._id) : null;
    if (!leagueId || !allowlist.has(leagueId)) return;
    const league = bsdPredictionsPayloadToLeague(doc.payload, {
      leagueId,
      updatedAt: doc.updated_at,
      leagueNameById,
    });
    if (league) out.push(league);
  });
  return out;
}

// ---------------------------------------------------------------------------
// Top-level projection from Mongo
// ---------------------------------------------------------------------------

// Returns the leagueId(string) → currentSeasonId(number|null) map so historical
// fixtures (e.g. BSD carries 2022 World Cup events under the same league id) are
// excluded from the current-season projection.
async function loadCurrentSeasonByLeague() {
  const leagues = await getBsdRecords("bsd_leagues");
  const map = new Map();
  leagues.forEach((doc) => {
    const p = doc.payload || {};
    const id = p.id != null ? String(p.id) : doc._id;
    const seasonId =
      p.current_season && p.current_season.id != null ? Number(p.current_season.id) : null;
    if (id) map.set(String(id), seasonId);
  });
  return map;
}

function currentSeasonByLeagueFromDocs(leagues) {
  const map = new Map();
  (Array.isArray(leagues) ? leagues : []).forEach((doc) => {
    const payload = doc && doc.payload ? doc.payload : {};
    const leagueId = payload.id != null ? String(payload.id) : String((doc && doc._id) || "");
    if (!leagueId) return;
    const seasonId =
      payload.current_season && payload.current_season.id != null
        ? Number(payload.current_season.id)
        : null;
    map.set(leagueId, Number.isFinite(seasonId) ? seasonId : null);
  });
  return map;
}

function normalizedSeasonDate(value) {
  const match = String(value || "").trim().match(/^(\d{4}-\d{2}-\d{2})/);
  return match ? match[1] : null;
}

function nextUtcDateKey(dateKey) {
  const parsed = Date.parse(`${dateKey}T00:00:00Z`);
  if (!Number.isFinite(parsed)) return null;
  return new Date(parsed + 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
}

function currentSeasonContextByLeagueFromDocs(leagues) {
  const map = new Map();
  (Array.isArray(leagues) ? leagues : []).forEach((doc) => {
    const payload = doc && doc.payload ? doc.payload : {};
    const leagueId = payload.id != null ? String(payload.id) : String((doc && doc._id) || "");
    if (!leagueId) return;
    const season = payload.current_season || {};
    const seasonId = season.id != null ? Number(season.id) : null;
    const startDate = normalizedSeasonDate(season.start_date);
    const endDate = normalizedSeasonDate(season.end_date);
    map.set(leagueId, {
      seasonId: Number.isFinite(seasonId) ? seasonId : null,
      startDate,
      endDateExclusive: endDate ? nextUtcDateKey(endDate) : null,
    });
  });
  return map;
}

function currentSeasonId(context) {
  if (context && typeof context === "object") {
    if (context.seasonId == null) return null;
    const value = Number(context.seasonId);
    return Number.isFinite(value) ? value : null;
  }
  if (context == null) return null;
  const value = Number(context);
  return Number.isFinite(value) ? value : null;
}

function currentSeasonDateRange(context) {
  if (!context || typeof context !== "object") return null;
  const startDate = normalizedSeasonDate(context.startDate);
  const endDateExclusive = normalizedSeasonDate(context.endDateExclusive);
  if (!startDate || !endDateExclusive || startDate >= endDateExclusive) return null;
  return { startDate, endDateExclusive };
}

function mongoIds(values) {
  const output = [];
  (Array.isArray(values) ? values : []).forEach((value) => {
    const stringValue = String(value);
    output.push(stringValue);
    const numericValue = Number(value);
    if (Number.isFinite(numericValue)) output.push(numericValue);
  });
  return [...new Set(output)];
}

function buildCurrentBsdEventsFilter(currentSeasonByLeague) {
  const allowlistedIds = mongoIds(BSD_LEAGUE_ALLOWLIST);
  const allowlist = new Set(BSD_LEAGUE_ALLOWLIST.map(String));
  const finishedSeasonClauses = [];
  currentSeasonByLeague.forEach((seasonContext, leagueId) => {
    const seasonId = currentSeasonId(seasonContext);
    const dateRange = currentSeasonDateRange(seasonContext);
    if ((seasonId == null && !dateRange) || !allowlist.has(String(leagueId))) {
      return;
    }
    const currentSeasonSelectors = [];
    if (seasonId != null) {
      currentSeasonSelectors.push(
        { season_id: { $in: mongoIds([seasonId]) } },
        { "payload.season_id": { $in: mongoIds([seasonId]) } }
      );
    }
    if (dateRange) {
      const range = {
        $gte: dateRange.startDate,
        $lt: dateRange.endDateExclusive,
      };
      currentSeasonSelectors.push(
        { event_date: range },
        { "payload.event_date": range }
      );
    }
    finishedSeasonClauses.push({
      $and: [
        {
          $or: [
            { league_id: { $in: mongoIds([leagueId]) } },
            { "payload.league_id": { $in: mongoIds([leagueId]) } },
          ],
        },
        { $or: currentSeasonSelectors },
      ],
    });
  });

  return {
    $and: [
      {
        $or: [
          { league_id: { $in: allowlistedIds } },
          { "payload.league_id": { $in: allowlistedIds } },
        ],
      },
      {
        $or: [
          { status: { $nin: ["finished", null] } },
          { status: null, "payload.status": { $ne: "finished" } },
          { season_id: null, "payload.season_id": null },
          ...finishedSeasonClauses,
        ],
      },
    ],
  };
}

// Event belongs to the current season (or is a live event without a season id).
// Season scoping only matters for "finished" events — it exists to keep stale
// results from past seasons out of the projection. Non-finished events (e.g.
// next season's already-published notstarted fixtures) are always relevant:
// bsd_leagues' current_season lags the actual fixture calendar around the
// turn of a season, which previously hid the entire next season's fixtures
// for weeks once the outgoing season's matches had all finished.
function isCurrentSeasonEvent(event, currentSeasonByLeague) {
  if (String(event.status || "").trim().toLowerCase() !== "finished") return true;
  if (event.season_id == null) return true; // live-poll events carry no season id
  const leagueId = event.league_id != null ? String(event.league_id) : null;
  const current = leagueId ? currentSeasonByLeague.get(leagueId) : null;
  if (current == null) return true; // no season info — don't exclude
  const seasonId = currentSeasonId(current);
  const dateRange = currentSeasonDateRange(current);
  if (seasonId == null && !dateRange) return true;
  if (seasonId != null && Number(event.season_id) === seasonId) return true;
  const eventDate = normalizedSeasonDate(event.event_date);
  return Boolean(
    dateRange &&
    eventDate &&
    eventDate >= dateRange.startDate &&
    eventDate < dateRange.endDateExclusive
  );
}

// Projects all current-season bsd_events into canonical list matches.
async function projectBsdMatches() {
  const leagues = await getBsdRecords("bsd_leagues");
  const currentSeasonByLeague = currentSeasonContextByLeagueFromDocs(leagues);
  const events = await getBsdRecords(
    "bsd_events",
    buildCurrentBsdEventsFilter(currentSeasonByLeague)
  );
  const eventIds = events.map((doc) => String(doc._id));
  const venueIds = [...new Set(events
    .map((doc) => doc && doc.payload && doc.payload.venue_id)
    .filter((id) => id != null)
    .map(String))];
  const [broadcasts, incidentsDocs, venueDocs] = eventIds.length > 0
    ? await Promise.all([
        getBsdRecords("bsd_broadcasts", { _id: { $in: eventIds } }),
        getBsdRecords("bsd_incidents", { _id: { $in: eventIds } }),
        venueIds.length > 0
          ? getBsdRecords("bsd_venues", { _id: { $in: venueIds } })
          : Promise.resolve([]),
      ])
    : [[], [], []];
  const leagueNameById = new Map();
  leagues.forEach((doc) => {
    const p = doc.payload || {};
    if (p.id != null && p.name) leagueNameById.set(String(p.id), String(p.name));
  });

  // event_id(string) → structured TvChannel[] for the broadcasts join.
  const channelsByEventId = new Map();
  broadcasts.forEach((doc) => {
    const eventId = doc && doc._id != null ? String(doc._id) : null;
    if (!eventId) return;
    const channels = bsdBroadcastChannels(doc.payload);
    if (channels.length > 0) channelsByEventId.set(eventId, channels);
  });

  const incidentsByEventId = new Map();
  incidentsDocs.forEach((doc) => {
    const eventId = doc && doc._id != null ? String(doc._id) : null;
    if (eventId) incidentsByEventId.set(eventId, doc.payload || null);
  });
  const venuesById = new Map(
    venueDocs.map((doc) => [String(doc._id), doc.payload || null])
  );

  // The live poller ingests every live league, not just the allowlist, so
  // restrict the projection to allowlisted leagues — otherwise live-only
  // events from unrelated competitions (with no fixtures/results context)
  // would surface in the toggle.
  const allowlist = new Set(BSD_LEAGUE_ALLOWLIST.map(String));

  const out = [];
  events.forEach((doc) => {
    const event = doc.payload;
    if (!event || !isCurrentSeasonEvent(event, currentSeasonByLeague)) return;
    if (event.league_id != null && !allowlist.has(String(event.league_id))) return;
    const eventId = event && event.id != null ? String(event.id) : null;
    const match = bsdEventToCanonicalMatch(event, {
      leagueNameById,
      channelsByEventId,
      incidentsPayload: eventId ? incidentsByEventId.get(eventId) : null,
      venuesById,
    });
    if (match) out.push(match);
  });
  return applyBsdTwoLegAggregates(
    events.map((doc) => doc && doc.payload).filter(Boolean),
    out
  );
}

// Projects a single bsd_event (with incidents + lineups) into a canonical
// match-details payload. Lineup identifiers remain BSD player identifiers, so
// clients can pass them directly to the BSD-backed player-details endpoint.
async function projectBsdMatchDetails(eventId, options = {}) {
  const id = String(eventId || "").trim();
  if (!id) return null;
  const eventDoc = options.eventDoc
    || await getBsdRecords("bsd_events", { _id: id }).then((r) => r[0] || null);
  if (!eventDoc || !eventDoc.payload) return null;
  const previousLegId = String(eventDoc.payload.previous_leg_event_id || "").trim();
  const venueId = eventDoc.payload.venue_id != null ? String(eventDoc.payload.venue_id) : null;
  const [incidentsDoc, lineupsDoc, broadcastsDoc, venueDoc, previousLegDoc, leagues] = await Promise.all([
    options.incidentsDoc || getBsdRecords("bsd_incidents", { _id: id }).then((r) => r[0] || null),
    options.lineupsDoc || getBsdRecords("bsd_lineups", { _id: id }).then((r) => r[0] || null),
    options.broadcastsDoc || getBsdRecords("bsd_broadcasts", { _id: id }).then((r) => r[0] || null),
    options.venueDoc || (venueId
      ? getBsdRecords("bsd_venues", { _id: venueId }).then((r) => r[0] || null)
      : Promise.resolve(null)),
    options.previousLegDoc || (previousLegId
      ? getBsdRecords("bsd_events", { _id: previousLegId }).then((r) => r[0] || null)
      : Promise.resolve(null)),
    getBsdRecords("bsd_leagues"),
  ]);
  const leagueNameById = new Map();
  leagues.forEach((doc) => {
    const p = doc.payload || {};
    if (p.id != null && p.name) leagueNameById.set(String(p.id), String(p.name));
  });
  const match = bsdEventToCanonicalMatch(eventDoc.payload, {
    detail: true,
    incidentsPayload: incidentsDoc ? incidentsDoc.payload : null,
    lineupsPayload: lineupsDoc ? lineupsDoc.payload : null,
    broadcastsPayload: broadcastsDoc ? broadcastsDoc.payload : null,
    leagueNameById,
    venuesById: venueId && venueDoc
      ? new Map([[venueId, venueDoc.payload || null]])
      : new Map(),
  });
  return applyBsdTwoLegAggregates(
    [previousLegDoc && previousLegDoc.payload, eventDoc.payload].filter(Boolean),
    [match]
  )[0];
}

module.exports = {
  bsdEventToCanonicalMatch,
  projectBsdMatches,
  projectBsdMatchDetails,
  projectBsdStandings,
  projectBsdPredictions,
  BSD_LEAGUE_NAME_MAP,
  __private: {
    mapBsdStatus,
    isDisallowedGoalVarDecision,
    parseBsdIncidents,
    buildBsdTeamLineups,
    bsdPlayerEntry,
    extractBsdSubstitutions,
    isPlaceholderTeam,
    bsdVenueDetails,
    bsdMinute,
    bsdPositionCategory,
    bsdBroadcastChannels,
    extractBsdPeriodSummary,
    buildPenaltyResultText,
    parseBsdFormString,
    bsdStandingsRowToCanonical,
    bsdStandingsZonesToCanonical,
    bsdStandingsPayloadToTable,
    completeBsdStandingsRowsFromEvents,
    buildBsdStandingsEventsFilter,
    bsdStandingsEventFromDoc,
    canonicalLeagueName,
    zonedKickoff,
    bsdVenueCoordinates,
    bsdKickoffLightContext,
    bsdVenueDetails,
    fallbackKickoffLightContext,
    bsdEventScoreIncludingExtraTime,
    applyBsdTwoLegAggregates,
    isCurrentSeasonEvent,
    buildCurrentBsdEventsFilter,
    currentSeasonByLeagueFromDocs,
    currentSeasonContextByLeagueFromDocs,
    bsdPredictionFixtureToCanonical,
    bsdPredictionsPayloadToLeague,
  },
};
