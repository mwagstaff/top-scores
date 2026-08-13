#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// BSD API client (https://sports.bzzoiro.com/api/v2)
//
// Mirrors the design of thesportsdb_client.js: a token-bucket rate limiter,
// exponential-backoff retry that honours Retry-After on HTTP 429, a request
// observer hook, and a pagination helper for list endpoints.
//
// Auth: every request sends `Authorization: Token <BSD_API_KEY>`.
// ---------------------------------------------------------------------------

const https = require("https");
const { URL } = require("url");

const BSD_BASE_URL = "https://sports.bzzoiro.com/api/v2";
const BSD_REQUEST_TIMEOUT_MS = Number(process.env.BSD_REQUEST_TIMEOUT_MS || 30_000);
const BSD_PAGE_LIMIT = 200; // max allowed by the API
const BSD_MAX_PAGES = Number(process.env.BSD_MAX_PAGES || 100); // safety cap

const BSD_RETRY_MAX_ATTEMPTS = Number(process.env.BSD_RETRY_MAX_ATTEMPTS || 4);
const BSD_RETRY_BASE_DELAY_MS = Number(process.env.BSD_RETRY_BASE_DELAY_MS || 500);
const BSD_RETRY_MAX_DELAY_MS = Number(process.env.BSD_RETRY_MAX_DELAY_MS || 30_000);
const BSD_RETRY_JITTER_MS = Number(process.env.BSD_RETRY_JITTER_MS || 250);

// Conservative default token budget (req/min). Override via env if the upstream
// allowance is known to be higher. Refilled once per minute.
const RATE_LIMIT_MAX_TOKENS = Number(process.env.BSD_RATE_LIMIT_MAX_TOKENS || 60);
const RATE_LIMIT_REFILL_INTERVAL_MS = 60_000;

function _sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, Number(ms) || 0)));
}

function _randomDelay(maxMs) {
  const normalized = Math.max(0, Number(maxMs) || 0);
  if (normalized <= 0) return 0;
  return Math.floor(Math.random() * normalized);
}

function _retryDelayMs(attempt, options = {}) {
  const base = Math.max(0, Number(options.baseDelayMs ?? BSD_RETRY_BASE_DELAY_MS) || 0);
  const cap = Math.max(base, Number(options.maxDelayMs ?? BSD_RETRY_MAX_DELAY_MS) || base);
  const exponential = Math.min(cap, base * Math.max(1, 2 ** Math.max(0, attempt - 1)));
  const retryAfterMs = Math.max(0, Number(options.retryAfterMs) || 0);
  return Math.max(exponential, retryAfterMs) + _randomDelay(BSD_RETRY_JITTER_MS);
}

function _isRetryableError(error) {
  if (!error) return false;
  const statusCode = Number(error.statusCode || 0);
  if (statusCode === 408 || statusCode === 429) return true;
  if (statusCode >= 500 && statusCode <= 599) return true;
  const code = String(error.code || "").trim().toUpperCase();
  if (code === "BSD_JSON_PARSE_ERROR") return true;
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

function _createRateLimiter(maxTokens) {
  return {
    tokens: maxTokens,
    maxTokens,
    lastRefillMs: Date.now(),
    waitQueue: [],
  };
}

const _rateLimiter = _createRateLimiter(RATE_LIMIT_MAX_TOKENS);

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

function _acquireToken(cost = 1, limiter = _rateLimiter) {
  _refillTokens(limiter);
  if (limiter.tokens >= cost) {
    limiter.tokens -= cost;
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    limiter.waitQueue.push({ resolve, cost });
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
  return _rateLimitState(_rateLimiter);
}

// ---------------------------------------------------------------------------
// Request observer
// ---------------------------------------------------------------------------

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
    const apiKey = String(process.env.BSD_API_KEY || "").trim();
    if (!apiKey) {
      const err = new Error("BSD_API_KEY environment variable is not set");
      err.code = "BSD_NO_API_KEY";
      return reject(err);
    }

    const source = String(options.source || "bsd_unknown").trim() || "bsd_unknown";
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
        errorCode: error && error.code ? String(error.code) : null,
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
          "Authorization": `Token ${apiKey}`,
          "Accept": "application/json",
        },
      },
      (res) => {
        const statusCode = Number(res.statusCode || 0);

        if (statusCode >= 300 && statusCode < 400 && res.headers.location) {
          res.resume();
          _fetchJson(new URL(res.headers.location, target).toString(), options)
            .then(resolve)
            .catch(reject);
          return;
        }

        if (statusCode !== 200) {
          res.resume();
          const error = new Error(`BSD request failed with status ${statusCode}`);
          error.statusCode = statusCode;
          error.code = `HTTP_${statusCode}`;
          error.url = requestedUrl;
          if (statusCode === 429) {
            error.retryAfterMs = _retryAfterMs(res.headers) || RATE_LIMIT_REFILL_INTERVAL_MS;
          }
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
            parseErr.code = "BSD_JSON_PARSE_ERROR";
            parseErr.url = requestedUrl;
            complete({ statusCode, error: parseErr });
            return;
          }
          complete({ statusCode, data: parsed });
        });
      }
    );

    req.setTimeout(BSD_REQUEST_TIMEOUT_MS, () => {
      const error = new Error("BSD request timed out");
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

async function _fetchWithRetry(url, options = {}) {
  const maxAttempts = Math.max(1, Number(options.maxAttempts ?? BSD_RETRY_MAX_ATTEMPTS) || 1);
  let lastError = null;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      // eslint-disable-next-line no-await-in-loop
      await _acquireToken();
      // eslint-disable-next-line no-await-in-loop
      return await _fetchJson(url, options);
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
// URL + pagination helpers
// ---------------------------------------------------------------------------

function _buildUrl(path, query = {}) {
  // BSD canonicalises API paths with a trailing slash. Avoiding its 301
  // redirect prevents every logical API request from becoming two billable
  // upstream calls and keeps our request metric aligned with BSD usage.
  const rawPath = String(path || "/");
  const canonicalPath = rawPath.endsWith("/") ? rawPath : `${rawPath}/`;
  const url = new URL(`${BSD_BASE_URL}${canonicalPath}`);
  Object.entries(query).forEach(([key, value]) => {
    if (value === undefined || value === null || value === "") return;
    url.searchParams.set(key, String(value));
  });
  return url.toString();
}

async function _request(path, options = {}) {
  return _fetchWithRetry(_buildUrl(path, options.query), options);
}

// Pure pagination loop: walks `offset` calling `fetchPage(offset)` (which
// resolves to a `{ next, results: [...] }` page) until `next` is null or a
// short page is returned. Returns the concatenated `results`. Extracted so it
// can be unit-tested without a network round-trip.
async function _collectPages(fetchPage, { pageLimit = BSD_PAGE_LIMIT, maxPages = BSD_MAX_PAGES } = {}) {
  const all = [];
  for (let page = 0; page < maxPages; page += 1) {
    const offset = page * pageLimit;
    // eslint-disable-next-line no-await-in-loop
    const data = await fetchPage(offset);
    const results = Array.isArray(data && data.results) ? data.results : [];
    all.push(...results);
    const hasNext = Boolean(data && data.next) && results.length === pageLimit;
    if (!hasNext) break;
  }
  return all;
}

// Pages a `{ count, next, previous, results: [...] }` list endpoint, sending
// `limit=200` and walking `offset`. Returns the concatenated `results` array.
async function _requestAllPages(path, options = {}) {
  const baseQuery = { ...(options.query || {}), limit: BSD_PAGE_LIMIT };
  return _collectPages((offset) =>
    _request(path, { ...options, query: { ...baseQuery, offset } })
  );
}

// ---------------------------------------------------------------------------
// Public API methods
// ---------------------------------------------------------------------------

// Leagues / competitions (paginated). Returns the flat results array.
function getLeagues(options = {}) {
  return _requestAllPages("/leagues", {
    source: "bsd_leagues",
    reason: "leagues_fetch",
    ...options,
  });
}

function getLeague(id, options = {}) {
  return _request(`/leagues/${encodeURIComponent(id)}`, {
    source: "bsd_league",
    reason: "league_lookup",
    ...options,
  });
}

function getStandings(id, options = {}) {
  return _request(`/leagues/${encodeURIComponent(id)}/standings`, {
    source: "bsd_standings",
    reason: "standings_fetch",
    ...options,
  });
}

function getTeam(id, options = {}) {
  return _request(`/teams/${encodeURIComponent(id)}`, {
    source: "bsd_team",
    reason: "team_lookup",
    ...options,
  });
}

// Events (matches) for a league filtered by status (notstarted | finished | ...).
// Paginated. Returns the flat results array.
function getEvents({ leagueId, status } = {}, options = {}) {
  return _requestAllPages("/events", {
    source: "bsd_events",
    reason: "events_fetch",
    ...options,
    query: { ...(options.query || {}), league_id: leagueId, status },
  });
}

// TV broadcasts (paginated). Filter to a single country via `countryCode`
// (the website/app are UK-only, so callers pass "GB"). Returns the flat
// results array — one row per channel-per-event.
function getBroadcasts({ countryCode } = {}, options = {}) {
  return _requestAllPages("/broadcasts", {
    source: "bsd_broadcasts",
    reason: "broadcasts_fetch",
    ...options,
    query: { ...(options.query || {}), country_code: countryCode },
  });
}

// Live matches in progress. Shape: { count, events: [...] }. Not paginated.
function getLiveEvents(options = {}) {
  return _request("/events/live", {
    source: "bsd_events_live",
    reason: "events_live_poll",
    ...options,
  });
}

function getEvent(id, options = {}) {
  return _request(`/events/${encodeURIComponent(id)}`, {
    source: "bsd_event",
    reason: "event_lookup",
    ...options,
  });
}

function getIncidents(id, options = {}) {
  return _request(`/events/${encodeURIComponent(id)}/incidents`, {
    source: "bsd_event_incidents",
    reason: "event_incidents_fetch",
    ...options,
  });
}

function getLineups(id, options = {}) {
  return _request(`/events/${encodeURIComponent(id)}/lineups`, {
    source: "bsd_event_lineups",
    reason: "event_lineups_fetch",
    ...options,
  });
}

function getPlayer(id, options = {}) {
  return _request(`/players/${encodeURIComponent(id)}`, {
    source: "bsd_player",
    reason: "player_lookup",
    ...options,
  });
}

// Predictions for a league (paginated). Returns the flat results array.
function getPredictions({ leagueId } = {}, options = {}) {
  return _requestAllPages("/predictions", {
    source: "bsd_predictions",
    reason: "predictions_fetch",
    ...options,
    query: { ...(options.query || {}), league_id: leagueId },
  });
}

function getSocial({ eventId } = {}, options = {}) {
  return _requestAllPages("/social", {
    source: "bsd_social",
    reason: "social_fetch",
    ...options,
    query: { ...(options.query || {}), event_id: eventId },
  });
}

module.exports = {
  setRequestObserver,
  getRateLimitState,

  getLeagues,
  getLeague,
  getStandings,
  getTeam,
  getEvents,
  getBroadcasts,
  getLiveEvents,
  getEvent,
  getIncidents,
  getLineups,
  getPlayer,
  getPredictions,
  getSocial,

  __private: {
    _acquireToken,
    _isRetryableError,
    _retryAfterMs,
    _retryDelayMs,
    _buildUrl,
    _collectPages,
    _requestAllPages,
    _fetchWithRetry,
    _rateLimiter,
    RATE_LIMIT_MAX_TOKENS,
    RATE_LIMIT_REFILL_INTERVAL_MS,
    BSD_PAGE_LIMIT,
  },
};
