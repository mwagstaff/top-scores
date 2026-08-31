"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { createEurGbpRateService } = require("./exchange_rates");

test("EUR to GBP service reuses a fresh persisted rate", async () => {
  let requestCount = 0;
  const service = createEurGbpRateService({
    now: () => Date.parse("2026-08-30T12:00:00Z"),
    load: async () => ({
      rate: 0.85,
      date: "2026-08-30",
      fetched_at: "2026-08-30T08:00:00Z",
    }),
    request: async () => {
      requestCount += 1;
      return { rate: 0.9 };
    },
  });

  const result = await service.getRate();
  assert.equal(result.rate, 0.85);
  assert.equal(result.source, "cache");
  assert.equal(requestCount, 0);
});

test("EUR to GBP service falls back to the last good stale rate", async () => {
  const service = createEurGbpRateService({
    now: () => Date.parse("2026-08-30T12:00:00Z"),
    load: async () => ({
      rate: 0.84,
      date: "2026-08-28",
      fetched_at: "2026-08-28T08:00:00Z",
    }),
    request: async () => {
      throw new Error("offline");
    },
  });

  const result = await service.getRate();
  assert.equal(result.rate, 0.84);
  assert.equal(result.stale, true);
  assert.equal(result.source, "stale_cache");
});

test("EUR to GBP service deduplicates concurrent refreshes", async () => {
  let requestCount = 0;
  const service = createEurGbpRateService({
    now: () => Date.parse("2026-08-30T12:00:00Z"),
    request: async () => {
      requestCount += 1;
      await new Promise((resolve) => setImmediate(resolve));
      return { rate: 0.85761, date: "2026-08-30" };
    },
  });

  const [first, second] = await Promise.all([service.getRate(), service.getRate()]);
  assert.equal(first.rate, 0.85761);
  assert.equal(second.rate, 0.85761);
  assert.equal(requestCount, 1);
});
