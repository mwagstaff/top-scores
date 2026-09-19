"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const https = require("node:https");

const {
  setRequestObserver,
  getRateLimitState,
  getLeagues,
  getEvent,
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
  const limiter = _createRateLimiter(30);
  await _acquireToken(1, limiter);
  // Reading global state refills tokens with elapsed wall time, which makes
  // an exact decrement assertion race the clock.
  assert.equal(limiter.tokens, 29);
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
// Response lifecycle
// ---------------------------------------------------------------------------

function mockResponses(t, respond, responseOptions = () => ({})) {
  const savedApiKey = process.env.BSD_API_KEY;
  process.env.BSD_API_KEY = "test-key";
  t.after(() => {
    if (savedApiKey === undefined) delete process.env.BSD_API_KEY;
    else process.env.BSD_API_KEY = savedApiKey;
    setRequestObserver(null);
  });
  return t.mock.method(https, "get", (_url, _options, onResponse) => {
    const req = new EventEmitter();
    const res = new EventEmitter();
    const response = responseOptions(_url);
    res.statusCode = response.statusCode || 200;
    res.headers = response.headers || {};
    res.complete = false;
    res.setEncoding = () => res;
    res.resume = () => res;
    let onTimeout;
    req.setTimeout = (_timeoutMs, callback) => {
      onTimeout = callback;
      return req;
    };
    // A destroyed request can report its error only on the response once
    // headers have arrived. Reproduce that sequence without a live server.
    req.destroy = (error) => {
      res.emit("error", error);
      res.emit("close");
      return req;
    };
    process.nextTick(() => {
      onResponse(res);
      respond(res, () => onTimeout());
    });
    return req;
  });
}

test("truncated response errors reject and release their request slot", { timeout: 1_000 }, async (t) => {
  const observed = [];
  mockResponses(t, (res) => {
    res.emit("data", '{"id":');
    res.emit("error", Object.assign(new Error("aborted"), { code: "ECONNRESET" }));
    res.emit("close");
  });
  setRequestObserver((event) => observed.push(event));

  await assert.rejects(getEvent(123, { maxAttempts: 1 }), {
    code: "ECONNRESET",
    url: "https://sports.bzzoiro.com/api/v2/events/123/",
  });
  assert.equal(getRateLimitState().activeRequests, 0);
  assert.equal(observed.length, 1);
  assert.equal(observed[0].errorCode, "ECONNRESET");
});

test("incomplete response close rejects even without a response error", { timeout: 1_000 }, async (t) => {
  mockResponses(t, (res) => {
    res.emit("data", '{"id":');
    res.emit("close");
  });

  await assert.rejects(getEvent(123, { maxAttempts: 1 }), { code: "ECONNRESET" });
  assert.equal(getRateLimitState().activeRequests, 0);
});

test("discarded HTTP error body failures preserve the status and retry delay", { timeout: 1_000 }, async (t) => {
  const observed = [];
  mockResponses(t, (res) => {
    res.emit("error", Object.assign(new Error("aborted"), { code: "ECONNRESET" }));
    res.emit("close");
  }, () => ({ statusCode: 429, headers: { "retry-after": "2" } }));
  setRequestObserver((event) => observed.push(event));

  await assert.rejects(getEvent(123, { maxAttempts: 1 }), {
    code: "HTTP_429",
    statusCode: 429,
    retryAfterMs: 2_000,
  });
  assert.equal(getRateLimitState().activeRequests, 0);
  assert.equal(observed.length, 1);
  assert.equal(observed[0].errorCode, "HTTP_429");
});

test("discarded redirect body failures do not settle the follow-up request", { timeout: 1_000 }, async (t) => {
  const observed = [];
  mockResponses(t, (res) => {
    if (res.statusCode === 301) {
      res.emit("error", Object.assign(new Error("aborted"), { code: "ECONNRESET" }));
      res.emit("close");
      return;
    }
    setImmediate(() => {
      assert.equal(getRateLimitState().activeRequests, 1);
      assert.equal(observed.length, 0);
      res.emit("data", '{"id":456}');
      res.complete = true;
      res.emit("end");
      res.emit("close");
    });
  }, (url) => url.pathname.endsWith("/123/")
    ? { statusCode: 301, headers: { location: "/api/v2/events/456/" } }
    : {});
  setRequestObserver((event) => observed.push(event));

  assert.deepEqual(await getEvent(123, { maxAttempts: 1 }), { id: 456 });
  assert.equal(getRateLimitState().activeRequests, 0);
  assert.equal(observed.length, 1);
  assert.equal(observed[0].url, "https://sports.bzzoiro.com/api/v2/events/456/");
});

test("timeout after response headers rejects once and releases its request slot", { timeout: 1_000 }, async (t) => {
  const observed = [];
  mockResponses(t, (res, timeout) => {
    res.emit("data", '{"id":');
    timeout();
    // Late events must not parse or append the abandoned body.
    res.emit("data", "123}");
    res.emit("end");
  });
  setRequestObserver((event) => observed.push(event));

  await assert.rejects(getEvent(123, { maxAttempts: 1 }), { code: "ETIMEDOUT" });
  assert.equal(getRateLimitState().activeRequests, 0);
  assert.equal(observed.length, 1);
  assert.equal(observed[0].errorCode, "ETIMEDOUT");
});

test("truncated responses retry and a complete response releases its request slot", { timeout: 1_000 }, async (t) => {
  let attempt = 0;
  mockResponses(t, (res) => {
    attempt += 1;
    if (attempt === 1) {
      res.emit("data", '{"id":');
      res.emit("error", Object.assign(new Error("aborted"), { code: "ECONNRESET" }));
    } else {
      res.emit("data", '{"id":123}');
      res.complete = true;
      res.emit("end");
    }
    res.emit("close");
  });

  assert.deepEqual(await getEvent(123, { maxAttempts: 2, baseDelayMs: 0, maxDelayMs: 0 }), { id: 123 });
  assert.equal(attempt, 2);
  assert.equal(getRateLimitState().activeRequests, 0);
});

// ---------------------------------------------------------------------------
// Request observer
// ---------------------------------------------------------------------------

test("setRequestObserver ignores non-functions without throwing", () => {
  assert.doesNotThrow(() => setRequestObserver(null));
  assert.doesNotThrow(() => setRequestObserver(42));
  setRequestObserver(null);
});
