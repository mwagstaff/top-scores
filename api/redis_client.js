const crypto = require("crypto");
const { createClient } = require("redis");

const REDIS_HOST = process.env.REDIS_HOST || "127.0.0.1";
const REDIS_PORT = process.env.REDIS_PORT || 6379;
const REDIS_DB = process.env.REDIS_DB || 0;
const REDIS_PASSWORD = process.env.REDIS_PASSWORD || undefined;

const DB_NAME = "top_scores";
const USER_PREFERENCES_PREFIX = `${DB_NAME}:user_preferences:`;

const ONE_WEEK_SECONDS = 7 * 24 * 60 * 60;

function parsePositiveIntOrFallback(value, fallback) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  const normalized = Math.floor(parsed);
  if (normalized <= 0) return fallback;
  return normalized;
}

const BBC_HISTORY_TTL_SECONDS = parsePositiveIntOrFallback(
  process.env.BBC_HISTORY_TTL_SECONDS,
  ONE_WEEK_SECONDS
);
const BBC_EVENT_HISTORY_TTL_SECONDS = parsePositiveIntOrFallback(
  process.env.BBC_EVENT_HISTORY_TTL_SECONDS,
  BBC_HISTORY_TTL_SECONDS
);
const BBC_NOTIFICATION_HISTORY_TTL_SECONDS = parsePositiveIntOrFallback(
  process.env.BBC_NOTIFICATION_HISTORY_TTL_SECONDS,
  BBC_HISTORY_TTL_SECONDS
);
const BBC_NOTIFICATION_IDEMPOTENCY_TTL_SECONDS = parsePositiveIntOrFallback(
  process.env.BBC_NOTIFICATION_IDEMPOTENCY_TTL_SECONDS,
  6 * 60 * 60
);
const USER_PREFERENCES_TTL_SECONDS = parsePositiveIntOrFallback(
  process.env.USER_PREFERENCES_TTL_SECONDS,
  180 * 24 * 60 * 60
);
const FANTASY_REMINDER_HISTORY_TTL_SECONDS = parsePositiveIntOrFallback(
  process.env.FANTASY_REMINDER_HISTORY_TTL_SECONDS,
  180 * 24 * 60 * 60
);
const FANTASY_REMINDER_SEND_IDEMPOTENCY_TTL_SECONDS = parsePositiveIntOrFallback(
  process.env.FANTASY_REMINDER_SEND_IDEMPOTENCY_TTL_SECONDS,
  30 * 24 * 60 * 60
);
const LIVE_ACTIVITY_DEBUG_HISTORY_TTL_SECONDS = parsePositiveIntOrFallback(
  process.env.LIVE_ACTIVITY_DEBUG_HISTORY_TTL_SECONDS,
  14 * 24 * 60 * 60
);
const MAX_BBC_HISTORY_QUERY_MS = 7 * 24 * 60 * 60 * 1000;

const BBC_EVENTS_INDEX_KEY = `${DB_NAME}:bbc:events:index`;
const BBC_EVENTS_MATCH_INDEX_PREFIX = `${DB_NAME}:bbc:events:match:`;
const BBC_EVENTS_RECORD_PREFIX = `${DB_NAME}:bbc:events:record:`;

const BBC_NOTIFICATIONS_INDEX_KEY = `${DB_NAME}:bbc:notifications:index`;
const BBC_NOTIFICATIONS_MATCH_INDEX_PREFIX = `${DB_NAME}:bbc:notifications:match:`;
const BBC_NOTIFICATIONS_MATCH_DEVICE_INDEX_PREFIX =
  `${DB_NAME}:bbc:notifications:match_device:`;
const BBC_NOTIFICATIONS_RECORD_PREFIX = `${DB_NAME}:bbc:notifications:record:`;
const BBC_NOTIFICATION_IDEMPOTENCY_PREFIX =
  `${DB_NAME}:bbc:notifications:idempotency:`;

const FANTASY_REMINDERS_INDEX_KEY = `${DB_NAME}:fantasy:reminders:index`;
const FANTASY_REMINDERS_DEVICE_INDEX_PREFIX = `${DB_NAME}:fantasy:reminders:device:`;
const FANTASY_REMINDERS_RECORD_PREFIX = `${DB_NAME}:fantasy:reminders:record:`;
const FANTASY_REMINDERS_SEND_IDEMPOTENCY_PREFIX =
  `${DB_NAME}:fantasy:reminders:idempotency:`;

const OPERATIONAL_DATASET_PREFIX = `${DB_NAME}:operational:dataset:`;
const OPERATIONAL_MATCH_DETAILS_PREFIX = `${DB_NAME}:operational:match_details:`;
const OPERATIONAL_MATCH_DETAILS_INDEX_KEY = `${DB_NAME}:operational:match_details:index`;
const OPERATIONAL_MATCH_DETAILS_META_KEY = `${DB_NAME}:operational:match_details:meta`;
const LIVE_ACTIVITY_DEBUG_DEVICE_INDEX_PREFIX = `${DB_NAME}:live_activity:debug:device:`;
const LIVE_ACTIVITY_DEBUG_RECORD_PREFIX = `${DB_NAME}:live_activity:debug:record:`;

let client = null;
let isConnected = false;
let ttlPolicyEnsured = false;

function sanitizeTokenForKey(value, fallback = "unknown") {
  const normalized = String(value || "").trim();
  if (!normalized) return fallback;
  return encodeURIComponent(normalized).replace(/%/g, "_");
}

function normalizeTimeRange(startMs, endMs) {
  const nowMs = Date.now();
  let normalizedStart = Number(startMs);
  let normalizedEnd = Number(endMs);

  if (!Number.isFinite(normalizedStart)) {
    normalizedStart = nowMs - MAX_BBC_HISTORY_QUERY_MS;
  }
  if (!Number.isFinite(normalizedEnd)) {
    normalizedEnd = nowMs;
  }

  if (normalizedEnd < normalizedStart) {
    const temp = normalizedStart;
    normalizedStart = normalizedEnd;
    normalizedEnd = temp;
  }

  if (normalizedEnd - normalizedStart > MAX_BBC_HISTORY_QUERY_MS) {
    normalizedStart = normalizedEnd - MAX_BBC_HISTORY_QUERY_MS;
  }

  return {
    startMs: Math.max(0, Math.floor(normalizedStart)),
    endMs: Math.max(0, Math.floor(normalizedEnd)),
  };
}

function randomRecordId() {
  return crypto.randomBytes(8).toString("hex");
}

function hashForRedisKey(value) {
  return crypto.createHash("sha1").update(String(value || "")).digest("hex");
}

function shortDeviceToken(deviceToken) {
  return String(deviceToken || "").slice(0, 12);
}

function numericTimestampMs(value) {
  const parsed = Number(value);
  if (Number.isFinite(parsed) && parsed > 0) return Math.floor(parsed);
  return Date.now();
}

function pruneCutoffMs(ttlSeconds) {
  return Date.now() - ttlSeconds * 1000;
}

async function pruneIndexEntries(redisClient, indexKey, cutoffMs) {
  if (!Number.isFinite(cutoffMs)) return;
  try {
    await redisClient.zRemRangeByScore(indexKey, 0, cutoffMs);
  } catch (error) {
    console.warn(`[Redis] Failed pruning index ${indexKey}:`, error.message || error);
  }
}

function buildMatchGroup(matchId, seed = null) {
  const seedMatch = seed && typeof seed === "object" ? seed : {};
  return {
    match_id: matchId,
    home_team: seedMatch.home_team || null,
    away_team: seedMatch.away_team || null,
    league: seedMatch.league || null,
    kickoff_date: seedMatch.date || null,
    kickoff_time: seedMatch.time || null,
    events: [],
    notifications: [],
    first_timestamp_ms: null,
    last_timestamp_ms: null,
  };
}

function updateMatchGroupTimestamps(group, timestampMs) {
  if (!Number.isFinite(timestampMs)) return;
  if (!Number.isFinite(group.first_timestamp_ms) || timestampMs < group.first_timestamp_ms) {
    group.first_timestamp_ms = timestampMs;
  }
  if (!Number.isFinite(group.last_timestamp_ms) || timestampMs > group.last_timestamp_ms) {
    group.last_timestamp_ms = timestampMs;
  }
}

function safeJsonParse(raw, contextLabel) {
  try {
    return JSON.parse(raw);
  } catch (error) {
    console.warn(`[Redis] Failed to parse ${contextLabel}:`, error.message || error);
    return null;
  }
}

async function countKeysByPattern(redisClient, pattern) {
  let count = 0;
  for await (const entry of redisClient.scanIterator({ MATCH: pattern, COUNT: 500 })) {
    if (Array.isArray(entry)) {
      count += entry.length;
      continue;
    }
    count += 1;
  }
  return count;
}

async function ensureFiniteTtlForKey(redisClient, key, ttlSeconds) {
  if (!key) return;
  const ttl = await redisClient.ttl(key);
  if (ttl === -1) {
    await redisClient.expire(key, ttlSeconds);
  }
}

async function ensureFiniteTtlForPattern(redisClient, pattern, ttlSeconds) {
  for await (const entry of redisClient.scanIterator({ MATCH: pattern, COUNT: 500 })) {
    const keys = Array.isArray(entry) ? entry : [entry];
    for (const key of keys) {
      // eslint-disable-next-line no-await-in-loop
      await ensureFiniteTtlForKey(redisClient, key, ttlSeconds);
    }
  }
}

async function ensureRedisTtlPolicy(redisClient) {
  await Promise.all([
    ensureFiniteTtlForKey(redisClient, BBC_EVENTS_INDEX_KEY, BBC_EVENT_HISTORY_TTL_SECONDS),
    ensureFiniteTtlForKey(
      redisClient,
      BBC_NOTIFICATIONS_INDEX_KEY,
      BBC_NOTIFICATION_HISTORY_TTL_SECONDS
    ),
    ensureFiniteTtlForKey(
      redisClient,
      FANTASY_REMINDERS_INDEX_KEY,
      FANTASY_REMINDER_HISTORY_TTL_SECONDS
    ),
  ]);

  const patternPolicies = [
    { pattern: `${USER_PREFERENCES_PREFIX}*`, ttl: USER_PREFERENCES_TTL_SECONDS },
    { pattern: `${BBC_EVENTS_RECORD_PREFIX}*`, ttl: BBC_EVENT_HISTORY_TTL_SECONDS },
    { pattern: `${BBC_EVENTS_MATCH_INDEX_PREFIX}*`, ttl: BBC_EVENT_HISTORY_TTL_SECONDS },
    { pattern: `${BBC_NOTIFICATIONS_RECORD_PREFIX}*`, ttl: BBC_NOTIFICATION_HISTORY_TTL_SECONDS },
    {
      pattern: `${BBC_NOTIFICATIONS_MATCH_INDEX_PREFIX}*`,
      ttl: BBC_NOTIFICATION_HISTORY_TTL_SECONDS,
    },
    {
      pattern: `${BBC_NOTIFICATIONS_MATCH_DEVICE_INDEX_PREFIX}*`,
      ttl: BBC_NOTIFICATION_HISTORY_TTL_SECONDS,
    },
    {
      pattern: `${BBC_NOTIFICATION_IDEMPOTENCY_PREFIX}*`,
      ttl: BBC_NOTIFICATION_IDEMPOTENCY_TTL_SECONDS,
    },
    {
      pattern: `${FANTASY_REMINDERS_RECORD_PREFIX}*`,
      ttl: FANTASY_REMINDER_HISTORY_TTL_SECONDS,
    },
    {
      pattern: `${FANTASY_REMINDERS_DEVICE_INDEX_PREFIX}*`,
      ttl: FANTASY_REMINDER_HISTORY_TTL_SECONDS,
    },
    {
      pattern: `${FANTASY_REMINDERS_SEND_IDEMPOTENCY_PREFIX}*`,
      ttl: FANTASY_REMINDER_SEND_IDEMPOTENCY_TTL_SECONDS,
    },
    {
      pattern: `${LIVE_ACTIVITY_DEBUG_RECORD_PREFIX}*`,
      ttl: LIVE_ACTIVITY_DEBUG_HISTORY_TTL_SECONDS,
    },
    {
      pattern: `${LIVE_ACTIVITY_DEBUG_DEVICE_INDEX_PREFIX}*`,
      ttl: LIVE_ACTIVITY_DEBUG_HISTORY_TTL_SECONDS,
    },
  ];
  for (const policy of patternPolicies) {
    await ensureFiniteTtlForPattern(redisClient, policy.pattern, policy.ttl);
  }
}

async function getClient() {
  if (client && isConnected) {
    return client;
  }

  const config = {
    socket: {
      host: REDIS_HOST,
      port: REDIS_PORT,
    },
    database: REDIS_DB,
  };

  if (REDIS_PASSWORD) {
    config.password = REDIS_PASSWORD;
  }

  client = createClient(config);

  client.on("error", (err) => {
    console.error("[Redis] Client error:", err);
    isConnected = false;
  });

  client.on("connect", () => {
    console.log(`[Redis] Connected to ${REDIS_HOST}:${REDIS_PORT} (DB ${REDIS_DB})`);
    isConnected = true;
  });

  client.on("disconnect", () => {
    console.log("[Redis] Disconnected");
    isConnected = false;
    ttlPolicyEnsured = false;
  });

  await client.connect();
  if (!ttlPolicyEnsured) {
    try {
      await ensureRedisTtlPolicy(client);
      ttlPolicyEnsured = true;
    } catch (error) {
      console.warn("[Redis] Failed applying TTL policy:", error.message || error);
    }
  }
  return client;
}

function normalizeOptionalToken(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function normalizeFantasyPositiveInt(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return null;
  const normalized = Math.floor(parsed);
  return normalized > 0 ? normalized : null;
}

function normalizeFantasyBoolean(value, fallback = false) {
  return typeof value === "boolean" ? value : fallback;
}

function normalizeFantasyPlayer(player = {}) {
  if (!player || typeof player !== "object") return null;

  const elementID = normalizeFantasyPositiveInt(player.elementID);
  const pickPosition = normalizeFantasyPositiveInt(player.pickPosition);
  const positionType = normalizeFantasyPositiveInt(player.positionType);
  const displayName = normalizeOptionalToken(player.displayName);
  const fullName = normalizeOptionalToken(player.fullName);
  const teamName = normalizeOptionalToken(player.teamName);

  if (!elementID || !pickPosition || !positionType || !displayName || !teamName) {
    return null;
  }

  return {
    elementID,
    pickPosition,
    positionType,
    displayName,
    fullName,
    teamName,
    rawPoints: Number.isFinite(Number(player.rawPoints)) ? Number(player.rawPoints) : 0,
    appliedPoints: Number.isFinite(Number(player.appliedPoints)) ? Number(player.appliedPoints) : 0,
    displayPoints: Number.isFinite(Number(player.displayPoints)) ? Number(player.displayPoints) : 0,
    multiplier: Number.isFinite(Number(player.multiplier)) ? Number(player.multiplier) : 1,
    isCaptain: normalizeFantasyBoolean(player.isCaptain),
    isViceCaptain: normalizeFantasyBoolean(player.isViceCaptain),
    isStarter: normalizeFantasyBoolean(player.isStarter),
    hasAnyFixtureThisGameweek: normalizeFantasyBoolean(player.hasAnyFixtureThisGameweek),
    hasUpcomingFixtureThisGameweek: normalizeFantasyBoolean(player.hasUpcomingFixtureThisGameweek),
    hasActiveFixtureThisGameweek: normalizeFantasyBoolean(player.hasActiveFixtureThisGameweek),
    minutesPlayed: Number.isFinite(Number(player.minutesPlayed)) ? Number(player.minutesPlayed) : 0,
  };
}

function normalizeFantasyContribution(contribution = {}) {
  if (!contribution || typeof contribution !== "object") return null;

  const elementID = normalizeFantasyPositiveInt(contribution.elementID);
  const displayName = normalizeOptionalToken(contribution.displayName);
  const fullName = normalizeOptionalToken(contribution.fullName);
  const teamName = normalizeOptionalToken(contribution.teamName);
  const points = Number(contribution.points);

  if (!elementID || !displayName || !teamName || !Number.isFinite(points)) {
    return null;
  }

  return {
    elementID,
    displayName,
    fullName,
    teamName,
    points: Math.floor(points),
  };
}

function normalizeFantasySquad(value = {}, managerEntryID = null) {
  if (!value || typeof value !== "object") return null;

  const resolvedManagerEntryID =
    normalizeFantasyPositiveInt(value.managerEntryID) || normalizeFantasyPositiveInt(managerEntryID);
  const gameweekID = normalizeFantasyPositiveInt(value.gameweekID);
  const gameweekTitle = normalizeOptionalToken(value.gameweekTitle);
  if (!resolvedManagerEntryID || !gameweekID || !gameweekTitle) {
    return null;
  }

  const players = Array.isArray(value.players)
    ? value.players.map(normalizeFantasyPlayer).filter(Boolean)
    : [];
  const effectiveContributions = Array.isArray(value.effectiveContributions)
    ? value.effectiveContributions.map(normalizeFantasyContribution).filter(Boolean)
    : [];

  return {
    managerEntryID: resolvedManagerEntryID,
    syncedAt: normalizeOptionalToken(value.syncedAt) || new Date().toISOString(),
    gameweekID,
    gameweekTitle,
    totalPoints: Number.isFinite(Number(value.totalPoints)) ? Number(value.totalPoints) : 0,
    estimatedCurrentScore: Number.isFinite(Number(value.estimatedCurrentScore))
      ? Number(value.estimatedCurrentScore)
      : 0,
    resolvedCurrentScore: Number.isFinite(Number(value.resolvedCurrentScore))
      ? Number(value.resolvedCurrentScore)
      : 0,
    isEstimatedScore: normalizeFantasyBoolean(value.isEstimatedScore),
    hasActiveFixtures: normalizeFantasyBoolean(value.hasActiveFixtures),
    activeChipCodes: Array.isArray(value.activeChipCodes)
      ? value.activeChipCodes
        .map(normalizeOptionalToken)
        .filter(Boolean)
      : [],
    players,
    effectiveContributions,
  };
}

function normalizeFantasyState(value) {
  if (value === null) return null;
  if (!value || typeof value !== "object") return undefined;

  const managerEntryID = normalizeFantasyPositiveInt(value.managerEntryID);
  const squad = normalizeFantasySquad(value.squad, managerEntryID);
  const resolvedManagerEntryID =
    managerEntryID || normalizeFantasyPositiveInt(squad && squad.managerEntryID);

  if (!resolvedManagerEntryID && !squad) {
    return null;
  }

  return {
    managerEntryID: resolvedManagerEntryID || null,
    squad: squad || null,
  };
}

function normalizeLiveActivityStatePatch(patch = {}) {
  const normalized = {};
  if (!patch || typeof patch !== "object") return normalized;

  if (Object.prototype.hasOwnProperty.call(patch, "pushToStartToken")) {
    normalized.pushToStartToken = normalizeOptionalToken(patch.pushToStartToken);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "currentActivityId")) {
    normalized.currentActivityId = normalizeOptionalToken(patch.currentActivityId);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "currentActivityPushToken")) {
    normalized.currentActivityPushToken = normalizeOptionalToken(patch.currentActivityPushToken);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "pendingStartAt")) {
    normalized.pendingStartAt = normalizeOptionalToken(patch.pendingStartAt);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "lastPayloadHash")) {
    normalized.lastPayloadHash = normalizeOptionalToken(patch.lastPayloadHash);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "lastScoreHash")) {
    normalized.lastScoreHash = normalizeOptionalToken(patch.lastScoreHash);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "lastMode")) {
    normalized.lastMode = normalizeOptionalToken(patch.lastMode);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "lastDispatchAt")) {
    normalized.lastDispatchAt = normalizeOptionalToken(patch.lastDispatchAt);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "lastStartAt")) {
    normalized.lastStartAt = normalizeOptionalToken(patch.lastStartAt);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "pushToStartTokenUpdatedAt")) {
    normalized.pushToStartTokenUpdatedAt = normalizeOptionalToken(patch.pushToStartTokenUpdatedAt);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "currentActivityTokenUpdatedAt")) {
    normalized.currentActivityTokenUpdatedAt = normalizeOptionalToken(
      patch.currentActivityTokenUpdatedAt
    );
  }
  if (Object.prototype.hasOwnProperty.call(patch, "lastEndedAt")) {
    normalized.lastEndedAt = normalizeOptionalToken(patch.lastEndedAt);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "testHoldUntil")) {
    normalized.testHoldUntil = normalizeOptionalToken(patch.testHoldUntil);
  }
  return normalized;
}

function mergedLiveActivityState(existingState = {}, patch = {}) {
  const existing = existingState && typeof existingState === "object" ? existingState : {};
  return {
    ...existing,
    ...normalizeLiveActivityStatePatch(patch),
  };
}

function recordUpdatedAtMs(record) {
  const parsed = Date.parse(String(record && record.updatedAt ? record.updatedAt : "").trim());
  return Number.isFinite(parsed) ? parsed : null;
}

function freshestUserRecord(...records) {
  return records
    .filter((record) => record && typeof record === "object")
    .sort((left, right) => {
      const leftMs = recordUpdatedAtMs(left);
      const rightMs = recordUpdatedAtMs(right);
      if (leftMs === null && rightMs === null) return 0;
      if (leftMs === null) return 1;
      if (rightMs === null) return -1;
      return rightMs - leftMs;
    })[0] || null;
}

async function saveUserPreferences(
  deviceToken,
  preferences,
  apnsToken = null,
  isDevelopmentBuild = false,
  options = {}
) {
  if (!deviceToken || typeof deviceToken !== "string" || !deviceToken.trim()) {
    throw new Error("Invalid device token");
  }

  const normalizedToken = deviceToken.trim();
  const key = `${USER_PREFERENCES_PREFIX}${normalizedToken}`;

  try {
    const redisClient = await getClient();
    let existing = null;
    if (options && options.mergeExisting !== false) {
      const rawExisting = await redisClient.get(key);
      existing = rawExisting ? safeJsonParse(rawExisting, `user preferences ${normalizedToken}`) : null;
    }

    const resolvedAPNSToken = apnsToken !== undefined
      ? normalizeOptionalToken(apnsToken)
      : normalizeOptionalToken(existing && existing.apnsToken);
    const resolvedIsDevelopmentBuild = typeof isDevelopmentBuild === "boolean"
      ? isDevelopmentBuild
      : Boolean(existing && existing.isDevelopmentBuild);
    const resolvedPreferences =
      preferences && typeof preferences === "object"
        ? preferences
        : existing && typeof existing.preferences === "object"
          ? existing.preferences
          : {};
    const hasFantasyStatePatch =
      options &&
      Object.prototype.hasOwnProperty.call(options, "fantasy");
    const resolvedFantasy = hasFantasyStatePatch
      ? normalizeFantasyState(options.fantasy)
      : existing && Object.prototype.hasOwnProperty.call(existing, "fantasy")
        ? existing.fantasy
        : null;
    const liveActivityPatch = options && options.liveActivity
      ? normalizeLiveActivityStatePatch(options.liveActivity)
      : {};
    const existingLiveActivity =
      existing && existing.liveActivity && typeof existing.liveActivity === "object"
        ? existing.liveActivity
        : {};

    const data = {
      ...(existing && typeof existing === "object" ? existing : {}),
      deviceToken: normalizedToken,
      apnsToken: resolvedAPNSToken,
      isDevelopmentBuild: resolvedIsDevelopmentBuild,
      preferences: resolvedPreferences,
      fantasy: resolvedFantasy,
      liveActivity: {
        ...existingLiveActivity,
        ...liveActivityPatch,
      },
      updatedAt: new Date().toISOString(),
    };

    await redisClient.set(key, JSON.stringify(data), { EX: USER_PREFERENCES_TTL_SECONDS });
    console.log(
      `[Redis] Saved preferences for device: ${normalizedToken.substring(0, 12)}... (APNS: ${resolvedAPNSToken ? "Yes" : "No"}, Dev: ${resolvedIsDevelopmentBuild})`
    );
    return data;
  } catch (error) {
    console.error("[Redis] Error saving user preferences:", error);
    throw error;
  }
}

async function getUserPreferences(deviceToken) {
  if (!deviceToken || typeof deviceToken !== "string" || !deviceToken.trim()) {
    return null;
  }

  const normalizedToken = deviceToken.trim();
  const key = `${USER_PREFERENCES_PREFIX}${normalizedToken}`;

  try {
    const redisClient = await getClient();
    const data = await redisClient.get(key);

    if (!data) {
      return null;
    }

    return JSON.parse(data);
  } catch (error) {
    console.error("[Redis] Error retrieving user preferences:", error);
    return null;
  }
}

async function deleteUserPreferences(deviceToken) {
  if (!deviceToken || typeof deviceToken !== "string" || !deviceToken.trim()) {
    return false;
  }

  const normalizedToken = deviceToken.trim();
  const key = `${USER_PREFERENCES_PREFIX}${normalizedToken}`;

  try {
    const redisClient = await getClient();
    const deleted = await redisClient.del(key);
    console.log(`[Redis] Deleted preferences for device: ${normalizedToken.substring(0, 12)}...`);
    return deleted > 0;
  } catch (error) {
    console.error("[Redis] Error deleting user preferences:", error);
    return false;
  }
}

async function getAllUserPreferences() {
  try {
    const redisClient = await getClient();
    const pattern = `${USER_PREFERENCES_PREFIX}*`;

    const keys = await redisClient.keys(pattern);

    if (keys.length === 0) {
      return [];
    }

    const values = await Promise.all(
      keys.map(async (key) => {
        try {
          return await redisClient.get(key);
        } catch (error) {
          console.error(`[Redis] Error fetching key ${key}:`, error);
          return null;
        }
      })
    );

    return values
      .filter((value) => value !== null)
      .map((value) => {
        try {
          return JSON.parse(value);
        } catch (error) {
          console.error("[Redis] Error parsing preference value:", error);
          return null;
        }
      })
      .filter((data) => data && data.deviceToken);
  } catch (error) {
    console.error("[Redis] Error retrieving all user preferences:", error);
    return [];
  }
}

async function updateUserLiveActivityState(deviceToken, liveActivityPatch = {}, options = {}) {
  if (!deviceToken || typeof deviceToken !== "string" || !deviceToken.trim()) {
    throw new Error("Invalid device token");
  }

  const normalizedToken = deviceToken.trim();
  const key = `${USER_PREFERENCES_PREFIX}${normalizedToken}`;
  const nowIso = new Date().toISOString();

  try {
    const redisClient = await getClient();
    const raw = await redisClient.get(key);
    const existing = raw ? safeJsonParse(raw, `user preferences ${normalizedToken}`) : null;
    // Live-activity callbacks can race with preference/fantasy sync writes.
    // Re-read the latest record before persisting so we don't resurrect stale fantasy data.
    const latestRaw = await redisClient.get(key);
    const latest = latestRaw ? safeJsonParse(latestRaw, `user preferences latest ${normalizedToken}`) : null;
    const freshest = freshestUserRecord(latest, existing);
    const existingPreferences =
      freshest && typeof freshest.preferences === "object" ? freshest.preferences : {};
    const existingLiveActivity =
      freshest && freshest.liveActivity && typeof freshest.liveActivity === "object"
        ? freshest.liveActivity
        : {};
    const data = {
      ...(freshest && typeof freshest === "object" ? freshest : {}),
      deviceToken: normalizedToken,
      apnsToken: normalizeOptionalToken(freshest && freshest.apnsToken),
      isDevelopmentBuild:
        typeof options.isDevelopmentBuild === "boolean"
          ? options.isDevelopmentBuild
          : Boolean(freshest && freshest.isDevelopmentBuild),
      preferences: existingPreferences,
      liveActivity: mergedLiveActivityState(existingLiveActivity, liveActivityPatch),
      updatedAt: nowIso,
    };

    await redisClient.set(key, JSON.stringify(data), { EX: USER_PREFERENCES_TTL_SECONDS });
    console.log(`[Redis] Updated live activity state for device: ${normalizedToken.substring(0, 12)}...`);
    return data;
  } catch (error) {
    console.error("[Redis] Error updating live activity state:", error);
    throw error;
  }
}

async function saveBbcMatchEventHistory(payload) {
  const matchIdRaw = String(payload && payload.match_id ? payload.match_id : "").trim();
  if (!matchIdRaw) {
    throw new Error("match_id is required to save BBC event history");
  }

  const matchIdForKey = sanitizeTokenForKey(matchIdRaw);
  const eventType = String(payload && payload.event_type ? payload.event_type : "unknown").trim();
  const timestampMs = numericTimestampMs(payload && payload.timestamp_ms);
  const eventId = String(payload && payload.event_id ? payload.event_id : randomRecordId());

  const recordKey = `${BBC_EVENTS_RECORD_PREFIX}${matchIdForKey}:${eventId}`;
  const matchIndexKey = `${BBC_EVENTS_MATCH_INDEX_PREFIX}${matchIdForKey}`;

  const record = {
    event_id: eventId,
    match_id: matchIdRaw,
    event_type: eventType || "unknown",
    timestamp_ms: timestampMs,
    timestamp: new Date(timestampMs).toISOString(),
    match: payload && payload.match ? payload.match : null,
    ...payload,
  };

  try {
    const redisClient = await getClient();
    const transaction = redisClient.multi();
    transaction.set(recordKey, JSON.stringify(record), { EX: BBC_EVENT_HISTORY_TTL_SECONDS });
    transaction.zAdd(BBC_EVENTS_INDEX_KEY, [{ score: timestampMs, value: recordKey }]);
    transaction.zAdd(matchIndexKey, [{ score: timestampMs, value: recordKey }]);
    transaction.expire(BBC_EVENTS_INDEX_KEY, BBC_EVENT_HISTORY_TTL_SECONDS);
    transaction.expire(matchIndexKey, BBC_EVENT_HISTORY_TTL_SECONDS);
    await transaction.exec();

    const cutoffMs = pruneCutoffMs(BBC_EVENT_HISTORY_TTL_SECONDS);
    await Promise.all([
      pruneIndexEntries(redisClient, BBC_EVENTS_INDEX_KEY, cutoffMs),
      pruneIndexEntries(redisClient, matchIndexKey, cutoffMs),
    ]);

    return record;
  } catch (error) {
    console.error("[Redis] Error saving BBC match event history:", error);
    throw error;
  }
}

async function saveBbcNotificationHistory(payload) {
  const matchIdRaw = String(payload && payload.match_id ? payload.match_id : "").trim();
  if (!matchIdRaw) {
    throw new Error("match_id is required to save BBC notification history");
  }

  const deviceTokenRaw = String(payload && payload.device_token ? payload.device_token : "").trim();
  if (!deviceTokenRaw) {
    throw new Error("device_token is required to save BBC notification history");
  }

  const matchIdForKey = sanitizeTokenForKey(matchIdRaw);
  const deviceTokenForKey = sanitizeTokenForKey(deviceTokenRaw);
  const timestampMs = numericTimestampMs(payload && payload.timestamp_ms);
  const notificationId = String(
    payload && payload.notification_id ? payload.notification_id : randomRecordId()
  );
  const status = String(payload && payload.status ? payload.status : "unknown").trim();

  const recordKey = `${BBC_NOTIFICATIONS_RECORD_PREFIX}${matchIdForKey}:${notificationId}`;
  const matchIndexKey = `${BBC_NOTIFICATIONS_MATCH_INDEX_PREFIX}${matchIdForKey}`;
  const matchDeviceIndexKey =
    `${BBC_NOTIFICATIONS_MATCH_DEVICE_INDEX_PREFIX}${matchIdForKey}:${deviceTokenForKey}`;

  const record = {
    notification_id: notificationId,
    match_id: matchIdRaw,
    device_token: deviceTokenRaw,
    status: status || "unknown",
    timestamp_ms: timestampMs,
    timestamp: new Date(timestampMs).toISOString(),
    ...payload,
  };

  try {
    const redisClient = await getClient();
    const transaction = redisClient.multi();
    transaction.set(recordKey, JSON.stringify(record), { EX: BBC_NOTIFICATION_HISTORY_TTL_SECONDS });
    transaction.zAdd(BBC_NOTIFICATIONS_INDEX_KEY, [{ score: timestampMs, value: recordKey }]);
    transaction.zAdd(matchIndexKey, [{ score: timestampMs, value: recordKey }]);
    transaction.zAdd(matchDeviceIndexKey, [{ score: timestampMs, value: recordKey }]);
    transaction.expire(BBC_NOTIFICATIONS_INDEX_KEY, BBC_NOTIFICATION_HISTORY_TTL_SECONDS);
    transaction.expire(matchIndexKey, BBC_NOTIFICATION_HISTORY_TTL_SECONDS);
    transaction.expire(matchDeviceIndexKey, BBC_NOTIFICATION_HISTORY_TTL_SECONDS);
    await transaction.exec();

    const cutoffMs = pruneCutoffMs(BBC_NOTIFICATION_HISTORY_TTL_SECONDS);
    await Promise.all([
      pruneIndexEntries(redisClient, BBC_NOTIFICATIONS_INDEX_KEY, cutoffMs),
      pruneIndexEntries(redisClient, matchIndexKey, cutoffMs),
      pruneIndexEntries(redisClient, matchDeviceIndexKey, cutoffMs),
    ]);

    return record;
  } catch (error) {
    console.error("[Redis] Error saving BBC notification history:", error);
    throw error;
  }
}

function buildBbcNotificationIdempotencyKey(notificationId) {
  const normalizedId = String(notificationId || "").trim();
  if (!normalizedId) {
    throw new Error("notificationId is required to build idempotency key");
  }
  return `${BBC_NOTIFICATION_IDEMPOTENCY_PREFIX}${hashForRedisKey(normalizedId)}`;
}

async function claimBbcNotificationIdempotency(notificationId, options = {}) {
  const normalizedId = String(notificationId || "").trim();
  if (!normalizedId) {
    throw new Error("notificationId is required to claim notification idempotency");
  }

  const ttlSeconds = parsePositiveIntOrFallback(
    options && options.ttl_seconds,
    BBC_NOTIFICATION_IDEMPOTENCY_TTL_SECONDS
  );
  const idempotencyKey = buildBbcNotificationIdempotencyKey(normalizedId);
  const nowIso = new Date().toISOString();
  const payload = JSON.stringify({
    notification_id: normalizedId,
    claimed_at: nowIso,
    context: options && options.context ? options.context : null,
  });

  try {
    const redisClient = await getClient();
    const result = await redisClient.set(idempotencyKey, payload, {
      NX: true,
      EX: ttlSeconds,
    });
    return {
      claimed: result === "OK",
      key: idempotencyKey,
      ttl_seconds: ttlSeconds,
      claimed_at: nowIso,
      source: "redis",
    };
  } catch (error) {
    // Fail open: send notifications even if Redis is temporarily unavailable.
    console.warn(
      `[Redis] Notification idempotency unavailable for ${normalizedId.slice(0, 80)}...:`,
      error.message || error
    );
    return {
      claimed: true,
      key: null,
      ttl_seconds: ttlSeconds,
      claimed_at: nowIso,
      source: "degraded",
      error: error.message || String(error),
    };
  }
}

async function getHistoryRecordsBySortedKeys(redisClient, keys, indexKey, contextLabel) {
  if (!Array.isArray(keys) || keys.length === 0) {
    return [];
  }

  const rawValues = await redisClient.mGet(keys);
  const staleKeys = [];
  const records = [];

  rawValues.forEach((rawValue, index) => {
    const key = keys[index];
    if (!rawValue) {
      staleKeys.push(key);
      return;
    }
    const parsed = safeJsonParse(rawValue, `${contextLabel} record`);
    if (parsed) {
      records.push(parsed);
    }
  });

  if (staleKeys.length > 0) {
    await redisClient.zRem(indexKey, staleKeys);
  }

  return records;
}

async function getHistoryRecordsByRange(redisClient, indexKey, startMs, endMs, contextLabel) {
  const keys = await redisClient.zRangeByScore(indexKey, startMs, endMs);
  return getHistoryRecordsBySortedKeys(redisClient, keys, indexKey, contextLabel);
}

async function getHistoryRecordsAll(redisClient, indexKey, contextLabel) {
  const keys = await redisClient.zRange(indexKey, 0, -1);
  return getHistoryRecordsBySortedKeys(redisClient, keys, indexKey, contextLabel);
}

function buildLiveActivityDebugRecordKey(deviceToken, recordId) {
  const normalizedToken = String(deviceToken || "").trim();
  const normalizedRecordId = String(recordId || "").trim();
  if (!normalizedToken || !normalizedRecordId) {
    throw new Error("deviceToken and recordId are required for live activity debug record key");
  }
  return `${LIVE_ACTIVITY_DEBUG_RECORD_PREFIX}${sanitizeTokenForKey(normalizedToken)}:${sanitizeTokenForKey(normalizedRecordId)}`;
}

function buildLiveActivityDebugDeviceIndexKey(deviceToken) {
  const normalizedToken = String(deviceToken || "").trim();
  if (!normalizedToken) return null;
  return `${LIVE_ACTIVITY_DEBUG_DEVICE_INDEX_PREFIX}${sanitizeTokenForKey(normalizedToken)}`;
}

async function saveLiveActivityDebugRecord(deviceToken, payload = {}) {
  const normalizedToken = String(deviceToken || "").trim();
  if (!normalizedToken) {
    throw new Error("deviceToken is required to save live activity debug history");
  }

  const timestampMs = numericTimestampMs(payload && payload.timestamp_ms);
  const recordId = String(
    payload && (payload.record_id || payload.recordId) ? (payload.record_id || payload.recordId) : randomRecordId()
  ).trim();
  const recordKey = buildLiveActivityDebugRecordKey(normalizedToken, recordId);
  const deviceIndexKey = buildLiveActivityDebugDeviceIndexKey(normalizedToken);
  const record = {
    ...(payload && typeof payload === "object" ? payload : {}),
    record_id: recordId,
    device_token: normalizedToken,
    timestamp_ms: timestampMs,
    timestamp: new Date(timestampMs).toISOString(),
  };

  try {
    const redisClient = await getClient();
    const transaction = redisClient.multi();
    transaction.set(recordKey, JSON.stringify(record), { EX: LIVE_ACTIVITY_DEBUG_HISTORY_TTL_SECONDS });
    transaction.zAdd(deviceIndexKey, [{ score: timestampMs, value: recordKey }]);
    transaction.expire(deviceIndexKey, LIVE_ACTIVITY_DEBUG_HISTORY_TTL_SECONDS);
    await transaction.exec();

    const cutoffMs = pruneCutoffMs(LIVE_ACTIVITY_DEBUG_HISTORY_TTL_SECONDS);
    await pruneIndexEntries(redisClient, deviceIndexKey, cutoffMs);
    return record;
  } catch (error) {
    console.error("[Redis] Error saving live activity debug history:", error);
    throw error;
  }
}

async function getLiveActivityDebugRecords(options = {}) {
  const deviceToken = String(options && options.device_token ? options.device_token : "").trim();
  if (!deviceToken) return [];

  const order = String(options && options.order ? options.order : "desc").trim().toLowerCase() === "asc"
    ? "asc"
    : "desc";
  const limit = parsePositiveIntOrFallback(options && options.limit, 10);

  try {
    const redisClient = await getClient();
    const indexKey = buildLiveActivityDebugDeviceIndexKey(deviceToken);
    if (!indexKey) return [];
    const allRecords = await getHistoryRecordsAll(redisClient, indexKey, "live activity debug");
    const filtered = allRecords.filter((record) => (
      record &&
      typeof record === "object" &&
      String(record.device_token || "").trim() === deviceToken
    ));
    filtered.sort((lhs, rhs) => {
      const left = numericTimestampMs(lhs && lhs.timestamp_ms);
      const right = numericTimestampMs(rhs && rhs.timestamp_ms);
      if (left !== right) return order === "asc" ? left - right : right - left;
      return String(lhs && lhs.record_id ? lhs.record_id : "").localeCompare(
        String(rhs && rhs.record_id ? rhs.record_id : "")
      );
    });
    return limit > 0 ? filtered.slice(0, limit) : filtered;
  } catch (error) {
    console.error("[Redis] Error retrieving live activity debug history:", error);
    return [];
  }
}

function applyHistoryFilters(eventRecordsRaw, notificationRecordsRaw, options = {}) {
  const matchIdFilter = String(options.match_id || "").trim();
  const deviceTokenFilter = String(options.device_token || "").trim();

  const eventRecords = eventRecordsRaw.filter((record) => {
    if (!record || !record.match_id) return false;
    if (matchIdFilter && String(record.match_id) !== matchIdFilter) return false;
    return true;
  });

  const notificationRecords = notificationRecordsRaw.filter((record) => {
    if (!record || !record.match_id) return false;
    if (matchIdFilter && String(record.match_id) !== matchIdFilter) return false;
    if (deviceTokenFilter && String(record.device_token || "") !== deviceTokenFilter) return false;
    return true;
  });

  eventRecords.sort((lhs, rhs) => numericTimestampMs(lhs.timestamp_ms) - numericTimestampMs(rhs.timestamp_ms));
  notificationRecords.sort(
    (lhs, rhs) => numericTimestampMs(lhs.timestamp_ms) - numericTimestampMs(rhs.timestamp_ms)
  );

  return { eventRecords, notificationRecords };
}

function groupHistoryRecordsByMatch(eventRecords, notificationRecords) {
  const grouped = new Map();

  eventRecords.forEach((eventRecord) => {
    const matchId = String(eventRecord.match_id || "").trim() || "unknown";
    if (!grouped.has(matchId)) {
      grouped.set(matchId, buildMatchGroup(matchId, eventRecord.match));
    }
    const matchGroup = grouped.get(matchId);
    if (!matchGroup.home_team && eventRecord.match && eventRecord.match.home_team) {
      matchGroup.home_team = eventRecord.match.home_team;
    }
    if (!matchGroup.away_team && eventRecord.match && eventRecord.match.away_team) {
      matchGroup.away_team = eventRecord.match.away_team;
    }
    if (!matchGroup.league && eventRecord.match && eventRecord.match.league) {
      matchGroup.league = eventRecord.match.league;
    }
    if (!matchGroup.kickoff_date && eventRecord.match && eventRecord.match.date) {
      matchGroup.kickoff_date = eventRecord.match.date;
    }
    if (!matchGroup.kickoff_time && eventRecord.match && eventRecord.match.time) {
      matchGroup.kickoff_time = eventRecord.match.time;
    }
    matchGroup.events.push(eventRecord);
    updateMatchGroupTimestamps(matchGroup, numericTimestampMs(eventRecord.timestamp_ms));
  });

  notificationRecords.forEach((notificationRecord) => {
    const matchId = String(notificationRecord.match_id || "").trim() || "unknown";
    if (!grouped.has(matchId)) {
      grouped.set(matchId, buildMatchGroup(matchId, notificationRecord.match));
    }
    const matchGroup = grouped.get(matchId);
    if (!matchGroup.home_team && notificationRecord.match && notificationRecord.match.home_team) {
      matchGroup.home_team = notificationRecord.match.home_team;
    }
    if (!matchGroup.away_team && notificationRecord.match && notificationRecord.match.away_team) {
      matchGroup.away_team = notificationRecord.match.away_team;
    }
    if (!matchGroup.league && notificationRecord.match && notificationRecord.match.league) {
      matchGroup.league = notificationRecord.match.league;
    }
    if (!matchGroup.kickoff_date && notificationRecord.match && notificationRecord.match.date) {
      matchGroup.kickoff_date = notificationRecord.match.date;
    }
    if (!matchGroup.kickoff_time && notificationRecord.match && notificationRecord.match.time) {
      matchGroup.kickoff_time = notificationRecord.match.time;
    }
    matchGroup.notifications.push(notificationRecord);
    updateMatchGroupTimestamps(matchGroup, numericTimestampMs(notificationRecord.timestamp_ms));
  });

  return Array.from(grouped.values()).sort((lhs, rhs) => {
    const leftTs = Number.isFinite(lhs.last_timestamp_ms) ? lhs.last_timestamp_ms : 0;
    const rightTs = Number.isFinite(rhs.last_timestamp_ms) ? rhs.last_timestamp_ms : 0;
    if (leftTs !== rightTs) return rightTs - leftTs;
    return String(lhs.match_id).localeCompare(String(rhs.match_id));
  });
}

function buildHistoryRetentionPolicy() {
  return {
    event_ttl_seconds: BBC_EVENT_HISTORY_TTL_SECONDS,
    notification_ttl_seconds: BBC_NOTIFICATION_HISTORY_TTL_SECONDS,
    notification_idempotency_ttl_seconds: BBC_NOTIFICATION_IDEMPOTENCY_TTL_SECONDS,
    fantasy_reminder_ttl_seconds: FANTASY_REMINDER_HISTORY_TTL_SECONDS,
    fantasy_reminder_idempotency_ttl_seconds: FANTASY_REMINDER_SEND_IDEMPOTENCY_TTL_SECONDS,
    live_activity_debug_ttl_seconds: LIVE_ACTIVITY_DEBUG_HISTORY_TTL_SECONDS,
    user_preferences_ttl_seconds: USER_PREFERENCES_TTL_SECONDS,
    max_query_window_ms: MAX_BBC_HISTORY_QUERY_MS,
  };
}

function fantasyReminderTimestampMs(value) {
  const direct = Number(value);
  if (Number.isFinite(direct) && direct > 0) return Math.floor(direct);
  const parsed = Date.parse(String(value || "").trim());
  if (Number.isFinite(parsed) && parsed > 0) return Math.floor(parsed);
  return null;
}

function normalizeFantasyReminderStatus(value) {
  const normalized = String(value || "").trim().toLowerCase();
  if (!normalized) return "scheduled";
  return normalized;
}

function buildFantasyReminderRecordKey(reminderId) {
  const normalizedId = String(reminderId || "").trim();
  if (!normalizedId) {
    throw new Error("reminderId is required for fantasy reminder record key");
  }
  return `${FANTASY_REMINDERS_RECORD_PREFIX}${sanitizeTokenForKey(normalizedId)}`;
}

function buildFantasyReminderDeviceIndexKey(deviceToken) {
  const normalizedToken = String(deviceToken || "").trim();
  if (!normalizedToken) return null;
  return `${FANTASY_REMINDERS_DEVICE_INDEX_PREFIX}${sanitizeTokenForKey(normalizedToken)}`;
}

async function saveFantasyReminderRecord(payload, options = {}) {
  const reminderId = String(
    payload && (payload.reminder_id || payload.reminderId) ? (payload.reminder_id || payload.reminderId) : ""
  ).trim();
  if (!reminderId) {
    throw new Error("reminder_id is required to save fantasy reminder record");
  }

  const redisClient = await getClient();
  const recordKey = buildFantasyReminderRecordKey(reminderId);
  const mergeExisting = options && options.mergeExisting !== false;
  const rawExisting = mergeExisting ? await redisClient.get(recordKey) : null;
  const existing = rawExisting ? safeJsonParse(rawExisting, `fantasy reminder ${reminderId}`) : null;

  const deviceToken = String(
    payload && (payload.device_token || payload.deviceToken)
      ? (payload.device_token || payload.deviceToken)
      : existing && existing.device_token
        ? existing.device_token
        : ""
  ).trim();
  const apnsToken = normalizeOptionalToken(
    payload && Object.prototype.hasOwnProperty.call(payload, "apns_token")
      ? payload.apns_token
      : payload && Object.prototype.hasOwnProperty.call(payload, "apnsToken")
        ? payload.apnsToken
        : existing && existing.apns_token
  );
  const scheduledForMs = fantasyReminderTimestampMs(
    payload && Object.prototype.hasOwnProperty.call(payload, "scheduled_for_ms")
      ? payload.scheduled_for_ms
      : payload && Object.prototype.hasOwnProperty.call(payload, "scheduledForMs")
        ? payload.scheduledForMs
        : existing && existing.scheduled_for_ms
  );
  if (!Number.isFinite(scheduledForMs)) {
    throw new Error("scheduled_for_ms is required to save fantasy reminder record");
  }

  const deadlineTimeMs = fantasyReminderTimestampMs(
    payload && Object.prototype.hasOwnProperty.call(payload, "deadline_time_ms")
      ? payload.deadline_time_ms
      : payload && Object.prototype.hasOwnProperty.call(payload, "deadlineTimeMs")
        ? payload.deadlineTimeMs
        : payload && Object.prototype.hasOwnProperty.call(payload, "deadline_time")
          ? payload.deadline_time
          : payload && Object.prototype.hasOwnProperty.call(payload, "deadlineTime")
            ? payload.deadlineTime
            : existing && existing.deadline_time_ms
              ? existing.deadline_time_ms
              : existing && existing.deadline_time
  );
  if (!Number.isFinite(deadlineTimeMs)) {
    throw new Error("deadline_time is required to save fantasy reminder record");
  }

  const nowIso = new Date().toISOString();
  const previousDeviceIndexKey = buildFantasyReminderDeviceIndexKey(existing && existing.device_token);
  const nextDeviceIndexKey = buildFantasyReminderDeviceIndexKey(deviceToken);

  const record = {
    ...(existing && typeof existing === "object" ? existing : {}),
    ...(payload && typeof payload === "object" ? payload : {}),
    reminder_id: reminderId,
    device_token: deviceToken || null,
    apns_token: apnsToken || null,
    scheduled_for_ms: scheduledForMs,
    scheduled_for: new Date(scheduledForMs).toISOString(),
    deadline_time_ms: deadlineTimeMs,
    deadline_time: new Date(deadlineTimeMs).toISOString(),
    status: normalizeFantasyReminderStatus(
      payload && Object.prototype.hasOwnProperty.call(payload, "status")
        ? payload.status
        : existing && existing.status
    ),
    created_at:
      existing && existing.created_at ? String(existing.created_at) : nowIso,
    updated_at: nowIso,
  };

  try {
    const transaction = redisClient.multi();
    transaction.set(recordKey, JSON.stringify(record), { EX: FANTASY_REMINDER_HISTORY_TTL_SECONDS });
    transaction.zAdd(FANTASY_REMINDERS_INDEX_KEY, [{ score: scheduledForMs, value: recordKey }]);
    transaction.expire(FANTASY_REMINDERS_INDEX_KEY, FANTASY_REMINDER_HISTORY_TTL_SECONDS);

    if (previousDeviceIndexKey && previousDeviceIndexKey !== nextDeviceIndexKey) {
      transaction.zRem(previousDeviceIndexKey, recordKey);
    }
    if (nextDeviceIndexKey) {
      transaction.zAdd(nextDeviceIndexKey, [{ score: scheduledForMs, value: recordKey }]);
      transaction.expire(nextDeviceIndexKey, FANTASY_REMINDER_HISTORY_TTL_SECONDS);
    }
    await transaction.exec();

    const cutoffMs = pruneCutoffMs(FANTASY_REMINDER_HISTORY_TTL_SECONDS);
    await Promise.all([
      pruneIndexEntries(redisClient, FANTASY_REMINDERS_INDEX_KEY, cutoffMs),
      nextDeviceIndexKey ? pruneIndexEntries(redisClient, nextDeviceIndexKey, cutoffMs) : Promise.resolve(),
      previousDeviceIndexKey && previousDeviceIndexKey !== nextDeviceIndexKey
        ? pruneIndexEntries(redisClient, previousDeviceIndexKey, cutoffMs)
        : Promise.resolve(),
    ]);

    return record;
  } catch (error) {
    console.error("[Redis] Error saving fantasy reminder record:", error);
    throw error;
  }
}

async function getFantasyReminderRecord(reminderId) {
  const normalizedId = String(reminderId || "").trim();
  if (!normalizedId) return null;

  try {
    const redisClient = await getClient();
    const raw = await redisClient.get(buildFantasyReminderRecordKey(normalizedId));
    if (!raw) return null;
    const parsed = safeJsonParse(raw, `fantasy reminder ${normalizedId}`);
    return parsed && typeof parsed === "object" ? parsed : null;
  } catch (error) {
    console.error("[Redis] Error retrieving fantasy reminder record:", error);
    return null;
  }
}

async function getFantasyReminderRecords(options = {}) {
  const statusFilter = normalizeOptionalToken(options.status);
  const reminderIdFilter = normalizeOptionalToken(options.reminder_id);
  const gameweekIdFilter =
    options && options.gameweek_id !== undefined && options.gameweek_id !== null
      ? String(options.gameweek_id).trim()
      : "";
  const deviceTokenFilter = normalizeOptionalToken(options.device_token);
  const order = String(options.order || "desc").trim().toLowerCase() === "asc" ? "asc" : "desc";
  const limit = parsePositiveIntOrFallback(options.limit, 0);

  try {
    const redisClient = await getClient();
    const indexKey = deviceTokenFilter
      ? buildFantasyReminderDeviceIndexKey(deviceTokenFilter)
      : FANTASY_REMINDERS_INDEX_KEY;
    const records = await getHistoryRecordsAll(redisClient, indexKey, "fantasy reminder");
    const filtered = records.filter((record) => {
      if (!record || typeof record !== "object") return false;
      if (statusFilter && normalizeFantasyReminderStatus(record.status) !== statusFilter) return false;
      if (reminderIdFilter && String(record.reminder_id || "").trim() !== reminderIdFilter) return false;
      if (gameweekIdFilter && String(record.gameweek_id || "").trim() !== gameweekIdFilter) return false;
      if (deviceTokenFilter && String(record.device_token || "").trim() !== deviceTokenFilter) return false;
      return true;
    });

    filtered.sort((lhs, rhs) => {
      const left = fantasyReminderTimestampMs(lhs && lhs.scheduled_for_ms) || 0;
      const right = fantasyReminderTimestampMs(rhs && rhs.scheduled_for_ms) || 0;
      if (left !== right) return order === "asc" ? left - right : right - left;
      return String(lhs && lhs.reminder_id ? lhs.reminder_id : "").localeCompare(
        String(rhs && rhs.reminder_id ? rhs.reminder_id : "")
      );
    });

    return limit > 0 ? filtered.slice(0, limit) : filtered;
  } catch (error) {
    console.error("[Redis] Error retrieving fantasy reminder records:", error);
    return [];
  }
}

function buildFantasyReminderSendIdempotencyKey(reminderId) {
  const normalizedId = String(reminderId || "").trim();
  if (!normalizedId) {
    throw new Error("reminderId is required to build fantasy reminder idempotency key");
  }
  return `${FANTASY_REMINDERS_SEND_IDEMPOTENCY_PREFIX}${hashForRedisKey(normalizedId)}`;
}

async function claimFantasyReminderSendIdempotency(reminderId, options = {}) {
  const normalizedId = String(reminderId || "").trim();
  if (!normalizedId) {
    throw new Error("reminderId is required to claim fantasy reminder idempotency");
  }

  const ttlSeconds = parsePositiveIntOrFallback(
    options && options.ttl_seconds,
    FANTASY_REMINDER_SEND_IDEMPOTENCY_TTL_SECONDS
  );
  const idempotencyKey = buildFantasyReminderSendIdempotencyKey(normalizedId);
  const nowIso = new Date().toISOString();
  const payload = JSON.stringify({
    reminder_id: normalizedId,
    claimed_at: nowIso,
    context: options && options.context ? options.context : null,
  });

  try {
    const redisClient = await getClient();
    const result = await redisClient.set(idempotencyKey, payload, {
      NX: true,
      EX: ttlSeconds,
    });
    return {
      claimed: result === "OK",
      key: idempotencyKey,
      ttl_seconds: ttlSeconds,
      claimed_at: nowIso,
      source: "redis",
    };
  } catch (error) {
    console.warn(
      `[Redis] Fantasy reminder idempotency unavailable for ${normalizedId.slice(0, 80)}...:`,
      error.message || error
    );
    return {
      claimed: true,
      key: null,
      ttl_seconds: ttlSeconds,
      claimed_at: nowIso,
      source: "degraded",
      error: error.message || String(error),
    };
  }
}

function buildOperationalDatasetKey(name) {
  const normalized = String(name || "").trim();
  if (!normalized) {
    throw new Error("Operational dataset name is required");
  }
  return `${OPERATIONAL_DATASET_PREFIX}${sanitizeTokenForKey(normalized)}`;
}

function buildOperationalMatchDetailsKey(matchId) {
  const normalized = String(matchId || "").trim();
  if (!normalized) {
    throw new Error("matchId is required for operational match details key");
  }
  return `${OPERATIONAL_MATCH_DETAILS_PREFIX}${sanitizeTokenForKey(normalized)}`;
}

function normalizeOperationalRecordsInput(recordsById) {
  if (recordsById instanceof Map) {
    return Array.from(recordsById.entries());
  }
  if (Array.isArray(recordsById)) {
    return recordsById
      .filter((entry) => Array.isArray(entry) && entry.length >= 2)
      .map((entry) => [entry[0], entry[1]]);
  }
  if (recordsById && typeof recordsById === "object") {
    return Object.entries(recordsById);
  }
  return [];
}

async function saveOperationalDataset(name, payload, options = {}) {
  try {
    const redisClient = await getClient();
    const key = buildOperationalDatasetKey(name);
    const record = {
      name: String(name || "").trim(),
      updated_at: options.updated_at || new Date().toISOString(),
      source: options.source || null,
      payload,
    };
    const ttlSeconds = Number(options.ttl_seconds);
    if (Number.isFinite(ttlSeconds) && ttlSeconds > 0) {
      await redisClient.set(key, JSON.stringify(record), {
        EX: Math.floor(ttlSeconds),
      });
    } else {
      await redisClient.set(key, JSON.stringify(record));
    }
    return record;
  } catch (error) {
    console.error(`[Redis] Error saving operational dataset ${name}:`, error);
    throw error;
  }
}

async function getOperationalDataset(name) {
  try {
    const redisClient = await getClient();
    const key = buildOperationalDatasetKey(name);
    const raw = await redisClient.get(key);
    if (!raw) return null;
    const parsed = safeJsonParse(raw, `operational dataset ${name}`);
    if (!parsed || typeof parsed !== "object") return null;
    if (!Object.prototype.hasOwnProperty.call(parsed, "payload")) return null;
    return parsed;
  } catch (error) {
    console.error(`[Redis] Error retrieving operational dataset ${name}:`, error);
    return null;
  }
}

async function getOperationalDatasets(names = []) {
  const requestedNames = Array.isArray(names)
    ? names.map((name) => String(name || "").trim()).filter(Boolean)
    : [];
  if (requestedNames.length === 0) return {};

  try {
    const redisClient = await getClient();
    const keys = requestedNames.map((name) => buildOperationalDatasetKey(name));
    const rawValues = await redisClient.mGet(keys);
    const output = {};
    requestedNames.forEach((name, index) => {
      const raw = rawValues[index];
      if (!raw) return;
      const parsed = safeJsonParse(raw, `operational dataset ${name}`);
      if (parsed && typeof parsed === "object" && Object.prototype.hasOwnProperty.call(parsed, "payload")) {
        output[name] = parsed;
      }
    });
    return output;
  } catch (error) {
    console.error("[Redis] Error retrieving operational datasets:", error);
    return {};
  }
}

async function saveOperationalMatchDetailsRecords(recordsById, options = {}) {
  const records = normalizeOperationalRecordsInput(recordsById)
    .map(([matchId, payload]) => [String(matchId || "").trim().toLowerCase(), payload])
    .filter(([matchId, payload]) => Boolean(matchId) && payload && typeof payload === "object");

  const replace = Boolean(options.replace);
  const updatedAt = options.updated_at || new Date().toISOString();

  try {
    const redisClient = await getClient();
    if (records.length === 0) {
      if (!replace) {
        return {
          updated_at: updatedAt,
          upserted: 0,
          removed: 0,
          total: null,
          replace,
        };
      }

      const existingIds = await redisClient.sMembers(OPERATIONAL_MATCH_DETAILS_INDEX_KEY);
      const transactionClear = redisClient.multi();
      existingIds.forEach((matchId) => {
        transactionClear.del(buildOperationalMatchDetailsKey(matchId));
      });
      if (existingIds.length > 0) {
        transactionClear.del(OPERATIONAL_MATCH_DETAILS_INDEX_KEY);
      }
      transactionClear.set(
        OPERATIONAL_MATCH_DETAILS_META_KEY,
        JSON.stringify({
          updated_at: updatedAt,
          source: options.source || null,
          total: 0,
        })
      );
      await transactionClear.exec();
      return {
        updated_at: updatedAt,
        upserted: 0,
        removed: existingIds.length,
        total: 0,
        replace,
      };
    }

    const transaction = redisClient.multi();
    let removed = 0;

    if (replace) {
      const existingIds = await redisClient.sMembers(OPERATIONAL_MATCH_DETAILS_INDEX_KEY);
      const incomingIds = new Set(records.map(([matchId]) => matchId));
      const staleIds = existingIds.filter((matchId) => !incomingIds.has(String(matchId || "")));
      if (staleIds.length > 0) {
        staleIds.forEach((matchId) => {
          const matchKey = buildOperationalMatchDetailsKey(matchId);
          transaction.del(matchKey);
          transaction.sRem(OPERATIONAL_MATCH_DETAILS_INDEX_KEY, matchId);
        });
        removed = staleIds.length;
      }
    }

    records.forEach(([matchId, payload]) => {
      const key = buildOperationalMatchDetailsKey(matchId);
      const normalizedPayload = {
        ...payload,
        id: String(payload.id || matchId).trim().toLowerCase(),
      };
      transaction.set(key, JSON.stringify(normalizedPayload));
      transaction.sAdd(OPERATIONAL_MATCH_DETAILS_INDEX_KEY, normalizedPayload.id);
    });

    transaction.set(
      OPERATIONAL_MATCH_DETAILS_META_KEY,
      JSON.stringify({
        updated_at: updatedAt,
        source: options.source || null,
      })
    );
    await transaction.exec();

    const total = await redisClient.sCard(OPERATIONAL_MATCH_DETAILS_INDEX_KEY);
    await redisClient.set(
      OPERATIONAL_MATCH_DETAILS_META_KEY,
      JSON.stringify({
        updated_at: updatedAt,
        source: options.source || null,
        total: Number(total || 0),
      })
    );

    return {
      updated_at: updatedAt,
      upserted: records.length,
      removed,
      total: Number(total || 0),
      replace,
    };
  } catch (error) {
    console.error("[Redis] Error saving operational match details:", error);
    throw error;
  }
}

async function getOperationalMatchDetails(matchId) {
  const normalized = String(matchId || "").trim().toLowerCase();
  if (!normalized) return null;

  try {
    const redisClient = await getClient();
    const key = buildOperationalMatchDetailsKey(normalized);
    const raw = await redisClient.get(key);
    if (!raw) return null;
    const parsed = safeJsonParse(raw, `operational match details ${normalized}`);
    if (!parsed || typeof parsed !== "object") return null;
    return parsed;
  } catch (error) {
    console.error(`[Redis] Error retrieving operational match details ${normalized}:`, error);
    return null;
  }
}

async function getAllOperationalMatchDetails() {
  try {
    const redisClient = await getClient();
    const ids = await redisClient.sMembers(OPERATIONAL_MATCH_DETAILS_INDEX_KEY);
    if (!Array.isArray(ids) || ids.length === 0) {
      return {
        updated_at: null,
        total: 0,
        records: {},
      };
    }

    const keys = ids.map((matchId) => buildOperationalMatchDetailsKey(matchId));
    const values = await redisClient.mGet(keys);
    const records = {};
    const staleIds = [];
    ids.forEach((matchId, index) => {
      const raw = values[index];
      if (!raw) {
        staleIds.push(matchId);
        return;
      }
      const parsed = safeJsonParse(raw, `operational match details ${matchId}`);
      if (!parsed || typeof parsed !== "object") {
        staleIds.push(matchId);
        return;
      }
      const normalizedId = String(parsed.id || matchId).trim().toLowerCase();
      records[normalizedId] = parsed;
    });

    if (staleIds.length > 0) {
      await redisClient.sRem(OPERATIONAL_MATCH_DETAILS_INDEX_KEY, staleIds);
    }

    const metaRaw = await redisClient.get(OPERATIONAL_MATCH_DETAILS_META_KEY);
    const meta = metaRaw ? safeJsonParse(metaRaw, "operational match details meta") : null;
    return {
      updated_at: meta && meta.updated_at ? meta.updated_at : null,
      total: Object.keys(records).length,
      records,
    };
  } catch (error) {
    console.error("[Redis] Error retrieving all operational match details:", error);
    return {
      updated_at: null,
      total: 0,
      records: {},
      error: error.message || String(error),
    };
  }
}

async function getOperationalMatchDetailsSummary() {
  try {
    const redisClient = await getClient();
    const [total, metaRaw] = await Promise.all([
      redisClient.sCard(OPERATIONAL_MATCH_DETAILS_INDEX_KEY),
      redisClient.get(OPERATIONAL_MATCH_DETAILS_META_KEY),
    ]);
    const meta = metaRaw ? safeJsonParse(metaRaw, "operational match details meta") : null;
    return {
      total: Number(total || 0),
      updated_at: meta && meta.updated_at ? meta.updated_at : null,
      source: meta && meta.source ? meta.source : null,
    };
  } catch (error) {
    console.error("[Redis] Error retrieving operational match details summary:", error);
    return {
      total: 0,
      updated_at: null,
      source: null,
      error: error.message || String(error),
    };
  }
}

function sanitizeMatchIdList(matchIds) {
  if (!Array.isArray(matchIds)) return [];
  const unique = [];
  const seen = new Set();
  matchIds.forEach((value) => {
    const normalized = String(value || "").trim();
    if (!normalized || seen.has(normalized)) return;
    seen.add(normalized);
    unique.push(normalized);
  });
  return unique;
}

async function getBbcMatchHistoryGrouped(options = {}) {
  const range = normalizeTimeRange(options.start_ms, options.end_ms);

  try {
    const redisClient = await getClient();

    const [eventRecordsRaw, notificationRecordsRaw] = await Promise.all([
      getHistoryRecordsByRange(
        redisClient,
        BBC_EVENTS_INDEX_KEY,
        range.startMs,
        range.endMs,
        "event"
      ),
      getHistoryRecordsByRange(
        redisClient,
        BBC_NOTIFICATIONS_INDEX_KEY,
        range.startMs,
        range.endMs,
        "notification"
      ),
    ]);

    const filtered = applyHistoryFilters(eventRecordsRaw, notificationRecordsRaw, options);
    const matches = groupHistoryRecordsByMatch(filtered.eventRecords, filtered.notificationRecords);

    return {
      start_ms: range.startMs,
      end_ms: range.endMs,
      count_matches: matches.length,
      count_events: filtered.eventRecords.length,
      count_notifications: filtered.notificationRecords.length,
      matches,
    };
  } catch (error) {
    console.error("[Redis] Error retrieving grouped BBC match history:", error);
    return {
      start_ms: range.startMs,
      end_ms: range.endMs,
      count_matches: 0,
      count_events: 0,
      count_notifications: 0,
      matches: [],
      error: error.message,
    };
  }
}

async function getBbcRealtimeSnapshot(options = {}) {
  const matchIdFilter = String(options.match_id || "").trim();
  const deviceTokenFilter = String(options.device_token || "").trim();
  const limitMatches = parsePositiveIntOrFallback(options.limit_matches, 0);
  const nowIso = new Date().toISOString();

  try {
    const redisClient = await getClient();
    const [eventRecordsRaw, notificationRecordsRaw] = await Promise.all([
      getHistoryRecordsAll(redisClient, BBC_EVENTS_INDEX_KEY, "event"),
      getHistoryRecordsAll(redisClient, BBC_NOTIFICATIONS_INDEX_KEY, "notification"),
    ]);

    const filtered = applyHistoryFilters(eventRecordsRaw, notificationRecordsRaw, {
      match_id: matchIdFilter,
      device_token: deviceTokenFilter,
    });
    const groupedMatches = groupHistoryRecordsByMatch(
      filtered.eventRecords,
      filtered.notificationRecords
    );
    const limitedMatches =
      limitMatches > 0 ? groupedMatches.slice(0, limitMatches) : groupedMatches;

    const [eventsIndexTtl, notificationsIndexTtl, eventIndexEntries, notificationIndexEntries] =
      await Promise.all([
        redisClient.ttl(BBC_EVENTS_INDEX_KEY),
        redisClient.ttl(BBC_NOTIFICATIONS_INDEX_KEY),
        redisClient.zCard(BBC_EVENTS_INDEX_KEY),
        redisClient.zCard(BBC_NOTIFICATIONS_INDEX_KEY),
      ]);

    const [preferenceKeyCount, idempotencyKeyCount] = await Promise.all([
      countKeysByPattern(redisClient, `${USER_PREFERENCES_PREFIX}*`),
      countKeysByPattern(redisClient, `${BBC_NOTIFICATION_IDEMPOTENCY_PREFIX}*`),
    ]);

    return {
      generated_at: nowIso,
      filters: {
        match_id: matchIdFilter || null,
        device_token: deviceTokenFilter || null,
        limit_matches: limitMatches > 0 ? limitMatches : null,
      },
      count_matches: limitedMatches.length,
      count_events: filtered.eventRecords.length,
      count_notifications: filtered.notificationRecords.length,
      count_matches_total: groupedMatches.length,
      key_metrics: {
        preferences_keys: preferenceKeyCount,
        idempotency_keys: idempotencyKeyCount,
        events_index_entries: Number(eventIndexEntries || 0),
        notifications_index_entries: Number(notificationIndexEntries || 0),
      },
      key_ttl_seconds: {
        events_index: Number(eventsIndexTtl),
        notifications_index: Number(notificationsIndexTtl),
      },
      retention_policy: buildHistoryRetentionPolicy(),
      matches: limitedMatches,
    };
  } catch (error) {
    console.error("[Redis] Error building realtime BBC snapshot:", error);
    return {
      generated_at: nowIso,
      filters: {
        match_id: matchIdFilter || null,
        device_token: deviceTokenFilter || null,
        limit_matches: limitMatches > 0 ? limitMatches : null,
      },
      count_matches: 0,
      count_events: 0,
      count_notifications: 0,
      count_matches_total: 0,
      key_metrics: {
        preferences_keys: 0,
        idempotency_keys: 0,
        events_index_entries: 0,
        notifications_index_entries: 0,
      },
      key_ttl_seconds: {
        events_index: -2,
        notifications_index: -2,
      },
      retention_policy: buildHistoryRetentionPolicy(),
      matches: [],
      error: error.message,
    };
  }
}

async function cleanupBbcHistory(options = {}) {
  const matchIdsFilter = sanitizeMatchIdList(options.match_ids || []);
  const deviceTokenFilter = String(options.device_token || "").trim();
  const includeEvents = !deviceTokenFilter || matchIdsFilter.length > 0;
  const hasRange =
    Number.isFinite(Number(options.start_ms)) || Number.isFinite(Number(options.end_ms));
  const range = hasRange ? normalizeTimeRange(options.start_ms, options.end_ms) : null;
  const dryRun = Boolean(options.dry_run);

  try {
    const redisClient = await getClient();
    const [eventRecordsRaw, notificationRecordsRaw] = await Promise.all([
      range
        ? getHistoryRecordsByRange(
            redisClient,
            BBC_EVENTS_INDEX_KEY,
            range.startMs,
            range.endMs,
            "event"
          )
        : getHistoryRecordsAll(redisClient, BBC_EVENTS_INDEX_KEY, "event"),
      range
        ? getHistoryRecordsByRange(
            redisClient,
            BBC_NOTIFICATIONS_INDEX_KEY,
            range.startMs,
            range.endMs,
            "notification"
          )
        : getHistoryRecordsAll(redisClient, BBC_NOTIFICATIONS_INDEX_KEY, "notification"),
    ]);

    const matchIdSet = new Set(matchIdsFilter);
    const filterByMatchIds = matchIdSet.size > 0;
    const filteredEvents = includeEvents
      ? eventRecordsRaw.filter((record) => {
          const matchId = String(record && record.match_id ? record.match_id : "").trim();
          if (!matchId) return false;
          if (filterByMatchIds && !matchIdSet.has(matchId)) return false;
          return true;
        })
      : [];

    const filteredNotifications = notificationRecordsRaw.filter((record) => {
      const matchId = String(record && record.match_id ? record.match_id : "").trim();
      if (!matchId) return false;
      if (filterByMatchIds && !matchIdSet.has(matchId)) return false;
      if (deviceTokenFilter && String(record.device_token || "") !== deviceTokenFilter) return false;
      return true;
    });

    const eventRecordKeys = [];
    const eventKeysByMatch = new Map();
    filteredEvents.forEach((record) => {
      const matchId = String(record.match_id || "").trim();
      const eventId = String(record.event_id || "").trim();
      if (!matchId || !eventId) return;
      const key =
        `${BBC_EVENTS_RECORD_PREFIX}${sanitizeTokenForKey(matchId)}:${eventId}`;
      eventRecordKeys.push(key);
      if (!eventKeysByMatch.has(matchId)) eventKeysByMatch.set(matchId, []);
      eventKeysByMatch.get(matchId).push(key);
    });

    const notificationRecordKeys = [];
    const notificationKeysByMatch = new Map();
    const notificationKeysByMatchDevice = new Map();
    filteredNotifications.forEach((record) => {
      const matchId = String(record.match_id || "").trim();
      const notificationId = String(record.notification_id || "").trim();
      const deviceToken = String(record.device_token || "").trim();
      if (!matchId || !notificationId) return;
      const key =
        `${BBC_NOTIFICATIONS_RECORD_PREFIX}${sanitizeTokenForKey(matchId)}:${notificationId}`;
      notificationRecordKeys.push(key);
      if (!notificationKeysByMatch.has(matchId)) notificationKeysByMatch.set(matchId, []);
      notificationKeysByMatch.get(matchId).push(key);
      if (deviceToken) {
        const composite = `${matchId}::${deviceToken}`;
        if (!notificationKeysByMatchDevice.has(composite)) {
          notificationKeysByMatchDevice.set(composite, []);
        }
        notificationKeysByMatchDevice.get(composite).push(key);
      }
    });

    const summary = {
      dry_run: dryRun,
      filters: {
        match_ids: matchIdsFilter,
        device_token: deviceTokenFilter || null,
        include_events: includeEvents,
        start_ms: range ? range.startMs : null,
        end_ms: range ? range.endMs : null,
      },
      matched: {
        events: filteredEvents.length,
        notifications: filteredNotifications.length,
      },
      deleted: {
        events: 0,
        notifications: 0,
      },
    };

    if (dryRun) {
      return summary;
    }

    const transaction = redisClient.multi();

    if (eventRecordKeys.length > 0) {
      transaction.del(eventRecordKeys);
      transaction.zRem(BBC_EVENTS_INDEX_KEY, eventRecordKeys);
      eventKeysByMatch.forEach((keys, matchId) => {
        const matchIndexKey = `${BBC_EVENTS_MATCH_INDEX_PREFIX}${sanitizeTokenForKey(matchId)}`;
        transaction.zRem(matchIndexKey, keys);
      });
    }

    if (notificationRecordKeys.length > 0) {
      transaction.del(notificationRecordKeys);
      transaction.zRem(BBC_NOTIFICATIONS_INDEX_KEY, notificationRecordKeys);
      notificationKeysByMatch.forEach((keys, matchId) => {
        const matchIndexKey =
          `${BBC_NOTIFICATIONS_MATCH_INDEX_PREFIX}${sanitizeTokenForKey(matchId)}`;
        transaction.zRem(matchIndexKey, keys);
      });
      notificationKeysByMatchDevice.forEach((keys, composite) => {
        const [matchId, deviceToken] = composite.split("::");
        const matchDeviceIndexKey =
          `${BBC_NOTIFICATIONS_MATCH_DEVICE_INDEX_PREFIX}` +
          `${sanitizeTokenForKey(matchId)}:${sanitizeTokenForKey(deviceToken)}`;
        transaction.zRem(matchDeviceIndexKey, keys);
      });
    }

    await transaction.exec();

    summary.deleted.events = eventRecordKeys.length;
    summary.deleted.notifications = notificationRecordKeys.length;
    return summary;
  } catch (error) {
    console.error("[Redis] Error cleaning BBC history:", error);
    return {
      dry_run: dryRun,
      filters: {
        match_ids: matchIdsFilter,
        device_token: deviceTokenFilter || null,
        include_events: includeEvents,
        start_ms: range ? range.startMs : null,
        end_ms: range ? range.endMs : null,
      },
      matched: {
        events: 0,
        notifications: 0,
      },
      deleted: {
        events: 0,
        notifications: 0,
      },
      error: error.message || String(error),
    };
  }
}

async function closeRedisConnection() {
  if (client && isConnected) {
    await client.quit();
    console.log("[Redis] Connection closed");
    isConnected = false;
  }
}

module.exports = {
  getClient,
  saveUserPreferences,
  updateUserLiveActivityState,
  getUserPreferences,
  deleteUserPreferences,
  getAllUserPreferences,
  saveFantasyReminderRecord,
  getFantasyReminderRecord,
  getFantasyReminderRecords,
  saveLiveActivityDebugRecord,
  getLiveActivityDebugRecords,
  saveBbcMatchEventHistory,
  saveBbcNotificationHistory,
  claimFantasyReminderSendIdempotency,
  claimBbcNotificationIdempotency,
  getBbcMatchHistoryGrouped,
  getBbcRealtimeSnapshot,
  cleanupBbcHistory,
  saveOperationalDataset,
  getOperationalDataset,
  getOperationalDatasets,
  saveOperationalMatchDetailsRecords,
  getOperationalMatchDetails,
  getAllOperationalMatchDetails,
  getOperationalMatchDetailsSummary,
  closeRedisConnection,
  __historyConfig: buildHistoryRetentionPolicy(),
  __private: {
    sanitizeTokenForKey,
    normalizeTimeRange,
    shortDeviceToken,
    normalizeFantasyReminderStatus,
    buildLiveActivityDebugRecordKey,
    buildLiveActivityDebugDeviceIndexKey,
    buildFantasyReminderRecordKey,
    buildFantasyReminderSendIdempotencyKey,
    buildBbcNotificationIdempotencyKey,
    countKeysByPattern,
  },
};
