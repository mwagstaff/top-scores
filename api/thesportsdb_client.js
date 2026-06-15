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
const TSDB_RETRY_MAX_ATTEMPTS = Number(process.env.TSDB_RETRY_MAX_ATTEMPTS || 3);
const TSDB_RETRY_BASE_DELAY_MS = Number(process.env.TSDB_RETRY_BASE_DELAY_MS || 400);
const TSDB_RETRY_MAX_DELAY_MS = Number(process.env.TSDB_RETRY_MAX_DELAY_MS || 5_000);
const TSDB_RETRY_JITTER_MS = Number(process.env.TSDB_RETRY_JITTER_MS || 250);
const TSDB_V1_RETRY_MAX_ATTEMPTS = Number(process.env.TSDB_V1_RETRY_MAX_ATTEMPTS || 4);
const TSDB_V1_RETRY_BASE_DELAY_MS = Number(process.env.TSDB_V1_RETRY_BASE_DELAY_MS || 2_000);
const TSDB_V1_RETRY_MAX_DELAY_MS = Number(process.env.TSDB_V1_RETRY_MAX_DELAY_MS || 60_000);

// Hard cap from TheSportsDB docs: 100 req/min on premium tier.
// We target 90 to keep a comfortable headroom against clock skew.
const RATE_LIMIT_MAX_TOKENS = 90;
const RATE_LIMIT_V1_MAX_TOKENS = 30;
const RATE_LIMIT_REFILL_INTERVAL_MS = 60_000;

// When the upstream returns HTTP 200 but the body is `{"events":null}` or an
// equivalent null-result during a live data update, we retry after a short
// delay. Forum-documented behaviour — see THESPORTSDB_MIGRATION_PLAN.md.
const NULL_RESULT_RETRY_DELAY_MS = 2_000;
const NULL_RESULT_MAX_RETRIES = 2;

function _sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, Number(ms) || 0)));
}

function _randomDelay(maxMs) {
  const normalized = Math.max(0, Number(maxMs) || 0);
  if (normalized <= 0) return 0;
  return Math.floor(Math.random() * normalized);
}

function _retryDelayMs(attempt, options = {}) {
  const base = Math.max(0, Number(options.baseDelayMs ?? TSDB_RETRY_BASE_DELAY_MS) || 0);
  const cap = Math.max(base, Number(options.maxDelayMs ?? TSDB_RETRY_MAX_DELAY_MS) || base);
  const exponential = Math.min(cap, base * Math.max(1, 2 ** Math.max(0, attempt - 1)));
  const retryAfterMs = Math.max(0, Number(options.retryAfterMs) || 0);
  return Math.max(exponential, retryAfterMs) + _randomDelay(TSDB_RETRY_JITTER_MS);
}

function _isRetryableError(error) {
  if (!error) return false;
  const statusCode = Number(error.statusCode || 0);
  if (statusCode === 408 || statusCode === 429) return true;
  if (statusCode >= 500 && statusCode <= 599) return true;
  const code = String(error.code || "").trim().toUpperCase();
  if (code === "TSDB_JSON_PARSE_ERROR") return true;
  return [
    "ECONNRESET",
    "ECONNREFUSED",
    "EAI_AGAIN",
    "ETIMEDOUT",
    "ENOTFOUND",
    "EPIPE",
  ].includes(code);
}

function _retryAfterMs(headers = {}) {
  const raw = headers["retry-after"];
  if (raw == null) return 0;

  const seconds = Number(raw);
  if (Number.isFinite(seconds)) {
    return Math.max(0, Math.floor(seconds * 1000));
  }

  const retryAtMs = Date.parse(String(raw));
  if (Number.isFinite(retryAtMs)) {
    return Math.max(0, retryAtMs - Date.now());
  }

  return 0;
}

// ---------------------------------------------------------------------------
// Token-bucket rate limiter
// ---------------------------------------------------------------------------
//
// v2 and v1 have different upstream caps, so each API generation gets its own
// bucket while sharing the same refill cadence.

function _createRateLimiter(maxTokens) {
  return {
    tokens: maxTokens,
    maxTokens,
    lastRefillMs: Date.now(),
    waitQueue: [],
  };
}

const _v2RateLimiter = _createRateLimiter(RATE_LIMIT_MAX_TOKENS);
const _v1RateLimiter = _createRateLimiter(RATE_LIMIT_V1_MAX_TOKENS);

function _refillTokens(limiter) {
  const now = Date.now();
  const elapsed = now - limiter.lastRefillMs;
  if (elapsed >= RATE_LIMIT_REFILL_INTERVAL_MS) {
    limiter.tokens = limiter.maxTokens;
    limiter.lastRefillMs = now;
    _drainQueue(limiter);
  }
}

function _drainQueue(limiter) {
  while (limiter.waitQueue.length > 0 && limiter.tokens >= limiter.waitQueue[0].cost) {
    const waiter = limiter.waitQueue.shift();
    limiter.tokens -= waiter.cost;
    waiter.resolve();
  }
}

// Returns a Promise that resolves once `cost` tokens are available.
// Cost is always 1 for a single API call.
function _acquireToken(cost = 1, limiter = _v2RateLimiter) {
  _refillTokens(limiter);
  if (limiter.tokens >= cost) {
    limiter.tokens -= cost;
    return Promise.resolve();
  }
  // Queue the waiter; a scheduled refill will drain it.
  return new Promise((resolve) => {
    limiter.waitQueue.push({ resolve, cost });
    // Schedule a wakeup at the next refill boundary if one isn't already
    // pending. We only need one timeout regardless of queue depth.
    if (limiter.waitQueue.length === 1) {
      const msUntilRefill = RATE_LIMIT_REFILL_INTERVAL_MS - (Date.now() - limiter.lastRefillMs);
      setTimeout(() => {
        limiter.tokens = limiter.maxTokens;
        limiter.lastRefillMs = Date.now();
        _drainQueue(limiter);
      }, Math.max(0, msUntilRefill));
    }
  });
}

// Exposed for tests / diagnostics.
function _rateLimitState(limiter) {
  _refillTokens(limiter);
  return {
    tokens: limiter.tokens,
    maxTokens: limiter.maxTokens,
    queueDepth: limiter.waitQueue.length,
    msUntilRefill: Math.max(0, RATE_LIMIT_REFILL_INTERVAL_MS - (Date.now() - limiter.lastRefillMs)),
  };
}

function getRateLimitState() {
  return _rateLimitState(_v2RateLimiter);
}

function getV1RateLimitState() {
  return _rateLimitState(_v1RateLimiter);
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
      await _sleep(NULL_RESULT_RETRY_DELAY_MS + _randomDelay(TSDB_RETRY_JITTER_MS));
    }
    // eslint-disable-next-line no-await-in-loop
    lastData = await _fetchJson(url, options);
    if (!_isNullResult(lastData)) return lastData;
  }
  // Return the null result after exhausting retries — caller decides what to do.
  return lastData;
}

async function _fetchWithRetry(fetcher, url, options = {}) {
  const maxAttempts = Math.max(1, Number(options.maxAttempts ?? TSDB_RETRY_MAX_ATTEMPTS) || 1);
  let lastError = null;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      // eslint-disable-next-line no-await-in-loop
      return await fetcher(url, options);
    } catch (error) {
      lastError = error;
      if (attempt >= maxAttempts || !_isRetryableError(error)) {
        throw error;
      }
      // eslint-disable-next-line no-await-in-loop
      await _sleep(_retryDelayMs(attempt, {
        baseDelayMs: options.baseDelayMs,
        maxDelayMs: options.maxDelayMs,
        retryAfterMs: error && error.retryAfterMs,
      }));
    }
  }
  throw lastError;
}

// ---------------------------------------------------------------------------
// Rate-limited public fetch
// ---------------------------------------------------------------------------

async function _request(path, options = {}) {
  const url = `${TSDB_BASE_URL}${path}`;
  return _fetchWithRetry(async (targetUrl, requestOptions) => {
    await _acquireToken();
    return _fetchWithNullRetry(targetUrl, requestOptions);
  }, url, options);
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

function getPlayer(idPlayer, options = {}) {
  return _request(`/lookup/player/${encodeURIComponent(idPlayer)}`, {
    source: "tsdb_player",
    reason: "player_lookup",
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
          if (statusCode === 429) {
            error.retryAfterMs = _retryAfterMs(res.headers) || RATE_LIMIT_REFILL_INTERVAL_MS;
          }
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
  const url = `${TSDB_V1_BASE_URL}${path}`;
  return _fetchWithRetry(async (targetUrl, requestOptions) => {
    await _acquireToken(1, _v1RateLimiter);
    return _fetchJsonV1(targetUrl, requestOptions);
  }, url, {
    ...options,
    maxAttempts: TSDB_V1_RETRY_MAX_ATTEMPTS,
    baseDelayMs: TSDB_V1_RETRY_BASE_DELAY_MS,
    maxDelayMs: TSDB_V1_RETRY_MAX_DELAY_MS,
  });
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
  getV1RateLimitState,

  // Livescores
  getLivescores,

  // Event detail
  getEvent,
  getEventTimeline,
  getEventLineup,
  getEventStats,
  getPlayer,

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
    _isRetryableError,
    _retryAfterMs,
    getV1RateLimitState,
    getRateLimitState,
    RATE_LIMIT_MAX_TOKENS,
    RATE_LIMIT_V1_MAX_TOKENS,
    RATE_LIMIT_REFILL_INTERVAL_MS,
    NULL_RESULT_RETRY_DELAY_MS,
    NULL_RESULT_MAX_RETRIES,
  },
};
