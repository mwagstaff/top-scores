#!/usr/bin/env node
// Dry-run by default. Updates only server-owned bindings; never sends pushes.
const fs = require("node:fs");
const crypto = require("node:crypto");
const { createClient } = require("redis");
const { MongoClient } = require("mongodb");
const { buildNotificationTeamRegistry, migrateNotificationTeamSubscriptions } = require("../notification_team_subscriptions");
const FIELD = "notificationTeamSubscriptions";
const UPDATED = "notificationTeamSubscriptionsUpdatedAt";
const PREFIX = "top_scores:user_preferences:";
const CAS = `
if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
redis.call('SET', KEYS[1], ARGV[2], 'KEEPTTL')
return 1`;

async function migrateRecord({ source, key, read, write, registry, apply, backup, now }) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const record = await read();
    if (!record) return { source, device: key.slice(0, 8), status: "missing" };
    const next = migrateNotificationTeamSubscriptions(record, registry);
    const report = {
      source, device: String(record.deviceToken || key).slice(0, 8),
      resolved: Object.keys(next.bindings).length, unresolved: next.unresolved,
    };
    if (JSON.stringify(next) === JSON.stringify(record[FIELD])) return { ...report, status: "unchanged" };
    if (!apply) return { ...report, status: "would_update" };
    await backup({ source, key, previous: record[FIELD] ?? null, previousUpdatedAt: record[UPDATED] ?? null,
      preferencesHash: crypto.createHash("sha256").update(JSON.stringify(record.preferences || {})).digest("hex") });
    if (await write(record, next, now)) return { ...report, status: "updated" };
  }
  throw new Error(`Concurrent preference updates prevented migration for ${source}:${key.slice(0, 8)}`);
}

async function loadCatalog(baseURL) {
  const teams = [];
  for (let offset = 0; ; offset += 200) {
    const response = await fetch(`${baseURL}/teams/catalog?limit=200&offset=${offset}`, { signal: AbortSignal.timeout(15000) });
    if (!response.ok) throw new Error(`Catalogue HTTP ${response.status}`);
    const page = await response.json();
    if (!Array.isArray(page.teams)) throw new Error("Invalid catalogue response");
    teams.push(...page.teams);
    if (!page.has_more) break;
    if (!page.teams.length) throw new Error("Empty catalogue page with has_more");
  }
  if (!teams.length) throw new Error("Refusing migration with an empty team catalogue");
  return teams;
}

async function main(argv = process.argv.slice(2)) {
  const apply = argv.includes("--apply");
  const option = (name, fallback) => argv.find((arg) => arg.startsWith(`${name}=`))?.slice(name.length + 1) || fallback;
  const uri = process.env.MONGODB_URI_TOP_SCORES;
  if (!uri) throw new Error("MONGODB_URI_TOP_SCORES is required to migrate both stores");
  const teams = await loadCatalog(option("--api-url", "http://127.0.0.1:3011/api/v1"));
  const registry = buildNotificationTeamRegistry(teams);
  const redis = createClient({ socket: { host: process.env.REDIS_HOST || "127.0.0.1", port: Number(process.env.REDIS_PORT || 6379), reconnectStrategy: false }, database: Number(process.env.REDIS_DB || 0), password: process.env.REDIS_PASSWORD || undefined });
  redis.on("error", () => {});
  const mongo = new MongoClient(uri, { maxPoolSize: 2, serverSelectionTimeoutMS: 10000 });
  let backupFD;
  const now = new Date().toISOString();
  const reports = [];
  try {
    await redis.connect();
    await mongo.connect();
    if (apply) {
      const backupPath = option("--backup", `/tmp/top-scores-team-subscriptions-${Date.now()}.jsonl`);
      backupFD = fs.openSync(backupPath, "wx", 0o600);
      console.log(JSON.stringify({ backup: backupPath }));
    }
    const backup = async (record) => { fs.writeSync(backupFD, JSON.stringify(record) + "\n"); fs.fsyncSync(backupFD); };
    // Do not call the app's getDb(): its index setup mutates unrelated collections.
    const databaseName = new URL(uri).pathname.replace(/^\//, "") || "top_scores";
    const collection = mongo.db(databaseName).collection("user_devices");
    const projection = { deviceToken: 1, preferences: 1, [FIELD]: 1, [UPDATED]: 1 };
    for await (const record of collection.find({}, { projection })) {
      reports.push(await migrateRecord({ source: "mongo", key: String(record._id), registry, apply, backup, now,
        read: () => collection.findOne({ _id: record._id }, { projection }),
        write: async (old, next, updatedAt) => {
          const result = await collection.updateOne({ _id: record._id, preferences: old.preferences ?? { $exists: false },
            [FIELD]: old[FIELD] ?? { $exists: false } }, { $set: { [FIELD]: next, [UPDATED]: updatedAt } });
          return result.matchedCount === 1;
        },
      }));
    }
    for await (const keys of redis.scanIterator({ MATCH: `${PREFIX}*`, COUNT: 200 })) {
      for (const key of keys) {
        if (key === `${PREFIX}index` || key === `${PREFIX}index:ready`) continue;
        reports.push(await migrateRecord({ source: "redis", key: key.slice(PREFIX.length), registry, apply, backup, now,
          read: async () => { const raw = await redis.get(key); if (!raw) return null; const value = JSON.parse(raw); Object.defineProperty(value, "_migrationRaw", { value: raw }); return value; },
          write: async (old, next, updatedAt) => Number(await redis.eval(CAS, { keys: [key], arguments: [old._migrationRaw, JSON.stringify({ ...old, [FIELD]: next, [UPDATED]: updatedAt })] })) === 1,
        }));
      }
    }
    console.log(JSON.stringify({ apply, catalogue_teams: teams.length, results: reports }, null, 2));
  } finally {
    if (backupFD !== undefined) fs.closeSync(backupFD);
    await Promise.allSettled([redis.isOpen ? redis.quit() : Promise.resolve(), mongo.close()]);
  }
}
if (require.main === module) main().catch((error) => { console.error(error.message); process.exitCode = 1; });
module.exports = { migrateRecord, CAS };
