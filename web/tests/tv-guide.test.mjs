import test from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";

registerHooks({ resolve(specifier, context, next) {
  try { return next(specifier, context); }
  catch (error) {
    if (error.code === "ERR_MODULE_NOT_FOUND" && specifier.startsWith(".") && !/\.[a-z]+$/i.test(specifier)) return next(`${specifier}.ts`, context);
    throw error;
  }
} });
globalThis.document = { getElementById: () => null };
globalThis.sessionStorage = { getItem: () => null, setItem: () => {} };
const { loadDay } = await import("../src/client/dayStore.ts");
const { nextTVGuideDay } = await import("../src/client/tvGuide.ts");

const game = (date, id, status, onTV = true) => ({
  match_details_id: id,
  date,
  time: "20:00",
  league: "Premier League",
  home_team: `Home ${id}`,
  away_team: `Away ${id}`,
  score_status: status,
  tv_channels: onTV ? [{ name: "TNT Sports", countryCode: "GB" }] : [],
});

test("TV guide checks later pages before saying there are no more matches today", async () => {
  const original = globalThis.fetch;
  const date = "2026-11-10";
  const requests = [];
  globalThis.fetch = async url => {
    const query = new URL(String(url), "http://localhost").searchParams;
    requests.push(query);
    return new Response(JSON.stringify(query.get("page") === "1"
      ? [game(date, "finished", "FT")]
      : [game(date, "upcoming", "NS")]), {
      headers: { "X-Has-More": query.get("page") === "1" ? "true" : "false" },
    });
  };
  try {
    const first = await loadDay(date);
    const found = await nextTVGuideDay(date, first, false, () => true);
    assert.equal(found?.date, date);
    assert.deepEqual(found?.matches.map(match => match.id), ["upcoming"]);
    assert.deepEqual(requests.map(query => query.get("page")), ["1", "2"]);
  } finally {
    globalThis.fetch = original;
  }
});

test("TV guide skips days without remaining UK broadcasts and uses the next available date", async () => {
  const original = globalThis.fetch;
  const start = "2026-11-20";
  const requests = [];
  globalThis.fetch = async url => {
    const query = new URL(String(url), "http://localhost").searchParams;
    const date = query.get("start");
    requests.push(date);
    const games = date === start
      ? [game(date, "finished", "FT")]
      : date === "2026-11-21"
        ? [game(date, "not-on-tv", "NS", false)]
        : [game(date, "next-on-tv", "NS")];
    return new Response(JSON.stringify(games));
  };
  try {
    const first = await loadDay(start);
    const found = await nextTVGuideDay(start, first, false, () => true);
    assert.equal(found?.date, "2026-11-22");
    assert.deepEqual(found?.matches.map(match => match.id), ["next-on-tv"]);
    assert.deepEqual(requests, [start, "2026-11-21", "2026-11-22"]);
  } finally {
    globalThis.fetch = original;
  }
});
