"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  sourceFromRequest,
  defaultMatchSource,
  resolveMatchSource,
} = require("./match_source");

test("sourceFromRequest reads ?source query (normalised)", () => {
  assert.equal(sourceFromRequest({ query: { source: "bsd" } }), "bsd");
  assert.equal(sourceFromRequest({ query: { source: "TSDB" } }), "tsdb");
  assert.equal(sourceFromRequest({ query: { source: "thesportsdb" } }), "tsdb");
  assert.equal(sourceFromRequest({ query: { source: "garbage" } }), null);
  assert.equal(sourceFromRequest({ query: {} }), null);
});

test("sourceFromRequest reads X-Match-Source header via req.get and header bag", () => {
  assert.equal(sourceFromRequest({ get: (h) => (h === "x-match-source" ? "bsd" : undefined) }), "bsd");
  assert.equal(sourceFromRequest({ headers: { "x-match-source": "tsdb" } }), "tsdb");
});

test("sourceFromRequest: query takes precedence over header", () => {
  assert.equal(
    sourceFromRequest({ query: { source: "bsd" }, headers: { "x-match-source": "tsdb" } }),
    "bsd"
  );
});

test("defaultMatchSource: runtime global default wins, falls back to env then tsdb", () => {
  assert.equal(defaultMatchSource("bsd"), "bsd");
  assert.equal(defaultMatchSource(null), "tsdb"); // env default is tsdb in test env
  assert.equal(defaultMatchSource("nonsense"), "tsdb");
});

test("resolveMatchSource: request override beats global default", () => {
  assert.equal(resolveMatchSource({ query: { source: "bsd" } }, "tsdb"), "bsd");
  assert.equal(resolveMatchSource({ query: {} }, "bsd"), "bsd");
  assert.equal(resolveMatchSource({}, null), "tsdb");
});
