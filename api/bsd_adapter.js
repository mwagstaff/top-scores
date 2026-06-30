#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// BSD → canonical match adapter.
//
// Projects the already-ingested `bsd_*` Mongo collections into the SAME
// canonical match shape the TSDB pipeline emits (see fetch_tsdb_matches.js).
// Keeping the shape identical means the source toggle is a cache selection —
// serving, the clients (which key matches on the source-independent composite
// `date|time|league|home|away`), and the monitor are all unchanged.
//
// The correctness gate is that team and league names + zoned date/time
// normalise to the SAME values TSDB produces, so the composite id is stable
// across a source switch. Team names go through team_identity (alias-backed);
// league names go through BSD_LEAGUE_NAME_MAP; date/time through match_time.
// ---------------------------------------------------------------------------

const { canonicalTeamName } = require("./team_identity");
const { utcDateTimeToZonedDateTime } = require("./match_time");
const { __private: tsdbPrivate } = require("./fetch_tsdb_matches");
const { getBsdRecords } = require("./mongo_client");
const { BSD_LEAGUE_ALLOWLIST } = require("./bsd_config");

const assignFormationGridPositions = tsdbPrivate.assignFormationGridPositions;

// BSD league_id → canonical league name. Must match what the TSDB pipeline
// emits for the same competition (e.g. TSDB emits "FIFA World Cup 2026"),
// otherwise the composite match id diverges across sources.
const BSD_LEAGUE_NAME_MAP = {
  "27": "FIFA World Cup 2026",
  "1": "Premier League",
  "12": "Championship",
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
  "64": "UEFA Nations League",
  "31": "International Friendly",
  "58": "World Cup Qualifying UEFA",
  "59": "World Cup Qualifying CONMEBOL",
  "62": "World Cup Qualifying CONCACAF",
  "63": "World Cup Qualifying OFC",
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Undetermined knockout slots ("W101", "L33", "1A", "H2", "3D/3E/3I") are not
// real teams and must not surface as fixtures until the team is decided.
function isPlaceholderTeam(name) {
  const n = String(name || "").trim();
  if (!n) return true;
  if (n.includes("/")) return true; // "3D/3E/3I" composite slot
  if (/^[WL]\d+$/i.test(n)) return true; // W101 / L33 (winner/loser of match N)
  if (/^\d[A-Za-z]$/.test(n)) return true; // 1A, 2B (group position)
  if (/^[A-Za-z]\d+$/.test(n) && n.length <= 3) return true; // H2, G1
  return false;
}

// Format a minute as "67'" or "45+6'", mirroring fetch_tsdb_matches formatMinute.
function bsdMinute(minute, addedTime) {
  if (minute === null || minute === undefined || minute === "") return null;
  const base = String(minute).trim();
  if (!base || base === "0") return null;
  const added = Number(addedTime);
  if (Number.isFinite(added) && added > 0) return `${base}+${added}'`;
  return `${base}'`;
}

// BSD position code (G/D/M/F) → canonical category (matches TSDB
// positionCategoryFromShort output).
function bsdPositionCategory(position) {
  switch (String(position || "").trim().toUpperCase()) {
    case "G": return "goalkeeper";
    case "D": return "defender";
    case "M": return "midfielder";
    case "F": return "attacker";
    default: return null;
  }
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

// Maps BSD status/period/current_minute to the internal score_status vocabulary
// used throughout the codebase (mirrors fetch_tsdb_matches mapTsdbStatus output:
// null | "HT" | "FT" | "AET" | "Pens" | "POSTPONED" | "ET" | minute | "LIVE").
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

  if (!status || status === "notstarted" || status === "not_started" || status === "ns") {
    return null;
  }
  if (["postponed", "cancelled", "canceled", "abandoned", "suspended", "void"].includes(status)) {
    return "POSTPONED";
  }
  if (periodSummary && periodSummary.penaltyShootout) {
    return "AET";
  }
  if (status === "finished" || status === "ft" || status === "aet" || period === "ft") {
    if (event.penalty_shootout != null) return "AET";
    if (event.extra_time_score != null) return "AET";
    if (periodSummary && periodSummary.extraTimeScore) return "AET";
    return "FT";
  }
  if (status === "halftime" || status === "ht" || period === "ht" || period === "halftime") {
    return "HT";
  }
  // In progress.
  if (period.includes("penal") || status.includes("penal")) return "Pens";
  if (period.includes("extra")) return minuteStr || "ET";
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

  function addGoal(map, player, time, isOwn) {
    if (!player || !time) return;
    const existing = map.get(player) || { player, goal_times: [], own_goal_times: [] };
    const bucket = isOwn ? existing.own_goal_times : existing.goal_times;
    if (!bucket.includes(time)) bucket.push(time);
    map.set(player, existing);
  }
  function addAssist(map, player, time) {
    if (!player || !time) return;
    const existing = map.get(player) || { player, assist_times: [] };
    if (!existing.assist_times.includes(time)) existing.assist_times.push(time);
    map.set(player, existing);
  }
  function addCard(map, player, time, field) {
    if (!player || !time) return;
    const existing = map.get(player) || { player, [field]: [] };
    if (!existing[field].includes(time)) existing[field].push(time);
    map.set(player, existing);
  }

  incidents.forEach((inc) => {
    if (!inc || typeof inc !== "object") return;
    const home = inc.is_home === true;
    const minute = bsdMinute(inc.minute, inc.added_time);
    const player = String(inc.player || "").trim() || null;

    if (inc.type === "goal") {
      const own = String(inc.goal_type || "").toLowerCase().includes("own");
      const assist = String(inc.assist || "").trim() || null;
      if (own) {
        // Own goal benefits the opposing side (matches TSDB/BBC convention).
        addGoal(home ? awayGoals : homeGoals, player, minute, true);
      } else {
        addGoal(home ? homeGoals : awayGoals, player, minute, false);
        if (assist) addAssist(home ? homeAssists : awayAssists, assist, minute);
      }
    } else if (inc.type === "card") {
      const cardType = String(inc.card_type || "").toLowerCase();
      if (cardType.includes("red")) {
        addCard(home ? homeRed : awayRed, player, minute, "red_card_times");
      } else if (cardType.includes("yellow")) {
        addCard(home ? homeYellow : awayYellow, player, minute, "yellow_card_times");
      }
    } else if (inc.type === "varDecision") {
      if (isDisallowedGoalVarDecision(inc.decision, inc.confirmed)) {
        (home ? result.home_var_events : result.away_var_events).push({
          player,
          minute,
          detail: "VAR: Goal disallowed",
        });
      }
    }
  });

  const materialiseGoals = (map) =>
    Array.from(map.values()).map((e) => {
      const out = { player: e.player };
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
  return {
    number: Number.isFinite(number) ? number : null,
    name,
    id_player: player.id != null ? String(player.id) : null,
    position_category: bsdPositionCategory(position),
    position,
    position_short: position,
    cutout_url: null,
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
    if (!playerOn) return;
    const home_ = inc.is_home === true;
    const lookup = home_ ? homeLookup : awayLookup;
    const subEvent = {
      minute,
      player_off: playerOff ? { number: lookup.get(playerOff.toLowerCase()) ?? null, name: playerOff } : null,
      player_on: { number: lookup.get(playerOn.toLowerCase()) ?? null, name: playerOn },
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

function buildBsdTeamLineups(lineupsPayload, incidents) {
  const lineups = lineupsPayload && lineupsPayload.lineups;
  if (!lineups || typeof lineups !== "object") return null;

  const out = {};
  ["home", "away"].forEach((side) => {
    const team = lineups[side];
    if (!team) return;
    const starters = (Array.isArray(team.players) ? team.players : [])
      .map(bsdPlayerEntry)
      .filter(Boolean);
    const substitutes = (Array.isArray(team.substitutes) ? team.substitutes : [])
      .map(bsdPlayerEntry)
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

// Splits a BSD ISO event_date into UTC date + time, then zones it through the
// shared match_time helper so it matches the TSDB pipeline's date/time exactly.
function zonedKickoff(eventDate) {
  const ms = Date.parse(String(eventDate || ""));
  if (!Number.isFinite(ms)) return { date: null, time: null };
  const iso = new Date(ms).toISOString();
  return utcDateTimeToZonedDateTime(iso.slice(0, 10), iso.slice(11, 16));
}

function toNumber(value) {
  return value !== null && value !== undefined && value !== "" ? Number(value) : null;
}

// BSD broadcasts are fetched filtered to GB, so every channel is a UK listing.
// Project a bsd_broadcasts payload's channels into the structured TvChannel
// shape the clients expect ({ name, country, countryCode, logo }), matching
// what the TSDB pipeline emitted. countryCode "GB" lets the clients' locale
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

// Projects one bsd_standings payload (the raw /leagues/:id/standings response)
// into the canonical league-table shape shared with the TSDB pipeline.
// `leagueId`/`updatedAt` come from the Mongo doc wrapper; `leagueNameById`
// resolves a human league name when BSD_LEAGUE_NAME_MAP has no entry.
function bsdStandingsPayloadToTable(payload, { leagueId, updatedAt, leagueNameById } = {}) {
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
    groups,
    rows,
  };
}

// Projects every allowlisted bsd_standings doc into the canonical table list.
async function projectBsdStandings() {
  const [standingsDocs, leagues] = await Promise.all([
    getBsdRecords("bsd_standings"),
    getBsdRecords("bsd_leagues"),
  ]);
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
    home_score: normalTimeScore ? normalTimeScore.home : toNumber(event.home_score),
    away_score: normalTimeScore ? normalTimeScore.away : toNumber(event.away_score),
    aggregate_home_score: null,
    aggregate_away_score: null,
    score_status: scoreStatus,
    match_time: scoreStatus,
    date: kickoff.date,
    time: kickoff.time,
    league,
    league_subcategory: leagueSubcategory,
    details_url: null,
    has_bsd_source: true,
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
    Object.assign(match, parseBsdIncidents(incidents));
    const teamLineups = buildBsdTeamLineups(options.lineupsPayload, incidents);
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
  return Number(event.season_id) === current;
}

// Projects all current-season bsd_events into canonical list matches.
async function projectBsdMatches() {
  const [events, currentSeasonByLeague, broadcasts, incidentsDocs] = await Promise.all([
    getBsdRecords("bsd_events"),
    loadCurrentSeasonByLeague(),
    getBsdRecords("bsd_broadcasts"),
    getBsdRecords("bsd_incidents"),
  ]);
  const leagueNameById = new Map();
  (await getBsdRecords("bsd_leagues")).forEach((doc) => {
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
    });
    if (match) out.push(match);
  });
  return out;
}

// Projects a single bsd_event (with incidents + lineups) into a canonical
// match-details payload. `recordsById` lets callers pass pre-loaded docs.
// Strict enrichment from the persistent bsd_tsdb_player_map (keyed by BSD
// player id = the player's id_player): fills cutout_url, AND swaps id_player
// to the TSDB player id so the client's existing GET /api/v1/players/:id ->
// TSDB cache/live-fetch path (bio, position, birth info) works unmodified for
// BSD lineup players. Players without a confident map entry keep their BSD
// id_player and cutout_url = null — the client shows an initials placeholder
// and "Player details unavailable" rather than risk the wrong player's data.
async function enrichBsdLineupPhotos(match) {
  const lineups = match && match.team_lineups;
  if (!lineups || typeof lineups !== "object") return match;

  const ids = new Set();
  ["home", "away"].forEach((side) => {
    const team = lineups[side];
    if (!team) return;
    [...(team.starting_lineup || []), ...(team.substitutes || [])].forEach((p) => {
      const id = p && p.id_player != null ? String(p.id_player) : null;
      if (id) ids.add(id);
    });
  });
  if (ids.size === 0) return match;

  const mapDocs = await getBsdRecords("bsd_tsdb_player_map", { _id: { $in: [...ids] } });
  const photoById = new Map();
  mapDocs.forEach((doc) => {
    const payload = doc && doc.payload;
    const tsdbId = payload && payload.tsdb_player_id ? String(payload.tsdb_player_id) : null;
    if (tsdbId) {
      photoById.set(String(doc._id), { cutout_url: payload.cutout_url || null, tsdb_player_id: tsdbId });
    }
  });
  if (photoById.size === 0) return match;

  const applyPhotos = (players) =>
    (Array.isArray(players) ? players : []).map((p) => {
      const mapped = p && p.id_player != null ? photoById.get(String(p.id_player)) : null;
      if (!mapped) return p;
      return {
        ...p,
        id_player: mapped.tsdb_player_id,
        cutout_url: mapped.cutout_url || p.cutout_url,
      };
    });

  ["home", "away"].forEach((side) => {
    const team = lineups[side];
    if (!team) return;
    team.starting_lineup = applyPhotos(team.starting_lineup);
    team.substitutes = applyPhotos(team.substitutes);
  });
  return match;
}

async function projectBsdMatchDetails(eventId, options = {}) {
  const id = String(eventId || "").trim();
  if (!id) return null;
  const [eventDoc, incidentsDoc, lineupsDoc, broadcastsDoc, leagues] = await Promise.all([
    options.eventDoc || getBsdRecords("bsd_events", { _id: id }).then((r) => r[0] || null),
    options.incidentsDoc || getBsdRecords("bsd_incidents", { _id: id }).then((r) => r[0] || null),
    options.lineupsDoc || getBsdRecords("bsd_lineups", { _id: id }).then((r) => r[0] || null),
    options.broadcastsDoc || getBsdRecords("bsd_broadcasts", { _id: id }).then((r) => r[0] || null),
    getBsdRecords("bsd_leagues"),
  ]);
  if (!eventDoc || !eventDoc.payload) return null;
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
  });
  return enrichBsdLineupPhotos(match);
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
    extractBsdSubstitutions,
    isPlaceholderTeam,
    bsdMinute,
    bsdPositionCategory,
    bsdBroadcastChannels,
    extractBsdPeriodSummary,
    buildPenaltyResultText,
    parseBsdFormString,
    bsdStandingsRowToCanonical,
    bsdStandingsPayloadToTable,
    canonicalLeagueName,
    zonedKickoff,
    isCurrentSeasonEvent,
    enrichBsdLineupPhotos,
    bsdPredictionFixtureToCanonical,
    bsdPredictionsPayloadToLeague,
  },
};
