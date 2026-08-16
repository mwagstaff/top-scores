"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  setRequestObserver,
  getRateLimitState,
  getLeagues,
  __private,
} = require("./bsd_client");

const {
  _acquireToken,
  _createRateLimiter,
  _refillTokens,
  _acquireRequestSlot,
  _releaseRequestSlot,
  _isRetryableError,
  _retryAfterMs,
  _buildUrl,
  _collectPages,
  RATE_LIMIT_MAX_TOKENS,
  RATE_LIMIT_BURST_TOKENS,
  RATE_LIMIT_REFILL_INTERVAL_MS,
  BSD_PAGE_LIMIT,
  BSD_MAX_CONCURRENT_REQUESTS,
} = __private;

// ---------------------------------------------------------------------------
// Rate limiter
// ---------------------------------------------------------------------------

test("getRateLimitState returns expected shape", () => {
  const state = getRateLimitState();
  assert.ok(typeof state.tokens === "number");
  assert.ok(typeof state.maxTokens === "number");
  assert.ok(typeof state.queueDepth === "number");
  assert.ok(typeof state.msUntilRefill === "number");
  assert.ok(typeof state.activeRequests === "number");
  assert.ok(typeof state.requestQueueDepth === "number");
  assert.equal(state.maxTokens, RATE_LIMIT_MAX_TOKENS);
  assert.equal(state.burstTokens, RATE_LIMIT_BURST_TOKENS);
  assert.equal(state.maxConcurrentRequests, BSD_MAX_CONCURRENT_REQUESTS);
});

test("_acquireToken decrements the token count by 1", async () => {
  const before = getRateLimitState().tokens;
  assert.ok(before > 0, "expected tokens to be available");
  await _acquireToken();
  assert.equal(getRateLimitState().tokens, before - 1);
});

test("RATE_LIMIT_REFILL_INTERVAL_MS is 60 seconds", () => {
  assert.equal(RATE_LIMIT_REFILL_INTERVAL_MS, 60_000);
});

test("rate limiter refills smoothly throughout the minute", () => {
  const limiter = _createRateLimiter(60, 1_000);
  limiter.tokens = 0;
  _refillTokens(limiter, 1_500);
  assert.equal(limiter.tokens, 0.5);
  _refillTokens(limiter, 31_000);
  assert.equal(limiter.tokens, 30);
  _refillTokens(limiter, 91_000);
  assert.equal(limiter.tokens, 60);
});

test("request concurrency hands released slots to queued callers", async () => {
  const state = { active: 0, max: 2, waitQueue: [] };
  await _acquireRequestSlot(state);
  await _acquireRequestSlot(state);
  let thirdAcquired = false;
  const third = _acquireRequestSlot(state).then(() => { thirdAcquired = true; });
  await Promise.resolve();
  assert.equal(thirdAcquired, false);
  assert.equal(state.waitQueue.length, 1);
  _releaseRequestSlot(state);
  await third;
  assert.equal(thirdAcquired, true);
  assert.equal(state.active, 2);
  _releaseRequestSlot(state);
  _releaseRequestSlot(state);
  assert.equal(state.active, 0);
});

// ---------------------------------------------------------------------------
// Retry helpers
// ---------------------------------------------------------------------------

test("_isRetryableError retries 429/5xx/transient, not 4xx", () => {
  assert.equal(_isRetryableError({ statusCode: 429 }), true);
  assert.equal(_isRetryableError({ statusCode: 503 }), true);
  assert.equal(_isRetryableError({ code: "BSD_JSON_PARSE_ERROR" }), true);
  assert.equal(_isRetryableError({ code: "ETIMEDOUT" }), true);
  assert.equal(_isRetryableError({ statusCode: 404 }), false);
  assert.equal(_isRetryableError({ statusCode: 401 }), false);
});

test("_retryAfterMs parses retry-after seconds", () => {
  assert.equal(_retryAfterMs({ "retry-after": "2" }), 2_000);
  assert.equal(_retryAfterMs({}), 0);
});

// ---------------------------------------------------------------------------
// URL building
// ---------------------------------------------------------------------------

test("_buildUrl uses BSD's trailing-slash canonical URL and skips empty query values", () => {
  const url = _buildUrl("/events", { league_id: 27, status: "finished", offset: 0, page: null });
  assert.ok(url.startsWith("https://sports.bzzoiro.com/api/v2/events/?"));
  assert.ok(url.includes("league_id=27"));
  assert.ok(url.includes("status=finished"));
  assert.ok(url.includes("offset=0"));
  assert.ok(!url.includes("page="));
});

// ---------------------------------------------------------------------------
// Pagination assembly
// ---------------------------------------------------------------------------

test("_collectPages concatenates full pages until next is null", async () => {
  const pages = [
    { next: "url-2", results: Array.from({ length: BSD_PAGE_LIMIT }, (_, i) => i) },
    { next: "url-3", results: Array.from({ length: BSD_PAGE_LIMIT }, (_, i) => BSD_PAGE_LIMIT + i) },
    { next: null, results: [9991, 9992] },
  ];
  const seenOffsets = [];
  const fetchPage = async (offset) => {
    seenOffsets.push(offset);
    return pages[offset / BSD_PAGE_LIMIT];
  };
  const all = await _collectPages(fetchPage);
  assert.equal(all.length, BSD_PAGE_LIMIT * 2 + 2);
  assert.deepEqual(seenOffsets, [0, BSD_PAGE_LIMIT, BSD_PAGE_LIMIT * 2]);
});

test("_collectPages stops on a short page even if next is set", async () => {
  const fetchPage = async () => ({ next: "more", results: [1, 2, 3] });
  const all = await _collectPages(fetchPage);
  assert.deepEqual(all, [1, 2, 3]);
});

test("_collectPages tolerates a missing results array", async () => {
  const fetchPage = async () => ({ next: null });
  const all = await _collectPages(fetchPage);
  assert.deepEqual(all, []);
});

test("_collectPages honours a per-call page cap", async () => {
  const seenOffsets = [];
  const fetchPage = async (offset) => {
    seenOffsets.push(offset);
    return { next: "more", results: Array.from({ length: BSD_PAGE_LIMIT }, (_, i) => i) };
  };
  const all = await _collectPages(fetchPage, { maxPages: 2 });
  assert.equal(all.length, BSD_PAGE_LIMIT * 2);
  assert.deepEqual(seenOffsets, [0, BSD_PAGE_LIMIT]);
});

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

test("requests reject with BSD_NO_API_KEY when BSD_API_KEY is unset", async () => {
  const saved = process.env.BSD_API_KEY;
  delete process.env.BSD_API_KEY;
  try {
    await assert.rejects(() => getLeagues(), (err) => err && err.code === "BSD_NO_API_KEY");
  } finally {
    if (saved !== undefined) process.env.BSD_API_KEY = saved;
  }
});

// ---------------------------------------------------------------------------
// Request observer
// ---------------------------------------------------------------------------

test("setRequestObserver ignores non-functions without throwing", () => {
  assert.doesNotThrow(() => setRequestObserver(null));
  assert.doesNotThrow(() => setRequestObserver(42));
  setRequestObserver(null);
});
