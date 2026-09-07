"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { __private: { _collectPages } } = require("./bsd_client");

test("strict catalogue pagination walks offsets and verifies the final count", async () => {
  const offsets = [];
  const all = await _collectPages(async (offset) => {
    offsets.push(offset);
    return offset === 0 ? { count: 3, next: "more", results: [1, 2] } : { count: 3, next: null, results: [3] };
  }, { pageLimit: 2, strict: true });
  assert.deepEqual(offsets, [0, 2]);
  assert.deepEqual(all, [1, 2, 3]);
});

test("strict catalogue pagination refuses malformed, truncated, count-drifted and capped responses", async () => {
  for (const response of [ {}, { count: 3, next: null, results: [1, 2] }, { count: 3, next: "more", results: [1] }, { count: 4, next: "more", results: [1, 2] } ]) {
    await assert.rejects(_collectPages(async () => response, { pageLimit: 2, maxPages: 1, strict: true }), /pagination/);
  }
});
