"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { createReferenceService } = require("./reference_service");
const { createColourResolver, normalizePlayer, DAY_MS } = require("./reference_model");
const { dataset, memoryStore, rawPlayer, time } = require("./reference_test_helpers");

test("last successful catalogue survives Mongo failure and is marked stale", async () => {
  let now = Date.parse(time);
  const store = memoryStore(dataset());
  const service = createReferenceService({ store, competitionIds: ["1"], now: () => now });
  const original = await service.catalogue();
  store.load = async () => { throw new Error("Mongo unavailable"); };
  assert.equal(await service.reload(), original);
  assert.equal(service.metadata(original).stale, true);
  store.load = memoryStore(dataset()).load;
  await service.reload();
  assert.equal(service.metadata(original).stale, false);
  now += 3 * DAY_MS;
  assert.equal(service.metadata(original).stale, true);
});

test("incomplete saved snapshot never replaces the serving catalogue", async () => {
  const store = memoryStore(dataset());
  const service = createReferenceService({ store, competitionIds: ["1"] });
  const original = await service.catalogue();
  store.state.rows = [];
  assert.equal(await service.reload(), original);
  assert.equal(service.metadata(original).stale, true);
});

test("concurrent cold reads share one database load", async () => {
  let count = 0;
  const service = createReferenceService({ store: { async load() { count += 1; await new Promise((resolve) => setImmediate(resolve)); return dataset(); } }, competitionIds: ["1"] });
  const results = await Promise.all(Array.from({ length: 20 }, () => service.catalogue()));
  assert.equal(count, 1);
  assert.ok(results.every((value) => value === results[0]));
});

test("colours use configured aliases, then BSD, and never pretend defaults are verified", () => {
  const resolve = createColourResolver({ teams: [{ name: "Example United", aliases: ["Example"], primary: "#abcdef", secondary: "#123456" }] });
  assert.deepEqual(resolve({ name: "Example", colours: { primary: "#ffffff" } }), { primary: "#ABCDEF", secondary: "#123456", source: "top_scores", is_fallback: false });
  assert.equal(resolve({ name: "Unknown", colours: { primary: "abcdef" } }).source, "bsd");
  assert.deepEqual(resolve({ name: "Unknown" }), { primary: null, secondary: null, source: "unavailable", is_fallback: true });
});

test("zero ratings remain zero, missing ratings stay null and source data is not mutated", () => {
  const source = rawPlayer(363, 0);
  const before = structuredClone(source);
  assert.equal(normalizePlayer(source, time).rating, 0);
  assert.equal(normalizePlayer(rawPlayer(363, null), time).rating, null);
  assert.deepEqual(source, before);
});

test("live BSD attribute values above its documented scale are preserved without blocking a player", () => {
  const source = rawPlayer(4974, 63);
  source.attributes = { position: "M", tactical: 32, attacking: 56, defending: 33, technical: 74, creativity: 49 };
  const player = normalizePlayer(source, time);
  assert.deepEqual(player.attributes, source.attributes);
  assert.equal(player.rating, 63);
});
