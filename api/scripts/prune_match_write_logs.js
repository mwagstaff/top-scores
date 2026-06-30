#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// One-off cleanup: delete `match_write_logs` documents older than the
// retention window now enforced by the TTL index (see mongo_client.js
// MATCH_WRITE_LOGS_TTL_SECONDS). The TTL index only governs documents going
// forward from when it was created; it does not retroactively purge the
// existing backlog, so this script clears that backlog once.
//
// Idempotent and safe to re-run.
//
// Run: MONGODB_URI_TOP_SCORES=... node api/scripts/prune_match_write_logs.js [--dry-run]
// ---------------------------------------------------------------------------

const { getDb, closeMongoConnection } = require("../mongo_client");

const RETENTION_SECONDS = 6 * 24 * 60 * 60;

async function run() {
  const dryRun = process.argv.includes("--dry-run");
  const db = await getDb();
  if (!db) {
    console.error("[prune-match-write-logs] Mongo not configured (MONGODB_URI_TOP_SCORES unset).");
    process.exitCode = 1;
    return;
  }

  const cutoffMs = Date.now() - RETENTION_SECONDS * 1000;
  const filter = { inserted_at_ms: { $lt: cutoffMs } };
  const collection = db.collection("match_write_logs");

  const totalCount = await collection.countDocuments();
  const staleCount = await collection.countDocuments(filter);
  console.log(
    `[prune-match-write-logs] ${totalCount} total docs, ${staleCount} older than ${new Date(cutoffMs).toISOString()}`
  );

  if (staleCount === 0) {
    console.log("[prune-match-write-logs] nothing to prune");
    return;
  }

  if (dryRun) {
    console.log(`[prune-match-write-logs] would delete ${staleCount} docs (dry-run)`);
    return;
  }

  const result = await collection.deleteMany(filter);
  console.log(`[prune-match-write-logs] deleted ${result.deletedCount} docs`);
}

run()
  .catch((error) => {
    console.error("[prune-match-write-logs] failed:", error.message || error);
    process.exitCode = 1;
  })
  .finally(() => closeMongoConnection().catch(() => {}));
