let MongoClient = null;
let mongodbLoadError = null;

try {
  ({ MongoClient } = require("mongodb"));
} catch (error) {
  mongodbLoadError = error;
}

const MONGODB_URI_TOP_SCORES = process.env.MONGODB_URI_TOP_SCORES || "";
const DEFAULT_DB_NAME = "top_scores";
const MATCH_WRITE_LOGS_TTL_SECONDS = 6 * 24 * 60 * 60;
const BBC_REQUESTS_TTL_SECONDS = 7 * 24 * 60 * 60;

let client = null;
let db = null;
let connecting = null;
let indexesEnsured = false;
let unavailableLogged = false;

function runtimeRoleFromEntrypoint() {
  const entrypoint = String(process.argv[1] || "").split(/[\\/]/).pop();
  if (entrypoint === "server.js") return "api";
  if (entrypoint === "scraper.js") return "scraper";
  if (entrypoint === "match_monitor.js") return "monitor";
  if (entrypoint === "bsd_poller.js") return "bsd";
  return "worker";
}

function configuredMongoPoolSize() {
  const explicit = Number(process.env.MONGODB_MAX_POOL_SIZE);
  if (Number.isFinite(explicit) && explicit > 0) return Math.floor(explicit);
  const role = String(process.env.TOP_SCORES_RUNTIME_ROLE || runtimeRoleFromEntrypoint())
    .trim()
    .toLowerCase();
  return { api: 10, scraper: 5, monitor: 5, bsd: 5 }[role] || 5;
}

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
    // The legacy ttl_expiry index was on numeric inserted_at_ms, which Mongo's
    // TTL monitor silently ignores (it only expires BSON Date fields) — drop it
    // and index the Date-typed inserted_at instead.
    collection("match_write_logs")
      .dropIndex("ttl_expiry")
      .catch(() => {})
      .then(() =>
        collection("match_write_logs").createIndexes([
          { key: { match_id: 1, timestamp_ms: -1 }, name: "match_timestamp" },
          { key: { inserted_at_ms: -1 }, name: "insertedAt_desc" },
          { key: { inserted_at: 1 }, name: "inserted_at_ttl", expireAfterSeconds: MATCH_WRITE_LOGS_TTL_SECONDS },
        ])
      ),
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
      { key: { inserted_at: 1 }, name: "inserted_at_ttl", expireAfterSeconds: BBC_REQUESTS_TTL_SECONDS },
    ]),
    collection("tsdb_tv_listings").createIndexes([
      { key: { date_event: 1 }, name: "date_event" },
      { key: { updated_at: -1 }, name: "updatedAt_desc" },
    ]),
    collection("tsdb_leagues").createIndex({ updated_at: -1 }, { name: "updatedAt_desc" }),
    collection("tsdb_league_tables").createIndexes([
      { key: { updated_at: -1 }, name: "updatedAt_desc" },
      { key: { league_name: 1 }, name: "league_name" },
    ]),
    collection("tsdb_match_lineups").createIndexes([
      { key: { updated_at_ms: -1 }, name: "updatedAtMs_desc" },
      { key: { next_refresh_at_ms: 1 }, name: "nextRefreshAtMs" },
      { key: { final: 1 }, name: "final" },
    ]),
    collection("tsdb_match_timelines").createIndexes([
      { key: { updated_at_ms: -1 }, name: "timelineUpdatedAtMs_desc" },
      { key: { next_refresh_at_ms: 1 }, name: "timelineNextRefreshAtMs" },
      { key: { final: 1 }, name: "timelineFinal" },
    ]),
    collection("tsdb_teams").createIndexes([
      { key: { updated_at_ms: -1 }, name: "teamUpdatedAtMs_desc" },
    ]),
    collection("tsdb_players").createIndexes([
      { key: { updated_at_ms: -1 }, name: "playerUpdatedAtMs_desc" },
    ]),
    // BSD evaluation collections (all carry an `updated_at` ISO timestamp).
    collection("bsd_leagues").createIndex({ updated_at: -1 }, { name: "updatedAt_desc" }),
    collection("bsd_standings").createIndex({ updated_at: -1 }, { name: "updatedAt_desc" }),
    collection("bsd_teams").createIndex({ updated_at: -1 }, { name: "updatedAt_desc" }),
    collection("bsd_venues").createIndex({ updated_at: -1 }, { name: "updatedAt_desc" }),
    collection("bsd_events").createIndexes([
      { key: { updated_at: -1 }, name: "updatedAt_desc" },
      { key: { league_id: 1, status: 1 }, name: "league_status" },
      {
        key: { league_id: 1, status: 1, event_date: 1 },
        name: "league_status_event_date",
      },
      {
        key: { league_id: 1, status: 1, "payload.season_id": 1 },
        name: "league_status_season",
      },
      { key: { event_date: 1 }, name: "event_date" },
    ]),
    collection("bsd_incidents").createIndex({ updated_at: -1 }, { name: "updatedAt_desc" }),
    collection("bsd_broadcasts").createIndex({ updated_at: -1 }, { name: "updatedAt_desc" }),
    collection("bsd_lineups").createIndex({ updated_at: -1 }, { name: "updatedAt_desc" }),
    collection("bsd_players").createIndex({ updated_at: -1 }, { name: "updatedAt_desc" }),
    // BSD<->TSDB id maps (keyed by _id = BSD player/team id).
    collection("bsd_tsdb_player_map").createIndexes([
      { key: { updated_at: -1 }, name: "updatedAt_desc" },
      { key: { "payload.tsdb_player_id": 1 }, name: "tsdbPlayerId" },
    ]),
    collection("bsd_tsdb_team_map").createIndex({ updated_at: -1 }, { name: "updatedAt_desc" }),
    collection("gg_players").createIndexes([
      { key: { updated_at: -1 }, name: "updatedAt_desc" },
    ]),
    collection("gg_sessions").createIndexes([
      { key: { player_id: 1 }, name: "player" },
      { key: { updated_at: -1 }, name: "updatedAt_desc" },
    ]),
    collection("gg_identities").createIndexes([
      { key: { provider: 1, subject: 1 }, name: "provider_subject_unique", unique: true },
      { key: { email_normalized: 1, email_verified: 1 }, name: "verified_email" },
      { key: { player_id: 1 }, name: "player" },
    ]),
    collection("gg_login_challenges").createIndexes([
      { key: { expires_at: 1 }, name: "expires_at_ttl", expireAfterSeconds: 0 },
      { key: { email_normalized: 1, created_at: -1 }, name: "email_created" },
    ]),
    collection("gg_auth_assertions").createIndex({ expires_at: 1 }, { name: "expires_at_ttl", expireAfterSeconds: 0 }),
    collection("gg_leagues").createIndexes([
      { key: { join_code: 1 }, name: "joinCode_unique", unique: true },
      { key: { owner_player_id: 1, archived: 1 }, name: "owner_archived" },
      { key: { simulation_id: 1 }, name: "simulation", sparse: true },
    ]),
    collection("gg_memberships").createIndexes([
      { key: { league_id: 1, player_id: 1 }, name: "league_player_unique", unique: true },
      { key: { player_id: 1, joined_at: -1 }, name: "player_joined" },
    ]),
    collection("gg_contests").createIndexes([
      { key: { competition_key: 1, season_key: 1, game_type: 1 }, name: "contest_identity", unique: true },
    ]),
    collection("gg_fixtures").createIndexes([
      { key: { source_key: 1 }, name: "sourceKey_unique", unique: true },
      { key: { contest_id: 1, kickoff_at: 1 }, name: "contest_kickoff" },
      { key: { contest_id: 1, pick_week_id: 1 }, name: "contest_pickWeek" },
      { key: { status: 1, result_revision: 1 }, name: "status_revision" },
      { key: { simulation_id: 1, pick_week_id: 1 }, name: "simulation_pickWeek", sparse: true },
    ]),
    collection("gg_picks")
      .dropIndex("player_week_power_unique")
      .catch(() => {})
      .then(() => collection("gg_picks").createIndexes([
        { key: { player_id: 1, fixture_id: 1 }, name: "player_fixture_unique", unique: true },
        { key: { player_id: 1, contest_id: 1, pick_week_id: 1 }, name: "player_contest_week_power_unique", unique: true, partialFilterExpression: { power_pick: true } },
        { key: { fixture_id: 1 }, name: "fixture" },
      ])),
    collection("gg_simulation_runs").createIndexes([
      { key: { league_id: 1 }, name: "league_unique", unique: true },
      { key: { status: 1, updated_at: -1 }, name: "status_updated" },
    ]),
    collection("gg_wildcards").createIndexes([
      { key: { card_key: 1 }, name: "cardKey_unique", unique: true },
      { key: { league_id: 1, player_id: 1, status: 1 }, name: "league_player_status" },
    ]),
    collection("gg_admin_audit_events").createIndexes([
      { key: { simulation_id: 1, created_at: -1 }, name: "simulation_created" },
      { key: { actor_player_id: 1, created_at: -1 }, name: "actor_created" },
    ]),
    collection("gg_image_assets").createIndexes([
      { key: { target_player_id: 1, created_at: -1 }, name: "target_created" },
      { key: { league_id: 1, created_at: -1 }, name: "league_created", sparse: true },
      { key: { moderation_status: 1, created_at: 1 }, name: "moderation_created" },
      { key: { moderation_email_status: 1, created_at: 1 }, name: "moderation_email_created" },
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
        maxPoolSize: configuredMongoPoolSize(),
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

async function getOperationalDatasetMetadata(names = []) {
  const mongoDb = await getDb();
  const normalizedNames = Array.isArray(names)
    ? names.map((name) => normalizeRecordId(name)).filter(Boolean)
    : [];
  if (!mongoDb || normalizedNames.length === 0) return null;
  const records = await collection("operational_datasets")
    .find(
      { _id: { $in: normalizedNames } },
      { projection: { name: 1, updated_at: 1, source: 1, payload_hash: 1, payload_count: 1 } }
    )
    .toArray();
  const output = {};
  records.forEach((record) => {
    const stripped = stripMongoId(record);
    if (stripped && stripped.name) output[stripped.name] = stripped;
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

async function getOperationalMatchDetailsByDates(dates = []) {
  const mongoDb = await getDb();
  const normalizedDates = Array.isArray(dates)
    ? [...new Set(dates.map((date) => String(date || "").trim()).filter(Boolean))]
    : [];
  if (!mongoDb || normalizedDates.length === 0) return {};
  const records = await collection("matches")
    .find({ date: { $in: normalizedDates } }, { projection: { payload: 1 } })
    .toArray();
  const output = {};
  records.forEach((record) => {
    if (!record || !record.payload) return;
    const matchId = normalizeRecordId(record.payload.id || record._id).toLowerCase();
    if (matchId) output[matchId] = record.payload;
  });
  return output;
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
          // BSON Date required for the inserted_at_ttl TTL index to expire docs.
          inserted_at: new Date(nowMs),
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
  // BSON Date required for the inserted_at_ttl TTL index to expire docs.
  const doc = { ...record, _id: id, inserted_at: new Date() };
  await collection("bbc_requests").updateOne({ _id: id }, { $set: doc }, { upsert: true });
  return stripMongoId(doc);
}

// ---------------------------------------------------------------------------
// TV listings
//
// One document per idEvent: { _id: idEvent, date_event, channels[], updated_at }
// Upserted on every 2-hour TV listings refresh.
// ---------------------------------------------------------------------------

async function upsertTvListings(listings) {
  const mongoDb = await getDb();
  if (!mongoDb || !Array.isArray(listings) || listings.length === 0) return null;
  const nowIso = new Date().toISOString();
  const ops = listings.map(({ idEvent, dateEvent, channels }) => ({
    updateOne: {
      filter: { _id: String(idEvent) },
      update: {
        $set: {
          _id: String(idEvent),
          date_event: dateEvent || null,
          channels: Array.isArray(channels) ? channels : [],
          updated_at: nowIso,
        },
      },
      upsert: true,
    },
  }));
  const result = await collection("tsdb_tv_listings").bulkWrite(ops, { ordered: false });
  return { upserted: result.upsertedCount, modified: result.modifiedCount };
}

async function getAllTvListings() {
  const mongoDb = await getDb();
  if (!mongoDb) return {};
  const records = await collection("tsdb_tv_listings").find({}).toArray();
  const out = {};
  records.forEach((r) => {
    if (r._id && Array.isArray(r.channels)) {
      out[String(r._id)] = r.channels;
    }
  });
  return out;
}

// ---------------------------------------------------------------------------
// Leagues
//
// One document per idLeague: { _id: idLeague, name, sport, updated_at }
// Upserted nightly from the TheSportsDB /all/leagues endpoint.
// ---------------------------------------------------------------------------

async function upsertTsdbLeagueTables(tables) {
  const mongoDb = await getDb();
  if (!mongoDb || !Array.isArray(tables) || tables.length === 0) return null;
  const nowIso = new Date().toISOString();
  const ops = tables.map((table) => ({
    updateOne: {
      filter: { _id: String(table.league_id) },
      update: {
        $set: {
          _id: String(table.league_id),
          league_name: table.league_name || null,
          stage_name: table.stage_name || null,
          season: table.season || null,
          source_url: table.source_url || null,
          rows: Array.isArray(table.rows) ? table.rows : [],
          groups: Array.isArray(table.groups) ? table.groups : [],
          updated_at: nowIso,
        },
      },
      upsert: true,
    },
  }));
  const result = await collection("tsdb_league_tables").bulkWrite(ops, { ordered: false });
  return { upserted: result.upsertedCount, modified: result.modifiedCount, total: tables.length };
}

async function getAllTsdbLeagueTables() {
  const mongoDb = await getDb();
  if (!mongoDb) return [];
  const docs = await collection("tsdb_league_tables").find({}).toArray();
  return docs.map((doc) => ({
    league_id: String(doc._id),
    league_name: doc.league_name || null,
    stage_name: doc.stage_name || null,
    season: doc.season || null,
    source_url: doc.source_url || null,
    updated_at: doc.updated_at || null,
    groups: Array.isArray(doc.groups) ? doc.groups : [],
    rows: Array.isArray(doc.rows) ? doc.rows : [],
  }));
}

async function upsertLeagues(leagues) {
  const mongoDb = await getDb();
  if (!mongoDb || !Array.isArray(leagues) || leagues.length === 0) return null;
  const nowIso = new Date().toISOString();
  const ops = leagues.map(({ idLeague, strLeague, strSport }) => ({
    updateOne: {
      filter: { _id: String(idLeague) },
      update: {
        $set: {
          _id: String(idLeague),
          name: strLeague || null,
          sport: strSport || null,
          updated_at: nowIso,
        },
      },
      upsert: true,
    },
  }));
  const result = await collection("tsdb_leagues").bulkWrite(ops, { ordered: false });
  return { upserted: result.upsertedCount, modified: result.modifiedCount, total: leagues.length };
}

async function purgeStaleTvListings(cutoffDateStr) {
  const mongoDb = await getDb();
  if (!mongoDb || !cutoffDateStr) return null;
  const result = await collection("tsdb_tv_listings").deleteMany({
    date_event: { $lt: String(cutoffDateStr) },
  });
  return { deleted: result.deletedCount };
}

function buildTsdbCacheDocument(id, payload, metadata = {}) {
  const normalized = normalizeRecordId(id);
  if (!normalized) return null;
  const nowMs = Date.now();
  const updatedAtMs = Number.isFinite(Number(metadata.updated_at_ms))
    ? Number(metadata.updated_at_ms)
    : nowMs;
  return {
    _id: normalized,
    payload,
    updated_at: metadata.updated_at || new Date(updatedAtMs).toISOString(),
    updated_at_ms: updatedAtMs,
    next_refresh_at_ms: Number.isFinite(Number(metadata.next_refresh_at_ms))
      ? Number(metadata.next_refresh_at_ms)
      : null,
    final: metadata.final === true,
    source: metadata.source || null,
  };
}

async function upsertTsdbCacheRecord(collectionName, id, payload, metadata = {}) {
  const mongoDb = await getDb();
  const doc = buildTsdbCacheDocument(id, payload, metadata);
  if (!mongoDb || !doc) return null;
  await collection(collectionName).updateOne(
    { _id: doc._id },
    { $set: doc, $setOnInsert: { created_at: new Date().toISOString() } },
    { upsert: true }
  );
  return stripMongoId(doc);
}

async function getTsdbCacheRecord(collectionName, id) {
  const mongoDb = await getDb();
  const normalized = normalizeRecordId(id);
  if (!mongoDb || !normalized) return null;
  const record = await collection(collectionName).findOne({ _id: normalized });
  return record ? stripMongoId(record) : null;
}

async function getTsdbCacheRecords(collectionName, ids = []) {
  const mongoDb = await getDb();
  const normalizedIds = Array.isArray(ids)
    ? [...new Set(ids.map((id) => normalizeRecordId(id)).filter(Boolean))]
    : [];
  if (!mongoDb || normalizedIds.length === 0) return {};
  const records = await collection(collectionName)
    .find({ _id: { $in: normalizedIds } })
    .toArray();
  const output = {};
  records.forEach((record) => {
    const stripped = stripMongoId(record);
    output[String(record._id)] = stripped;
  });
  return output;
}

function timestampSecondsFromMs(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number / 1000 : 0;
}

async function summarizeTsdbCacheCollection(collectionName, nowMs = Date.now()) {
  const mongoDb = await getDb();
  if (!mongoDb) return null;
  const [summary] = await collection(collectionName)
    .aggregate([
      {
        $group: {
          _id: null,
          count: { $sum: 1 },
          final_count: {
            $sum: { $cond: [{ $eq: ["$final", true] }, 1, 0] },
          },
          non_final_count: {
            $sum: { $cond: [{ $ne: ["$final", true] }, 1, 0] },
          },
          due_count: {
            $sum: {
              $cond: [
                {
                  $and: [
                    { $ne: ["$final", true] },
                    { $ne: ["$next_refresh_at_ms", null] },
                    { $lte: ["$next_refresh_at_ms", nowMs] },
                  ],
                },
                1,
                0,
              ],
            },
          },
          latest_updated_at_ms: { $max: "$updated_at_ms" },
          oldest_updated_at_ms: { $min: "$updated_at_ms" },
          next_refresh_at_ms: {
            $min: {
              $cond: [
                {
                  $and: [
                    { $ne: ["$final", true] },
                    { $ne: ["$next_refresh_at_ms", null] },
                  ],
                },
                "$next_refresh_at_ms",
                null,
              ],
            },
          },
        },
      },
    ])
    .toArray();
  const nextRefreshRecord = await collection(collectionName)
    .find(
      { final: { $ne: true }, next_refresh_at_ms: { $ne: null } },
      { projection: { next_refresh_at_ms: 1 } }
    )
    .sort({ next_refresh_at_ms: 1 })
    .limit(1)
    .toArray();
  const nextRefreshAtMs =
    nextRefreshRecord[0] && Number.isFinite(Number(nextRefreshRecord[0].next_refresh_at_ms))
      ? Number(nextRefreshRecord[0].next_refresh_at_ms)
      : 0;
  return {
    count: Number(summary && summary.count) || 0,
    final_count: Number(summary && summary.final_count) || 0,
    non_final_count: Number(summary && summary.non_final_count) || 0,
    due_count: Number(summary && summary.due_count) || 0,
    latest_updated_at_seconds: timestampSecondsFromMs(summary && summary.latest_updated_at_ms),
    oldest_updated_at_seconds: timestampSecondsFromMs(summary && summary.oldest_updated_at_ms),
    next_refresh_at_seconds: timestampSecondsFromMs(nextRefreshAtMs),
  };
}

function extractIdsFromLineupPayload(payload, key) {
  if (!payload || typeof payload !== "object") return [];
  const lookup = Array.isArray(payload.lookup) ? payload.lookup : [];
  return lookup
    .map((entry) => String(entry && entry[key] ? entry[key] : "").trim())
    .filter((id) => /^\d+$/.test(id));
}

async function getExpectedTsdbCacheIdsFromMongo() {
  const mongoDb = await getDb();
  if (!mongoDb) {
    return {
      matchIds: [],
      playerIds: [],
      teamIds: [],
    };
  }

  const [matches, lineupRecords] = await Promise.all([
    collection("matches")
      .find(
        { _id: { $regex: /^\d+$/ } },
        { projection: { _id: 1, "payload.home_team_id": 1, "payload.away_team_id": 1 } }
      )
      .toArray(),
    collection("tsdb_match_lineups")
      .find({}, { projection: { payload: 1 } })
      .toArray(),
  ]);

  const matchIds = new Set();
  const playerIds = new Set();
  const teamIds = new Set();

  matches.forEach((record) => {
    const id = String(record && record._id ? record._id : "").trim();
    if (/^\d+$/.test(id)) matchIds.add(id);
    const payload = record && record.payload && typeof record.payload === "object"
      ? record.payload
      : {};
    [payload.home_team_id, payload.away_team_id].forEach((teamId) => {
      const normalizedTeamId = String(teamId || "").trim();
      if (/^\d+$/.test(normalizedTeamId)) teamIds.add(normalizedTeamId);
    });
  });

  lineupRecords.forEach((record) => {
    extractIdsFromLineupPayload(record && record.payload, "idPlayer").forEach((id) => playerIds.add(id));
  });

  return {
    matchIds: Array.from(matchIds),
    playerIds: Array.from(playerIds),
    teamIds: Array.from(teamIds),
  };
}

async function countMissingTsdbCacheRecords(collectionName, expectedIds = []) {
  const mongoDb = await getDb();
  const ids = Array.isArray(expectedIds)
    ? [...new Set(expectedIds.map((id) => normalizeRecordId(id)).filter(Boolean))]
    : [];
  if (!mongoDb || ids.length === 0) return 0;
  const cached = await collection(collectionName).distinct("_id", { _id: { $in: ids } });
  return Math.max(0, ids.length - cached.length);
}

async function getTsdbCacheObservabilitySnapshot() {
  const mongoDb = await getDb();
  const nowMs = Date.now();
  const emptyCollection = {
    count: 0,
    final_count: 0,
    non_final_count: 0,
    due_count: 0,
    latest_updated_at_seconds: 0,
    oldest_updated_at_seconds: 0,
    next_refresh_at_seconds: 0,
    expected_count: 0,
    missing_count: 0,
    completion_ratio: 1,
  };
  if (!mongoDb) {
    return {
      available: false,
      refreshed_at_seconds: Math.floor(nowMs / 1000),
      collections: {
        tsdb_players: { ...emptyCollection },
        tsdb_teams: { ...emptyCollection },
        tsdb_match_lineups: { ...emptyCollection },
        tsdb_match_timelines: { ...emptyCollection },
      },
    };
  }

  const [expected, players, teams, matchLineups, matchTimelines] = await Promise.all([
    getExpectedTsdbCacheIdsFromMongo(),
    summarizeTsdbCacheCollection("tsdb_players", nowMs),
    summarizeTsdbCacheCollection("tsdb_teams", nowMs),
    summarizeTsdbCacheCollection("tsdb_match_lineups", nowMs),
    summarizeTsdbCacheCollection("tsdb_match_timelines", nowMs),
  ]);

  const expectedByCollection = {
    tsdb_players: expected.playerIds,
    tsdb_teams: expected.teamIds,
    tsdb_match_lineups: expected.matchIds,
    tsdb_match_timelines: expected.matchIds,
  };
  const summaries = {
    tsdb_players: players,
    tsdb_teams: teams,
    tsdb_match_lineups: matchLineups,
    tsdb_match_timelines: matchTimelines,
  };

  const collections = {};
  await Promise.all(
    Object.entries(summaries).map(async ([name, summary]) => {
      const expectedIds = expectedByCollection[name] || [];
      const missingCount = await countMissingTsdbCacheRecords(name, expectedIds);
      const expectedCount = expectedIds.length;
      const cachedCount = Number(summary && summary.count) || 0;
      collections[name] = {
        ...emptyCollection,
        ...(summary || {}),
        expected_count: expectedCount,
        missing_count: missingCount,
        completion_ratio: expectedCount > 0
          ? Math.max(0, Math.min(1, (expectedCount - missingCount) / expectedCount))
          : (cachedCount > 0 ? 1 : 0),
      };
    })
  );

  return {
    available: true,
    refreshed_at_seconds: Math.floor(nowMs / 1000),
    collections,
  };
}

async function upsertMatchLineupCache(eventId, payload, metadata = {}) {
  return upsertTsdbCacheRecord("tsdb_match_lineups", eventId, payload, metadata);
}

async function getMatchLineupCache(eventId) {
  return getTsdbCacheRecord("tsdb_match_lineups", eventId);
}

async function getMatchLineupCaches(eventIds = []) {
  return getTsdbCacheRecords("tsdb_match_lineups", eventIds);
}

async function upsertMatchTimelineCache(eventId, payload, metadata = {}) {
  return upsertTsdbCacheRecord("tsdb_match_timelines", eventId, payload, metadata);
}

async function getMatchTimelineCache(eventId) {
  return getTsdbCacheRecord("tsdb_match_timelines", eventId);
}

async function upsertTeamCache(teamId, payload, metadata = {}) {
  return upsertTsdbCacheRecord("tsdb_teams", teamId, payload, metadata);
}

async function getTeamCache(teamId) {
  return getTsdbCacheRecord("tsdb_teams", teamId);
}

async function getTeamCaches(teamIds = []) {
  return getTsdbCacheRecords("tsdb_teams", teamIds);
}

async function upsertPlayerCache(playerId, payload, metadata = {}) {
  return upsertTsdbCacheRecord("tsdb_players", playerId, payload, metadata);
}

async function getPlayerCache(playerId) {
  return getTsdbCacheRecord("tsdb_players", playerId);
}

async function getPlayerCaches(playerIds = []) {
  return getTsdbCacheRecords("tsdb_players", playerIds);
}

async function findPlayerCachesByNames(playerNames = []) {
  const mongoDb = await getDb();
  if (!mongoDb) return [];
  const names = Array.isArray(playerNames)
    ? [...new Set(playerNames.map((name) => String(name || "").trim()).filter(Boolean))]
    : [];
  if (names.length === 0) return [];
  const nameRegexes = playerNameSearchRegexes(names);
  const regexClauses = nameRegexes.flatMap((regex) => [
    { "payload.strPlayer": regex },
    { "payload.strPlayerAlternate": regex },
  ]);
  const records = await collection("tsdb_players")
    .find({
      $or: [
        { "payload.strPlayer": { $in: names } },
        { "payload.strPlayerAlternate": { $in: names } },
        ...regexClauses,
      ],
    })
    .collation({ locale: "en", strength: 1 })
    .toArray();
  return records.map(stripMongoId);
}

function playerNameSearchRegexes(names = []) {
  const regexes = [];
  const seen = new Set();
  names.forEach((name) => {
    const variants = [
      String(name || "").trim(),
      String(name || "")
        .normalize("NFD")
        .replace(/[\u0300-\u036f]/g, "")
        .trim(),
    ].filter(Boolean);
    variants.forEach((variant) => {
      const tokens = variant.split(/[^A-Za-z0-9À-ÖØ-öø-ÿ]+/).filter(Boolean);
      if (tokens.length === 0 || tokens.some((token) => token.length < 3)) return;
      const pattern = tokens.map(escapeRegex).join("[^A-Za-z0-9À-ÖØ-öø-ÿ]+");
      const boundedPattern = `(^|[^A-Za-z0-9À-ÖØ-öø-ÿ])${pattern}([^A-Za-z0-9À-ÖØ-öø-ÿ]|$)`;
      const key = boundedPattern.toLowerCase();
      if (seen.has(key)) return;
      seen.add(key);
      regexes.push(new RegExp(boundedPattern, "i"));
    });
  });
  return regexes.slice(0, 60);
}

function escapeRegex(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// ---------------------------------------------------------------------------
// BSD evaluation collections
//
// Generic id-keyed upsert: one document per BSD entity, `_id` = entity id,
// every document stamped with an `updated_at` ISO timestamp. Extra top-level
// fields (passed via `extra`) are indexed for querying; the full payload is
// preserved verbatim under `payload`.
// ---------------------------------------------------------------------------

function hasBsdEventRoundName(payload) {
  return Boolean(
    payload &&
    typeof payload === "object" &&
    String(payload.round_name || "").trim()
  );
}

function shouldPreserveExistingBsdEventRoundName(collectionName, payload) {
  return collectionName === "bsd_events" && !hasBsdEventRoundName(payload);
}

function existingBsdEventRoundNameExpression() {
  return {
    $and: [
      { $ne: ["$payload.round_name", null] },
      { $ne: ["$payload.round_name", ""] },
    ],
  };
}

function bsdEventPayloadPreservingRoundNameExpression(payload) {
  return {
    $cond: [
      existingBsdEventRoundNameExpression(),
      {
        $mergeObjects: [
          { $literal: payload },
          { round_name: "$payload.round_name" },
        ],
      },
      { $literal: payload },
    ],
  };
}

function bsdUpsertSetStage(collectionName, payload, extra, updatedAtIso) {
  const setStage = {
    payload: shouldPreserveExistingBsdEventRoundName(collectionName, payload)
      ? bsdEventPayloadPreservingRoundNameExpression(payload)
      : { $literal: payload },
    updated_at: updatedAtIso,
  };
  Object.entries(extra && typeof extra === "object" ? extra : {}).forEach(([key, value]) => {
    setStage[key] = { $literal: value };
  });
  return setStage;
}

async function upsertBsdRecord(collectionName, id, payload, extra = {}) {
  const mongoDb = await getDb();
  if (!mongoDb) return null;
  const normalizedId = normalizeRecordId(id);
  if (!normalizedId) return null;
  const updatedAtIso = new Date().toISOString();
  const update = shouldPreserveExistingBsdEventRoundName(collectionName, payload)
    ? [
        {
          $set: {
            ...bsdUpsertSetStage(collectionName, payload, extra, updatedAtIso),
          },
        },
      ]
    : {
        $set: {
          _id: normalizedId,
          payload,
          ...extra,
          updated_at: updatedAtIso,
        },
      };
  await collection(collectionName).updateOne(
    { _id: normalizedId },
    update,
    { upsert: true }
  );
  return normalizedId;
}

async function upsertBsdRecords(collectionName, records = []) {
  const mongoDb = await getDb();
  if (!mongoDb || !Array.isArray(records) || records.length === 0) return null;
  const nowIso = new Date().toISOString();
  const ops = [];
  records.forEach(({ id, payload, extra }) => {
    const normalizedId = normalizeRecordId(id);
    if (!normalizedId) return;
    const update = shouldPreserveExistingBsdEventRoundName(collectionName, payload)
      ? [
          {
            $set: {
              ...bsdUpsertSetStage(collectionName, payload, extra, nowIso),
            },
          },
        ]
      : {
          $set: {
            _id: normalizedId,
            payload,
            ...(extra && typeof extra === "object" ? extra : {}),
            updated_at: nowIso,
          },
        };
    ops.push({
      updateOne: {
        filter: { _id: normalizedId },
        update,
        upsert: true,
      },
    });
  });
  if (ops.length === 0) return null;
  const result = await collection(collectionName).bulkWrite(ops, { ordered: false });
  return { upserted: result.upsertedCount, modified: result.modifiedCount };
}

async function getBsdRecords(collectionName, filter = {}, options = {}) {
  const mongoDb = await getDb();
  if (!mongoDb) return [];
  let cursor = collection(collectionName).find(filter, {
    ...(options.projection ? { projection: options.projection } : {}),
  });
  if (options.sort) cursor = cursor.sort(options.sort);
  if (Number.isFinite(Number(options.limit)) && Number(options.limit) > 0) {
    cursor = cursor.limit(Math.floor(Number(options.limit)));
  }
  return cursor.toArray();
}

async function getBsdPlayerMapsByTsdbIds(playerIds = []) {
  const ids = Array.isArray(playerIds)
    ? [...new Set(playerIds.map((id) => String(id || "").trim()).filter(Boolean))]
    : [];
  if (ids.length === 0) return [];
  return getBsdRecords(
    "bsd_tsdb_player_map",
    { "payload.tsdb_player_id": { $in: ids } },
    {
      projection: {
        _id: 1,
        "payload.tsdb_player_id": 1,
      },
    }
  );
}

// Lightweight existence check across a whole bsd_ collection — projects only
// _id so callers can build a "already have this" Set without pulling every
// payload (used to skip re-hydrating incidents/lineups for events already on
// file).
async function getBsdRecordIds(collectionName) {
  const mongoDb = await getDb();
  if (!mongoDb) return [];
  const docs = await collection(collectionName).find({}, { projection: { _id: 1 } }).toArray();
  return docs.map((doc) => doc._id);
}

// Prunes every doc in a bsd_ collection whose _id is NOT in `keepIds` — used
// by the broadcasts daily snapshot so fixtures that drop all their listings
// don't keep stale channels. Returns the deleted count.
async function deleteBsdRecordsNotIn(collectionName, keepIds = []) {
  const mongoDb = await getDb();
  if (!mongoDb) return 0;
  const normalized = (Array.isArray(keepIds) ? keepIds : [])
    .map(normalizeRecordId)
    .filter(Boolean);
  const result = await collection(collectionName).deleteMany({
    _id: { $nin: normalized },
  });
  return result.deletedCount || 0;
}

async function getBsdRecord(collectionName, id) {
  const mongoDb = await getDb();
  if (!mongoDb) return null;
  const normalizedId = normalizeRecordId(id);
  if (!normalizedId) return null;
  return collection(collectionName).findOne({ _id: normalizedId });
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
  getOperationalDatasetMetadata,
  saveOperationalMatchDetailsRecords,
  getOperationalMatchDetails,
  getAllOperationalMatchDetails,
  getOperationalMatchDetailsByDates,
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
  upsertTvListings,
  getAllTvListings,
  purgeStaleTvListings,
  upsertLeagues,
  upsertTsdbLeagueTables,
  getAllTsdbLeagueTables,
  upsertMatchLineupCache,
  getMatchLineupCache,
  getMatchLineupCaches,
  upsertMatchTimelineCache,
  getMatchTimelineCache,
  upsertTeamCache,
  getTeamCache,
  getTeamCaches,
  upsertPlayerCache,
  getPlayerCache,
  getPlayerCaches,
  findPlayerCachesByNames,
  getTsdbCacheObservabilitySnapshot,
  upsertBsdRecord,
  upsertBsdRecords,
  getBsdRecords,
  getBsdPlayerMapsByTsdbIds,
  getBsdRecordIds,
  getBsdRecord,
  deleteBsdRecordsNotIn,
  __private: {
    configuredMongoPoolSize,
    runtimeRoleFromEntrypoint,
    hasBsdEventRoundName,
    shouldPreserveExistingBsdEventRoundName,
    bsdEventPayloadPreservingRoundNameExpression,
    bsdUpsertSetStage,
  },
};
