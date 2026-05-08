#!/usr/bin/env node

process.env.MONGO_READ_BACKFILL_DISABLED = "1";
process.env.MONGO_READ_PRIMARY_DISABLED = "1";

const {
  getAllUserPreferences,
  getAllOperationalMatchDetails,
  getOperationalDatasets,
  getFantasyReminderRecords,
  getBbcMatchHistoryGrouped,
  getBbcRequestHistory,
  closeRedisConnection,
} = require("../redis_client");
const mongoStore = require("../mongo_client");

const DEFAULT_COLLECTIONS = [
  "user_devices",
  "matches",
  "operational_datasets",
  "fantasy_reminders",
  "bbc_history",
  "bbc_requests",
];

const OPERATIONAL_DATASETS = [
  "live_matches",
  "bbc_live_matches",
  "bbc_range_matches",
  "recent_matches",
  "merged_matches",
  "premier_league_teams",
  "league_tables",
  "club_elo_teams",
  "football_database_teams",
  "national_elo_teams",
  "missing_team_logos",
  "team_short_names",
  "cache_state",
];

function parseArgs(argv) {
  const args = {
    dryRun: true,
    collections: DEFAULT_COLLECTIONS,
    historyDays: 14,
  };

  argv.slice(2).forEach((arg) => {
    if (arg === "--apply") {
      args.dryRun = false;
      return;
    }
    if (arg === "--dry-run") {
      args.dryRun = true;
      return;
    }
    if (arg.startsWith("--collections=")) {
      args.collections = arg
        .slice("--collections=".length)
        .split(",")
        .map((value) => value.trim())
        .filter(Boolean);
      return;
    }
    if (arg.startsWith("--history-days=")) {
      const parsed = Number(arg.slice("--history-days=".length));
      if (Number.isFinite(parsed) && parsed > 0) {
        args.historyDays = Math.floor(parsed);
      }
    }
  });

  return args;
}

function emptyResult(name) {
  return {
    collection: name,
    read: 0,
    written: 0,
    skipped: 0,
    failed: 0,
  };
}

async function maybeWrite(dryRun, fn) {
  if (dryRun) return true;
  await fn();
  return true;
}

async function migrateUserDevices(dryRun) {
  const result = emptyResult("user_devices");
  const records = await getAllUserPreferences();
  result.read = Array.isArray(records) ? records.length : 0;
  for (const record of records || []) {
    try {
      if (!record || !record.deviceToken) {
        result.skipped += 1;
        continue;
      }
      await maybeWrite(dryRun, () => mongoStore.upsertUserPreferences(record));
      result.written += 1;
    } catch (error) {
      result.failed += 1;
      console.warn(`[Migration] user_devices failed for ${record && record.deviceToken}:`, error.message || error);
    }
  }
  return result;
}

async function migrateMatches(dryRun) {
  const result = emptyResult("matches");
  const snapshot = await getAllOperationalMatchDetails();
  const records = snapshot && snapshot.records ? snapshot.records : {};
  result.read = Object.keys(records).length;
  if (result.read === 0) return result;
  try {
    await maybeWrite(dryRun, () =>
      mongoStore.saveOperationalMatchDetailsRecords(records, {
        updated_at: snapshot.updated_at || new Date().toISOString(),
        source: "redis_migration",
      })
    );
    result.written = result.read;
  } catch (error) {
    result.failed = result.read;
    console.warn("[Migration] matches failed:", error.message || error);
  }
  return result;
}

async function migrateOperationalDatasets(dryRun) {
  const result = emptyResult("operational_datasets");
  const records = await getOperationalDatasets(OPERATIONAL_DATASETS);
  const values = records && typeof records === "object" ? Object.values(records) : [];
  result.read = values.length;
  for (const record of values) {
    try {
      if (!record || !record.name) {
        result.skipped += 1;
        continue;
      }
      await maybeWrite(dryRun, () => mongoStore.saveOperationalDataset(record));
      result.written += 1;
    } catch (error) {
      result.failed += 1;
      console.warn(`[Migration] operational dataset failed for ${record && record.name}:`, error.message || error);
    }
  }
  return result;
}

async function migrateFantasyReminders(dryRun) {
  const result = emptyResult("fantasy_reminders");
  const records = await getFantasyReminderRecords({ order: "desc" });
  result.read = Array.isArray(records) ? records.length : 0;
  for (const record of records || []) {
    try {
      if (!record || !record.reminder_id) {
        result.skipped += 1;
        continue;
      }
      await maybeWrite(dryRun, () => mongoStore.saveFantasyReminderRecord(record));
      result.written += 1;
    } catch (error) {
      result.failed += 1;
      console.warn(`[Migration] fantasy reminder failed for ${record && record.reminder_id}:`, error.message || error);
    }
  }
  return result;
}

async function migrateBbcHistory(dryRun, historyDays) {
  const result = emptyResult("bbc_history");
  const endMs = Date.now();
  const startMs = endMs - historyDays * 24 * 60 * 60 * 1000;
  const grouped = await getBbcMatchHistoryGrouped({ start_ms: startMs, end_ms: endMs });
  const matches = Array.isArray(grouped && grouped.matches) ? grouped.matches : [];
  const eventRecords = [];
  const notificationRecords = [];
  matches.forEach((match) => {
    (Array.isArray(match.events) ? match.events : []).forEach((record) => eventRecords.push(record));
    (Array.isArray(match.notifications) ? match.notifications : []).forEach((record) => notificationRecords.push(record));
  });
  result.read = eventRecords.length + notificationRecords.length;
  for (const record of eventRecords) {
    try {
      await maybeWrite(dryRun, () => mongoStore.saveBbcMatchEventHistory(record));
      result.written += 1;
    } catch (error) {
      result.failed += 1;
      console.warn("[Migration] BBC event failed:", error.message || error);
    }
  }
  for (const record of notificationRecords) {
    try {
      await maybeWrite(dryRun, () => mongoStore.saveBbcNotificationHistory(record));
      result.written += 1;
    } catch (error) {
      result.failed += 1;
      console.warn("[Migration] BBC notification failed:", error.message || error);
    }
  }
  return result;
}

async function migrateBbcRequests(dryRun, historyDays) {
  const result = emptyResult("bbc_requests");
  const endMs = Date.now();
  const startMs = endMs - historyDays * 24 * 60 * 60 * 1000;
  const history = await getBbcRequestHistory({ start_ms: startMs, end_ms: endMs, limit: 0 });
  const records = Array.isArray(history && history.requests) ? history.requests : [];
  result.read = records.length;
  for (const record of records) {
    try {
      await maybeWrite(dryRun, () => mongoStore.saveBbcRequestHistory(record));
      result.written += 1;
    } catch (error) {
      result.failed += 1;
      console.warn("[Migration] BBC request failed:", error.message || error);
    }
  }
  return result;
}

async function main() {
  const args = parseArgs(process.argv);
  if (!mongoStore.isMongoConfigured()) {
    throw new Error("MONGODB_URI_TOP_SCORES must be set before running the migration.");
  }

  const selected = new Set(args.collections);
  const results = [];
  if (selected.has("user_devices")) results.push(await migrateUserDevices(args.dryRun));
  if (selected.has("matches")) results.push(await migrateMatches(args.dryRun));
  if (selected.has("operational_datasets")) results.push(await migrateOperationalDatasets(args.dryRun));
  if (selected.has("fantasy_reminders")) results.push(await migrateFantasyReminders(args.dryRun));
  if (selected.has("bbc_history")) results.push(await migrateBbcHistory(args.dryRun, args.historyDays));
  if (selected.has("bbc_requests")) results.push(await migrateBbcRequests(args.dryRun, args.historyDays));

  console.log(JSON.stringify({
    dry_run: args.dryRun,
    collections: args.collections,
    history_days: args.historyDays,
    results,
  }, null, 2));
}

main()
  .catch((error) => {
    console.error("[Migration] Failed:", error.message || error);
    process.exitCode = 1;
  })
  .finally(async () => {
    await Promise.all([
      closeRedisConnection().catch(() => {}),
      mongoStore.closeMongoConnection().catch(() => {}),
    ]);
  });
