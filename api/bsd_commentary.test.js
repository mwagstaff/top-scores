"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { createCommentaryService } = require("./bsd_commentary");

const line = (id, text = id) => ({
  id, text, type: "shot_saved", period: 2, minute: 90, added_time: 3,
  second: null, team: "home", player: null, related_player: null,
  score: { home: 1, away: 0 }, important: false,
});
const payload = (lines, status = "inprogress") => ({
  event_id: 123, status, has_play_by_play: true, commentary: lines,
});

function fixture() {
  let time = Date.parse("2026-10-20T17:00:00Z");
  let doc;
  let event = { status: "inprogress", event_date: "2026-10-20T16:00:00Z" };
  const calls = [];
  let fetch = async () => payload([line("a")]);
  const api = createCommentaryService({
    now: () => time,
    read: async collection => collection === "bsd_events" ? (event ? [event] : []) : doc ? [doc] : [],
    save: async (collection, id, value, extra) => {
      assert.equal(collection, "bsd_commentary");
      doc = { payload: value, updated_at: new Date(time).toISOString(), ...extra };
    },
    client: { getCommentary: async (id, options) => {
      calls.push({ id, ...options });
      return fetch();
    } },
  });
  return {
    api, calls, get doc() { return doc; },
    advance(ms) { time += ms; },
    setEvent(value) { event = value; },
    setFetch(value) { fetch = value; },
    flush: () => new Promise(resolve => setImmediate(resolve)),
  };
}

test("cold concurrent viewers share one fetch; a fresh snapshot never calls BSD", async () => {
  const f = fixture();
  const [a, b] = await Promise.all([f.api.getMatchCommentary("123"), f.api.getMatchCommentary("123")]);
  assert.equal(f.calls.length, 1);
  assert.deepEqual(a, b);
  assert.equal(a.refresh_after_seconds, 15);
  assert.equal(a.stale, false);
  assert.equal(a.commentary[0].added_time, 3);
  await f.api.getMatchCommentary("123");
  assert.equal(f.calls.length, 1);
  assert.deepEqual(f.calls[0].query, { order: "asc" });
});

test("stale reads return immediately, then append deltas using the last chronological ID", async () => {
  const f = fixture();
  await f.api.getMatchCommentary("123");
  f.advance(16_000);
  f.setFetch(async () => payload([line("b"), line("b")]));
  const cached = await f.api.getMatchCommentary("123");
  assert.equal(cached.stale, true);
  assert.deepEqual(cached.commentary.map(x => x.id), ["a"]);
  await f.flush();
  assert.equal(f.calls[1].query.since, "a");
  assert.deepEqual(f.doc.payload.commentary.map(x => x.id), ["a", "b"]);
  f.advance(16_000);
  f.setFetch(async () => payload([]));
  await f.api.getMatchCommentary("123");
  await f.flush();
  assert.deepEqual(f.doc.payload.commentary.map(x => x.id), ["a", "b"]);
});

test("periodic full refresh replaces corrected and deleted lines", async () => {
  const f = fixture();
  await f.api.getMatchCommentary("123");
  f.advance(121_000);
  f.setFetch(async () => payload([line("c", "Goal disallowed.")]));
  await f.api.getMatchCommentary("123");
  await f.flush();
  assert.deepEqual(f.calls[1].query, { order: "asc" });
  assert.deepEqual(f.doc.payload.commentary.map(x => x.id), ["c"]);
});

test("a replayed full feed triggers replacement instead of retaining obsolete entries", async () => {
  const f = fixture();
  f.setFetch(async () => payload([line("a"), line("removed")]));
  await f.api.getMatchCommentary("123");
  f.advance(16_000);
  f.setFetch(async () => payload([line("a", "Corrected"), line("c")]));
  await f.api.getMatchCommentary("123");
  await f.flush();
  assert.equal(f.calls.length, 3);
  assert.deepEqual(f.calls[2].query, { order: "asc" });
  assert.deepEqual(f.doc.payload.commentary.map(x => x.id), ["a", "c"]);
  assert.equal(f.doc.payload.commentary[0].text, "Corrected");
});

test("failures preserve cached commentary and throttle retries; cold failures reject", async () => {
  const f = fixture();
  await f.api.getMatchCommentary("123");
  f.advance(16_000);
  f.setFetch(async () => { throw new Error("BSD offline"); });
  await f.api.getMatchCommentary("123");
  await f.flush();
  await f.api.getMatchCommentary("123");
  await f.flush();
  assert.equal(f.calls.length, 2);
  assert.equal(f.doc.payload.commentary[0].id, "a");
  f.advance(31_000);
  f.setFetch(async () => payload([line("b")]));
  await f.api.getMatchCommentary("123");
  await f.flush();
  assert.equal(f.doc.payload.commentary.length, 2);
  const cold = fixture();
  cold.setFetch(async () => { throw new Error("BSD offline"); });
  await assert.rejects(cold.api.getMatchCommentary("123"), /BSD offline/);
});

test("malformed or mismatched responses cannot replace a good snapshot", async () => {
  const f = fixture();
  await f.api.getMatchCommentary("123");
  f.advance(121_000);
  f.setFetch(async () => ({ ...payload([]), event_id: 999 }));
  await f.api.getMatchCommentary("123");
  await f.flush();
  assert.equal(f.doc.payload.commentary[0].id, "a");
  const cold = fixture();
  cold.setFetch(async () => payload([{ id: "broken" }]));
  await assert.rejects(cold.api.getMatchCommentary("123"), /Invalid BSD/);
});

test("upcoming and unknown matches do not hit BSD; live empty feeds remain refreshable", async () => {
  const f = fixture();
  f.setEvent(null);
  assert.equal(await f.api.getMatchCommentary("123"), null);
  f.setEvent({ status: "notstarted" });
  const upcoming = await f.api.getMatchCommentary("123");
  assert.deepEqual(upcoming.commentary, []);
  assert.equal(upcoming.refresh_after_seconds, 30);
  assert.equal(f.calls.length, 0);
  f.setEvent({ status: "inprogress" });
  f.setFetch(async () => payload([]));
  assert.deepEqual((await f.api.getMatchCommentary("123")).commentary, []);
  assert.equal(f.calls.length, 1);
});

test("full-time transition and settlement replace snapshots; unwatched matches are not fetched", async () => {
  const f = fixture();
  await f.api.refreshCachedMatchCommentary("123");
  assert.equal(f.calls.length, 0);
  await f.api.getMatchCommentary("123");
  f.setEvent({ status: "finished", event_date: "2026-10-20T16:00:00Z" });
  f.setFetch(async () => payload([line("ft")], "finished"));
  assert.equal((await f.api.getMatchCommentary("123")).stale, true);
  await f.flush();
  assert.equal(f.calls[1].query.since, undefined);
  assert.deepEqual(f.doc.payload.commentary.map(x => x.id), ["ft"]);
  assert.equal((await f.api.getMatchCommentary("123")).refresh_after_seconds, 60);
  await f.api.refreshCachedMatchCommentary("123");
  assert.equal(f.calls.length, 3);
  f.advance(6 * 60 * 60 * 1000);
  assert.equal((await f.api.getMatchCommentary("123")).refresh_after_seconds, null);
});

test("old stale completed snapshots ask the client to return for the refreshed result", async () => {
  const f = fixture();
  f.setEvent({ status: "finished", event_date: "2026-10-17T16:00:00Z" });
  f.setFetch(async () => payload([line("ft")], "finished"));
  await f.api.getMatchCommentary("123");
  f.advance(86400_001);
  const stale = await f.api.getMatchCommentary("123");
  assert.equal(stale.stale, true);
  assert.equal(stale.refresh_after_seconds, 15);
  await f.flush();
  assert.equal((await f.api.getMatchCommentary("123")).refresh_after_seconds, null);
});
