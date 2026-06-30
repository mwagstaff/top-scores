#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// One-time migration: rename the TSDB-sourced Mongo collections to a `tsdb_`
// prefix (symmetry with the `bsd_` collections). Uses Mongo renameCollection,
// which is atomic and preserves documents + indexes.
//
// Idempotent and safe to re-run:
//   - if the old collection is missing, skip
//   - if the new (tsdb_) collection already exists, skip (never overwrites)
//
// Run: MONGODB_URI_TOP_SCORES=... node api/scripts/rename_tsdb_collections.js [--dry-run]
//
// NOTE: only the listed caches are renamed. `matches`, `operational_datasets`,
// `match_write_logs` are source-agnostic operational data and are NOT renamed.
// ---------------------------------------------------------------------------

const { getDb, closeMongoConnection } = require("../mongo_client");

const RENAMES = [
  ["players", "tsdb_players"],
  ["teams", "tsdb_teams"],
  ["match_lineups", "tsdb_match_lineups"],
  ["match_timelines", "tsdb_match_timelines"],
  ["leagues", "tsdb_leagues"],
  ["league_tables", "tsdb_league_tables"],
  ["tv_listings", "tsdb_tv_listings"],
];

async function collectionExists(db, name) {
  const found = await db.listCollections({ name }, { nameOnly: true }).toArray();
  return found.length > 0;
}

async function run() {
  const dryRun = process.argv.includes("--dry-run");
  const db = await getDb();
  if (!db) {
    console.error("[rename-tsdb] Mongo not configured (MONGODB_URI_TOP_SCORES unset).");
    process.exitCode = 1;
    return;
  }

  console.log(`[rename-tsdb] starting${dryRun ? " (dry-run)" : ""}`);
  for (const [oldName, newName] of RENAMES) {
    // eslint-disable-next-line no-await-in-loop
    const [oldExists, newExists] = await Promise.all([
      collectionExists(db, oldName),
      collectionExists(db, newName),
    ]);

    if (newExists) {
      console.log(`[rename-tsdb] skip ${oldName} -> ${newName}: target already exists`);
      continue;
    }
    if (!oldExists) {
      console.log(`[rename-tsdb] skip ${oldName} -> ${newName}: source missing`);
      continue;
    }
    // eslint-disable-next-line no-await-in-loop
    const count = await db.collection(oldName).countDocuments();
    if (dryRun) {
      console.log(`[rename-tsdb] would rename ${oldName} -> ${newName} (${count} docs)`);
      continue;
    }
    // eslint-disable-next-line no-await-in-loop
    await db.collection(oldName).rename(newName, { dropTarget: false });
    console.log(`[rename-tsdb] renamed ${oldName} -> ${newName} (${count} docs, indexes preserved)`);
  }

  console.log("[rename-tsdb] complete");
}

run()
  .catch((error) => {
    console.error("[rename-tsdb] failed:", error.message || error);
    process.exitCode = 1;
  })
  .finally(() => closeMongoConnection().catch(() => {}));
