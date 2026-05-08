let MongoClient = null;
let mongodbLoadError = null;

try {
  ({ MongoClient } = require("mongodb"));
} catch (error) {
  mongodbLoadError = error;
}

const MONGODB_URI_TOP_SCORES = process.env.MONGODB_URI_TOP_SCORES || "";
const DEFAULT_DB_NAME = "top_scores";

let client = null;
let db = null;
let connecting = null;
let indexesEnsured = false;
let unavailableLogged = false;

function isMongoConfigured() {
  return Boolean(String(MONGODB_URI_TOP_SCORES || "").trim());
}

function collection(name) {
  if (!db) {
    throw new Error("MongoDB is not connected");
  }
  return db.collection(name);
}

function dbNameFromUri(uri) {
  try {
    const parsed = new URL(uri);
    const pathname = String(parsed.pathname || "").replace(/^\/+/, "").trim();
    return pathname || DEFAULT_DB_NAME;
  } catch (_error) {
    return DEFAULT_DB_NAME;
  }
}

async function ensureIndexes() {
  if (indexesEnsured || !db) return;

  await Promise.all([
    collection("user_devices").createIndexes([
      { key: { updatedAt: -1 }, name: "updatedAt_desc" },
      { key: { apnsToken: 1 }, name: "apnsToken" },
    ]),
    collection("operational_datasets").createIndex({ updated_at: -1 }, { name: "updatedAt_desc" }),
    collection("matches").createIndexes([
      { key: { date: 1 }, name: "date" },
      { key: { league: 1, date: 1 }, name: "league_date" },
      { key: { score_status: 1 }, name: "score_status" },
      { key: { updated_at: -1 }, name: "updatedAt_desc" },
    ]),
    collection("match_write_logs").createIndexes([
      { key: { match_id: 1, timestamp_ms: -1 }, name: "match_timestamp" },
      { key: { inserted_at_ms: -1 }, name: "insertedAt_desc" },
    ]),
    collection("fantasy_reminders").createIndexes([
      { key: { scheduled_for_ms: 1 }, name: "scheduledFor" },
      { key: { device_token: 1, scheduled_for_ms: -1 }, name: "device_scheduledFor" },
      { key: { status: 1 }, name: "status" },
    ]),
    collection("bbc_events").createIndexes([
      { key: { timestamp_ms: -1 }, name: "timestamp_desc" },
      { key: { match_id: 1, timestamp_ms: -1 }, name: "match_timestamp" },
    ]),
    collection("notification_history").createIndexes([
      { key: { timestamp_ms: -1 }, name: "timestamp_desc" },
      { key: { match_id: 1, timestamp_ms: -1 }, name: "match_timestamp" },
      { key: { device_token: 1, timestamp_ms: -1 }, name: "device_timestamp" },
    ]),
    collection("bbc_requests").createIndexes([
      { key: { timestamp_ms: -1 }, name: "timestamp_desc" },
      { key: { source: 1, timestamp_ms: -1 }, name: "source_timestamp" },
      { key: { status_code: 1, timestamp_ms: -1 }, name: "status_timestamp" },
    ]),
  ]);

  indexesEnsured = true;
}

async function getDb() {
  if (!isMongoConfigured()) {
    return null;
  }
  if (!MongoClient) {
    if (!unavailableLogged) {
      unavailableLogged = true;
      console.warn(
        "[Mongo] mongodb package is not installed; falling back to Redis:",
        mongodbLoadError && mongodbLoadError.message ? mongodbLoadError.message : "missing mongodb dependency"
      );
    }
    return null;
  }
  if (db) {
    return db;
  }
  if (!connecting) {
    connecting = (async () => {
      client = new MongoClient(MONGODB_URI_TOP_SCORES, {
        maxPoolSize: 20,
        serverSelectionTimeoutMS: 5000,
      });
      await client.connect();
      db = client.db(dbNameFromUri(MONGODB_URI_TOP_SCORES));
      await ensureIndexes();
      console.log(`[Mongo] Connected to ${db.databaseName}`);
      return db;
    })().catch((error) => {
      client = null;
      db = null;
      connecting = null;
      if (!unavailableLogged) {
        unavailableLogged = true;
        console.warn("[Mongo] Unavailable, falling back to Redis:", error.message || error);
      }
      return null;
    });
  }
  return connecting;
}

async function closeMongoConnection() {
  if (client) {
    await client.close();
  }
  client = null;
  db = null;
  connecting = null;
  indexesEnsured = false;
}

function stripMongoId(record) {
  if (!record || typeof record !== "object") return record;
  const { _id, ...rest } = record;
  return rest;
}

function normalizeRecordId(value) {
  return String(value || "").trim();
}

function buildMatchDocument(matchId, payload, metadata = {}) {
  const normalizedId = normalizeRecordId((payload && payload.id) || matchId).toLowerCase();
  return {
    _id: normalizedId,
    payload: {
      ...(payload && typeof payload === "object" ? payload : {}),
      id: normalizedId,
    },
    match_id: normalizedId,
    date: payload && payload.date ? String(payload.date) : null,
    time: payload && payload.time ? String(payload.time) : null,
    league: payload && payload.league ? String(payload.league) : null,
    home_team: payload && payload.home_team ? String(payload.home_team) : null,
    away_team: payload && payload.away_team ? String(payload.away_team) : null,
    score_status: payload && payload.score_status ? String(payload.score_status) : null,
    updated_at: metadata.updated_at || (payload && payload.updated_at) || new Date().toISOString(),
    source: metadata.source || null,
  };
}

async function upsertUserPreferences(record) {
  const mongoDb = await getDb();
  if (!mongoDb || !record || !record.deviceToken) return null;
  const nowIso = new Date().toISOString();
  const doc = {
    ...record,
    _id: String(record.deviceToken).trim(),
    updatedAt: record.updatedAt || nowIso,
  };
  const insertFields = {};
  if (!Object.prototype.hasOwnProperty.call(doc, "createdAt")) {
    insertFields.createdAt = nowIso;
  }
  await collection("user_devices").updateOne(
    { _id: doc._id },
    {
      $set: doc,
      ...(Object.keys(insertFields).length > 0 ? { $setOnInsert: insertFields } : {}),
    },
    { upsert: true }
  );
  return stripMongoId(doc);
}

async function getUserPreferences(deviceToken) {
  const mongoDb = await getDb();
  const normalized = normalizeRecordId(deviceToken);
  if (!mongoDb || !normalized) return null;
  const record = await collection("user_devices").findOne({ _id: normalized });
  return record ? stripMongoId(record) : null;
}

async function getAllUserPreferences() {
  const mongoDb = await getDb();
  if (!mongoDb) return null;
  const records = await collection("user_devices").find({}).sort({ updatedAt: -1 }).toArray();
  return records.map(stripMongoId);
}

async function deleteUserPreferences(deviceToken) {
  const mongoDb = await getDb();
  const normalized = normalizeRecordId(deviceToken);
  if (!mongoDb || !normalized) return null;
  const result = await collection("user_devices").deleteOne({ _id: normalized });
  return result.deletedCount > 0;
}

async function saveOperationalDataset(record) {
  const mongoDb = await getDb();
  if (!mongoDb || !record || !record.name) return null;
  const doc = {
    ...record,
    _id: String(record.name).trim(),
    updated_at: record.updated_at || new Date().toISOString(),
  };
  await collection("operational_datasets").updateOne(
    { _id: doc._id },
    { $set: doc, $setOnInsert: { created_at: new Date().toISOString() } },
    { upsert: true }
  );
  return stripMongoId(doc);
}

async function getOperationalDataset(name) {
  const mongoDb = await getDb();
  const normalized = normalizeRecordId(name);
  if (!mongoDb || !normalized) return null;
  const record = await collection("operational_datasets").findOne({ _id: normalized });
  return record ? stripMongoId(record) : null;
}

async function getOperationalDatasets(names = []) {
  const mongoDb = await getDb();
  const normalizedNames = Array.isArray(names)
    ? names.map((name) => normalizeRecordId(name)).filter(Boolean)
    : [];
  if (!mongoDb || normalizedNames.length === 0) return null;
  const records = await collection("operational_datasets")
    .find({ _id: { $in: normalizedNames } })
    .toArray();
  const output = {};
  records.forEach((record) => {
    const stripped = stripMongoId(record);
    if (stripped && stripped.name) {
      output[stripped.name] = stripped;
    }
  });
  return output;
}

async function saveOperationalMatchDetailsRecords(recordsById, options = {}) {
  const mongoDb = await getDb();
  if (!mongoDb) return null;
  const entries = recordsById instanceof Map
    ? Array.from(recordsById.entries())
    : recordsById && typeof recordsById === "object"
      ? Object.entries(recordsById)
      : [];
  const records = entries
    .map(([matchId, payload]) => buildMatchDocument(matchId, payload, options))
    .filter((record) => record._id && record.payload);

  if (options.replace) {
    const incomingIds = records.map((record) => record._id);
    await collection("matches").deleteMany({ _id: { $nin: incomingIds } });
  }

  if (records.length > 0) {
    await collection("matches").bulkWrite(
      records.map((record) => ({
        updateOne: {
          filter: { _id: record._id },
          update: {
            $set: record,
            $setOnInsert: { first_seen_at: record.updated_at },
          },
          upsert: true,
        },
      })),
      { ordered: false }
    );
  }

  const total = await collection("matches").countDocuments();
  await saveOperationalDataset({
    name: "match_details_meta",
    updated_at: options.updated_at || new Date().toISOString(),
    source: options.source || null,
    payload: { total },
  });
  return {
    updated_at: options.updated_at || new Date().toISOString(),
    upserted: records.length,
    removed: 0,
    total,
    replace: Boolean(options.replace),
  };
}

async function getOperationalMatchDetails(matchId) {
  const mongoDb = await getDb();
  const normalized = normalizeRecordId(matchId).toLowerCase();
  if (!mongoDb || !normalized) return null;
  const record = await collection("matches").findOne({ _id: normalized });
  return record && record.payload ? record.payload : null;
}

async function getAllOperationalMatchDetails() {
  const mongoDb = await getDb();
  if (!mongoDb) return null;
  const records = await collection("matches").find({}).toArray();
  const output = {};
  let latestUpdatedAt = null;
  records.forEach((record) => {
    if (!record || !record.payload) return;
    const id = normalizeRecordId(record.payload.id || record._id).toLowerCase();
    if (!id) return;
    output[id] = record.payload;
    if (record.updated_at && (!latestUpdatedAt || record.updated_at > latestUpdatedAt)) {
      latestUpdatedAt = record.updated_at;
    }
  });
  return {
    updated_at: latestUpdatedAt,
    total: Object.keys(output).length,
    records: output,
  };
}

async function getOperationalMatchDetailsSummary() {
  const mongoDb = await getDb();
  if (!mongoDb) return null;
  const [total, latest] = await Promise.all([
    collection("matches").countDocuments(),
    collection("matches").find({}).sort({ updated_at: -1 }).limit(1).toArray(),
  ]);
  return {
    total,
    updated_at: latest[0] && latest[0].updated_at ? latest[0].updated_at : null,
    source: latest[0] && latest[0].source ? latest[0].source : null,
  };
}

async function deleteOperationalMatchDetailsRecords(matchIds) {
  const mongoDb = await getDb();
  const ids = Array.isArray(matchIds)
    ? matchIds.map((matchId) => normalizeRecordId(matchId).toLowerCase()).filter(Boolean)
    : [];
  if (!mongoDb || ids.length === 0) return null;
  const existing = await collection("matches").find({ _id: { $in: ids } }, { projection: { _id: 1 } }).toArray();
  const existingIds = existing.map((record) => record._id);
  const result = await collection("matches").deleteMany({ _id: { $in: ids } });
  return {
    requested: ids.length,
    deleted: result.deletedCount || 0,
    deleted_ids: existingIds,
    missing_ids: ids.filter((id) => !existingIds.includes(id)),
    total: await collection("matches").countDocuments(),
    updated_at: new Date().toISOString(),
  };
}

async function saveOperationalMatchWriteLogEntries(entriesByMatchId) {
  const mongoDb = await getDb();
  if (!mongoDb) return null;
  const nowMs = Date.now();
  const docs = [];
  Object.entries(entriesByMatchId && typeof entriesByMatchId === "object" ? entriesByMatchId : {}).forEach(
    ([matchId, entries]) => {
      (Array.isArray(entries) ? entries : []).forEach((entry) => {
        docs.push({
          ...entry,
          match_id: normalizeRecordId(entry.match_id || matchId).toLowerCase(),
          timestamp_ms: Number.isFinite(Number(entry.timestamp_ms)) ? Number(entry.timestamp_ms) : nowMs,
          inserted_at_ms: nowMs,
        });
      });
    }
  );
  if (docs.length === 0) return { written: 0, matches: 0 };
  await collection("match_write_logs").insertMany(docs, { ordered: false });
  return { written: docs.length, matches: new Set(docs.map((doc) => doc.match_id)).size };
}

async function getOperationalMatchWriteLog(matchId, options = {}) {
  const mongoDb = await getDb();
  const normalized = normalizeRecordId(matchId).toLowerCase();
  if (!mongoDb || !normalized) return null;
  const pageSize = Math.min(500, Math.max(1, Math.floor(Number(options.page_size) || 200)));
  const page = Math.max(1, Math.floor(Number(options.page) || 1));
  const skip = (page - 1) * pageSize;
  const filter = { match_id: normalized };
  const [total, entries] = await Promise.all([
    collection("match_write_logs").countDocuments(filter),
    collection("match_write_logs").find(filter).sort({ timestamp_ms: -1 }).skip(skip).limit(pageSize).toArray(),
  ]);
  return {
    match_id: normalized,
    total,
    page,
    page_size: pageSize,
    entries: entries.map(stripMongoId),
  };
}

async function saveFantasyReminderRecord(record) {
  const mongoDb = await getDb();
  if (!mongoDb || !record || !record.reminder_id) return null;
  const doc = { ...record, _id: String(record.reminder_id).trim() };
  const insertFields = {};
  if (!Object.prototype.hasOwnProperty.call(doc, "created_at")) {
    insertFields.created_at = new Date().toISOString();
  }
  await collection("fantasy_reminders").updateOne(
    { _id: doc._id },
    {
      $set: doc,
      ...(Object.keys(insertFields).length > 0 ? { $setOnInsert: insertFields } : {}),
    },
    { upsert: true }
  );
  return stripMongoId(doc);
}

async function getFantasyReminderRecord(reminderId) {
  const mongoDb = await getDb();
  const normalized = normalizeRecordId(reminderId);
  if (!mongoDb || !normalized) return null;
  const record = await collection("fantasy_reminders").findOne({ _id: normalized });
  return record ? stripMongoId(record) : null;
}

async function getFantasyReminderRecords(options = {}) {
  const mongoDb = await getDb();
  if (!mongoDb) return null;
  const filter = {};
  if (options.status) filter.status = String(options.status).trim().toLowerCase();
  if (options.reminder_id) filter._id = String(options.reminder_id).trim();
  if (options.gameweek_id !== undefined && options.gameweek_id !== null) {
    const normalizedGameweekId = String(options.gameweek_id).trim();
    const numericGameweekId = Number(normalizedGameweekId);
    filter.gameweek_id = Number.isFinite(numericGameweekId)
      ? { $in: [normalizedGameweekId, numericGameweekId] }
      : normalizedGameweekId;
  }
  if (options.device_token) filter.device_token = String(options.device_token).trim();
  const order = String(options.order || "desc").toLowerCase() === "asc" ? 1 : -1;
  const limit = Math.max(0, Math.floor(Number(options.limit) || 0));
  let cursor = collection("fantasy_reminders").find(filter).sort({ scheduled_for_ms: order, _id: 1 });
  if (limit > 0) cursor = cursor.limit(limit);
  const records = await cursor.toArray();
  return records.map(stripMongoId);
}

async function saveBbcMatchEventHistory(record) {
  const mongoDb = await getDb();
  if (!mongoDb || !record) return null;
  const id = `${record.match_id || "unknown"}:${record.event_id || record.timestamp_ms || Date.now()}`;
  const doc = { ...record, _id: id };
  await collection("bbc_events").updateOne({ _id: id }, { $set: doc }, { upsert: true });
  return stripMongoId(doc);
}

async function saveBbcNotificationHistory(record) {
  const mongoDb = await getDb();
  if (!mongoDb || !record) return null;
  const id = `${record.match_id || "unknown"}:${record.notification_id || record.timestamp_ms || Date.now()}`;
  const doc = { ...record, _id: id };
  await collection("notification_history").updateOne({ _id: id }, { $set: doc }, { upsert: true });
  return stripMongoId(doc);
}

async function saveBbcRequestHistory(record) {
  const mongoDb = await getDb();
  if (!mongoDb || !record) return null;
  const id = `${record.timestamp_ms || Date.now()}:${record.request_id || Math.random().toString(16).slice(2)}`;
  const doc = { ...record, _id: id };
  await collection("bbc_requests").updateOne({ _id: id }, { $set: doc }, { upsert: true });
  return stripMongoId(doc);
}

module.exports = {
  isMongoConfigured,
  getDb,
  closeMongoConnection,
  upsertUserPreferences,
  getUserPreferences,
  getAllUserPreferences,
  deleteUserPreferences,
  saveOperationalDataset,
  getOperationalDataset,
  getOperationalDatasets,
  saveOperationalMatchDetailsRecords,
  getOperationalMatchDetails,
  getAllOperationalMatchDetails,
  getOperationalMatchDetailsSummary,
  deleteOperationalMatchDetailsRecords,
  saveOperationalMatchWriteLogEntries,
  getOperationalMatchWriteLog,
  saveFantasyReminderRecord,
  getFantasyReminderRecord,
  getFantasyReminderRecords,
  saveBbcMatchEventHistory,
  saveBbcNotificationHistory,
  saveBbcRequestHistory,
};
