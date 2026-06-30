#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// Ingest BSD reference data into Mongo:
//   - all leagues          -> bsd_leagues   (one doc per league)
//   - standings per league -> bsd_standings (one doc per allowlisted league)
//
// Run: BSD_API_KEY=... MONGODB_URI_TOP_SCORES=... node api/fetch_bsd_reference.js
// ---------------------------------------------------------------------------

const bsd = require("./bsd_client");
const { BSD_LEAGUE_ALLOWLIST } = require("./bsd_config");
const { upsertBsdRecords, upsertBsdRecord, closeMongoConnection } = require("./mongo_client");

async function ingestLeagues() {
  const leagues = await bsd.getLeagues({ initiator: "fetch_bsd_reference" });
  const records = leagues
    .filter((league) => league && league.id != null)
    .map((league) => ({
      id: league.id,
      payload: league,
      extra: {
        name: league.name || null,
        country: league.country || null,
        is_active: Boolean(league.is_active),
      },
    }));
  const result = await upsertBsdRecords("bsd_leagues", records);
  console.log(`[bsd] leagues: fetched ${leagues.length}, upserted ${records.length}`);
  return result;
}

async function ingestStandings(leagueId) {
  try {
    const standings = await bsd.getStandings(leagueId, { initiator: "fetch_bsd_reference" });
    await upsertBsdRecord("bsd_standings", leagueId, standings, {
      league_id: standings && standings.league_id != null ? standings.league_id : Number(leagueId),
      grouped: Boolean(standings && standings.grouped),
    });
    const groupCount =
      standings && standings.groups ? Object.keys(standings.groups).length : null;
    console.log(
      `[bsd] standings league ${leagueId}: ok` +
        (groupCount != null ? ` (${groupCount} groups)` : "")
    );
  } catch (error) {
    console.error(`[bsd] standings league ${leagueId} failed: ${error.message || error}`);
  }
}

// Standings for every allowlisted league. Split out from refreshAllReference
// so the bsd runtime can refresh standings on their own cadence (live poll /
// daily) independently of the much-less-frequent leagues list refresh.
async function refreshAllStandings() {
  for (const leagueId of BSD_LEAGUE_ALLOWLIST) {
    // eslint-disable-next-line no-await-in-loop
    await ingestStandings(leagueId);
  }
}

// Full reference refresh: leagues + standings for every allowlisted league.
// Shared by the CLI entry point and the bsd runtime's initial on-start run.
async function refreshAllReference() {
  console.log(`[bsd] reference ingest, allowlist: ${BSD_LEAGUE_ALLOWLIST.join(", ")}`);
  await ingestLeagues();
  await refreshAllStandings();
  console.log("[bsd] reference ingest complete");
}

async function runCli() {
  await refreshAllReference();
  await closeMongoConnection();
}

if (require.main === module) {
  runCli().catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

module.exports = { ingestLeagues, ingestStandings, refreshAllStandings, refreshAllReference };
