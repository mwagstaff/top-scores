"use strict";

function normalizeMetricLabel(value, fallback = "unknown") {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 64);
  return normalized || fallback;
}

function metricLabelKey(labels) {
  return Object.keys(labels)
    .sort()
    .map((key) => `${key}:${labels[key]}`)
    .join("|");
}

function buildTypeLabel(isDevelopmentBuild) {
  return isDevelopmentBuild ? "development" : "production";
}

function incrementCounter(map, labels, amount = 1) {
  const key = metricLabelKey(labels);
  if (!map.has(key)) {
    map.set(key, {
      labels: { ...labels },
      count: 0,
    });
  }
  map.get(key).count += amount;
}

function recordGaugeStats(map, labels, value) {
  const normalizedValue = Number.isFinite(value) && value >= 0 ? value : 0;
  const key = metricLabelKey(labels);
  if (!map.has(key)) {
    map.set(key, {
      labels: { ...labels },
      min: normalizedValue,
      max: normalizedValue,
      sum: 0,
      count: 0,
    });
  }

  const entry = map.get(key);
  entry.min = Math.min(entry.min, normalizedValue);
  entry.max = Math.max(entry.max, normalizedValue);
  entry.sum += normalizedValue;
  entry.count += 1;
}

const activeActivitiesByDeviceToken = new Map();
const liveActivityPushCounters = new Map();
const liveActivityStartCounters = new Map();
const liveActivityEndCounters = new Map();
const liveActivityPayloadStats = new Map();

function recordPush({ event, status, isDevelopmentBuild }) {
  incrementCounter(
    liveActivityPushCounters,
    {
      event: normalizeMetricLabel(event),
      status: normalizeMetricLabel(status),
      build_type: buildTypeLabel(Boolean(isDevelopmentBuild)),
    },
    1
  );
}

function recordStart({ isDevelopmentBuild }) {
  incrementCounter(
    liveActivityStartCounters,
    { build_type: buildTypeLabel(Boolean(isDevelopmentBuild)) },
    1
  );
}

function recordEnd({ isDevelopmentBuild, reason }) {
  incrementCounter(
    liveActivityEndCounters,
    {
      build_type: buildTypeLabel(Boolean(isDevelopmentBuild)),
      reason: normalizeMetricLabel(reason, "unknown"),
    },
    1
  );
}

function recordPayloadSample({ event, isDevelopmentBuild, kind, bytes }) {
  recordGaugeStats(liveActivityPayloadStats, {
    event: normalizeMetricLabel(event),
    build_type: buildTypeLabel(Boolean(isDevelopmentBuild)),
    kind: normalizeMetricLabel(kind),
  }, bytes);
}

function markActivityActive({ deviceToken, activityId, isDevelopmentBuild }) {
  const normalizedDeviceToken = String(deviceToken || "").trim();
  if (!normalizedDeviceToken) {
    return { changed: false, previous: null, current: null };
  }

  const current = {
    activityId: String(activityId || "").trim() || "unknown",
    buildType: buildTypeLabel(Boolean(isDevelopmentBuild)),
  };
  const previous = activeActivitiesByDeviceToken.get(normalizedDeviceToken) || null;
  const changed = !previous ||
    previous.activityId !== current.activityId ||
    previous.buildType !== current.buildType;

  activeActivitiesByDeviceToken.set(normalizedDeviceToken, current);
  return { changed, previous, current };
}

function markActivityInactive({ deviceToken }) {
  const normalizedDeviceToken = String(deviceToken || "").trim();
  if (!normalizedDeviceToken) return null;
  const previous = activeActivitiesByDeviceToken.get(normalizedDeviceToken) || null;
  if (previous) {
    activeActivitiesByDeviceToken.delete(normalizedDeviceToken);
  }
  return previous;
}

function appendPrometheusMetrics(lines, pushPrometheusSample) {
  const activeCountsByBuildType = new Map();
  activeActivitiesByDeviceToken.forEach(({ buildType }) => {
    activeCountsByBuildType.set(buildType, (activeCountsByBuildType.get(buildType) || 0) + 1);
  });

  lines.push("# HELP top_scores_live_activity_active Active live activities currently known to the server.");
  lines.push("# TYPE top_scores_live_activity_active gauge");
  ["development", "production"].forEach((buildType) => {
    pushPrometheusSample(lines, "top_scores_live_activity_active", activeCountsByBuildType.get(buildType) || 0, {
      build_type: buildType,
    });
  });

  lines.push("# HELP top_scores_live_activity_pushes_total Total live activity push and confirmation events.");
  lines.push("# TYPE top_scores_live_activity_pushes_total counter");
  Array.from(liveActivityPushCounters.values())
    .sort((lhs, rhs) => metricLabelKey(lhs.labels).localeCompare(metricLabelKey(rhs.labels)))
    .forEach((entry) => {
      pushPrometheusSample(lines, "top_scores_live_activity_pushes_total", entry.count, entry.labels);
    });

  lines.push("# HELP top_scores_live_activity_starts_total Total successful live activity starts.");
  lines.push("# TYPE top_scores_live_activity_starts_total counter");
  Array.from(liveActivityStartCounters.values())
    .sort((lhs, rhs) => metricLabelKey(lhs.labels).localeCompare(metricLabelKey(rhs.labels)))
    .forEach((entry) => {
      pushPrometheusSample(lines, "top_scores_live_activity_starts_total", entry.count, entry.labels);
    });

  lines.push("# HELP top_scores_live_activity_ends_total Total live activity end transitions by reason.");
  lines.push("# TYPE top_scores_live_activity_ends_total counter");
  Array.from(liveActivityEndCounters.values())
    .sort((lhs, rhs) => metricLabelKey(lhs.labels).localeCompare(metricLabelKey(rhs.labels)))
    .forEach((entry) => {
      pushPrometheusSample(lines, "top_scores_live_activity_ends_total", entry.count, entry.labels);
    });

  lines.push("# HELP top_scores_live_activity_payload_size_bytes_min Minimum observed live activity payload size in bytes.");
  lines.push("# TYPE top_scores_live_activity_payload_size_bytes_min gauge");
  lines.push("# HELP top_scores_live_activity_payload_size_bytes_max Maximum observed live activity payload size in bytes.");
  lines.push("# TYPE top_scores_live_activity_payload_size_bytes_max gauge");
  lines.push("# HELP top_scores_live_activity_payload_size_bytes_avg Average observed live activity payload size in bytes.");
  lines.push("# TYPE top_scores_live_activity_payload_size_bytes_avg gauge");
  lines.push("# HELP top_scores_live_activity_payload_samples_total Total observed live activity payload samples.");
  lines.push("# TYPE top_scores_live_activity_payload_samples_total counter");
  Array.from(liveActivityPayloadStats.values())
    .sort((lhs, rhs) => metricLabelKey(lhs.labels).localeCompare(metricLabelKey(rhs.labels)))
    .forEach((entry) => {
      pushPrometheusSample(lines, "top_scores_live_activity_payload_size_bytes_min", entry.min, entry.labels);
      pushPrometheusSample(lines, "top_scores_live_activity_payload_size_bytes_max", entry.max, entry.labels);
      pushPrometheusSample(
        lines,
        "top_scores_live_activity_payload_size_bytes_avg",
        entry.count > 0 ? entry.sum / entry.count : 0,
        entry.labels
      );
      pushPrometheusSample(
        lines,
        "top_scores_live_activity_payload_samples_total",
        entry.count,
        entry.labels
      );
    });
}

module.exports = {
  appendPrometheusMetrics,
  buildTypeLabel,
  markActivityActive,
  markActivityInactive,
  recordEnd,
  recordPayloadSample,
  recordPush,
  recordStart,
};
