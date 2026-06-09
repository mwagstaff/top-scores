#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

const https = require("https");
const { URL } = require("url");

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const TSDB_BASE_URL = "https://www.thesportsdb.com/api/v2/json";
const TSDB_REQUEST_TIMEOUT_MS = 30_000;

// Hard cap from TheSportsDB docs: 100 req/min on premium tier.
// We target 90 to keep a comfortable headroom against clock skew.
const RATE_LIMIT_MAX_TOKENS = 90;
const RATE_LIMIT_REFILL_INTERVAL_MS = 60_000;

// When the upstream returns HTTP 200 but the body is `{"events":null}` or an
// equivalent null-result during a live data update, we retry after a short
// delay. Forum-documented behaviour — see THESPORTSDB_MIGRATION_PLAN.md.
const NULL_RESULT_RETRY_DELAY_MS = 2_000;
const NULL_RESULT_MAX_RETRIES = 2;

// ---------------------------------------------------------------------------
// Token-bucket rate limiter
// ---------------------------------------------------------------------------
//
// Single shared bucket for all calls made through this module so every
// code path (live scores, match details, schedules, etc.) counts toward
// the same cap.

let _tokens = RATE_LIMIT_MAX_TOKENS;
let _lastRefillMs = Date.now();

// Waiters queued when the bucket is empty: { resolve, cost }
const _waitQueue = [];

function _refillTokens() {
  const now = Date.now();
  const elapsed = now - _lastRefillMs;
  if (elapsed >= RATE_LIMIT_REFILL_INTERVAL_MS) {
    _tokens = RATE_LIMIT_MAX_TOKENS;
    _lastRefillMs = now;
    _drainQueue();
  }
}

function _drainQueue() {
  while (_waitQueue.length > 0 && _tokens >= _waitQueue[0].cost) {
    const waiter = _waitQueue.shift();
    _tokens -= waiter.cost;
    waiter.resolve();
  }
}

// Returns a Promise that resolves once `cost` tokens are available.
// Cost is always 1 for a single API call.
function _acquireToken(cost = 1) {
  _refillTokens();
  if (_tokens >= cost) {
    _tokens -= cost;
    return Promise.resolve();
  }
  // Queue the waiter; a scheduled refill will drain it.
  return new Promise((resolve) => {
    _waitQueue.push({ resolve, cost });
    // Schedule a wakeup at the next refill boundary if one isn't already
    // pending. We only need one timeout regardless of queue depth.
    if (_waitQueue.length === 1) {
      const msUntilRefill = RATE_LIMIT_REFILL_INTERVAL_MS - (Date.now() - _lastRefillMs);
      setTimeout(() => {
        _tokens = RATE_LIMIT_MAX_TOKENS;
        _lastRefillMs = Date.now();
        _drainQueue();
      }, Math.max(0, msUntilRefill));
    }
  });
}

// Exposed for tests / diagnostics.
function getRateLimitState() {
  _refillTokens();
  return {
    tokens: _tokens,
    maxTokens: RATE_LIMIT_MAX_TOKENS,
    queueDepth: _waitQueue.length,
    msUntilRefill: Math.max(0, RATE_LIMIT_REFILL_INTERVAL_MS - (Date.now() - _lastRefillMs)),
  };
}

// ---------------------------------------------------------------------------
// Request observer (mirrors BBC observer contract)
// ---------------------------------------------------------------------------
//
// Observer receives: { source, initiator, reason, trigger, url,
//                      statusCode, durationMs, timestampMs }
// server.js wires this to the same trackBbcHttpRequestMetric handler used
// for BBC metrics (with a renamed source label), so existing Prometheus
// counters and request-history persist without change.

let _requestObserver = null;

function setRequestObserver(observer) {
  _requestObserver = typeof observer === "function" ? observer : null;
}

function _notifyObserver(event) {
  if (typeof _requestObserver !== "function") return;
  try {
    _requestObserver(event);
  } catch (_err) {
    // Never let an observer failure break the fetch.
  }
}

// ---------------------------------------------------------------------------
// Core HTTP fetch
// ---------------------------------------------------------------------------

function _fetchJson(url, options = {}) {
  return new Promise((resolve, reject) => {
    const apiKey = String(process.env.THE_SPORTS_DB_API_KEY || "").trim();
    if (!apiKey) {
      const err = new Error("THE_SPORTS_DB_API_KEY environment variable is not set");
      err.code = "TSDB_NO_API_KEY";
      return reject(err);
    }

    const source = String(options.source || "tsdb_unknown").trim() || "tsdb_unknown";
    const initiator = String(options.initiator || "").trim() || null;
    const reason = String(options.reason || "").trim() || null;
    const trigger = String(options.trigger || "").trim() || null;
    const requestedUrl = String(url || "").trim();
    const startedAtMs = Date.now();
    let settled = false;

    const complete = ({ statusCode, error, data }) => {
      if (settled) return;
      settled = true;
      _notifyObserver({
        source,
        initiator,
        reason,
        trigger,
        url: requestedUrl,
        statusCode,
        durationMs: Date.now() - startedAtMs,
        timestampMs: Date.now(),
      });
      if (error) {
        reject(error);
        return;
      }
      resolve(data);
    };

    const target = new URL(requestedUrl);
    const req = https.get(
      target,
      {
        headers: {
          "X-API-KEY": apiKey,
          "Accept": "application/json",
        },
      },
      (res) => {
        const statusCode = Number(res.statusCode || 0);

        if (statusCode >= 300 && statusCode < 400 && res.headers.location) {
          res.resume();
          _fetchJson(
            new URL(res.headers.location, target).toString(),
            options
          ).then(resolve).catch(reject);
          return;
        }

        if (statusCode !== 200) {
          res.resume();
          const error = new Error(`TheSportsDB request failed with status ${statusCode}`);
          error.statusCode = statusCode;
          error.code = `HTTP_${statusCode}`;
          error.url = requestedUrl;
          complete({ statusCode, error });
          return;
        }

        let raw = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => { raw += chunk; });
        res.on("end", () => {
          let parsed;
          try {
            parsed = JSON.parse(raw);
          } catch (parseErr) {
            parseErr.code = "TSDB_JSON_PARSE_ERROR";
            parseErr.url = requestedUrl;
            complete({ statusCode, error: parseErr });
            return;
          }
          complete({ statusCode, data: parsed });
        });
      }
    );

    req.setTimeout(TSDB_REQUEST_TIMEOUT_MS, () => {
      const error = new Error("TheSportsDB request timed out");
      error.code = "ETIMEDOUT";
      error.url = requestedUrl;
      req.destroy(error);
    });

    req.on("error", (error) => {
      if (!error.url) error.url = requestedUrl;
      complete({
        statusCode:
          Number.isFinite(Number(error.statusCode)) && Number(error.statusCode) >= 0
            ? Number(error.statusCode)
            : 0,
        error,
      });
    });
  });
}

// ---------------------------------------------------------------------------
// Null-result detection
// ---------------------------------------------------------------------------
//
// SportsDB returns HTTP 200 with a null-valued key during live data updates.
// e.g. { "events": null } or { "livescore": null } or { "lookup": null }
// Retry a couple of times with a short delay before surfacing the null.

function _isNullResult(data) {
  if (!data || typeof data !== "object") return false;
  const values = Object.values(data);
  // A single-key response where the value is null is the null-result pattern.
  return values.length > 0 && values.every((v) => v === null);
}

async function _fetchWithNullRetry(url, options = {}) {
  let lastData = null;
  for (let attempt = 0; attempt <= NULL_RESULT_MAX_RETRIES; attempt += 1) {
    if (attempt > 0) {
      // eslint-disable-next-line no-await-in-loop
      await new Promise((res) => setTimeout(res, NULL_RESULT_RETRY_DELAY_MS));
    }
    // eslint-disable-next-line no-await-in-loop
    lastData = await _fetchJson(url, options);
    if (!_isNullResult(lastData)) return lastData;
  }
  // Return the null result after exhausting retries — caller decides what to do.
  return lastData;
}

// ---------------------------------------------------------------------------
// Rate-limited public fetch
// ---------------------------------------------------------------------------

async function _request(path, options = {}) {
  await _acquireToken();
  const url = `${TSDB_BASE_URL}${path}`;
  return _fetchWithNullRetry(url, options);
}

// ---------------------------------------------------------------------------
// Public API methods
// ---------------------------------------------------------------------------

// --- Livescores ---

// All live soccer matches in a single call.
// Returns: { livescore: [ { idEvent, strHomeTeam, strAwayTeam, intHomeScore,
//             intAwayScore, strStatus, strProgress, strTimestamp, ... } ] }
function getLivescores(options = {}) {
  return _request("/livescore/soccer", {
    source: "tsdb_livescores",
    reason: "livescore_poll",
    ...options,
  });
}

// --- Event/match detail ---

// Core event fields: teams, scores, date, status, league.
function getEvent(idEvent, options = {}) {
  return _request(`/lookup/event/${encodeURIComponent(idEvent)}`, {
    source: "tsdb_event",
    reason: "event_lookup",
    ...options,
  });
}

// Timeline: goals (normal/penalty/missed), cards, substitutions.
function getEventTimeline(idEvent, options = {}) {
  return _request(`/lookup/event_timeline/${encodeURIComponent(idEvent)}`, {
    source: "tsdb_event_timeline",
    reason: "event_timeline_lookup",
    ...options,
  });
}

// Lineup: both-team squads with position, formation, sub flag, squad number.
function getEventLineup(idEvent, options = {}) {
  return _request(`/lookup/event_lineup/${encodeURIComponent(idEvent)}`, {
    source: "tsdb_event_lineup",
    reason: "event_lineup_lookup",
    ...options,
  });
}

// Stats (not yet used in the migration, available for future phases).
function getEventStats(idEvent, options = {}) {
  return _request(`/lookup/event_stats/${encodeURIComponent(idEvent)}`, {
    source: "tsdb_event_stats",
    reason: "event_stats_lookup",
    ...options,
  });
}

// --- Schedule ---

// Full-season fixture list for a league.
// season format: "2025-2026"
function getLeagueSchedule(idLeague, season, options = {}) {
  return _request(
    `/schedule/league/${encodeURIComponent(idLeague)}/${encodeURIComponent(season)}`,
    {
      source: "tsdb_schedule",
      reason: "league_schedule_fetch",
      ...options,
    }
  );
}

// Next 15 events for a league (useful for near-term fixture refresh).
function getLeagueNextEvents(idLeague, options = {}) {
  return _request(`/schedule/next/league/${encodeURIComponent(idLeague)}`, {
    source: "tsdb_schedule_next",
    reason: "league_next_events",
    ...options,
  });
}

// Previous 15 events for a league (useful for recent-results refresh).
function getLeaguePreviousEvents(idLeague, options = {}) {
  return _request(`/schedule/previous/league/${encodeURIComponent(idLeague)}`, {
    source: "tsdb_schedule_prev",
    reason: "league_prev_events",
    ...options,
  });
}

// --- Teams ---

// All teams in a league (replaces fetchPremierLeagueTeams for any league).
function getLeagueTeams(idLeague, options = {}) {
  return _request(`/list/teams/${encodeURIComponent(idLeague)}`, {
    source: "tsdb_league_teams",
    reason: "league_teams_fetch",
    ...options,
  });
}

// Single team lookup (used to populate strTeamShort etc).
function getTeam(idTeam, options = {}) {
  return _request(`/lookup/team/${encodeURIComponent(idTeam)}`, {
    source: "tsdb_team",
    reason: "team_lookup",
    ...options,
  });
}

// --- Standings ---
// Path/season format still unconfirmed on the test key; exposed here but not
// wired to the rest of the app yet. Revisit in the standings phase.
function getStandings(idLeague, season, options = {}) {
  return _request(
    `/lookup/table/${encodeURIComponent(idLeague)}/${encodeURIComponent(season)}`,
    {
      source: "tsdb_standings",
      reason: "standings_fetch",
      ...options,
    }
  );
}

// --- TV listings ---

// All soccer TV listings. Returns entries grouped under `filter`, each with:
//   idEvent, strChannel, strCountry, strLogo, dateEvent, strTime
// One entry per (event × channel × country). Refreshed every ~2 hours.
function getTvListings(options = {}) {
  return _request("/filter/tv/sport/soccer", {
    source: "tsdb_tv_listings",
    reason: "tv_listings_fetch",
    ...options,
  });
}

// --- League search / all leagues (for building the allowlist) ---

function searchLeague(name, options = {}) {
  return _request(`/search/league/${encodeURIComponent(name)}`, {
    source: "tsdb_search",
    reason: "league_search",
    ...options,
  });
}

function getAllLeagues(options = {}) {
  return _request("/all/leagues", {
    source: "tsdb_all_leagues",
    reason: "all_leagues_fetch",
    ...options,
  });
}

// ---------------------------------------------------------------------------
// v1 API — league tables
// ---------------------------------------------------------------------------
//
// The lookuptable endpoint is only available on the legacy v1 API where the
// key "123" is baked into the URL path. No X-API-KEY header is needed.

const TSDB_V1_BASE_URL = "https://www.thesportsdb.com/api/v1/json/123";

function _fetchJsonV1(url, options = {}) {
  return new Promise((resolve, reject) => {
    const source = String(options.source || "tsdb_v1_unknown").trim() || "tsdb_v1_unknown";
    const initiator = String(options.initiator || "").trim() || null;
    const reason = String(options.reason || "").trim() || null;
    const trigger = String(options.trigger || "").trim() || null;
    const requestedUrl = String(url || "").trim();
    const startedAtMs = Date.now();
    let settled = false;

    const complete = ({ statusCode, error, data }) => {
      if (settled) return;
      settled = true;
      _notifyObserver({
        source,
        initiator,
        reason,
        trigger,
        url: requestedUrl,
        statusCode,
        durationMs: Date.now() - startedAtMs,
        timestampMs: Date.now(),
      });
      if (error) {
        reject(error);
        return;
      }
      resolve(data);
    };

    const target = new URL(requestedUrl);
    const req = https.get(
      target,
      { headers: { "Accept": "application/json" } },
      (res) => {
        const statusCode = Number(res.statusCode || 0);

        if (statusCode >= 300 && statusCode < 400 && res.headers.location) {
          res.resume();
          _fetchJsonV1(
            new URL(res.headers.location, target).toString(),
            options
          ).then(resolve).catch(reject);
          return;
        }

        if (statusCode !== 200) {
          res.resume();
          const error = new Error(`TheSportsDB v1 request failed with status ${statusCode}`);
          error.statusCode = statusCode;
          error.code = `HTTP_${statusCode}`;
          error.url = requestedUrl;
          complete({ statusCode, error });
          return;
        }

        let raw = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => { raw += chunk; });
        res.on("end", () => {
          let parsed;
          try {
            parsed = JSON.parse(raw);
          } catch (parseErr) {
            parseErr.code = "TSDB_JSON_PARSE_ERROR";
            parseErr.url = requestedUrl;
            complete({ statusCode, error: parseErr });
            return;
          }
          complete({ statusCode, data: parsed });
        });
      }
    );

    req.setTimeout(TSDB_REQUEST_TIMEOUT_MS, () => {
      const error = new Error("TheSportsDB v1 request timed out");
      error.code = "ETIMEDOUT";
      error.url = requestedUrl;
      req.destroy(error);
    });

    req.on("error", (error) => {
      if (!error.url) error.url = requestedUrl;
      complete({
        statusCode:
          Number.isFinite(Number(error.statusCode)) && Number(error.statusCode) >= 0
            ? Number(error.statusCode)
            : 0,
        error,
      });
    });
  });
}

async function _requestV1(path, options = {}) {
  await _acquireToken();
  const url = `${TSDB_V1_BASE_URL}${path}`;
  return _fetchJsonV1(url, options);
}

function getLeagueTable(idLeague, options = {}) {
  return _requestV1(`/lookuptable.php?l=${encodeURIComponent(String(idLeague || ""))}`, {
    source: "tsdb_league_table",
    ...options,
  });
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

module.exports = {
  // Auth / config
  setRequestObserver,
  getRateLimitState,

  // Livescores
  getLivescores,

  // Event detail
  getEvent,
  getEventTimeline,
  getEventLineup,
  getEventStats,

  // Schedule
  getLeagueSchedule,
  getLeagueNextEvents,
  getLeaguePreviousEvents,

  // Teams
  getLeagueTeams,
  getTeam,

  // Standings (parked — path TBC)
  getStandings,

  // League tables (v1)
  getLeagueTable,

  // TV listings
  getTvListings,

  // Utilities
  searchLeague,
  getAllLeagues,

  // Exposed for tests
  __private: {
    _acquireToken,
    _isNullResult,
    _fetchWithNullRetry,
    getRateLimitState,
    RATE_LIMIT_MAX_TOKENS,
    RATE_LIMIT_REFILL_INTERVAL_MS,
    NULL_RESULT_RETRY_DELAY_MS,
    NULL_RESULT_MAX_RETRIES,
  },
};
