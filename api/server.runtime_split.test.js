const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    buildDefaultOperationalCacheState,
    filterCacheStateDomainsForRuntimeRefresh,
    normalizeCacheStateDomains,
    resolveTsdbLivescorePollIntervalMs,
    TSDB_LIVESCORE_ACTIVE_INTERVAL_MS,
    TSDB_LIVESCORE_INTERVAL_MS,
    TSDB_LIVESCORE_MAX_CALLS_PER_MINUTE,
  },
  startApiRuntime,
  startMonitorRuntime,
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
    "team_badges",
    "tsdb_live",
  ]);
});

test("normalizeCacheStateDomains accepts teams tables and team short name aliases", () => {
  assert.deepEqual(normalizeCacheStateDomains(["teams", "table", "team-short-names"]), {
    domains: ["teams", "tables", "team_short_names"],
    invalid: [],
  });
});

test("filterCacheStateDomainsForRuntimeRefresh avoids monitor match details churn", () => {
  assert.deepEqual(
    filterCacheStateDomainsForRuntimeRefresh(["matches", "match_details", "teams", "tsdb_live"], {
      runtimeRole: "monitor",
    }),
    ["matches", "tsdb_live"]
  );
  assert.deepEqual(
    filterCacheStateDomainsForRuntimeRefresh(["match_details"], {
      runtimeRole: "monitor",
    }),
    []
  );
  assert.deepEqual(
    filterCacheStateDomainsForRuntimeRefresh(["match_details"], {
      runtimeRole: "api",
    }),
    ["match_details"]
  );
});

test("server exports explicit api monitor and scraper runtime starters", () => {
  assert.equal(typeof startApiRuntime, "function");
  assert.equal(typeof startMonitorRuntime, "function");
  assert.equal(typeof startScraperRuntime, "function");
  assert.equal(typeof shutdownRuntime, "function");
});

test("TSDB livescore polling uses faster bounded cadence while matches are live", () => {
  assert.equal(resolveTsdbLivescorePollIntervalMs({ hasLiveMatches: false }), TSDB_LIVESCORE_INTERVAL_MS);
  assert.equal(resolveTsdbLivescorePollIntervalMs({ hasLiveMatches: true }), TSDB_LIVESCORE_ACTIVE_INTERVAL_MS);
  assert.ok(TSDB_LIVESCORE_ACTIVE_INTERVAL_MS <= TSDB_LIVESCORE_INTERVAL_MS);
  assert.ok(
    Math.ceil(60_000 / TSDB_LIVESCORE_ACTIVE_INTERVAL_MS) <= TSDB_LIVESCORE_MAX_CALLS_PER_MINUTE
  );
  assert.ok(TSDB_LIVESCORE_MAX_CALLS_PER_MINUTE <= 90);
});
