#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// Cleanup for `match_write_logs`:
//   1. Deletes documents older than the retention window in batches (the
//      legacy ttl_expiry index was on numeric inserted_at_ms, which Mongo's
//      TTL monitor ignores, so a large backlog accumulated).
//   2. Backfills the BSON Date `inserted_at` field on remaining documents so
//      the inserted_at_ttl TTL index (see mongo_client.js) can expire them.
//
// Idempotent and safe to re-run — rerun after deploying the inserted_at
// writer so any old-format docs written in the interim get backfilled too.
//
// Run: MONGODB_URI_TOP_SCORES=... node api/scripts/prune_match_write_logs.js [--dry-run]
// ---------------------------------------------------------------------------

const { getDb, closeMongoConnection } = require("../mongo_client");

const RETENTION_SECONDS = 6 * 24 * 60 * 60;
const DELETE_BATCH_SIZE = 20000;

async function run() {
  const dryRun = process.argv.includes("--dry-run");
  const db = await getDb();
  if (!db) {
    console.error("[prune-match-write-logs] Mongo not configured (MONGODB_URI_TOP_SCORES unset).");
    process.exitCode = 1;
    return;
  }

  const cutoffMs = Date.now() - RETENTION_SECONDS * 1000;
  const staleFilter = { inserted_at_ms: { $lt: cutoffMs } };
  const collection = db.collection("match_write_logs");

  const totalCount = await collection.estimatedDocumentCount();
  const staleCount = await collection.countDocuments(staleFilter);
  console.log(
    `[prune-match-write-logs] ~${totalCount} total docs, ${staleCount} older than ${new Date(cutoffMs).toISOString()}`
  );

  if (dryRun) {
    const backfillCount = await collection.countDocuments({
      inserted_at_ms: { $gte: cutoffMs },
      inserted_at: { $exists: false },
    });
    console.log(
      `[prune-match-write-logs] would delete ${staleCount} docs and backfill inserted_at on ${backfillCount} docs (dry-run)`
    );
    return;
  }

  // Batched deletes: grab the oldest batch of _ids, delete them, repeat. Keeps
  // each write small so a multi-million-doc backlog doesn't monopolise the
  // server the way a single deleteMany would.
  let deletedTotal = 0;
  for (;;) {
    const batch = await collection
      .find(staleFilter, { projection: { _id: 1 } })
      .sort({ inserted_at_ms: 1 })
      .limit(DELETE_BATCH_SIZE)
      .toArray();
    if (batch.length === 0) break;
    const result = await collection.deleteMany({ _id: { $in: batch.map((doc) => doc._id) } });
    deletedTotal += result.deletedCount || 0;
    console.log(`[prune-match-write-logs] deleted ${deletedTotal}/${staleCount}`);
  }

  const backfillResult = await collection.updateMany(
    { inserted_at: { $exists: false } },
    [{ $set: { inserted_at: { $toDate: "$inserted_at_ms" } } }]
  );
  console.log(
    `[prune-match-write-logs] deleted ${deletedTotal} docs, backfilled inserted_at on ${backfillResult.modifiedCount} docs`
  );
}

run()
  .catch((error) => {
    console.error("[prune-match-write-logs] failed:", error.message || error);
    process.exitCode = 1;
  })
  .finally(() => closeMongoConnection().catch(() => {}));
