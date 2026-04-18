const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    buildDefaultOperationalCacheState,
    normalizeCacheStateDomains,
  },
  startApiRuntime,
  startScraperRuntime,
  shutdownRuntime,
} = require("./server");

test("buildDefaultOperationalCacheState initializes all split-runtime cache domains", () => {
  const snapshot = buildDefaultOperationalCacheState("2026-04-17T12:00:00.000Z");

  assert.deepEqual(Object.keys(snapshot.domains), [
    "matches",
    "match_details",
    "teams",
    "tables",
    "team_short_names",
    "bbc_live",
  ]);
});

test("normalizeCacheStateDomains accepts teams tables and team short name aliases", () => {
  assert.deepEqual(normalizeCacheStateDomains(["teams", "table", "team-short-names"]), {
    domains: ["teams", "tables", "team_short_names"],
    invalid: [],
  });
});

test("server exports explicit api and scraper runtime starters", () => {
  assert.equal(typeof startApiRuntime, "function");
  assert.equal(typeof startScraperRuntime, "function");
  assert.equal(typeof shutdownRuntime, "function");
});
