#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// Resumable cleanup for history written before BSON Date TTL fields were added.
// The default is deliberately read-only. Pass --execute to delete/backfill.

const { getDb, closeMongoConnection } = require("../mongo_client");

const COLLECTIONS = {
  match_write_logs: { retentionDays: 6, timestampField: "inserted_at_ms" },
  bbc_requests: { retentionDays: 7, timestampField: "timestamp_ms" },
};

function parseArgs(argv) {
  const value = (name) => {
    const prefix = `--${name}=`;
    const entry = argv.find((arg) => arg.startsWith(prefix));
    return entry ? entry.slice(prefix.length) : null;
  };
  const selected = String(value("collection") || "all")
    .split(",")
    .map((name) => name.trim())
    .filter(Boolean);
  const collections = selected.includes("all") ? Object.keys(COLLECTIONS) : selected;
  collections.forEach((name) => {
    if (!COLLECTIONS[name]) throw new Error(`Unsupported collection: ${name}`);
  });
  return {
    execute: argv.includes("--execute"),
    collections,
    batchSize: Math.max(100, Math.min(50_000, Number(value("batch-size")) || 5_000)),
    maxBatches: Math.max(0, Number(value("max-batches")) || 0),
  };
}

async function processCollection(db, name, args) {
  const config = COLLECTIONS[name];
  const history = db.collection(name);
  const cutoffMs = Date.now() - config.retentionDays * 24 * 60 * 60 * 1000;
  const staleFilter = { [config.timestampField]: { $lt: cutoffMs } };
  const missingDateFilter = {
    [config.timestampField]: { $gte: cutoffMs, $type: "number" },
    // `$type: "missing"` is not supported by MongoDB. `$exists: false` is
    // the portable way to identify the legacy records which lack the BSON
    // Date field required by the TTL index.
    inserted_at: { $exists: false },
  };
  const [staleCount, missingDateCount] = await Promise.all([
    history.countDocuments(staleFilter),
    history.countDocuments(missingDateFilter),
  ]);

  console.log(
    `[legacy-cleanup] ${name}: stale=${staleCount} retained_missing_date=${missingDateCount} ` +
      `cutoff=${new Date(cutoffMs).toISOString()} mode=${args.execute ? "execute" : "dry-run"}`
  );
  if (!args.execute) return { name, staleCount, missingDateCount, deleted: 0, backfilled: 0 };

  let deleted = 0;
  let backfilled = 0;
  let batches = 0;
  while (!args.maxBatches || batches < args.maxBatches) {
    const docs = await history
      .find(staleFilter, { projection: { _id: 1 } })
      .sort({ [config.timestampField]: 1 })
      .limit(args.batchSize)
      .toArray();
    if (docs.length === 0) break;
    const result = await history.deleteMany({ _id: { $in: docs.map((doc) => doc._id) } });
    deleted += result.deletedCount || 0;
    batches += 1;
    console.log(`[legacy-cleanup] ${name}: deleted=${deleted}/${staleCount}`);
  }

  while (!args.maxBatches || batches < args.maxBatches) {
    const docs = await history
      .find(missingDateFilter, { projection: { _id: 1, [config.timestampField]: 1 } })
      .sort({ [config.timestampField]: 1 })
      .limit(args.batchSize)
      .toArray();
    if (docs.length === 0) break;
    const result = await history.bulkWrite(
      docs.map((doc) => ({
        updateOne: {
          filter: { _id: doc._id, inserted_at: { $exists: false } },
          update: { $set: { inserted_at: new Date(doc[config.timestampField]) } },
        },
      })),
      { ordered: false }
    );
    backfilled += result.modifiedCount || 0;
    batches += 1;
    console.log(`[legacy-cleanup] ${name}: backfilled=${backfilled}/${missingDateCount}`);
  }

  return { name, staleCount, missingDateCount, deleted, backfilled, batches };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const db = await getDb();
  if (!db) throw new Error("MONGODB_URI_TOP_SCORES must be configured");
  const results = [];
  for (const name of args.collections) {
    // Sequential by design: never run two large cleanup streams against Mongo.
    // eslint-disable-next-line no-await-in-loop
    results.push(await processCollection(db, name, args));
  }
  console.log(JSON.stringify({ execute: args.execute, batchSize: args.batchSize, results }, null, 2));
}

if (require.main === module) {
  main()
    .catch((error) => {
      console.error("[legacy-cleanup] failed:", error.message || error);
      process.exitCode = 1;
    })
    .finally(() => closeMongoConnection().catch(() => {}));
}

module.exports = { COLLECTIONS, parseArgs, processCollection };
