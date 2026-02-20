const { createClient } = require("redis");

const REDIS_HOST = process.env.REDIS_HOST || "127.0.0.1";
const REDIS_PORT = process.env.REDIS_PORT || 6379;
const REDIS_DB = process.env.REDIS_DB || 0;
const REDIS_PASSWORD = process.env.REDIS_PASSWORD || undefined;

const DB_NAME = "top_scores";
const USER_PREFERENCES_PREFIX = `${DB_NAME}:user_preferences:`;

let client = null;
let isConnected = false;

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
  });

  await client.connect();
  return client;
}

async function saveUserPreferences(deviceToken, preferences, apnsToken = null, isDevelopmentBuild = false) {
  if (!deviceToken || typeof deviceToken !== "string" || !deviceToken.trim()) {
    throw new Error("Invalid device token");
  }

  const normalizedToken = deviceToken.trim();
  const key = `${USER_PREFERENCES_PREFIX}${normalizedToken}`;

  const data = {
    deviceToken: normalizedToken,
    apnsToken: apnsToken ? apnsToken.trim() : null,
    isDevelopmentBuild: isDevelopmentBuild,
    preferences: preferences || {},
    updatedAt: new Date().toISOString(),
  };

  try {
    const redisClient = await getClient();
    await redisClient.set(key, JSON.stringify(data));
    console.log(`[Redis] Saved preferences for device: ${normalizedToken.substring(0, 12)}... (APNS: ${apnsToken ? 'Yes' : 'No'}, Dev: ${isDevelopmentBuild})`);
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

    // Use KEYS command for simplicity (acceptable for small datasets)
    // For production with many keys, consider SCAN with proper cursor handling
    const keys = await redisClient.keys(pattern);

    if (keys.length === 0) {
      return [];
    }

    // Fetch all preference values in parallel
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
  getUserPreferences,
  deleteUserPreferences,
  getAllUserPreferences,
  closeRedisConnection,
};
