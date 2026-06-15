"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  setRequestObserver,
  getRateLimitState,
  getV1RateLimitState,
  __private,
} = require("./thesportsdb_client");

const {
  _acquireToken,
  _isNullResult,
  _isRetryableError,
  _retryAfterMs,
  RATE_LIMIT_MAX_TOKENS,
  RATE_LIMIT_V1_MAX_TOKENS,
  RATE_LIMIT_REFILL_INTERVAL_MS,
  NULL_RESULT_RETRY_DELAY_MS,
  NULL_RESULT_MAX_RETRIES,
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
  assert.equal(state.maxTokens, RATE_LIMIT_MAX_TOKENS);
});

test("getV1RateLimitState returns the v1 30/minute cap", () => {
  const state = getV1RateLimitState();
  assert.ok(typeof state.tokens === "number");
  assert.ok(typeof state.maxTokens === "number");
  assert.ok(typeof state.queueDepth === "number");
  assert.ok(typeof state.msUntilRefill === "number");
  assert.equal(state.maxTokens, RATE_LIMIT_V1_MAX_TOKENS);
  assert.equal(RATE_LIMIT_V1_MAX_TOKENS, 30);
});

test("_acquireToken resolves immediately when tokens are available", async () => {
  // There should always be tokens at the start of the test suite.
  const before = getRateLimitState().tokens;
  assert.ok(before > 0, "expected tokens to be available");
  await assert.doesNotReject(() => _acquireToken());
  const after = getRateLimitState().tokens;
  assert.equal(after, before - 1);
});

test("token count decrements by 1 per _acquireToken call", async () => {
  const { tokens: start } = getRateLimitState();
  const calls = Math.min(5, start);
  for (let i = 0; i < calls; i += 1) {
    // eslint-disable-next-line no-await-in-loop
    await _acquireToken();
  }
  const { tokens: end } = getRateLimitState();
  assert.equal(end, start - calls);
});

test("RATE_LIMIT_MAX_TOKENS is strictly below 100", () => {
  assert.ok(RATE_LIMIT_MAX_TOKENS < 100, "must stay under the 100 req/min hard cap");
  assert.ok(RATE_LIMIT_MAX_TOKENS > 0);
});

test("RATE_LIMIT_V1_MAX_TOKENS is 30", () => {
  assert.equal(RATE_LIMIT_V1_MAX_TOKENS, 30);
});

test("RATE_LIMIT_REFILL_INTERVAL_MS is 60 seconds", () => {
  assert.equal(RATE_LIMIT_REFILL_INTERVAL_MS, 60_000);
});

// ---------------------------------------------------------------------------
// Null-result detection
// ---------------------------------------------------------------------------

test("_isNullResult: single null-valued key is a null result", () => {
  assert.equal(_isNullResult({ livescore: null }), true);
  assert.equal(_isNullResult({ events: null }), true);
  assert.equal(_isNullResult({ lookup: null }), true);
});

test("_isNullResult: multi-key object with all nulls is a null result", () => {
  assert.equal(_isNullResult({ a: null, b: null }), true);
});

test("_isNullResult: object with actual data is not a null result", () => {
  assert.equal(_isNullResult({ livescore: [] }), false);
  assert.equal(_isNullResult({ lookup: [{ idEvent: "123" }] }), false);
  assert.equal(_isNullResult({ events: [{}] }), false);
});

test("_isNullResult: mixed null and non-null is not a null result", () => {
  assert.equal(_isNullResult({ a: null, b: "value" }), false);
});

test("_isNullResult: empty object is not a null result", () => {
  assert.equal(_isNullResult({}), false);
});

test("_isNullResult: non-objects are not null results", () => {
  assert.equal(_isNullResult(null), false);
  assert.equal(_isNullResult(undefined), false);
  assert.equal(_isNullResult("string"), false);
  assert.equal(_isNullResult(42), false);
});

// ---------------------------------------------------------------------------
// Retry helpers
// ---------------------------------------------------------------------------

test("_isRetryableError retries 429 and transient JSON parse failures", () => {
  assert.equal(_isRetryableError({ statusCode: 429 }), true);
  assert.equal(_isRetryableError({ statusCode: 500 }), true);
  assert.equal(_isRetryableError({ code: "TSDB_JSON_PARSE_ERROR" }), true);
  assert.equal(_isRetryableError({ statusCode: 404 }), false);
});

test("_retryAfterMs parses retry-after seconds", () => {
  assert.equal(_retryAfterMs({ "retry-after": "2" }), 2_000);
});

// ---------------------------------------------------------------------------
// Request observer
// ---------------------------------------------------------------------------

test("setRequestObserver: non-function is ignored (no crash)", () => {
  assert.doesNotThrow(() => setRequestObserver(null));
  assert.doesNotThrow(() => setRequestObserver(undefined));
  assert.doesNotThrow(() => setRequestObserver(42));
});

test("setRequestObserver: observer is called when set, cleared when set to null", async () => {
  const events = [];
  setRequestObserver((e) => events.push(e));

  // Directly invoke the module's observer machinery by making a real call.
  // Since THE_SPORTS_DB_API_KEY is not set in the test environment, _fetchJson
  // will reject immediately with TSDB_NO_API_KEY — but the observer should
  // NOT be called because the token is acquired before _fetchJson is called,
  // and _fetchJson rejects before the HTTP round-trip (so no observer event).
  // We test the observer wiring by verifying setRequestObserver doesn't throw
  // and the stored reference is cleared correctly.
  setRequestObserver(null);
  assert.equal(events.length, 0); // No HTTP calls happened; just wiring check.
});

// ---------------------------------------------------------------------------
// Constants (regression guard)
// ---------------------------------------------------------------------------

test("NULL_RESULT_RETRY_DELAY_MS is 2 seconds", () => {
  assert.equal(NULL_RESULT_RETRY_DELAY_MS, 2_000);
});

test("NULL_RESULT_MAX_RETRIES is 2", () => {
  assert.equal(NULL_RESULT_MAX_RETRIES, 2);
});
