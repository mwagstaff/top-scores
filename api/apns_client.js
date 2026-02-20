const apn = require("@parse/node-apn");
const path = require("path");
const fs = require("fs");

// APNS Configuration
const APNS_KEY_ID = "UQ2DV6UTF4";
const APNS_TEAM_ID = "SJ8X4DLAN9";
const APNS_KEY_PATH = path.join(__dirname, "certs", "APNS_AuthKey_SkyNoLimit_SandboxAndProd.p8");
const APNS_TOPIC = "topscores.dev.skynolimit"; // Replace with your actual bundle ID

// Validate that the APNS key file exists
if (!fs.existsSync(APNS_KEY_PATH)) {
  console.error(`[APNS] ERROR: APNS key file not found at ${APNS_KEY_PATH}`);
}

// Create APNS providers (one for production, one for development)
let productionProvider = null;
let developmentProvider = null;

function getProductionProvider() {
  if (!productionProvider) {
    productionProvider = new apn.Provider({
      token: {
        key: APNS_KEY_PATH,
        keyId: APNS_KEY_ID,
        teamId: APNS_TEAM_ID,
      },
      production: true,
    });
    console.log("[APNS] Production provider initialized");
  }
  return productionProvider;
}

function getDevelopmentProvider() {
  if (!developmentProvider) {
    developmentProvider = new apn.Provider({
      token: {
        key: APNS_KEY_PATH,
        keyId: APNS_KEY_ID,
        teamId: APNS_TEAM_ID,
      },
      production: false,
    });
    console.log("[APNS] Development (sandbox) provider initialized");
  }
  return developmentProvider;
}

/**
 * Send a push notification to a device
 * @param {string} deviceToken - The APNS device token
 * @param {string} title - Notification title
 * @param {string} body - Notification body
 * @param {object} data - Additional data payload
 * @param {boolean} isDevelopmentBuild - Whether to use sandbox or production APNS
 * @returns {Promise<object>} - Result of the send operation
 */
async function sendNotification(deviceToken, title, body, data = {}, isDevelopmentBuild = false) {
  if (!deviceToken) {
    throw new Error("Device token is required");
  }

  const provider = isDevelopmentBuild ? getDevelopmentProvider() : getProductionProvider();
  const environment = isDevelopmentBuild ? "sandbox" : "production";

  const notification = new apn.Notification();
  notification.alert = {
    title: title,
    body: body,
  };
  notification.topic = APNS_TOPIC;
  notification.sound = "default";
  notification.badge = 1;
  notification.payload = data;

  try {
    const result = await provider.send(notification, deviceToken);

    if (result.failed && result.failed.length > 0) {
      const failure = result.failed[0];
      console.error(
        `[APNS] Failed to send notification (${environment}):`,
        failure.response ? failure.response.reason : failure.error
      );
      return {
        success: false,
        error: failure.response ? failure.response.reason : failure.error.message,
        environment,
      };
    }

    console.log(
      `[APNS] Successfully sent notification (${environment}): "${title}" to ${deviceToken.substring(0, 12)}...`
    );
    return {
      success: true,
      sent: result.sent.length,
      environment,
    };
  } catch (error) {
    console.error(`[APNS] Error sending notification (${environment}):`, error);
    return {
      success: false,
      error: error.message,
      environment,
    };
  }
}

/**
 * Send notifications to multiple devices
 * @param {Array<{deviceToken: string, isDevelopmentBuild: boolean}>} devices - Array of device info
 * @param {string} title - Notification title
 * @param {string} body - Notification body
 * @param {object} data - Additional data payload
 * @returns {Promise<object>} - Results of the send operations
 */
async function sendNotificationToMultipleDevices(devices, title, body, data = {}) {
  const results = {
    success: 0,
    failed: 0,
    errors: [],
  };

  const promises = devices.map(async (device) => {
    try {
      const result = await sendNotification(
        device.deviceToken,
        title,
        body,
        data,
        device.isDevelopmentBuild
      );
      if (result.success) {
        results.success++;
      } else {
        results.failed++;
        results.errors.push({
          deviceToken: device.deviceToken.substring(0, 12) + "...",
          error: result.error,
        });
      }
    } catch (error) {
      results.failed++;
      results.errors.push({
        deviceToken: device.deviceToken.substring(0, 12) + "...",
        error: error.message,
      });
    }
  });

  await Promise.all(promises);
  return results;
}

/**
 * Shutdown APNS providers
 */
async function shutdown() {
  const promises = [];
  if (productionProvider) {
    promises.push(productionProvider.shutdown());
    console.log("[APNS] Production provider shutdown");
  }
  if (developmentProvider) {
    promises.push(developmentProvider.shutdown());
    console.log("[APNS] Development provider shutdown");
  }
  await Promise.all(promises);
}

module.exports = {
  sendNotification,
  sendNotificationToMultipleDevices,
  shutdown,
};
