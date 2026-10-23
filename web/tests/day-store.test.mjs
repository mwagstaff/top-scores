import test from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";

// Execute the browser TypeScript directly under Node's type stripping, with
// extension resolution matching Vite. No production loader is introduced.
registerHooks({
  resolve(specifier, context, next) {
    try {
      return next(specifier, context);
    } catch (error) {
      if (
        error.code === "ERR_MODULE_NOT_FOUND" &&
        specifier.startsWith(".") &&
        !/\.[a-z]+$/i.test(specifier)
      )
        return next(`${specifier}.ts`, context);
      throw error;
    }
  },
});
globalThis.document = { getElementById: () => null };
globalThis.sessionStorage = { getItem: () => null, setItem: () => {} };
const { loadDay, cachedDay } = await import("../src/client/dayStore.ts");
const raw = {
  match_details_id: "42",
  date: "2026-10-21",
  time: "20:00",
  league: "Premier League",
  home_team: "Home",
  away_team: "Away",
  tv_channels: [],
};

test("day requests deduplicate, retain row identity, and preserve cached scores on failure", async () => {
  const original = globalThis.fetch;
  let count = 0;
  globalThis.fetch = async () => {
    count++;
    return new Response(JSON.stringify([raw]));
  };
  try {
    const [a, b] = await Promise.all([
      loadDay("2026-10-21"),
      loadDay("2026-10-21"),
    ]);
    assert.equal(count, 1);
    assert.equal(a, b);
    const c = await loadDay("2026-10-21", false, true);
    assert.equal(c.matches[0], a.matches[0]);
    globalThis.fetch = async () => {
      throw new Error("offline");
    };
    await assert.rejects(loadDay("2026-10-21", false, true));
    assert.equal(cachedDay("2026-10-21"), c);
  } finally {
    globalThis.fetch = original;
  }
});
test("cache keys separate dates and EPL scope, and page loads deduplicate IDs", async () => {
  const original = globalThis.fetch;
  const urls = [];
  globalThis.fetch = async (url) => {
    urls.push(String(url));
    return new Response(JSON.stringify([raw]), {
      headers: { "X-Has-More": "true" },
    });
  };
  try {
    await loadDay("2026-10-22", true);
    const second = await loadDay("2026-10-22", true, true, 2);
    assert.equal(second.matches.length, 1);
    assert.equal(second.page, 2);
    assert.match(urls[0], /epl_only=true/);
    assert.match(urls[0], /page_size=200/);
    assert.match(urls[1], /page=2/);
    assert.equal(cachedDay("2026-10-22", false), undefined);
    const refreshed = await loadDay("2026-10-22", true, true);
    assert.equal(refreshed.page, 2);
    assert.equal(urls.length, 4);
  } finally {
    globalThis.fetch = original;
  }
});

test("Premier League focus honours each saved inclusion preference", async () => {
  const original = globalThis.fetch;
  const urls = [];
  globalThis.fetch = async (url) => {
    urls.push(String(url));
    return new Response("[]");
  };
  try {
    await loadDay(
      "2026-10-23",
      "major_uefa=false&home_nations=true&major_tournaments=false",
    );
    await loadDay(
      "2026-10-23",
      "major_uefa=true&home_nations=false&major_tournaments=true",
    );
    assert.equal(urls.length, 2);
    assert.match(urls[0], /home_nations=true/);
    assert.doesNotMatch(urls[0], /major_uefa|major_tournaments/);
    assert.match(urls[1], /major_uefa=true/);
    assert.match(urls[1], /major_tournaments=true/);
    assert.doesNotMatch(urls[1], /home_nations/);
  } finally {
    globalThis.fetch = original;
  }
});

test("app scopes keep all competitions unfiltered, top teams on the shared preset, and EPL free of extras", async () => {
  const original = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url) => {
    requests.push(new URL(String(url), "http://localhost").searchParams);
    return new Response("[]");
  };
  try {
    await loadDay("2026-10-24", false, true);
    await loadDay("2026-10-24", "top", true);
    await loadDay("2026-10-24", "epl", true);
    assert.equal(requests[0].has("epl_only"), false);
    assert.equal(requests[0].has("view_option"), false);
    assert.equal(requests[1].get("view_option"), "preset:top-teams");
    assert.equal(requests[1].has("epl_only"), false);
    assert.equal(requests[2].get("epl_only"), "true");
    for (const key of ["major_uefa", "home_nations", "major_tournaments"])
      assert.equal(requests[2].has(key), false);
    assert.notEqual(
      cachedDay("2026-10-24", "top"),
      cachedDay("2026-10-24", "epl"),
    );
  } finally {
    globalThis.fetch = original;
  }
});

test("watchability preserves API stars and tier without recalculating the app algorithm", async () => {
  const { normalizeMatch } = await import("../src/client/api.ts");
  const index = { score: 79, stars: 4, tier: "highly_watchable" };
  assert.deepEqual(
    normalizeMatch({ ...raw, watchability_index: index }).watchabilityIndex,
    index,
  );
  assert.equal(normalizeMatch(raw).watchabilityIndex, null);
  assert.equal(
    normalizeMatch({ ...raw, watchability_index: { ...index, stars: 9 } })
      .watchabilityIndex,
    null,
  );
});
