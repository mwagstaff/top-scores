#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require("fs");
const path = require("path");
const v8 = require("v8");
const { monitorEventLoopDelay } = require("perf_hooks");
const express = require("express");
const { SERVER_CONFIG } = require("./config");
const {
  DEFAULT_URL,
  DEFAULT_OUTPUT,
  fetchMatches,
  writeMatches,
} = require("./fetch_live_footballontv");
const {
  DEFAULT_BBC_URL,
  DEFAULT_BBC_OUTPUT,
  DEFAULT_BBC_MATCH_TIMEZONE,
  DEFAULT_BBC_RANGE_PAST_DAYS,
  DEFAULT_BBC_RANGE_FUTURE_DAYS,
  DEFAULT_BBC_RANGE_CONCURRENCY,
  fetchBbcFixtures,
  fetchBbcScoresFixturesByDateRange,
  fetchBbcMatchByDetailsUrl,
  writeBbcFixtures,
} = require("./fetch_bbc_scores");
const {
  DEFAULT_BBC_TABLES_URL,
  DEFAULT_BBC_PREMIER_LEAGUE_OUTPUT,
  fetchPremierLeagueTeams,
  writePremierLeagueTeams,
} = require("./fetch_bbc_premier_league_table");
const {
  LEAGUE_TABLE_SOURCES,
  DEFAULT_BBC_LEAGUE_TABLES_OUTPUT,
  fetchLeagueTables,
  writeLeagueTables,
} = require("./fetch_bbc_league_tables");
const testMatchState = require("./test_match_state");

const PORT = Number(process.env.PORT || 3011);
const SOURCE_URL = process.env.SOURCE_URL || DEFAULT_URL;
const OUTPUT_PATH = process.env.OUTPUT_PATH || DEFAULT_OUTPUT;
const INTERVAL_MINUTES = Number(process.env.UPDATE_INTERVAL_MINUTES || 30);
const INTERVAL_MS = Number(process.env.UPDATE_INTERVAL_MS || INTERVAL_MINUTES * 60 * 1000);

const BBC_SOURCE_URL = process.env.BBC_SOURCE_URL || DEFAULT_BBC_URL;
const BBC_OUTPUT_PATH = process.env.BBC_OUTPUT_PATH || DEFAULT_BBC_OUTPUT;
const BBC_INTERVAL_MS = Number(process.env.BBC_UPDATE_INTERVAL_MS || 30 * 1000);
const BBC_RANGE_BASE_URL = process.env.BBC_RANGE_BASE_URL || DEFAULT_BBC_URL;
const BBC_RANGE_OUTPUT_PATH =
  process.env.BBC_RANGE_OUTPUT_PATH || path.join(__dirname, "bbc_scores_fixtures_matches.json");
const parsedBbcRangePastDays = Number(process.env.BBC_RANGE_PAST_DAYS || DEFAULT_BBC_RANGE_PAST_DAYS);
const BBC_RANGE_PAST_DAYS = Number.isFinite(parsedBbcRangePastDays)
  ? Math.max(0, Math.floor(parsedBbcRangePastDays))
  : DEFAULT_BBC_RANGE_PAST_DAYS;
const parsedBbcRangeFutureDays = Number(
  process.env.BBC_RANGE_FUTURE_DAYS || DEFAULT_BBC_RANGE_FUTURE_DAYS
);
const BBC_RANGE_FUTURE_DAYS = Number.isFinite(parsedBbcRangeFutureDays)
  ? Math.max(0, Math.floor(parsedBbcRangeFutureDays))
  : DEFAULT_BBC_RANGE_FUTURE_DAYS;
const parsedBbcRangeConcurrency = Number(
  process.env.BBC_RANGE_CONCURRENCY || DEFAULT_BBC_RANGE_CONCURRENCY
);
const BBC_RANGE_CONCURRENCY = Number.isFinite(parsedBbcRangeConcurrency)
  ? Math.max(1, Math.floor(parsedBbcRangeConcurrency))
  : DEFAULT_BBC_RANGE_CONCURRENCY;
const BBC_RANGE_MATCH_TIMEZONE = process.env.BBC_RANGE_MATCH_TIMEZONE || DEFAULT_BBC_MATCH_TIMEZONE;
const BBC_RANGE_INTERVAL_HOURS = Number(process.env.BBC_RANGE_INTERVAL_HOURS || 1);
const BBC_RANGE_INTERVAL_MS = Number(
  process.env.BBC_RANGE_INTERVAL_MS || BBC_RANGE_INTERVAL_HOURS * 60 * 60 * 1000
);

const EPL_SOURCE_URL = process.env.EPL_SOURCE_URL || DEFAULT_BBC_TABLES_URL;
const EPL_OUTPUT_PATH = process.env.EPL_OUTPUT_PATH || DEFAULT_BBC_PREMIER_LEAGUE_OUTPUT;
const EPL_INTERVAL_HOURS = Number(process.env.EPL_UPDATE_INTERVAL_HOURS || 24);
const EPL_INTERVAL_MS = Number(
  process.env.EPL_UPDATE_INTERVAL_MS || EPL_INTERVAL_HOURS * 60 * 60 * 1000
);
const parsedEplTeamMinConfidence = Number(process.env.EPL_TEAM_MIN_CONFIDENCE || 0.82);
const EPL_TEAM_MIN_CONFIDENCE = Number.isFinite(parsedEplTeamMinConfidence)
  ? Math.min(1, Math.max(0, parsedEplTeamMinConfidence))
  : 0.82;
const LEAGUE_TABLES_OUTPUT_PATH =
  process.env.LEAGUE_TABLES_OUTPUT_PATH || DEFAULT_BBC_LEAGUE_TABLES_OUTPUT;
const parsedLeagueTablesIntervalMs = Number(
  process.env.LEAGUE_TABLES_UPDATE_INTERVAL_MS || 2 * 60 * 1000
);
const LEAGUE_TABLES_INTERVAL_MS = Number.isFinite(parsedLeagueTablesIntervalMs)
  ? Math.max(15 * 1000, Math.floor(parsedLeagueTablesIntervalMs))
  : 2 * 60 * 1000;
const RECENT_OUTPUT_PATH =
  process.env.RECENT_OUTPUT_PATH || path.join(__dirname, "recent_matches.json");
const MISSING_TEAM_LOGOS_OUTPUT_PATH =
  process.env.MISSING_TEAM_LOGOS_OUTPUT_PATH || path.join(__dirname, "missing_team_logos.json");
const RECENT_CACHE_HOURS = Number(process.env.RECENT_CACHE_HOURS || 24);
const RECENT_CACHE_MS = Number.isFinite(RECENT_CACHE_HOURS)
  ? RECENT_CACHE_HOURS * 60 * 60 * 1000
  : 24 * 60 * 60 * 1000;
const parsedMatchDetailsPollIntervalMs = Number(
  process.env.MATCH_DETAILS_POLL_INTERVAL_MS || 10 * 1000
);
const MATCH_DETAILS_POLL_INTERVAL_MS = Number.isFinite(parsedMatchDetailsPollIntervalMs)
  ? Math.max(1000, Math.floor(parsedMatchDetailsPollIntervalMs))
  : 10 * 1000;
const parsedMatchDetailsPollConcurrency = Number(
  process.env.MATCH_DETAILS_POLL_CONCURRENCY || 20
);
const MATCH_DETAILS_POLL_CONCURRENCY = Number.isFinite(parsedMatchDetailsPollConcurrency)
  ? Math.max(1, Math.floor(parsedMatchDetailsPollConcurrency))
  : 20;
const parsedMatchDetailsBackfillBatchSize = Number(
  process.env.MATCH_DETAILS_BACKFILL_BATCH_SIZE || 50
);
const MATCH_DETAILS_BACKFILL_BATCH_SIZE = Number.isFinite(parsedMatchDetailsBackfillBatchSize)
  ? Math.max(1, Math.floor(parsedMatchDetailsBackfillBatchSize))
  : 50;
const parsedMatchDetailsStaleInProgressMs = Number(
  process.env.MATCH_DETAILS_STALE_IN_PROGRESS_MS || 20 * 60 * 1000
);
const MATCH_DETAILS_STALE_IN_PROGRESS_MS = Number.isFinite(parsedMatchDetailsStaleInProgressMs)
  ? Math.max(60 * 1000, Math.floor(parsedMatchDetailsStaleInProgressMs))
  : 20 * 60 * 1000;
const parsedMatchDetailsStaleMinuteThreshold = Number(
  process.env.MATCH_DETAILS_STALE_MINUTE_THRESHOLD || 90
);
const MATCH_DETAILS_STALE_MINUTE_THRESHOLD = Number.isFinite(parsedMatchDetailsStaleMinuteThreshold)
  ? Math.max(1, Math.floor(parsedMatchDetailsStaleMinuteThreshold))
  : 90;

const app = express();
const API_PREFIX = "/api/v1";
const APP_DATA_SOURCE = "redis-operational";
const DEVICE_TOKEN_HEADER = "x-device-token";
const parsedAppMetricsActiveWindowHours = Number(
  process.env.APP_METRICS_ACTIVE_DEVICE_WINDOW_HOURS || 24 * 30
);
const APP_METRICS_ACTIVE_DEVICE_WINDOW_MS = Number.isFinite(parsedAppMetricsActiveWindowHours)
  ? Math.max(1, Math.floor(parsedAppMetricsActiveWindowHours)) * 60 * 60 * 1000
  : 30 * 24 * 60 * 60 * 1000;
app.use(express.json({ limit: "64kb" }));

const appUsageMetrics = {
  apiRequestsTotal: 0,
  apiRequestsWithDeviceTokenTotal: 0,
  apiRequestsWithoutDeviceTokenTotal: 0,
  appMetricEventsTotal: 0,
  appMetricEventsRejectedTotal: 0,
};
const appMetricEventsByDimension = new Map();
const seenDeviceTokens = new Set();
const deviceLastSeenAtMs = new Map();
let appMetricEventsLastUpdated = null;
const PROCESS_START_TIME_SECONDS = Math.floor(Date.now() / 1000);
const PROCESS_CPU_USAGE_START = process.cpuUsage();
const HTTP_REQUEST_DURATION_BUCKETS = [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5];
const SOURCE_FETCH_DURATION_BUCKETS = [0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10];
const UNIQUE_USER_WINDOWS = [
  { period: "1m", windowMs: 60 * 1000 },
  { period: "5m", windowMs: 5 * 60 * 1000 },
  { period: "1h", windowMs: 60 * 60 * 1000 },
  { period: "1d", windowMs: 24 * 60 * 60 * 1000 },
  { period: "1w", windowMs: 7 * 24 * 60 * 60 * 1000 },
  { period: "30d", windowMs: 30 * 24 * 60 * 60 * 1000 },
];
const httpRequestMetrics = new Map();
const sourceFetchMetrics = new Map();
const sourceRecordsFetchedTotalBySource = new Map();
const sourceCacheSizeBySource = new Map();
const sourceLastSuccessAtSeconds = new Map();
const SOURCE_LIVE_FOOTBALL = "live_football_on_tv";
const SOURCE_BBC_LIVE = "bbc_live_scores";
const SOURCE_BBC_RANGE = "bbc_scores_fixtures_range";
const SOURCE_BBC_PREMIER_LEAGUE = "bbc_premier_league_table";
const SOURCE_BBC_LEAGUE_TABLES = "bbc_league_tables";
const SOURCE_BBC_MATCH_DETAILS = "bbc_match_details";
const SOURCE_RECENT_CACHE = "recent_matches_cache";
const OP_DATASET_LIVE_MATCHES = "live_matches";
const OP_DATASET_BBC_LIVE_MATCHES = "bbc_live_matches";
const OP_DATASET_BBC_RANGE_MATCHES = "bbc_range_matches";
const OP_DATASET_RECENT_MATCHES = "recent_matches";
const OP_DATASET_MERGED_MATCHES = "merged_matches";
const OP_DATASET_PREMIER_LEAGUE_TEAMS = "premier_league_teams";
const OP_DATASET_LEAGUE_TABLES = "league_tables";
const OP_DATASET_MISSING_TEAM_LOGOS = "missing_team_logos";
const eventLoopDelayMonitor = monitorEventLoopDelay({ resolution: 20 });
eventLoopDelayMonitor.enable();

app.use((req, res, next) => {
  const isApiPath = req.path.startsWith(API_PREFIX);
  if (isApiPath) {
    const deviceToken = normalizeDeviceToken(req.get(DEVICE_TOKEN_HEADER));
    req.deviceToken = deviceToken || null;
    appUsageMetrics.apiRequestsTotal += 1;
    if (req.deviceToken) {
      appUsageMetrics.apiRequestsWithDeviceTokenTotal += 1;
      trackSeenDeviceToken(req.deviceToken);
    } else {
      appUsageMetrics.apiRequestsWithoutDeviceTokenTotal += 1;
    }
  } else {
    req.deviceToken = null;
  }

  const requestId = Math.random().toString(36).slice(2, 10);
  const startedAtMs = Date.now();
  res.set("X-Request-Id", requestId);
  res.on("finish", () => {
    const durationMs = Date.now() - startedAtMs;
    const route = normalizeHttpRouteLabel(req);
    if (route !== "/metrics") {
      recordHistogramSample(
        httpRequestMetrics,
        {
          method: req.method,
          route,
          status_code: String(res.statusCode || 0),
        },
        durationMs / 1000,
        HTTP_REQUEST_DURATION_BUCKETS
      );
    }

    if (isApiPath) {
      console.log(
        `[api] id=${requestId} method=${req.method} path=${req.originalUrl} status=${res.statusCode} duration_ms=${durationMs} device_token=${req.deviceToken ? "present" : "missing"}`
      );
    }
  });
  next();
});

let cachedMatches = [];
let lastUpdated = null;
let updating = false;
let cachedBbcMatches = [];
let bbcLastUpdated = null;
let bbcUpdating = false;
let cachedBbcRangeMatches = [];
let bbcRangeLastUpdated = null;
let bbcRangeUpdating = false;
let cachedMergedMatches = [];
let cachedRecentMatches = [];
let recentLastUpdated = null;
let cachedPremierLeagueTeams = [];
let eplLastUpdated = null;
let eplUpdating = false;
let cachedLeagueTables = [];
let leagueTablesLastUpdated = null;
let leagueTablesUpdating = false;
let matchDetailsById = new Map();
let matchDetailsLastUpdated = null;
let matchDetailsUpdating = false;
let missingTeamLogosByKey = new Map();
let missingTeamLogosLastUpdated = null;

const STAGE_PATTERNS = [
  /\s*[-:–]\s*Round\s+\w+$/i,
  /\s+\w+\s+Round$/i,
  /\s+Round\s+\w+$/i,
  /\s+Round\s+\d+$/i,
  /\s+Round\s+of\s+\d+$/i,
  /\s+Last\s+\d+$/i,
  /\s+Group\s+Stage$/i,
  /\s+Group\s+[A-Z]$/i,
  /\s+Quarter[- ]Finals?$/i,
  /\s+Semi[- ]Finals?$/i,
  /\s+Finals?$/i,
  /\s+Third[- ]Place\s+Play-?Off$/i,
  /\s+Play-?Offs?$/i,
  /\s+Qualifying$/i,
  /\s+Qualification$/i,
  /\s+Preliminary\s+Round$/i,
  /\s+First\s+Leg$/i,
  /\s+Second\s+Leg$/i,
  /\s+1st\s+Leg$/i,
  /\s+2nd\s+Leg$/i,
  /\s+Leg\s+\d+$/i,
];

function normalizeLeagueName(name) {
  if (!name) return name;
  let normalized = String(name).replace(/\s+/g, " ").trim();
  let changed = true;
  while (changed) {
    changed = false;
    for (const pattern of STAGE_PATTERNS) {
      if (pattern.test(normalized)) {
        normalized = normalized.replace(pattern, "").trim();
        normalized = normalized.replace(/[-:–]\s*$/, "").trim();
        changed = true;
      }
    }
  }
  return normalized;
}

const LEAGUE_TABLE_ID_ALIASES = {
  "uefa-champions-league": "champions-league",
  "uefa-europa-league": "europa-league",
  "uefa-conference-league": "europa-conference-league",
  "uefa-europa-conference-league": "europa-conference-league",
  championsip: "championship",
};

function normalizeLeagueTableId(value) {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  if (!normalized) return "";
  return LEAGUE_TABLE_ID_ALIASES[normalized] || normalized;
}

function leagueTableRowsCount(tables) {
  if (!Array.isArray(tables)) return 0;
  return tables.reduce((total, league) => {
    const rows = Array.isArray(league && league.rows) ? league.rows.length : 0;
    return total + rows;
  }, 0);
}

function sortLeagueTablesForResponse(tables) {
  if (!Array.isArray(tables)) return [];
  const order = new Map(LEAGUE_TABLE_SOURCES.map((source, index) => [source.id, index]));
  return [...tables].sort((left, right) => {
    const leftId = normalizeLeagueTableId(left && left.league_id);
    const rightId = normalizeLeagueTableId(right && right.league_id);
    const leftOrder = order.has(leftId) ? order.get(leftId) : Number.MAX_SAFE_INTEGER;
    const rightOrder = order.has(rightId) ? order.get(rightId) : Number.MAX_SAFE_INTEGER;
    if (leftOrder !== rightOrder) return leftOrder - rightOrder;
    const leftName = String((left && left.league_name) || "");
    const rightName = String((right && right.league_name) || "");
    return leftName.localeCompare(rightName);
  });
}

function findLeagueTableById(tables, leagueId) {
  const normalizedId = normalizeLeagueTableId(leagueId);
  if (!normalizedId || !Array.isArray(tables)) return null;
  return (
    tables.find((table) => normalizeLeagueTableId(table && table.league_id) === normalizedId) ||
    null
  );
}

function extractPremierLeagueTeamsFromTables(tables) {
  const premier = findLeagueTableById(tables, "premier-league");
  if (!premier || !Array.isArray(premier.rows)) return [];
  return premier.rows
    .map((row) => String((row && row.team) || "").trim())
    .filter(Boolean);
}

const ALLOWED_COMPETITION_SET = new Set(
  (SERVER_CONFIG.competitionAllowlist || [])
    .map(normalizeLeagueName)
    .filter(Boolean)
    .map((league) => league.toLowerCase())
);

function isAllowedCompetition(leagueName) {
  if (ALLOWED_COMPETITION_SET.size === 0) return true;
  const normalized = normalizeLeagueName(leagueName || "");
  return ALLOWED_COMPETITION_SET.has(normalized.toLowerCase());
}

function filterMatchesByCompetition(matches) {
  return matches.filter((match) => isAllowedCompetition(match && match.league));
}

function compareInsensitive(a, b) {
  return a.localeCompare(b, undefined, { sensitivity: "base" });
}

function normalizeDeviceToken(value) {
  if (typeof value !== "string") return "";
  const normalized = value.trim();
  if (!normalized) return "";
  if (normalized.length > 200) return "";
  if (!/^[A-Za-z0-9._:-]+$/.test(normalized)) return "";
  return normalized;
}

function normalizeLiveActivityToken(value) {
  if (typeof value !== "string") return "";
  const normalized = value.trim();
  if (!normalized) return "";
  if (normalized.length > 1024) return "";
  if (!/^[A-Fa-f0-9]+$/.test(normalized)) return "";
  return normalized.toLowerCase();
}

function normalizeMetricLabel(value, fallback = "unknown") {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 64);
  return normalized || fallback;
}

function appMetricEventKey(labels) {
  return [
    labels.event,
    labels.screen,
    labels.build_type,
    labels.platform,
    labels.os_version,
    labels.device_type,
    labels.device_model,
    labels.app_version,
    labels.build_number,
  ].join("|");
}

function trackSeenDeviceToken(deviceToken) {
  if (!deviceToken) return;
  seenDeviceTokens.add(deviceToken);
  deviceLastSeenAtMs.set(deviceToken, Date.now());
}

function pruneInactiveDevices(nowMs = Date.now()) {
  deviceLastSeenAtMs.forEach((lastSeenAtMs, token) => {
    if (nowMs - lastSeenAtMs > APP_METRICS_ACTIVE_DEVICE_WINDOW_MS) {
      deviceLastSeenAtMs.delete(token);
    }
  });
}

function activeDeviceCount(nowMs = Date.now()) {
  pruneInactiveDevices(nowMs);
  return deviceLastSeenAtMs.size;
}

function escapePrometheusLabel(value) {
  return String(value || "")
    .replace(/\\/g, "\\\\")
    .replace(/\n/g, "\\n")
    .replace(/"/g, '\\"');
}

function normalizeHttpRouteLabel(req) {
  const routePath = req.route && req.route.path;
  let route = "";

  if (typeof routePath === "string") {
    route = `${req.baseUrl || ""}${routePath}`;
  } else if (Array.isArray(routePath)) {
    const matched = routePath.find((candidate) => candidate === req.path) ||
      routePath.find((candidate) => typeof candidate === "string");
    if (matched) {
      route = `${req.baseUrl || ""}${matched}`;
    }
  }

  if (!route) {
    route = req.path || (req.originalUrl ? String(req.originalUrl).split("?")[0] : "") || "unknown";
  }

  if (!route.startsWith("/")) {
    route = `/${route}`;
  }

  return route;
}

function metricLabelKey(labels) {
  return Object.keys(labels)
    .sort()
    .map((key) => `${key}:${labels[key]}`)
    .join("|");
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

function activeUsersWithinWindow(windowMs, nowMs = Date.now()) {
  let count = 0;
  deviceLastSeenAtMs.forEach((lastSeenAtMs) => {
    if (nowMs - lastSeenAtMs <= windowMs) {
      count += 1;
    }
  });
  return count;
}

function countByType(items, selector) {
  const counts = new Map();
  (Array.isArray(items) ? items : []).forEach((item) => {
    const raw = selector(item);
    const key = String(raw || "unknown").trim() || "unknown";
    counts.set(key, (counts.get(key) || 0) + 1);
  });
  return counts;
}

function setSourceCacheSize(source, size) {
  const normalizedSize = Number.isFinite(size) && size >= 0 ? size : 0;
  sourceCacheSizeBySource.set(source, normalizedSize);
}

function trackSourceUpdateMetrics({ source, startedAtMs, success, recordsFetched = null }) {
  const status = success ? "success" : "failure";
  const durationSeconds = Math.max(0, (Date.now() - startedAtMs) / 1000);
  recordHistogramSample(
    sourceFetchMetrics,
    { source, status },
    durationSeconds,
    SOURCE_FETCH_DURATION_BUCKETS
  );

  if (success) {
    sourceLastSuccessAtSeconds.set(source, Math.floor(Date.now() / 1000));
    if (Number.isFinite(recordsFetched) && recordsFetched >= 0) {
      sourceRecordsFetchedTotalBySource.set(
        source,
        (sourceRecordsFetchedTotalBySource.get(source) || 0) + recordsFetched
      );
    }
  }
}

function buildPrometheusMetricsText() {
  const lines = [];
  const cpuUsage = process.cpuUsage(PROCESS_CPU_USAGE_START);
  const cpuUserSeconds = cpuUsage.user / 1_000_000;
  const cpuSystemSeconds = cpuUsage.system / 1_000_000;
  const memoryUsage = process.memoryUsage();
  const heapStats = v8.getHeapStatistics();

  const normalizeLagSeconds = (valueNs) => {
    if (!Number.isFinite(valueNs) || valueNs < 0 || valueNs > 1e16) return 0;
    return valueNs / 1_000_000_000;
  };
  const eventLoopLagSeconds = normalizeLagSeconds(eventLoopDelayMonitor.mean);
  const eventLoopLagMinSeconds = normalizeLagSeconds(eventLoopDelayMonitor.min);
  const eventLoopLagMaxSeconds = normalizeLagSeconds(eventLoopDelayMonitor.max);
  const eventLoopLagStdDevSeconds = normalizeLagSeconds(eventLoopDelayMonitor.stddev);
  const eventLoopLagP50Seconds = normalizeLagSeconds(eventLoopDelayMonitor.percentile(50));
  const eventLoopLagP90Seconds = normalizeLagSeconds(eventLoopDelayMonitor.percentile(90));
  const eventLoopLagP99Seconds = normalizeLagSeconds(eventLoopDelayMonitor.percentile(99));

  lines.push("# HELP process_cpu_user_seconds_total Total user CPU time spent in seconds.");
  lines.push("# TYPE process_cpu_user_seconds_total counter");
  pushPrometheusSample(lines, "process_cpu_user_seconds_total", cpuUserSeconds);

  lines.push("# HELP process_cpu_system_seconds_total Total system CPU time spent in seconds.");
  lines.push("# TYPE process_cpu_system_seconds_total counter");
  pushPrometheusSample(lines, "process_cpu_system_seconds_total", cpuSystemSeconds);

  lines.push("# HELP process_cpu_seconds_total Total user and system CPU time spent in seconds.");
  lines.push("# TYPE process_cpu_seconds_total counter");
  pushPrometheusSample(lines, "process_cpu_seconds_total", cpuUserSeconds + cpuSystemSeconds);

  lines.push("# HELP process_start_time_seconds Start time of the process since unix epoch in seconds.");
  lines.push("# TYPE process_start_time_seconds gauge");
  pushPrometheusSample(lines, "process_start_time_seconds", PROCESS_START_TIME_SECONDS);

  lines.push("# HELP process_resident_memory_bytes Resident memory size in bytes.");
  lines.push("# TYPE process_resident_memory_bytes gauge");
  pushPrometheusSample(lines, "process_resident_memory_bytes", memoryUsage.rss);

  lines.push("# HELP process_virtual_memory_bytes Virtual memory size in bytes.");
  lines.push("# TYPE process_virtual_memory_bytes gauge");
  pushPrometheusSample(
    lines,
    "process_virtual_memory_bytes",
    memoryUsage.rss + memoryUsage.heapTotal + memoryUsage.external + (memoryUsage.arrayBuffers || 0)
  );

  lines.push("# HELP process_heap_bytes Process heap size in bytes.");
  lines.push("# TYPE process_heap_bytes gauge");
  pushPrometheusSample(lines, "process_heap_bytes", memoryUsage.heapTotal);

  lines.push("# HELP nodejs_eventloop_lag_seconds Lag of event loop in seconds.");
  lines.push("# TYPE nodejs_eventloop_lag_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_seconds", eventLoopLagSeconds);

  lines.push("# HELP nodejs_eventloop_lag_min_seconds The minimum recorded event loop delay.");
  lines.push("# TYPE nodejs_eventloop_lag_min_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_min_seconds", eventLoopLagMinSeconds);

  lines.push("# HELP nodejs_eventloop_lag_max_seconds The maximum recorded event loop delay.");
  lines.push("# TYPE nodejs_eventloop_lag_max_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_max_seconds", eventLoopLagMaxSeconds);

  lines.push("# HELP nodejs_eventloop_lag_mean_seconds The mean of the recorded event loop delays.");
  lines.push("# TYPE nodejs_eventloop_lag_mean_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_mean_seconds", eventLoopLagSeconds);

  lines.push("# HELP nodejs_eventloop_lag_stddev_seconds The standard deviation of the recorded event loop delays.");
  lines.push("# TYPE nodejs_eventloop_lag_stddev_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_stddev_seconds", eventLoopLagStdDevSeconds);

  lines.push("# HELP nodejs_eventloop_lag_p50_seconds The 50th percentile of the recorded event loop delays.");
  lines.push("# TYPE nodejs_eventloop_lag_p50_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_p50_seconds", eventLoopLagP50Seconds);

  lines.push("# HELP nodejs_eventloop_lag_p90_seconds The 90th percentile of the recorded event loop delays.");
  lines.push("# TYPE nodejs_eventloop_lag_p90_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_p90_seconds", eventLoopLagP90Seconds);

  lines.push("# HELP nodejs_eventloop_lag_p99_seconds The 99th percentile of the recorded event loop delays.");
  lines.push("# TYPE nodejs_eventloop_lag_p99_seconds gauge");
  pushPrometheusSample(lines, "nodejs_eventloop_lag_p99_seconds", eventLoopLagP99Seconds);

  const activeResourceCounts = countByType(
    typeof process.getActiveResourcesInfo === "function" ? process.getActiveResourcesInfo() : [],
    (name) => name
  );
  lines.push("# HELP nodejs_active_resources Number of active resources that are currently keeping the event loop alive, grouped by async resource type.");
  lines.push("# TYPE nodejs_active_resources gauge");
  Array.from(activeResourceCounts.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([type, count]) => {
      pushPrometheusSample(lines, "nodejs_active_resources", count, { type });
    });
  lines.push("# HELP nodejs_active_resources_total Total number of active resources.");
  lines.push("# TYPE nodejs_active_resources_total gauge");
  pushPrometheusSample(
    lines,
    "nodejs_active_resources_total",
    Array.from(activeResourceCounts.values()).reduce((sum, count) => sum + count, 0)
  );

  const activeHandleCounts = countByType(
    typeof process._getActiveHandles === "function" ? process._getActiveHandles() : [],
    (handle) => handle && handle.constructor && handle.constructor.name
  );
  lines.push("# HELP nodejs_active_handles Number of active libuv handles grouped by handle type. Every handle type is C++ class name.");
  lines.push("# TYPE nodejs_active_handles gauge");
  Array.from(activeHandleCounts.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([type, count]) => {
      pushPrometheusSample(lines, "nodejs_active_handles", count, { type });
    });
  lines.push("# HELP nodejs_active_handles_total Total number of active handles.");
  lines.push("# TYPE nodejs_active_handles_total gauge");
  pushPrometheusSample(
    lines,
    "nodejs_active_handles_total",
    Array.from(activeHandleCounts.values()).reduce((sum, count) => sum + count, 0)
  );

  const activeRequestCounts = countByType(
    typeof process._getActiveRequests === "function" ? process._getActiveRequests() : [],
    (request) => request && request.constructor && request.constructor.name
  );
  lines.push("# HELP nodejs_active_requests Number of active libuv requests grouped by request type. Every request type is C++ class name.");
  lines.push("# TYPE nodejs_active_requests gauge");
  Array.from(activeRequestCounts.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([type, count]) => {
      pushPrometheusSample(lines, "nodejs_active_requests", count, { type });
    });
  lines.push("# HELP nodejs_active_requests_total Total number of active requests.");
  lines.push("# TYPE nodejs_active_requests_total gauge");
  pushPrometheusSample(
    lines,
    "nodejs_active_requests_total",
    Array.from(activeRequestCounts.values()).reduce((sum, count) => sum + count, 0)
  );

  lines.push("# HELP nodejs_heap_size_total_bytes Process heap size from Node.js in bytes.");
  lines.push("# TYPE nodejs_heap_size_total_bytes gauge");
  pushPrometheusSample(lines, "nodejs_heap_size_total_bytes", heapStats.total_heap_size);

  lines.push("# HELP nodejs_heap_size_used_bytes Process heap size used from Node.js in bytes.");
  lines.push("# TYPE nodejs_heap_size_used_bytes gauge");
  pushPrometheusSample(lines, "nodejs_heap_size_used_bytes", heapStats.used_heap_size);

  lines.push("# HELP nodejs_external_memory_bytes Node.js external memory size in bytes.");
  lines.push("# TYPE nodejs_external_memory_bytes gauge");
  pushPrometheusSample(lines, "nodejs_external_memory_bytes", heapStats.external_memory);

  const nodeVersion = process.version.replace(/^v/, "");
  const versionParts = nodeVersion.split(".");
  lines.push("# HELP nodejs_version_info Node.js version info.");
  lines.push("# TYPE nodejs_version_info gauge");
  pushPrometheusSample(lines, "nodejs_version_info", 1, {
    version: process.version,
    major: versionParts[0] || "0",
    minor: versionParts[1] || "0",
    patch: versionParts[2] || "0",
  });

  const httpMetricEntries = Array.from(httpRequestMetrics.values()).sort((lhs, rhs) =>
    metricLabelKey(lhs.labels).localeCompare(metricLabelKey(rhs.labels))
  );
  appendHistogramMetrics(
    lines,
    "http_request_duration_seconds",
    "Duration of HTTP requests in seconds",
    HTTP_REQUEST_DURATION_BUCKETS,
    httpMetricEntries
  );
  lines.push("# HELP http_requests_total Total number of HTTP requests");
  lines.push("# TYPE http_requests_total counter");
  httpMetricEntries.forEach((entry) => {
    pushPrometheusSample(lines, "http_requests_total", entry.count, entry.labels);
  });

  const sourceMetricEntries = Array.from(sourceFetchMetrics.values()).sort((lhs, rhs) =>
    metricLabelKey(lhs.labels).localeCompare(metricLabelKey(rhs.labels))
  );
  appendHistogramMetrics(
    lines,
    "source_fetch_duration_seconds",
    "Duration of source fetch/update operations in seconds",
    SOURCE_FETCH_DURATION_BUCKETS,
    sourceMetricEntries
  );
  lines.push("# HELP source_fetches_total Total number of source fetch/update operations");
  lines.push("# TYPE source_fetches_total counter");
  sourceMetricEntries.forEach((entry) => {
    pushPrometheusSample(lines, "source_fetches_total", entry.count, entry.labels);
  });

  lines.push("# HELP source_records_fetched_total Total number of source records fetched.");
  lines.push("# TYPE source_records_fetched_total counter");
  Array.from(sourceRecordsFetchedTotalBySource.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([source, count]) => {
      pushPrometheusSample(lines, "source_records_fetched_total", count, { source });
    });

  lines.push("# HELP source_cache_size Number of records currently cached by source.");
  lines.push("# TYPE source_cache_size gauge");
  Array.from(sourceCacheSizeBySource.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([source, count]) => {
      pushPrometheusSample(lines, "source_cache_size", count, { source });
    });

  lines.push("# HELP source_last_success_timestamp_seconds Last successful source update timestamp.");
  lines.push("# TYPE source_last_success_timestamp_seconds gauge");
  Array.from(sourceLastSuccessAtSeconds.entries())
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .forEach(([source, timestampSeconds]) => {
      pushPrometheusSample(lines, "source_last_success_timestamp_seconds", timestampSeconds, {
        source,
      });
    });

  lines.push("# HELP top_scores_api_requests_total Total API requests.");
  lines.push("# TYPE top_scores_api_requests_total counter");
  pushPrometheusSample(lines, "top_scores_api_requests_total", appUsageMetrics.apiRequestsTotal);

  lines.push("# HELP top_scores_api_requests_with_device_token_total API requests with X-Device-Token.");
  lines.push("# TYPE top_scores_api_requests_with_device_token_total counter");
  pushPrometheusSample(
    lines,
    "top_scores_api_requests_with_device_token_total",
    appUsageMetrics.apiRequestsWithDeviceTokenTotal
  );

  lines.push("# HELP top_scores_api_requests_without_device_token_total API requests without X-Device-Token.");
  lines.push("# TYPE top_scores_api_requests_without_device_token_total counter");
  pushPrometheusSample(
    lines,
    "top_scores_api_requests_without_device_token_total",
    appUsageMetrics.apiRequestsWithoutDeviceTokenTotal
  );

  lines.push("# HELP top_scores_app_metrics_events_total App metrics events accepted by /api/v1/app-metrics.");
  lines.push("# TYPE top_scores_app_metrics_events_total counter");
  pushPrometheusSample(
    lines,
    "top_scores_app_metrics_events_total",
    appUsageMetrics.appMetricEventsTotal
  );

  lines.push("# HELP top_scores_app_metrics_events_rejected_total App metrics events rejected by /api/v1/app-metrics.");
  lines.push("# TYPE top_scores_app_metrics_events_rejected_total counter");
  pushPrometheusSample(
    lines,
    "top_scores_app_metrics_events_rejected_total",
    appUsageMetrics.appMetricEventsRejectedTotal
  );

  lines.push("# HELP top_scores_app_metrics_unique_devices_total Unique devices observed.");
  lines.push("# TYPE top_scores_app_metrics_unique_devices_total gauge");
  pushPrometheusSample(lines, "top_scores_app_metrics_unique_devices_total", seenDeviceTokens.size);

  lines.push("# HELP top_scores_app_metrics_active_devices_total Active devices seen recently.");
  lines.push("# TYPE top_scores_app_metrics_active_devices_total gauge");
  pushPrometheusSample(lines, "top_scores_app_metrics_active_devices_total", activeDeviceCount());

  lines.push("# HELP top_scores_app_metrics_active_window_seconds Active-device lookback window.");
  lines.push("# TYPE top_scores_app_metrics_active_window_seconds gauge");
  pushPrometheusSample(
    lines,
    "top_scores_app_metrics_active_window_seconds",
    Math.floor(APP_METRICS_ACTIVE_DEVICE_WINDOW_MS / 1000)
  );

  lines.push("# HELP top_scores_app_metrics_events_by_device_total App metric events by normalized app dimensions.");
  lines.push("# TYPE top_scores_app_metrics_events_by_device_total counter");
  lines.push("# HELP app_actions_total Total number of app actions recorded");
  lines.push("# TYPE app_actions_total counter");
  Array.from(appMetricEventsByDimension.values())
    .sort((lhs, rhs) => appMetricEventKey(lhs.labels).localeCompare(appMetricEventKey(rhs.labels)))
    .forEach((entry) => {
      pushPrometheusSample(
        lines,
        "top_scores_app_metrics_events_by_device_total",
        entry.count,
        entry.labels
      );
      pushPrometheusSample(lines, "app_actions_total", entry.count, {
        action: entry.labels.event,
        screen: entry.labels.screen || "unknown",
        build_type: entry.labels.build_type || "unknown",
        platform: entry.labels.platform,
      });
    });

  if (appMetricEventsLastUpdated) {
    const timestampSeconds = Math.floor(Date.parse(appMetricEventsLastUpdated) / 1000);
    if (Number.isFinite(timestampSeconds) && timestampSeconds > 0) {
      lines.push("# HELP top_scores_app_metrics_last_updated_timestamp_seconds Last accepted app metrics timestamp.");
      lines.push("# TYPE top_scores_app_metrics_last_updated_timestamp_seconds gauge");
      pushPrometheusSample(
        lines,
        "top_scores_app_metrics_last_updated_timestamp_seconds",
        timestampSeconds
      );
    }
  }

  const nowMs = Date.now();
  lines.push("# HELP unique_users Number of unique users (by device token) over time periods");
  lines.push("# TYPE unique_users gauge");
  UNIQUE_USER_WINDOWS.forEach(({ period, windowMs }) => {
    pushPrometheusSample(lines, "unique_users", activeUsersWithinWindow(windowMs, nowMs), {
      period,
    });
  });
  pushPrometheusSample(lines, "unique_users", seenDeviceTokens.size, { period: "all" });

  return `${lines.join("\n")}\n`;
}

function normalizeMissingTeamLogoName(value) {
  return String(value || "")
    .trim()
    .replace(/\s+/g, " ");
}

function missingTeamLogoKey(value) {
  return normalizeMissingTeamLogoName(value).toLowerCase();
}

function sortedMissingTeamLogoNames() {
  return Array.from(missingTeamLogosByKey.values()).sort(compareInsensitive);
}

function missingTeamLogoNamesFromPayload(payload) {
  if (Array.isArray(payload)) return payload;
  if (payload && typeof payload === "object" && Array.isArray(payload.team_names)) {
    return payload.team_names;
  }
  return null;
}

function ingestMissingTeamLogoNames(teamNames) {
  let acceptedCount = 0;
  let addedCount = 0;
  const added = [];
  const seenInRequest = new Set();

  (Array.isArray(teamNames) ? teamNames : []).forEach((rawTeamName) => {
    if (typeof rawTeamName !== "string") return;
    const normalized = normalizeMissingTeamLogoName(rawTeamName);
    if (!normalized) return;
    const key = missingTeamLogoKey(normalized);
    if (!key || seenInRequest.has(key)) return;
    seenInRequest.add(key);
    acceptedCount += 1;
    if (missingTeamLogosByKey.has(key)) return;
    missingTeamLogosByKey.set(key, normalized);
    added.push(normalized);
    addedCount += 1;
  });

  if (addedCount > 0) {
    missingTeamLogosLastUpdated = new Date().toISOString();
    const names = sortedMissingTeamLogoNames();
    writeMissingTeamLogos(MISSING_TEAM_LOGOS_OUTPUT_PATH, names);
    void persistOperationalDatasetSafe(OP_DATASET_MISSING_TEAM_LOGOS, names, {
      updated_at: missingTeamLogosLastUpdated,
      source: "missing_team_logos_ingest",
    });
  }

  return {
    acceptedCount,
    addedCount,
    added,
    totalCount: missingTeamLogosByKey.size,
  };
}

function removeMissingTeamLogoNames(teamNames) {
  let acceptedCount = 0;
  let removedCount = 0;
  const removed = [];
  const seenInRequest = new Set();

  (Array.isArray(teamNames) ? teamNames : []).forEach((rawTeamName) => {
    if (typeof rawTeamName !== "string") return;
    const normalized = normalizeMissingTeamLogoName(rawTeamName);
    if (!normalized) return;
    const key = missingTeamLogoKey(normalized);
    if (!key || seenInRequest.has(key)) return;
    seenInRequest.add(key);
    acceptedCount += 1;
    if (!missingTeamLogosByKey.has(key)) return;
    removed.push(missingTeamLogosByKey.get(key));
    missingTeamLogosByKey.delete(key);
    removedCount += 1;
  });

  if (removedCount > 0) {
    missingTeamLogosLastUpdated = new Date().toISOString();
    const names = sortedMissingTeamLogoNames();
    writeMissingTeamLogos(MISSING_TEAM_LOGOS_OUTPUT_PATH, names);
    void persistOperationalDatasetSafe(OP_DATASET_MISSING_TEAM_LOGOS, names, {
      updated_at: missingTeamLogosLastUpdated,
      source: "missing_team_logos_remove",
    });
  }

  return {
    acceptedCount,
    removedCount,
    removed,
    totalCount: missingTeamLogosByKey.size,
  };
}

function clearMissingTeamLogos() {
  const removed = sortedMissingTeamLogoNames();
  const removedCount = removed.length;
  missingTeamLogosByKey = new Map();
  missingTeamLogosLastUpdated = new Date().toISOString();
  writeMissingTeamLogos(MISSING_TEAM_LOGOS_OUTPUT_PATH, []);
  void persistOperationalDatasetSafe(OP_DATASET_MISSING_TEAM_LOGOS, [], {
    updated_at: missingTeamLogosLastUpdated,
    source: "missing_team_logos_clear",
  });

  return {
    removedCount,
    removed,
    totalCount: 0,
  };
}

async function mapWithConcurrency(items, concurrency, worker) {
  if (!Array.isArray(items) || items.length === 0) return;
  const limit = Math.max(1, Number(concurrency) || 1);
  let cursor = 0;

  async function runWorker() {
    while (cursor < items.length) {
      const idx = cursor;
      cursor += 1;
      // eslint-disable-next-line no-await-in-loop
      await worker(items[idx], idx);
    }
  }

  const workers = [];
  const workerCount = Math.min(limit, items.length);
  for (let i = 0; i < workerCount; i += 1) {
    workers.push(runWorker());
  }
  await Promise.all(workers);
}

const CHANNEL_SPECIAL_OPTIONS = [
  "Amazon (all)",
  "BBC (all)",
  "ITV (all)",
  "Sky (all)",
  "TNT (all)",
];
const CHANNEL_SPECIAL_KEYWORDS = new Map([
  ["Amazon (all)", "amazon"],
  ["BBC (all)", "bbc"],
  ["ITV (all)", "itv"],
  ["Sky (all)", "sky"],
  ["TNT (all)", "tnt"],
]);

function normalizedChannelTokens(value) {
  return String(value || "")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .split(/[^a-z0-9]+/i)
    .map((token) => token.trim())
    .filter(Boolean);
}

function specialChannelNameForSelection(selection) {
  const trimmed = String(selection || "")
    .trim()
    .toLowerCase();
  if (!trimmed) return null;

  for (const option of CHANNEL_SPECIAL_OPTIONS) {
    const canonical = option.toLowerCase();
    const base = option.replace(/\s*\(all\)\s*$/i, "").toLowerCase();
    if (trimmed === canonical || trimmed === base) {
      return option;
    }
  }

  return null;
}

function channelMatchesSelection(channelName, selection) {
  const trimmedSelection = String(selection || "").trim();
  if (!trimmedSelection) return false;

  const specialOption = specialChannelNameForSelection(trimmedSelection);
  if (specialOption) {
    const keyword = CHANNEL_SPECIAL_KEYWORDS.get(specialOption);
    return normalizedChannelTokens(channelName).some((token) => token.startsWith(keyword));
  }

  return compareInsensitive(String(channelName || "").trim(), trimmedSelection) === 0;
}

const SCORE_MIN_COMBINED_CONFIDENCE = 0.82;
const SCORE_MIN_TEAM_CONFIDENCE = 0.7;
const SCORE_SWAPPED_PENALTY = 0.08;
const SCORE_PREFIX_BOOST = 0.35;
const SCORE_SINGLE_TOKEN_PENALTY = 0.12;

const SCORE_STOP_WORDS = new Set([
  "fc",
  "cf",
  "sc",
  "afc",
  "ac",
  "sv",
  "fk",
  "bk",
  "bc",
  "ks",
  "nk",
  "club",
  "de",
  "the",
  "and",
]);
const TEAM_IDENTITY_STOP_WORDS = new Set([
  ...SCORE_STOP_WORDS,
  "vfb",
  "vfl",
  "tsg",
  "ifk",
  "fkf",
  "fsv",
  "us",
  "ca",
  "cd",
  "ud",
  "rc",
]);
const DEDUPE_MIN_COMBINED_CONFIDENCE = 0.9;
const DEDUPE_MIN_TEAM_CONFIDENCE = 0.84;

const SCORE_ALIAS_MAP = new Map([
  ["manchester united", "man united"],
  ["man united", "manchester united"],
  ["man utd", "manchester united"],
  ["manchester city", "man city"],
  ["man city", "manchester city"],
  ["tottenham hotspur", "tottenham"],
  ["spurs", "tottenham hotspur"],
  ["wolverhampton wanderers", "wolves"],
  ["wolves", "wolverhampton wanderers"],
  ["sheffield united", "sheff utd"],
  ["sheffield wednesday", "sheff wed"],
  ["nottingham forest", "nottm forest"],
  ["nottm forest", "nottingham forest"],
  ["newcastle united", "newcastle"],
  ["brighton", "brighton and hove albion"],
  ["brighton & hove albion", "brighton"],
  ["brighton and hove albion", "brighton"],
  ["west ham united", "west ham"],
  ["west ham", "west ham united"],
  ["wolverhampton", "wolverhampton wanderers"],
  ["tottenham", "tottenham hotspur"],
  ["borussia dortmund", "dortmund"],
  ["borussia m'gladbach", "m'gladbach"],
  ["athletic club", "athletic"],
  ["real betis", "betis"],
  ["fc copenhagen", "copenhagen"],
  ["fc porto", "porto"],
  ["paok thessaloniki", "paok"],
  ["paok thessaloniki fc", "paok"],
  ["inter milan", "inter"],
  ["ac milan", "ac milan"],
]);

function normalizeTeamName(value) {
  if (!value) return "";
  return String(value)
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/&/g, " and ")
    .replace(/'/g, "")
    .replace(/\./g, " ")
    .replace(/[-_]/g, " ")
    .trim();
}

function normalizedTokens(value) {
  const lowered = normalizeTeamName(value);
  return lowered
    .split(/[^a-z0-9]+/i)
    .map((token) => token.trim())
    .filter((token) => token && !SCORE_STOP_WORDS.has(token));
}

function identityTokens(value) {
  return normalizeTeamName(value)
    .split(/[^a-z0-9]+/i)
    .map((token) => token.trim())
    .filter((token) => {
      if (!token) return false;
      if (TEAM_IDENTITY_STOP_WORDS.has(token)) return false;
      if (/^\d+$/.test(token)) return false;
      return true;
    });
}

function canonicalTeamIdentity(value) {
  const tokens = identityTokens(value);
  if (tokens.length > 0) return tokens.join(" ");
  return normalizeTeamName(value).replace(/\s+/g, " ").trim();
}

function identityTeamKeys(value) {
  const keys = [];
  const addKey = (candidate) => {
    const normalized = String(candidate || "").replace(/\s+/g, " ").trim();
    if (!normalized) return;
    if (!keys.includes(normalized)) keys.push(normalized);
  };

  addKey(normalizeTeamName(value));
  addKey(canonicalTeamIdentity(value));

  nameVariants(value).forEach((variant) => {
    addKey(variant.tokens.join(" "));
    const canonicalVariant = variant.tokens
      .filter((token) => {
        if (TEAM_IDENTITY_STOP_WORDS.has(token)) return false;
        if (/^\d+$/.test(token)) return false;
        return true;
      })
      .join(" ");
    addKey(canonicalVariant);
  });

  return keys;
}

function nameVariants(name) {
  const lowered = String(name || "").toLowerCase();
  const candidates = [lowered];
  if (SCORE_ALIAS_MAP.has(lowered)) {
    candidates.push(SCORE_ALIAS_MAP.get(lowered));
  }

  const variants = [];
  candidates.forEach((candidate) => {
    const tokens = normalizedTokens(candidate);
    const key = tokens.join("");
    if (!key) return;
    const exists = variants.some((variant) => variant.key === key);
    if (!exists) variants.push({ key, tokens });
  });
  return variants;
}

function diceCoefficient(lhs, rhs) {
  if (!lhs.length && !rhs.length) return 1;
  const left = new Set(lhs);
  const right = new Set(rhs);
  let intersection = 0;
  left.forEach((token) => {
    if (right.has(token)) intersection += 1;
  });
  return (2 * intersection) / (lhs.length + rhs.length);
}

function prefixScore(lhs, rhs) {
  if (Math.min(lhs.tokens.length, rhs.tokens.length) !== 1) return 0;
  if (lhs.key.startsWith(rhs.key) || rhs.key.startsWith(lhs.key)) {
    const minLength = Math.min(lhs.key.length, rhs.key.length);
    const maxLength = Math.max(lhs.key.length, rhs.key.length);
    if (!maxLength) return 1;
    return Math.min(1, minLength / maxLength + SCORE_PREFIX_BOOST);
  }
  return 0;
}

function levenshtein(lhs, rhs) {
  const left = Array.from(lhs);
  const right = Array.from(rhs);
  const previous = Array.from({ length: right.length + 1 }, (_, i) => i);
  let current = Array.from({ length: right.length + 1 }, () => 0);

  for (let i = 0; i < left.length; i += 1) {
    current[0] = i + 1;
    for (let j = 0; j < right.length; j += 1) {
      const cost = left[i] === right[j] ? 0 : 1;
      current[j + 1] = Math.min(
        previous[j + 1] + 1,
        current[j] + 1,
        previous[j] + cost
      );
    }
    for (let k = 0; k < current.length; k += 1) {
      previous[k] = current[k];
    }
  }

  return previous[right.length];
}

function similarity(lhs, rhs) {
  const maxLength = Math.max(lhs.length, rhs.length);
  if (!maxLength) return 1;
  return 1 - levenshtein(lhs, rhs) / maxLength;
}

function similarityScore(lhs, rhs) {
  const leftVariants = nameVariants(lhs);
  const rightVariants = nameVariants(rhs);
  let best = 0;

  leftVariants.forEach((left) => {
    rightVariants.forEach((right) => {
      const base = similarity(left.key, right.key);
      const dice = diceCoefficient(left.tokens, right.tokens);
      const prefix = prefixScore(left, right);
      let candidate = Math.max(base, dice, prefix);

      if (left.tokens.length >= 2 && right.tokens.length >= 2) {
        const intersection = left.tokens.filter((token) => right.tokens.includes(token)).length;
        if (intersection === 1) {
          candidate = Math.max(0, candidate - SCORE_SINGLE_TOKEN_PENALTY);
        }
      }

      best = Math.max(best, candidate);
    });
  });

  return Math.min(1, best);
}

function scoreTeams(home, away, bbcHome, bbcAway, penalty) {
  const homeScore = similarityScore(home, bbcHome);
  const awayScore = similarityScore(away, bbcAway);
  const combined = Math.max(0, (homeScore + awayScore) / 2 - penalty);
  return { confidence: combined, minTeamConfidence: Math.min(homeScore, awayScore) };
}

function bestScoreCandidate(match, bbcMatches) {
  let best = null;
  bbcMatches.forEach((bbc) => {
    const direct = scoreTeams(match.home_team, match.away_team, bbc.home_team, bbc.away_team, 0);
    const swapped = scoreTeams(
      match.home_team,
      match.away_team,
      bbc.away_team,
      bbc.home_team,
      SCORE_SWAPPED_PENALTY
    );
    const directCandidate = {
      match: bbc,
      confidence: direct.confidence,
      minTeamConfidence: direct.minTeamConfidence,
      swapped: false,
    };
    const swappedCandidate = {
      match: bbc,
      confidence: swapped.confidence,
      minTeamConfidence: swapped.minTeamConfidence,
      swapped: true,
    };
    const chosen = directCandidate.confidence >= swappedCandidate.confidence
      ? directCandidate
      : swappedCandidate;
    const candidate = {
      match: chosen.match,
      confidence: chosen.confidence,
      minTeamConfidence: chosen.minTeamConfidence,
      swapped: chosen.swapped,
    };

    if (!best || candidate.confidence > best.confidence) {
      best = candidate;
    }
  });

  if (!best) return null;
  if (
    best.confidence < SCORE_MIN_COMBINED_CONFIDENCE ||
    best.minTeamConfidence < SCORE_MIN_TEAM_CONFIDENCE
  ) {
    return null;
  }

  return best;
}

function matchKey(match) {
  return [
    match.date,
    match.time,
    String(match.league || "").toLowerCase().trim(),
    String(match.home_team || "").toLowerCase().trim(),
    String(match.away_team || "").toLowerCase().trim(),
  ].join("|");
}

const DATE_ONLY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
const TIME_ONLY_PATTERN = /^\d{2}:\d{2}$/;

function isDateOnly(value) {
  return DATE_ONLY_PATTERN.test(String(value || "").trim());
}

function normalizeTimeValue(value) {
  const normalized = String(value || "").trim();
  return TIME_ONLY_PATTERN.test(normalized) ? normalized : "00:00";
}

function parseNumericScore(value) {
  if (value === undefined || value === null || value === "") return null;
  const num = Number(value);
  return Number.isFinite(num) ? num : null;
}

function uniqueChannels(channels) {
  const output = [];
  (Array.isArray(channels) ? channels : []).forEach((channel) => {
    const trimmed = String(channel || "").trim();
    if (!trimmed) return;
    if (!output.includes(trimmed)) output.push(trimmed);
  });
  return output;
}

const MATCH_STATUS_IN_PROGRESS_TOKENS = new Set(["LIVE", "HT", "ET", "PENS", "PEN", "PEN."]);
const MATCH_STATUS_COMPLETE_TOKENS = new Set(["FT", "AET"]);
const MATCH_STATUS_MINUTE_PATTERN = /^\d{1,3}(?:\+\d{1,2})?'?$/;
const MATCH_DETAILS_ID_PATTERN = /^[a-z0-9]+$/i;
const MATCH_DETAILS_EVENT_FIELDS = [
  "home_goal_scorers",
  "away_goal_scorers",
  "home_assists",
  "away_assists",
  "home_red_cards",
  "away_red_cards",
];

function normalizeMatchStatusValue(status) {
  const normalized = String(status || "").trim();
  if (!normalized) return null;
  if (TIME_ONLY_PATTERN.test(normalized)) return null;
  if (MATCH_STATUS_MINUTE_PATTERN.test(normalized)) {
    return normalized.replace(/'$/, "");
  }

  const token = normalized.toUpperCase();
  if (token === "PENS" || token === "PEN" || token === "PEN.") return "Pens";
  if (token === "HALF TIME" || token === "HALF-TIME") return "HT";
  if (token === "FULL TIME" || token === "FULL-TIME") return "FT";
  if (token === "EXTRA TIME") return "ET";
  if (
    MATCH_STATUS_COMPLETE_TOKENS.has(token) ||
    MATCH_STATUS_IN_PROGRESS_TOKENS.has(token)
  ) {
    return token;
  }
  return normalized;
}

function parseMatchStatusMinute(status) {
  const normalized = normalizeMatchStatusValue(status);
  if (!normalized) return null;
  const match = normalized.match(/^(\d{1,3})(?:\+(\d{1,2}))?$/);
  if (!match) return null;
  const base = Number(match[1]);
  const added = Number(match[2] || 0);
  if (!Number.isFinite(base) || !Number.isFinite(added)) return null;
  return base + added;
}

function isPenaltyShootoutStatusToken(status) {
  const normalized = normalizeMatchStatusValue(status);
  if (!normalized) return false;
  const token = normalized.toUpperCase();
  return token === "PENS" || token === "PEN" || token === "PEN.";
}

function pickPreferredMatchStatus(existingStatus, incomingStatus, options = {}) {
  const preferIncomingOnTie = options.preferIncomingOnTie !== false;
  const existing = normalizeMatchStatusValue(existingStatus);
  const incoming = normalizeMatchStatusValue(incomingStatus);

  if (!existing) return incoming;
  if (!incoming) return existing;

  const existingToken = existing.toUpperCase();
  const incomingToken = incoming.toUpperCase();
  const existingFinished = MATCH_STATUS_COMPLETE_TOKENS.has(existingToken);
  const incomingFinished = MATCH_STATUS_COMPLETE_TOKENS.has(incomingToken);

  // Never regress a terminal status back to an in-progress token.
  if (existingFinished && !incomingFinished) return existing;
  if (incomingFinished && !existingFinished) return incoming;

  const existingMinute = parseMatchStatusMinute(existing);
  const incomingMinute = parseMatchStatusMinute(incoming);

  if (existingMinute !== null && incomingMinute !== null) {
    if (incomingMinute > existingMinute) return incoming;
    if (existingMinute > incomingMinute) return existing;
    return preferIncomingOnTie ? incoming : existing;
  }

  if (existingMinute !== null || incomingMinute !== null) {
    if (incomingMinute !== null) {
      if (existingToken === "LIVE") return incoming;
      if (existingToken === "HT" && incomingMinute <= 45) return existing;
      if (existingToken === "ET" && incomingMinute <= 90) return existing;
      return incoming;
    }

    // Existing has a minute; keep it unless incoming represents a strictly later phase.
    if (incomingToken === "LIVE") return existing;
    if (incomingToken === "HT" && existingMinute >= 46) return existing;
    if (incomingToken === "ET" || isPenaltyShootoutStatusToken(incoming)) return incoming;
    return preferIncomingOnTie ? incoming : existing;
  }

  if (isPenaltyShootoutStatusToken(existing) !== isPenaltyShootoutStatusToken(incoming)) {
    return isPenaltyShootoutStatusToken(incoming) ? incoming : existing;
  }

  return preferIncomingOnTie ? incoming : existing;
}

function resolveMatchScoreStatus(match) {
  if (!match || typeof match !== "object") return null;
  return pickPreferredMatchStatus(match.score_status, match.match_time, {
    preferIncomingOnTie: true,
  });
}

function isInProgressMatchStatus(status) {
  const normalized = normalizeMatchStatusValue(status);
  if (!normalized) return false;
  if (MATCH_STATUS_MINUTE_PATTERN.test(normalized)) return true;

  const token = normalized.toUpperCase();
  if (MATCH_STATUS_COMPLETE_TOKENS.has(token)) return false;
  return MATCH_STATUS_IN_PROGRESS_TOKENS.has(token);
}

function matchDetailsIdFromUrl(detailsUrl) {
  if (!detailsUrl) return null;
  try {
    const parsed = new URL(String(detailsUrl));
    const pathname = String(parsed.pathname || "");
    if (!pathname.includes("/football/")) return null;
    const parts = pathname.split("/").filter(Boolean);
    if (parts.length === 0) return null;
    const last = String(parts[parts.length - 1] || "").trim();
    if (!MATCH_DETAILS_ID_PATTERN.test(last)) return null;
    return last.toLowerCase();
  } catch (_err) {
    return null;
  }
}

function normalizeMatchDetailsId(value) {
  const normalized = String(value || "").trim().toLowerCase();
  if (!MATCH_DETAILS_ID_PATTERN.test(normalized)) return null;
  return normalized;
}

function normalizeMatchDetailsPayload(match) {
  if (!match || typeof match !== "object") return null;
  const detailsUrl = String(match.details_url || "").trim();
  if (!detailsUrl) return null;
  const detailsId = matchDetailsIdFromUrl(detailsUrl);
  if (!detailsId) return null;

  const homeTeam = String(match.home_team || "").trim();
  const awayTeam = String(match.away_team || "").trim();
  if (!homeTeam || !awayTeam) return null;

  const date = isDateOnly(match.date) ? String(match.date).trim() : null;
  const time = TIME_ONLY_PATTERN.test(String(match.time || "").trim())
    ? String(match.time).trim()
    : null;
  const league = String(match.league || "").trim() || null;
  const homeScore = parseNumericScore(match.home_score);
  const awayScore = parseNumericScore(match.away_score);
  const aggregateHomeScore = parseNumericScore(match.aggregate_home_score);
  const aggregateAwayScore = parseNumericScore(match.aggregate_away_score);
  const scoreStatus = resolveMatchScoreStatus(match);

  const payload = {
    id: detailsId,
    details_url: detailsUrl,
    date,
    time,
    league,
    home_team: homeTeam,
    away_team: awayTeam,
    home_score: homeScore,
    away_score: awayScore,
    aggregate_home_score: aggregateHomeScore,
    aggregate_away_score: aggregateAwayScore,
    score_status: scoreStatus,
    in_progress: isInProgressMatchStatus(scoreStatus),
  };

  MATCH_DETAILS_EVENT_FIELDS.forEach((field) => {
    payload[field] = Array.isArray(match[field]) ? match[field] : [];
  });

  const penaltyResult = String(match.penalty_result || "").trim();
  if (penaltyResult) {
    payload.penalty_result = penaltyResult;
  }

  return payload;
}

function mergeMatchDetailsPayload(existing, incoming, updatedAtIso) {
  const merged = {
    ...(existing || {}),
    ...incoming,
    id: incoming.id,
    details_url: incoming.details_url || (existing ? existing.details_url : null),
    date: incoming.date || (existing ? existing.date : null),
    time: incoming.time || (existing ? existing.time : null),
    league: incoming.league || (existing ? existing.league : null),
    home_team: incoming.home_team || (existing ? existing.home_team : null),
    away_team: incoming.away_team || (existing ? existing.away_team : null),
    updated_at: updatedAtIso,
  };

  if (incoming.home_score !== null && incoming.home_score !== undefined) {
    merged.home_score = incoming.home_score;
  } else if (existing && existing.home_score !== undefined) {
    merged.home_score = existing.home_score;
  } else {
    merged.home_score = null;
  }

  if (incoming.away_score !== null && incoming.away_score !== undefined) {
    merged.away_score = incoming.away_score;
  } else if (existing && existing.away_score !== undefined) {
    merged.away_score = existing.away_score;
  } else {
    merged.away_score = null;
  }

  if (incoming.aggregate_home_score !== null && incoming.aggregate_home_score !== undefined) {
    merged.aggregate_home_score = incoming.aggregate_home_score;
  } else if (existing && existing.aggregate_home_score !== undefined) {
    merged.aggregate_home_score = existing.aggregate_home_score;
  } else {
    merged.aggregate_home_score = null;
  }

  if (incoming.aggregate_away_score !== null && incoming.aggregate_away_score !== undefined) {
    merged.aggregate_away_score = incoming.aggregate_away_score;
  } else if (existing && existing.aggregate_away_score !== undefined) {
    merged.aggregate_away_score = existing.aggregate_away_score;
  } else {
    merged.aggregate_away_score = null;
  }

  merged.score_status = pickPreferredMatchStatus(
    existing && existing.score_status !== undefined ? existing.score_status : null,
    incoming && incoming.score_status !== undefined ? incoming.score_status : null,
    { preferIncomingOnTie: true }
  );

  MATCH_DETAILS_EVENT_FIELDS.forEach((field) => {
    const incomingValue = incoming[field];
    if (Array.isArray(incomingValue) && incomingValue.length > 0) {
      merged[field] = incomingValue;
      return;
    }
    if (Array.isArray(existing && existing[field])) {
      merged[field] = existing[field];
      return;
    }
    merged[field] = Array.isArray(incomingValue) ? incomingValue : [];
  });

  if (incoming.penalty_result) {
    merged.penalty_result = incoming.penalty_result;
  } else if (existing && existing.penalty_result) {
    merged.penalty_result = existing.penalty_result;
  }

  // If we have a penalty result (shootout complete) and status is "Pens", change to "AET"
  // The JSON data often has "Pens" status, but the HTML shows "AET" when complete
  if (merged.penalty_result && (merged.score_status === "Pens" || merged.score_status === "PEN" || merged.score_status === "PEN.")) {
    merged.score_status = "AET";
  }

  merged.in_progress = isInProgressMatchStatus(merged.score_status);
  return merged;
}

function upsertMatchDetailsFromMatch(match, updatedAtIso = new Date().toISOString()) {
  const incoming = normalizeMatchDetailsPayload(match);
  if (!incoming) return null;
  const existing = matchDetailsById.get(incoming.id);
  const merged = mergeMatchDetailsPayload(existing, incoming, updatedAtIso);
  matchDetailsById.set(incoming.id, merged);
  return incoming.id;
}

function matchDetailsNeedsEnrichment(payload) {
  if (!payload || typeof payload !== "object") return false;
  const hasAnyEvents = MATCH_DETAILS_EVENT_FIELDS.some((field) => {
    const value = payload[field];
    return Array.isArray(value) && value.length > 0;
  });
  return !hasAnyEvents;
}

function matchDetailsHasStaleInProgressStatus(payload, nowMs = Date.now()) {
  if (!payload || typeof payload !== "object") return false;

  const scoreStatus = normalizeMatchStatusValue(payload.score_status);
  const statusMinute = parseMatchStatusMinute(scoreStatus);
  if (statusMinute === null || statusMinute < MATCH_DETAILS_STALE_MINUTE_THRESHOLD) {
    return false;
  }

  const inProgressFlag =
    payload.in_progress !== undefined
      ? Boolean(payload.in_progress)
      : isInProgressMatchStatus(scoreStatus);
  if (!inProgressFlag) return false;

  const updatedAtMs = Date.parse(String(payload.updated_at || "").trim());
  if (!Number.isFinite(updatedAtMs)) return true;
  if (nowMs <= updatedAtMs) return false;
  return nowMs - updatedAtMs >= MATCH_DETAILS_STALE_IN_PROGRESS_MS;
}

function matchDetailsNeedsBackfill(payload, nowMs = Date.now()) {
  if (!payload || typeof payload !== "object") return false;
  if (!payload.details_url) return false;
  return (
    matchDetailsNeedsEnrichment(payload) ||
    matchDetailsHasStaleInProgressStatus(payload, nowMs)
  );
}

function buildMergedMatchDetailsCandidate(seedMatch, fetchedMatch, detailsUrl) {
  const seed = seedMatch && typeof seedMatch === "object" ? seedMatch : {};
  const fetched = fetchedMatch && typeof fetchedMatch === "object" ? fetchedMatch : {};

  const combined = {
    ...seed,
    ...fetched,
  };

  if (detailsUrl) {
    combined.details_url = detailsUrl;
  }

  const preferredStatus = pickPreferredMatchStatus(
    seed.score_status || seed.match_time,
    fetched.score_status || fetched.match_time,
    { preferIncomingOnTie: true }
  );
  if (preferredStatus) {
    combined.score_status = preferredStatus;
  }

  return combined;
}

function indexMatchDetailsFromMatches(matches, updatedAtIso = new Date().toISOString()) {
  if (!Array.isArray(matches) || matches.length === 0) return 0;
  let inserted = 0;
  matches.forEach((match) => {
    if (upsertMatchDetailsFromMatch(match, updatedAtIso)) {
      inserted += 1;
    }
  });
  if (inserted > 0) {
    matchDetailsLastUpdated = updatedAtIso;
  }
  return inserted;
}

function collectMatchDetailsSubsetByMatches(matches) {
  const subset = {};
  (Array.isArray(matches) ? matches : []).forEach((match) => {
    const detailsId =
      matchDetailsIdFromUrl(match && match.details_url) ||
      normalizeMatchDetailsId(match && match.match_details_id);
    if (!detailsId) return;
    const payload = matchDetailsById.get(detailsId);
    if (payload && typeof payload === "object") {
      subset[detailsId] = payload;
    }
  });
  return subset;
}

async function rebuildMatchDetailsCache(source = "match_details_rebuild") {
  const nowIso = new Date().toISOString();
  indexMatchDetailsFromMatches(cachedMergedMatches, nowIso);
  indexMatchDetailsFromMatches(cachedBbcMatches, nowIso);
  indexMatchDetailsFromMatches(cachedRecentMatches, nowIso);
  matchDetailsLastUpdated = nowIso;
  setSourceCacheSize(SOURCE_BBC_MATCH_DETAILS, matchDetailsById.size);
  await persistOperationalMatchDetailsSafe(Object.fromEntries(matchDetailsById), {
    replace: true,
    updated_at: nowIso,
    source,
  });
}

function collectInProgressMatchDetailTargets() {
  const targets = new Map();
  const sources = [cachedBbcMatches, cachedMergedMatches];
  const upsertTarget = (detailsPayload) => {
    if (!detailsPayload || typeof detailsPayload !== "object") return;

    const detailsId = normalizeMatchDetailsId(detailsPayload.id);
    if (!detailsId) return;

    const detailsUrl = String(detailsPayload.details_url || "").trim();
    if (!detailsUrl) return;

    const scoreStatus = normalizeMatchStatusValue(detailsPayload.score_status);
    const isInProgress =
      isInProgressMatchStatus(scoreStatus) || Boolean(detailsPayload.in_progress);
    if (!isInProgress) return;

    const existing = targets.get(detailsId);
    const mergedSeedMatch = existing && existing.seed_match
      ? { ...existing.seed_match, ...detailsPayload }
      : { ...detailsPayload };

    const preferredStatus = pickPreferredMatchStatus(
      existing && existing.seed_match ? existing.seed_match.score_status : null,
      detailsPayload.score_status,
      { preferIncomingOnTie: true }
    );
    if (preferredStatus) {
      mergedSeedMatch.score_status = preferredStatus;
    }

    mergedSeedMatch.id = detailsId;
    mergedSeedMatch.details_url = detailsUrl;
    mergedSeedMatch.in_progress =
      isInProgressMatchStatus(mergedSeedMatch.score_status) || Boolean(mergedSeedMatch.in_progress);

    targets.set(detailsId, {
      id: detailsId,
      details_url: detailsUrl,
      seed_match: mergedSeedMatch,
    });
  };

  sources.forEach((matches) => {
    (Array.isArray(matches) ? matches : []).forEach((rawMatch) => {
      const detailsPayload = normalizeMatchDetailsPayload(rawMatch);
      if (!detailsPayload) return;
      upsertTarget(detailsPayload);
    });
  });

  matchDetailsById.forEach((payload, matchId) => {
    if (!payload || typeof payload !== "object") return;
    const normalizedId = normalizeMatchDetailsId(payload.id || matchId);
    if (!normalizedId) return;
    upsertTarget({
      ...payload,
      id: normalizedId,
      score_status: resolveMatchScoreStatus(payload) || payload.score_status || null,
    });
  });

  return Array.from(targets.values());
}

async function refreshInProgressMatchDetails() {
  if (matchDetailsUpdating) return;
  matchDetailsUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = 0;

  try {
    const targets = collectInProgressMatchDetailTargets();
    if (targets.length === 0) {
      success = true;
      return;
    }
    const nowIso = new Date().toISOString();
    const refreshedDetailsIds = new Set();

    await mapWithConcurrency(
      targets,
      MATCH_DETAILS_POLL_CONCURRENCY,
      async (target) => {
        try {
          const fetched = await fetchBbcMatchByDetailsUrl(target.details_url);
          if (!fetched) return;
          const combined = buildMergedMatchDetailsCandidate(
            target.seed_match,
            fetched,
            target.details_url
          );
          const detailsId = upsertMatchDetailsFromMatch(combined, nowIso);
          if (detailsId) refreshedDetailsIds.add(detailsId);
        } catch (err) {
          console.warn(
            `Failed to refresh match details for ${target.details_url}:`,
            err.message || err
          );
        }
      }
    );

    recordsFetched = targets.length;
    success = true;
    matchDetailsLastUpdated = nowIso;
    setSourceCacheSize(SOURCE_BBC_MATCH_DETAILS, matchDetailsById.size);
    const updatedDetailsSubset = {};
    refreshedDetailsIds.forEach((detailsId) => {
      const payload = matchDetailsById.get(detailsId);
      if (payload && typeof payload === "object") {
        updatedDetailsSubset[detailsId] = payload;
      }
    });
    if (Object.keys(updatedDetailsSubset).length > 0) {
      await persistOperationalMatchDetailsSafe(updatedDetailsSubset, {
        replace: false,
        updated_at: nowIso,
        source: SOURCE_BBC_MATCH_DETAILS,
      });
    }
    console.log(
      `Refreshed in-progress match details (${targets.length}) at ${nowIso}`
    );
  } catch (err) {
    console.warn("Failed to refresh in-progress match details:", err.message || err);
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_BBC_MATCH_DETAILS,
      startedAtMs,
      success,
      recordsFetched,
    });
    matchDetailsUpdating = false;
  }
}

function normalizeMatchRecord(match) {
  if (!match || typeof match !== "object") return null;
  const date = String(match.date || "").trim();
  if (!isDateOnly(date)) return null;
  const home = String(match.home_team || "").trim();
  const away = String(match.away_team || "").trim();
  if (!home || !away) return null;

  const record = {
    date,
    time: normalizeTimeValue(match.time),
    league: normalizeLeagueName(match.league || "") || "",
    home_team: home,
    away_team: away,
    tv_channels: uniqueChannels(match.tv_channels),
  };

  if (match.league_subcategory) {
    record.league_subcategory = String(match.league_subcategory).trim();
  }

  const homeScore = parseNumericScore(match.home_score);
  const awayScore = parseNumericScore(match.away_score);
  if (homeScore !== null && awayScore !== null) {
    record.home_score = homeScore;
    record.away_score = awayScore;
  }

  const aggregateHomeScore = parseNumericScore(match.aggregate_home_score);
  const aggregateAwayScore = parseNumericScore(match.aggregate_away_score);
  if (aggregateHomeScore !== null && aggregateAwayScore !== null) {
    record.aggregate_home_score = aggregateHomeScore;
    record.aggregate_away_score = aggregateAwayScore;
  }

  const scoreStatus = String(match.score_status || match.match_time || "").trim();
  if (scoreStatus) {
    record.score_status = scoreStatus;
  }

  if (match.details_url) {
    record.details_url = String(match.details_url);
  }

  if (match.match_details_id) {
    record.match_details_id = String(match.match_details_id);
  }

  [
    "home_goal_scorers",
    "away_goal_scorers",
    "home_assists",
    "away_assists",
    "home_red_cards",
    "away_red_cards",
  ].forEach((field) => {
    if (Array.isArray(match[field])) record[field] = match[field];
  });

  const penaltyResult = String(match.penalty_result || "").trim();
  if (penaltyResult) {
    record.penalty_result = penaltyResult;
  }

  return record;
}

function toMatchListPayload(match, options = {}) {
  const normalized = normalizeMatchRecord(match);
  if (!normalized) return null;

  const payload = {
    date: normalized.date,
    time: normalized.time,
    league: normalized.league,
    home_team: normalized.home_team,
    away_team: normalized.away_team,
    tv_channels: uniqueChannels(normalized.tv_channels),
  };

  if (normalized.league_subcategory) {
    payload.league_subcategory = normalized.league_subcategory;
  } else {
  }

  if (normalized.home_score !== undefined && normalized.home_score !== null) {
    payload.home_score = normalized.home_score;
  }
  if (normalized.away_score !== undefined && normalized.away_score !== null) {
    payload.away_score = normalized.away_score;
  }
  if (normalized.aggregate_home_score !== undefined && normalized.aggregate_home_score !== null) {
    payload.aggregate_home_score = normalized.aggregate_home_score;
  }
  if (normalized.aggregate_away_score !== undefined && normalized.aggregate_away_score !== null) {
    payload.aggregate_away_score = normalized.aggregate_away_score;
  }
  if (normalized.score_status) {
    payload.score_status = normalized.score_status;
  }

  // Try to get match details ID from details_url or explicit match_details_id field
  let detailsId = matchDetailsIdFromUrl(normalized.details_url);
  if (!detailsId && normalized.match_details_id) {
    // For test matches or matches with explicit match_details_id
    detailsId = normalizeMatchDetailsId(normalized.match_details_id);
  }
  if (detailsId) {
    payload.match_details_id = detailsId;
  }

  const matchDetailsLookup =
    options && options.matchDetailsLookup ? options.matchDetailsLookup : null;

  // Check if we have enriched match details (including penalty_result) in the cache
  let penaltyResult = normalized.penalty_result;
  let aggregateHomeScore = normalized.aggregate_home_score;
  let aggregateAwayScore = normalized.aggregate_away_score;
  if (detailsId && matchDetailsLookup) {
    const matchDetails =
      matchDetailsLookup instanceof Map
        ? matchDetailsLookup.get(detailsId)
        : matchDetailsLookup[detailsId];
    if (matchDetails) {
      // CRITICAL FIX: Only use penalty_result if the cached details match this actual match
      const teamsMatch = (() => {
        const normalizedHome = normalizeTeamName(normalized.home_team || "");
        const normalizedAway = normalizeTeamName(normalized.away_team || "");
        const detailsHome = normalizeTeamName(matchDetails.home_team || "");
        const detailsAway = normalizeTeamName(matchDetails.away_team || "");
        if (!normalizedHome || !normalizedAway || !detailsHome || !detailsAway) return false;
        return normalizedHome === detailsHome && normalizedAway === detailsAway;
      })();
      if (
        teamsMatch
      ) {
        if (!penaltyResult && matchDetails.penalty_result) {
          penaltyResult = matchDetails.penalty_result;
        }
        if (aggregateHomeScore === undefined || aggregateHomeScore === null) {
          aggregateHomeScore = parseNumericScore(matchDetails.aggregate_home_score);
        }
        if (aggregateAwayScore === undefined || aggregateAwayScore === null) {
          aggregateAwayScore = parseNumericScore(matchDetails.aggregate_away_score);
        }
      }
    }
  }

  if (aggregateHomeScore !== undefined && aggregateHomeScore !== null) {
    payload.aggregate_home_score = aggregateHomeScore;
  }
  if (aggregateAwayScore !== undefined && aggregateAwayScore !== null) {
    payload.aggregate_away_score = aggregateAwayScore;
  }

  // Clean up penalty_result - only use it if it's a non-empty string
  if (penaltyResult !== null && penaltyResult !== undefined) {
    if (typeof penaltyResult === 'string') {
      penaltyResult = penaltyResult.trim();
      if (!penaltyResult) {
        penaltyResult = null;
      }
    } else {
      penaltyResult = null;
    }
  }

  // If we have a penalty result (shootout complete) and status is "Pens", change to "AET"
  if (penaltyResult && (payload.score_status === "Pens" || payload.score_status === "PEN" || payload.score_status === "PEN.")) {
    payload.score_status = "AET";
  }

  // Include penalty_result in the payload only if it exists, is non-empty, AND the match status is AET
  // (AET means the penalty shootout is complete, so we should show the result)
  if (penaltyResult && payload.score_status === "AET") {
    payload.penalty_result = penaltyResult;
  }

  return payload;
}

function monitorCandidateSortAsc(lhs, rhs) {
  const lhsDate = String(lhs && lhs.date ? lhs.date : "").trim();
  const rhsDate = String(rhs && rhs.date ? rhs.date : "").trim();
  const dateCompare = lhsDate.localeCompare(rhsDate);
  if (dateCompare !== 0) return dateCompare;

  const lhsTime = normalizeTimeValue(lhs && lhs.time ? lhs.time : null);
  const rhsTime = normalizeTimeValue(rhs && rhs.time ? rhs.time : null);
  const timeCompare = lhsTime.localeCompare(rhsTime);
  if (timeCompare !== 0) return timeCompare;

  const lhsId = String(lhs && lhs.match_details_id ? lhs.match_details_id : "");
  const rhsId = String(rhs && rhs.match_details_id ? rhs.match_details_id : "");
  return lhsId.localeCompare(rhsId);
}

function toMonitorCandidateFromDetailsPayload(payload) {
  if (!payload || typeof payload !== "object") return null;
  const matchId = normalizeMatchDetailsId(payload.id);
  if (!matchId) return null;

  const date = isDateOnly(payload.date) ? String(payload.date).trim() : null;
  if (!date) return null;

  const time = TIME_ONLY_PATTERN.test(String(payload.time || "").trim())
    ? String(payload.time).trim()
    : "00:00";
  const homeScore = parseNumericScore(payload.home_score);
  const awayScore = parseNumericScore(payload.away_score);

  const candidate = {
    match_details_id: matchId,
    date,
    time,
    league: String(payload.league || "").trim() || null,
    home_team: String(payload.home_team || "").trim() || null,
    away_team: String(payload.away_team || "").trim() || null,
    score_status: String(payload.score_status || "").trim() || null,
    details_url: String(payload.details_url || "").trim() || null,
    tv_channels: [],
    source_details_updated_at: String(payload.updated_at || "").trim() || null,
  };

  if (homeScore !== null) candidate.home_score = homeScore;
  if (awayScore !== null) candidate.away_score = awayScore;

  return candidate;
}

function mergeMonitorCandidate(existing, incoming) {
  if (!existing) return incoming ? { ...incoming } : null;
  if (!incoming) return { ...existing };

  const merged = { ...existing };
  const textFields = [
    "date",
    "time",
    "league",
    "home_team",
    "away_team",
    "score_status",
    "details_url",
    "source_details_updated_at",
  ];
  textFields.forEach((field) => {
    const value = incoming[field];
    if (value !== null && value !== undefined && String(value).trim().length > 0) {
      merged[field] = value;
    }
  });

  if (Number.isFinite(Number(incoming.home_score))) merged.home_score = Number(incoming.home_score);
  if (Number.isFinite(Number(incoming.away_score))) merged.away_score = Number(incoming.away_score);

  const mergedChannels = uniqueChannels([
    ...(Array.isArray(existing.tv_channels) ? existing.tv_channels : []),
    ...(Array.isArray(incoming.tv_channels) ? incoming.tv_channels : []),
  ]);
  if (mergedChannels.length > 0) {
    merged.tv_channels = mergedChannels;
  } else if (!Array.isArray(merged.tv_channels)) {
    merged.tv_channels = [];
  }

  return merged;
}

function mergeTvChannels(lhs, rhs) {
  const merged = uniqueChannels(lhs);
  uniqueChannels(rhs).forEach((channel) => {
    if (!merged.includes(channel)) merged.push(channel);
  });
  return merged;
}

function mergePreferredMatch(existing, incoming, preferIncoming) {
  const merged = { ...existing };

  if (preferIncoming && incoming.league) merged.league = incoming.league;
  if (!merged.league && incoming.league) merged.league = incoming.league;

  // Merge league_subcategory field
  if (preferIncoming && incoming.league_subcategory) {
    merged.league_subcategory = incoming.league_subcategory;
  } else if (!merged.league_subcategory && incoming.league_subcategory) {
    merged.league_subcategory = incoming.league_subcategory;
  }

  if (preferIncoming) {
    if (incoming.time && (incoming.time !== "00:00" || merged.time === "00:00")) {
      merged.time = incoming.time;
    }
  } else if ((merged.time === "00:00" || !merged.time) && incoming.time) {
    merged.time = incoming.time;
  }

  if (incoming.home_score !== undefined && incoming.home_score !== null) {
    merged.home_score = incoming.home_score;
  }
  if (incoming.away_score !== undefined && incoming.away_score !== null) {
    merged.away_score = incoming.away_score;
  }
  if (incoming.aggregate_home_score !== undefined && incoming.aggregate_home_score !== null) {
    merged.aggregate_home_score = incoming.aggregate_home_score;
  }
  if (incoming.aggregate_away_score !== undefined && incoming.aggregate_away_score !== null) {
    merged.aggregate_away_score = incoming.aggregate_away_score;
  }
  if (incoming.score_status) merged.score_status = incoming.score_status;
  if (incoming.details_url) merged.details_url = incoming.details_url;

  [
    "home_goal_scorers",
    "away_goal_scorers",
    "home_assists",
    "away_assists",
    "home_red_cards",
    "away_red_cards",
  ].forEach((field) => {
    if (Array.isArray(incoming[field])) {
      merged[field] = incoming[field];
    }
  });

  if (incoming.penalty_result) {
    merged.penalty_result = incoming.penalty_result;
  }

  // If we have a penalty result (shootout complete) and status is "Pens", change to "AET"
  if (merged.penalty_result && (merged.score_status === "Pens" || merged.score_status === "PEN" || merged.score_status === "PEN.")) {
    merged.score_status = "AET";
  }

  merged.tv_channels = mergeTvChannels(existing.tv_channels, incoming.tv_channels);
  return merged;
}

function identityKeysForMatch(match) {
  const date = String(match.date || "").trim();
  const time = normalizeTimeValue(match.time);
  const league = normalizeLeagueName(match.league || "").toLowerCase();
  const homeKeys = identityTeamKeys(match.home_team || "");
  const awayKeys = identityTeamKeys(match.away_team || "");
  const keys = new Set();

  homeKeys.forEach((home) => {
    awayKeys.forEach((away) => {
      keys.add(`${date}|${time}|${league}|${home}|${away}`);
      keys.add(`${date}|${league}|${home}|${away}`);
      keys.add(`${date}|${time}|${home}|${away}`);
      keys.add(`${date}|${home}|${away}`);
    });
  });

  return Array.from(keys);
}

function isComparableKickoffTime(lhs, rhs) {
  const leftTime = normalizeTimeValue(lhs.time);
  const rightTime = normalizeTimeValue(rhs.time);
  return leftTime === rightTime || leftTime === "00:00" || rightTime === "00:00";
}

function findFuzzyDuplicatePrimaryKey(normalized, byPrimaryKey) {
  let best = null;
  byPrimaryKey.forEach((existing, primaryKey) => {
    if (!existing) return;
    if (String(existing.date || "") !== String(normalized.date || "")) return;
    if (!isComparableKickoffTime(existing, normalized)) return;
    if (
      compareInsensitive(
        normalizeLeagueName(existing.league || ""),
        normalizeLeagueName(normalized.league || "")
      ) !== 0
    ) {
      return;
    }

    // Check if at least one team matches with high confidence
    const homeHomeScore = similarityScore(normalized.home_team, existing.home_team);
    const awayAwayScore = similarityScore(normalized.away_team, existing.away_team);
    const homeAwayScore = similarityScore(normalized.home_team, existing.away_team);
    const awayHomeScore = similarityScore(normalized.away_team, existing.home_team);

    // If any single team matches with high confidence, consider it a duplicate
    // This handles cases like "Bodø / Glimt" vs "Bodo/Glimt" where the away team "Inter Milan" is identical
    const maxSingleTeamScore = Math.max(homeHomeScore, awayAwayScore, homeAwayScore, awayHomeScore);

    if (maxSingleTeamScore < DEDUPE_MIN_TEAM_CONFIDENCE) {
      return;
    }

    // Calculate overall confidence for ranking purposes
    const direct = scoreTeams(
      normalized.home_team,
      normalized.away_team,
      existing.home_team,
      existing.away_team,
      0
    );

    if (!best || direct.confidence > best.confidence) {
      best = { primaryKey, confidence: direct.confidence };
    }
  });
  return best ? best.primaryKey : null;
}

function compareMatches(lhs, rhs) {
  const leftDateTime = `${lhs.date || ""} ${normalizeTimeValue(lhs.time)}`;
  const rightDateTime = `${rhs.date || ""} ${normalizeTimeValue(rhs.time)}`;
  if (leftDateTime !== rightDateTime) {
    return leftDateTime < rightDateTime ? -1 : 1;
  }
  const leagueCompare = compareInsensitive(lhs.league || "", rhs.league || "");
  if (leagueCompare !== 0) return leagueCompare;
  const homeCompare = compareInsensitive(lhs.home_team || "", rhs.home_team || "");
  if (homeCompare !== 0) return homeCompare;
  return compareInsensitive(lhs.away_team || "", rhs.away_team || "");
}

function mergeBbcAndLiveMatches(liveMatches, bbcMatches) {
  const byPrimaryKey = new Map();
  const keyToPrimary = new Map();

  function upsert(rawMatch, preferIncoming) {
    const normalized = normalizeMatchRecord(rawMatch);
    if (!normalized) return;
    if (!isAllowedCompetition(normalized.league)) return;

    const identityKeys = identityKeysForMatch(normalized);
    let primaryKey = null;
    identityKeys.forEach((key) => {
      if (!primaryKey && keyToPrimary.has(key)) {
        primaryKey = keyToPrimary.get(key);
      }
    });
    if (!primaryKey) {
      primaryKey = findFuzzyDuplicatePrimaryKey(normalized, byPrimaryKey);
    }
    if (!primaryKey) primaryKey = identityKeys[0];

    const existing = byPrimaryKey.get(primaryKey);
    const merged = existing
      ? mergePreferredMatch(existing, normalized, preferIncoming)
      : normalized;
    byPrimaryKey.set(primaryKey, merged);
    identityKeys.forEach((key) => keyToPrimary.set(key, primaryKey));
  }

  (Array.isArray(liveMatches) ? liveMatches : []).forEach((match) => upsert(match, false));
  (Array.isArray(bbcMatches) ? bbcMatches : []).forEach((match) => upsert(match, true));

  return Array.from(byPrimaryKey.values()).sort(compareMatches);
}

async function rebuildMergedMatchesCache(source = "cache_rebuild") {
  // Include test matches in the merged cache
  const allTestMatches = testMatchState.getAllMatches();
  const testMatchesForMerge = allTestMatches.map(testMatch => ({
    date: testMatch.date,
    time: testMatch.time,
    home_team: testMatch.home_team,
    away_team: testMatch.away_team,
    league: testMatch.league,
    league_subcategory: testMatch.league_subcategory,
    details_url: testMatch.details_url,
    match_details_id: testMatch.match_details_id,
    tv_channels: testMatch.tv_channels || [],
    home_score: testMatch.home_score,
    away_score: testMatch.away_score,
    score_status: testMatch.score_status,
    home_goal_scorers: testMatch.home_goal_scorers || [],
    away_goal_scorers: testMatch.away_goal_scorers || [],
    home_assists: testMatch.home_assists || [],
    away_assists: testMatch.away_assists || [],
    home_red_cards: testMatch.home_red_cards || [],
    away_red_cards: testMatch.away_red_cards || [],
    penalty_result: testMatch.penalty_result,
    is_test_match: true
  }));

  // Merge all matches: live matches + BBC range matches + test matches
  const allMatches = [
    ...(Array.isArray(cachedMatches) ? cachedMatches : []),
    ...(Array.isArray(cachedBbcRangeMatches) ? cachedBbcRangeMatches : []),
    ...testMatchesForMerge
  ];

  cachedMergedMatches = mergeBbcAndLiveMatches(allMatches, []);
  indexMatchDetailsFromMatches(cachedMergedMatches);

  const updatedAt =
    newestIsoTimestamp([bbcRangeLastUpdated, lastUpdated, bbcLastUpdated, recentLastUpdated]) ||
    new Date().toISOString();
  await Promise.all([
    persistOperationalDatasetSafe(OP_DATASET_MERGED_MATCHES, cachedMergedMatches, {
      updated_at: updatedAt,
      source,
    }),
    persistOperationalMatchDetailsSafe(Object.fromEntries(matchDetailsById), {
      replace: true,
      updated_at: matchDetailsLastUpdated || updatedAt,
      source,
    }),
  ]);
}

function newestIsoTimestamp(values) {
  let best = null;
  values.forEach((value) => {
    if (!value) return;
    const timestamp = Date.parse(value);
    if (!Number.isFinite(timestamp)) return;
    if (!best || timestamp > best.timestamp) {
      best = { timestamp, value };
    }
  });
  return best ? best.value : null;
}

function parseKickoff(match) {
  if (!match || !match.date || !match.time) return null;
  const dateParts = String(match.date).split("-").map((part) => Number(part));
  const timeParts = String(match.time).split(":").map((part) => Number(part));
  if (dateParts.length !== 3 || timeParts.length < 2) return null;
  const [year, month, day] = dateParts;
  const [hour, minute] = timeParts;
  if (
    !Number.isFinite(year) ||
    !Number.isFinite(month) ||
    !Number.isFinite(day) ||
    !Number.isFinite(hour) ||
    !Number.isFinite(minute)
  ) {
    return null;
  }
  return new Date(year, month - 1, day, hour, minute);
}

function isWithinRetention(match, now = new Date()) {
  const kickoff = parseKickoff(match);
  if (!kickoff) return false;
  const diff = now - kickoff;
  return diff >= 0 && diff <= RECENT_CACHE_MS;
}

function mergeScoreFields(base, scored) {
  const merged = { ...base };
  if (scored.home_score !== undefined && scored.home_score !== null) {
    merged.home_score = scored.home_score;
  }
  if (scored.away_score !== undefined && scored.away_score !== null) {
    merged.away_score = scored.away_score;
  }
  if (scored.aggregate_home_score !== undefined && scored.aggregate_home_score !== null) {
    merged.aggregate_home_score = scored.aggregate_home_score;
  }
  if (scored.aggregate_away_score !== undefined && scored.aggregate_away_score !== null) {
    merged.aggregate_away_score = scored.aggregate_away_score;
  }
  if (scored.score_status !== undefined && scored.score_status !== null) {
    merged.score_status = scored.score_status;
  }
  if (Array.isArray(scored.home_goal_scorers)) {
    merged.home_goal_scorers = scored.home_goal_scorers;
  }
  if (Array.isArray(scored.away_goal_scorers)) {
    merged.away_goal_scorers = scored.away_goal_scorers;
  }
  if (Array.isArray(scored.home_assists)) {
    merged.home_assists = scored.home_assists;
  }
  if (Array.isArray(scored.away_assists)) {
    merged.away_assists = scored.away_assists;
  }
  if (Array.isArray(scored.home_red_cards)) {
    merged.home_red_cards = scored.home_red_cards;
  }
  if (Array.isArray(scored.away_red_cards)) {
    merged.away_red_cards = scored.away_red_cards;
  }
  return merged;
}

function applyScoresToMatches(matches, bbcMatches, now = new Date()) {
  if (!Array.isArray(bbcMatches) || bbcMatches.length === 0) return matches;
  return matches.map((match) => {
    const kickoff = parseKickoff(match);
    if (!kickoff || kickoff > now) return match;
    const candidate = bestScoreCandidate(match, bbcMatches);
    if (!candidate) return match;
    const source = candidate.match;
    const swapped = candidate.swapped;
    const merged = {
      ...match,
      home_score: swapped ? source.away_score : source.home_score,
      away_score: swapped ? source.home_score : source.away_score,
      score_status: source.match_time,
    };

    if (source.aggregate_home_score !== undefined && source.aggregate_home_score !== null) {
      merged.aggregate_home_score = swapped
        ? source.aggregate_away_score
        : source.aggregate_home_score;
    }
    if (source.aggregate_away_score !== undefined && source.aggregate_away_score !== null) {
      merged.aggregate_away_score = swapped
        ? source.aggregate_home_score
        : source.aggregate_away_score;
    }

    const homeGoalScorers = swapped ? source.away_goal_scorers : source.home_goal_scorers;
    const awayGoalScorers = swapped ? source.home_goal_scorers : source.away_goal_scorers;
    const homeAssists = swapped ? source.away_assists : source.home_assists;
    const awayAssists = swapped ? source.home_assists : source.away_assists;
    const homeRedCards = swapped ? source.away_red_cards : source.home_red_cards;
    const awayRedCards = swapped ? source.home_red_cards : source.away_red_cards;

    if (Array.isArray(homeGoalScorers)) merged.home_goal_scorers = homeGoalScorers;
    if (Array.isArray(awayGoalScorers)) merged.away_goal_scorers = awayGoalScorers;
    if (Array.isArray(homeAssists)) merged.home_assists = homeAssists;
    if (Array.isArray(awayAssists)) merged.away_assists = awayAssists;
    if (Array.isArray(homeRedCards)) merged.home_red_cards = homeRedCards;
    if (Array.isArray(awayRedCards)) merged.away_red_cards = awayRedCards;

    return merged;
  });
}

function buildLeagueList(matches) {
  const set = new Set();
  matches.forEach((match) => {
    if (!match || !match.league) return;
    const normalized = normalizeLeagueName(match.league);
    if (normalized) set.add(normalized);
  });
  return Array.from(set).sort(compareInsensitive);
}

function buildTeamList(matches, leagueFilter) {
  const set = new Set();
  const normalizedFilter = leagueFilter ? normalizeLeagueName(leagueFilter) : null;
  matches.forEach((match) => {
    if (!match) return;
    if (normalizedFilter) {
      const matchLeague = normalizeLeagueName(match.league || "");
      if (compareInsensitive(matchLeague, normalizedFilter) !== 0) {
        return;
      }
    }
    if (match.home_team) set.add(match.home_team);
    if (match.away_team) set.add(match.away_team);
  });
  return Array.from(set).sort(compareInsensitive);
}

function buildChannelList(matches) {
  const set = new Set(CHANNEL_SPECIAL_OPTIONS);
  matches.forEach((match) => {
    if (!match || !Array.isArray(match.tv_channels)) return;
    match.tv_channels.forEach((channel) => {
      const trimmed = String(channel || "").trim();
      if (trimmed) set.add(trimmed);
    });
  });
  return Array.from(set).sort(compareInsensitive);
}

function normalizeListParam(value) {
  if (!value) return [];
  const raw = Array.isArray(value) ? value : [value];
  const items = [];
  raw.forEach((entry) => {
    String(entry)
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean)
      .forEach((item) => items.push(item));
  });
  return items;
}

function isTruthyParam(value) {
  if (value === undefined || value === null) return false;
  const normalized = String(value).trim().toLowerCase();
  return ["1", "true", "yes", "on"].includes(normalized);
}

function teamMatchesPremierLeague(teamName, premierLeagueTeams) {
  if (!teamName) {
    return false;
  }

  // If Premier League teams haven't loaded yet, fail open (allow all teams)
  // to avoid filtering out all matches
  if (!Array.isArray(premierLeagueTeams) || premierLeagueTeams.length === 0) {
    return true;
  }

  const normalizedTeamName = String(teamName).trim();
  return premierLeagueTeams.some((candidate) => {
    if (!candidate) return false;
    const normalizedCandidate = String(candidate).trim();
    if (compareInsensitive(normalizedTeamName, normalizedCandidate) === 0) {
      return true;
    }
    return similarityScore(normalizedTeamName, normalizedCandidate) >= EPL_TEAM_MIN_CONFIDENCE;
  });
}

function matchIncludesPremierLeagueTeam(match, premierLeagueTeams) {
  if (!match) return false;
  return (
    teamMatchesPremierLeague(match.home_team, premierLeagueTeams) ||
    teamMatchesPremierLeague(match.away_team, premierLeagueTeams)
  );
}

function matchesFilters(match, filters) {
  const { leagues, teams, channels, dateFrom, dateTo, filterMode } = filters;

  const matchLeague = normalizeLeagueName(match.league || "");
  const leagueOk =
    leagues.length === 0 ||
    leagues.some((league) => compareInsensitive(matchLeague, league) === 0);

  const home = match.home_team || "";
  const away = match.away_team || "";
  const teamOk =
    teams.length === 0 ||
    teams.some(
      (team) =>
        compareInsensitive(home, team) === 0 ||
        compareInsensitive(away, team) === 0
    );

  if (leagues.length > 0 || teams.length > 0) {
    const mode = filterMode === "intersection" ? "intersection" : "union";
    if (mode === "intersection") {
      if (!(leagueOk && teamOk)) return false;
    } else {
      if (!(leagueOk || teamOk)) return false;
    }
  }

  const channelList = Array.isArray(match.tv_channels) ? match.tv_channels : [];
  const channelOk =
    channels.length === 0 ||
    channelList.some((channel) =>
      channels.some((selection) => channelMatchesSelection(channel, selection))
    );
  if (!channelOk) return false;

  if (dateFrom || dateTo) {
    const matchDate = match.date || "";
    if (dateFrom && matchDate < dateFrom) return false;
    if (dateTo && matchDate > dateTo) return false;
  }

  return true;
}

function loadFromDisk() {
  try {
    if (!fs.existsSync(OUTPUT_PATH)) return;
    const raw = fs.readFileSync(OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedMatches = filterMatchesByCompetition(parsed);
      setSourceCacheSize(SOURCE_LIVE_FOOTBALL, cachedMatches.length);
      const stat = fs.statSync(OUTPUT_PATH);
      lastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load matches from disk:", err.message || err);
  }
}

function loadBbcFromDisk() {
  try {
    if (!fs.existsSync(BBC_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(BBC_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedBbcMatches = parsed;
      setSourceCacheSize(SOURCE_BBC_LIVE, cachedBbcMatches.length);
      const stat = fs.statSync(BBC_OUTPUT_PATH);
      bbcLastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load BBC matches from disk:", err.message || err);
  }
}

function loadBbcRangeFromDisk() {
  try {
    if (!fs.existsSync(BBC_RANGE_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(BBC_RANGE_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedBbcRangeMatches = filterMatchesByCompetition(parsed);
      setSourceCacheSize(SOURCE_BBC_RANGE, cachedBbcRangeMatches.length);
      const stat = fs.statSync(BBC_RANGE_OUTPUT_PATH);
      bbcRangeLastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load BBC range matches from disk:", err.message || err);
  }
}

function loadRecentFromDisk() {
  try {
    if (!fs.existsSync(RECENT_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(RECENT_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedRecentMatches = filterMatchesByCompetition(parsed);
      setSourceCacheSize(SOURCE_RECENT_CACHE, cachedRecentMatches.length);
      const stat = fs.statSync(RECENT_OUTPUT_PATH);
      recentLastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load recent matches from disk:", err.message || err);
  }
}

function loadPremierLeagueFromDisk() {
  try {
    if (!fs.existsSync(EPL_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(EPL_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedPremierLeagueTeams = parsed
        .map((team) => String(team || "").trim())
        .filter(Boolean);
      setSourceCacheSize(SOURCE_BBC_PREMIER_LEAGUE, cachedPremierLeagueTeams.length);
      const stat = fs.statSync(EPL_OUTPUT_PATH);
      eplLastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load Premier League teams from disk:", err.message || err);
  }
}

function loadLeagueTablesFromDisk() {
  try {
    if (!fs.existsSync(LEAGUE_TABLES_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(LEAGUE_TABLES_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cachedLeagueTables = sortLeagueTablesForResponse(parsed);
      setSourceCacheSize(SOURCE_BBC_LEAGUE_TABLES, leagueTableRowsCount(cachedLeagueTables));
      const stat = fs.statSync(LEAGUE_TABLES_OUTPUT_PATH);
      leagueTablesLastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load league tables from disk:", err.message || err);
  }
}

function loadMissingTeamLogosFromDisk() {
  try {
    if (!fs.existsSync(MISSING_TEAM_LOGOS_OUTPUT_PATH)) return;
    const raw = fs.readFileSync(MISSING_TEAM_LOGOS_OUTPUT_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      missingTeamLogosByKey = new Map();
      parsed.forEach((teamName) => {
        const normalized = normalizeMissingTeamLogoName(teamName);
        if (!normalized) return;
        missingTeamLogosByKey.set(missingTeamLogoKey(normalized), normalized);
      });
      const stat = fs.statSync(MISSING_TEAM_LOGOS_OUTPUT_PATH);
      missingTeamLogosLastUpdated = stat.mtime.toISOString();
    }
  } catch (err) {
    console.warn("Failed to load missing team logos from disk:", err.message || err);
  }
}

function writeRecentMatches(outputPath, matches) {
  try {
    fs.writeFileSync(outputPath, JSON.stringify(matches, null, 2), "utf8");
  } catch (err) {
    console.warn("Failed to write recent matches to disk:", err.message || err);
  }
}

function writeBbcRangeMatches(outputPath, matches) {
  try {
    fs.writeFileSync(outputPath, JSON.stringify(matches, null, 2), "utf8");
  } catch (err) {
    console.warn("Failed to write BBC range matches to disk:", err.message || err);
  }
}

function writeMissingTeamLogos(outputPath, teamNames) {
  try {
    fs.writeFileSync(outputPath, JSON.stringify(teamNames, null, 2), "utf8");
  } catch (err) {
    console.warn("Failed to write missing team logos to disk:", err.message || err);
  }
}

async function persistOperationalDatasetSafe(name, payload, options = {}) {
  if (!name) return null;
  try {
    return await saveOperationalDataset(name, payload, options);
  } catch (error) {
    console.warn(
      `[OperationalState] Failed to persist dataset ${name}:`,
      error.message || error
    );
    return null;
  }
}

async function loadOperationalDatasetSafe(name) {
  if (!name) return null;
  try {
    return await getOperationalDataset(name);
  } catch (error) {
    console.warn(
      `[OperationalState] Failed to load dataset ${name}:`,
      error.message || error
    );
    return null;
  }
}

async function persistOperationalMatchDetailsSafe(recordsById, options = {}) {
  try {
    return await saveOperationalMatchDetailsRecords(recordsById, options);
  } catch (error) {
    console.warn(
      "[OperationalState] Failed to persist match details to Redis:",
      error.message || error
    );
    return null;
  }
}

async function hydrateOperationalStateFromRedis() {
  try {
    const datasetRecords = await getOperationalDatasets([
      OP_DATASET_LIVE_MATCHES,
      OP_DATASET_BBC_LIVE_MATCHES,
      OP_DATASET_BBC_RANGE_MATCHES,
      OP_DATASET_RECENT_MATCHES,
      OP_DATASET_MERGED_MATCHES,
      OP_DATASET_PREMIER_LEAGUE_TEAMS,
      OP_DATASET_LEAGUE_TABLES,
      OP_DATASET_MISSING_TEAM_LOGOS,
    ]);
    const matchDetailsSnapshot = await getAllOperationalMatchDetails();

    const liveRecord = datasetRecords[OP_DATASET_LIVE_MATCHES];
    if (liveRecord && Array.isArray(liveRecord.payload)) {
      cachedMatches = filterMatchesByCompetition(liveRecord.payload);
      lastUpdated = liveRecord.updated_at || lastUpdated;
      setSourceCacheSize(SOURCE_LIVE_FOOTBALL, cachedMatches.length);
    }

    const bbcLiveRecord = datasetRecords[OP_DATASET_BBC_LIVE_MATCHES];
    if (bbcLiveRecord && Array.isArray(bbcLiveRecord.payload)) {
      cachedBbcMatches = bbcLiveRecord.payload;
      bbcLastUpdated = bbcLiveRecord.updated_at || bbcLastUpdated;
      setSourceCacheSize(SOURCE_BBC_LIVE, cachedBbcMatches.length);
    }

    const bbcRangeRecord = datasetRecords[OP_DATASET_BBC_RANGE_MATCHES];
    if (bbcRangeRecord && Array.isArray(bbcRangeRecord.payload)) {
      cachedBbcRangeMatches = filterMatchesByCompetition(bbcRangeRecord.payload);
      bbcRangeLastUpdated = bbcRangeRecord.updated_at || bbcRangeLastUpdated;
      setSourceCacheSize(SOURCE_BBC_RANGE, cachedBbcRangeMatches.length);
    }

    const recentRecord = datasetRecords[OP_DATASET_RECENT_MATCHES];
    if (recentRecord && Array.isArray(recentRecord.payload)) {
      cachedRecentMatches = filterMatchesByCompetition(recentRecord.payload);
      recentLastUpdated = recentRecord.updated_at || recentLastUpdated;
      setSourceCacheSize(SOURCE_RECENT_CACHE, cachedRecentMatches.length);
    }

    const mergedRecord = datasetRecords[OP_DATASET_MERGED_MATCHES];
    if (mergedRecord && Array.isArray(mergedRecord.payload)) {
      cachedMergedMatches = filterMatchesByCompetition(mergedRecord.payload);
    }

    const teamsRecord = datasetRecords[OP_DATASET_PREMIER_LEAGUE_TEAMS];
    if (teamsRecord && Array.isArray(teamsRecord.payload)) {
      cachedPremierLeagueTeams = teamsRecord.payload
        .map((team) => String(team || "").trim())
        .filter(Boolean);
      eplLastUpdated = teamsRecord.updated_at || eplLastUpdated;
      setSourceCacheSize(SOURCE_BBC_PREMIER_LEAGUE, cachedPremierLeagueTeams.length);
    }

    const leagueTablesRecord = datasetRecords[OP_DATASET_LEAGUE_TABLES];
    if (leagueTablesRecord && Array.isArray(leagueTablesRecord.payload)) {
      cachedLeagueTables = sortLeagueTablesForResponse(leagueTablesRecord.payload);
      leagueTablesLastUpdated = leagueTablesRecord.updated_at || leagueTablesLastUpdated;
      setSourceCacheSize(SOURCE_BBC_LEAGUE_TABLES, leagueTableRowsCount(cachedLeagueTables));
    }

    const missingLogosRecord = datasetRecords[OP_DATASET_MISSING_TEAM_LOGOS];
    if (missingLogosRecord && Array.isArray(missingLogosRecord.payload)) {
      missingTeamLogosByKey = new Map();
      missingLogosRecord.payload.forEach((teamName) => {
        const normalized = normalizeMissingTeamLogoName(teamName);
        if (!normalized) return;
        missingTeamLogosByKey.set(missingTeamLogoKey(normalized), normalized);
      });
      missingTeamLogosLastUpdated = missingLogosRecord.updated_at || missingTeamLogosLastUpdated;
    }

    if (matchDetailsSnapshot && matchDetailsSnapshot.records) {
      const entries = Object.entries(matchDetailsSnapshot.records);
      matchDetailsById = new Map(entries);
      if (matchDetailsSnapshot.updated_at) {
        matchDetailsLastUpdated = matchDetailsSnapshot.updated_at;
      }
      setSourceCacheSize(SOURCE_BBC_MATCH_DETAILS, matchDetailsById.size);
    }

    console.log(
      "[OperationalState] Hydrated from Redis:",
      JSON.stringify({
        live_matches: cachedMatches.length,
        bbc_live_matches: cachedBbcMatches.length,
        bbc_range_matches: cachedBbcRangeMatches.length,
        merged_matches: cachedMergedMatches.length,
        recent_matches: cachedRecentMatches.length,
        league_tables: cachedLeagueTables.length,
        match_details: matchDetailsById.size,
      })
    );
  } catch (error) {
    console.warn("[OperationalState] Failed to hydrate from Redis:", error.message || error);
  }
}

async function persistStartupOperationalStateFromDisk() {
  await Promise.all([
    persistOperationalDatasetSafe(OP_DATASET_LIVE_MATCHES, cachedMatches, {
      updated_at: lastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_BBC_LIVE_MATCHES, cachedBbcMatches, {
      updated_at: bbcLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_BBC_RANGE_MATCHES, cachedBbcRangeMatches, {
      updated_at: bbcRangeLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_RECENT_MATCHES, cachedRecentMatches, {
      updated_at: recentLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_MERGED_MATCHES, cachedMergedMatches, {
      updated_at: newestIsoTimestamp([bbcRangeLastUpdated, lastUpdated, bbcLastUpdated]) || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_PREMIER_LEAGUE_TEAMS, cachedPremierLeagueTeams, {
      updated_at: eplLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_LEAGUE_TABLES, cachedLeagueTables, {
      updated_at: leagueTablesLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalDatasetSafe(OP_DATASET_MISSING_TEAM_LOGOS, sortedMissingTeamLogoNames(), {
      updated_at: missingTeamLogosLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
    persistOperationalMatchDetailsSafe(Object.fromEntries(matchDetailsById), {
      replace: true,
      updated_at: matchDetailsLastUpdated || new Date().toISOString(),
      source: "startup_disk_seed",
    }),
  ]);
}

async function getOperationalArrayDataset(name, fallback = []) {
  const record = await loadOperationalDatasetSafe(name);
  if (record && Array.isArray(record.payload)) {
    return {
      items: record.payload,
      updated_at: record.updated_at || null,
      source: "redis",
    };
  }
  const fallbackItems = Array.isArray(fallback) ? fallback : [];
  return {
    items: fallbackItems,
    updated_at: null,
    source: "memory_fallback",
  };
}

async function getOperationalMatchDetailsByIdSafe(matchId) {
  const payload = await getOperationalMatchDetails(matchId);
  if (payload && typeof payload === "object") {
    return { payload, source: "redis" };
  }
  return {
    payload: null,
    source: "redis_missing",
  };
}

async function getOperationalMatchDetailsSnapshotSafe() {
  const snapshot = await getAllOperationalMatchDetails();
  if (snapshot && snapshot.records && typeof snapshot.records === "object") {
    return {
      ...snapshot,
      source: "redis",
    };
  }
  return {
    updated_at: null,
    total: 0,
    records: {},
    source: "redis_missing",
    error: snapshot && snapshot.error ? snapshot.error : null,
  };
}

const ADMIN_OPERATIONAL_DATASET_NAMES = [
  OP_DATASET_MERGED_MATCHES,
  OP_DATASET_LIVE_MATCHES,
  OP_DATASET_BBC_LIVE_MATCHES,
  OP_DATASET_BBC_RANGE_MATCHES,
  OP_DATASET_RECENT_MATCHES,
  OP_DATASET_PREMIER_LEAGUE_TEAMS,
  OP_DATASET_LEAGUE_TABLES,
];

function toOperationalAdminMatchPayload(payload) {
  if (!payload || typeof payload !== "object") return null;
  const matchId = normalizeMatchDetailsId(payload.id) || null;
  if (!matchId) return null;
  return {
    match_id: matchId,
    id: matchId,
    details_url: payload.details_url || null,
    date: payload.date || null,
    time: payload.time || null,
    league: payload.league || null,
    home_team: payload.home_team || null,
    away_team: payload.away_team || null,
    home_score:
      payload.home_score !== undefined && payload.home_score !== null ? payload.home_score : null,
    away_score:
      payload.away_score !== undefined && payload.away_score !== null ? payload.away_score : null,
    aggregate_home_score:
      payload.aggregate_home_score !== undefined && payload.aggregate_home_score !== null
        ? payload.aggregate_home_score
        : null,
    aggregate_away_score:
      payload.aggregate_away_score !== undefined && payload.aggregate_away_score !== null
        ? payload.aggregate_away_score
        : null,
    score_status: payload.score_status || null,
    in_progress: Boolean(payload.in_progress),
    penalty_result: payload.penalty_result || null,
    home_goal_scorers: Array.isArray(payload.home_goal_scorers) ? payload.home_goal_scorers : [],
    away_goal_scorers: Array.isArray(payload.away_goal_scorers) ? payload.away_goal_scorers : [],
    home_assists: Array.isArray(payload.home_assists) ? payload.home_assists : [],
    away_assists: Array.isArray(payload.away_assists) ? payload.away_assists : [],
    home_red_cards: Array.isArray(payload.home_red_cards) ? payload.home_red_cards : [],
    away_red_cards: Array.isArray(payload.away_red_cards) ? payload.away_red_cards : [],
    updated_at: payload.updated_at || null,
  };
}

function operationalMatchSortDesc(lhs, rhs) {
  const lhsUpdated = Date.parse(lhs && lhs.updated_at ? lhs.updated_at : "");
  const rhsUpdated = Date.parse(rhs && rhs.updated_at ? rhs.updated_at : "");
  if (Number.isFinite(lhsUpdated) || Number.isFinite(rhsUpdated)) {
    const leftValue = Number.isFinite(lhsUpdated) ? lhsUpdated : 0;
    const rightValue = Number.isFinite(rhsUpdated) ? rhsUpdated : 0;
    if (rightValue !== leftValue) return rightValue - leftValue;
  }
  const lhsKickoff = Date.parse(
    `${String(lhs && lhs.date ? lhs.date : "").trim()}T${String(
      lhs && lhs.time ? lhs.time : "00:00"
    ).trim()}:00Z`
  );
  const rhsKickoff = Date.parse(
    `${String(rhs && rhs.date ? rhs.date : "").trim()}T${String(
      rhs && rhs.time ? rhs.time : "00:00"
    ).trim()}:00Z`
  );
  if (Number.isFinite(lhsKickoff) || Number.isFinite(rhsKickoff)) {
    const leftValue = Number.isFinite(lhsKickoff) ? lhsKickoff : 0;
    const rightValue = Number.isFinite(rhsKickoff) ? rhsKickoff : 0;
    if (rightValue !== leftValue) return rightValue - leftValue;
  }
  const lhsId = String(lhs && lhs.match_id ? lhs.match_id : "");
  const rhsId = String(rhs && rhs.match_id ? rhs.match_id : "");
  return lhsId.localeCompare(rhsId);
}

async function getOperationalRealtimeSnapshot(options = {}) {
  const matchIdFilter = normalizeMatchDetailsId(options.match_id || "");
  const limitMatches = parsePositiveInt(options.limit_matches, 0, 0, 1000);
  const nowIso = new Date().toISOString();

  try {
    const [datasetRecords, matchDetailsSummary] = await Promise.all([
      getOperationalDatasets(ADMIN_OPERATIONAL_DATASET_NAMES),
      getOperationalMatchDetailsSummary(),
    ]);

    let matches = [];
    let matchDetailsSource = matchDetailsSummary && matchDetailsSummary.source
      ? matchDetailsSummary.source
      : null;

    if (matchIdFilter) {
      const payload = await getOperationalMatchDetails(matchIdFilter);
      if (payload && typeof payload === "object") {
        const normalizedPayload = toOperationalAdminMatchPayload(payload);
        if (normalizedPayload) {
          matches = [normalizedPayload];
        }
      }
    } else {
      const snapshot = await getAllOperationalMatchDetails();
      if (snapshot && snapshot.records && typeof snapshot.records === "object") {
        matches = Object.values(snapshot.records)
          .map((payload) => toOperationalAdminMatchPayload(payload))
          .filter(Boolean)
          .sort(operationalMatchSortDesc);
        if (limitMatches > 0) {
          matches = matches.slice(0, limitMatches);
        }
        if (snapshot.source) {
          matchDetailsSource = snapshot.source;
        }
      }
    }

    const datasetCounts = {};
    const datasetMeta = {};
    ADMIN_OPERATIONAL_DATASET_NAMES.forEach((name) => {
      const record = datasetRecords && datasetRecords[name] ? datasetRecords[name] : null;
      const payload = record && Array.isArray(record.payload) ? record.payload : [];
      datasetCounts[name] = payload.length;
      datasetMeta[name] = {
        updated_at: record && record.updated_at ? record.updated_at : null,
        source: record && record.source ? record.source : null,
      };
    });

    return {
      generated_at: nowIso,
      filters: {
        match_id: matchIdFilter || null,
        limit_matches: limitMatches > 0 ? limitMatches : null,
      },
      count_matches: matches.length,
      count_match_details_total: Number(matchDetailsSummary && matchDetailsSummary.total
        ? matchDetailsSummary.total
        : 0),
      match_details_updated_at:
        matchDetailsSummary && matchDetailsSummary.updated_at
          ? matchDetailsSummary.updated_at
          : null,
      match_details_source: matchDetailsSource,
      dataset_counts: datasetCounts,
      dataset_meta: datasetMeta,
      matches,
    };
  } catch (error) {
    console.error("[API] Error building operational realtime snapshot:", error);
    return {
      generated_at: nowIso,
      filters: {
        match_id: matchIdFilter || null,
        limit_matches: limitMatches > 0 ? limitMatches : null,
      },
      count_matches: 0,
      count_match_details_total: 0,
      match_details_updated_at: null,
      match_details_source: null,
      dataset_counts: {},
      dataset_meta: {},
      matches: [],
      error: error.message || String(error),
    };
  }
}

async function updateRecentCache(source = "recent_cache_refresh") {
  const now = new Date();
  const live = Array.isArray(cachedMatches) ? cachedMatches : [];
  const bbc = Array.isArray(cachedBbcMatches) ? cachedBbcMatches : [];
  const liveKeys = new Set(live.map(matchKey));

  const map = new Map();
  cachedRecentMatches.forEach((match) => {
    if (!match) return;
    map.set(matchKey(match), match);
  });

  live.forEach((match) => {
    if (!match) return;
    const key = matchKey(match);
    const existing = map.get(key);
    map.set(key, existing ? { ...existing, ...match } : { ...match });
  });

  const withScores = applyScoresToMatches(Array.from(map.values()), bbc, now);
  const next = [];
  withScores.forEach((match) => {
    const key = matchKey(match);
    if (liveKeys.has(key) || isWithinRetention(match, now)) {
      next.push(match);
    }
  });

  cachedRecentMatches = next;
  recentLastUpdated = now.toISOString();
  setSourceCacheSize(SOURCE_RECENT_CACHE, cachedRecentMatches.length);
  writeRecentMatches(RECENT_OUTPUT_PATH, cachedRecentMatches);
  indexMatchDetailsFromMatches(cachedRecentMatches, recentLastUpdated);
  await persistOperationalDatasetSafe(OP_DATASET_RECENT_MATCHES, cachedRecentMatches, {
    updated_at: recentLastUpdated,
    source,
  });
}

function mergedMatchesForResponse() {
  return Array.isArray(cachedMergedMatches) ? cachedMergedMatches : [];
}

async function updateMatches() {
  if (updating) return;
  updating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  try {
    const matches = filterMatchesByCompetition(await fetchMatches(SOURCE_URL));
    cachedMatches = matches;
    recordsFetched = matches.length;
    setSourceCacheSize(SOURCE_LIVE_FOOTBALL, matches.length);
    lastUpdated = new Date().toISOString();
    writeMatches(OUTPUT_PATH, matches);
    await persistOperationalDatasetSafe(OP_DATASET_LIVE_MATCHES, matches, {
      updated_at: lastUpdated,
      source: SOURCE_LIVE_FOOTBALL,
    });
    await updateRecentCache(SOURCE_LIVE_FOOTBALL);
    await rebuildMergedMatchesCache(SOURCE_LIVE_FOOTBALL);
    success = true;
    console.log(`Updated ${matches.length} matches at ${lastUpdated}`);
  } catch (err) {
    console.warn("Failed to update matches:", err.message || err);
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_LIVE_FOOTBALL,
      startedAtMs,
      success,
      recordsFetched,
    });
    updating = false;
  }
}

function filterStaleBbcMatches(newMatches, cachedMatches) {
  if (!cachedMatches || cachedMatches.length === 0) {
    return newMatches;
  }

  // Build a map of cached matches by team names for quick lookup
  const cachedMap = new Map();
  cachedMatches.forEach((match) => {
    const key = `${match.home_team}|${match.away_team}`.toLowerCase();
    cachedMap.set(key, match);
  });

  const filtered = [];
  let staleCount = 0;

  newMatches.forEach((newMatch) => {
    const key = `${newMatch.home_team}|${newMatch.away_team}`.toLowerCase();
    const cached = cachedMap.get(key);

    if (!cached) {
      // New match, not in cache - accept it
      filtered.push(newMatch);
      return;
    }

    // Check if the new match data is stale (match time has regressed)
    const newTime = parseMatchTimeMinutes(newMatch.match_time);
    const cachedTime = parseMatchTimeMinutes(cached.match_time);

    if (newTime !== null && cachedTime !== null && newTime < cachedTime) {
      console.log(
        `[STALE DATA] Rejecting stale BBC data for ${newMatch.home_team} vs ${newMatch.away_team} - ` +
        `new time=${newTime}' cached time=${cachedTime}' (time regressed)`
      );
      staleCount++;
      filtered.push(cached); // Keep the cached version
      return;
    }

    // Check if scores have regressed
    if (cached.home_score !== null && cached.away_score !== null) {
      const cachedTotal = cached.home_score + cached.away_score;
      const newTotal = (newMatch.home_score || 0) + (newMatch.away_score || 0);

      if (newTotal < cachedTotal && newTime <= cachedTime) {
        console.log(
          `[STALE DATA] Rejecting stale BBC data for ${newMatch.home_team} vs ${newMatch.away_team} - ` +
          `scores regressed from ${cached.home_score}-${cached.away_score} to ${newMatch.home_score}-${newMatch.away_score}`
        );
        staleCount++;
        filtered.push(cached); // Keep the cached version
        return;
      }
    }

    // Data looks fresh - accept it
    filtered.push(newMatch);
  });

  if (staleCount > 0) {
    console.log(`[STALE DATA] Filtered out ${staleCount} stale match(es) from BBC update`);
  }

  return filtered;
}

function parseMatchTimeMinutes(matchTime) {
  if (!matchTime || typeof matchTime !== 'string') return null;

  const trimmed = matchTime.trim();

  // Extract minute value (e.g., "45+2" -> 47, "90" -> 90)
  const match = trimmed.match(/^(\d+)(?:\+(\d+))?['']?$/);
  if (match) {
    const base = parseInt(match[1], 10);
    const added = match[2] ? parseInt(match[2], 10) : 0;
    return base + added;
  }

  // Handle "HT", "FT", "AET", etc. - assign high values so they don't regress
  if (/^(HT|Half.?Time)$/i.test(trimmed)) return 45;
  if (/^(FT|Full.?Time)$/i.test(trimmed)) return 90;
  if (/^AET$/i.test(trimmed)) return 120;
  if (/^(Pens?|Penalty|PEN\.?)$/i.test(trimmed)) return 120;

  return null;
}

async function updateBbcMatches() {
  if (bbcUpdating) return;
  bbcUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  try {
    const matches = await fetchBbcFixtures(BBC_SOURCE_URL);
    const filteredMatches = filterStaleBbcMatches(matches, cachedBbcMatches);
    cachedBbcMatches = filteredMatches;
    recordsFetched = filteredMatches.length;
    setSourceCacheSize(SOURCE_BBC_LIVE, filteredMatches.length);
    bbcLastUpdated = new Date().toISOString();
    writeBbcFixtures(BBC_OUTPUT_PATH, filteredMatches);
    await persistOperationalDatasetSafe(OP_DATASET_BBC_LIVE_MATCHES, filteredMatches, {
      updated_at: bbcLastUpdated,
      source: SOURCE_BBC_LIVE,
    });
    await updateRecentCache(SOURCE_BBC_LIVE);
    indexMatchDetailsFromMatches(filteredMatches, bbcLastUpdated);
    const detailsSubset = collectMatchDetailsSubsetByMatches(filteredMatches);
    await persistOperationalMatchDetailsSafe(detailsSubset, {
      replace: false,
      updated_at: bbcLastUpdated,
      source: SOURCE_BBC_LIVE,
    });
    success = true;
    console.log(`Updated BBC live matches (${filteredMatches.length}) at ${bbcLastUpdated}`);
  } catch (err) {
    console.warn("Failed to update BBC matches:", err.message || err);
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_BBC_LIVE,
      startedAtMs,
      success,
      recordsFetched,
    });
    bbcUpdating = false;
  }
}

async function updateBbcRangeMatches() {
  if (bbcRangeUpdating) return;
  bbcRangeUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  try {
    const matches = filterMatchesByCompetition(
      await fetchBbcScoresFixturesByDateRange({
        baseUrl: BBC_RANGE_BASE_URL,
        pastDays: BBC_RANGE_PAST_DAYS,
        futureDays: BBC_RANGE_FUTURE_DAYS,
        concurrency: BBC_RANGE_CONCURRENCY,
        timeZone: BBC_RANGE_MATCH_TIMEZONE,
      })
    );
    cachedBbcRangeMatches = matches;
    recordsFetched = matches.length;
    setSourceCacheSize(SOURCE_BBC_RANGE, matches.length);
    bbcRangeLastUpdated = new Date().toISOString();
    writeBbcRangeMatches(BBC_RANGE_OUTPUT_PATH, matches);
    await persistOperationalDatasetSafe(OP_DATASET_BBC_RANGE_MATCHES, matches, {
      updated_at: bbcRangeLastUpdated,
      source: SOURCE_BBC_RANGE,
    });
    await rebuildMergedMatchesCache(SOURCE_BBC_RANGE);
    success = true;
    console.log(
      `Updated BBC date-range matches (${matches.length}) at ${bbcRangeLastUpdated} ` +
      `(window ${BBC_RANGE_PAST_DAYS}d past to ${BBC_RANGE_FUTURE_DAYS}d future)`
    );
  } catch (err) {
    console.warn("Failed to update BBC date-range matches:", err.message || err);
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_BBC_RANGE,
      startedAtMs,
      success,
      recordsFetched,
    });
    bbcRangeUpdating = false;
  }
}

async function updatePremierLeagueTeams() {
  if (eplUpdating) return;
  eplUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;
  try {
    const teams = await fetchPremierLeagueTeams(EPL_SOURCE_URL);
    if (!Array.isArray(teams) || teams.length === 0) {
      console.warn("Premier League table update returned no teams");
      return;
    }

    cachedPremierLeagueTeams = teams.map((team) => String(team || "").trim()).filter(Boolean);
    recordsFetched = cachedPremierLeagueTeams.length;
    setSourceCacheSize(SOURCE_BBC_PREMIER_LEAGUE, cachedPremierLeagueTeams.length);
    eplLastUpdated = new Date().toISOString();
    writePremierLeagueTeams(EPL_OUTPUT_PATH, cachedPremierLeagueTeams);
    await persistOperationalDatasetSafe(
      OP_DATASET_PREMIER_LEAGUE_TEAMS,
      cachedPremierLeagueTeams,
      {
        updated_at: eplLastUpdated,
        source: SOURCE_BBC_PREMIER_LEAGUE,
      }
    );
    success = true;
    console.log(`Updated Premier League teams (${cachedPremierLeagueTeams.length}) at ${eplLastUpdated}`);
  } catch (err) {
    console.warn("Failed to update Premier League teams:", err.message || err);
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_BBC_PREMIER_LEAGUE,
      startedAtMs,
      success,
      recordsFetched,
    });
    eplUpdating = false;
  }
}

async function updateLeagueTables() {
  if (leagueTablesUpdating) return;
  leagueTablesUpdating = true;
  const startedAtMs = Date.now();
  let success = false;
  let recordsFetched = null;

  try {
    const { tables, errors } = await fetchLeagueTables(LEAGUE_TABLE_SOURCES);

    if (Array.isArray(errors) && errors.length > 0) {
      errors.forEach((error) => {
        console.warn(
          `[LeagueTables] Failed ${error.league_id || "unknown"}: ${error.message || String(error)}`
        );
      });
    }

    if (!Array.isArray(tables) || tables.length === 0) {
      console.warn("League tables update returned no tables");
      return;
    }

    const previousTables = Array.isArray(cachedLeagueTables) ? cachedLeagueTables : [];
    const mergedById = new Map();
    previousTables.forEach((table) => {
      const id = normalizeLeagueTableId(table && table.league_id);
      if (!id) return;
      mergedById.set(id, table);
    });
    tables.forEach((table) => {
      const id = normalizeLeagueTableId(table && table.league_id);
      if (!id) return;
      mergedById.set(id, table);
    });
    const sortedTables = sortLeagueTablesForResponse(Array.from(mergedById.values()));
    const nowIso = new Date().toISOString();
    const updatedAtCandidates = sortedTables
      .map((league) => (league && league.updated_at ? String(league.updated_at) : ""))
      .filter(Boolean);
    const resolvedUpdatedAt = newestIsoTimestamp([...updatedAtCandidates, nowIso]) || nowIso;

    cachedLeagueTables = sortedTables;
    leagueTablesLastUpdated = resolvedUpdatedAt;
    recordsFetched = leagueTableRowsCount(sortedTables);
    setSourceCacheSize(SOURCE_BBC_LEAGUE_TABLES, recordsFetched);

    writeLeagueTables(LEAGUE_TABLES_OUTPUT_PATH, sortedTables);
    await persistOperationalDatasetSafe(OP_DATASET_LEAGUE_TABLES, sortedTables, {
      updated_at: leagueTablesLastUpdated,
      source: SOURCE_BBC_LEAGUE_TABLES,
    });

    // Keep EPL team filters aligned with the live table feed.
    const premierLeagueTeams = extractPremierLeagueTeamsFromTables(sortedTables);
    if (premierLeagueTeams.length > 0) {
      cachedPremierLeagueTeams = premierLeagueTeams;
      eplLastUpdated = leagueTablesLastUpdated;
      setSourceCacheSize(SOURCE_BBC_PREMIER_LEAGUE, cachedPremierLeagueTeams.length);
      await persistOperationalDatasetSafe(
        OP_DATASET_PREMIER_LEAGUE_TEAMS,
        cachedPremierLeagueTeams,
        {
          updated_at: eplLastUpdated,
          source: SOURCE_BBC_LEAGUE_TABLES,
        }
      );
    }

    success = true;
    console.log(
      `Updated league tables (${sortedTables.length} leagues, ${recordsFetched} rows) at ${leagueTablesLastUpdated}`
    );
  } catch (err) {
    console.warn("Failed to update league tables:", err.message || err);
  } finally {
    trackSourceUpdateMetrics({
      source: SOURCE_BBC_LEAGUE_TABLES,
      startedAtMs,
      success,
      recordsFetched,
    });
    leagueTablesUpdating = false;
  }
}

function parseRequiredDateRange(query) {
  const start = query.start ? String(query.start).trim() : "";
  const end = query.end ? String(query.end).trim() : "";
  if (!start || !end) {
    return { error: "Missing required query params: start and end (YYYY-MM-DD)" };
  }
  if (!isDateOnly(start) || !isDateOnly(end)) {
    return { error: "Invalid date range. Expected YYYY-MM-DD for start and end." };
  }
  if (start > end) {
    return { error: "Invalid date range. start must be on or before end." };
  }
  return { start, end };
}

function parsePositiveInt(value, fallback, min = 1, max = Number.MAX_SAFE_INTEGER) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  const normalized = Math.floor(parsed);
  if (normalized < min) return fallback;
  return Math.min(max, normalized);
}

const MAX_BBC_HISTORY_QUERY_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_BBC_HISTORY_QUERY_HOURS = Math.max(1, Math.floor(MAX_BBC_HISTORY_QUERY_MS / (60 * 60 * 1000)));

function parseBbcHistoryWindow(query) {
  const rawStart = query.start ? String(query.start).trim() : "";
  const rawEnd = query.end ? String(query.end).trim() : "";
  const nowMs = Date.now();

  if (rawStart || rawEnd) {
    if (!rawStart || !rawEnd) {
      return {
        error: "When using absolute range, both start and end are required (ISO datetime).",
      };
    }
    const startMs = Date.parse(rawStart);
    const endMs = Date.parse(rawEnd);
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs)) {
      return {
        error: "Invalid start/end datetime. Use ISO format, e.g. 2026-02-21T10:00:00Z.",
      };
    }
    if (endMs < startMs) {
      return { error: "Invalid date range. end must be greater than or equal to start." };
    }
    if (endMs - startMs > MAX_BBC_HISTORY_QUERY_MS) {
      return {
        error: `Maximum query range is ${MAX_BBC_HISTORY_QUERY_HOURS} hours (7 days).`,
      };
    }
    return {
      startMs: Math.floor(startMs),
      endMs: Math.floor(endMs),
      mode: "absolute",
    };
  }

  const hours = parsePositiveInt(query.hours, 24, 1, MAX_BBC_HISTORY_QUERY_HOURS);
  return {
    startMs: nowMs - hours * 60 * 60 * 1000,
    endMs: nowMs,
    mode: "relative",
    hours,
  };
}

function parseStatusMinuteValue(status) {
  return parseMatchStatusMinute(status);
}

function isFinishedMatchStatus(status) {
  const normalized = String(status || "").trim();
  if (!normalized) return false;
  return MATCH_STATUS_COMPLETE_TOKENS.has(normalized.toUpperCase());
}

function displayMatchStatusForAdmin(status) {
  const normalized = String(status || "").trim();
  if (!normalized) return null;
  if (MATCH_STATUS_MINUTE_PATTERN.test(normalized)) {
    return `${normalized.replace(/'/g, "")}'`;
  }
  return normalized;
}

function kickoffTimestampMs(match) {
  const kickoff = parseKickoff(match);
  return kickoff ? kickoff.getTime() : null;
}

function startOfTodayLocal(now = new Date()) {
  return new Date(now.getFullYear(), now.getMonth(), now.getDate());
}

function parseMatchDayLocal(dateValue) {
  const value = String(dateValue || "").trim();
  if (!isDateOnly(value)) return null;
  const [year, month, day] = value.split("-").map((part) => Number(part));
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day)) {
    return null;
  }
  return new Date(year, month - 1, day);
}

function sortAdminMatchesByKickoff(lhs, rhs, direction = "asc") {
  const lhsKickoffMs = Number(lhs && lhs.kickoff_ts_ms);
  const rhsKickoffMs = Number(rhs && rhs.kickoff_ts_ms);
  const lhsHasKickoff = Number.isFinite(lhsKickoffMs);
  const rhsHasKickoff = Number.isFinite(rhsKickoffMs);

  if (lhsHasKickoff || rhsHasKickoff) {
    if (!lhsHasKickoff) return direction === "asc" ? 1 : -1;
    if (!rhsHasKickoff) return direction === "asc" ? -1 : 1;
    if (lhsKickoffMs !== rhsKickoffMs) {
      return direction === "asc" ? lhsKickoffMs - rhsKickoffMs : rhsKickoffMs - lhsKickoffMs;
    }
  }

  const dateCompare = String(lhs && lhs.date ? lhs.date : "").localeCompare(
    String(rhs && rhs.date ? rhs.date : "")
  );
  if (dateCompare !== 0) {
    return direction === "asc" ? dateCompare : -dateCompare;
  }

  const timeCompare = normalizeTimeValue(lhs && lhs.time).localeCompare(
    normalizeTimeValue(rhs && rhs.time)
  );
  if (timeCompare !== 0) {
    return direction === "asc" ? timeCompare : -timeCompare;
  }

  const leagueCompare = compareInsensitive(lhs && lhs.league ? lhs.league : "", rhs && rhs.league ? rhs.league : "");
  if (leagueCompare !== 0) return leagueCompare;
  const homeCompare = compareInsensitive(
    lhs && lhs.home_team ? lhs.home_team : "",
    rhs && rhs.home_team ? rhs.home_team : ""
  );
  if (homeCompare !== 0) return homeCompare;
  return compareInsensitive(
    lhs && lhs.away_team ? lhs.away_team : "",
    rhs && rhs.away_team ? rhs.away_team : ""
  );
}

function toAdminListMatchPayload(match, options = {}) {
  const payload = toMatchListPayload(match, options);
  if (!payload) return null;

  const kickoffMs = kickoffTimestampMs(payload);
  const inProgress = isInProgressMatchStatus(payload.score_status);
  const finished = isFinishedMatchStatus(payload.score_status);
  const hasScore =
    payload.home_score !== undefined &&
    payload.home_score !== null &&
    payload.away_score !== undefined &&
    payload.away_score !== null;

  return {
    ...payload,
    id: payload.match_details_id || matchKey(payload),
    kickoff_ts_ms: Number.isFinite(kickoffMs) ? kickoffMs : null,
    in_progress: inProgress,
    finished,
    has_score: hasScore,
    display_score_status: displayMatchStatusForAdmin(payload.score_status),
  };
}

function isFixtureMatchForAdmin(match, now = new Date()) {
  const nowMs = now.getTime();
  if (match.in_progress || match.finished) return false;

  const kickoffMs = Number(match.kickoff_ts_ms);
  if (Number.isFinite(kickoffMs)) {
    return kickoffMs >= nowMs;
  }

  const day = parseMatchDayLocal(match.date);
  if (!day) return false;
  return day.getTime() >= startOfTodayLocal(now).getTime();
}

function isResultMatchForAdmin(match, now = new Date()) {
  const day = parseMatchDayLocal(match.date);
  const todayStartMs = startOfTodayLocal(now).getTime();

  if (!day) {
    return Boolean(match.in_progress || match.finished);
  }

  const dayMs = day.getTime();
  if (dayMs < todayStartMs) return true;
  if (dayMs > todayStartMs) return false;
  return Boolean(match.in_progress || match.finished);
}

function filterAdminMatches(rawMatches, options = {}) {
  const mode = options.mode === "results" ? "results" : "fixtures";
  const now = options.now instanceof Date ? options.now : new Date();
  const matchDetailsLookup = options.matchDetailsLookup || {};

  const mapped = (Array.isArray(rawMatches) ? rawMatches : [])
    .map((match) => toAdminListMatchPayload(match, { matchDetailsLookup }))
    .filter(Boolean);

  const filtered = mapped.filter((match) => (
    mode === "fixtures" ? isFixtureMatchForAdmin(match, now) : isResultMatchForAdmin(match, now)
  ));

  return filtered.sort((lhs, rhs) =>
    sortAdminMatchesByKickoff(lhs, rhs, mode === "fixtures" ? "asc" : "desc")
  );
}

function extractDeviceNameFromPreferenceRecord(record) {
  if (!record || typeof record !== "object") return null;
  const preferences =
    record.preferences && typeof record.preferences === "object" ? record.preferences : {};
  const candidates = [
    record.deviceName,
    record.device_name,
    record.name,
    preferences.deviceName,
    preferences.device_name,
    preferences.deviceLabel,
    preferences.device_label,
    preferences.displayName,
    preferences.display_name,
    preferences.nickname,
    preferences.name,
  ];

  const selected = candidates.find(
    (value) => typeof value === "string" && value.trim().length > 0
  );
  return selected ? selected.trim().slice(0, 120) : null;
}

function buildDeviceTokenNameLookup(preferenceRecords) {
  const lookup = new Map();
  (Array.isArray(preferenceRecords) ? preferenceRecords : []).forEach((record) => {
    const token = normalizeDeviceToken(record && record.deviceToken);
    if (!token) return;
    const name = extractDeviceNameFromPreferenceRecord(record);
    if (!name) return;
    lookup.set(token, name);
  });
  return lookup;
}

function shortDeviceTokenForAdmin(deviceToken, prefix = 8, suffix = 6) {
  const value = String(deviceToken || "").trim();
  if (!value) return "unknown-device";
  if (value.length <= prefix + suffix + 3) return value;
  return `${value.slice(0, prefix)}...${value.slice(-suffix)}`;
}

function adminHistoryTimestampMs(value) {
  const parsed = Number(value);
  if (Number.isFinite(parsed) && parsed > 0) return Math.floor(parsed);
  return 0;
}

function sortHistoryRecordsByTimestampAsc(lhs, rhs) {
  const left = adminHistoryTimestampMs(lhs && lhs.timestamp_ms);
  const right = adminHistoryTimestampMs(rhs && rhs.timestamp_ms);
  if (left !== right) return left - right;
  return String(lhs && lhs.event_type ? lhs.event_type : "").localeCompare(
    String(rhs && rhs.event_type ? rhs.event_type : "")
  );
}

function normalizeNotificationStatusForAdmin(status) {
  const normalized = String(status || "").trim().toLowerCase();
  if (!normalized) return "unknown";
  if (normalized === "sent") return "sent";
  if (normalized === "failed") return "failed";
  if (normalized === "dedupe_skipped") return "dedupe_skipped";
  return normalized;
}

function notificationGroupKeyForAdmin(record) {
  const eventType = String(record && record.event_type ? record.event_type : "unknown").trim();
  const eventKey = String(record && record.event_key ? record.event_key : "").trim();
  const title = String(record && record.title ? record.title : "").trim();
  const body = String(record && record.body ? record.body : "").trim();
  const dispatchMode = String(record && record.dispatch_mode ? record.dispatch_mode : "").trim();
  const delay = Number.isFinite(Number(record && record.delay_minutes))
    ? Math.floor(Number(record.delay_minutes))
    : 0;

  if (eventKey) {
    return `event:${eventType}|${eventKey}|${title}|${body}|${dispatchMode}|${delay}`;
  }

  const timestampBucket = Math.floor(adminHistoryTimestampMs(record && record.timestamp_ms) / 60_000);
  return `fallback:${eventType}|${title}|${body}|${dispatchMode}|${delay}|${timestampBucket}`;
}

function buildNotificationDispatches(records, deviceTokenNameLookup = new Map()) {
  const sorted = (Array.isArray(records) ? records : [])
    .slice()
    .sort(sortHistoryRecordsByTimestampAsc);
  const grouped = new Map();

  sorted.forEach((record) => {
    const key = notificationGroupKeyForAdmin(record);
    if (!grouped.has(key)) {
      grouped.set(key, {
        dispatch_key: key,
        event_type: String(record && record.event_type ? record.event_type : "unknown"),
        event_key: String(record && record.event_key ? record.event_key : "").trim() || null,
        title: record && record.title ? String(record.title) : null,
        body: record && record.body ? String(record.body) : null,
        delay_minutes: Number.isFinite(Number(record && record.delay_minutes))
          ? Number(record.delay_minutes)
          : 0,
        dispatch_mode: record && record.dispatch_mode ? String(record.dispatch_mode) : null,
        first_timestamp_ms: null,
        last_timestamp_ms: null,
        statuses: {},
        count_notifications: 0,
        _device_tokens_set: new Set(),
      });
    }

    const group = grouped.get(key);
    const timestampMs = adminHistoryTimestampMs(record && record.timestamp_ms);
    if (!group.first_timestamp_ms || timestampMs < group.first_timestamp_ms) {
      group.first_timestamp_ms = timestampMs;
    }
    if (!group.last_timestamp_ms || timestampMs > group.last_timestamp_ms) {
      group.last_timestamp_ms = timestampMs;
    }

    const statusKey = normalizeNotificationStatusForAdmin(record && record.status);
    group.statuses[statusKey] = (group.statuses[statusKey] || 0) + 1;
    group.count_notifications += 1;

    const deviceToken = normalizeDeviceToken(record && record.device_token);
    if (deviceToken) {
      group._device_tokens_set.add(deviceToken);
    }
  });

  return Array.from(grouped.values())
    .map((group) => {
      const deviceTokens = Array.from(group._device_tokens_set).sort(compareInsensitive);
      const devices = deviceTokens.map((token) => {
        const configuredName = deviceTokenNameLookup.get(token) || null;
        const shortToken = shortDeviceTokenForAdmin(token);
        return {
          token,
          short_token: shortToken,
          name: configuredName,
          label: configuredName ? `${configuredName} (${shortToken})` : shortToken,
        };
      });

      return {
        dispatch_key: group.dispatch_key,
        event_type: group.event_type,
        event_key: group.event_key,
        title: group.title,
        body: group.body,
        delay_minutes: group.delay_minutes,
        dispatch_mode: group.dispatch_mode,
        first_timestamp_ms: group.first_timestamp_ms,
        last_timestamp_ms: group.last_timestamp_ms,
        count_notifications: group.count_notifications,
        count_device_tokens: devices.length,
        statuses: group.statuses,
        devices,
      };
    })
    .sort((lhs, rhs) => {
      const left = adminHistoryTimestampMs(lhs && lhs.last_timestamp_ms);
      const right = adminHistoryTimestampMs(rhs && rhs.last_timestamp_ms);
      if (left !== right) return right - left;
      return String(lhs && lhs.event_type ? lhs.event_type : "").localeCompare(
        String(rhs && rhs.event_type ? rhs.event_type : "")
      );
    });
}

function goalEventAssisterForAdmin(goalTimeLabel, assists) {
  if (!goalTimeLabel) return null;
  if (!Array.isArray(assists)) return null;
  for (const assister of assists) {
    const assistTimes = Array.isArray(assister && assister.assist_times)
      ? assister.assist_times
      : [];
    if (assistTimes.includes(goalTimeLabel)) {
      const player = String(assister && assister.player ? assister.player : "").trim();
      if (player) return player;
    }
  }
  return null;
}

function flattenGoalTimelineEventsForAdmin(goalScorers, assists, side, teamName) {
  const events = [];
  let sourceOrder = 0;

  (Array.isArray(goalScorers) ? goalScorers : []).forEach((scorer) => {
    const player = String(scorer && scorer.player ? scorer.player : "").trim() || null;

    (Array.isArray(scorer && scorer.goal_times) ? scorer.goal_times : []).forEach((rawTime) => {
      const timeLabel = String(rawTime || "").trim() || null;
      events.push({
        event_type: "goal",
        team_side: side,
        team_name: teamName || null,
        player,
        assister: goalEventAssisterForAdmin(timeLabel, assists),
        time_label: timeLabel,
        minute: parseStatusMinuteValue(timeLabel),
        own_goal: false,
        source_order: sourceOrder++,
      });
    });

    (Array.isArray(scorer && scorer.own_goal_times) ? scorer.own_goal_times : []).forEach(
      (rawTime) => {
        const timeLabel = String(rawTime || "").trim() || null;
        events.push({
          event_type: "goal",
          team_side: side,
          team_name: teamName || null,
          player,
          assister: null,
          time_label: timeLabel,
          minute: parseStatusMinuteValue(timeLabel),
          own_goal: true,
          source_order: sourceOrder++,
        });
      }
    );
  });

  return events;
}

function flattenRedCardTimelineEventsForAdmin(redCards, side, teamName) {
  const events = [];
  let sourceOrder = 0;
  (Array.isArray(redCards) ? redCards : []).forEach((redCard) => {
    const player = String(redCard && redCard.player ? redCard.player : "").trim() || null;
    (Array.isArray(redCard && redCard.red_card_times) ? redCard.red_card_times : []).forEach(
      (rawTime) => {
        const timeLabel = String(rawTime || "").trim() || null;
        events.push({
          event_type: "red_card",
          team_side: side,
          team_name: teamName || null,
          player,
          assister: null,
          time_label: timeLabel,
          minute: parseStatusMinuteValue(timeLabel),
          own_goal: false,
          source_order: sourceOrder++,
        });
      }
    );
  });
  return events;
}

function buildMatchEventTimeline(matchPayload) {
  if (!matchPayload || typeof matchPayload !== "object") return [];

  const homeGoals = flattenGoalTimelineEventsForAdmin(
    matchPayload.home_goal_scorers,
    matchPayload.home_assists,
    "home",
    matchPayload.home_team
  );
  const awayGoals = flattenGoalTimelineEventsForAdmin(
    matchPayload.away_goal_scorers,
    matchPayload.away_assists,
    "away",
    matchPayload.away_team
  );
  const homeRedCards = flattenRedCardTimelineEventsForAdmin(
    matchPayload.home_red_cards,
    "home",
    matchPayload.home_team
  );
  const awayRedCards = flattenRedCardTimelineEventsForAdmin(
    matchPayload.away_red_cards,
    "away",
    matchPayload.away_team
  );

  return [...homeGoals, ...awayGoals, ...homeRedCards, ...awayRedCards]
    .sort((lhs, rhs) => {
      const leftMinute = Number(lhs && lhs.minute);
      const rightMinute = Number(rhs && rhs.minute);
      const leftHasMinute = Number.isFinite(leftMinute);
      const rightHasMinute = Number.isFinite(rightMinute);

      if (leftHasMinute || rightHasMinute) {
        if (!leftHasMinute) return 1;
        if (!rightHasMinute) return -1;
        if (leftMinute !== rightMinute) return leftMinute - rightMinute;
      }

      const leftLabel = String(lhs && lhs.time_label ? lhs.time_label : "");
      const rightLabel = String(rhs && rhs.time_label ? rhs.time_label : "");
      const labelCompare = leftLabel.localeCompare(rightLabel);
      if (labelCompare !== 0) return labelCompare;

      return Number(lhs && lhs.source_order ? lhs.source_order : 0) -
        Number(rhs && rhs.source_order ? rhs.source_order : 0);
    })
    .map((event, index) => ({
      ...event,
      timeline_id: `${event.event_type}:${event.team_side}:${event.time_label || "na"}:${index}`,
    }));
}

function toAdminResultMatchPayload(detailsPayload, fallbackMatchRecord = null, fallbackListPayload = null) {
  const detailId = normalizeMatchDetailsId(detailsPayload && detailsPayload.id);
  const fallbackId =
    normalizeMatchDetailsId(fallbackListPayload && fallbackListPayload.match_details_id) ||
    normalizeMatchDetailsId(fallbackMatchRecord && fallbackMatchRecord.match_details_id) ||
    matchDetailsIdFromUrl(fallbackMatchRecord && fallbackMatchRecord.details_url);
  const matchId = detailId || fallbackId;
  if (!matchId) return null;

  const baseDate = String(
    (detailsPayload && detailsPayload.date) ||
    (fallbackListPayload && fallbackListPayload.date) ||
    (fallbackMatchRecord && fallbackMatchRecord.date) ||
    ""
  ).trim();
  const baseTime = String(
    (detailsPayload && detailsPayload.time) ||
    (fallbackListPayload && fallbackListPayload.time) ||
    (fallbackMatchRecord && fallbackMatchRecord.time) ||
    ""
  ).trim();

  const scoreStatus = String(
    (detailsPayload && detailsPayload.score_status) ||
    (fallbackListPayload && fallbackListPayload.score_status) ||
    (fallbackMatchRecord && fallbackMatchRecord.score_status) ||
    ""
  ).trim() || null;

  const homeScore = parseNumericScore(
    detailsPayload && detailsPayload.home_score !== undefined
      ? detailsPayload.home_score
      : fallbackListPayload && fallbackListPayload.home_score !== undefined
        ? fallbackListPayload.home_score
        : fallbackMatchRecord && fallbackMatchRecord.home_score
  );
  const awayScore = parseNumericScore(
    detailsPayload && detailsPayload.away_score !== undefined
      ? detailsPayload.away_score
      : fallbackListPayload && fallbackListPayload.away_score !== undefined
        ? fallbackListPayload.away_score
        : fallbackMatchRecord && fallbackMatchRecord.away_score
  );
  const aggregateHomeScore = parseNumericScore(
    detailsPayload && detailsPayload.aggregate_home_score !== undefined
      ? detailsPayload.aggregate_home_score
      : fallbackListPayload && fallbackListPayload.aggregate_home_score !== undefined
        ? fallbackListPayload.aggregate_home_score
        : fallbackMatchRecord && fallbackMatchRecord.aggregate_home_score
  );
  const aggregateAwayScore = parseNumericScore(
    detailsPayload && detailsPayload.aggregate_away_score !== undefined
      ? detailsPayload.aggregate_away_score
      : fallbackListPayload && fallbackListPayload.aggregate_away_score !== undefined
        ? fallbackListPayload.aggregate_away_score
        : fallbackMatchRecord && fallbackMatchRecord.aggregate_away_score
  );

  const payload = {
    match_details_id: matchId,
    date: baseDate || null,
    time: baseTime || null,
    league: String(
      (detailsPayload && detailsPayload.league) ||
      (fallbackListPayload && fallbackListPayload.league) ||
      (fallbackMatchRecord && fallbackMatchRecord.league) ||
      ""
    ).trim() || null,
    home_team: String(
      (detailsPayload && detailsPayload.home_team) ||
      (fallbackListPayload && fallbackListPayload.home_team) ||
      (fallbackMatchRecord && fallbackMatchRecord.home_team) ||
      ""
    ).trim() || null,
    away_team: String(
      (detailsPayload && detailsPayload.away_team) ||
      (fallbackListPayload && fallbackListPayload.away_team) ||
      (fallbackMatchRecord && fallbackMatchRecord.away_team) ||
      ""
    ).trim() || null,
    home_score: homeScore,
    away_score: awayScore,
    aggregate_home_score: aggregateHomeScore,
    aggregate_away_score: aggregateAwayScore,
    score_status: scoreStatus,
    display_score_status: displayMatchStatusForAdmin(scoreStatus),
    in_progress: isInProgressMatchStatus(scoreStatus),
    finished: isFinishedMatchStatus(scoreStatus),
    has_score: homeScore !== null && awayScore !== null,
    penalty_result: String(
      (detailsPayload && detailsPayload.penalty_result) ||
      (fallbackListPayload && fallbackListPayload.penalty_result) ||
      (fallbackMatchRecord && fallbackMatchRecord.penalty_result) ||
      ""
    ).trim() || null,
    details_url: String(
      (detailsPayload && detailsPayload.details_url) ||
      (fallbackMatchRecord && fallbackMatchRecord.details_url) ||
      ""
    ).trim() || null,
    updated_at: String(detailsPayload && detailsPayload.updated_at ? detailsPayload.updated_at : "").trim() || null,
    tv_channels: uniqueChannels(
      (fallbackListPayload && fallbackListPayload.tv_channels) ||
      (fallbackMatchRecord && fallbackMatchRecord.tv_channels) ||
      []
    ),
    home_goal_scorers: Array.isArray(detailsPayload && detailsPayload.home_goal_scorers)
      ? detailsPayload.home_goal_scorers
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.home_goal_scorers)
        ? fallbackMatchRecord.home_goal_scorers
        : [],
    away_goal_scorers: Array.isArray(detailsPayload && detailsPayload.away_goal_scorers)
      ? detailsPayload.away_goal_scorers
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.away_goal_scorers)
        ? fallbackMatchRecord.away_goal_scorers
        : [],
    home_assists: Array.isArray(detailsPayload && detailsPayload.home_assists)
      ? detailsPayload.home_assists
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.home_assists)
        ? fallbackMatchRecord.home_assists
        : [],
    away_assists: Array.isArray(detailsPayload && detailsPayload.away_assists)
      ? detailsPayload.away_assists
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.away_assists)
        ? fallbackMatchRecord.away_assists
        : [],
    home_red_cards: Array.isArray(detailsPayload && detailsPayload.home_red_cards)
      ? detailsPayload.home_red_cards
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.home_red_cards)
        ? fallbackMatchRecord.home_red_cards
        : [],
    away_red_cards: Array.isArray(detailsPayload && detailsPayload.away_red_cards)
      ? detailsPayload.away_red_cards
      : Array.isArray(fallbackMatchRecord && fallbackMatchRecord.away_red_cards)
        ? fallbackMatchRecord.away_red_cards
        : [],
  };

  const kickoffMs = kickoffTimestampMs(payload);
  payload.kickoff_ts_ms = Number.isFinite(kickoffMs) ? kickoffMs : null;

  return payload;
}

function setCacheOnlyHeaders(res) {
  res.set("X-Data-Source", APP_DATA_SOURCE);
  res.set("X-External-Dependency", "none");
}

app.get("/", (_req, res) => {
  res
    .type("text/plain")
    .send("Football on TV API. Try /api/v1/matches?start=YYYY-MM-DD&end=YYYY-MM-DD");
});

app.get("/admin/bbc-history", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_bbc_history_ui.html"));
});

app.get("/admin/preferences", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_preferences_ui.html"));
});

app.get("/admin/fixtures", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_matches_ui.html"));
});

app.get("/admin/results", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_matches_ui.html"));
});

app.get("/admin/results/:matchId", (_req, res) => {
  res.sendFile(path.join(__dirname, "admin_match_details_ui.html"));
});

app.get(["/healthcheck", `${API_PREFIX}/healthcheck`], (_req, res) => {
  res.json({ status: "ok" });
});

app.post(`${API_PREFIX}/app-metrics`, (req, res) => {
  setCacheOnlyHeaders(res);

  if (!req.body || typeof req.body !== "object" || Array.isArray(req.body)) {
    appUsageMetrics.appMetricEventsRejectedTotal += 1;
    res.status(400).json({ error: "Invalid JSON payload." });
    return;
  }

  const payload = req.body;
  const event = normalizeMetricLabel(payload.event || "app_open", "app_open");
  const labels = {
    event,
    screen: normalizeMetricLabel(payload.screen || payload.view, "unknown"),
    build_type: normalizeMetricLabel(payload.buildType || payload.build_type, "unknown"),
    platform: normalizeMetricLabel(payload.platform || "ios", "ios"),
    os_version: normalizeMetricLabel(payload.osVersion || payload.systemVersion, "unknown"),
    device_type: normalizeMetricLabel(
      payload.deviceType || payload.userInterfaceIdiom || payload.idiom,
      "unknown"
    ),
    device_model: normalizeMetricLabel(payload.deviceModel || payload.model, "unknown"),
    app_version: normalizeMetricLabel(payload.appVersion, "unknown"),
    build_number: normalizeMetricLabel(payload.buildNumber, "unknown"),
  };

  const deviceToken = req.deviceToken || normalizeDeviceToken(payload.deviceToken);
  if (deviceToken) {
    trackSeenDeviceToken(deviceToken);
  }

  const key = appMetricEventKey(labels);
  const existing = appMetricEventsByDimension.get(key);
  if (existing) {
    existing.count += 1;
  } else {
    appMetricEventsByDimension.set(key, { labels, count: 1 });
  }

  appUsageMetrics.appMetricEventsTotal += 1;
  appMetricEventsLastUpdated = new Date().toISOString();

  res.status(202).json({
    success: true,
    recorded: true,
    event,
    has_device_token: Boolean(deviceToken),
    received_at: appMetricEventsLastUpdated,
  });
});

app.get("/metrics", (_req, res) => {
  res.set("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
  res.send(buildPrometheusMetricsText());
});

app.get(`${API_PREFIX}/matches`, async (req, res) => {
  setCacheOnlyHeaders(res);
  try {
    const range = parseRequiredDateRange(req.query);
    if (range.error) {
      res.status(400).json({ error: range.error });
      return;
    }

    const [mergedDataset, premierLeagueDataset, matchDetailsSnapshot] = await Promise.all([
      getOperationalArrayDataset(OP_DATASET_MERGED_MATCHES, mergedMatchesForResponse()),
      getOperationalArrayDataset(OP_DATASET_PREMIER_LEAGUE_TEAMS, cachedPremierLeagueTeams),
      getOperationalMatchDetailsSnapshotSafe(),
    ]);

    const latestUpdated = newestIsoTimestamp([
      mergedDataset.updated_at,
      bbcRangeLastUpdated,
      lastUpdated,
      bbcLastUpdated,
    ]);
    if (latestUpdated) {
      res.set("X-Last-Updated", latestUpdated);
    }
    res.set("X-Operational-Source", mergedDataset.source || "unknown");
    res.set(
      "X-Operational-Match-Details-Source",
      matchDetailsSnapshot.source || "unknown"
    );

    const mergedMatches = Array.isArray(mergedDataset.items) ? mergedDataset.items : [];
    const leagues = normalizeListParam(req.query.league).map(normalizeLeagueName);
    const teams = normalizeListParam(req.query.team);
    const channels = normalizeListParam(req.query.channel);
    const filterMode = req.query.filter_mode ? String(req.query.filter_mode) : "union";
    const sortOrder = String(req.query.sort || "asc").toLowerCase() === "desc" ? "desc" : "asc";
    const pageSize = parsePositiveInt(req.query.page_size, 100, 1, 500);
    const page = parsePositiveInt(req.query.page, 1, 1, Number.MAX_SAFE_INTEGER);
    const dateFrom = range.start;
    const dateTo = range.end;
    const eplOnly = isTruthyParam(req.query.epl_only);

    let filtered = mergedMatches.filter((match) =>
      matchesFilters(match, {
        leagues,
        teams,
        channels,
        filterMode,
        dateFrom,
        dateTo,
      })
    );

    if (eplOnly) {
      filtered = filtered.filter((match) =>
        matchIncludesPremierLeagueTeam(match, premierLeagueDataset.items)
      );
    }

    // Inject all test matches if they match filters
    const allTestMatches = testMatchState.getAllMatches();
    for (const testMatch of allTestMatches) {
      if (testMatch && testMatch.is_test_match) {
        const testMatchDate = testMatch.date;
        if (testMatchDate >= dateFrom && testMatchDate <= dateTo) {
          // Check if test match matches other filters
          const matchesLeagueFilter =
          leagues.length === 0 ||
          leagues.some((league) =>
            normalizeLeagueName(testMatch.league) === league
          );
        const matchesTeamFilter =
          teams.length === 0 ||
          teams.some(
            (team) =>
              testMatch.home_team.toLowerCase().includes(team.toLowerCase()) ||
              testMatch.away_team.toLowerCase().includes(team.toLowerCase())
          );

          if (matchesLeagueFilter && matchesTeamFilter) {
            // Insert test match at the appropriate position based on date/time
            filtered.push(testMatch);
            // Re-sort by kickoff time (date + time)
            filtered.sort((a, b) => {
              const aTime = `${a.date} ${a.time}`;
              const bTime = `${b.date} ${b.time}`;
              return aTime.localeCompare(bTime);
            });
          }
        }
      }
    }

    // mergedMatchesForResponse() is stored in ascending kickoff order already.
    // Filtering preserves order, so only reverse for descending responses.
    if (sortOrder === "desc") {
      filtered = filtered.slice().reverse();
    }

    const totalCount = filtered.length;
    const totalPages = totalCount > 0 ? Math.ceil(totalCount / pageSize) : 0;
    const pageStart = (page - 1) * pageSize;
    const pageEnd = pageStart + pageSize;
    const paged = pageStart >= totalCount ? [] : filtered.slice(pageStart, pageEnd);
    const hasMore = page < totalPages;

    res.set("X-Total-Count", String(totalCount));
    res.set("X-Page", String(page));
    res.set("X-Page-Size", String(pageSize));
    res.set("X-Total-Pages", String(totalPages));
    res.set("X-Has-More", hasMore ? "true" : "false");
    res.set("X-Sort-Order", sortOrder);

    const payload = paged
      .map((match) =>
        toMatchListPayload(match, {
          matchDetailsLookup: matchDetailsSnapshot.records || {},
        })
      )
      .filter(Boolean);
    res.json(payload);
  } catch (err) {
    console.warn("Failed to serve /matches from cache:", err.message || err);
    res.status(500).json({ error: "Failed to serve matches from cache" });
  }
});

app.get(`${API_PREFIX}/matches/:matchId`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const matchId = normalizeMatchDetailsId(req.params.matchId);
  if (!matchId) {
    res.status(400).json({ error: "Invalid match id. Expected BBC details id (e.g. c043pne0q3kt)." });
    return;
  }

  // Check if this is a test match (search all test matches by their ID)
  const allTestMatches = testMatchState.getAllMatches();
  const testMatch = allTestMatches.find(m => m.match_details_id === matchId);
  if (testMatch) {
    const testMatchDetails = {
      id: testMatch.match_details_id,
      details_url: null,
      date: testMatch.date,
      time: testMatch.time,
      league: testMatch.league,
      home_team: testMatch.home_team,
      away_team: testMatch.away_team,
      home_score: testMatch.home_score,
      away_score: testMatch.away_score,
      aggregate_home_score: testMatch.aggregate_home_score,
      aggregate_away_score: testMatch.aggregate_away_score,
      score_status: testMatch.score_status,
      home_goal_scorers: testMatch.home_goal_scorers || [],
      away_goal_scorers: testMatch.away_goal_scorers || [],
      home_assists: testMatch.home_assists || [],
      away_assists: testMatch.away_assists || [],
      home_red_cards: testMatch.home_red_cards || [],
      away_red_cards: testMatch.away_red_cards || [],
      penalty_result: testMatch.penalty_result,
      in_progress: testMatch.in_progress,
      updated_at: testMatch.updated_at,
    };
    res.json(testMatchDetails);
    return;
  }

  let detailsLookup = await getOperationalMatchDetailsByIdSafe(matchId);
  let payload = detailsLookup.payload;
  if (!payload) {
    res.status(404).json({ error: "No cached match details found for match id." });
    return;
  }
  res.set("X-Operational-Source", detailsLookup.source || "unknown");

  if (matchDetailsNeedsBackfill(payload) && payload.details_url) {
    try {
      const nowIso = new Date().toISOString();
      const fetched = await fetchBbcMatchByDetailsUrl(payload.details_url);
      if (fetched) {
        const combined = buildMergedMatchDetailsCandidate(
          payload,
          fetched,
          payload.details_url
        );
        const upsertedMatchId = upsertMatchDetailsFromMatch(combined, nowIso);
        payload = matchDetailsById.get(matchId);
        if (upsertedMatchId && payload) {
          await persistOperationalMatchDetailsSafe(
            {
              [upsertedMatchId]: payload,
            },
            {
              replace: false,
              updated_at: nowIso,
              source: "lazy_match_details_backfill",
            }
          );
        }
        console.log(`Lazy backfilled match details for ${matchId} at ${nowIso}`);
      }
    } catch (err) {
      console.warn(
        `Failed to lazy backfill match details for ${matchId}:`,
        err.message || err
      );
    }
  }

  if (payload.updated_at) {
    res.set("X-Last-Updated", payload.updated_at);
  } else if (matchDetailsLastUpdated) {
    res.set("X-Last-Updated", matchDetailsLastUpdated);
  }
  res.json(payload);
});

app.get(`${API_PREFIX}/monitor/candidates`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const date = req.query.date
    ? String(req.query.date).trim()
    : new Date().toISOString().split("T")[0];
  if (!isDateOnly(date)) {
    res.status(400).json({
      error: "Invalid date. Expected YYYY-MM-DD.",
    });
    return;
  }

  try {
    const [mergedDataset, matchDetailsSnapshot] = await Promise.all([
      getOperationalArrayDataset(OP_DATASET_MERGED_MATCHES, mergedMatchesForResponse()),
      getOperationalMatchDetailsSnapshotSafe(),
    ]);
    const matchDetailsLookup =
      matchDetailsSnapshot && matchDetailsSnapshot.records && typeof matchDetailsSnapshot.records === "object"
        ? matchDetailsSnapshot.records
        : {};

    const candidatesById = new Map();
    const sourceTagsById = new Map();
    const markSource = (matchId, source) => {
      if (!sourceTagsById.has(matchId)) sourceTagsById.set(matchId, new Set());
      sourceTagsById.get(matchId).add(source);
    };

    const mergedItems = Array.isArray(mergedDataset && mergedDataset.items)
      ? mergedDataset.items
      : [];
    for (const rawMatch of mergedItems) {
      const candidate = toMatchListPayload(rawMatch, { matchDetailsLookup });
      const matchId = normalizeMatchDetailsId(candidate && candidate.match_details_id);
      if (!candidate || !matchId) continue;
      if (String(candidate.date || "") !== date) continue;

      const existing = candidatesById.get(matchId);
      candidatesById.set(matchId, mergeMonitorCandidate(existing, candidate));
      markSource(matchId, "merged");
    }

    for (const payload of Object.values(matchDetailsLookup)) {
      const candidate = toMonitorCandidateFromDetailsPayload(payload);
      const matchId = normalizeMatchDetailsId(candidate && candidate.match_details_id);
      if (!candidate || !matchId) continue;
      if (String(candidate.date || "") !== date) continue;

      const existing = candidatesById.get(matchId);
      candidatesById.set(matchId, mergeMonitorCandidate(existing, candidate));
      markSource(matchId, "details");
    }

    const candidates = Array.from(candidatesById.values())
      .map((candidate) => {
        const matchId = normalizeMatchDetailsId(candidate && candidate.match_details_id);
        const sources = matchId && sourceTagsById.has(matchId)
          ? Array.from(sourceTagsById.get(matchId).values()).sort()
          : [];
        return {
          ...candidate,
          sources,
        };
      })
      .sort(monitorCandidateSortAsc);

    res.status(200).json({
      success: true,
      date,
      count: candidates.length,
      source: {
        merged_matches: mergedDataset && mergedDataset.source ? mergedDataset.source : "unknown",
        merged_matches_updated_at: mergedDataset && mergedDataset.updated_at ? mergedDataset.updated_at : null,
        match_details: matchDetailsSnapshot && matchDetailsSnapshot.source ? matchDetailsSnapshot.source : "unknown",
        match_details_updated_at:
          matchDetailsSnapshot && matchDetailsSnapshot.updated_at ? matchDetailsSnapshot.updated_at : null,
      },
      candidates,
    });
  } catch (error) {
    console.error("[API] Error retrieving monitor candidates:", error);
    res.status(500).json({
      error: "Failed to retrieve monitor candidates",
      message: error.message || String(error),
    });
  }
});

app.get(`${API_PREFIX}/competitions`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const dataset = await getOperationalArrayDataset(
    OP_DATASET_MERGED_MATCHES,
    mergedMatchesForResponse()
  );
  res.set("X-Operational-Source", dataset.source || "unknown");
  res.json(buildLeagueList(dataset.items));
});

app.get(`${API_PREFIX}/teams`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const leagueFilter = req.query.league ? String(req.query.league) : null;
  const dataset = await getOperationalArrayDataset(
    OP_DATASET_MERGED_MATCHES,
    mergedMatchesForResponse()
  );
  res.set("X-Operational-Source", dataset.source || "unknown");
  res.json(buildTeamList(dataset.items, leagueFilter));
});

app.get(`${API_PREFIX}/teams/premier-league`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const dataset = await getOperationalArrayDataset(
    OP_DATASET_PREMIER_LEAGUE_TEAMS,
    cachedPremierLeagueTeams
  );
  const updatedAt = dataset.updated_at || eplLastUpdated;
  if (updatedAt) {
    res.set("X-Last-Updated", updatedAt);
  }
  res.set("X-Operational-Source", dataset.source || "unknown");
  res.json(dataset.items);
});

app.get(`${API_PREFIX}/tables`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const dataset = await getOperationalArrayDataset(OP_DATASET_LEAGUE_TABLES, cachedLeagueTables);
  const leagues = sortLeagueTablesForResponse(dataset.items);
  const updatedAt =
    dataset.updated_at ||
    leagueTablesLastUpdated ||
    newestIsoTimestamp(
      leagues
        .map((league) => String((league && league.updated_at) || "").trim())
        .filter(Boolean)
    );
  if (updatedAt) {
    res.set("X-Last-Updated", updatedAt);
  }
  res.set("X-Operational-Source", dataset.source || "unknown");
  res.json({
    updated_at: updatedAt || null,
    count: leagues.length,
    leagues,
  });
});

app.get(`${API_PREFIX}/tables/:leagueId`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const dataset = await getOperationalArrayDataset(OP_DATASET_LEAGUE_TABLES, cachedLeagueTables);
  const leagues = sortLeagueTablesForResponse(dataset.items);
  const league = findLeagueTableById(leagues, req.params.leagueId);
  if (!league) {
    res.status(404).json({
      error: "League table not found",
      league_id: normalizeLeagueTableId(req.params.leagueId),
      available_leagues: leagues.map((item) => item.league_id).filter(Boolean),
    });
    return;
  }
  if (league.updated_at) {
    res.set("X-Last-Updated", league.updated_at);
  } else if (dataset.updated_at) {
    res.set("X-Last-Updated", dataset.updated_at);
  }
  res.set("X-Operational-Source", dataset.source || "unknown");
  res.json(league);
});

app.get(`${API_PREFIX}/channels`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const dataset = await getOperationalArrayDataset(
    OP_DATASET_MERGED_MATCHES,
    mergedMatchesForResponse()
  );
  res.set("X-Operational-Source", dataset.source || "unknown");
  res.json(buildChannelList(dataset.items));
});

app.post(`${API_PREFIX}/audit/missing-team-logos`, (req, res) => {
  setCacheOnlyHeaders(res);

  const payload = req.body;
  const teamNames = missingTeamLogoNamesFromPayload(payload);

  if (!teamNames) {
    res.status(400).json({
      error: "Invalid payload. Send a JSON array of team names or {\"team_names\":[...]}",
    });
    return;
  }

  const result = ingestMissingTeamLogoNames(teamNames);
  if (result.acceptedCount === 0) {
    res.status(400).json({
      error: "No valid team names were provided.",
      total_count: result.totalCount,
      last_updated: missingTeamLogosLastUpdated,
    });
    return;
  }

  if (missingTeamLogosLastUpdated) {
    res.set("X-Last-Updated", missingTeamLogosLastUpdated);
  }
  res.json({
    accepted_count: result.acceptedCount,
    added_count: result.addedCount,
    added: result.added,
    total_count: result.totalCount,
    last_updated: missingTeamLogosLastUpdated,
  });
});

app.post(`${API_PREFIX}/audit/missing-team-logos/cleanup`, (req, res) => {
  setCacheOnlyHeaders(res);

  const payload = req.body;
  const teamNames = missingTeamLogoNamesFromPayload(payload);
  const clearAll =
    isTruthyParam(req.query.all) ||
    (payload && typeof payload === "object" && isTruthyParam(payload.clear_all));

  if (!clearAll && !teamNames) {
    res.status(400).json({
      error:
        "Invalid cleanup payload. Send a JSON array, {\"team_names\":[...]}, or set all=true/clear_all=true.",
    });
    return;
  }

  const result = clearAll ? clearMissingTeamLogos() : removeMissingTeamLogoNames(teamNames);

  if (missingTeamLogosLastUpdated) {
    res.set("X-Last-Updated", missingTeamLogosLastUpdated);
  }

  res.json({
    accepted_count: clearAll ? result.removedCount : result.acceptedCount,
    removed_count: result.removedCount,
    removed: result.removed,
    total_count: result.totalCount,
    last_updated: missingTeamLogosLastUpdated,
    cleared_all: clearAll,
  });
});

app.get(`${API_PREFIX}/audit/missing-team-logos`, (_req, res) => {
  setCacheOnlyHeaders(res);
  if (missingTeamLogosLastUpdated) {
    res.set("X-Last-Updated", missingTeamLogosLastUpdated);
  }
  res.json(sortedMissingTeamLogoNames());
});

app.get(`${API_PREFIX}/bbc/live`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const [bbcLiveDataset, matchDetailsSnapshot] = await Promise.all([
    getOperationalArrayDataset(OP_DATASET_BBC_LIVE_MATCHES, cachedBbcMatches),
    getOperationalMatchDetailsSnapshotSafe(),
  ]);

  const updatedAt = bbcLiveDataset.updated_at || bbcLastUpdated;
  if (updatedAt) {
    res.set("X-Last-Updated", updatedAt);
  }
  res.set("X-Operational-Source", bbcLiveDataset.source || "unknown");

  // Transform "Pens" to "AET" for completed penalty shootouts in BBC Live matches
  const transformedMatches = bbcLiveDataset.items.map((match) => {
    // If match has Pens status and we have match details with penalty_result, change to AET
    if (match.match_time === "Pens" || match.match_time === "PEN" || match.match_time === "PEN.") {
      const detailsId = matchDetailsIdFromUrl(match.details_url);
      if (detailsId) {
        const matchDetails =
          matchDetailsSnapshot && matchDetailsSnapshot.records
            ? matchDetailsSnapshot.records[detailsId]
            : null;
        if (matchDetails && matchDetails.penalty_result) {
          return { ...match, match_time: "AET" };
        }
      }
    }
    return match;
  });

  res.json(transformedMatches);
});

app.get(`${API_PREFIX}/bbc/details`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const detailsUrl = req.query.url ? String(req.query.url).trim() : "";
  if (!detailsUrl) {
    res.status(400).json({ error: "Missing required query parameter: url" });
    return;
  }

  const detailsId = matchDetailsIdFromUrl(detailsUrl);
  if (!detailsId) {
    res.status(400).json({ error: "Invalid BBC football details URL" });
    return;
  }

  const detailsLookup = await getOperationalMatchDetailsByIdSafe(detailsId);
  const payload = detailsLookup.payload;
  if (!payload) {
    res.status(404).json({ error: "No cached match details found for provided details URL" });
    return;
  }
  res.set("X-Operational-Source", detailsLookup.source || "unknown");
  if (payload.updated_at) {
    res.set("X-Last-Updated", payload.updated_at);
  }
  res.json(payload);
});

app.post(`${API_PREFIX}/matches/backfill`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const batchSize = parsePositiveInt(
    req.query.batch_size,
    MATCH_DETAILS_BACKFILL_BATCH_SIZE,
    1,
    500
  );

  const detailsSnapshot = await getOperationalMatchDetailsSnapshotSafe();
  res.set("X-Operational-Source", detailsSnapshot.source || "unknown");

  const candidates = [];
  Object.entries(detailsSnapshot.records || {}).forEach(([matchId, payload]) => {
    if (matchDetailsNeedsBackfill(payload) && payload.details_url) {
      candidates.push({ matchId, payload });
    }
  });

  const toEnrich = candidates.slice(0, batchSize);
  const enriched = [];
  const failed = [];
  const skipped = candidates.length - toEnrich.length;
  const nowIso = new Date().toISOString();

  await mapWithConcurrency(
    toEnrich,
    MATCH_DETAILS_POLL_CONCURRENCY,
    async (candidate) => {
      try {
        const fetched = await fetchBbcMatchByDetailsUrl(candidate.payload.details_url);
        if (fetched) {
          const combined = buildMergedMatchDetailsCandidate(
            candidate.payload,
            fetched,
            candidate.payload.details_url
          );
          const upsertedMatchId = upsertMatchDetailsFromMatch(combined, nowIso);
          if (upsertedMatchId) {
            enriched.push(upsertedMatchId);
          } else {
            failed.push(candidate.matchId);
          }
        } else {
          failed.push(candidate.matchId);
        }
      } catch (err) {
        console.warn(
          `Failed to backfill match ${candidate.matchId}:`,
          err.message || err
        );
        failed.push(candidate.matchId);
      }
    }
  );

  console.log(
    `Batch backfilled ${enriched.length} matches, ${failed.length} failed, ${skipped} skipped at ${nowIso}`
  );

  if (enriched.length > 0) {
    const updatedSubset = {};
    enriched.forEach((matchId) => {
      const payload = matchDetailsById.get(matchId);
      if (payload && typeof payload === "object") {
        updatedSubset[matchId] = payload;
      }
    });
    if (Object.keys(updatedSubset).length > 0) {
      await persistOperationalMatchDetailsSafe(updatedSubset, {
        replace: false,
        updated_at: nowIso,
        source: "admin_backfill_matches",
      });
    }
  }

  res.json({
    enriched_count: enriched.length,
    enriched_ids: enriched,
    failed_count: failed.length,
    failed_ids: failed,
    skipped_count: skipped,
    total_candidates: candidates.length,
    batch_size: batchSize,
    timestamp: nowIso,
  });
});

app.get(`${API_PREFIX}/status`, async (_req, res) => {
  setCacheOnlyHeaders(res);
  const [
    mergedDataset,
    liveDataset,
    bbcLiveDataset,
    bbcRangeDataset,
    recentDataset,
    teamsDataset,
    leagueTablesDataset,
    matchDetailsSummary,
    matchDetailsSnapshot,
  ] = await Promise.all([
    getOperationalArrayDataset(OP_DATASET_MERGED_MATCHES, cachedMergedMatches),
    getOperationalArrayDataset(OP_DATASET_LIVE_MATCHES, cachedMatches),
    getOperationalArrayDataset(OP_DATASET_BBC_LIVE_MATCHES, cachedBbcMatches),
    getOperationalArrayDataset(OP_DATASET_BBC_RANGE_MATCHES, cachedBbcRangeMatches),
    getOperationalArrayDataset(OP_DATASET_RECENT_MATCHES, cachedRecentMatches),
    getOperationalArrayDataset(OP_DATASET_PREMIER_LEAGUE_TEAMS, cachedPremierLeagueTeams),
    getOperationalArrayDataset(OP_DATASET_LEAGUE_TABLES, cachedLeagueTables),
    getOperationalMatchDetailsSummary(),
    getOperationalMatchDetailsSnapshotSafe(),
  ]);

  const mergedLastUpdated = newestIsoTimestamp([
    mergedDataset.updated_at,
    bbcRangeDataset.updated_at,
    liveDataset.updated_at,
    bbcLiveDataset.updated_at,
    bbcRangeLastUpdated,
    lastUpdated,
    bbcLastUpdated,
  ]);

  let needsEnrichmentCount = 0;
  let needsStatusRefreshCount = 0;
  let needsBackfillCount = 0;
  const detailsRecords = matchDetailsSnapshot.records || {};
  Object.values(detailsRecords).forEach((payload) => {
    if (matchDetailsNeedsEnrichment(payload) && payload.details_url) {
      needsEnrichmentCount += 1;
    }
    if (matchDetailsHasStaleInProgressStatus(payload)) {
      needsStatusRefreshCount += 1;
    }
    if (matchDetailsNeedsBackfill(payload)) {
      needsBackfillCount += 1;
    }
  });

  res.json({
    count: mergedDataset.items.length,
    last_updated: mergedLastUpdated,
    live_count: liveDataset.items.length,
    live_last_updated: liveDataset.updated_at || lastUpdated,
    source_url: SOURCE_URL,
    output_path: path.resolve(OUTPUT_PATH),
    interval_ms: INTERVAL_MS,
    bbc_count: bbcLiveDataset.items.length,
    bbc_last_updated: bbcLiveDataset.updated_at || bbcLastUpdated,
    bbc_source_url: BBC_SOURCE_URL,
    bbc_output_path: path.resolve(BBC_OUTPUT_PATH),
    bbc_interval_ms: BBC_INTERVAL_MS,
    bbc_range_count: bbcRangeDataset.items.length,
    bbc_range_last_updated: bbcRangeDataset.updated_at || bbcRangeLastUpdated,
    bbc_range_base_url: BBC_RANGE_BASE_URL,
    bbc_range_output_path: path.resolve(BBC_RANGE_OUTPUT_PATH),
    bbc_range_interval_ms: BBC_RANGE_INTERVAL_MS,
    bbc_range_past_days: BBC_RANGE_PAST_DAYS,
    bbc_range_future_days: BBC_RANGE_FUTURE_DAYS,
    bbc_range_concurrency: BBC_RANGE_CONCURRENCY,
    bbc_range_match_timezone: BBC_RANGE_MATCH_TIMEZONE,
    epl_count: teamsDataset.items.length,
    epl_last_updated: teamsDataset.updated_at || eplLastUpdated,
    epl_source_url: EPL_SOURCE_URL,
    epl_output_path: path.resolve(EPL_OUTPUT_PATH),
    epl_interval_ms: EPL_INTERVAL_MS,
    epl_team_min_confidence: EPL_TEAM_MIN_CONFIDENCE,
    league_tables_count: leagueTablesDataset.items.length,
    league_tables_rows_count: leagueTableRowsCount(leagueTablesDataset.items),
    league_tables_last_updated: leagueTablesDataset.updated_at || leagueTablesLastUpdated,
    league_tables_output_path: path.resolve(LEAGUE_TABLES_OUTPUT_PATH),
    league_tables_interval_ms: LEAGUE_TABLES_INTERVAL_MS,
    recent_count: recentDataset.items.length,
    recent_last_updated: recentDataset.updated_at || recentLastUpdated,
    recent_output_path: path.resolve(RECENT_OUTPUT_PATH),
    recent_cache_hours: RECENT_CACHE_HOURS,
    match_details_count:
      Number.isFinite(matchDetailsSummary.total) && matchDetailsSummary.total > 0
        ? matchDetailsSummary.total
        : matchDetailsSnapshot.total,
    match_details_last_updated:
      matchDetailsSummary.updated_at || matchDetailsSnapshot.updated_at || matchDetailsLastUpdated,
    match_details_poll_interval_ms: MATCH_DETAILS_POLL_INTERVAL_MS,
    match_details_poll_concurrency: MATCH_DETAILS_POLL_CONCURRENCY,
    match_details_stale_in_progress_ms: MATCH_DETAILS_STALE_IN_PROGRESS_MS,
    match_details_stale_minute_threshold: MATCH_DETAILS_STALE_MINUTE_THRESHOLD,
    match_details_updating: matchDetailsUpdating,
    match_details_needs_enrichment_count: needsEnrichmentCount,
    match_details_needs_status_refresh_count: needsStatusRefreshCount,
    match_details_backfill_candidates_count: needsBackfillCount,
    match_details_backfill_batch_size: MATCH_DETAILS_BACKFILL_BATCH_SIZE,
    missing_team_logos_count: missingTeamLogosByKey.size,
    missing_team_logos_last_updated: missingTeamLogosLastUpdated,
    missing_team_logos_output_path: path.resolve(MISSING_TEAM_LOGOS_OUTPUT_PATH),
    app_api_data_source: APP_DATA_SOURCE,
    app_api_cache_only: true,
    app_metrics_last_updated: appMetricEventsLastUpdated,
    app_metrics_events_total: appUsageMetrics.appMetricEventsTotal,
    app_metrics_events_rejected_total: appUsageMetrics.appMetricEventsRejectedTotal,
    app_metrics_unique_devices_total: seenDeviceTokens.size,
    app_metrics_active_devices_total: activeDeviceCount(),
    app_metrics_active_window_ms: APP_METRICS_ACTIVE_DEVICE_WINDOW_MS,
    api_requests_total: appUsageMetrics.apiRequestsTotal,
    api_requests_with_device_token_total: appUsageMetrics.apiRequestsWithDeviceTokenTotal,
    api_requests_without_device_token_total: appUsageMetrics.apiRequestsWithoutDeviceTokenTotal,
    competition_allowlist: SERVER_CONFIG.competitionAllowlist,
    operational_state_source: {
      merged_matches: mergedDataset.source,
      live_matches: liveDataset.source,
      bbc_live_matches: bbcLiveDataset.source,
      bbc_range_matches: bbcRangeDataset.source,
      recent_matches: recentDataset.source,
      premier_league_teams: teamsDataset.source,
      league_tables: leagueTablesDataset.source,
      match_details: matchDetailsSnapshot.source,
    },
  });
});

loadFromDisk();
loadBbcFromDisk();
loadBbcRangeFromDisk();
loadRecentFromDisk();
loadPremierLeagueFromDisk();
loadLeagueTablesFromDisk();
// ===== User Preferences Redis Endpoints =====
const {
  saveUserPreferences,
  updateUserLiveActivityState,
  getUserPreferences,
  deleteUserPreferences,
  getAllUserPreferences,
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
  __historyConfig: bbcHistoryConfig,
} = require("./redis_client");

// Save user preferences
app.post(`${API_PREFIX}/preferences`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken, preferences, apnsToken, isDevelopmentBuild, liveActivity } = req.body;
  const resolvedDeviceToken = req.deviceToken || normalizeDeviceToken(deviceToken);

  if (!resolvedDeviceToken) {
    res.status(400).json({
      error: "Missing device token (X-Device-Token header or deviceToken body field).",
    });
    return;
  }

  try {
    const saved = await saveUserPreferences(
      resolvedDeviceToken,
      preferences,
      apnsToken,
      typeof isDevelopmentBuild === "boolean" ? isDevelopmentBuild : false,
      {
        liveActivity:
          liveActivity && typeof liveActivity === "object" ? liveActivity : undefined,
      }
    );
    res.status(200).json({
      success: true,
      data: saved,
    });
  } catch (error) {
    console.error("[API] Error saving preferences:", error);
    res.status(500).json({
      error: "Failed to save preferences",
      message: error.message,
    });
  }
});

// Save push-to-start token used to server-trigger Live Activities.
app.post(`${API_PREFIX}/live-activity/push-to-start-token`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken, pushToStartToken, isDevelopmentBuild } = req.body || {};
  const resolvedDeviceToken = req.deviceToken || normalizeDeviceToken(deviceToken);
  const normalizedToken = normalizeLiveActivityToken(pushToStartToken);

  if (!resolvedDeviceToken) {
    res.status(400).json({
      error: "Missing device token (X-Device-Token header or deviceToken body field).",
    });
    return;
  }
  if (!normalizedToken) {
    res.status(400).json({
      error: "Missing or invalid pushToStartToken.",
    });
    return;
  }

  try {
    const nowIso = new Date().toISOString();
    const saved = await updateUserLiveActivityState(
      resolvedDeviceToken,
      {
        pushToStartToken: normalizedToken,
        pushToStartTokenUpdatedAt: nowIso,
      },
      {
        isDevelopmentBuild: typeof isDevelopmentBuild === "boolean" ? isDevelopmentBuild : undefined,
      }
    );
    res.status(200).json({
      success: true,
      data: saved,
    });
  } catch (error) {
    console.error("[API] Error saving push-to-start token:", error);
    res.status(500).json({
      error: "Failed to save push-to-start token",
      message: error.message,
    });
  }
});

// Save active Live Activity push token so server can send update/end events.
app.post(`${API_PREFIX}/live-activity/activity-token`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken, activityId, activityPushToken, isDevelopmentBuild } = req.body || {};
  const resolvedDeviceToken = req.deviceToken || normalizeDeviceToken(deviceToken);
  const normalizedActivityId = normalizeDeviceToken(activityId);
  const normalizedActivityPushToken = normalizeLiveActivityToken(activityPushToken);

  if (!resolvedDeviceToken) {
    res.status(400).json({
      error: "Missing device token (X-Device-Token header or deviceToken body field).",
    });
    return;
  }
  if (!normalizedActivityId || !normalizedActivityPushToken) {
    res.status(400).json({
      error: "Missing or invalid activityId/activityPushToken.",
    });
    return;
  }

  try {
    const nowIso = new Date().toISOString();
    const saved = await updateUserLiveActivityState(
      resolvedDeviceToken,
      {
        currentActivityId: normalizedActivityId,
        currentActivityPushToken: normalizedActivityPushToken,
        currentActivityTokenUpdatedAt: nowIso,
        pendingStartAt: null,
      },
      {
        isDevelopmentBuild: typeof isDevelopmentBuild === "boolean" ? isDevelopmentBuild : undefined,
      }
    );
    res.status(200).json({
      success: true,
      data: saved,
    });
  } catch (error) {
    console.error("[API] Error saving activity push token:", error);
    res.status(500).json({
      error: "Failed to save activity push token",
      message: error.message,
    });
  }
});

// Mark the current Live Activity as ended for this device.
app.post(`${API_PREFIX}/live-activity/activity-ended`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken, activityId, isDevelopmentBuild } = req.body || {};
  const resolvedDeviceToken = req.deviceToken || normalizeDeviceToken(deviceToken);
  const normalizedActivityId = normalizeDeviceToken(activityId);

  if (!resolvedDeviceToken) {
    res.status(400).json({
      error: "Missing device token (X-Device-Token header or deviceToken body field).",
    });
    return;
  }

  try {
    const nowIso = new Date().toISOString();
    const patch = {
      currentActivityPushToken: null,
      pendingStartAt: null,
      lastPayloadHash: null,
      lastMode: null,
      lastEndedAt: nowIso,
      testHoldUntil: null,
    };
    if (normalizedActivityId) {
      patch.currentActivityId = normalizedActivityId;
    } else {
      patch.currentActivityId = null;
    }
    const saved = await updateUserLiveActivityState(
      resolvedDeviceToken,
      patch,
      {
        isDevelopmentBuild: typeof isDevelopmentBuild === "boolean" ? isDevelopmentBuild : undefined,
      }
    );
    res.status(200).json({
      success: true,
      data: saved,
    });
  } catch (error) {
    console.error("[API] Error marking live activity as ended:", error);
    res.status(500).json({
      error: "Failed to mark live activity as ended",
      message: error.message,
    });
  }
});

// Get user preferences
app.get(`${API_PREFIX}/preferences/:deviceToken`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken } = req.params;

  if (!deviceToken) {
    res.status(400).json({
      error: "Missing deviceToken parameter",
    });
    return;
  }

  try {
    const data = await getUserPreferences(deviceToken);

    if (!data) {
      res.status(404).json({
        error: "Preferences not found for this device",
      });
      return;
    }

    res.status(200).json({
      success: true,
      data,
    });
  } catch (error) {
    console.error("[API] Error retrieving preferences:", error);
    res.status(500).json({
      error: "Failed to retrieve preferences",
      message: error.message,
    });
  }
});

// Delete user preferences
app.delete(`${API_PREFIX}/preferences/:deviceToken`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken } = req.params;

  if (!deviceToken) {
    res.status(400).json({
      error: "Missing deviceToken parameter",
    });
    return;
  }

  try {
    const deleted = await deleteUserPreferences(deviceToken);

    if (!deleted) {
      res.status(404).json({
        error: "Preferences not found for this device",
      });
      return;
    }

    res.status(200).json({
      success: true,
      message: "Preferences deleted successfully",
    });
  } catch (error) {
    console.error("[API] Error deleting preferences:", error);
    res.status(500).json({
      error: "Failed to delete preferences",
      message: error.message,
    });
  }
});

// Get all user preferences (admin endpoint)
app.get(`${API_PREFIX}/preferences`, async (_req, res) => {
  setCacheOnlyHeaders(res);

  try {
    const allPreferences = await getAllUserPreferences();

    res.status(200).json({
      success: true,
      count: allPreferences.length,
      data: allPreferences,
    });
  } catch (error) {
    console.error("[API] Error retrieving all preferences:", error);
    res.status(500).json({
      error: "Failed to retrieve all preferences",
      message: error.message,
    });
  }
});

function normalizePreferenceFilterText(value) {
  if (typeof value !== "string") return "";
  return value.trim().toLowerCase().slice(0, 200);
}

function sortPreferencesByUpdatedAtDescending(records) {
  return records.slice().sort((lhs, rhs) => {
    const lhsTs = Date.parse(lhs && lhs.updatedAt ? lhs.updatedAt : "");
    const rhsTs = Date.parse(rhs && rhs.updatedAt ? rhs.updatedAt : "");
    const safeLhsTs = Number.isFinite(lhsTs) ? lhsTs : 0;
    const safeRhsTs = Number.isFinite(rhsTs) ? rhsTs : 0;
    return safeRhsTs - safeLhsTs;
  });
}

function preferenceObjectToSearchText(preferences) {
  if (!preferences || typeof preferences !== "object") return "";
  try {
    return JSON.stringify(preferences).toLowerCase();
  } catch (_error) {
    return "";
  }
}

// Admin preferences query endpoint
app.get(`${API_PREFIX}/admin/preferences`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const deviceTokenFilter = normalizePreferenceFilterText(req.query.device_token);
  const preferenceFilter = normalizePreferenceFilterText(req.query.preference_text);
  const searchFilter = normalizePreferenceFilterText(req.query.q);
  const limit = parsePositiveInt(req.query.limit, 500, 1, 2000);

  try {
    const allPreferences = await getAllUserPreferences();
    const sorted = sortPreferencesByUpdatedAtDescending(allPreferences);

    const filtered = sorted.filter((record) => {
      const deviceToken = String(record && record.deviceToken ? record.deviceToken : "").toLowerCase();
      const apnsToken = String(record && record.apnsToken ? record.apnsToken : "").toLowerCase();
      const updatedAt = String(record && record.updatedAt ? record.updatedAt : "").toLowerCase();
      const preferencesText = preferenceObjectToSearchText(record && record.preferences);
      const searchable = `${deviceToken} ${apnsToken} ${updatedAt} ${preferencesText}`;

      if (deviceTokenFilter && !deviceToken.includes(deviceTokenFilter)) return false;
      if (preferenceFilter && !preferencesText.includes(preferenceFilter)) return false;
      if (searchFilter && !searchable.includes(searchFilter)) return false;
      return true;
    });

    const limited = filtered.slice(0, limit);

    res.status(200).json({
      success: true,
      count: limited.length,
      totalMatched: filtered.length,
      totalAvailable: sorted.length,
      limit,
      filters: {
        device_token: deviceTokenFilter || null,
        preference_text: preferenceFilter || null,
        q: searchFilter || null,
      },
      data: limited,
    });
  } catch (error) {
    console.error("[API] Error retrieving admin preferences:", error);
    res.status(500).json({
      error: "Failed to retrieve admin preferences",
      message: error.message,
    });
  }
});

app.get(`${API_PREFIX}/admin/fixtures`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const limit = parsePositiveInt(req.query.limit, 500, 1, 5000);

  try {
    const [mergedDataset, matchDetailsSnapshot] = await Promise.all([
      getOperationalArrayDataset(OP_DATASET_MERGED_MATCHES, mergedMatchesForResponse()),
      getOperationalMatchDetailsSnapshotSafe(),
    ]);

    const matches = filterAdminMatches(mergedDataset.items, {
      mode: "fixtures",
      matchDetailsLookup: matchDetailsSnapshot.records || {},
    });
    const limited = matches.slice(0, limit);

    res.status(200).json({
      success: true,
      mode: "fixtures",
      generated_at: new Date().toISOString(),
      count: limited.length,
      total_available: matches.length,
      limit,
      source: mergedDataset.source || "unknown",
      updated_at: mergedDataset.updated_at || null,
      matches: limited,
    });
  } catch (error) {
    console.error("[API] Error retrieving admin fixtures:", error);
    res.status(500).json({
      error: "Failed to retrieve admin fixtures",
      message: error.message,
    });
  }
});

app.get(`${API_PREFIX}/admin/results`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const limit = parsePositiveInt(req.query.limit, 500, 1, 5000);

  try {
    const [mergedDataset, matchDetailsSnapshot] = await Promise.all([
      getOperationalArrayDataset(OP_DATASET_MERGED_MATCHES, mergedMatchesForResponse()),
      getOperationalMatchDetailsSnapshotSafe(),
    ]);

    const matches = filterAdminMatches(mergedDataset.items, {
      mode: "results",
      matchDetailsLookup: matchDetailsSnapshot.records || {},
    });
    const limited = matches.slice(0, limit);

    res.status(200).json({
      success: true,
      mode: "results",
      generated_at: new Date().toISOString(),
      count: limited.length,
      total_available: matches.length,
      limit,
      source: mergedDataset.source || "unknown",
      updated_at: mergedDataset.updated_at || null,
      matches: limited,
    });
  } catch (error) {
    console.error("[API] Error retrieving admin results:", error);
    res.status(500).json({
      error: "Failed to retrieve admin results",
      message: error.message,
    });
  }
});

app.get(`${API_PREFIX}/admin/results/:matchId`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const matchId = normalizeMatchDetailsId(req.params.matchId);
  if (!matchId) {
    res.status(400).json({
      error: "Invalid match id. Expected BBC details id (e.g. c043pne0q3kt).",
    });
    return;
  }

  try {
    const [detailsLookup, mergedDataset, historySnapshot, allPreferences] = await Promise.all([
      getOperationalMatchDetailsByIdSafe(matchId),
      getOperationalArrayDataset(OP_DATASET_MERGED_MATCHES, mergedMatchesForResponse()),
      getBbcRealtimeSnapshot({ match_id: matchId, limit_matches: 1 }),
      getAllUserPreferences(),
    ]);

    const mergedItems = Array.isArray(mergedDataset.items) ? mergedDataset.items : [];
    const fallbackRawMatch = mergedItems.find((candidate) => {
      const detailsId =
        matchDetailsIdFromUrl(candidate && candidate.details_url) ||
        normalizeMatchDetailsId(candidate && candidate.match_details_id);
      return detailsId === matchId;
    });
    const fallbackMatchRecord = fallbackRawMatch ? normalizeMatchRecord(fallbackRawMatch) : null;
    const fallbackListPayload = fallbackRawMatch ? toAdminListMatchPayload(fallbackRawMatch) : null;

    const matchPayload = toAdminResultMatchPayload(
      detailsLookup.payload,
      fallbackMatchRecord,
      fallbackListPayload
    );
    if (!matchPayload) {
      res.status(404).json({
        error: "No cached match details found for match id.",
      });
      return;
    }

    const historyMatch = Array.isArray(historySnapshot && historySnapshot.matches)
      ? historySnapshot.matches.find((entry) => String(entry && entry.match_id) === matchId) || null
      : null;
    const eventRecords = Array.isArray(historyMatch && historyMatch.events)
      ? historyMatch.events.slice().sort(sortHistoryRecordsByTimestampAsc)
      : [];
    const notificationRecords = Array.isArray(historyMatch && historyMatch.notifications)
      ? historyMatch.notifications.slice().sort(sortHistoryRecordsByTimestampAsc)
      : [];

    const deviceTokenNameLookup = buildDeviceTokenNameLookup(allPreferences);
    const notificationDispatches = buildNotificationDispatches(
      notificationRecords,
      deviceTokenNameLookup
    );

    res.status(200).json({
      success: true,
      generated_at: new Date().toISOString(),
      match_id: matchId,
      match: matchPayload,
      match_timeline: buildMatchEventTimeline(matchPayload),
      match_source: {
        details: detailsLookup && detailsLookup.source ? detailsLookup.source : "unknown",
        merged_matches: mergedDataset && mergedDataset.source ? mergedDataset.source : "unknown",
      },
      history: {
        source: historySnapshot && historySnapshot.error ? "error" : "redis",
        error: historySnapshot && historySnapshot.error ? historySnapshot.error : null,
        count_events: eventRecords.length,
        count_notifications: notificationRecords.length,
        events: eventRecords,
        notifications: notificationRecords,
        notification_dispatches: notificationDispatches,
      },
      device_tokens_named_count: deviceTokenNameLookup.size,
    });
  } catch (error) {
    console.error("[API] Error retrieving admin result details:", error);
    res.status(500).json({
      error: "Failed to retrieve admin result details",
      message: error.message,
    });
  }
});

app.get(`${API_PREFIX}/admin/bbc-history`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const historyWindow = parseBbcHistoryWindow(req.query || {});
  if (historyWindow.error) {
    res.status(400).json({ error: historyWindow.error });
    return;
  }

  const rawMatchId = req.query.match_id ? String(req.query.match_id).trim() : "";
  const normalizedMatchId = rawMatchId ? normalizeMatchDetailsId(rawMatchId) : null;
  if (rawMatchId && !normalizedMatchId) {
    res.status(400).json({
      error: "Invalid match_id. Expected BBC details id (e.g. c043pne0q3kt).",
    });
    return;
  }

  const rawDeviceToken = req.query.device_token ? String(req.query.device_token).trim() : "";
  const normalizedDeviceToken = rawDeviceToken ? normalizeDeviceToken(rawDeviceToken) : "";
  if (rawDeviceToken && !normalizedDeviceToken) {
    res.status(400).json({
      error: "Invalid device_token filter.",
    });
    return;
  }

  try {
    const groupedHistory = await getBbcMatchHistoryGrouped({
      start_ms: historyWindow.startMs,
      end_ms: historyWindow.endMs,
      match_id: normalizedMatchId || undefined,
      device_token: normalizedDeviceToken || undefined,
    });

    const statusCode = groupedHistory.error ? 500 : 200;
    res.status(statusCode).json({
      success: !groupedHistory.error,
      window: {
        mode: historyWindow.mode,
        start_ms: historyWindow.startMs,
        end_ms: historyWindow.endMs,
        start: new Date(historyWindow.startMs).toISOString(),
        end: new Date(historyWindow.endMs).toISOString(),
        hours: historyWindow.hours || null,
        max_hours: MAX_BBC_HISTORY_QUERY_HOURS,
      },
      filters: {
        match_id: normalizedMatchId || null,
        device_token: normalizedDeviceToken || null,
      },
      history_config: {
        event_ttl_seconds: bbcHistoryConfig.event_ttl_seconds,
        notification_ttl_seconds: bbcHistoryConfig.notification_ttl_seconds,
        notification_idempotency_ttl_seconds:
          bbcHistoryConfig.notification_idempotency_ttl_seconds,
        user_preferences_ttl_seconds: bbcHistoryConfig.user_preferences_ttl_seconds,
      },
      ...groupedHistory,
    });
  } catch (error) {
    console.error("[API] Error retrieving BBC history:", error);
    res.status(500).json({
      error: "Failed to retrieve BBC history",
      message: error.message,
    });
  }
});

app.get(`${API_PREFIX}/admin/bbc-history/realtime`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const rawMatchId = req.query.match_id ? String(req.query.match_id).trim() : "";
  const normalizedMatchId = rawMatchId ? normalizeMatchDetailsId(rawMatchId) : null;
  if (rawMatchId && !normalizedMatchId) {
    res.status(400).json({
      error: "Invalid match_id. Expected BBC details id (e.g. c043pne0q3kt).",
    });
    return;
  }

  const rawDeviceToken = req.query.device_token ? String(req.query.device_token).trim() : "";
  const normalizedDeviceToken = rawDeviceToken ? normalizeDeviceToken(rawDeviceToken) : "";
  if (rawDeviceToken && !normalizedDeviceToken) {
    res.status(400).json({
      error: "Invalid device_token filter.",
    });
    return;
  }

  const limitMatches = parsePositiveInt(req.query.limit_matches, 0, 0, 1000);

  try {
    const [snapshot, operationalSnapshot] = await Promise.all([
      getBbcRealtimeSnapshot({
        match_id: normalizedMatchId || undefined,
        device_token: normalizedDeviceToken || undefined,
        limit_matches: limitMatches || undefined,
      }),
      getOperationalRealtimeSnapshot({
        match_id: normalizedMatchId || undefined,
        limit_matches: limitMatches || undefined,
      }),
    ]);

    const hasError = Boolean(
      (snapshot && snapshot.error) ||
      (operationalSnapshot && operationalSnapshot.error)
    );
    const statusCode = hasError ? 500 : 200;
    res.status(statusCode).json({
      success: !hasError,
      realtime: true,
      ...snapshot,
      operational: operationalSnapshot,
    });
  } catch (error) {
    console.error("[API] Error retrieving BBC realtime snapshot:", error);
    res.status(500).json({
      error: "Failed to retrieve BBC realtime snapshot",
      message: error.message,
    });
  }
});

app.post(`${API_PREFIX}/admin/bbc-history/cleanup`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const payload =
    req.body && typeof req.body === "object" && !Array.isArray(req.body)
      ? req.body
      : {};

  const parseBoolean = (value, fallback = false) => {
    if (value === undefined || value === null) return fallback;
    if (typeof value === "boolean") return value;
    const normalized = String(value).trim().toLowerCase();
    if (["1", "true", "yes", "on"].includes(normalized)) return true;
    if (["0", "false", "no", "off"].includes(normalized)) return false;
    return fallback;
  };

  const rawMatchIds = [];
  if (payload.match_id !== undefined && payload.match_id !== null) {
    rawMatchIds.push(payload.match_id);
  }
  if (Array.isArray(payload.match_ids)) {
    payload.match_ids.forEach((value) => rawMatchIds.push(value));
  } else if (typeof payload.match_ids === "string") {
    payload.match_ids
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean)
      .forEach((value) => rawMatchIds.push(value));
  }

  const normalizedMatchIds = [];
  const invalidMatchIds = [];
  rawMatchIds
    .map((value) => String(value || "").trim())
    .filter(Boolean)
    .forEach((value) => {
      const normalized = normalizeMatchDetailsId(value);
      if (!normalized) {
        invalidMatchIds.push(value);
        return;
      }
      if (!normalizedMatchIds.includes(normalized)) normalizedMatchIds.push(normalized);
    });

  if (invalidMatchIds.length > 0) {
    res.status(400).json({
      error: "Invalid match_ids. Expected BBC details ids (e.g. c043pne0q3kt).",
      invalid_match_ids: invalidMatchIds,
    });
    return;
  }

  const rawDeviceToken =
    payload.device_token !== undefined && payload.device_token !== null
      ? String(payload.device_token).trim()
      : "";
  const normalizedDeviceToken = rawDeviceToken ? normalizeDeviceToken(rawDeviceToken) : "";
  if (rawDeviceToken && !normalizedDeviceToken) {
    res.status(400).json({
      error: "Invalid device_token filter.",
    });
    return;
  }

  const rawStart = payload.start ? String(payload.start).trim() : "";
  const rawEnd = payload.end ? String(payload.end).trim() : "";
  let startMs = null;
  let endMs = null;
  if (rawStart || rawEnd) {
    if (!rawStart || !rawEnd) {
      res.status(400).json({
        error: "When using absolute range cleanup, both start and end are required (ISO datetime).",
      });
      return;
    }
    startMs = Date.parse(rawStart);
    endMs = Date.parse(rawEnd);
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs)) {
      res.status(400).json({
        error: "Invalid cleanup start/end datetime. Use ISO format.",
      });
      return;
    }
    if (endMs < startMs) {
      res.status(400).json({
        error: "Invalid cleanup date range. end must be greater than or equal to start.",
      });
      return;
    }
    if (endMs - startMs > MAX_BBC_HISTORY_QUERY_MS) {
      res.status(400).json({
        error: `Maximum cleanup query range is ${MAX_BBC_HISTORY_QUERY_HOURS} hours (7 days).`,
      });
      return;
    }
  }

  const dryRun = parseBoolean(payload.dry_run, true);
  const allowAll = parseBoolean(payload.allow_all, false);
  const hasAnyFilter = normalizedMatchIds.length > 0 || Boolean(normalizedDeviceToken) || rawStart || rawEnd;
  if (!hasAnyFilter && !allowAll) {
    res.status(400).json({
      error:
        "Cleanup requires at least one filter (match_id(s), device_token, or start/end) unless allow_all=true.",
    });
    return;
  }

  try {
    const cleanupResult = await cleanupBbcHistory({
      match_ids: normalizedMatchIds,
      device_token: normalizedDeviceToken || undefined,
      start_ms: Number.isFinite(startMs) ? startMs : undefined,
      end_ms: Number.isFinite(endMs) ? endMs : undefined,
      dry_run: dryRun,
    });

    const statusCode = cleanupResult.error ? 500 : 200;
    res.status(statusCode).json({
      success: !cleanupResult.error,
      cleanup: cleanupResult,
      history_config: bbcHistoryConfig,
    });
  } catch (error) {
    console.error("[API] Error cleaning BBC history:", error);
    res.status(500).json({
      error: "Failed to cleanup BBC history",
      message: error.message,
    });
  }
});

app.post(`${API_PREFIX}/admin/bbc-state/backfill-range`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const payload =
    req.body && typeof req.body === "object" && !Array.isArray(req.body)
      ? req.body
      : {};

  const parseBoolean = (value, fallback = false) => {
    if (value === undefined || value === null) return fallback;
    if (typeof value === "boolean") return value;
    const normalized = String(value).trim().toLowerCase();
    if (["1", "true", "yes", "on"].includes(normalized)) return true;
    if (["0", "false", "no", "off"].includes(normalized)) return false;
    return fallback;
  };

  const startDate = String(payload.start_date || payload.start || "").trim();
  const endDate = String(payload.end_date || payload.end || "").trim();
  if (!startDate || !endDate) {
    res.status(400).json({
      error: "Missing required fields: start_date and end_date (YYYY-MM-DD).",
    });
    return;
  }
  if (!isDateOnly(startDate) || !isDateOnly(endDate)) {
    res.status(400).json({
      error: "Invalid date format. Expected YYYY-MM-DD for start_date and end_date.",
    });
    return;
  }
  if (startDate > endDate) {
    res.status(400).json({
      error: "Invalid date range. start_date must be on or before end_date.",
    });
    return;
  }

  const startMs = Date.parse(`${startDate}T00:00:00.000Z`);
  const endMs = Date.parse(`${endDate}T23:59:59.999Z`);
  const spanDays = Math.floor((endMs - startMs) / (24 * 60 * 60 * 1000)) + 1;
  const maxSpanDays = 366;
  if (spanDays > maxSpanDays) {
    res.status(400).json({
      error: `Date range too large. Maximum span is ${maxSpanDays} days.`,
    });
    return;
  }

  const concurrency = parsePositiveInt(
    payload.concurrency,
    BBC_RANGE_CONCURRENCY,
    1,
    50
  );
  const applyToRangeCache = parseBoolean(payload.apply_to_range_cache, true);
  const startedAtMs = Date.now();

  try {
    const fetchedMatches = filterMatchesByCompetition(
      await fetchBbcScoresFixturesByDateRange({
        baseUrl: BBC_RANGE_BASE_URL,
        startDate,
        endDate,
        concurrency,
        timeZone: BBC_RANGE_MATCH_TIMEZONE,
      })
    );

    let nextRangeMatches = fetchedMatches;
    let existingRangeCount = cachedBbcRangeMatches.length;
    if (applyToRangeCache) {
      const rangeDataset = await getOperationalArrayDataset(
        OP_DATASET_BBC_RANGE_MATCHES,
        cachedBbcRangeMatches
      );
      const existingRangeMatches = Array.isArray(rangeDataset.items) ? rangeDataset.items : [];
      existingRangeCount = existingRangeMatches.length;
      const outsideRequestedWindow = existingRangeMatches.filter((match) => {
        const date = String(match && match.date ? match.date : "").trim();
        if (!date || !isDateOnly(date)) return true;
        return date < startDate || date > endDate;
      });
      nextRangeMatches = mergeBbcAndLive(
        [...outsideRequestedWindow, ...fetchedMatches],
        []
      );
      nextRangeMatches = filterMatchesByCompetition(nextRangeMatches);

      cachedBbcRangeMatches = nextRangeMatches;
      bbcRangeLastUpdated = new Date().toISOString();
      setSourceCacheSize(SOURCE_BBC_RANGE, nextRangeMatches.length);
      writeBbcRangeMatches(BBC_RANGE_OUTPUT_PATH, nextRangeMatches);
      await persistOperationalDatasetSafe(OP_DATASET_BBC_RANGE_MATCHES, nextRangeMatches, {
        updated_at: bbcRangeLastUpdated,
        source: "admin_bbc_range_backfill",
      });
      await rebuildMergedMatchesCache("admin_bbc_range_backfill");
    }

    res.status(200).json({
      success: true,
      backfill: {
        start_date: startDate,
        end_date: endDate,
        span_days: spanDays,
        concurrency,
        apply_to_range_cache: applyToRangeCache,
        fetched_matches: fetchedMatches.length,
        existing_range_matches: existingRangeCount,
        updated_range_matches: nextRangeMatches.length,
        duration_ms: Date.now() - startedAtMs,
      },
      state: {
        bbc_range_last_updated: bbcRangeLastUpdated,
        bbc_range_count: cachedBbcRangeMatches.length,
      },
    });
  } catch (error) {
    console.error("[API] Error backfilling BBC range state:", error);
    res.status(500).json({
      error: "Failed to backfill BBC range state",
      message: error.message,
    });
  }
});

// ===== Push Notification & Live Activity Testing Endpoints =====
const { sendNotification, sendLiveActivityPush } = require("./apns_client");

const LIVE_ACTIVITY_TEST_MODES = new Set([
  "single_upcoming",
  "single_live",
  "multi_upcoming",
  "multi_live",
]);

function normalizeLiveActivityTestMode(value, fallback = "single_live") {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
  if (LIVE_ACTIVITY_TEST_MODES.has(normalized)) return normalized;
  return fallback;
}

function normalizeLiveActivityTestDelay(value, fallback = 0) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(0, Math.min(10, Math.floor(parsed)));
}

function normalizeLiveActivityTestHoldSeconds(value, fallback = 300) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(30, Math.min(1800, Math.floor(parsed)));
}

function liveActivityNowTimeLabel(now = new Date()) {
  return now.toLocaleTimeString("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

function normalizeLiveActivityTestMatch(rawMatch, index = 0, now = new Date()) {
  const match = rawMatch && typeof rawMatch === "object" ? rawMatch : {};
  const fallbackKickoff = liveActivityNowTimeLabel(now);
  const fallbackHome = index % 2 === 0 ? "Atalanta" : "Norwich City";
  const fallbackAway = index % 2 === 0 ? "Borussia Dortmund" : "Sheffield Wednesday";

  return {
    matchId: String(match.matchId || match.match_id || `test_match_${index + 1}`).trim(),
    date: String(match.date || now.toISOString().split("T")[0]).trim(),
    time: String(match.time || fallbackKickoff).trim(),
    league: String(match.league || "UEFA Champions League").trim(),
    leagueSubcategory:
      match.leagueSubcategory !== undefined && match.leagueSubcategory !== null
        ? String(match.leagueSubcategory).trim()
        : match.league_subcategory !== undefined && match.league_subcategory !== null
          ? String(match.league_subcategory).trim()
          : null,
    homeTeam: String(match.homeTeam || match.home_team || fallbackHome).trim(),
    awayTeam: String(match.awayTeam || match.away_team || fallbackAway).trim(),
    homeScore: Number.isFinite(Number(match.homeScore)) ? Number(match.homeScore) : null,
    awayScore: Number.isFinite(Number(match.awayScore)) ? Number(match.awayScore) : null,
    aggregateHomeScore: Number.isFinite(Number(match.aggregateHomeScore))
      ? Number(match.aggregateHomeScore)
      : Number.isFinite(Number(match.aggregate_home_score))
        ? Number(match.aggregate_home_score)
        : null,
    aggregateAwayScore: Number.isFinite(Number(match.aggregateAwayScore))
      ? Number(match.aggregateAwayScore)
      : Number.isFinite(Number(match.aggregate_away_score))
        ? Number(match.aggregate_away_score)
        : null,
    matchTime:
      match.matchTime !== undefined && match.matchTime !== null
        ? String(match.matchTime).trim()
        : null,
    tvChannels: Array.isArray(match.tvChannels || match.tv_channels)
      ? (match.tvChannels || match.tv_channels)
          .map((channel) => String(channel || "").trim())
          .filter(Boolean)
          .slice(0, 3)
      : ["TNT Sports 1"],
  };
}

function defaultLiveActivityTestMatches(mode, now = new Date()) {
  const timeLabel = liveActivityNowTimeLabel(now);
  if (mode === "single_upcoming") {
    return [
      normalizeLiveActivityTestMatch(
        {
          matchId: "test_upcoming_1",
          date: now.toISOString().split("T")[0],
          time: timeLabel,
          league: "UEFA Champions League",
          leagueSubcategory: "Round of 16",
          homeTeam: "Atalanta",
          awayTeam: "Borussia Dortmund",
          homeScore: null,
          awayScore: null,
          aggregateHomeScore: 2,
          aggregateAwayScore: 2,
          matchTime: null,
          tvChannels: ["TNT Sports 1"],
        },
        0,
        now
      ),
    ];
  }
  if (mode === "single_live") {
    return [
      normalizeLiveActivityTestMatch(
        {
          matchId: "test_live_1",
          date: now.toISOString().split("T")[0],
          time: timeLabel,
          league: "UEFA Champions League",
          leagueSubcategory: "Round of 16",
          homeTeam: "Atalanta",
          awayTeam: "Borussia Dortmund",
          homeScore: 1,
          awayScore: 0,
          aggregateHomeScore: 3,
          aggregateAwayScore: 2,
          matchTime: "7'",
          tvChannels: ["TNT Sports 1"],
        },
        0,
        now
      ),
    ];
  }
  if (mode === "multi_upcoming") {
    return [
      normalizeLiveActivityTestMatch(
        {
          matchId: "test_multi_upcoming_1",
          date: now.toISOString().split("T")[0],
          time: "19:45",
          league: "Premier League",
          homeTeam: "Norwich City",
          awayTeam: "Sheffield Wednesday",
          tvChannels: ["Sky Sports Main Event"],
        },
        0,
        now
      ),
      normalizeLiveActivityTestMatch(
        {
          matchId: "test_multi_upcoming_2",
          date: now.toISOString().split("T")[0],
          time: "20:00",
          league: "UEFA Champions League",
          homeTeam: "Atalanta",
          awayTeam: "Borussia Dortmund",
          tvChannels: ["TNT Sports 1"],
        },
        1,
        now
      ),
    ];
  }
  return [
    normalizeLiveActivityTestMatch(
      {
        matchId: "test_multi_live_1",
        date: now.toISOString().split("T")[0],
        time: "19:45",
        league: "UEFA Champions League",
        leagueSubcategory: "Round of 16",
        homeTeam: "Atalanta",
        awayTeam: "Borussia Dortmund",
        homeScore: 2,
        awayScore: 0,
        aggregateHomeScore: 4,
        aggregateAwayScore: 2,
        matchTime: "45+2'",
        tvChannels: ["TNT Sports 1"],
      },
      0,
      now
    ),
    normalizeLiveActivityTestMatch(
      {
        matchId: "test_multi_live_2",
        date: now.toISOString().split("T")[0],
        time: "20:00",
        league: "Premier League",
        homeTeam: "Norwich City",
        awayTeam: "Sheffield Wednesday",
        homeScore: 1,
        awayScore: 1,
        matchTime: "55'",
        tvChannels: ["Sky Sports Main Event"],
      },
      1,
      now
    ),
  ];
}

function buildLiveActivityTestContentState(payload = {}) {
  const now = new Date();
  const mode = normalizeLiveActivityTestMode(payload.mode, "single_live");
  const delayMinutes = normalizeLiveActivityTestDelay(payload.delayMinutes, 0);
  const providedMatches = Array.isArray(payload.matches) ? payload.matches : [];
  const matchesSource =
    providedMatches.length > 0 ? providedMatches : defaultLiveActivityTestMatches(mode, now);
  const matches = matchesSource
    .map((match, index) => normalizeLiveActivityTestMatch(match, index, now))
    .slice(0, 10);
  const delayLabel =
    delayMinutes > 0 && mode.includes("live") ? `Delayed by ${delayMinutes}m` : null;

  return {
    mode,
    generatedAtEpochSeconds: Math.floor(now.getTime() / 1000),
    delayMinutes,
    delayLabel,
    matches,
  };
}

function resolveLiveActivityTestUserDeviceToken(req, body = {}) {
  const headerToken = req.deviceToken ? normalizeDeviceToken(req.deviceToken) : "";
  if (headerToken) return headerToken;
  const fromUserField = normalizeDeviceToken(body.userDeviceToken);
  if (fromUserField) return fromUserField;
  return normalizeDeviceToken(body.deviceToken);
}

function isLiveActivityTerminalResult(result) {
  const message = String(result && result.error ? result.error : "").toLowerCase();
  if (!message) return false;
  return (
    message.includes("baddevicetoken") ||
    message.includes("unregistered") ||
    message.includes("device token not for topic")
  );
}

app.get(`${API_PREFIX}/live-activity/test/state`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const resolvedDeviceToken = resolveLiveActivityTestUserDeviceToken(req, req.query || {});
  if (!resolvedDeviceToken) {
    res.status(400).json({
      error: "Missing user device token. Provide X-Device-Token header or userDeviceToken query field.",
    });
    return;
  }

  try {
    const record = await getUserPreferences(resolvedDeviceToken);
    if (!record) {
      res.status(404).json({
        error: "No preferences found for user device token.",
        userDeviceToken: resolvedDeviceToken,
      });
      return;
    }
    res.status(200).json({
      success: true,
      userDeviceToken: resolvedDeviceToken,
      apnsTokenPresent: Boolean(record.apnsToken),
      isDevelopmentBuild: Boolean(record.isDevelopmentBuild),
      liveActivity: record.liveActivity || null,
    });
  } catch (error) {
    res.status(500).json({
      error: "Failed to fetch live activity test state",
      message: error.message,
    });
  }
});

app.post(`${API_PREFIX}/live-activity/test/start`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const payload =
    req.body && typeof req.body === "object" && !Array.isArray(req.body) ? req.body : {};
  const userDeviceToken = resolveLiveActivityTestUserDeviceToken(req, payload);
  if (!userDeviceToken) {
    res.status(400).json({
      error: "Missing user device token. Provide X-Device-Token header or userDeviceToken/deviceToken body field.",
    });
    return;
  }

  try {
    const record = await getUserPreferences(userDeviceToken);
    const explicitActivityPushToken = normalizeLiveActivityToken(payload.activityPushToken);
    const storedActivityPushToken = normalizeLiveActivityToken(
      record && record.liveActivity ? record.liveActivity.currentActivityPushToken : ""
    );
    const activityPushToken = explicitActivityPushToken || storedActivityPushToken;
    const explicitPushToStartToken = normalizeLiveActivityToken(payload.pushToStartToken);
    const storedPushToStartToken = normalizeLiveActivityToken(
      record && record.liveActivity ? record.liveActivity.pushToStartToken : ""
    );
    const pushToStartToken = explicitPushToStartToken || storedPushToStartToken;
    const forceStart = payload.forceStart === true;
    const contentState = buildLiveActivityTestContentState(payload);
    if (!pushToStartToken) {
      res.status(400).json({
        error:
          "No push-to-start token available. Ensure the app uploaded it or provide pushToStartToken in request body.",
      });
      return;
    }

    const isDevelopmentBuild =
      typeof payload.isDevelopmentBuild === "boolean"
        ? payload.isDevelopmentBuild
        : Boolean(record && record.isDevelopmentBuild);
    const title = String(payload.title || "Top Scores Test").trim();
    const body = String(payload.body || "Live Activity test start").trim();
    const timestamp = Math.floor(Date.now() / 1000);
    const fallbackStartOnUpdateFailure = payload.fallbackStartOnUpdateFailure === true;
    const testHoldSeconds = normalizeLiveActivityTestHoldSeconds(payload.testHoldSeconds, 300);
    const testHoldUntil = new Date((timestamp + testHoldSeconds) * 1000).toISOString();

    if (activityPushToken && !forceStart) {
      const updateResult = await sendLiveActivityPush({
        token: activityPushToken,
        event: "update",
        contentState,
        staleDate: timestamp + 30 * 60,
        isDevelopmentBuild,
      });

      if (updateResult.success) {
        await updateUserLiveActivityState(
          userDeviceToken,
          {
            pendingStartAt: null,
            lastMode: contentState.mode,
            lastDispatchAt: new Date().toISOString(),
            testHoldUntil,
          },
          {
            isDevelopmentBuild,
          }
        );
        res.status(200).json({
          success: true,
          userDeviceToken,
          dispatch: "update_existing",
          forceStart,
          testHoldSeconds,
          result: updateResult,
          contentState,
        });
        return;
      }

      const terminalUpdateFailure =
        Boolean(updateResult && updateResult.isTerminal) || isLiveActivityTerminalResult(updateResult);
      if (terminalUpdateFailure) {
        await updateUserLiveActivityState(
          userDeviceToken,
          {
            currentActivityPushToken: null,
            currentActivityId: null,
            pendingStartAt: null,
            lastMode: null,
            lastDispatchAt: new Date().toISOString(),
            testHoldUntil: null,
          },
          {
            isDevelopmentBuild,
          }
        );
      }

      if ((terminalUpdateFailure || fallbackStartOnUpdateFailure) && pushToStartToken) {
        const fallbackStartResult = await sendLiveActivityPush({
          token: pushToStartToken,
          event: "start",
          attributesType: "TopScoresLiveActivityAttributes",
          attributes: { appScope: "topscores" },
          contentState,
          staleDate: timestamp + 30 * 60,
          alert: {
            title,
            body,
          },
          isDevelopmentBuild,
        });

        if (fallbackStartResult.success) {
          await updateUserLiveActivityState(
            userDeviceToken,
            {
              pendingStartAt: new Date().toISOString(),
              lastStartAt: new Date().toISOString(),
              lastMode: contentState.mode,
              lastDispatchAt: new Date().toISOString(),
              testHoldUntil,
            },
            {
              isDevelopmentBuild,
            }
          );
        }

        res.status(fallbackStartResult.success ? 200 : 502).json({
          success: Boolean(fallbackStartResult.success),
          userDeviceToken,
          dispatch: "fallback_start_after_update_failure",
          forceStart,
          testHoldSeconds,
          updateResult,
          result: fallbackStartResult,
          contentState,
        });
        return;
      }

      res.status(502).json({
        success: false,
        userDeviceToken,
        dispatch: "update_existing_failed",
        forceStart,
        result: updateResult,
        contentState,
      });
      return;
    }

    const result = await sendLiveActivityPush({
      token: pushToStartToken,
      event: "start",
      attributesType: "TopScoresLiveActivityAttributes",
      attributes: { appScope: "topscores" },
      contentState,
      staleDate: timestamp + 30 * 60,
      alert: {
        title,
        body,
      },
      isDevelopmentBuild,
    });

    if (result.success) {
      await updateUserLiveActivityState(
        userDeviceToken,
        {
          pendingStartAt: new Date().toISOString(),
          lastStartAt: new Date().toISOString(),
          lastMode: contentState.mode,
          lastDispatchAt: new Date().toISOString(),
          testHoldUntil,
        },
        {
          isDevelopmentBuild,
        }
      );
    }

    res.status(result.success ? 200 : 502).json({
      success: Boolean(result.success),
      userDeviceToken,
      dispatch: "start_new",
      forceStart,
      testHoldSeconds,
      result,
      contentState,
    });
  } catch (error) {
    res.status(500).json({
      error: "Failed to send live activity test start push",
      message: error.message,
    });
  }
});

app.post(`${API_PREFIX}/live-activity/test/update`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const payload =
    req.body && typeof req.body === "object" && !Array.isArray(req.body) ? req.body : {};
  const userDeviceToken = resolveLiveActivityTestUserDeviceToken(req, payload);
  if (!userDeviceToken) {
    res.status(400).json({
      error: "Missing user device token. Provide X-Device-Token header or userDeviceToken/deviceToken body field.",
    });
    return;
  }

  try {
    const record = await getUserPreferences(userDeviceToken);
    const explicitActivityPushToken = normalizeLiveActivityToken(payload.activityPushToken);
    const storedActivityPushToken = normalizeLiveActivityToken(
      record && record.liveActivity ? record.liveActivity.currentActivityPushToken : ""
    );
    const activityPushToken = explicitActivityPushToken || storedActivityPushToken;
    if (!activityPushToken) {
      res.status(400).json({
        error:
          "No activity push token available. Wait for app callback after start, or provide activityPushToken in request body.",
      });
      return;
    }

    const isDevelopmentBuild =
      typeof payload.isDevelopmentBuild === "boolean"
        ? payload.isDevelopmentBuild
        : Boolean(record && record.isDevelopmentBuild);
    const contentState = buildLiveActivityTestContentState(payload);
    const timestamp = Math.floor(Date.now() / 1000);

    const result = await sendLiveActivityPush({
      token: activityPushToken,
      event: "update",
      contentState,
      staleDate: timestamp + 30 * 60,
      isDevelopmentBuild,
    });

    if (result.success) {
      await updateUserLiveActivityState(
        userDeviceToken,
        {
          lastMode: contentState.mode,
          lastDispatchAt: new Date().toISOString(),
        },
        {
          isDevelopmentBuild,
        }
      );
    }

    res.status(result.success ? 200 : 502).json({
      success: Boolean(result.success),
      userDeviceToken,
      result,
      contentState,
    });
  } catch (error) {
    res.status(500).json({
      error: "Failed to send live activity test update push",
      message: error.message,
    });
  }
});

app.post(`${API_PREFIX}/live-activity/test/end`, async (req, res) => {
  setCacheOnlyHeaders(res);
  const payload =
    req.body && typeof req.body === "object" && !Array.isArray(req.body) ? req.body : {};
  const userDeviceToken = resolveLiveActivityTestUserDeviceToken(req, payload);
  if (!userDeviceToken) {
    res.status(400).json({
      error: "Missing user device token. Provide X-Device-Token header or userDeviceToken/deviceToken body field.",
    });
    return;
  }

  try {
    const record = await getUserPreferences(userDeviceToken);
    const explicitActivityPushToken = normalizeLiveActivityToken(payload.activityPushToken);
    const storedActivityPushToken = normalizeLiveActivityToken(
      record && record.liveActivity ? record.liveActivity.currentActivityPushToken : ""
    );
    const activityPushToken = explicitActivityPushToken || storedActivityPushToken;
    const isDevelopmentBuild =
      typeof payload.isDevelopmentBuild === "boolean"
        ? payload.isDevelopmentBuild
        : Boolean(record && record.isDevelopmentBuild);

    if (!activityPushToken) {
      await updateUserLiveActivityState(
        userDeviceToken,
        {
          currentActivityPushToken: null,
          currentActivityId: null,
          pendingStartAt: null,
          lastMode: null,
          lastPayloadHash: null,
          lastEndedAt: new Date().toISOString(),
          testHoldUntil: null,
        },
        {
          isDevelopmentBuild,
        }
      );
      res.status(200).json({
        success: true,
        userDeviceToken,
        message: "No activity token found; state cleared.",
      });
      return;
    }

    const timestamp = Math.floor(Date.now() / 1000);
    const result = await sendLiveActivityPush({
      token: activityPushToken,
      event: "end",
      contentState: {
        mode: "ended",
        generatedAtEpochSeconds: timestamp,
        delayMinutes: 0,
        delayLabel: null,
        matches: [],
      },
      dismissalDate: timestamp + 30,
      isDevelopmentBuild,
    });

    if (result.success) {
      await updateUserLiveActivityState(
        userDeviceToken,
        {
          currentActivityPushToken: null,
          currentActivityId: null,
          pendingStartAt: null,
          lastMode: null,
          lastPayloadHash: null,
          lastEndedAt: new Date().toISOString(),
          testHoldUntil: null,
        },
        {
          isDevelopmentBuild,
        }
      );
    }

    res.status(result.success ? 200 : 502).json({
      success: Boolean(result.success),
      userDeviceToken,
      result,
    });
  } catch (error) {
    res.status(500).json({
      error: "Failed to send live activity test end push",
      message: error.message,
    });
  }
});

// Send a test notification to a specific device
app.post(`${API_PREFIX}/notifications/test`, async (req, res) => {
  setCacheOnlyHeaders(res);

  const { deviceToken, userDeviceToken, apnsToken, title, body, isDevelopmentBuild } = req.body || {};

  const normalizedLegacyDeviceToken =
    typeof deviceToken === "string" ? deviceToken.trim() : "";
  const normalizedUserDeviceToken =
    typeof userDeviceToken === "string" ? userDeviceToken.trim() : "";
  const normalizedProvidedAPNSToken =
    typeof apnsToken === "string" ? apnsToken.trim() : "";

  const looksLikeAPNSToken = (value) => /^[a-f0-9]{64,}$/i.test(value);

  let resolvedAPNSToken = normalizedProvidedAPNSToken;
  let resolvedIsDevelopmentBuild =
    typeof isDevelopmentBuild === "boolean" ? isDevelopmentBuild : false;
  let usedStoredAPNSToken = false;

  // Backward compatibility: legacy clients sent APNS token in `deviceToken`.
  if (!resolvedAPNSToken && normalizedLegacyDeviceToken && looksLikeAPNSToken(normalizedLegacyDeviceToken)) {
    resolvedAPNSToken = normalizedLegacyDeviceToken;
  }

  const lookupDeviceToken =
    normalizedUserDeviceToken ||
    (!looksLikeAPNSToken(normalizedLegacyDeviceToken) ? normalizedLegacyDeviceToken : "");

  if (!resolvedAPNSToken && lookupDeviceToken) {
    try {
      const stored = await getUserPreferences(lookupDeviceToken);
      if (stored && typeof stored.apnsToken === "string" && stored.apnsToken.trim()) {
        resolvedAPNSToken = stored.apnsToken.trim();
        usedStoredAPNSToken = true;
        if (
          typeof isDevelopmentBuild !== "boolean" &&
          typeof stored.isDevelopmentBuild === "boolean"
        ) {
          resolvedIsDevelopmentBuild = stored.isDevelopmentBuild;
        }
      }
    } catch (lookupError) {
      console.warn("[API] Failed to resolve APNS token from stored preferences:", lookupError);
    }
  }

  if (!resolvedAPNSToken) {
    res.status(400).json({
      error:
        "Missing APNS token. Provide `apnsToken` (or legacy APNS `deviceToken`) or a known `userDeviceToken` with synced preferences.",
    });
    return;
  }

  try {
    const result = await sendNotification(
      resolvedAPNSToken,
      title || "Test Notification",
      body || "This is a test notification from Top Scores API",
      {
        test: true,
        source: "manual_test",
        requested_at: new Date().toISOString(),
      },
      resolvedIsDevelopmentBuild
    );

    res.status(200).json({
      success: result.success,
      usedStoredAPNSToken,
      ...result,
    });
  } catch (error) {
    console.error("[API] Error sending test notification:", error);
    res.status(500).json({
      error: "Failed to send test notification",
      message: error.message,
    });
  }
});

// ===== End User Preferences Endpoints =====

async function seedOperationalStateFromDiskIfNeeded() {
  const [mergedDataset, matchDetailsSummary] = await Promise.all([
    loadOperationalDatasetSafe(OP_DATASET_MERGED_MATCHES),
    getOperationalMatchDetailsSummary(),
  ]);
  const hasMergedState =
    mergedDataset && Array.isArray(mergedDataset.payload) && mergedDataset.payload.length > 0;
  const hasMatchDetails = Number(matchDetailsSummary && matchDetailsSummary.total) > 0;
  if (hasMergedState && hasMatchDetails) {
    return { seeded: false, reason: "redis_has_state" };
  }

  await persistStartupOperationalStateFromDisk();
  return { seeded: true, reason: "redis_was_empty_or_partial" };
}

async function bootstrapOperationalState() {
  loadMissingTeamLogosFromDisk();

  await hydrateOperationalStateFromRedis();
  const seedResult = await seedOperationalStateFromDiskIfNeeded();
  if (seedResult.seeded) {
    await hydrateOperationalStateFromRedis();
  }

  await updateRecentCache("startup_bootstrap");
  await rebuildMergedMatchesCache("startup_bootstrap");
  await rebuildMatchDetailsCache("startup_bootstrap");

  // Run network refresh tasks in background after bootstrapping cached state.
  void refreshInProgressMatchDetails();
  void updateMatches();
  void updateBbcMatches();
  void updateBbcRangeMatches();
  void updatePremierLeagueTeams();
  void updateLeagueTables();
}

const operationalBootstrapPromise = bootstrapOperationalState().catch((error) => {
  console.warn("[Startup] Operational bootstrap failed:", error.message || error);
});

const interval = Number.isFinite(INTERVAL_MS) && INTERVAL_MS > 0 ? INTERVAL_MS : 30 * 60 * 1000;
setInterval(updateMatches, interval);
const bbcInterval = Number.isFinite(BBC_INTERVAL_MS) && BBC_INTERVAL_MS > 0 ? BBC_INTERVAL_MS : 30 * 1000;
setInterval(updateBbcMatches, bbcInterval);
const bbcRangeInterval =
  Number.isFinite(BBC_RANGE_INTERVAL_MS) && BBC_RANGE_INTERVAL_MS > 0
    ? BBC_RANGE_INTERVAL_MS
    : 60 * 60 * 1000;
setInterval(updateBbcRangeMatches, bbcRangeInterval);
const eplInterval =
  Number.isFinite(EPL_INTERVAL_MS) && EPL_INTERVAL_MS > 0 ? EPL_INTERVAL_MS : 24 * 60 * 60 * 1000;
setInterval(updatePremierLeagueTeams, eplInterval);
const leagueTablesInterval =
  Number.isFinite(LEAGUE_TABLES_INTERVAL_MS) && LEAGUE_TABLES_INTERVAL_MS > 0
    ? LEAGUE_TABLES_INTERVAL_MS
    : 2 * 60 * 1000;
setInterval(updateLeagueTables, leagueTablesInterval);
const matchDetailsPollInterval =
  Number.isFinite(MATCH_DETAILS_POLL_INTERVAL_MS) && MATCH_DETAILS_POLL_INTERVAL_MS > 0
    ? MATCH_DETAILS_POLL_INTERVAL_MS
    : 10 * 1000;
setInterval(refreshInProgressMatchDetails, matchDetailsPollInterval);

// Test harness endpoints (for internal use only)
app.get(`${API_PREFIX}/test-harness/match`, (req, res) => {
  const matchId = req.query.matchId || null;
  const match = testMatchState.getMatch(matchId);
  if (!match) {
    res.json({ active: false, match: null });
  } else {
    res.json({
      active: true,
      match: match,
      config: match.config,
      isPaused: match.isPaused,
      matchMinute: match.matchMinute,
    });
  }
});

app.post(`${API_PREFIX}/test-harness/match/create`, express.json(), (req, res) => {
  try {
    const match = testMatchState.createMatch(req.body);
    res.json({ success: true, match });
  } catch (err) {
    console.error("Failed to create test match:", err);
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/start`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.startSimulation(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/pause`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.pauseSimulation(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/resume`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.resumeSimulation(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/add-goal`, express.json(), (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    const isHome = req.body.team === "home";
    testMatchState.addGoal(matchId, isHome, req.body.playerName, req.body.assisterName);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/add-red-card`, express.json(), (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    const isHome = req.body.team === "home";
    testMatchState.addRedCard(matchId, isHome, req.body.playerName);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/jump-to-ht`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.jumpToHalfTime(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/jump-to-ft`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.jumpToFullTime(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/restart`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.restartMatch(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/set-speed`, express.json(), (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    const speedMs = parseInt(req.body.speedMs);
    if (isNaN(speedMs) || speedMs < 100) {
      return res.status(400).json({ error: "speedMs must be a number >= 100" });
    }
    testMatchState.setMatchSpeed(matchId, speedMs);
    res.json({ success: true, speedMs });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post(`${API_PREFIX}/test-harness/match/delete`, (req, res) => {
  try {
    const matchId = req.query.matchId || null;
    testMatchState.deleteMatch(matchId);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ===== Match Monitoring for Push Notifications =====
const matchMonitor = require("./match_monitor");

// Initialize and start match monitoring
const SERVER_BASE_URL = `http://localhost:${PORT}${API_PREFIX}`;
matchMonitor.initialize(SERVER_BASE_URL);

// Status endpoint for monitoring
app.get(`${API_PREFIX}/monitor/status`, (req, res) => {
  setCacheOnlyHeaders(res);
  const rawMatchId = req.query.match_id ? String(req.query.match_id).trim() : "";
  const normalizedMatchId = rawMatchId ? normalizeMatchDetailsId(rawMatchId) : "";
  if (rawMatchId && !normalizedMatchId) {
    res.status(400).json({
      error: "Invalid match_id. Expected BBC details id (e.g. c043pne0q3kt).",
    });
    return;
  }
  const limitRecent = parsePositiveInt(req.query.limit_recent, 50, 1, 500);
  const status = matchMonitor.getStatus({
    matchId: normalizedMatchId || "",
    limitRecent,
  });
  res.status(200).json({
    success: true,
    filters: {
      match_id: normalizedMatchId || null,
      limit_recent: limitRecent,
    },
    ...status,
  });
});

app.listen(PORT, () => {
  console.log(`Server listening on http://localhost:${PORT}`);

  // Start match monitoring after server is ready
  setTimeout(async () => {
    await operationalBootstrapPromise;
    matchMonitor.startMonitoring();
  }, 2000); // Wait 2 seconds for server to fully initialize
});

// Graceful shutdown
process.on("SIGTERM", async () => {
  console.log("SIGTERM received, shutting down gracefully");
  matchMonitor.stopMonitoring();
  const { shutdown: shutdownAPNS } = require("./apns_client");
  await shutdownAPNS();
  process.exit(0);
});

process.on("SIGINT", async () => {
  console.log("SIGINT received, shutting down gracefully");
  matchMonitor.stopMonitoring();
  const { shutdown: shutdownAPNS } = require("./apns_client");
  await shutdownAPNS();
  process.exit(0);
});
