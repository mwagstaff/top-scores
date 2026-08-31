const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    buildDefaultOperationalCacheState,
    filterCacheStateDomainsForRuntimeRefresh,
    normalizeCacheStateDomains,
    scheduleEplSeasonStatusDailyRefresh,
    scheduleLeagueTablesDailyRefresh,
    scheduleLiveFootballTvDailyRefresh,
    hasValidLiveFootballTvAdminToken,
    updateFantasyBootstrapStatic,
    updateFantasyEventLive,
    updateFantasyFixtures,
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
  ]);
});

test("normalizeCacheStateDomains accepts teams tables and team short name aliases", () => {
  assert.deepEqual(normalizeCacheStateDomains(["teams", "table", "team-short-names"]), {
    domains: ["teams", "tables", "team_short_names"],
    invalid: [],
  });
});

test("filterCacheStateDomainsForRuntimeRefresh keeps the monitor's team dataset current without match-details churn", () => {
  assert.deepEqual(
    filterCacheStateDomainsForRuntimeRefresh(["matches", "match_details", "teams"], {
      runtimeRole: "monitor",
    }),
    ["matches", "teams"]
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

test("split runtimes retain working daily schedulers", async () => {
  assert.equal(typeof scheduleLeagueTablesDailyRefresh, "function");
  assert.equal(typeof scheduleLiveFootballTvDailyRefresh, "function");
  assert.equal(typeof scheduleEplSeasonStatusDailyRefresh, "function");
  assert.doesNotThrow(() => {
    scheduleLeagueTablesDailyRefresh();
    scheduleLiveFootballTvDailyRefresh();
    scheduleEplSeasonStatusDailyRefresh();
  });
  await shutdownRuntime();
});

test("TV listings admin refresh uses an exact bearer token", () => {
  const request = (authorization) => ({ get: () => authorization });
  assert.equal(hasValidLiveFootballTvAdminToken(request("Bearer secret"), "secret"), true);
  assert.equal(hasValidLiveFootballTvAdminToken(request("Bearer wrong"), "secret"), false);
  assert.equal(hasValidLiveFootballTvAdminToken(request("Basic secret"), "secret"), false);
  assert.equal(hasValidLiveFootballTvAdminToken(request("Bearer secret"), ""), false);
});

test("API intervals retain their fantasy updaters", () => {
  assert.equal(typeof updateFantasyBootstrapStatic, "function");
  assert.equal(typeof updateFantasyFixtures, "function");
  assert.equal(typeof updateFantasyEventLive, "function");
});
