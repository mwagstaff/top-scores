"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { parseArgs, processCollection } = require("./cleanup_legacy_history");

test("legacy history cleanup is dry-run and covers both collections by default", () => {
  const args = parseArgs([]);
  assert.equal(args.execute, false);
  assert.deepEqual(args.collections.sort(), ["bbc_requests", "match_write_logs"]);
});

test("legacy history cleanup requires explicit execute and bounds batch size", () => {
  const args = parseArgs([
    "--execute",
    "--collection=bbc_requests",
    "--batch-size=999999",
    "--max-batches=3",
  ]);
  assert.equal(args.execute, true);
  assert.deepEqual(args.collections, ["bbc_requests"]);
  assert.equal(args.batchSize, 50_000);
  assert.equal(args.maxBatches, 3);
});

test("legacy history cleanup uses $exists for documents missing the TTL date", async () => {
  const filters = [];
  const db = {
    collection() {
      return {
        countDocuments: async (filter) => {
          filters.push(filter);
          return 0;
        },
      };
    },
  };
  await processCollection(db, "bbc_requests", {
    execute: false,
    batchSize: 5000,
    maxBatches: 0,
  });
  assert.deepEqual(filters[1].inserted_at, { $exists: false });
});
