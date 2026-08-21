"use strict";

const BSD_HTTP_REQUEST_DURATION_BUCKETS = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 30];
const BSD_HTTP_SLOW_REQUEST_WINDOW_MS = Number(
  process.env.BSD_HTTP_SLOW_REQUEST_WINDOW_MS || 6 * 60 * 60 * 1000
);
const BSD_HTTP_TOP_URL_COUNT_LIMIT = Number(process.env.BSD_HTTP_TOP_URL_COUNT_LIMIT || 100);
const BSD_HTTP_TIMEOUT_URL_LIMIT = Number(process.env.BSD_HTTP_TIMEOUT_URL_LIMIT || 100);
const BSD_HTTP_SLOW_URL_P95_LIMIT = Number(
  process.env.BSD_HTTP_SLOW_URL_P95_LIMIT || 100
);
const BSD_HTTP_SLOW_URL_MAX_LIMIT = Number(
  process.env.BSD_HTTP_SLOW_URL_MAX_LIMIT || 20
);

const bsdHttpRequestMetrics = new Map();
const bsdHttpTimeoutMetrics = new Map();
const bsdHttpRequestDurationMetrics = new Map();
let bsdHttpRecentRequests = [];

function escapePrometheusLabel(value) {
  return String(value || "")
    .replace(/\\/g, "\\\\")
    .replace(/\n/g, "\\n")
    .replace(/"/g, '\\"');
}

function metricLabelKey(labels) {
  return Object.keys(labels)
    .sort()
    .map((key) => `${key}:${labels[key]}`)
    .join("|");
}

function parseMetricLabelKey(key) {
  return String(key || "")
    .split("|")
    .filter(Boolean)
    .reduce((labels, pair) => {
      const separatorIndex = pair.indexOf(":");
      if (separatorIndex <= 0) return labels;
      const labelKey = pair.slice(0, separatorIndex);
      const labelValue = pair.slice(separatorIndex + 1);
      labels[labelKey] = labelValue;
      return labels;
    }, {});
}

function formatPrometheusLabels(labels) {
  return Object.keys(labels)
    .sort()
    .map((key) => `${key}="${escapePrometheusLabel(labels[key])}"`)
    .join(",");
}

function pushPrometheusSample(lines, metricName, value, labels = null) {
  const normalizedValue = Number.isFinite(value) ? value : 0;
  if (labels && Object.keys(labels).length > 0) {
    lines.push(`${metricName}{${formatPrometheusLabels(labels)}} ${normalizedValue}`);
    return;
  }
  lines.push(`${metricName} ${normalizedValue}`);
}

function recordHistogramSample(map, labels, value, bucketBoundaries) {
  const normalizedValue = Number.isFinite(value) && value >= 0 ? value : 0;
  const key = metricLabelKey(labels);
  if (!map.has(key)) {
    map.set(key, {
      labels: { ...labels },
      count: 0,
      sum: 0,
      bucketCounts: bucketBoundaries.map(() => 0),
    });
  }

  const entry = map.get(key);
  entry.count += 1;
  entry.sum += normalizedValue;
  bucketBoundaries.forEach((boundary, index) => {
    if (normalizedValue <= boundary) {
      entry.bucketCounts[index] += 1;
    }
  });
}

function appendHistogramMetrics(lines, metricName, helpText, bucketBoundaries, entries) {
  lines.push(`# HELP ${metricName} ${helpText}`);
  lines.push(`# TYPE ${metricName} histogram`);
  entries.forEach((entry) => {
    bucketBoundaries.forEach((boundary, index) => {
      pushPrometheusSample(lines, `${metricName}_bucket`, entry.bucketCounts[index], {
        ...entry.labels,
        le: String(boundary),
      });
    });
    pushPrometheusSample(lines, `${metricName}_bucket`, entry.count, {
      ...entry.labels,
      le: "+Inf",
    });
    pushPrometheusSample(lines, `${metricName}_sum`, entry.sum, entry.labels);
    pushPrometheusSample(lines, `${metricName}_count`, entry.count, entry.labels);
  });
}

function percentileFromSorted(values, percentile) {
  if (!Array.isArray(values) || values.length === 0) return 0;
  const normalizedPercentile = Math.min(1, Math.max(0, Number(percentile) || 0));
  const index = Math.min(
    values.length - 1,
    Math.max(0, Math.ceil(normalizedPercentile * values.length) - 1)
  );
  return values[index];
}

function pruneRecentRequests(nowMs = Date.now()) {
  const windowMs =
    Number.isFinite(BSD_HTTP_SLOW_REQUEST_WINDOW_MS) && BSD_HTTP_SLOW_REQUEST_WINDOW_MS > 0
      ? BSD_HTTP_SLOW_REQUEST_WINDOW_MS
      : 6 * 60 * 60 * 1000;
  const cutoffMs = nowMs - windowMs;
  if (bsdHttpRecentRequests.length === 0) return;
  if (bsdHttpRecentRequests[0].timestampMs >= cutoffMs) return;
  bsdHttpRecentRequests = bsdHttpRecentRequests.filter((entry) => entry.timestampMs >= cutoffMs);
}

function buildTopUrlRows(nowMs = Date.now()) {
  pruneRecentRequests(nowMs);
  const grouped = new Map();

  bsdHttpRecentRequests.forEach((entry) => {
    const labels = {
      source: entry.source,
      status_code: entry.statusCode,
      url: entry.url,
    };
    const key = metricLabelKey(labels);
    if (!grouped.has(key)) {
      grouped.set(key, {
        labels,
        durations: [],
        count: 0,
        timeoutCount: 0,
        maxSeconds: 0,
        maxTimestampSeconds: 0,
      });
    }
    const row = grouped.get(key);
    row.count += 1;
    if (entry.errorCode === "ETIMEDOUT") row.timeoutCount += 1;
    row.durations.push(entry.durationSeconds);
    if (entry.durationSeconds >= row.maxSeconds) {
      row.maxSeconds = entry.durationSeconds;
      row.maxTimestampSeconds = entry.timestampMs / 1000;
    }
  });

  const rows = Array.from(grouped.values()).map((row) => {
    row.durations.sort((lhs, rhs) => lhs - rhs);
    return {
      labels: row.labels,
      count: row.count,
      timeoutCount: row.timeoutCount,
      p95Seconds: percentileFromSorted(row.durations, 0.95),
      maxSeconds: row.maxSeconds,
      maxTimestampSeconds: row.maxTimestampSeconds,
    };
  });

  const countLimit = Math.max(1, Number(BSD_HTTP_TOP_URL_COUNT_LIMIT) || 100);
  const timeoutLimit = Math.max(1, Number(BSD_HTTP_TIMEOUT_URL_LIMIT) || 100);
  const p95Limit = Math.max(1, Number(BSD_HTTP_SLOW_URL_P95_LIMIT) || 100);
  const maxLimit = Math.max(1, Number(BSD_HTTP_SLOW_URL_MAX_LIMIT) || 20);
  return {
    countRows: rows
      .slice()
      .sort((lhs, rhs) => rhs.count - lhs.count)
      .slice(0, countLimit),
    timeoutRows: rows
      .filter((row) => row.timeoutCount > 0)
      .slice()
      .sort((lhs, rhs) => rhs.timeoutCount - lhs.timeoutCount)
      .slice(0, timeoutLimit)
      .map((row) => ({
        ...row,
        count: row.timeoutCount,
        labels: {
          source: row.labels.source,
          error_code: "ETIMEDOUT",
          url: row.labels.url,
        },
      })),
    p95Rows: rows
      .slice()
      .sort((lhs, rhs) => rhs.p95Seconds - lhs.p95Seconds)
      .slice(0, p95Limit),
    maxRows: rows
      .slice()
      .sort((lhs, rhs) => rhs.maxSeconds - lhs.maxSeconds)
      .slice(0, maxLimit),
  };
}

function trackRequestMetric({
  source,
  url,
  statusCode,
  errorCode,
  durationMs,
  timestampMs,
}) {
  const normalizedSource = String(source || "bsd_unknown").trim() || "bsd_unknown";
  const normalizedStatusCode =
    Number.isFinite(Number(statusCode)) && Number(statusCode) >= 0
      ? String(Math.floor(Number(statusCode)))
      : "0";
  const normalizedUrl = String(url || "").trim();
  const normalizedDurationMs =
    Number.isFinite(Number(durationMs)) && Number(durationMs) >= 0
      ? Math.round(Number(durationMs))
      : null;
  const normalizedTimestampMs =
    Number.isFinite(Number(timestampMs)) && Number(timestampMs) > 0
      ? Math.floor(Number(timestampMs))
      : Date.now();
  const normalizedErrorCode = String(errorCode || "").trim().toUpperCase();

  const requestLabels = {
    source: normalizedSource,
    status_code: normalizedStatusCode,
  };
  const requestKey = metricLabelKey(requestLabels);
  bsdHttpRequestMetrics.set(requestKey, (bsdHttpRequestMetrics.get(requestKey) || 0) + 1);

  if (normalizedErrorCode === "ETIMEDOUT") {
    const timeoutLabels = {
      source: normalizedSource,
      error_code: normalizedErrorCode,
    };
    const timeoutKey = metricLabelKey(timeoutLabels);
    bsdHttpTimeoutMetrics.set(timeoutKey, (bsdHttpTimeoutMetrics.get(timeoutKey) || 0) + 1);
  }

  if (!normalizedUrl || normalizedDurationMs === null) return;

  recordHistogramSample(
    bsdHttpRequestDurationMetrics,
    requestLabels,
    normalizedDurationMs / 1000,
    BSD_HTTP_REQUEST_DURATION_BUCKETS
  );

  bsdHttpRecentRequests.push({
    source: normalizedSource,
    statusCode: normalizedStatusCode,
    errorCode: normalizedErrorCode || null,
    url: normalizedUrl,
    durationSeconds: normalizedDurationMs / 1000,
    timestampMs: normalizedTimestampMs,
  });
  pruneRecentRequests(normalizedTimestampMs);
}

function appendPrometheusMetrics(lines, nowMs = Date.now()) {
  lines.push("# HELP top_scores_bsd_http_requests_total Total number of BSD upstream HTTP requests by source and response code.");
  lines.push("# TYPE top_scores_bsd_http_requests_total counter");
  Array.from(bsdHttpRequestMetrics.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([key, count]) => {
      pushPrometheusSample(lines, "top_scores_bsd_http_requests_total", count, parseMetricLabelKey(key));
    });

  lines.push("# HELP top_scores_bsd_http_timeouts_total Total number of BSD upstream HTTP requests that timed out.");
  lines.push("# TYPE top_scores_bsd_http_timeouts_total counter");
  Array.from(bsdHttpTimeoutMetrics.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([key, count]) => {
      pushPrometheusSample(lines, "top_scores_bsd_http_timeouts_total", count, parseMetricLabelKey(key));
    });

  const durationEntries = Array.from(bsdHttpRequestDurationMetrics.values()).sort((lhs, rhs) =>
    metricLabelKey(lhs.labels).localeCompare(metricLabelKey(rhs.labels))
  );
  appendHistogramMetrics(
    lines,
    "top_scores_bsd_http_request_duration_seconds",
    "Duration of BSD upstream HTTP requests in seconds by source and response code.",
    BSD_HTTP_REQUEST_DURATION_BUCKETS,
    durationEntries
  );

  const topUrlRows = buildTopUrlRows(nowMs);
  lines.push("# HELP top_scores_bsd_http_top_url_requests Requests observed for top recent BSD HTTP URL rows over the process rolling window.");
  lines.push("# TYPE top_scores_bsd_http_top_url_requests gauge");
  topUrlRows.countRows.forEach((entry) => {
    pushPrometheusSample(lines, "top_scores_bsd_http_top_url_requests", entry.count, entry.labels);
  });

  lines.push("# HELP top_scores_bsd_http_timeout_url_requests Timeout requests observed for top recent BSD HTTP URL rows over the process rolling window.");
  lines.push("# TYPE top_scores_bsd_http_timeout_url_requests gauge");
  topUrlRows.timeoutRows.forEach((entry) => {
    pushPrometheusSample(lines, "top_scores_bsd_http_timeout_url_requests", entry.count, entry.labels);
  });

  lines.push("# HELP top_scores_bsd_http_slow_url_p95_seconds Top recent BSD HTTP URL p95 durations in seconds over the process rolling window.");
  lines.push("# TYPE top_scores_bsd_http_slow_url_p95_seconds gauge");
  topUrlRows.p95Rows.forEach((entry) => {
    pushPrometheusSample(lines, "top_scores_bsd_http_slow_url_p95_seconds", entry.p95Seconds, entry.labels);
  });

  lines.push("# HELP top_scores_bsd_http_slow_url_max_seconds Top recent BSD HTTP URL max durations in seconds over the process rolling window.");
  lines.push("# TYPE top_scores_bsd_http_slow_url_max_seconds gauge");
  topUrlRows.maxRows.forEach((entry) => {
    pushPrometheusSample(lines, "top_scores_bsd_http_slow_url_max_seconds", entry.maxSeconds, entry.labels);
  });

  lines.push("# HELP top_scores_bsd_http_slow_url_max_timestamp_seconds Timestamp of the max request for top recent BSD HTTP URLs over the process rolling window.");
  lines.push("# TYPE top_scores_bsd_http_slow_url_max_timestamp_seconds gauge");
  topUrlRows.maxRows.forEach((entry) => {
    pushPrometheusSample(
      lines,
      "top_scores_bsd_http_slow_url_max_timestamp_seconds",
      entry.maxTimestampSeconds,
      entry.labels
    );
  });
}

function buildPrometheusMetricsText(options = {}) {
  const lines = [];
  if (options.runtime || options.service) {
    lines.push("# HELP top_scores_runtime_info Runtime identity.");
    lines.push("# TYPE top_scores_runtime_info gauge");
    pushPrometheusSample(lines, "top_scores_runtime_info", 1, {
      runtime: options.runtime || "bsd_poller",
      service: options.service || "top-scores-bsd-poller",
    });
  }
  appendPrometheusMetrics(lines, options.nowMs || Date.now());
  return `${lines.join("\n")}\n`;
}

function resetForTests() {
  bsdHttpRequestMetrics.clear();
  bsdHttpTimeoutMetrics.clear();
  bsdHttpRequestDurationMetrics.clear();
  bsdHttpRecentRequests = [];
}

module.exports = {
  trackRequestMetric,
  appendPrometheusMetrics,
  buildPrometheusMetricsText,
  __private: {
    resetForTests,
    buildTopUrlRows,
    metricLabelKey,
  },
};
