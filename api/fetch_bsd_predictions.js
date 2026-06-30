#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// Ingest BSD predictions into Mongo:
//   - predictions per league -> bsd_predictions (one doc per allowlisted league)
//
// Predictions change slowly (recomputed periodically upstream), so this is
// refreshed once daily by the bsd runtime rather than on the events cadence.
//
// Run: BSD_API_KEY=... MONGODB_URI_TOP_SCORES=... node api/fetch_bsd_predictions.js
// ---------------------------------------------------------------------------

const bsd = require("./bsd_client");
const { BSD_LEAGUE_ALLOWLIST } = require("./bsd_config");
const { upsertBsdRecord, closeMongoConnection } = require("./mongo_client");

async function ingestPredictions(leagueId) {
  try {
    const results = await bsd.getPredictions(
      { leagueId },
      { initiator: "fetch_bsd_predictions" }
    );
    await upsertBsdRecord("bsd_predictions", leagueId, results, {
      league_id: Number(leagueId),
      count: Array.isArray(results) ? results.length : 0,
    });
    console.log(
      `[bsd] predictions league ${leagueId}: ok (${Array.isArray(results) ? results.length : 0} fixtures)`
    );
  } catch (error) {
    console.error(`[bsd] predictions league ${leagueId} failed: ${error.message || error}`);
  }
}

// Predictions for every allowlisted league. Shared by the CLI entry point and
// the bsd runtime's daily refresh cadence.
async function refreshAllPredictions() {
  for (const leagueId of BSD_LEAGUE_ALLOWLIST) {
    // eslint-disable-next-line no-await-in-loop
    await ingestPredictions(leagueId);
  }
}

async function runCli() {
  await refreshAllPredictions();
  await closeMongoConnection();
}

if (require.main === module) {
  runCli().catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

module.exports = { ingestPredictions, refreshAllPredictions };
