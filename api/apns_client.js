const apn = require("@parse/node-apn");
const path = require("path");
const fs = require("fs");

// APNS Configuration
const APNS_KEY_ID = "UQ2DV6UTF4";
const APNS_TEAM_ID = "SJ8X4DLAN9";
const APNS_KEY_PATH = path.join(__dirname, "certs", "APNS_AuthKey_SkyNoLimit_SandboxAndProd.p8");
const APNS_TOPIC = "topscores.dev.skynolimit";
const APNS_LIVE_ACTIVITY_TOPIC = `${APNS_TOPIC}.push-type.liveactivity`;

// Validate that the APNS key file exists
if (!fs.existsSync(APNS_KEY_PATH)) {
  console.error(`[APNS] ERROR: APNS key file not found at ${APNS_KEY_PATH}`);
}

let productionProvider = null;
let developmentProvider = null;

function createProvider(production) {
  return new apn.Provider({
    token: {
      key: APNS_KEY_PATH,
      keyId: APNS_KEY_ID,
      teamId: APNS_TEAM_ID,
    },
    production,
  });
}

function environmentLabel(isDevelopmentBuild) {
  return isDevelopmentBuild ? "sandbox" : "production";
}

function getProvider(isDevelopmentBuild) {
  if (isDevelopmentBuild) {
    if (!developmentProvider) {
      developmentProvider = createProvider(false);
      console.log("[APNS] Development (sandbox) provider initialized");
    }
    return developmentProvider;
  }

  if (!productionProvider) {
    productionProvider = createProvider(true);
    console.log("[APNS] Production provider initialized");
  }
  return productionProvider;
}

function getProductionProvider() {
  return getProvider(false);
}

function getDevelopmentProvider() {
  return getProvider(true);
}

async function resetProvider(isDevelopmentBuild, reason = "") {
  const environment = environmentLabel(isDevelopmentBuild);
  const provider = isDevelopmentBuild ? developmentProvider : productionProvider;
  if (!provider) return;

  try {
    await provider.shutdown();
  } catch (error) {
    console.warn(`[APNS] Provider shutdown during reset failed (${environment}):`, error.message || error);
  }

  if (isDevelopmentBuild) {
    developmentProvider = null;
  } else {
    productionProvider = null;
  }

  const reasonSuffix = reason ? ` reason=${reason}` : "";
  console.warn(`[APNS] Reset ${environment} provider${reasonSuffix}`);
}

function lowerText(value) {
  return String(value || "").toLowerCase();
}

function isRetriableTransportError(errorLike) {
  const aggregate = [
    errorLike && errorLike.code ? String(errorLike.code) : "",
    errorLike && errorLike.message ? String(errorLike.message) : "",
    String(errorLike || ""),
  ]
    .join(" ")
    .toLowerCase();

  return (
    aggregate.includes("err_http2_stream_cancel") ||
    aggregate.includes("pending stream has been canceled") ||
    aggregate.includes("etimedout") ||
    aggregate.includes("timeout") ||
    aggregate.includes("econnreset") ||
    aggregate.includes("ehostunreach") ||
    aggregate.includes("enetunreach") ||
    aggregate.includes("eai_again") ||
    aggregate.includes("socket hang up")
  );
}

function extractFailure(result) {
  if (!result || !Array.isArray(result.failed) || result.failed.length === 0) {
    return null;
  }
  return result.failed[0];
}

function extractFailureError(failure) {
  const reason = failure && failure.response ? failure.response.reason : failure && failure.error;
  if (reason && reason.message) return reason.message;
  return String(reason || "unknown");
}

function isRetriableFailure(failure) {
  if (failure && failure.response && failure.response.reason) {
    return false;
  }
  return isRetriableTransportError(failure && failure.error ? failure.error : failure);
}

function isTerminalApnsReason(errorText) {
  const normalized = lowerText(errorText);
  return (
    normalized.includes("baddevicetoken") ||
    normalized.includes("unregistered") ||
    normalized.includes("device token not for topic")
  );
}

async function sendWithSingleRetry({ isDevelopmentBuild, sendOperation, contextLabel }) {
  const environment = environmentLabel(isDevelopmentBuild);

  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const provider = getProvider(isDevelopmentBuild);

    try {
      const result = await sendOperation(provider);
      const failure = extractFailure(result);
      if (!failure) {
        return { success: true, result };
      }

      if (attempt === 1 && isRetriableFailure(failure)) {
        console.warn(
          `[APNS] Retrying ${contextLabel} (${environment}) after transport failure: ${extractFailureError(
            failure
          )}`
        );
        await resetProvider(isDevelopmentBuild, "retry_after_failed_result");
        continue;
      }

      return { success: false, failure };
    } catch (error) {
      if (attempt === 1 && isRetriableTransportError(error)) {
        console.warn(
          `[APNS] Retrying ${contextLabel} (${environment}) after transport exception: ${
            error.message || error
          }`
        );
        await resetProvider(isDevelopmentBuild, "retry_after_exception");
        continue;
      }

      return { success: false, error };
    }
  }

  return {
    success: false,
    error: new Error("APNS send exhausted retries"),
  };
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

  const environment = environmentLabel(isDevelopmentBuild);

  const notification = new apn.Notification();
  notification.alert = {
    title: title,
    body: body,
  };
  notification.topic = APNS_TOPIC;
  notification.sound = "default";
  notification.badge = 1;
  notification.payload = data;

  const sendResult = await sendWithSingleRetry({
    isDevelopmentBuild,
    contextLabel: "notification",
    sendOperation: (provider) => provider.send(notification, deviceToken),
  });

  if (!sendResult.success) {
    if (sendResult.failure) {
      const reason = sendResult.failure.response
        ? sendResult.failure.response.reason
        : sendResult.failure.error;
      const errorText = extractFailureError(sendResult.failure);
      console.error(`[APNS] Failed to send notification (${environment}):`, reason);
      return {
        success: false,
        error: errorText,
        environment,
        isTerminal: isTerminalApnsReason(errorText),
      };
    }

    const error = sendResult.error || new Error("unknown");
    console.error(`[APNS] Error sending notification (${environment}):`, error);
    return {
      success: false,
      error: error.message || String(error),
      environment,
      isTerminal: false,
    };
  }

  const result = sendResult.result;
  console.log(
    `[APNS] Successfully sent notification (${environment}): "${title}" to ${deviceToken.substring(0, 12)}...`
  );
  return {
    success: true,
    sent: result.sent.length,
    environment,
  };
}

/**
 * Send a Live Activity push payload (start/update/end).
 * @param {object} options
 * @param {string} options.token APNS push-to-start token (start) or activity push token (update/end)
 * @param {"start"|"update"|"end"} options.event
 * @param {object} options.contentState Codable content-state payload
 * @param {string} [options.attributesType] Required for "start"
 * @param {object} [options.attributes] Required for "start"
 * @param {object} [options.alert] Optional alert payload for start
 * @param {number} [options.timestamp] Unix timestamp seconds
 * @param {number} [options.staleDate] Unix timestamp seconds
 * @param {number} [options.dismissalDate] Unix timestamp seconds (for end)
 * @param {boolean} [options.isDevelopmentBuild]
 * @returns {Promise<object>}
 */
async function sendLiveActivityPush(options = {}) {
  const token = typeof options.token === "string" ? options.token.trim() : "";
  const event = typeof options.event === "string" ? options.event.trim().toLowerCase() : "";
  const isDevelopmentBuild = Boolean(options.isDevelopmentBuild);
  const environment = environmentLabel(isDevelopmentBuild);

  if (!token) {
    throw new Error("Live Activity token is required");
  }
  if (!["start", "update", "end"].includes(event)) {
    throw new Error(`Invalid Live Activity event: ${event || "missing"}`);
  }

  const aps = {
    timestamp: Number.isFinite(Number(options.timestamp))
      ? Math.floor(Number(options.timestamp))
      : Math.floor(Date.now() / 1000),
    event,
  };

  if (options.contentState && typeof options.contentState === "object") {
    aps["content-state"] = options.contentState;
  }
  if (Number.isFinite(Number(options.staleDate))) {
    aps["stale-date"] = Math.floor(Number(options.staleDate));
  }
  if (event === "start") {
    const attributesType = String(options.attributesType || "").trim();
    if (!attributesType) {
      throw new Error("Live Activity start requires attributesType");
    }
    if (!options.attributes || typeof options.attributes !== "object") {
      throw new Error("Live Activity start requires attributes");
    }
    aps["attributes-type"] = attributesType;
    aps.attributes = options.attributes;
    if (options.alert && typeof options.alert === "object") {
      aps.alert = options.alert;
    }
  }
  if (event === "end" && Number.isFinite(Number(options.dismissalDate))) {
    aps["dismissal-date"] = Math.floor(Number(options.dismissalDate));
  }

  const notification = new apn.Notification();
  notification.topic = APNS_LIVE_ACTIVITY_TOPIC;
  notification.pushType = "liveactivity";
  notification.priority = 10;
  notification.rawPayload = { aps };

  const sendResult = await sendWithSingleRetry({
    isDevelopmentBuild,
    contextLabel: `live_activity_${event}`,
    sendOperation: (provider) => provider.send(notification, token),
  });

  if (!sendResult.success) {
    if (sendResult.failure) {
      const reason = sendResult.failure.response
        ? sendResult.failure.response.reason
        : sendResult.failure.error;
      const errorText = extractFailureError(sendResult.failure);
      console.error(`[APNS] Failed Live Activity push (${environment}, event=${event}):`, reason);
      return {
        success: false,
        error: errorText,
        environment,
        event,
        isTerminal: isTerminalApnsReason(errorText),
      };
    }

    const error = sendResult.error || new Error("unknown");
    console.error(`[APNS] Error sending Live Activity push (${environment}, event=${event}):`, error);
    return {
      success: false,
      error: error.message || String(error),
      environment,
      event,
      isTerminal: false,
    };
  }

  const result = sendResult.result;
  console.log(
    `[APNS] Live Activity push sent (${environment}, event=${event}) to ${token.substring(0, 12)}...`
  );
  return {
    success: true,
    sent: result.sent.length,
    environment,
    event,
  };
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
    productionProvider = null;
  }
  if (developmentProvider) {
    promises.push(developmentProvider.shutdown());
    console.log("[APNS] Development provider shutdown");
    developmentProvider = null;
  }
  await Promise.all(promises);
}

module.exports = {
  sendNotification,
  sendNotificationToMultipleDevices,
  sendLiveActivityPush,
  shutdown,
};
