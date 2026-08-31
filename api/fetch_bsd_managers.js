#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// Ingest current BSD managers for every supported league. Managers can appear
// in more than one competition, so each refresh deduplicates them by id before
// writing one record per manager to Mongo.
// ---------------------------------------------------------------------------

const bsd = require("./bsd_client");
const { BSD_LEAGUE_ALLOWLIST } = require("./bsd_config");
const { upsertBsdRecords, closeMongoConnection } = require("./mongo_client");

function managerRecords(resultsByLeague = []) {
  const managersById = new Map();

  for (const entry of resultsByLeague) {
    const leagueId = String(entry && entry.leagueId || "").trim();
    const managers = Array.isArray(entry && entry.managers) ? entry.managers : [];
    for (const manager of managers) {
      const id = String(manager && manager.id || "").trim();
      if (!id) continue;
      const existing = managersById.get(id);
      const leagueIds = new Set(existing ? existing.extra.league_ids : []);
      if (leagueId) leagueIds.add(leagueId);
      managersById.set(id, {
        id,
        payload: { ...(existing && existing.payload || {}), ...manager },
        extra: {
          current_team_id: String(manager.current_team_id || existing && existing.extra.current_team_id || "").trim() || null,
          country: String(manager.country || existing && existing.extra.country || "").trim() || null,
          league_ids: [...leagueIds],
        },
      });
    }
  }

  return [...managersById.values()];
}

async function refreshAllManagers() {
  const resultsByLeague = [];
  for (const leagueId of BSD_LEAGUE_ALLOWLIST) {
    try {
      // Deliberately sequential: the shared BSD client already retries and
      // rate-limits, while this hourly reference refresh stays low priority.
      // eslint-disable-next-line no-await-in-loop
      const managers = await bsd.getManagers(
        { leagueId },
        { initiator: "fetch_bsd_managers" }
      );
      resultsByLeague.push({ leagueId, managers });
      console.log(`[bsd] managers league ${leagueId}: ok (${managers.length})`);
    } catch (error) {
      console.error(`[bsd] managers league ${leagueId} failed: ${error.message || error}`);
    }
  }

  const records = managerRecords(resultsByLeague);
  await upsertBsdRecords("bsd_managers", records);
  console.log(`[bsd] managers refresh complete (${records.length} unique managers)`);
  return records;
}

async function runCli() {
  await refreshAllManagers();
  await closeMongoConnection();
}

if (require.main === module) {
  runCli().catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

module.exports = { managerRecords, refreshAllManagers };
