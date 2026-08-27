const express = require("express");
const fs = require("fs");
const path = require("path");
let nodemailer = null;
try { nodemailer = require("nodemailer"); } catch { /* optional */ }

const API_PREFIX = "/api/v1";
const AUDIT_PORT = Number(process.env.AUDIT_PORT || 3015);
const AUDIT_TIME_ZONE = process.env.AUDIT_TIME_ZONE || "Europe/London";
const AUDIT_UNBOUNDED_START_DATE = process.env.AUDIT_UNBOUNDED_START_DATE || "1900-01-01";
const AUDIT_LOOKBACK_DAYS = Number.isFinite(Number(process.env.AUDIT_LOOKBACK_DAYS))
  ? Math.max(0, Math.floor(Number(process.env.AUDIT_LOOKBACK_DAYS)))
  : 0;
const AUDIT_INTERVAL_LOOKBACK_DAYS = Number.isFinite(Number(process.env.AUDIT_INTERVAL_LOOKBACK_DAYS))
  ? Math.max(0, Math.floor(Number(process.env.AUDIT_INTERVAL_LOOKBACK_DAYS)))
  : AUDIT_LOOKBACK_DAYS === 0
    ? 0
    : AUDIT_LOOKBACK_DAYS;
const AUDIT_SCHEDULE_HOUR = Number.isFinite(Number(process.env.AUDIT_SCHEDULE_HOUR))
  ? Math.max(0, Math.min(23, Math.floor(Number(process.env.AUDIT_SCHEDULE_HOUR))))
  : 0;
const AUDIT_SCHEDULE_MINUTE = Number.isFinite(Number(process.env.AUDIT_SCHEDULE_MINUTE))
  ? Math.max(0, Math.min(59, Math.floor(Number(process.env.AUDIT_SCHEDULE_MINUTE))))
  : 0;
const AUDIT_SCHEDULE_INTERVAL_MS = 24 * 60 * 60 * 1000;
const AUDIT_STALE_AFTER_MS = Number.isFinite(Number(process.env.AUDIT_STALE_AFTER_MS))
  ? Math.max(60 * 1000, Math.floor(Number(process.env.AUDIT_STALE_AFTER_MS)))
  : AUDIT_SCHEDULE_INTERVAL_MS + 6 * 60 * 60 * 1000;
const AUDIT_MATCH_MAX_DURATION_MS = Number.isFinite(Number(process.env.AUDIT_MATCH_MAX_DURATION_MS))
  ? Math.max(60 * 60 * 1000, Math.floor(Number(process.env.AUDIT_MATCH_MAX_DURATION_MS)))
  : 3 * 60 * 60 * 1000;
const AUDIT_HTTP_TIMEOUT_MS = Number.isFinite(Number(process.env.AUDIT_HTTP_TIMEOUT_MS))
  ? Math.max(5 * 1000, Math.floor(Number(process.env.AUDIT_HTTP_TIMEOUT_MS)))
  : 30 * 1000;
const AUDIT_MATCH_PAGE_SIZE = Number.isFinite(Number(process.env.AUDIT_MATCH_PAGE_SIZE))
  ? Math.max(100, Math.min(5000, Math.floor(Number(process.env.AUDIT_MATCH_PAGE_SIZE))))
  : 2000;
const AUDIT_MATCH_DETAIL_CONCURRENCY = Number.isFinite(Number(process.env.AUDIT_MATCH_DETAIL_CONCURRENCY))
  ? Math.max(1, Math.min(50, Math.floor(Number(process.env.AUDIT_MATCH_DETAIL_CONCURRENCY))))
  : 3;
const AUDIT_MATCH_DETAIL_MIN_INTERVAL_MS = Number.isFinite(Number(process.env.AUDIT_MATCH_DETAIL_MIN_INTERVAL_MS))
  ? Math.max(0, Math.floor(Number(process.env.AUDIT_MATCH_DETAIL_MIN_INTERVAL_MS)))
  : 250;
const AUDIT_DETAIL_MAX_ATTEMPTS = Number.isFinite(Number(process.env.AUDIT_DETAIL_MAX_ATTEMPTS))
  ? Math.max(1, Math.min(10, Math.floor(Number(process.env.AUDIT_DETAIL_MAX_ATTEMPTS))))
  : 3;
const AUDIT_DETAIL_RETRY_BASE_DELAY_MS = Number.isFinite(Number(process.env.AUDIT_DETAIL_RETRY_BASE_DELAY_MS))
  ? Math.max(100, Math.floor(Number(process.env.AUDIT_DETAIL_RETRY_BASE_DELAY_MS)))
  : 500;
const AUDIT_DETAIL_RETRY_MAX_DELAY_MS = Number.isFinite(Number(process.env.AUDIT_DETAIL_RETRY_MAX_DELAY_MS))
  ? Math.max(500, Math.floor(Number(process.env.AUDIT_DETAIL_RETRY_MAX_DELAY_MS)))
  : 5000;
const AUDIT_DETAIL_RETRY_BACKOFF_FACTOR = Number.isFinite(Number(process.env.AUDIT_DETAIL_RETRY_BACKOFF_FACTOR))
  ? Math.max(1, Math.min(10, Number(process.env.AUDIT_DETAIL_RETRY_BACKOFF_FACTOR)))
  : 2.0;
const AUDIT_AUTO_REPAIR_ENABLED = !["0", "false", "no", "off"].includes(
  String(process.env.AUDIT_AUTO_REPAIR_ENABLED || "true").trim().toLowerCase()
);
const AUDIT_AUTO_REPAIR_COOLDOWN_MS = Number.isFinite(Number(process.env.AUDIT_AUTO_REPAIR_COOLDOWN_MS))
  ? Math.max(60 * 1000, Math.floor(Number(process.env.AUDIT_AUTO_REPAIR_COOLDOWN_MS)))
  : 15 * 60 * 1000;
const AUDIT_AUTO_REPAIR_MAX_MATCHES_PER_RUN = Number.isFinite(Number(process.env.AUDIT_AUTO_REPAIR_MAX_MATCHES_PER_RUN))
  ? Math.max(1, Math.min(100, Math.floor(Number(process.env.AUDIT_AUTO_REPAIR_MAX_MATCHES_PER_RUN))))
  : 10;
const AUDIT_MAIN_API_BASE_URL = (
  process.env.AUDIT_MAIN_API_BASE_URL ||
  process.env.MAIN_API_BASE_URL ||
  process.env.API_BASE_URL ||
  `http://localhost:${process.env.PORT || 3011}`
).replace(/\/+$/, "");
const AUDIT_MAIN_API_PREFIX = (
  process.env.AUDIT_MAIN_API_PREFIX ||
  API_PREFIX
).replace(/\/+$/, "");
const AUDIT_MAIN_API_ROOT = `${AUDIT_MAIN_API_BASE_URL}${AUDIT_MAIN_API_PREFIX}`;

const AUDIT_DELETION_ENABLED = !["0", "false", "no", "off"].includes(
  String(process.env.AUDIT_DELETION_ENABLED || "true").trim().toLowerCase()
);
const AUDIT_DELETION_ISSUES_THRESHOLD = Number.isFinite(Number(process.env.AUDIT_DELETION_ISSUES_THRESHOLD))
  ? Math.max(1, Math.floor(Number(process.env.AUDIT_DELETION_ISSUES_THRESHOLD)))
  : 50;

// const AUDIT_EMAIL_ENABLED = !["0", "false", "no", "off"].includes(
//   String(process.env.AUDIT_EMAIL_ENABLED || "true").trim().toLowerCase()
// );
const AUDIT_EMAIL_ENABLED = false; // temporarily disable email for now since we don't have a means of sending right now
const AUDIT_EMAIL_TO = (process.env.AUDIT_EMAIL_TO || "mike.wagstaff@gmail.com").trim();
const AUDIT_EMAIL_FROM = (process.env.AUDIT_EMAIL_FROM || process.env.AUDIT_EMAIL_SMTP_USER || "").trim();
const AUDIT_EMAIL_SMTP_HOST = (process.env.AUDIT_EMAIL_SMTP_HOST || "").trim();
const AUDIT_EMAIL_SMTP_PORT = Number.isFinite(Number(process.env.AUDIT_EMAIL_SMTP_PORT))
  ? Math.floor(Number(process.env.AUDIT_EMAIL_SMTP_PORT))
  : 587;
const AUDIT_EMAIL_SMTP_USER = (process.env.AUDIT_EMAIL_SMTP_USER || "").trim();
const AUDIT_EMAIL_SMTP_PASS = (process.env.AUDIT_EMAIL_SMTP_PASS || "").trim();
const AUDIT_EMAIL_SMTP_SECURE = ["1", "true", "yes", "on"].includes(
  String(process.env.AUDIT_EMAIL_SMTP_SECURE || "false").trim().toLowerCase()
);

const FINAL_STATUS_TOKENS = new Set([
  "FT",
  "AET",
  "PENS",
  "PEN",
  "PEN.",
  "POSTPONED",
  "MATCH POSTPONED",
  "CANCELLED",
  "ABANDONED",
  "AWARDED",
]);

const NON_SCORE_TERMINAL_STATUSES = new Set([
  "POSTPONED",
  "MATCH POSTPONED",
  "CANCELLED",
  "ABANDONED",
]);

const AUTO_REPAIR_ISSUE_CODES = new Set([
  "missing_score_status_after_kickoff",
  "missing_scores_after_kickoff",
  "match_not_finished_after_max_window",
  "missing_match_details_payload",
  "incomplete_match_details_metadata",
  "missing_match_details_status",
  "match_details_status_mismatch",
  "match_details_score_mismatch",
]);

let runtimeServer = null;
let runtimeScheduleHandle = null;
let runtimeShutdownPromise = null;
const autoRepairLastTriggeredAtByMatchId = new Map();
let nextDetailFetchNotBeforeMs = 0;

function buildEmptyCurrentRun() {
  return {
    trigger: null,
    status: "idle",
    stage: "idle",
    started_at: null,
    completed_at: null,
    last_progress_at: null,
    window_start: null,
    window_end: null,
    total_matches: 0,
    matches_audited: 0,
    matches_remaining: 0,
    progress_ratio: 0,
    detail_candidates: 0,
    detail_checks_completed: 0,
    issues_found: 0,
    matches_per_second: 0,
    auto_repair_candidates: 0,
    auto_repair_attempted: 0,
    auto_repair_succeeded: 0,
    auto_repair_failed: 0,
  };
}

const auditState = {
  running: false,
  last_run_started_at: null,
  last_run_completed_at: null,
  last_success_at: null,
  next_run_scheduled_at: null,
  last_error: null,
  last_duration_ms: null,
  total_runs: 0,
  total_run_failures: 0,
  total_matches_audited: 0,
  total_rescrapes_requested: 0,
  total_rescrapes_succeeded: 0,
  total_rescrapes_failed: 0,
  total_auto_rescrapes_requested: 0,
  total_auto_rescrapes_succeeded: 0,
  total_auto_rescrapes_failed: 0,
  current_run: buildEmptyCurrentRun(),
  current_report: buildEmptyAuditReport(),
};

function buildEmptyAuditReport() {
  return {
    generated_at: null,
    trigger: "startup",
    config: buildPublicConfig(),
    window: {
      start: null,
      end: null,
      lookback_days: AUDIT_LOOKBACK_DAYS,
      time_zone: AUDIT_TIME_ZONE,
    },
    summary: {
      matches_checked: 0,
      started_matches: 0,
      finished_expected_matches: 0,
      detail_candidates: 0,
      detail_checks_attempted: 0,
      detail_checks_succeeded: 0,
      matches_with_issues: 0,
      issues_total: 0,
      healthy_matches: 0,
      auto_repair_candidates: 0,
      auto_repair_attempted: 0,
      auto_repair_succeeded: 0,
      auto_repair_failed: 0,
      issue_counts_by_code: {},
      issue_counts_by_severity: {},
      status_counts: {},
    },
    matches: [],
    issues: [],
  };
}

function buildPublicConfig() {
  return {
    port: AUDIT_PORT,
    schedule_hour: AUDIT_SCHEDULE_HOUR,
    schedule_minute: AUDIT_SCHEDULE_MINUTE,
    schedule_interval_ms: AUDIT_SCHEDULE_INTERVAL_MS,
    stale_after_ms: AUDIT_STALE_AFTER_MS,
    lookback_days: AUDIT_LOOKBACK_DAYS,
    interval_lookback_days: AUDIT_INTERVAL_LOOKBACK_DAYS,
    unbounded_start_date: AUDIT_UNBOUNDED_START_DATE,
    match_max_duration_ms: AUDIT_MATCH_MAX_DURATION_MS,
    match_detail_concurrency: AUDIT_MATCH_DETAIL_CONCURRENCY,
    match_detail_min_interval_ms: AUDIT_MATCH_DETAIL_MIN_INTERVAL_MS,
    auto_repair_enabled: AUDIT_AUTO_REPAIR_ENABLED,
    auto_repair_cooldown_ms: AUDIT_AUTO_REPAIR_COOLDOWN_MS,
    auto_repair_max_matches_per_run: AUDIT_AUTO_REPAIR_MAX_MATCHES_PER_RUN,
    time_zone: AUDIT_TIME_ZONE,
    upstream_api_root: AUDIT_MAIN_API_ROOT,
  };
}

function timeStringFromHourMinute(hour = 0, minute = 0) {
  const normalizedHour = Math.max(0, Math.min(23, Math.floor(Number(hour) || 0)));
  const normalizedMinute = Math.max(0, Math.min(59, Math.floor(Number(minute) || 0)));
  return `${String(normalizedHour).padStart(2, "0")}:${String(normalizedMinute).padStart(2, "0")}`;
}

function computeNextScheduledRunAt(nowMs = Date.now()) {
  const now = new Date(nowMs);
  const scheduledTime = timeStringFromHourMinute(AUDIT_SCHEDULE_HOUR, AUDIT_SCHEDULE_MINUTE);
  const baseDateKey = dateKeyInTimeZone(now, AUDIT_TIME_ZONE);
  for (let offset = 0; offset < 7; offset += 1) {
    const candidateDateKey = addDaysToDateKey(baseDateKey, offset);
    const candidateMs = zonedDateTimeToUtcMs(candidateDateKey, scheduledTime, AUDIT_TIME_ZONE);
    if (Number.isFinite(candidateMs) && candidateMs > nowMs + 1000) {
      return candidateMs;
    }
  }
  return nowMs + AUDIT_SCHEDULE_INTERVAL_MS;
}

function resolveAuditLookbackDays(trigger = "interval") {
  const normalizedTrigger = String(trigger || "interval").trim().toLowerCase();
  if (normalizedTrigger === "manual_api") {
    return AUDIT_LOOKBACK_DAYS;
  }
  return AUDIT_INTERVAL_LOOKBACK_DAYS;
}

function currentRunSnapshot() {
  return auditState.current_run && typeof auditState.current_run === "object"
    ? { ...auditState.current_run }
    : buildEmptyCurrentRun();
}

function updateCurrentRun(patch = {}) {
  const current = auditState.current_run && typeof auditState.current_run === "object"
    ? auditState.current_run
    : buildEmptyCurrentRun();
  const next = {
    ...current,
    ...patch,
  };
  const totalMatches = Number.isFinite(Number(next.total_matches)) ? Math.max(0, Number(next.total_matches)) : 0;
  const matchesAudited = Number.isFinite(Number(next.matches_audited))
    ? Math.max(0, Math.min(totalMatches || Number(next.matches_audited), Number(next.matches_audited)))
    : 0;
  const startedAtMs = Date.parse(next.started_at || "");
  const elapsedSeconds = Number.isFinite(startedAtMs)
    ? Math.max(0, (Date.now() - startedAtMs) / 1000)
    : 0;
  next.total_matches = totalMatches;
  next.matches_audited = matchesAudited;
  next.matches_remaining = Math.max(0, totalMatches - matchesAudited);
  next.progress_ratio = totalMatches > 0 ? Math.max(0, Math.min(1, matchesAudited / totalMatches)) : 0;
  next.matches_per_second = elapsedSeconds > 0 ? matchesAudited / elapsedSeconds : 0;
  next.last_progress_at = patch.last_progress_at || new Date().toISOString();
  auditState.current_run = next;
  return next;
}

function setNoStoreHeaders(res) {
  res.set("Cache-Control", "no-store, max-age=0");
  res.set("Pragma", "no-cache");
}

function normalizeMatchId(value) {
  const normalized = String(value || "").trim();
  if (!/^[a-z0-9]+$/i.test(normalized)) return null;
  return normalized.toLowerCase();
}

function normalizeText(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function normalizeFixtureIdentityToken(value) {
  return normalizeText(value)
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, "");
}

function loadTeamAliases() {
  try {
    const raw = fs.readFileSync(path.join(__dirname, "team_aliases.json"), "utf8");
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed.aliases === "object" ? parsed.aliases : {};
  } catch {
    return {};
  }
}

const TEAM_ALIASES = loadTeamAliases();

function resolveTeamAlias(name) {
  const normalized = normalizeText(name);
  return TEAM_ALIASES[normalized] || normalized;
}

function toAuditMatchRecord(match) {
  if (!match || typeof match !== "object") return null;
  const record = {
    ...match,
    match_details_id:
      match.match_details_id ||
      match.match_id ||
      match.id ||
      null,
    details_url: match.details_url || null,
    date: match.date ? String(match.date) : null,
    time: match.time ? String(match.time) : null,
    league: match.league ? String(match.league) : null,
    home_team: match.home_team ? String(match.home_team) : null,
    away_team: match.away_team ? String(match.away_team) : null,
  };
  return record;
}

function normalizeStatusToken(value) {
  const normalized = normalizeText(value).toUpperCase();
  if (!normalized) return "";
  if (normalized === "FULL TIME" || normalized === "FULL-TIME") return "FT";
  if (normalized === "HALF TIME" || normalized === "HALF-TIME") return "HT";
  if (normalized === "AFTER EXTRA TIME") return "AET";
  if (normalized === "PENALTY SHOOTOUT") return "PENS";
  return normalized;
}

function isInProgressStatus(value) {
  const normalized = normalizeStatusToken(value);
  if (!normalized) return false;
  if (FINAL_STATUS_TOKENS.has(normalized)) return false;
  if (normalized === "HT") return true;
  if (/^(?:ET\s+)?\d{1,3}(?:\+\d{1,2})?'?$/i.test(normalized)) return true;
  return normalized === "LIVE" || normalized === "ET";
}

function isFinalStatus(value) {
  return FINAL_STATUS_TOKENS.has(normalizeStatusToken(value));
}

function isNonScoreTerminalStatus(value) {
  return NON_SCORE_TERMINAL_STATUSES.has(normalizeStatusToken(value));
}

function parseNumericScore(value) {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return null;
  return parsed;
}

function buildSyntheticAuditMatchId(match) {
  return [
    normalizeText(match.date).toLowerCase(),
    normalizeText(match.time).toLowerCase(),
    normalizeText(match.league).toLowerCase(),
    normalizeText(match.home_team).toLowerCase(),
    normalizeText(match.away_team).toLowerCase(),
  ]
    .filter(Boolean)
    .join("|");
}

function getDatePartsInTimeZone(date, timeZone = AUDIT_TIME_ZONE) {
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  });
  const parts = formatter.formatToParts(date);
  const lookup = {};
  parts.forEach((part) => {
    if (part.type !== "literal") {
      lookup[part.type] = part.value;
    }
  });
  return lookup;
}

function dateKeyInTimeZone(date, timeZone = AUDIT_TIME_ZONE) {
  const parts = getDatePartsInTimeZone(date, timeZone);
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function addDaysToDateKey(dateKey, days = 0) {
  const match = String(dateKey || "").match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) return null;
  const shiftedDate = new Date(
    Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]) + days, 12, 0, 0)
  );
  return shiftedDate.toISOString().slice(0, 10);
}

function buildDateRangeWindow(nowMs = Date.now(), lookbackDays = AUDIT_LOOKBACK_DAYS) {
  const endDate = new Date(nowMs);
  if (!Number.isFinite(lookbackDays) || lookbackDays <= 0) {
    const end = dateKeyInTimeZone(endDate, AUDIT_TIME_ZONE);
    return {
      start: AUDIT_UNBOUNDED_START_DATE,
      end,
      dates: [],
      current_day: end,
      unbounded: true,
    };
  }
  const dates = [];
  for (let offset = lookbackDays; offset >= 0; offset -= 1) {
    dates.push(dateKeyInTimeZone(new Date(nowMs - offset * 24 * 60 * 60 * 1000), AUDIT_TIME_ZONE));
  }
  return {
    start: dates[0],
    end: dates[dates.length - 1],
    dates,
    current_day: dateKeyInTimeZone(endDate, AUDIT_TIME_ZONE),
    unbounded: false,
  };
}

function zonedDateTimeToUtcMs(dateString, timeString, timeZone = AUDIT_TIME_ZONE) {
  const dateMatch = String(dateString || "").match(/^(\d{4})-(\d{2})-(\d{2})$/);
  const timeMatch = String(timeString || "").match(/^(\d{2}):(\d{2})$/);
  if (!dateMatch || !timeMatch) return null;

  const targetYear = Number(dateMatch[1]);
  const targetMonth = Number(dateMatch[2]);
  const targetDay = Number(dateMatch[3]);
  const targetHour = Number(timeMatch[1]);
  const targetMinute = Number(timeMatch[2]);

  let guessMs = Date.UTC(targetYear, targetMonth - 1, targetDay, targetHour, targetMinute, 0);
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const parts = getDatePartsInTimeZone(new Date(guessMs), timeZone);
    const observedMs = Date.UTC(
      Number(parts.year),
      Number(parts.month) - 1,
      Number(parts.day),
      Number(parts.hour),
      Number(parts.minute),
      Number(parts.second || "0")
    );
    const desiredMs = Date.UTC(targetYear, targetMonth - 1, targetDay, targetHour, targetMinute, 0);
    const diffMs = desiredMs - observedMs;
    if (diffMs === 0) {
      return guessMs;
    }
    guessMs += diffMs;
  }

  return guessMs;
}

function kickoffTimestampMs(match) {
  if (!match || typeof match !== "object") return null;
  return zonedDateTimeToUtcMs(match.date, match.time, AUDIT_TIME_ZONE);
}

function hasScores(match) {
  return parseNumericScore(match && match.home_score) !== null &&
    parseNumericScore(match && match.away_score) !== null;
}

function issueSeverityScore(severity) {
  if (severity === "critical") return 3;
  if (severity === "warning") return 2;
  return 1;
}

function createIssue(match, code, severity, message, details = null) {
  const matchId = normalizeMatchId(match && match.match_details_id) || null;
  const auditMatchId = matchId || buildSyntheticAuditMatchId(match);
  return {
    key: `${auditMatchId}:${code}`,
    code,
    severity,
    message,
    match_id: matchId,
    audit_match_id: auditMatchId,
    date: match && match.date ? String(match.date) : null,
    time: match && match.time ? String(match.time) : null,
    league: match && match.league ? String(match.league) : null,
    home_team: match && match.home_team ? String(match.home_team) : null,
    away_team: match && match.away_team ? String(match.away_team) : null,
    score_status: match && match.score_status ? String(match.score_status) : null,
    home_score: parseNumericScore(match && match.home_score),
    away_score: parseNumericScore(match && match.away_score),
    details,
  };
}

function buildFutureFixturePresenceLookup(matches = []) {
  const byMatchId = new Set();
  const byLooseKey = new Set();

  (Array.isArray(matches) ? matches : []).forEach((rawMatch) => {
    const match = toAuditMatchRecord(rawMatch);
    if (!match) return;
    const matchId = normalizeMatchId(match.match_details_id);
    if (matchId) {
      byMatchId.add(matchId);
    }
    const looseKey = [
      match.date || "",
      normalizeFixtureIdentityToken(match.league || ""),
      normalizeFixtureIdentityToken(resolveTeamAlias(match.home_team || "")),
      normalizeFixtureIdentityToken(resolveTeamAlias(match.away_team || "")),
    ].join("|");
    if (looseKey !== "|||") {
      byLooseKey.add(looseKey);
    }
  });

  return { byMatchId, byLooseKey };
}

function buildFutureRedisFixtureAuditResults(redisMatches = [], bbcMatches = [], options = {}) {
  const nowMs = Number.isFinite(options.nowMs) ? Number(options.nowMs) : Date.now();
  const coverageEnd = normalizeText(options.coverageEnd);
  const lookup = buildFutureFixturePresenceLookup(bbcMatches);

  return (Array.isArray(redisMatches) ? redisMatches : []).flatMap((rawMatch) => {
    const match = toAuditMatchRecord(rawMatch);
    if (!match || !match.date || !match.home_team || !match.away_team) return [];
    if (coverageEnd && match.date > coverageEnd) return [];

    const kickoffMs = kickoffTimestampMs(match);
    if (!Number.isFinite(kickoffMs) || kickoffMs <= nowMs) return [];

    const matchId = normalizeMatchId(match.match_details_id);
    if (matchId && lookup.byMatchId.has(matchId)) return [];

    const looseKey = [
      match.date,
      normalizeFixtureIdentityToken(match.league || ""),
      normalizeFixtureIdentityToken(resolveTeamAlias(match.home_team || "")),
      normalizeFixtureIdentityToken(resolveTeamAlias(match.away_team || "")),
    ].join("|");
    if (lookup.byLooseKey.has(looseKey)) return [];

    return [
      {
        summary: summarizeMatch(match),
        kickoff_ts_ms: kickoffMs,
        should_have_kicked_off: false,
        should_be_finished: false,
        should_have_detail_payload: false,
        issues: [
          createIssue(
            match,
            "future_fixture_missing_from_bbc_listing",
            "warning",
            "Future fixture exists in Redis but could not be found in the BBC Scores & Fixtures listing for that date.",
            {
              coverage_end: coverageEnd || null,
              source: "redis_future_vs_bbc_range",
              has_bbc_source: rawMatch && rawMatch.has_bbc_source === true,
            }
          ),
        ],
      },
    ];
  });
}

function mergeAuditResults(primaryResults = [], additionalResults = []) {
  const merged = Array.isArray(primaryResults) ? primaryResults.map((result) => ({
    ...result,
    issues: Array.isArray(result && result.issues) ? result.issues.slice() : [],
  })) : [];
  const byAuditMatchId = new Map();

  merged.forEach((result, index) => {
    const key = result && result.summary ? result.summary.audit_match_id : null;
    if (key) {
      byAuditMatchId.set(key, index);
    }
  });

  (Array.isArray(additionalResults) ? additionalResults : []).forEach((result) => {
    const key = result && result.summary ? result.summary.audit_match_id : null;
    if (!key || !byAuditMatchId.has(key)) {
      merged.push({
        ...result,
        issues: Array.isArray(result && result.issues) ? result.issues.slice() : [],
      });
      if (key) {
        byAuditMatchId.set(key, merged.length - 1);
      }
      return;
    }

    const target = merged[byAuditMatchId.get(key)];
    const existingIssueKeys = new Set(
      (Array.isArray(target.issues) ? target.issues : []).map((issue) => String(issue && issue.key ? issue.key : ""))
    );
    (Array.isArray(result && result.issues) ? result.issues : []).forEach((issue) => {
      const issueKey = String(issue && issue.key ? issue.key : "");
      if (issueKey && existingIssueKeys.has(issueKey)) return;
      target.issues.push(issue);
      if (issueKey) {
        existingIssueKeys.add(issueKey);
      }
    });
  });

  return merged;
}

function summarizeMatch(match) {
  return {
    match_id: normalizeMatchId(match && match.match_details_id) || null,
    audit_match_id:
      normalizeMatchId(match && match.match_details_id) || buildSyntheticAuditMatchId(match),
    date: String(match && match.date ? match.date : "").trim() || null,
    time: String(match && match.time ? match.time : "").trim() || null,
    league: String(match && match.league ? match.league : "").trim() || null,
    home_team: String(match && match.home_team ? match.home_team : "").trim() || null,
    away_team: String(match && match.away_team ? match.away_team : "").trim() || null,
    score_status: String(match && match.score_status ? match.score_status : "").trim() || null,
    home_score: parseNumericScore(match && match.home_score),
    away_score: parseNumericScore(match && match.away_score),
  };
}

function evaluateAuditIssues(match, options = {}) {
  const nowMs = Number.isFinite(options.nowMs) ? Number(options.nowMs) : Date.now();
  const matchDurationMs = Number.isFinite(options.matchDurationMs)
    ? Number(options.matchDurationMs)
    : AUDIT_MATCH_MAX_DURATION_MS;
  const detailPayload = options.detailPayload && typeof options.detailPayload === "object"
    ? options.detailPayload
    : null;
  const detailMissing = options.detailMissing === true;
  const issues = [];

  const kickoffMs = kickoffTimestampMs(match);
  const status = String(match && match.score_status ? match.score_status : "").trim();
  const normalizedStatus = normalizeStatusToken(status);
  const kickoffKnown = Number.isFinite(kickoffMs);
  const shouldHaveKickedOff = kickoffKnown && nowMs >= kickoffMs;
  const shouldBeFinished = kickoffKnown && nowMs >= kickoffMs + matchDurationMs;
  const matchId = normalizeMatchId(match && match.match_details_id);
  const shouldHaveDetailPayload = shouldHaveKickedOff && !isNonScoreTerminalStatus(normalizedStatus);

  if (shouldHaveKickedOff && !normalizedStatus) {
    issues.push(
      createIssue(
        match,
        "missing_score_status_after_kickoff",
        "critical",
        "Match should have kicked off but has no score_status label.",
        { kickoff_ts_ms: kickoffMs }
      )
    );
  }

  if (shouldHaveKickedOff && !isNonScoreTerminalStatus(normalizedStatus) && !hasScores(match)) {
    issues.push(
      createIssue(
        match,
        "missing_scores_after_kickoff",
        "critical",
        "Match should have kicked off but scores are missing.",
        { kickoff_ts_ms: kickoffMs, score_status: status || null }
      )
    );
  }

  if (shouldBeFinished && !isFinalStatus(normalizedStatus)) {
    issues.push(
      createIssue(
        match,
        "match_not_finished_after_max_window",
        "critical",
        "Match is more than 3 hours past kickoff but is not marked finished.",
        { kickoff_ts_ms: kickoffMs, expected_finished_after_ms: kickoffMs + matchDurationMs }
      )
    );
  }

  if (shouldHaveDetailPayload && !matchId) {
    issues.push(
      createIssue(
        match,
        "missing_match_details_id",
        "critical",
        "Match should have match_details data but no match_details_id is present.",
        { kickoff_ts_ms: kickoffMs }
      )
    );
  }

  if (shouldHaveDetailPayload && matchId && detailMissing) {
    issues.push(
      createIssue(
        match,
        "missing_match_details_payload",
        "critical",
        "Match has a match_details_id but the match details payload could not be retrieved.",
        { match_id: matchId }
      )
    );
  }

  if (detailPayload && shouldHaveDetailPayload) {
    const detailStatus = String(detailPayload.score_status || "").trim();
    const listHomeScore = parseNumericScore(match.home_score);
    const listAwayScore = parseNumericScore(match.away_score);
    const detailHomeScore = parseNumericScore(detailPayload.home_score);
    const detailAwayScore = parseNumericScore(detailPayload.away_score);

    if (!String(detailPayload.date || "").trim() ||
        !String(detailPayload.time || "").trim() ||
        !String(detailPayload.league || "").trim() ||
        !String(detailPayload.home_team || "").trim() ||
        !String(detailPayload.away_team || "").trim()) {
      issues.push(
        createIssue(
          match,
          "incomplete_match_details_metadata",
          "warning",
          "Match details payload exists but core metadata is incomplete.",
          {
            detail_date: detailPayload.date || null,
            detail_time: detailPayload.time || null,
            detail_league: detailPayload.league || null,
          }
        )
      );
    }

    if (!detailStatus) {
      issues.push(
        createIssue(
          match,
          "missing_match_details_status",
          "warning",
          "Match details payload exists but score_status is missing.",
          { match_id: matchId }
        )
      );
    } else if (normalizedStatus && normalizeStatusToken(detailStatus) !== normalizedStatus) {
      // PENS and AET are treated as equivalent: the list payload normalises penalty
      // shootout results to AET during merging, so the details page (which retains PENS)
      // will always disagree. This is expected and not a data problem.
      const PENS_AET_TOKENS = new Set(["PENS", "PEN", "PEN.", "AET"]);
      const listIsPensOrAet = PENS_AET_TOKENS.has(normalizedStatus);
      const detailIsPensOrAet = PENS_AET_TOKENS.has(normalizeStatusToken(detailStatus));
      // Both in-progress (e.g. "7'" vs "12'"): clock drift between list scrape and detail fetch.
      const bothInProgress = isInProgressStatus(normalizedStatus) && isInProgressStatus(normalizeStatusToken(detailStatus));
      if (!(listIsPensOrAet && detailIsPensOrAet) && !bothInProgress) {
        issues.push(
          createIssue(
            match,
            "match_details_status_mismatch",
            "warning",
            "List payload and match details payload disagree on score_status.",
            { list_status: status, detail_status: detailStatus }
          )
        );
      }
    }

    if (
      listHomeScore !== null &&
      listAwayScore !== null &&
      detailHomeScore !== null &&
      detailAwayScore !== null &&
      (listHomeScore !== detailHomeScore || listAwayScore !== detailAwayScore)
    ) {
      issues.push(
        createIssue(
          match,
          "match_details_score_mismatch",
          "warning",
          "List payload and match details payload disagree on the scoreline.",
          {
            list_score: `${listHomeScore}-${listAwayScore}`,
            detail_score: `${detailHomeScore}-${detailAwayScore}`,
          }
        )
      );
    }
  }

  return {
    summary: summarizeMatch(match),
    kickoff_ts_ms: kickoffKnown ? kickoffMs : null,
    should_have_kicked_off: shouldHaveKickedOff,
    should_be_finished: shouldBeFinished,
    should_have_detail_payload: shouldHaveDetailPayload,
    issues,
  };
}

function groupIssuesByMatch(results) {
  const grouped = new Map();
  (Array.isArray(results) ? results : []).forEach((result) => {
    const summary = result && result.summary ? result.summary : summarizeMatch(result);
    const key = summary.audit_match_id;
    if (!key) return;
    const existing = grouped.get(key) || {
      ...summary,
      kickoff_ts_ms: result && Number.isFinite(result.kickoff_ts_ms) ? result.kickoff_ts_ms : null,
      should_have_kicked_off: Boolean(result && result.should_have_kicked_off),
      should_be_finished: Boolean(result && result.should_be_finished),
      should_have_detail_payload: Boolean(result && result.should_have_detail_payload),
      issues: [],
      highest_severity: "info",
    };
    const issues = Array.isArray(result && result.issues) ? result.issues : [];
    issues.forEach((issue) => {
      existing.issues.push(issue);
      if (issueSeverityScore(issue.severity) > issueSeverityScore(existing.highest_severity)) {
        existing.highest_severity = issue.severity;
      }
    });
    grouped.set(key, existing);
  });
  return Array.from(grouped.values()).sort((left, right) => {
    const severityDiff = issueSeverityScore(right.highest_severity) - issueSeverityScore(left.highest_severity);
    if (severityDiff !== 0) return severityDiff;
    return Number(right.kickoff_ts_ms || 0) - Number(left.kickoff_ts_ms || 0);
  });
}

function summarizeAuditReport(results, issues) {
  const summary = {
    matches_checked: Array.isArray(results) ? results.length : 0,
    started_matches: 0,
    finished_expected_matches: 0,
    detail_candidates: 0,
    detail_checks_attempted: 0,
    detail_checks_succeeded: 0,
    matches_with_issues: 0,
    issues_total: Array.isArray(issues) ? issues.length : 0,
    healthy_matches: 0,
    issue_counts_by_code: {},
    issue_counts_by_severity: {},
    status_counts: {},
  };

  (Array.isArray(results) ? results : []).forEach((result) => {
    if (result.should_have_kicked_off) summary.started_matches += 1;
    if (result.should_be_finished) summary.finished_expected_matches += 1;
    if (result.should_have_detail_payload) summary.detail_candidates += 1;
    if (result.should_have_detail_payload && result.summary && result.summary.match_id) {
      summary.detail_checks_attempted += 1;
    }
    if (
      result.should_have_detail_payload &&
      result.summary &&
      result.summary.match_id &&
      !result.issues.some((issue) => issue.code === "missing_match_details_payload")
    ) {
      summary.detail_checks_succeeded += 1;
    }
    const statusKey = normalizeStatusToken(result.summary && result.summary.score_status) || "UNKNOWN";
    summary.status_counts[statusKey] = (summary.status_counts[statusKey] || 0) + 1;
  });

  const issueMatches = new Set();
  (Array.isArray(issues) ? issues : []).forEach((issue) => {
    summary.issue_counts_by_code[issue.code] = (summary.issue_counts_by_code[issue.code] || 0) + 1;
    summary.issue_counts_by_severity[issue.severity] = (summary.issue_counts_by_severity[issue.severity] || 0) + 1;
    issueMatches.add(issue.audit_match_id);
  });
  summary.matches_with_issues = issueMatches.size;
  summary.healthy_matches = Math.max(0, summary.matches_checked - summary.matches_with_issues);

  return summary;
}

async function mapWithConcurrency(items, concurrency, worker) {
  if (!Array.isArray(items) || items.length === 0) return [];
  const limit = Math.max(1, Number(concurrency) || 1);
  const results = new Array(items.length);
  let cursor = 0;

  async function runWorker() {
    while (cursor < items.length) {
      const currentIndex = cursor;
      cursor += 1;
      // eslint-disable-next-line no-await-in-loop
      results[currentIndex] = await worker(items[currentIndex], currentIndex);
    }
  }

  const workers = [];
  for (let i = 0; i < Math.min(limit, items.length); i += 1) {
    workers.push(runWorker());
  }
  await Promise.all(workers);
  return results;
}

async function throttleMatchDetailFetch() {
  if (AUDIT_MATCH_DETAIL_MIN_INTERVAL_MS <= 0) return;
  const nowMs = Date.now();
  const waitMs = Math.max(0, nextDetailFetchNotBeforeMs - nowMs);
  nextDetailFetchNotBeforeMs = Math.max(nextDetailFetchNotBeforeMs, nowMs) + AUDIT_MATCH_DETAIL_MIN_INTERVAL_MS;
  if (waitMs > 0) {
    await new Promise((resolve) => setTimeout(resolve, waitMs));
  }
}

async function fetchJson(url, options = {}) {
  const controller = new AbortController();
  const timeoutMs = Number.isFinite(options.timeoutMs)
    ? Number(options.timeoutMs)
    : AUDIT_HTTP_TIMEOUT_MS;
  const timeoutHandle = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      method: options.method || "GET",
      headers: {
        Accept: "application/json",
        ...(options.headers || {}),
      },
      body: options.body,
      signal: controller.signal,
      redirect: "follow",
      cache: "no-store",
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      const message = payload && (payload.error || payload.message)
        ? payload.error || payload.message
        : `Request failed (${response.status})`;
      const error = new Error(message);
      error.status = response.status;
      error.payload = payload;
      throw error;
    }
    return payload;
  } finally {
    clearTimeout(timeoutHandle);
  }
}

async function fetchMatchesWindow(window) {
  const matches = [];
  let page = 1;
  let hasMore = true;

  while (hasMore) {
    const query = new URLSearchParams({
      start: window.start,
      end: window.end,
      page: String(page),
      page_size: String(AUDIT_MATCH_PAGE_SIZE),
      include_meta: "1",
    });
    // Use fixtures mode so the range includes today and recent past consistently.
    const payload = await fetchJson(`${AUDIT_MAIN_API_ROOT}/matches?${query.toString()}`);
    const pageMatches = Array.isArray(payload.matches) ? payload.matches : [];
    matches.push(...pageMatches);
    hasMore = payload.pagination ? payload.pagination.has_more === true : false;
    page += 1;
    if (page > 100) {
      throw new Error("Audit pagination guard exceeded 100 pages.");
    }
  }

  return matches;
}

async function fetchFutureFixtureSources() {
  return fetchJson(`${AUDIT_MAIN_API_ROOT}/admin/audit/future-fixtures`);
}

function sleepMs(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isRetryableDetailError(error) {
  if (!error) return false;
  const name = String(error.name || "");
  if (name === "AbortError") return true;
  const status = Number.isFinite(error.status) ? error.status : null;
  if (status === null) return true; // network error (no HTTP status)
  if (status === 408 || status === 429) return true;
  if (status >= 500 && status <= 599) return true;
  return false;
}

function computeRetryDelayMs(attempt, baseMs, maxMs, factor) {
  const exponential = baseMs * Math.pow(factor, attempt - 1);
  const capped = Math.min(exponential, maxMs);
  // Add ±25% jitter
  const jitter = capped * 0.25 * (Math.random() * 2 - 1);
  return Math.max(0, Math.round(capped + jitter));
}

async function fetchMatchDetailsPayload(matchId) {
  let lastError = null;
  for (let attempt = 1; attempt <= AUDIT_DETAIL_MAX_ATTEMPTS; attempt += 1) {
    try {
      // eslint-disable-next-line no-await-in-loop
      await throttleMatchDetailFetch();
      // eslint-disable-next-line no-await-in-loop
      const payload = await fetchJson(`${AUDIT_MAIN_API_ROOT}/matches/${encodeURIComponent(matchId)}`);
      return { ok: true, payload };
    } catch (error) {
      if (error && error.status === 404) {
        return { ok: false, missing: true, error: error.message || String(error) };
      }
      lastError = error;
      if (!isRetryableDetailError(error) || attempt >= AUDIT_DETAIL_MAX_ATTEMPTS) {
        break;
      }
      const delayMs = computeRetryDelayMs(
        attempt,
        AUDIT_DETAIL_RETRY_BASE_DELAY_MS,
        AUDIT_DETAIL_RETRY_MAX_DELAY_MS,
        AUDIT_DETAIL_RETRY_BACKOFF_FACTOR
      );
      console.warn(
        `[Audit] fetchMatchDetails attempt ${attempt}/${AUDIT_DETAIL_MAX_ATTEMPTS} failed for ${matchId}: ${error && error.message ? error.message : error}. Retrying in ${delayMs}ms.`
      );
      // eslint-disable-next-line no-await-in-loop
      await sleepMs(delayMs);
    }
  }
  return {
    ok: false,
    missing: false,
    error: lastError && lastError.message ? lastError.message : String(lastError),
  };
}

function autoRepairEligibleMatchIds(report, nowMs = Date.now()) {
  if (!AUDIT_AUTO_REPAIR_ENABLED) return [];
  const seen = new Set();
  const eligible = [];
  const issues = Array.isArray(report && report.issues) ? report.issues : [];
  for (const issue of issues) {
    const matchId = normalizeMatchId(issue && issue.match_id);
    if (!matchId) continue;
    if (!AUTO_REPAIR_ISSUE_CODES.has(String(issue && issue.code ? issue.code : ""))) continue;
    if (seen.has(matchId)) continue;
    const lastTriggeredAt = autoRepairLastTriggeredAtByMatchId.get(matchId) || 0;
    if (Number.isFinite(lastTriggeredAt) && nowMs - lastTriggeredAt < AUDIT_AUTO_REPAIR_COOLDOWN_MS) {
      continue;
    }
    seen.add(matchId);
    eligible.push(matchId);
    if (eligible.length >= AUDIT_AUTO_REPAIR_MAX_MATCHES_PER_RUN) {
      break;
    }
  }
  return eligible;
}

async function triggerRescrape(matchId, options = {}) {
  const normalizedMatchId = normalizeMatchId(matchId);
  if (!normalizedMatchId) {
    const error = new Error("Invalid match id. Expected BBC match details id.");
    error.status = 400;
    throw error;
  }

  const mode = String(options.mode || "manual").trim().toLowerCase();
  if (mode === "auto") {
    auditState.total_auto_rescrapes_requested += 1;
  } else {
    auditState.total_rescrapes_requested += 1;
  }

  try {
    const payload = await fetchJson(`${AUDIT_MAIN_API_ROOT}/admin/redis/matches/actions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        action: "rescrape",
        match_ids: [normalizedMatchId],
        request_initiator: "audit_service",
        request_reason: mode === "auto" ? "audit_auto_rescrape" : "audit_manual_rescrape",
        request_trigger: mode === "auto" ? "audit_auto_repair" : "audit_manual_request",
      }),
    });
    if (mode === "auto") {
      auditState.total_auto_rescrapes_succeeded += 1;
    } else {
      auditState.total_rescrapes_succeeded += 1;
    }
    return payload;
  } catch (error) {
    if (mode === "auto") {
      auditState.total_auto_rescrapes_failed += 1;
    } else {
      auditState.total_rescrapes_failed += 1;
    }
    throw error;
  }
}

async function autoRepairReportIssues(report, trigger = "interval") {
  const eligibleMatchIds = autoRepairEligibleMatchIds(report, Date.now());
  if (eligibleMatchIds.length === 0) {
    return {
      enabled: AUDIT_AUTO_REPAIR_ENABLED,
      trigger,
      candidates: 0,
      attempted: 0,
      succeeded: 0,
      failed: 0,
      match_ids: [],
      failures: [],
    };
  }

  updateCurrentRun({
    stage: "auto_repair",
    auto_repair_candidates: eligibleMatchIds.length,
  });

  const failures = [];
  let attempted = 0;
  let succeeded = 0;
  for (const matchId of eligibleMatchIds) {
    attempted += 1;
    autoRepairLastTriggeredAtByMatchId.set(matchId, Date.now());
    try {
      // eslint-disable-next-line no-await-in-loop
      await triggerRescrape(matchId, { mode: "auto" });
      succeeded += 1;
    } catch (error) {
      failures.push({
        match_id: matchId,
        error: error && error.message ? error.message : String(error),
      });
    }
    updateCurrentRun({
      auto_repair_attempted: attempted,
      auto_repair_succeeded: succeeded,
      auto_repair_failed: failures.length,
    });
  }

  return {
    enabled: AUDIT_AUTO_REPAIR_ENABLED,
    trigger,
    candidates: eligibleMatchIds.length,
    attempted,
    succeeded,
    failed: failures.length,
    match_ids: eligibleMatchIds,
    failures,
  };
}

async function markFutureFixturesAsDeleted(issues = []) {
  const candidates = issues.filter(
    (issue) => issue && issue.code === "future_fixture_missing_from_bbc_listing" && issue.match_id
  );
  if (candidates.length === 0) {
    return { enabled: AUDIT_DELETION_ENABLED, skipped: true, reason: "no_candidates", deleted: 0, failed: 0, results: [], errors: [] };
  }

  const matchIdsSeen = new Set();
  const uniqueCandidates = candidates.filter((issue) => {
    if (matchIdsSeen.has(issue.match_id)) return false;
    matchIdsSeen.add(issue.match_id);
    return true;
  });

  const metadataList = uniqueCandidates.map((issue) => ({
    match_id: issue.match_id,
    home_team: issue.home_team || null,
    away_team: issue.away_team || null,
    date: issue.date || null,
    time: issue.time || null,
    league: issue.league || null,
    reason: "audit_future_fixture_missing_from_bbc",
  }));

  try {
    const payload = await fetchJson(`${AUDIT_MAIN_API_ROOT}/admin/audit/matches/mark-deleted`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        match_ids: uniqueCandidates.map((i) => i.match_id),
        metadata: metadataList,
      }),
    });
    return {
      enabled: AUDIT_DELETION_ENABLED,
      skipped: false,
      deleted: payload.deleted || 0,
      failed: payload.failed || 0,
      results: payload.results || [],
      errors: payload.errors || [],
    };
  } catch (error) {
    return {
      enabled: AUDIT_DELETION_ENABLED,
      skipped: false,
      deleted: 0,
      failed: uniqueCandidates.length,
      results: [],
      errors: [{ error: error && error.message ? error.message : String(error) }],
    };
  }
}

function buildAuditEmailSubject(report, deletionResult) {
  const issueCount = report && report.summary ? (report.summary.matches_with_issues || 0) : 0;
  const deletedCount = deletionResult ? (deletionResult.deleted || 0) : 0;
  return `Top Scores match audit - ${issueCount} match${issueCount !== 1 ? "es" : ""} with potential issues, ${deletedCount} match${deletedCount !== 1 ? "es" : ""} deleted`;
}

function buildAuditEmailBody(report, deletionResult) {
  const summary = report && report.summary ? report.summary : {};
  const reconciliation = report && report.reconciliation ? report.reconciliation : {};
  const deletion = deletionResult || {};
  const matches = Array.isArray(report && report.matches) ? report.matches : [];

  const lines = [
    `Match Audit Report`,
    `Generated: ${report && report.generated_at ? report.generated_at : "unknown"}`,
    `Trigger: ${report && report.trigger ? report.trigger : "unknown"}`,
    ``,
    `=== SUMMARY ===`,
    `Matches checked: ${summary.matches_checked || 0}`,
    `Matches with issues: ${summary.matches_with_issues || 0}`,
    `Issues total: ${summary.issues_total || 0}`,
    `Healthy matches: ${summary.healthy_matches || 0}`,
    `Future Redis fixtures checked: ${reconciliation.future_redis_matches_checked || 0}`,
    `Future fixtures missing from BBC: ${reconciliation.future_redis_matches_missing_from_bbc || 0}`,
    ``,
    `=== DELETION ===`,
    `Deletion enabled: ${deletion.enabled !== false ? "yes" : "no"}`,
    deletion.skipped ? `Skipped: ${deletion.reason || "unknown"}` : `Matches deleted: ${deletion.deleted || 0}`,
    deletion.failed > 0 ? `Deletion failures: ${deletion.failed}` : null,
    ``,
  ].filter((line) => line !== null);

  if (deletion.results && deletion.results.length > 0) {
    lines.push(`=== DELETED MATCHES ===`);
    deletion.results.forEach((r) => {
      lines.push(`  - ${r.home_team || "?"} vs ${r.away_team || "?"} | ${r.date || "?"} ${r.time || ""} | ${r.league || "?"} | id: ${r.match_id}`);
    });
    lines.push(``);
  }

  if (matches.length > 0) {
    lines.push(`=== MATCHES WITH ISSUES ===`);
    matches.slice(0, 50).forEach((match) => {
      const issues = Array.isArray(match.issues) ? match.issues : [];
      lines.push(`  ${match.home_team || "?"} vs ${match.away_team || "?"} | ${match.date || "?"} | ${match.league || "?"}`);
      issues.forEach((issue) => {
        lines.push(`    [${issue.severity || "?"}] ${issue.code}: ${issue.message || ""}`);
      });
    });
    if (matches.length > 50) {
      lines.push(`  ... and ${matches.length - 50} more`);
    }
  }

  return lines.join("\n");
}

async function sendAuditSummaryEmail(report, deletionResult) {
  if (!AUDIT_EMAIL_ENABLED) return { sent: false, reason: "disabled" };
  if (!nodemailer) return { sent: false, reason: "nodemailer_not_installed" };
  if (!AUDIT_EMAIL_SMTP_HOST) return { sent: false, reason: "smtp_not_configured" };
  if (!AUDIT_EMAIL_TO) return { sent: false, reason: "no_recipient" };

  try {
    const transporter = nodemailer.createTransport({
      host: AUDIT_EMAIL_SMTP_HOST,
      port: AUDIT_EMAIL_SMTP_PORT,
      secure: AUDIT_EMAIL_SMTP_SECURE,
      auth: AUDIT_EMAIL_SMTP_USER ? { user: AUDIT_EMAIL_SMTP_USER, pass: AUDIT_EMAIL_SMTP_PASS } : undefined,
    });
    const subject = buildAuditEmailSubject(report, deletionResult);
    const text = buildAuditEmailBody(report, deletionResult);
    await transporter.sendMail({
      from: AUDIT_EMAIL_FROM || AUDIT_EMAIL_SMTP_USER,
      to: AUDIT_EMAIL_TO,
      subject,
      text,
    });
    return { sent: true, to: AUDIT_EMAIL_TO, subject };
  } catch (error) {
    console.error("[Audit] Failed to send summary email:", error && error.message ? error.message : error);
    return { sent: false, reason: "send_error", error: error && error.message ? error.message : String(error) };
  }
}

async function buildAuditReport(trigger = "interval") {
  const nowMs = Date.now();
  const effectiveLookbackDays = resolveAuditLookbackDays(trigger);
  const window = buildDateRangeWindow(nowMs, effectiveLookbackDays);
  updateCurrentRun({
    trigger,
    status: "running",
    stage: "fetching_matches",
    started_at: new Date(nowMs).toISOString(),
    completed_at: null,
    window_start: window.start,
    window_end: window.end,
    total_matches: 0,
    matches_audited: 0,
    detail_candidates: 0,
    detail_checks_completed: 0,
    issues_found: 0,
  });
  const [matches, futureFixtureSources] = await Promise.all([
    fetchMatchesWindow(window),
    fetchFutureFixtureSources().catch(() => null),
  ]);

  const detailCandidateIds = new Set(
    matches.flatMap((match) => {
      const kickoffMs = kickoffTimestampMs(match);
      const matchId = normalizeMatchId(match && match.match_details_id);
      return Number.isFinite(kickoffMs) && nowMs >= kickoffMs && matchId ? [matchId] : [];
    })
  );

  updateCurrentRun({
    stage: "auditing_matches",
    total_matches: matches.length,
    detail_candidates: detailCandidateIds.size,
  });

  const results = await mapWithConcurrency(
    matches,
    AUDIT_MATCH_DETAIL_CONCURRENCY,
    async (match) => {
      const matchId = normalizeMatchId(match && match.match_details_id);
      const needsDetailPayload = Boolean(matchId && detailCandidateIds.has(matchId));
      const detailResult = needsDetailPayload ? await fetchMatchDetailsPayload(matchId) : null;
      const result = evaluateAuditIssues(match, {
        nowMs,
        matchDurationMs: AUDIT_MATCH_MAX_DURATION_MS,
        detailPayload: detailResult && detailResult.ok ? detailResult.payload : null,
        detailMissing: Boolean(detailResult && !detailResult.ok),
      });
      auditState.total_matches_audited += 1;
      updateCurrentRun({
        matches_audited: (auditState.current_run.matches_audited || 0) + 1,
        detail_checks_completed:
          (auditState.current_run.detail_checks_completed || 0) + (needsDetailPayload ? 1 : 0),
        issues_found: (auditState.current_run.issues_found || 0) + result.issues.length,
      });
      return result;
    }
  );

  const futureFixtureResults = futureFixtureSources
    ? buildFutureRedisFixtureAuditResults(
      futureFixtureSources.redis_matches,
      futureFixtureSources.bbc_matches,
      {
        nowMs,
        coverageEnd:
          futureFixtureSources &&
          futureFixtureSources.coverage &&
          futureFixtureSources.coverage.end
            ? futureFixtureSources.coverage.end
            : null,
      }
    )
    : [];
  const mergedResults = mergeAuditResults(results, futureFixtureResults);
  const issues = mergedResults.flatMap((result) => result.issues);
  const matchesWithIssues = groupIssuesByMatch(mergedResults).filter((match) => match.issues.length > 0);
  const summary = summarizeAuditReport(mergedResults, issues);
  const report = {
    generated_at: new Date(nowMs).toISOString(),
    trigger,
    config: buildPublicConfig(),
    window: {
      start: window.start,
      end: window.end,
      lookback_days: effectiveLookbackDays,
      unbounded: Boolean(window.unbounded),
      time_zone: AUDIT_TIME_ZONE,
    },
    summary,
    matches: matchesWithIssues,
    issues,
    reconciliation: {
      future_redis_matches_checked: Array.isArray(futureFixtureSources && futureFixtureSources.redis_matches)
        ? futureFixtureSources.redis_matches.length
        : 0,
      future_redis_matches_missing_from_bbc: futureFixtureResults.length,
      coverage:
        futureFixtureSources && futureFixtureSources.coverage
          ? futureFixtureSources.coverage
          : null,
      sources:
        futureFixtureSources && futureFixtureSources.sources
          ? futureFixtureSources.sources
          : null,
      updated_at:
        futureFixtureSources && futureFixtureSources.updated_at
          ? futureFixtureSources.updated_at
          : null,
    },
  };

  const autoRepair = await autoRepairReportIssues(report, trigger);
  report.auto_repair = autoRepair;
  report.summary = {
    ...summary,
    auto_repair_candidates: autoRepair.candidates,
    auto_repair_attempted: autoRepair.attempted,
    auto_repair_succeeded: autoRepair.succeeded,
    auto_repair_failed: autoRepair.failed,
  };
  updateCurrentRun({
    stage: "deleting_stale_fixtures",
    auto_repair_candidates: autoRepair.candidates,
    auto_repair_attempted: autoRepair.attempted,
    auto_repair_succeeded: autoRepair.succeeded,
    auto_repair_failed: autoRepair.failed,
  });

  // Mark future fixtures missing from BBC as deleted, guarded by total issue count threshold.
  const matchesWithIssueCount = report.summary.matches_with_issues || 0;
  const deletionSuppressed = !AUDIT_DELETION_ENABLED || matchesWithIssueCount >= AUDIT_DELETION_ISSUES_THRESHOLD;
  let deletionResult;
  if (deletionSuppressed) {
    deletionResult = {
      enabled: AUDIT_DELETION_ENABLED,
      skipped: true,
      reason: !AUDIT_DELETION_ENABLED ? "disabled" : `issue_threshold_exceeded (${matchesWithIssueCount} >= ${AUDIT_DELETION_ISSUES_THRESHOLD})`,
      deleted: 0,
      failed: 0,
      results: [],
      errors: [],
    };
  } else {
    deletionResult = await markFutureFixturesAsDeleted(issues);
  }
  report.deletion = deletionResult;
  report.summary = {
    ...report.summary,
    matches_deleted: deletionResult.deleted || 0,
  };

  updateCurrentRun({ stage: "finalizing" });
  const emailResult = await sendAuditSummaryEmail(report, deletionResult);
  report.email = emailResult;

  return report;
}

async function runAuditCycle(trigger = "interval") {
  if (auditState.running) {
    return auditState.current_report;
  }

  auditState.running = true;
  auditState.total_runs += 1;
  auditState.last_run_started_at = new Date().toISOString();
  try {
    const startedAtMs = Date.now();
    const report = await buildAuditReport(trigger);
    auditState.current_report = report;
    auditState.last_run_completed_at = new Date().toISOString();
    auditState.last_success_at = auditState.last_run_completed_at;
    auditState.last_error = null;
    auditState.last_duration_ms = Date.now() - startedAtMs;
    updateCurrentRun({
      status: "completed",
      stage: "completed",
      completed_at: auditState.last_run_completed_at,
      matches_audited: report.summary && report.summary.matches_checked ? report.summary.matches_checked : 0,
    });
    return report;
  } catch (error) {
    auditState.total_run_failures += 1;
    auditState.last_run_completed_at = new Date().toISOString();
    auditState.last_error = error && error.message ? error.message : String(error);
    auditState.last_duration_ms = null;
    updateCurrentRun({
      status: "failed",
      stage: "failed",
      completed_at: auditState.last_run_completed_at,
    });
    throw error;
  } finally {
    auditState.running = false;
  }
}

function filteredIssuesFromReport(report, query = {}) {
  const issues = Array.isArray(report && report.issues) ? report.issues : [];
  const severity = normalizeText(query.severity).toLowerCase();
  const code = normalizeText(query.code).toLowerCase();
  const search = normalizeText(query.q || query.search).toLowerCase();
  return issues.filter((issue) => {
    if (severity && String(issue.severity || "").toLowerCase() !== severity) return false;
    if (code && String(issue.code || "").toLowerCase() !== code) return false;
    if (search) {
      const haystack = [
        issue.match_id,
        issue.date,
        issue.time,
        issue.league,
        issue.home_team,
        issue.away_team,
        issue.code,
        issue.message,
      ]
        .map((value) => String(value || "").toLowerCase())
        .join(" ");
      if (!haystack.includes(search)) return false;
    }
    return true;
  });
}

function escapePrometheusLabel(value) {
  return String(value)
    .replaceAll("\\", "\\\\")
    .replaceAll("\n", "\\n")
    .replaceAll('"', '\\"');
}

function formatPrometheusLabels(labels) {
  return Object.entries(labels)
    .filter(([, value]) => value !== null && value !== undefined && String(value).length > 0)
    .map(([key, value]) => `${key}="${escapePrometheusLabel(value)}"`)
    .join(",");
}

function pushPrometheusSample(lines, metricName, value, labels = null) {
  const numeric = Number.isFinite(Number(value)) ? Number(value) : 0;
  if (labels && Object.keys(labels).length > 0) {
    lines.push(`${metricName}{${formatPrometheusLabels(labels)}} ${numeric}`);
    return;
  }
  lines.push(`${metricName} ${numeric}`);
}

function buildPrometheusMetricsText() {
  const lines = [];
  const report = auditState.current_report || buildEmptyAuditReport();
  const summary = report.summary || {};
  const issues = Array.isArray(report.issues) ? report.issues : [];
  const nowMs = Date.now();
  const lastSuccessMs = Date.parse(auditState.last_success_at || "");
  const reportGeneratedMs = Date.parse(report.generated_at || "");

  lines.push("# HELP top_scores_match_audit_info Static audit runtime metadata.");
  lines.push("# TYPE top_scores_match_audit_info gauge");
  pushPrometheusSample(lines, "top_scores_match_audit_info", 1, {
    upstream_api_root: AUDIT_MAIN_API_ROOT,
    time_zone: AUDIT_TIME_ZONE,
  });

  lines.push("# HELP top_scores_match_audit_running 1 while an audit run is in progress.");
  lines.push("# TYPE top_scores_match_audit_running gauge");
  pushPrometheusSample(lines, "top_scores_match_audit_running", auditState.running ? 1 : 0);

  lines.push("# HELP top_scores_match_audit_matches_audited_total Total matches processed by the audit service.");
  lines.push("# TYPE top_scores_match_audit_matches_audited_total counter");
  pushPrometheusSample(lines, "top_scores_match_audit_matches_audited_total", auditState.total_matches_audited);

  lines.push("# HELP top_scores_match_audit_runs_total Total audit runs attempted.");
  lines.push("# TYPE top_scores_match_audit_runs_total counter");
  pushPrometheusSample(lines, "top_scores_match_audit_runs_total", auditState.total_runs);

  lines.push("# HELP top_scores_match_audit_run_failures_total Total audit runs that failed.");
  lines.push("# TYPE top_scores_match_audit_run_failures_total counter");
  pushPrometheusSample(lines, "top_scores_match_audit_run_failures_total", auditState.total_run_failures);

  lines.push("# HELP top_scores_match_audit_last_success_timestamp_seconds Unix timestamp of the last successful audit run.");
  lines.push("# TYPE top_scores_match_audit_last_success_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "top_scores_match_audit_last_success_timestamp_seconds",
    Number.isFinite(lastSuccessMs) ? lastSuccessMs / 1000 : 0
  );

  lines.push("# HELP top_scores_match_audit_last_report_timestamp_seconds Unix timestamp of the current report snapshot.");
  lines.push("# TYPE top_scores_match_audit_last_report_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "top_scores_match_audit_last_report_timestamp_seconds",
    Number.isFinite(reportGeneratedMs) ? reportGeneratedMs / 1000 : 0
  );

  lines.push("# HELP top_scores_match_audit_last_duration_seconds Duration of the last audit run.");
  lines.push("# TYPE top_scores_match_audit_last_duration_seconds gauge");
  pushPrometheusSample(
    lines,
    "top_scores_match_audit_last_duration_seconds",
    Number.isFinite(auditState.last_duration_ms) ? auditState.last_duration_ms / 1000 : 0
  );

  const nextRunScheduledMs = Date.parse(auditState.next_run_scheduled_at || "");
  lines.push("# HELP top_scores_match_audit_next_run_timestamp_seconds Unix timestamp of the next scheduled interval audit run.");
  lines.push("# TYPE top_scores_match_audit_next_run_timestamp_seconds gauge");
  pushPrometheusSample(
    lines,
    "top_scores_match_audit_next_run_timestamp_seconds",
    Number.isFinite(nextRunScheduledMs) ? nextRunScheduledMs / 1000 : 0
  );

  lines.push("# HELP top_scores_match_audit_report_age_seconds Age of the current audit report snapshot.");
  lines.push("# TYPE top_scores_match_audit_report_age_seconds gauge");
  pushPrometheusSample(
    lines,
    "top_scores_match_audit_report_age_seconds",
    Number.isFinite(reportGeneratedMs) ? Math.max(0, (nowMs - reportGeneratedMs) / 1000) : 0
  );

  const currentRun = currentRunSnapshot();
  lines.push("# HELP top_scores_match_audit_current_run_matches_total Current run total matches scheduled for audit.");
  lines.push("# TYPE top_scores_match_audit_current_run_matches_total gauge");
  pushPrometheusSample(lines, "top_scores_match_audit_current_run_matches_total", currentRun.total_matches || 0);

  lines.push("# HELP top_scores_match_audit_current_run_matches_completed Current run matches audited so far.");
  lines.push("# TYPE top_scores_match_audit_current_run_matches_completed gauge");
  pushPrometheusSample(lines, "top_scores_match_audit_current_run_matches_completed", currentRun.matches_audited || 0);

  lines.push("# HELP top_scores_match_audit_current_run_progress_ratio Current run completion ratio between 0 and 1.");
  lines.push("# TYPE top_scores_match_audit_current_run_progress_ratio gauge");
  pushPrometheusSample(lines, "top_scores_match_audit_current_run_progress_ratio", currentRun.progress_ratio || 0);

  lines.push("# HELP top_scores_match_audit_current_run_matches_per_second Current run audit throughput in matches per second.");
  lines.push("# TYPE top_scores_match_audit_current_run_matches_per_second gauge");
  pushPrometheusSample(lines, "top_scores_match_audit_current_run_matches_per_second", currentRun.matches_per_second || 0);

  const summaryMetrics = {
    matches_checked: summary.matches_checked || 0,
    started_matches: summary.started_matches || 0,
    finished_expected_matches: summary.finished_expected_matches || 0,
    detail_candidates: summary.detail_candidates || 0,
    detail_checks_attempted: summary.detail_checks_attempted || 0,
    detail_checks_succeeded: summary.detail_checks_succeeded || 0,
    matches_with_issues: summary.matches_with_issues || 0,
    issues_total: summary.issues_total || 0,
    healthy_matches: summary.healthy_matches || 0,
    auto_repair_candidates: summary.auto_repair_candidates || 0,
    auto_repair_attempted: summary.auto_repair_attempted || 0,
    auto_repair_succeeded: summary.auto_repair_succeeded || 0,
    auto_repair_failed: summary.auto_repair_failed || 0,
  };
  Object.entries(summaryMetrics).forEach(([name, value]) => {
    lines.push(`# HELP top_scores_match_audit_${name} Current audit summary value for ${name}.`);
    lines.push(`# TYPE top_scores_match_audit_${name} gauge`);
    pushPrometheusSample(lines, `top_scores_match_audit_${name}`, value);
  });

  lines.push("# HELP top_scores_match_audit_issue_count Current issue count grouped by code and severity.");
  lines.push("# TYPE top_scores_match_audit_issue_count gauge");
  Object.entries(summary.issue_counts_by_code || {}).forEach(([code, count]) => {
    const severity = issues.find((issue) => issue.code === code)?.severity || "warning";
    pushPrometheusSample(lines, "top_scores_match_audit_issue_count", count, {
      code,
      severity,
    });
  });

  lines.push("# HELP top_scores_match_audit_status_count Current match count grouped by score status.");
  lines.push("# TYPE top_scores_match_audit_status_count gauge");
  Object.entries(summary.status_counts || {}).forEach(([status, count]) => {
    pushPrometheusSample(lines, "top_scores_match_audit_status_count", count, { status });
  });

  lines.push("# HELP top_scores_match_audit_issue_match Current issue flags for individual matches.");
  lines.push("# TYPE top_scores_match_audit_issue_match gauge");
  issues.forEach((issue) => {
    pushPrometheusSample(lines, "top_scores_match_audit_issue_match", 1, {
      match_id: issue.match_id || issue.audit_match_id,
      code: issue.code,
      severity: issue.severity,
      league: issue.league || "",
      home_team: issue.home_team || "",
      away_team: issue.away_team || "",
      date: issue.date || "",
      time: issue.time || "",
      score_status: issue.score_status || "",
    });
  });

  lines.push("# HELP top_scores_match_audit_rescrapes_total Manual audit-triggered rescrape requests.");
  lines.push("# TYPE top_scores_match_audit_rescrapes_total counter");
  pushPrometheusSample(lines, "top_scores_match_audit_rescrapes_total", auditState.total_rescrapes_requested, {
    status: "requested",
  });
  pushPrometheusSample(lines, "top_scores_match_audit_rescrapes_total", auditState.total_rescrapes_succeeded, {
    status: "succeeded",
  });
  pushPrometheusSample(lines, "top_scores_match_audit_rescrapes_total", auditState.total_rescrapes_failed, {
    status: "failed",
  });

  lines.push("# HELP top_scores_match_audit_auto_rescrapes_total Automatic audit-triggered rescrape requests.");
  lines.push("# TYPE top_scores_match_audit_auto_rescrapes_total counter");
  pushPrometheusSample(lines, "top_scores_match_audit_auto_rescrapes_total", auditState.total_auto_rescrapes_requested, {
    status: "requested",
  });
  pushPrometheusSample(lines, "top_scores_match_audit_auto_rescrapes_total", auditState.total_auto_rescrapes_succeeded, {
    status: "succeeded",
  });
  pushPrometheusSample(lines, "top_scores_match_audit_auto_rescrapes_total", auditState.total_auto_rescrapes_failed, {
    status: "failed",
  });

  return `${lines.join("\n")}\n`;
}

function paginate(items, page, pageSize) {
  const totalCount = items.length;
  const totalPages = totalCount > 0 ? Math.ceil(totalCount / pageSize) : 0;
  const safePage = Math.max(1, Math.min(page, totalPages || 1));
  const start = (safePage - 1) * pageSize;
  const paged = totalCount > 0 ? items.slice(start, start + pageSize) : [];
  return {
    page: safePage,
    page_size: pageSize,
    total_count: totalCount,
    total_pages: totalPages,
    has_more: safePage < totalPages,
    items: paged,
  };
}

async function triggerManualRescrape(matchId) {
  return triggerRescrape(matchId, { mode: "manual" });
}

function createAuditServiceApp() {
  const app = express();
  app.disable("x-powered-by");
  app.use(express.json());

  app.get("/healthcheck", (_req, res) => {
    setNoStoreHeaders(res);
    const currentRun = currentRunSnapshot();
    const nowMs = Date.now();
    const reportGeneratedMs = Date.parse(auditState.current_report.generated_at || "");
    const stale = Number.isFinite(reportGeneratedMs)
      ? nowMs - reportGeneratedMs > AUDIT_STALE_AFTER_MS
      : true;
    const lastProgressMs = Date.parse(currentRun.last_progress_at || "");
    const progressing = auditState.running && Number.isFinite(lastProgressMs)
      ? nowMs - lastProgressMs <= Math.max(30 * 1000, AUDIT_HTTP_TIMEOUT_MS * 2)
      : false;
    const auditStatus = auditState.last_error
      ? "degraded"
      : stale
        ? "stale"
        : "ok";
    res.json({
      status: "ok",
      role: "match-audit",
      audit_status: auditStatus,
      ready: auditStatus === "ok" || progressing,
      progressing,
      running: auditState.running,
      current_run: currentRun,
      last_success_at: auditState.last_success_at,
      last_error: auditState.last_error,
      report_generated_at: auditState.current_report.generated_at,
      stale,
      config: buildPublicConfig(),
    });
  });

  app.get("/metrics", (_req, res) => {
    res.set("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
    res.send(buildPrometheusMetricsText());
  });

  app.get(`${API_PREFIX}/audit/summary`, (req, res) => {
    setNoStoreHeaders(res);
    const report = auditState.current_report || buildEmptyAuditReport();
    const limit = Number.isFinite(Number(req.query.limit))
      ? Math.max(1, Math.min(1000, Math.floor(Number(req.query.limit))))
      : 250;
    const filteredIssues = filteredIssuesFromReport(report, req.query);
    const filteredMatches = groupIssuesByMatch(
      filteredIssues.map((issue) => ({
        summary: {
          match_id: issue.match_id,
          audit_match_id: issue.audit_match_id,
          date: issue.date,
          time: issue.time,
          league: issue.league,
          home_team: issue.home_team,
          away_team: issue.away_team,
          score_status: issue.score_status,
          home_score: issue.home_score,
          away_score: issue.away_score,
        },
        issues: [issue],
      }))
    );

    res.json({
      success: true,
      running: auditState.running,
      current_run: currentRunSnapshot(),
      last_success_at: auditState.last_success_at,
      last_error: auditState.last_error,
      last_duration_ms: auditState.last_duration_ms,
      report: {
        ...report,
        matches: filteredMatches.slice(0, limit),
        issues: filteredIssues.slice(0, limit),
        filtered_issue_count: filteredIssues.length,
        filtered_match_count: filteredMatches.length,
      },
    });
  });

  app.get(`${API_PREFIX}/audit/issues`, (req, res) => {
    setNoStoreHeaders(res);
    const report = auditState.current_report || buildEmptyAuditReport();
    const pageSize = Number.isFinite(Number(req.query.page_size))
      ? Math.max(1, Math.min(1000, Math.floor(Number(req.query.page_size))))
      : 100;
    const page = Number.isFinite(Number(req.query.page))
      ? Math.max(1, Math.floor(Number(req.query.page)))
      : 1;
    const filtered = filteredIssuesFromReport(report, req.query);
    const paged = paginate(filtered, page, pageSize);
    res.json({
      success: true,
      generated_at: report.generated_at,
      pagination: {
        page: paged.page,
        page_size: paged.page_size,
        total_count: paged.total_count,
        total_pages: paged.total_pages,
        has_more: paged.has_more,
      },
      issues: paged.items,
    });
  });

  app.get(`${API_PREFIX}/audit/matches`, (req, res) => {
    setNoStoreHeaders(res);
    const report = auditState.current_report || buildEmptyAuditReport();
    const pageSize = Number.isFinite(Number(req.query.page_size))
      ? Math.max(1, Math.min(1000, Math.floor(Number(req.query.page_size))))
      : 100;
    const page = Number.isFinite(Number(req.query.page))
      ? Math.max(1, Math.floor(Number(req.query.page)))
      : 1;
    const filteredIssues = filteredIssuesFromReport(report, req.query);
    const filteredMatches = groupIssuesByMatch(
      filteredIssues.map((issue) => ({
        summary: {
          match_id: issue.match_id,
          audit_match_id: issue.audit_match_id,
          date: issue.date,
          time: issue.time,
          league: issue.league,
          home_team: issue.home_team,
          away_team: issue.away_team,
          score_status: issue.score_status,
          home_score: issue.home_score,
          away_score: issue.away_score,
        },
        issues: [issue],
      }))
    );
    const paged = paginate(filteredMatches, page, pageSize);
    res.json({
      success: true,
      generated_at: report.generated_at,
      pagination: {
        page: paged.page,
        page_size: paged.page_size,
        total_count: paged.total_count,
        total_pages: paged.total_pages,
        has_more: paged.has_more,
      },
      matches: paged.items,
    });
  });

  app.post(`${API_PREFIX}/audit/run`, async (_req, res) => {
    setNoStoreHeaders(res);
    try {
      const report = await runAuditCycle("manual_api");
      res.json({
        success: true,
        report,
      });
    } catch (error) {
      res.status(500).json({
        error: "Failed to run match audit",
        message: error && error.message ? error.message : String(error),
      });
    }
  });

  app.post(`${API_PREFIX}/audit/matches/:matchId/rescrape`, async (req, res) => {
    setNoStoreHeaders(res);
    try {
      const result = await triggerManualRescrape(req.params.matchId);
      const report = await runAuditCycle("manual_rescrape");
      res.json({
        success: true,
        match_id: normalizeMatchId(req.params.matchId),
        rescrape: result,
        report_generated_at: report.generated_at,
      });
    } catch (error) {
      const status = Number.isFinite(error && error.status) ? error.status : 500;
      res.status(status).json({
        error: "Failed to rescrape match via main API",
        message: error && error.message ? error.message : String(error),
      });
    }
  });

  app.get("/admin/audit-matches", (_req, res) => {
    res.sendFile(path.join(__dirname, "admin_match_audit_ui.html"));
  });

  return app;
}

function registerScheduledAuditRun(callback) {
  const nextRunMs = computeNextScheduledRunAt(Date.now());
  auditState.next_run_scheduled_at = Number.isFinite(nextRunMs)
    ? new Date(nextRunMs).toISOString()
    : null;
  const delayMs = Number.isFinite(nextRunMs)
    ? Math.max(1000, nextRunMs - Date.now())
    : AUDIT_SCHEDULE_INTERVAL_MS;
  runtimeScheduleHandle = setTimeout(async () => {
    runtimeScheduleHandle = null;
    const followingRunMs = computeNextScheduledRunAt(Date.now() + 1000);
    auditState.next_run_scheduled_at = Number.isFinite(followingRunMs)
      ? new Date(followingRunMs).toISOString()
      : null;
    try {
      await callback();
    } finally {
      if (runtimeServer) {
        registerScheduledAuditRun(callback);
      }
    }
  }, delayMs);
  if (typeof runtimeScheduleHandle.unref === "function") {
    runtimeScheduleHandle.unref();
  }
  return runtimeScheduleHandle;
}

function clearRuntimeIntervals() {
  auditState.next_run_scheduled_at = null;
  if (runtimeScheduleHandle) {
    clearTimeout(runtimeScheduleHandle);
    runtimeScheduleHandle = null;
  }
}

async function closeRuntimeServer() {
  if (!runtimeServer) return;
  const serverToClose = runtimeServer;
  runtimeServer = null;
  await new Promise((resolve, reject) => {
    serverToClose.close((error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
}

async function shutdownAuditService() {
  if (runtimeShutdownPromise) return runtimeShutdownPromise;
  runtimeShutdownPromise = (async () => {
    clearRuntimeIntervals();
    await closeRuntimeServer();
  })().finally(() => {
    runtimeShutdownPromise = null;
  });
  return runtimeShutdownPromise;
}

async function runStartupAuditWithRetry(maxAttempts = 6, delayMs = 3000) {
  let lastError = null;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      return await runAuditCycle(attempt === 1 ? "startup" : "startup_retry");
    } catch (error) {
      lastError = error;
      if (attempt >= maxAttempts) {
        break;
      }
      console.warn(
        `[Audit] Startup audit attempt ${attempt}/${maxAttempts} failed: ${error && error.message ? error.message : error}`
      );
      // eslint-disable-next-line no-await-in-loop
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
  throw lastError || new Error("Startup audit failed");
}

function installSignalHandlers() {
  const handleSignal = (signal) => {
    console.log(`[Audit] ${signal} received, shutting down gracefully`);
    void shutdownAuditService()
      .then(() => process.exit(0))
      .catch((error) => {
        console.error(`[Audit] Shutdown failed after ${signal}:`, error.message || error);
        process.exit(1);
      });
  };
  process.on("SIGTERM", () => handleSignal("SIGTERM"));
  process.on("SIGINT", () => handleSignal("SIGINT"));
}

function startAuditService() {
  if (runtimeServer) return runtimeServer;

  const app = createAuditServiceApp();
  runtimeServer = app.listen(AUDIT_PORT, () => {
    console.log(`Match audit service listening on http://localhost:${AUDIT_PORT}`);
  });

  registerScheduledAuditRun(async () => {
    await runAuditCycle("interval").catch((error) => {
      console.error("[Audit] Interval audit run failed:", error.message || error);
    });
  });

  installSignalHandlers();
  return runtimeServer;
}

if (require.main === module) {
  startAuditService();
}

module.exports = {
  createAuditServiceApp,
  startAuditService,
  shutdownAuditService,
  __private: {
    buildDateRangeWindow,
    buildFutureRedisFixtureAuditResults,
    buildFutureFixturePresenceLookup,
    computeNextScheduledRunAt,
    buildEmptyCurrentRun,
    currentRunSnapshot,
    mergeAuditResults,
    updateCurrentRun,
    zonedDateTimeToUtcMs,
    kickoffTimestampMs,
    normalizeStatusToken,
    isInProgressStatus,
    isFinalStatus,
    isNonScoreTerminalStatus,
    evaluateAuditIssues,
    groupIssuesByMatch,
    summarizeAuditReport,
    buildPrometheusMetricsText,
    filteredIssuesFromReport,
    autoRepairEligibleMatchIds,
    buildSyntheticAuditMatchId,
    normalizeMatchId,
    resolveTeamAlias,
    markFutureFixturesAsDeleted,
    buildAuditEmailSubject,
    buildAuditEmailBody,
    sleepMs,
    isRetryableDetailError,
    computeRetryDelayMs,
    auditState,
  },
};
