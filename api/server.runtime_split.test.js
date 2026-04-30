const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    buildDefaultOperationalCacheState,
    filterCacheStateDomainsForRuntimeRefresh,
    normalizeCacheStateDomains,
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
    "bbc_live",
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
    filterCacheStateDomainsForRuntimeRefresh(["matches", "match_details", "teams", "bbc_live"], {
      runtimeRole: "monitor",
    }),
    ["matches", "bbc_live"]
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
