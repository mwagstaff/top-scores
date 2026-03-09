const {
  getAllUserPreferences,
  updateUserLiveActivityState,
  saveBbcMatchEventHistory,
  saveBbcNotificationHistory,
  claimBbcNotificationIdempotency,
} = require("./redis_client");
const { sendNotification, sendLiveActivityPush } = require("./apns_client");
const { fetchBbcLiveTextEntriesByDetailsUrl } = require("./fetch_bbc_scores");
const liveActivityMetrics = require("./live_activity_metrics");
const crypto = require("crypto");
const LIVE_ACTIVITY_PREMIER_LEAGUE_TEAMS = require("./bbc_premier_league_teams.json");

// Configuration
const POLL_INTERVAL_MS = 10 * 1000; // Poll every 10 seconds for monitored matches
const DAILY_MATCHES_CHECK_INTERVAL_MS = 15 * 1000; // Check for today's matches every 15 seconds
const CLEANUP_INTERVAL_MS = 5 * 60 * 1000; // Clean up every 5 minutes
const UPCOMING_MONITOR_WINDOW_MS = 15 * 60 * 1000;
const MAX_MONITOR_DURATION_MS = 6 * 60 * 60 * 1000; // Keep monitoring up to 6h after kickoff
const NOTIFICATION_DEDUP_WINDOW_MS = 6 * 60 * 60 * 1000; // Keep event dedupe for a full match window
const KICKOFF_STATUS_MINUTE_THRESHOLD = 15; // Ignore kickoff if first seen too late in the match
const GOAL_TIMELINE_BACKLOG_LIMIT = 64; // Keep bounded unreconciled timeline events per match
const SCORE_REVERSION_CONFIRMATION_POLLS = 5;
const VAR_DECISION_REVIEW_WINDOW_MINUTES = 5;
const MONITOR_DIAGNOSTICS_RECENT_LIMIT = 300; // Keep a rolling in-memory diagnostics window
const MATCH_MONITOR_DECISION_LOG_ENABLED = process.env.MATCH_MONITOR_DECISION_LOG !== "0";
const LIVE_ACTIVITY_EVAL_INTERVAL_MS = 15 * 1000;
const LIVE_ACTIVITY_STARTUP_KICK_DELAYS_MS = [0, 3000, 9000];
// Keep server payloads aligned with the widget's 8 visible live-activity slots.
const LIVE_ACTIVITY_MAX_MATCHES = 8;
const LIVE_ACTIVITY_TEAM_RANKING_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const LIVE_ACTIVITY_TEAM_RANKING_RETRY_MS = 5 * 60 * 1000;
const LIVE_ACTIVITY_TEAM_RANKING_FETCH_TIMEOUT_MS = 15 * 1000;
// If APNS accepts a start but the app never reports an activity token, retry quickly.
const LIVE_ACTIVITY_PENDING_MAX_MS = 2 * 60 * 1000;
const LIVE_ACTIVITY_DEFAULT_STALE_AFTER_SECONDS = 30 * 60;
const LIVE_ACTIVITY_PAYLOAD_WARN_BYTES = 3500;
const LIVE_ACTIVITY_PAYLOAD_HARD_LIMIT_BYTES = 4096;
const LIVE_ACTIVITY_STALE_LIVE_UPDATED_GRACE_MS = 5 * 60 * 1000;
const LIVE_ACTIVITY_STALE_LIVE_KICKOFF_GRACE_MS = 2 * 60 * 60 * 1000;
const LIVE_ACTIVITY_FINISHED_RETENTION_MS = 8 * 60 * 60 * 1000;
const LIVE_ACTIVITY_ATTRIBUTES_TYPE = "TopScoresLiveActivityAttributes";
const LIVE_ACTIVITY_ATTRIBUTES = { appScope: "topscores" };
const LIVE_ACTIVITY_TEAM_RATING_STOP_WORDS = new Set([
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
const LIVE_ACTIVITY_TEAM_RATING_ALIAS_MAP = Object.freeze({
  celtavigo: "celta",
  manchesterunited: "manunited",
  manchestercity: "mancity",
  tottenhamhotspur: "tottenham",
  wolverhamptonwanderers: "wolves",
  sheffieldunited: "sheffutd",
  sheffieldwednesday: "sheffwed",
  nottinghamforest: "nottmforest",
  brightonhovealbion: "brighton",
  brightonandhovealbion: "brighton",
  bayernmunich: "bayern",
  borussiadortmund: "dortmund",
  borussiamonchengladbach: "gladbach",
  intermilan: "inter",
  oxfordunited: "oxford",
  prestonnorthend: "preston",
});

// State tracking
const monitoredMatches = new Map(); // matchId -> matchState
const scheduledNotifications = new Map(); // notificationId -> timeout handle
const sentNotifications = new Set(); // Local process dedupe; Redis enforces cross-process idempotency
const finishedMatchIds = new Set(); // Match IDs that have been fully processed - never restart these
const retainedFinishedMatches = new Map(); // matchId -> terminal snapshot kept for post-match Live Activity display
const monitorDiagnostics = {
  lastCheck: null,
  lastError: null,
  recentDecisions: [],
  recentMonitorStarts: [],
  recentMonitorStops: [],
};
let liveActivityTeamRatingLookup = null;
let liveActivityTeamRatingDefaultElo = 1000;
let liveActivityTeamRatingFetchedAtMs = 0;
let liveActivityTeamRatingLastAttemptAtMs = 0;
let liveActivityTeamRatingRefreshPromise = null;
let liveActivityPremierLeagueTeamLookup = null;

// Match status helpers - mirrors server.js MATCH_STATUS_* constants
const MATCH_STATUS_MINUTE_PATTERN = /^(\d{1,3})(?:\+(\d{1,2}))?'?$/;
const MATCH_STATUS_COMPLETE_TOKENS = new Set(["FT", "AET"]);
const MATCH_STATUS_IN_PROGRESS_TOKENS = new Set(["LIVE", "HT", "ET", "PENS", "PEN", "PEN."]);
const MATCH_STATUS_PENALTY_TOKENS = new Set(["PENS", "PEN", "PEN."]);
const SNAPSHOT_NULL_CLEAR_FIELDS = new Set(["aggregate_home_score", "aggregate_away_score"]);

function shortDeviceToken(deviceToken) {
  return String(deviceToken || "").slice(0, 12);
}

function logDecision(decisionType, details = {}) {
  if (!MATCH_MONITOR_DECISION_LOG_ENABLED) return;
  const payload = {
    ts: new Date().toISOString(),
    decision_type: decisionType,
    ...details,
  };
  console.log(`[MatchMonitor][Decision] ${JSON.stringify(payload)}`);
}

function boundedPush(list, item, limit = MONITOR_DIAGNOSTICS_RECENT_LIMIT) {
  list.push(item);
  if (list.length > limit) {
    list.splice(0, list.length - limit);
  }
}

function incrementReasonCounter(target, reason) {
  const key = String(reason || "unknown");
  target[key] = (target[key] || 0) + 1;
}

function nowIsoTimestamp() {
  return new Date().toISOString();
}

function addMonitorDecisionDiagnostic(decision) {
  boundedPush(monitorDiagnostics.recentDecisions, {
    timestamp: nowIsoTimestamp(),
    ...decision,
  });
}

function addMonitorStartDiagnostic(payload) {
  boundedPush(monitorDiagnostics.recentMonitorStarts, {
    timestamp: nowIsoTimestamp(),
    ...payload,
  });
}

function addMonitorStopDiagnostic(payload) {
  boundedPush(monitorDiagnostics.recentMonitorStops, {
    timestamp: nowIsoTimestamp(),
    ...payload,
  });
}

function resetMonitorDiagnostics() {
  monitorDiagnostics.lastCheck = null;
  monitorDiagnostics.lastError = null;
  monitorDiagnostics.recentDecisions.length = 0;
  monitorDiagnostics.recentMonitorStarts.length = 0;
  monitorDiagnostics.recentMonitorStops.length = 0;
}

function normalizeStatusToken(status) {
  return String(status || "").trim().toUpperCase();
}

function parseStatusMinute(status) {
  const normalized = String(status || "").trim();
  const match = normalized.match(MATCH_STATUS_MINUTE_PATTERN);
  if (!match) return null;
  const base = Number(match[1]);
  const added = Number(match[2] || 0);
  if (!Number.isFinite(base) || !Number.isFinite(added)) return null;
  return base + added;
}

function parseMatchEventMinute(value) {
  if (value === undefined || value === null) return null;
  const normalized = String(value).trim().replace(/'/g, "");
  if (!normalized) return null;
  const match = normalized.match(/^(\d{1,3})(?:\+(\d{1,2}))?$/);
  if (!match) return null;
  const base = Number(match[1]);
  const added = Number(match[2] || 0);
  if (!Number.isFinite(base) || !Number.isFinite(added)) return null;
  return base + added;
}

function countGoalsUpToMinute(goalScorers, limitMinute) {
  if (!Number.isFinite(limitMinute) || !Array.isArray(goalScorers)) return 0;

  let total = 0;
  goalScorers.forEach((scorer) => {
    const goalTimes = Array.isArray(scorer && scorer.goal_times) ? scorer.goal_times : [];
    const ownGoalTimes = Array.isArray(scorer && scorer.own_goal_times) ? scorer.own_goal_times : [];
    goalTimes.forEach((goalTime) => {
      const minute = parseMatchEventMinute(goalTime);
      if (Number.isFinite(minute) && minute <= limitMinute) {
        total += 1;
      }
    });
    ownGoalTimes.forEach((goalTime) => {
      const minute = parseMatchEventMinute(goalTime);
      if (Number.isFinite(minute) && minute <= limitMinute) {
        total += 1;
      }
    });
  });

  return total;
}

function buildDelayedLiveState(currentMatch, delayedMatch, delayMinutes) {
  if (!currentMatch || typeof currentMatch !== "object") return null;
  const currentMinute = parseStatusMinute(currentMatch.score_status);
  if (!Number.isFinite(currentMinute) || !Number.isFinite(delayMinutes) || delayMinutes <= 0) {
    return null;
  }

  const delayedStatusMinute = parseStatusMinute(delayedMatch && delayedMatch.score_status);
  const delayedMinute = Number.isFinite(delayedStatusMinute)
    ? delayedStatusMinute
    : Math.max(0, currentMinute - delayMinutes);
  if (delayedMinute <= 0) {
    return null;
  }
  const hasGoalTimeline =
    Array.isArray(currentMatch.home_goal_scorers) || Array.isArray(currentMatch.away_goal_scorers);
  const timelineHomeGoals = countGoalsUpToMinute(currentMatch.home_goal_scorers, delayedMinute);
  const timelineAwayGoals = countGoalsUpToMinute(currentMatch.away_goal_scorers, delayedMinute);
  const delayedHomeScore = toNumericScore(delayedMatch && delayedMatch.home_score);
  const delayedAwayScore = toNumericScore(delayedMatch && delayedMatch.away_score);
  const currentHomeScore = toNumericScore(currentMatch.home_score);
  const currentAwayScore = toNumericScore(currentMatch.away_score);
  const timelineHomeGoalCount = countGoals(currentMatch.home_goal_scorers);
  const timelineAwayGoalCount = countGoals(currentMatch.away_goal_scorers);
  const homeTimelineComplete =
    Number.isFinite(currentHomeScore) && timelineHomeGoalCount >= currentHomeScore;
  const awayTimelineComplete =
    Number.isFinite(currentAwayScore) && timelineAwayGoalCount >= currentAwayScore;

  if (hasGoalTimeline) {
    return {
      home_score: homeTimelineComplete
        ? timelineHomeGoals
        : Math.max(timelineHomeGoals, delayedHomeScore || 0),
      away_score: awayTimelineComplete
        ? timelineAwayGoals
        : Math.max(timelineAwayGoals, delayedAwayScore || 0),
      score_status:
        delayedMatch && delayedMatch.score_status ? String(delayedMatch.score_status) : String(delayedMinute),
    };
  }

  if (!delayedMatch || typeof delayedMatch !== "object") {
    return {
      home_score: null,
      away_score: null,
      score_status: String(delayedMinute),
    };
  }

  return {
    home_score: delayedMatch.home_score,
    away_score: delayedMatch.away_score,
    score_status: String(delayedMinute),
  };
}

function delayedScoreOverrideFromTimeline(currentMatch, delayedMatch) {
  const delayedMinute = parseStatusMinute(delayedMatch && delayedMatch.score_status);
  if (!Number.isFinite(delayedMinute)) return null;
  if (!currentMatch || typeof currentMatch !== "object") return null;

  const homeGoalsByMinute = countGoalsUpToMinute(currentMatch.home_goal_scorers, delayedMinute);
  const awayGoalsByMinute = countGoalsUpToMinute(currentMatch.away_goal_scorers, delayedMinute);
  const hasTimelineEvidence = homeGoalsByMinute > 0 || awayGoalsByMinute > 0;
  if (!hasTimelineEvidence) return null;

  return {
    home_score: homeGoalsByMinute,
    away_score: awayGoalsByMinute,
  };
}

function isLiveMatchStatus(status) {
  const normalized = String(status || "").trim();
  if (!normalized) return false;
  if (MATCH_STATUS_MINUTE_PATTERN.test(normalized)) return true;
  return MATCH_STATUS_IN_PROGRESS_TOKENS.has(normalized.toUpperCase());
}

function isFinishedMatchStatus(status) {
  const normalized = String(status || "").trim();
  if (!normalized) return false;
  return MATCH_STATUS_COMPLETE_TOKENS.has(normalized.toUpperCase());
}

function isPenaltyShootoutStatus(status) {
  return MATCH_STATUS_PENALTY_TOKENS.has(normalizeStatusToken(status));
}

function parseMatchDateTimeMs(match) {
  if (!match || !match.date || !match.time) return null;
  const value = Date.parse(`${match.date}T${match.time}:00`);
  if (!Number.isFinite(value)) return null;
  return value;
}

function isLikelyTerminalStaleLiveMatch(match, kickoffMs, nowMs = Date.now()) {
  if (!match || typeof match !== "object") return false;

  const statusMinute = parseStatusMinute(match.score_status);
  if (statusMinute === null || statusMinute < 90) return false;

  const resolvedKickoffMs = Number.isFinite(kickoffMs) ? kickoffMs : parseMatchDateTimeMs(match);
  if (!Number.isFinite(resolvedKickoffMs)) return false;
  if (nowMs - resolvedKickoffMs < LIVE_ACTIVITY_STALE_LIVE_KICKOFF_GRACE_MS) return false;

  const updatedAtMs = Date.parse(String(match.updated_at || "").trim());
  if (Number.isFinite(updatedAtMs)) {
    if (nowMs <= updatedAtMs) return false;
    if (nowMs - updatedAtMs < LIVE_ACTIVITY_STALE_LIVE_UPDATED_GRACE_MS) return false;
  }

  return true;
}

function toNumericScore(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function buildTimeoutSignal(timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  return {
    signal: controller.signal,
    clear() {
      clearTimeout(timer);
    },
  };
}

async function fetchJsonWithTimeout(url, timeoutMs = LIVE_ACTIVITY_TEAM_RANKING_FETCH_TIMEOUT_MS) {
  const timeout = buildTimeoutSignal(timeoutMs);
  try {
    const response = await fetch(url, {
      signal: timeout.signal,
      headers: {
        Accept: "application/json",
      },
    });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    return await response.json();
  } finally {
    timeout.clear();
  }
}

function normalizeLiveActivityTeamTokens(value) {
  const normalized = String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/'/g, "")
    .replace(/\./g, " ")
    .replace(/-/g, " ")
    .replace(/_/g, " ");

  return normalized
    .split(/[^a-z0-9]+/)
    .filter((token) => token && !LIVE_ACTIVITY_TEAM_RATING_STOP_WORDS.has(token));
}

function normalizeLiveActivityTeamKey(value) {
  const tokens = normalizeLiveActivityTeamTokens(value);
  if (tokens.length > 0) {
    return tokens.join("");
  }
  return String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "");
}

function liveActivityTeamDiceCoefficient(lhsTokens, rhsTokens) {
  if (lhsTokens.length === 0 && rhsTokens.length === 0) return 1;
  const lhsSet = new Set(lhsTokens);
  const rhsSet = new Set(rhsTokens);
  let overlap = 0;
  lhsSet.forEach((token) => {
    if (rhsSet.has(token)) overlap += 1;
  });
  return (2 * overlap) / (lhsTokens.length + rhsTokens.length);
}

function liveActivityTeamPrefixSimilarity(lhsKey, rhsKey, lhsTokens, rhsTokens) {
  if (Math.min(lhsTokens.length, rhsTokens.length) !== 1) return 0;
  if (lhsKey.startsWith(rhsKey) || rhsKey.startsWith(lhsKey)) {
    const shorter = Math.min(lhsKey.length, rhsKey.length);
    const longer = Math.max(lhsKey.length, rhsKey.length);
    if (longer <= 0) return 1;
    return Math.min(1, shorter / longer + 0.3);
  }
  return 0;
}

function liveActivityTeamLevenshtein(lhs, rhs) {
  const lhsChars = Array.from(lhs);
  const rhsChars = Array.from(rhs);
  const previous = Array.from({ length: rhsChars.length + 1 }, (_, index) => index);
  const current = new Array(rhsChars.length + 1).fill(0);

  for (let lhsIndex = 0; lhsIndex < lhsChars.length; lhsIndex += 1) {
    current[0] = lhsIndex + 1;
    for (let rhsIndex = 0; rhsIndex < rhsChars.length; rhsIndex += 1) {
      const cost = lhsChars[lhsIndex] === rhsChars[rhsIndex] ? 0 : 1;
      current[rhsIndex + 1] = Math.min(
        previous[rhsIndex + 1] + 1,
        current[rhsIndex] + 1,
        previous[rhsIndex] + cost
      );
    }
    for (let index = 0; index < current.length; index += 1) {
      previous[index] = current[index];
    }
  }

  return previous[rhsChars.length];
}

function liveActivityTeamNormalizedEditSimilarity(lhs, rhs) {
  const maxLength = Math.max(lhs.length, rhs.length);
  if (maxLength <= 0) return 1;
  return 1 - liveActivityTeamLevenshtein(lhs, rhs) / maxLength;
}

function liveActivityTeamSimilarity(lhsKey, rhsKey, lhsTokens, rhsTokens) {
  return Math.max(
    liveActivityTeamNormalizedEditSimilarity(lhsKey, rhsKey),
    liveActivityTeamDiceCoefficient(lhsTokens, rhsTokens),
    liveActivityTeamPrefixSimilarity(lhsKey, rhsKey, lhsTokens, rhsTokens)
  );
}

function buildLiveActivityTeamRatingLookup(rows, defaultElo = 1000) {
  const exactByKey = new Map();
  const candidates = [];

  (Array.isArray(rows) ? rows : []).forEach((row) => {
    const rating = Number(row && row.Points);
    if (!Number.isFinite(rating)) return;

    const names = [row && row.Name ? row.Name : ""];
    if (Array.isArray(row && row.aliases)) {
      names.push(...row.aliases);
    }

    Array.from(
      new Set(
        names
          .map((name) => String(name || "").trim())
          .filter(Boolean)
      )
    ).forEach((name) => {
      const key = normalizeLiveActivityTeamKey(name);
      if (!key) return;
      if (!exactByKey.has(key)) {
        exactByKey.set(key, rating);
      }
      candidates.push({
        key,
        tokens: normalizeLiveActivityTeamTokens(name),
        rating,
      });
    });
  });

  return {
    exactByKey,
    candidates,
    defaultElo: Number.isFinite(defaultElo) ? defaultElo : 1000,
  };
}

function lookupLiveActivityTeamRating(teamName) {
  const lookup = liveActivityTeamRatingLookup;
  const key = normalizeLiveActivityTeamKey(teamName);
  if (!lookup || !key) {
    return null;
  }

  if (lookup.exactByKey.has(key)) {
    return lookup.exactByKey.get(key);
  }

  const aliasedKey = LIVE_ACTIVITY_TEAM_RATING_ALIAS_MAP[key];
  if (aliasedKey && lookup.exactByKey.has(aliasedKey)) {
    return lookup.exactByKey.get(aliasedKey);
  }

  const sourceTokens = normalizeLiveActivityTeamTokens(teamName);
  let bestRating = null;
  let bestConfidence = 0;

  lookup.candidates.forEach((candidate) => {
    const confidence = liveActivityTeamSimilarity(
      key,
      candidate.key,
      sourceTokens,
      candidate.tokens
    );
    if (confidence > bestConfidence) {
      bestConfidence = confidence;
      bestRating = candidate.rating;
    }
  });

  return bestConfidence >= 0.86 ? bestRating : null;
}

function resolveLiveActivityTeamRating(teamName) {
  const exactRating = lookupLiveActivityTeamRating(teamName);
  if (Number.isFinite(exactRating)) {
    return {
      rating: exactRating,
      usedDefault: false,
    };
  }
  return {
    rating: liveActivityTeamRatingDefaultElo,
    usedDefault: true,
  };
}

function annotateMatchWithLiveActivityTeamRatings(match) {
  if (!match || typeof match !== "object") return match;
  const homeResolution = resolveLiveActivityTeamRating(match.home_team);
  const awayResolution = resolveLiveActivityTeamRating(match.away_team);
  return {
    ...match,
    home_team_score: homeResolution.rating,
    away_team_score: awayResolution.rating,
    total_team_score: homeResolution.rating + awayResolution.rating,
  };
}

function liveActivityTeamScoreTotal(match) {
  const explicitTotal = Number(match && match.total_team_score);
  if (Number.isFinite(explicitTotal)) return explicitTotal;
  const homeTeamScore = Number(match && match.home_team_score);
  const awayTeamScore = Number(match && match.away_team_score);
  const total = (Number.isFinite(homeTeamScore) ? homeTeamScore : 0) +
    (Number.isFinite(awayTeamScore) ? awayTeamScore : 0);
  return Number.isFinite(total) ? total : 0;
}

function buildLiveActivityPremierLeagueTeamLookup(teams) {
  const exactByKey = new Set();
  const candidates = [];

  (Array.isArray(teams) ? teams : []).forEach((team) => {
    const name = String(team || "").trim();
    if (!name) return;
    const key = normalizeLiveActivityTeamKey(name);
    if (!key) return;
    exactByKey.add(key);
    candidates.push({
      key,
      tokens: normalizeLiveActivityTeamTokens(name),
    });
  });

  return {
    exactByKey,
    candidates,
  };
}

function getLiveActivityPremierLeagueTeamLookup() {
  if (!liveActivityPremierLeagueTeamLookup) {
    liveActivityPremierLeagueTeamLookup = buildLiveActivityPremierLeagueTeamLookup(
      LIVE_ACTIVITY_PREMIER_LEAGUE_TEAMS
    );
  }
  return liveActivityPremierLeagueTeamLookup;
}

function isEnglishPremierLeagueTeam(teamName) {
  const key = normalizeLiveActivityTeamKey(teamName);
  if (!key) return false;

  const lookup = getLiveActivityPremierLeagueTeamLookup();
  if (lookup.exactByKey.has(key)) return true;

  const aliasedKey = LIVE_ACTIVITY_TEAM_RATING_ALIAS_MAP[key];
  if (aliasedKey && lookup.exactByKey.has(aliasedKey)) {
    return true;
  }

  const sourceTokens = normalizeLiveActivityTeamTokens(teamName);
  let bestConfidence = 0;

  lookup.candidates.forEach((candidate) => {
    const confidence = liveActivityTeamSimilarity(
      key,
      candidate.key,
      sourceTokens,
      candidate.tokens
    );
    if (confidence > bestConfidence) {
      bestConfidence = confidence;
    }
  });

  return bestConfidence >= 0.86;
}

async function ensureLiveActivityTeamRatingCache(nowMs = Date.now()) {
  if (
    liveActivityTeamRatingLookup &&
    nowMs - liveActivityTeamRatingFetchedAtMs < LIVE_ACTIVITY_TEAM_RANKING_CACHE_TTL_MS
  ) {
    return;
  }

  if (
    liveActivityTeamRatingRefreshPromise &&
    typeof liveActivityTeamRatingRefreshPromise.then === "function"
  ) {
    await liveActivityTeamRatingRefreshPromise;
    return;
  }

  if (
    !liveActivityTeamRatingLookup &&
    liveActivityTeamRatingLastAttemptAtMs > 0 &&
    nowMs - liveActivityTeamRatingLastAttemptAtMs < LIVE_ACTIVITY_TEAM_RANKING_RETRY_MS
  ) {
    return;
  }

  liveActivityTeamRatingLastAttemptAtMs = nowMs;
  liveActivityTeamRatingRefreshPromise = (async () => {
    try {
      const [settings, teams] = await Promise.all([
        fetchJsonWithTimeout(`${apiBaseURL}/teams/config`),
        fetchJsonWithTimeout(`${apiBaseURL}/teams?source=merged`),
      ]);
      const defaultElo = Number(settings && settings.default_elo);
      liveActivityTeamRatingDefaultElo = Number.isFinite(defaultElo) ? defaultElo : 1000;
      liveActivityTeamRatingLookup = buildLiveActivityTeamRatingLookup(
        Array.isArray(teams) ? teams : [],
        liveActivityTeamRatingDefaultElo
      );
      liveActivityTeamRatingFetchedAtMs = Date.now();
    } catch (error) {
      console.warn(
        "[MatchMonitor] Failed to refresh live activity team ratings:",
        error && error.message ? error.message : error
      );
      if (!liveActivityTeamRatingLookup) {
        liveActivityTeamRatingLookup = buildLiveActivityTeamRatingLookup(
          [],
          liveActivityTeamRatingDefaultElo
        );
      }
    } finally {
      liveActivityTeamRatingRefreshPromise = null;
    }
  })();

  await liveActivityTeamRatingRefreshPromise;
}

function evaluateMatchRelevance(match, nowMs = Date.now()) {
  const status = match ? match.score_status : null;

  if (isLiveMatchStatus(status)) {
    return {
      relevant: true,
      reason: "live_status",
      kickoff_delta_ms: null,
    };
  }

  // Avoid starting monitoring for matches already marked complete.
  if (isFinishedMatchStatus(status) || isPenaltyShootoutStatus(status)) {
    return {
      relevant: false,
      reason: "terminal_status",
      kickoff_delta_ms: null,
    };
  }

  // Monitor upcoming fixtures shortly before kickoff.
  const kickoffMs = parseMatchDateTimeMs(match);
  if (!Number.isFinite(kickoffMs)) {
    return {
      relevant: false,
      reason: "invalid_kickoff_time",
      kickoff_delta_ms: null,
    };
  }

  const diffMs = kickoffMs - nowMs;
  if (diffMs > 0 && diffMs <= UPCOMING_MONITOR_WINDOW_MS) {
    return {
      relevant: true,
      reason: "upcoming_window",
      kickoff_delta_ms: diffMs,
    };
  }

  if (diffMs <= 0) {
    return {
      relevant: false,
      reason: "kickoff_passed_without_live_status",
      kickoff_delta_ms: diffMs,
    };
  }

  return {
    relevant: false,
    reason: "outside_upcoming_window",
    kickoff_delta_ms: diffMs,
  };
}

function isMatchRelevant(match, nowMs = Date.now()) {
  return evaluateMatchRelevance(match, nowMs).relevant;
}

function evaluateStopMonitoringDecision(match, monitorState, nowMs = Date.now()) {
  if (!monitorState) {
    return {
      stop: true,
      reason: "missing_monitor_state",
    };
  }

  if (isLiveMatchStatus(match && match.score_status)) {
    return {
      stop: false,
      reason: "status_live",
    };
  }
  if (isFinishedMatchStatus(match && match.score_status)) {
    return {
      stop: false,
      reason: "status_finished",
    };
  }
  if (isPenaltyShootoutStatus(match && match.score_status)) {
    return {
      stop: false,
      reason: "status_penalties",
    };
  }

  const kickoffMs = parseMatchDateTimeMs(match) || monitorState.kickoffTimeMs;
  if (Number.isFinite(kickoffMs)) {
    // Keep polling for a long grace period in case upstream status temporarily disappears.
    const deadlineMs = kickoffMs + MAX_MONITOR_DURATION_MS;
    return {
      stop: nowMs > deadlineMs,
      reason: nowMs > deadlineMs ? "kickoff_window_expired" : "within_kickoff_window",
      deadline_ms: deadlineMs,
    };
  }

  const fallbackDeadlineMs = monitorState.startedAtMs + MAX_MONITOR_DURATION_MS;
  return {
    stop: nowMs > fallbackDeadlineMs,
    reason: nowMs > fallbackDeadlineMs ? "monitor_window_expired" : "within_monitor_window",
    deadline_ms: fallbackDeadlineMs,
  };
}

function shouldStopMonitoringAsIrrelevant(match, monitorState, nowMs = Date.now()) {
  return evaluateStopMonitoringDecision(match, monitorState, nowMs).stop;
}

function evaluateKickoffDecision(oldMatch, newMatch, lifecycle, nowMs = Date.now()) {
  if (!lifecycle) {
    return { emit: false, reason: "missing_lifecycle" };
  }
  if (lifecycle.kickoffEmitted) {
    return { emit: false, reason: "kickoff_already_emitted" };
  }
  if (!isLiveMatchStatus(newMatch && newMatch.score_status)) {
    return { emit: false, reason: "new_status_not_live" };
  }

  // Kick-off should be a transition into live status.
  if (isLiveMatchStatus(oldMatch && oldMatch.score_status)) {
    return { emit: false, reason: "old_status_already_live" };
  }

  const minute = parseStatusMinute(newMatch && newMatch.score_status);
  if (minute !== null) {
    if (minute <= KICKOFF_STATUS_MINUTE_THRESHOLD) {
      return {
        emit: true,
        reason: "live_minute_within_threshold",
        status_minute: minute,
      };
    }
    return {
      emit: false,
      reason: "live_minute_above_threshold",
      status_minute: minute,
    };
  }

  const normalizedStatus = normalizeStatusToken(newMatch && newMatch.score_status);
  if (normalizedStatus === "LIVE") {
    const homeScore = toNumericScore(newMatch && newMatch.home_score) || 0;
    const awayScore = toNumericScore(newMatch && newMatch.away_score) || 0;
    if (homeScore !== 0 || awayScore !== 0) {
      return {
        emit: false,
        reason: "live_non_zero_score",
      };
    }

    const kickoffMs = parseMatchDateTimeMs(newMatch);
    if (Number.isFinite(kickoffMs)) {
      const elapsedMs = nowMs - kickoffMs;
      const withinWindow =
        elapsedMs >= -UPCOMING_MONITOR_WINDOW_MS && elapsedMs <= UPCOMING_MONITOR_WINDOW_MS;
      return {
        emit: withinWindow,
        reason: withinWindow ? "live_zero_zero_within_window" : "live_zero_zero_outside_window",
        kickoff_elapsed_ms: elapsedMs,
      };
    }

    return { emit: true, reason: "live_zero_zero_without_kickoff_time" };
  }

  // Never treat HT/ET/PENS as kick-off.
  return { emit: false, reason: "live_status_not_kickoff_token" };
}

function goalEventAssister(assists, goalTimeLabel) {
  if (!Array.isArray(assists) || assists.length === 0) return null;
  if (!goalTimeLabel) return null;

  for (const assister of assists) {
    if (Array.isArray(assister.assist_times) && assister.assist_times.includes(goalTimeLabel)) {
      return assister.player || null;
    }
  }

  return null;
}

function flattenGoalEvents(goalScorers, assists, team) {
  if (!Array.isArray(goalScorers) || goalScorers.length === 0) return [];

  const events = [];
  let sourceOrder = 0;

  for (const scorer of goalScorers) {
    const player = scorer && scorer.player ? scorer.player : null;

    const regularTimes = Array.isArray(scorer && scorer.goal_times)
      ? scorer.goal_times
      : [];
    for (const rawTime of regularTimes) {
      const goalTime = String(rawTime || "").trim() || null;
      events.push({
        team,
        player,
        goalTime,
        ownGoal: false,
        assister: goalEventAssister(assists, goalTime),
        minute: parseStatusMinute(goalTime),
        sourceOrder: sourceOrder++,
      });
    }

    const ownGoalTimes = Array.isArray(scorer && scorer.own_goal_times)
      ? scorer.own_goal_times
      : [];
    for (const rawTime of ownGoalTimes) {
      const goalTime = String(rawTime || "").trim() || null;
      events.push({
        team,
        player,
        goalTime,
        ownGoal: true,
        assister: null,
        minute: parseStatusMinute(goalTime),
        sourceOrder: sourceOrder++,
      });
    }
  }

  return events;
}

function buildGoalTimeline(match) {
  const home = flattenGoalEvents(match && match.home_goal_scorers, match && match.home_assists, "home");
  const away = flattenGoalEvents(match && match.away_goal_scorers, match && match.away_assists, "away");
  const events = [...home, ...away];

  events.sort((lhs, rhs) => {
    const lhsMinute = Number.isFinite(lhs.minute) ? lhs.minute : Number.MAX_SAFE_INTEGER;
    const rhsMinute = Number.isFinite(rhs.minute) ? rhs.minute : Number.MAX_SAFE_INTEGER;
    if (lhsMinute !== rhsMinute) return lhsMinute - rhsMinute;
    return lhs.sourceOrder - rhs.sourceOrder;
  });

  const signatureCounts = new Map();
  events.forEach((event) => {
    const baseKey = [
      event.team || "",
      event.goalTime || "",
      event.player || "",
      event.ownGoal ? "OG" : "G",
    ].join("|");
    const nextCount = (signatureCounts.get(baseKey) || 0) + 1;
    signatureCounts.set(baseKey, nextCount);
    event.signature = `${baseKey}|${nextCount}`;
  });

  return events;
}

function diffGoalEvents(oldMatch, newMatch) {
  const oldTimeline = buildGoalTimeline(oldMatch || {});
  const newTimeline = buildGoalTimeline(newMatch || {});

  const oldCounts = new Map();
  oldTimeline.forEach((event) => {
    oldCounts.set(event.signature, (oldCounts.get(event.signature) || 0) + 1);
  });

  const newEvents = [];
  newTimeline.forEach((event) => {
    const remaining = oldCounts.get(event.signature) || 0;
    if (remaining > 0) {
      oldCounts.set(event.signature, remaining - 1);
      return;
    }
    newEvents.push(event);
  });

  return newEvents;
}

function diffRemovedGoalEvents(oldMatch, newMatch) {
  return diffGoalEvents(newMatch || {}, oldMatch || {});
}

function sameScoreSnapshot(lhs, rhs) {
  if (!lhs || !rhs) return false;
  return lhs.home_score === rhs.home_score && lhs.away_score === rhs.away_score;
}

function detectScoreReversion(oldMatch, newMatch) {
  const previous = scoreSnapshot(oldMatch || {});
  const current = scoreSnapshot(newMatch || {});
  const homeDelta = current.home_score - previous.home_score;
  const awayDelta = current.away_score - previous.away_score;
  const totalGoalsRemoved = Math.max(0, -homeDelta) + Math.max(0, -awayDelta);

  if (totalGoalsRemoved !== 1) {
    return null;
  }

  let affectedTeam = null;
  if (homeDelta === -1 && awayDelta === 0) {
    affectedTeam = "home";
  } else if (homeDelta === 0 && awayDelta === -1) {
    affectedTeam = "away";
  }
  if (!affectedTeam) {
    return null;
  }

  const removedGoalEvents = diffRemovedGoalEvents(oldMatch || {}, newMatch || {})
    .filter((event) => event.team === affectedTeam)
    .sort((lhs, rhs) => {
      const leftMinute = Number.isFinite(lhs.minute) ? lhs.minute : -1;
      const rightMinute = Number.isFinite(rhs.minute) ? rhs.minute : -1;
      if (leftMinute !== rightMinute) return rightMinute - leftMinute;
      return rhs.sourceOrder - lhs.sourceOrder;
    });
  const removedGoal = removedGoalEvents[0] || null;

  return {
    baseline: previous,
    reverted: current,
    affectedTeam,
    removedGoal,
  };
}

function updateScoreReversionState(monitorState, oldMatch, newMatch, nowMs = Date.now()) {
  const current = scoreSnapshot(newMatch || {});
  const directReversion = detectScoreReversion(oldMatch, newMatch);
  const previousState =
    monitorState && monitorState.scoreReversionState && typeof monitorState.scoreReversionState === "object"
      ? monitorState.scoreReversionState
      : null;

  if (directReversion) {
    monitorState.scoreReversionState = {
      baseline: directReversion.baseline,
      reverted: directReversion.reverted,
      affectedTeam: directReversion.affectedTeam,
      removedGoal: directReversion.removedGoal,
      consecutivePolls: 1,
      firstDetectedAtMs: nowMs,
      lastDetectedAtMs: nowMs,
      confirmedAtMs: null,
    };
    return monitorState.scoreReversionState;
  }

  if (!previousState) {
    return null;
  }

  if (sameScoreSnapshot(current, previousState.baseline)) {
    monitorState.scoreReversionState = null;
    return null;
  }

  if (sameScoreSnapshot(current, previousState.reverted)) {
    previousState.consecutivePolls = Number(previousState.consecutivePolls || 0) + 1;
    previousState.lastDetectedAtMs = nowMs;
    monitorState.scoreReversionState = previousState;
    return previousState;
  }

  monitorState.scoreReversionState = null;
  return null;
}

function escapedRegexFragment(value) {
  return String(value || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function normalizeLiveTextEntryText(value) {
  return String(value || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function entryMinuteWithinWindow(entryMinute, targetMinute, tolerance = 2) {
  if (!Number.isFinite(targetMinute)) return true;
  if (!Number.isFinite(entryMinute)) return false;
  return Math.abs(entryMinute - targetMinute) <= tolerance;
}

function matchesVarDecisionScoreline(entryText, newMatch, revertedSnapshot) {
  const homeTeam = String(newMatch && newMatch.home_team ? newMatch.home_team : "").trim();
  const awayTeam = String(newMatch && newMatch.away_team ? newMatch.away_team : "").trim();
  const homeScore = Number(revertedSnapshot && revertedSnapshot.home_score);
  const awayScore = Number(revertedSnapshot && revertedSnapshot.away_score);
  if (!homeTeam || !awayTeam || !Number.isFinite(homeScore) || !Number.isFinite(awayScore)) {
    return false;
  }

  const fragments = [
    escapedRegexFragment(homeTeam.toLowerCase()),
    String(homeScore),
    "-",
    String(awayScore),
    escapedRegexFragment(awayTeam.toLowerCase()),
  ];
  return new RegExp(fragments.join("\\s*")).test(entryText);
}

function buildVarDisallowedGoalEvent(matchId, newMatch, confirmation, reversionState) {
  const removedGoal = reversionState && reversionState.removedGoal ? reversionState.removedGoal : null;
  const goalTime =
    (removedGoal && removedGoal.goalTime) ||
    (confirmation && confirmation.goalMinuteLabel) ||
    (confirmation && confirmation.decisionMinuteLabel) ||
    null;
  const scorer = confirmation && confirmation.scorer ? confirmation.scorer : removedGoal && removedGoal.player;
  const assister =
    removedGoal && removedGoal.assister ? removedGoal.assister : null;
  const team =
    confirmation && confirmation.team
      ? confirmation.team
      : reversionState && reversionState.affectedTeam
        ? reversionState.affectedTeam
        : null;
  const current = scoreSnapshot(newMatch || {});

  return {
    type: "goal",
    team,
    title: goalTime ? `Goal disallowed by VAR ${goalTime}` : "Goal disallowed by VAR",
    body: formatScoreline(newMatch, current.home_score, current.away_score),
    goalTime,
    scorer: scorer || null,
    assister,
    ownGoal: false,
    disallowedByVar: true,
    varDecisionTime:
      confirmation && confirmation.decisionMinuteLabel ? confirmation.decisionMinuteLabel : null,
    eventKey: [
      "var_disallowed",
      String(team || ""),
      String(goalTime || ""),
      String(scorer || ""),
      String(matchId || ""),
    ].join(":"),
  };
}

async function confirmVarDisallowedGoal(matchId, newMatch, reversionState, options = {}) {
  if (!newMatch || !reversionState) return null;
  if (Number(reversionState.consecutivePolls || 0) < SCORE_REVERSION_CONFIRMATION_POLLS) {
    return null;
  }
  if (Number.isFinite(Number(reversionState.confirmedAtMs))) {
    return null;
  }

  const targetGoalMinute = Number(
    reversionState.removedGoal && Number.isFinite(reversionState.removedGoal.minute)
      ? reversionState.removedGoal.minute
      : null
  );
  const expectedScorer = String(
    reversionState.removedGoal && reversionState.removedGoal.player
      ? reversionState.removedGoal.player
      : ""
  ).trim();
  const revertedSnapshot = reversionState.reverted || scoreSnapshot(newMatch || {});

  let liveText;
  if (Array.isArray(newMatch.live_text_entries) && newMatch.live_text_entries.length > 0) {
    liveText = { entries: newMatch.live_text_entries };
  } else {
    if (!newMatch.details_url) return null;
    try {
      const fetchLiveText =
        options && typeof options.fetchLiveText === "function"
          ? options.fetchLiveText
          : fetchBbcLiveTextEntriesByDetailsUrl;
      liveText = await fetchLiveText(newMatch.details_url);
    } catch (error) {
      logDecision("var_disallowed_confirmation", {
        match_id: matchId,
        result: "fetch_error",
        error: error && error.message ? error.message : String(error),
      });
      return null;
    }
  }

  const entries = Array.isArray(liveText && liveText.entries) ? liveText.entries : [];
  if (entries.length === 0) {
    logDecision("var_disallowed_confirmation", {
      match_id: matchId,
      result: "no_live_text_entries",
    });
    return null;
  }

  let overturnedEntry = null;
  let noGoalEntry = null;

  entries.forEach((entry) => {
    if (!entry || !entry.text) return;
    const normalizedText = normalizeLiveTextEntryText(entry.text);
    if (
      normalizedText.includes("goal overturned by var") &&
      (!expectedScorer || normalizedText.includes(normalizeLiveTextEntryText(expectedScorer))) &&
      entryMinuteWithinWindow(entry.minute_value, targetGoalMinute, 2)
    ) {
      if (!overturnedEntry) overturnedEntry = entry;
      return;
    }

    if (
      normalizedText.includes("var decision: no goal") &&
      matchesVarDecisionScoreline(normalizedText, newMatch, revertedSnapshot) &&
      entryMinuteWithinWindow(
        entry.minute_value,
        Number.isFinite(targetGoalMinute) ? targetGoalMinute + VAR_DECISION_REVIEW_WINDOW_MINUTES : null,
        VAR_DECISION_REVIEW_WINDOW_MINUTES
      )
    ) {
      if (!noGoalEntry) noGoalEntry = entry;
    }
  });

  if (!overturnedEntry && !noGoalEntry) {
    logDecision("var_disallowed_confirmation", {
      match_id: matchId,
      result: "no_matching_live_text",
      expected_scorer: expectedScorer || null,
      reverted_home_score: revertedSnapshot.home_score,
      reverted_away_score: revertedSnapshot.away_score,
    });
    return null;
  }

  const scorerMatch =
    overturnedEntry && overturnedEntry.text
      ? overturnedEntry.text.match(/^GOAL OVERTURNED BY VAR:\s+(.+?)\s+\((.+?)\)\s+scores\b/i)
      : null;
  const scorer = scorerMatch && scorerMatch[1] ? scorerMatch[1].trim() : expectedScorer || null;
  const teamName = scorerMatch && scorerMatch[2] ? scorerMatch[2].trim() : null;
  const team =
    teamName && String(newMatch.home_team || "").trim() === teamName
      ? "home"
      : teamName && String(newMatch.away_team || "").trim() === teamName
        ? "away"
        : reversionState.affectedTeam;

  const goalMinuteLabel =
    reversionState.removedGoal && reversionState.removedGoal.goalTime
      ? reversionState.removedGoal.goalTime
      : overturnedEntry && overturnedEntry.minute
        ? overturnedEntry.minute
        : null;
  const decisionMinuteLabel =
    noGoalEntry && noGoalEntry.minute
      ? noGoalEntry.minute
      : overturnedEntry && overturnedEntry.minute
        ? overturnedEntry.minute
        : null;

  reversionState.confirmedAtMs = Date.now();
  logDecision("var_disallowed_confirmation", {
    match_id: matchId,
    result: "confirmed",
    goal_minute: goalMinuteLabel || null,
    decision_minute: decisionMinuteLabel || null,
    scorer: scorer || null,
    team: team || null,
  });

  return {
    team,
    scorer,
    goalMinuteLabel,
    decisionMinuteLabel,
  };
}

function buildMatchEvents(oldMatch, newMatch, monitorState, nowMs = Date.now(), context = null) {
  const events = [];
  const lifecycle = monitorState.lifecycle;
  const goalTimelineBacklog = Array.isArray(monitorState.goalTimelineBacklog)
    ? monitorState.goalTimelineBacklog
    : [];
  const unresolvedGoalCount = Number.isFinite(monitorState.unresolvedGoalCount)
    ? Math.max(0, Math.floor(monitorState.unresolvedGoalCount))
    : 0;
  monitorState.goalTimelineBacklog = goalTimelineBacklog;
  monitorState.unresolvedGoalCount = unresolvedGoalCount;
  const oldStatus = normalizeStatusToken(oldMatch && oldMatch.score_status);
  const newStatus = normalizeStatusToken(newMatch && newMatch.score_status);

  // Kick-off
  const kickoffDecision = evaluateKickoffDecision(oldMatch, newMatch, lifecycle, nowMs);
  if (kickoffDecision.emit) {
    events.push({
      type: "kickoff",
      title: "Kick off",
      body: `${newMatch.home_team} vs ${newMatch.away_team}`,
      eventKey: "kickoff",
    });
    lifecycle.kickoffEmitted = true;
  }

  // Half-time
  if (!lifecycle.halftimeEmitted && newStatus === "HT" && oldStatus !== "HT") {
    const homeScore = toNumericScore(newMatch.home_score) ?? countGoals(newMatch.home_goal_scorers);
    const awayScore = toNumericScore(newMatch.away_score) ?? countGoals(newMatch.away_goal_scorers);
    events.push({
      type: "halftime",
      title: "HT",
      body: formatScoreline(newMatch, homeScore, awayScore),
      eventKey: "halftime",
    });
    lifecycle.halftimeEmitted = true;
  }

  // Full-time (including penalties)
  const newIsFulltime = isFinishedMatchStatus(newStatus) || isPenaltyShootoutStatus(newStatus);
  if (!lifecycle.fulltimeEmitted && newIsFulltime && oldStatus !== newStatus) {
    const homeScore = toNumericScore(newMatch.home_score) ?? countGoals(newMatch.home_goal_scorers);
    const awayScore = toNumericScore(newMatch.away_score) ?? countGoals(newMatch.away_goal_scorers);
    let ftBody = formatScoreline(newMatch, homeScore, awayScore);

    if (newStatus === "AET") {
      ftBody += " (AET)";
    }
    if (isPenaltyShootoutStatus(newStatus) && newMatch.penalty_result) {
      ftBody += ` (${newMatch.penalty_result} on penalties)`;
    }

    events.push({
      type: "fulltime",
      title: newStatus === "AET" ? "AET" : isPenaltyShootoutStatus(newStatus) ? "FT (Pens)" : "FT",
      body: ftBody,
      eventKey: `fulltime:${newStatus || "FT"}`,
    });
    lifecycle.fulltimeEmitted = true;
  }

  // Goals: emit one notification per newly discovered goal event.
  const previousSnapshot = scoreSnapshot(oldMatch || {});
  const currentSnapshot = scoreSnapshot(newMatch || {});
  const newlyDiscoveredGoalEvents = diffGoalEvents(oldMatch || {}, newMatch || {});
  if (newlyDiscoveredGoalEvents.length > 0) {
    goalTimelineBacklog.push(...newlyDiscoveredGoalEvents);
    if (goalTimelineBacklog.length > GOAL_TIMELINE_BACKLOG_LIMIT) {
      goalTimelineBacklog.splice(0, goalTimelineBacklog.length - GOAL_TIMELINE_BACKLOG_LIMIT);
    }
  }

  const homeScoreDelta = currentSnapshot.home_score - previousSnapshot.home_score;
  const awayScoreDelta = currentSnapshot.away_score - previousSnapshot.away_score;
  const expectedGoalDelta = Math.max(0, homeScoreDelta) + Math.max(0, awayScoreDelta);
  if (expectedGoalDelta > 0) {
    monitorState.unresolvedGoalCount += expectedGoalDelta;
  }

  let newGoalEvents = [];
  if (monitorState.unresolvedGoalCount > 0 && goalTimelineBacklog.length > 0) {
    const emitCount = Math.min(monitorState.unresolvedGoalCount, goalTimelineBacklog.length);
    // Use the latest timeline entries so delayed backfills do not replay stale historical goals.
    newGoalEvents = goalTimelineBacklog.splice(goalTimelineBacklog.length - emitCount, emitCount);
    monitorState.unresolvedGoalCount = Math.max(0, monitorState.unresolvedGoalCount - emitCount);
  }

  let newHomeGoalsCount = 0;
  let newAwayGoalsCount = 0;
  newGoalEvents.forEach((goal) => {
    if (goal.team === "home") {
      newHomeGoalsCount += 1;
    } else {
      newAwayGoalsCount += 1;
    }
  });

  // Start from a base score that ensures emitted goal events reconcile exactly
  // to the current score (prevents impossible inflated scorelines).
  let runningHomeScore = currentSnapshot.home_score - newHomeGoalsCount;
  let runningAwayScore = currentSnapshot.away_score - newAwayGoalsCount;
  if (
    !Number.isFinite(runningHomeScore) ||
    !Number.isFinite(runningAwayScore) ||
    runningHomeScore < 0 ||
    runningAwayScore < 0
  ) {
    runningHomeScore = previousSnapshot.home_score;
    runningAwayScore = previousSnapshot.away_score;
  }

  for (const goal of newGoalEvents) {
    if (goal.team === "home") {
      runningHomeScore += 1;
    } else {
      runningAwayScore += 1;
    }

    let goalTitle = goal.ownGoal ? "Own goal" : "Goal";
    if (goal.goalTime) goalTitle += ` ${goal.goalTime}`;

    let goalBody = formatScoreline(newMatch, runningHomeScore, runningAwayScore);
    if (goal.player) {
      if (goal.ownGoal) {
        goalBody += ` (${goal.player}, own goal)`;
      } else {
        goalBody += ` (${goal.player}`;
        if (goal.assister) {
          goalBody += `, assist: ${goal.assister}`;
        }
        goalBody += ")";
      }
    }

    events.push({
      type: "goal",
      team: goal.team,
      title: goalTitle,
      body: goalBody,
      goalTime: goal.goalTime,
      scorer: goal.player,
      assister: goal.assister,
      ownGoal: goal.ownGoal,
      eventKey: goal.signature,
    });
  }

  // Red cards
  const oldHomeRedCards = countRedCards(oldMatch && oldMatch.home_red_cards);
  const newHomeRedCards = countRedCards(newMatch && newMatch.home_red_cards);
  const oldAwayRedCards = countRedCards(oldMatch && oldMatch.away_red_cards);
  const newAwayRedCards = countRedCards(newMatch && newMatch.away_red_cards);

  if (newHomeRedCards > oldHomeRedCards) {
    const lastRedCard = getLatestRedCard(newMatch.home_red_cards);
    const redCardTime = getLatestRedCardTime(newMatch.home_red_cards);
    let redCardTitle = "Red card";
    if (redCardTime) redCardTitle += ` ${redCardTime}`;
    events.push({
      type: "redcard",
      team: "home",
      title: redCardTitle,
      body: `${newMatch.home_team}${lastRedCard ? ` (${lastRedCard})` : ""}`,
      redCardTime,
      player: lastRedCard,
      eventKey: `red:${redCardTime || "unknown"}:${lastRedCard || "unknown"}:home`,
    });
  }

  if (newAwayRedCards > oldAwayRedCards) {
    const lastRedCard = getLatestRedCard(newMatch.away_red_cards);
    const redCardTime = getLatestRedCardTime(newMatch.away_red_cards);
    let redCardTitle = "Red card";
    if (redCardTime) redCardTitle += ` ${redCardTime}`;
    events.push({
      type: "redcard",
      team: "away",
      title: redCardTitle,
      body: `${newMatch.away_team}${lastRedCard ? ` (${lastRedCard})` : ""}`,
      redCardTime,
      player: lastRedCard,
      eventKey: `red:${redCardTime || "unknown"}:${lastRedCard || "unknown"}:away`,
    });
  }

  if (context) {
    logDecision("event_detection", {
      match_id: context.matchId,
      home_team: newMatch.home_team,
      away_team: newMatch.away_team,
      old_status: oldStatus || null,
      new_status: newStatus || null,
      kickoff_emit: kickoffDecision.emit,
      kickoff_reason: kickoffDecision.reason,
      kickoff_status_minute: kickoffDecision.status_minute || null,
      new_goal_events: newGoalEvents.length,
      emitted_event_types: events.map((event) => event.type),
      lifecycle_after: {
        kickoff: lifecycle.kickoffEmitted,
        halftime: lifecycle.halftimeEmitted,
        fulltime: lifecycle.fulltimeEmitted,
      },
    });
  }

  return events;
}

function buildNotificationId(user, matchId, event) {
  const parts = [
    String(user && user.deviceToken ? user.deviceToken : "unknown-device"),
    String(matchId || "unknown-match"),
    String(event && event.type ? event.type : "unknown"),
  ];

  if (event && event.type === "goal") {
    parts.push(
      String(event.team || ""),
      String(event.goalTime || ""),
      String(event.scorer || ""),
      String(event.ownGoal ? "og" : "g"),
      String(event.eventKey || "")
    );
  } else if (event && event.type === "redcard") {
    parts.push(
      String(event.team || ""),
      String(event.redCardTime || ""),
      String(event.player || ""),
      String(event.eventKey || "")
    );
  } else if (event && event.eventKey) {
    parts.push(String(event.eventKey));
  }

  return parts.join(":");
}

function scoreSnapshot(match) {
  const homeScoreFromPayload = toNumericScore(match && match.home_score);
  const awayScoreFromPayload = toNumericScore(match && match.away_score);
  return {
    home_score: Number.isFinite(homeScoreFromPayload)
      ? homeScoreFromPayload
      : countGoals(match && match.home_goal_scorers),
    away_score: Number.isFinite(awayScoreFromPayload)
      ? awayScoreFromPayload
      : countGoals(match && match.away_goal_scorers),
    score_status: String(match && match.score_status ? match.score_status : "").trim() || null,
  };
}

function aggregateScoreSuffix(match, homeScore, awayScore) {
  const aggregateHomeScore = toNumericScore(match && match.aggregate_home_score);
  const aggregateAwayScore = toNumericScore(match && match.aggregate_away_score);
  if (!Number.isFinite(aggregateHomeScore) || !Number.isFinite(aggregateAwayScore)) {
    return "";
  }
  const liveHomeScore = toNumericScore(homeScore);
  const liveAwayScore = toNumericScore(awayScore);
  const hasLiveScoreline =
    Number.isFinite(liveHomeScore) &&
    Number.isFinite(liveAwayScore) &&
    (liveHomeScore > 0 || liveAwayScore > 0);
  if (aggregateHomeScore === 0 && aggregateAwayScore === 0 && hasLiveScoreline) {
    return "";
  }
  return ` (agg: ${aggregateHomeScore}-${aggregateAwayScore})`;
}

function formatScoreline(match, homeScore, awayScore) {
  return (
    `${match && match.home_team ? match.home_team : "Home"} ${homeScore} - ${awayScore} ` +
    `${match && match.away_team ? match.away_team : "Away"}${aggregateScoreSuffix(match, homeScore, awayScore)}`
  );
}

function buildScoreChangeEvent(oldMatch, newMatch) {
  const previous = scoreSnapshot(oldMatch || {});
  const current = scoreSnapshot(newMatch || {});

  const scoreChanged =
    previous.home_score !== current.home_score ||
    previous.away_score !== current.away_score;
  const statusChanged = previous.score_status !== current.score_status;
  if (!scoreChanged && !statusChanged) {
    return null;
  }

  const statusSuffix = current.score_status ? ` (${current.score_status})` : "";
  return {
    type: "score_update",
    title: "Score update",
    body: `${formatScoreline(newMatch, current.home_score, current.away_score)}${statusSuffix}`,
    eventKey:
      `score:${current.home_score}:${current.away_score}:` +
      `${String(current.score_status || "unknown").toUpperCase()}`,
    scoreChanged,
    statusChanged,
    previous,
    current,
  };
}

function buildMatchHistoryContext(matchId, match) {
  const snapshot = scoreSnapshot(match || {});
  return {
    id: matchId,
    home_team: match && match.home_team ? match.home_team : null,
    away_team: match && match.away_team ? match.away_team : null,
    league: match && match.league ? match.league : null,
    date: match && match.date ? match.date : null,
    time: match && match.time ? match.time : null,
    score_status: snapshot.score_status,
    home_score: snapshot.home_score,
    away_score: snapshot.away_score,
  };
}

async function persistMatchEventHistory(matchId, match, event, source = "match_monitor") {
  try {
    await saveBbcMatchEventHistory({
      match_id: matchId,
      event_type: event && event.type ? event.type : "unknown",
      event_key: event && event.eventKey ? event.eventKey : null,
      title: event && event.title ? event.title : null,
      body: event && event.body ? event.body : null,
      team: event && event.team ? event.team : null,
      scorer: event && event.scorer ? event.scorer : null,
      assister: event && event.assister ? event.assister : null,
      goal_time: event && event.goalTime ? event.goalTime : null,
      red_card_time: event && event.redCardTime ? event.redCardTime : null,
      player: event && event.player ? event.player : null,
      own_goal: Boolean(event && event.ownGoal),
      disallowed_by_var: Boolean(event && event.disallowedByVar),
      var_decision_time: event && event.varDecisionTime ? event.varDecisionTime : null,
      score_changed: Boolean(event && event.scoreChanged),
      status_changed: Boolean(event && event.statusChanged),
      previous: event && event.previous ? event.previous : null,
      current: event && event.current ? event.current : null,
      source,
      match: buildMatchHistoryContext(matchId, match),
    });
  } catch (error) {
    console.warn(
      `[MatchMonitor] Failed to persist event history for match ${matchId}:`,
      error.message || error
    );
  }
}

async function persistNotificationHistory({
  user,
  matchId,
  match,
  event,
  notificationId,
  delayMinutes,
  dispatchMode,
  result,
  error,
  status,
  idempotencySource,
}) {
  const notificationError =
    (result && result.error ? String(result.error) : null) ||
    (error && error.message ? String(error.message) : null);
  const success = Boolean(result && result.success) && !notificationError;
  const statusValue = String(status || (success ? "sent" : "failed")).trim() || "unknown";

  try {
    await saveBbcNotificationHistory({
      match_id: matchId,
      device_token: user && user.deviceToken ? user.deviceToken : "unknown-device",
      notification_id: notificationId || null,
      status: statusValue,
      event_type: event && event.type ? event.type : "unknown",
      event_key: event && event.eventKey ? event.eventKey : null,
      title: event && event.title ? event.title : null,
      body: event && event.body ? event.body : null,
      delay_minutes: Number(delayMinutes || 0),
      dispatch_mode: dispatchMode || "unknown",
      disallowed_by_var: Boolean(event && event.disallowedByVar),
      var_decision_time: event && event.varDecisionTime ? event.varDecisionTime : null,
      environment:
        result && result.environment
          ? result.environment
          : user && user.isDevelopmentBuild
            ? "sandbox"
            : "production",
      apns_result_success: Boolean(result && result.success),
      apns_result_sent_count:
        result && Number.isFinite(result.sent) ? Number(result.sent) : null,
      error: notificationError,
      idempotency_source: idempotencySource || null,
      match: buildMatchHistoryContext(matchId, match),
    });
  } catch (persistError) {
    console.warn(
      `[MatchMonitor] Failed to persist notification history for ${shortDeviceToken(
        user && user.deviceToken
      )}... in match ${matchId}:`,
      persistError.message || persistError
    );
  }
}

let isMonitoring = false;
let dailyMatchesCheckTimer = null;
let cleanupTimer = null;
let liveActivityEvalTimer = null;
let liveActivityEvalInFlight = false;
let dailyMatchesCheckInFlight = false;
let liveActivityStartupKickTimers = [];
let apiBaseURL = "http://localhost:3000/api/v1";

async function runScheduledDailyMatchesCheck(reason = "interval") {
  if (!isMonitoring) return;
  if (dailyMatchesCheckInFlight) {
    console.log(`[MatchMonitor] Skipping overlapping daily match check (${reason})`);
    return;
  }

  dailyMatchesCheckInFlight = true;
  try {
    await checkTodaysMatches();
  } finally {
    dailyMatchesCheckInFlight = false;
  }
}

async function runStartupLiveActivityKick(reason = "startup") {
  if (!isMonitoring) return;
  try {
    await runScheduledDailyMatchesCheck(reason);
  } catch (error) {
    console.warn(
      `[MatchMonitor] Startup kick checkTodaysMatches failed (${reason}):`,
      error && error.message ? error.message : error
    );
  }
  await evaluateAndDispatchLiveActivities({
    forceDispatch: true,
    preserveExistingOnEmpty: true,
    reason,
  });
}

function clearStartupLiveActivityKickTimers() {
  for (const timer of liveActivityStartupKickTimers) {
    clearTimeout(timer);
  }
  liveActivityStartupKickTimers = [];
}

/**
 * Initialize the match monitoring service
 */
function initialize(baseURL = "http://localhost:3000/api/v1") {
  apiBaseURL = baseURL;
  console.log("[MatchMonitor] Initialized with API base URL:", apiBaseURL);
}

/**
 * Start monitoring for match events
 */
function startMonitoring() {
  if (isMonitoring) {
    console.log("[MatchMonitor] Already monitoring");
    return;
  }

  isMonitoring = true;
  console.log("[MatchMonitor] Starting match monitoring");

  // Run an eager startup refresh sequence so Live Activities resume promptly after restarts.
  for (const delayMs of LIVE_ACTIVITY_STARTUP_KICK_DELAYS_MS) {
    if (delayMs <= 0) {
      void runStartupLiveActivityKick("startup_immediate");
      continue;
    }
    const timer = setTimeout(() => {
      liveActivityStartupKickTimers = liveActivityStartupKickTimers.filter((item) => item !== timer);
      void runStartupLiveActivityKick(`startup_retry_${delayMs}ms`);
    }, delayMs);
    liveActivityStartupKickTimers.push(timer);
  }

  // Start daily matches check
  dailyMatchesCheckTimer = setInterval(() => {
    void runScheduledDailyMatchesCheck("interval");
  }, DAILY_MATCHES_CHECK_INTERVAL_MS);

  // Start cleanup timer
  cleanupTimer = setInterval(cleanup, CLEANUP_INTERVAL_MS);

  // Start Live Activity evaluation loop.
  void evaluateAndDispatchLiveActivities();
  liveActivityEvalTimer = setInterval(
    evaluateAndDispatchLiveActivities,
    LIVE_ACTIVITY_EVAL_INTERVAL_MS
  );
}

/**
 * Stop monitoring
 */
function stopMonitoring() {
  isMonitoring = false;
  console.log("[MatchMonitor] Stopping match monitoring");
  clearStartupLiveActivityKickTimers();

  if (dailyMatchesCheckTimer) {
    clearInterval(dailyMatchesCheckTimer);
    dailyMatchesCheckTimer = null;
  }

  if (cleanupTimer) {
    clearInterval(cleanupTimer);
    cleanupTimer = null;
  }

  if (liveActivityEvalTimer) {
    clearInterval(liveActivityEvalTimer);
    liveActivityEvalTimer = null;
  }

  // Cancel all scheduled notifications
  for (const [, timeout] of scheduledNotifications) {
    clearTimeout(timeout);
  }
  scheduledNotifications.clear();
  for (const matchId of Array.from(monitoredMatches.keys())) {
    stopMonitoringMatch(matchId, "monitor_service_stop");
  }
  finishedMatchIds.clear();
  retainedFinishedMatches.clear();
  resetMonitorDiagnostics();
}

/**
 * Check for today's matches and start monitoring relevant ones
 */
async function fetchTodaysMatchesWithPagination(today) {
  const pageSize = 500;
  const maxPages = 50;
  const collected = [];
  const seenMatchIds = new Set();

  for (let page = 1; page <= maxPages; page += 1) {
    const url =
      `${apiBaseURL}/matches?start=${today}&end=${today}` +
      `&page=${page}&page_size=${pageSize}`;

    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`Failed to fetch today's matches page ${page}: ${response.status}`);
    }

    const pageMatches = await response.json();
    if (!Array.isArray(pageMatches)) {
      throw new Error(`Invalid matches response format on page ${page}`);
    }

    pageMatches.forEach((match) => {
      const matchId = match && match.match_details_id ? String(match.match_details_id) : "";
      if (matchId) {
        if (seenMatchIds.has(matchId)) return;
        seenMatchIds.add(matchId);
      }
      collected.push(match);
    });

    const hasMoreHeader = String(response.headers.get("x-has-more") || "")
      .trim()
      .toLowerCase();
    const hasMore = hasMoreHeader === "true";
    if (!hasMore) {
      break;
    }
  }

  return collected;
}

async function fetchTodaysMonitorCandidates(today) {
  const monitorCandidatesUrl = `${apiBaseURL}/monitor/candidates?date=${today}`;
  try {
    const response = await fetch(monitorCandidatesUrl);
    if (!response.ok) {
      throw new Error(`Failed to fetch monitor candidates: ${response.status}`);
    }

    const payload = await response.json();
    if (!payload || typeof payload !== "object" || !Array.isArray(payload.candidates)) {
      throw new Error("Invalid monitor candidates response format");
    }

    const seenMatchIds = new Set();
    const candidates = [];
    payload.candidates.forEach((candidate) => {
      const matchId = candidate && candidate.match_details_id
        ? String(candidate.match_details_id).trim()
        : "";
      if (!matchId) return;
      if (seenMatchIds.has(matchId)) return;
      seenMatchIds.add(matchId);
      candidates.push(candidate);
    });

    return {
      matches: candidates,
      source: "monitor_candidates",
      sourceMeta: payload && payload.source ? payload.source : null,
    };
  } catch (error) {
    logDecision("monitor_candidates_fetch", {
      result: "fallback_to_matches",
      date: today,
      error: error.message || String(error),
    });
    const fallbackMatches = await fetchTodaysMatchesWithPagination(today);
    return {
      matches: fallbackMatches,
      source: "matches_fallback",
      sourceMeta: null,
      fallbackError: error.message || String(error),
    };
  }
}

async function checkTodaysMatches() {
  const today = new Date().toISOString().split("T")[0]; // YYYY-MM-DD

  try {
    const checkStartedAtMs = Date.now();
    const candidatesFetch = await fetchTodaysMonitorCandidates(today);
    const matches = Array.isArray(candidatesFetch.matches) ? candidatesFetch.matches : [];
    const checkSummary = {
      timestamp: new Date(checkStartedAtMs).toISOString(),
      timestamp_ms: checkStartedAtMs,
      date: today,
      candidate_source: candidatesFetch.source || "unknown",
      candidate_source_meta: candidatesFetch.sourceMeta || null,
      candidate_source_fallback_error: candidatesFetch.fallbackError || null,
      matches_total: matches.length,
      matches_considered: 0,
      relevant_matches: 0,
      started_monitoring: 0,
      reconciled_starts: 0,
      already_monitoring: 0,
      skipped_missing_match_id: 0,
      skipped_finished: 0,
      skipped_irrelevant: 0,
      expected_active_match_count: 0,
      actual_active_match_count: 0,
      missing_active_match_count: 0,
      unexpected_active_match_count: 0,
      expected_active_match_ids: [],
      actual_active_match_ids: [],
      missing_active_match_ids: [],
      unexpected_active_match_ids: [],
      coverage_ratio: 1,
      reasons: {},
    };
    const expectedActiveMatches = new Map();

    console.log(`[MatchMonitor] Found ${matches.length} matches for ${today}`);

    for (const match of matches) {
      const matchId = match.match_details_id;
      if (!matchId) {
        console.log(`[MatchMonitor] Skipping match without match_details_id: ${match.home_team} vs ${match.away_team}`);
        checkSummary.skipped_missing_match_id += 1;
        incrementReasonCounter(checkSummary.reasons, "missing_match_id");
        addMonitorDecisionDiagnostic({
          match_id: null,
          home_team: match && match.home_team ? match.home_team : null,
          away_team: match && match.away_team ? match.away_team : null,
          score_status: match && match.score_status ? match.score_status : null,
          relevant: false,
          reason: "missing_match_id",
          action: "skip",
          kickoff_delta_ms: null,
        });
        continue;
      }
      checkSummary.matches_considered += 1;

      // Skip matches we've already fully processed today
      if (finishedMatchIds.has(matchId)) {
        console.log(`[MatchMonitor] Match ${match.home_team} vs ${match.away_team} (${matchId}): already finished, skipping`);
        checkSummary.skipped_finished += 1;
        incrementReasonCounter(checkSummary.reasons, "already_finished");
        addMonitorDecisionDiagnostic({
          match_id: matchId,
          home_team: match && match.home_team ? match.home_team : null,
          away_team: match && match.away_team ? match.away_team : null,
          score_status: match && match.score_status ? match.score_status : null,
          relevant: false,
          reason: "already_finished",
          action: "skip",
          kickoff_delta_ms: null,
        });
        continue;
      }

      const relevanceDecision = evaluateMatchRelevance(match);
      const relevant = relevanceDecision.relevant;
      incrementReasonCounter(checkSummary.reasons, relevanceDecision.reason);
      console.log(`[MatchMonitor] Match ${match.home_team} vs ${match.away_team} (${matchId}): score_status=${match.score_status}, relevant=${relevant}`);
      logDecision("match_relevance", {
        match_id: matchId,
        home_team: match.home_team,
        away_team: match.away_team,
        score_status: match.score_status || null,
        relevant,
        reason: relevanceDecision.reason,
        kickoff_delta_ms: relevanceDecision.kickoff_delta_ms,
      });

      if (relevant) {
        expectedActiveMatches.set(matchId, match);
        checkSummary.relevant_matches += 1;
        if (!monitoredMatches.has(matchId)) {
          console.log(`[MatchMonitor] ✓ Starting to monitor match: ${match.home_team} vs ${match.away_team} (status: ${match.score_status || "none"})`);
          checkSummary.started_monitoring += 1;
          addMonitorDecisionDiagnostic({
            match_id: matchId,
            home_team: match && match.home_team ? match.home_team : null,
            away_team: match && match.away_team ? match.away_team : null,
            score_status: match && match.score_status ? match.score_status : null,
            relevant: true,
            reason: relevanceDecision.reason,
            action: "start_monitoring",
            kickoff_delta_ms: relevanceDecision.kickoff_delta_ms,
          });
          await monitorMatch(matchId, match);
        } else {
          checkSummary.already_monitoring += 1;
          addMonitorDecisionDiagnostic({
            match_id: matchId,
            home_team: match && match.home_team ? match.home_team : null,
            away_team: match && match.away_team ? match.away_team : null,
            score_status: match && match.score_status ? match.score_status : null,
            relevant: true,
            reason: relevanceDecision.reason,
            action: "already_monitoring",
            kickoff_delta_ms: relevanceDecision.kickoff_delta_ms,
          });
          console.log(`[MatchMonitor] Already monitoring: ${match.home_team} vs ${match.away_team}`);
        }
      } else {
        checkSummary.skipped_irrelevant += 1;
        addMonitorDecisionDiagnostic({
          match_id: matchId,
          home_team: match && match.home_team ? match.home_team : null,
          away_team: match && match.away_team ? match.away_team : null,
          score_status: match && match.score_status ? match.score_status : null,
          relevant: false,
          reason: relevanceDecision.reason,
          action: "skip_irrelevant",
          kickoff_delta_ms: relevanceDecision.kickoff_delta_ms,
        });
      }
    }

    const expectedActiveMatchIds = Array.from(expectedActiveMatches.keys()).sort();
    const expectedActiveSet = new Set(expectedActiveMatchIds);
    const preReconcileActualIds = Array.from(monitoredMatches.keys()).sort();
    const preReconcileActualSet = new Set(preReconcileActualIds);
    const missingBeforeReconcile = expectedActiveMatchIds.filter((matchId) => !preReconcileActualSet.has(matchId));
    if (missingBeforeReconcile.length > 0) {
      for (const matchId of missingBeforeReconcile) {
        const match = expectedActiveMatches.get(matchId);
        if (!match) continue;
        addMonitorDecisionDiagnostic({
          match_id: matchId,
          home_team: match && match.home_team ? match.home_team : null,
          away_team: match && match.away_team ? match.away_team : null,
          score_status: match && match.score_status ? match.score_status : null,
          relevant: true,
          reason: "reconcile_missing_monitor",
          action: "reconcile_start_monitoring",
          kickoff_delta_ms: null,
        });
        try {
          await monitorMatch(matchId, match);
          checkSummary.reconciled_starts += 1;
        } catch (reconcileError) {
          addMonitorDecisionDiagnostic({
            match_id: matchId,
            home_team: match && match.home_team ? match.home_team : null,
            away_team: match && match.away_team ? match.away_team : null,
            score_status: match && match.score_status ? match.score_status : null,
            relevant: true,
            reason: "reconcile_start_failed",
            action: "reconcile_error",
            error: reconcileError && reconcileError.message
              ? reconcileError.message
              : String(reconcileError || "unknown error"),
            kickoff_delta_ms: null,
          });
        }
      }
    }

    const actualActiveMatchIds = Array.from(monitoredMatches.keys()).sort();
    const actualActiveSet = new Set(actualActiveMatchIds);
    const missingActiveMatchIds = expectedActiveMatchIds.filter((matchId) => !actualActiveSet.has(matchId));
    const unexpectedActiveMatchIds = actualActiveMatchIds.filter((matchId) => !expectedActiveSet.has(matchId));

    checkSummary.expected_active_match_count = expectedActiveMatchIds.length;
    checkSummary.actual_active_match_count = actualActiveMatchIds.length;
    checkSummary.missing_active_match_count = missingActiveMatchIds.length;
    checkSummary.unexpected_active_match_count = unexpectedActiveMatchIds.length;
    checkSummary.expected_active_match_ids = expectedActiveMatchIds;
    checkSummary.actual_active_match_ids = actualActiveMatchIds;
    checkSummary.missing_active_match_ids = missingActiveMatchIds;
    checkSummary.unexpected_active_match_ids = unexpectedActiveMatchIds;
    checkSummary.coverage_ratio = expectedActiveMatchIds.length === 0
      ? 1
      : (expectedActiveMatchIds.length - missingActiveMatchIds.length) / expectedActiveMatchIds.length;

    logDecision("monitor_coverage", {
      date: today,
      expected_active_match_count: checkSummary.expected_active_match_count,
      actual_active_match_count: checkSummary.actual_active_match_count,
      missing_active_match_count: checkSummary.missing_active_match_count,
      unexpected_active_match_count: checkSummary.unexpected_active_match_count,
      coverage_ratio: checkSummary.coverage_ratio,
      candidate_source: checkSummary.candidate_source,
    });

    monitorDiagnostics.lastCheck = checkSummary;
    monitorDiagnostics.lastError = null;
  } catch (error) {
    console.error("[MatchMonitor] Error checking today's matches:", error.message);
    monitorDiagnostics.lastError = {
      timestamp: nowIsoTimestamp(),
      stage: "check_todays_matches",
      message: error.message || String(error),
    };
  }
}

/**
 * Monitor a specific match for changes
 */
async function monitorMatch(matchId, initialMatch) {
  const seedMatch = await fetchInitialMatchSnapshot(matchId, initialMatch);
  const initialStatus = normalizeStatusToken(seedMatch && seedMatch.score_status);
  const startedAtMs = Date.now();
  const kickoffTimeMs = parseMatchDateTimeMs(seedMatch);
  monitoredMatches.set(matchId, {
    lastState: { ...seedMatch },
    pollTimer: null,
    lastPollTime: startedAtMs,
    startedAtMs,
    kickoffTimeMs,
    history: [],
    unresolvedGoalCount: 0,
    scoreReversionState: null,
    lifecycle: {
      // If the first state is already live, don't send a synthetic delayed kickoff later.
      kickoffEmitted: isLiveMatchStatus(initialStatus),
      halftimeEmitted: initialStatus === "HT",
      fulltimeEmitted: isFinishedMatchStatus(initialStatus) || isPenaltyShootoutStatus(initialStatus),
    },
  });
  appendMonitorHistorySnapshot(monitoredMatches.get(matchId), seedMatch, startedAtMs);
  logDecision("monitor_start", {
    match_id: matchId,
    home_team: seedMatch.home_team,
    away_team: seedMatch.away_team,
    initial_status: seedMatch.score_status || null,
    kickoff_time_ms: kickoffTimeMs,
    kickoff_already_emitted: isLiveMatchStatus(initialStatus),
  });
  addMonitorStartDiagnostic({
    match_id: matchId,
    home_team: seedMatch.home_team || null,
    away_team: seedMatch.away_team || null,
    initial_status: seedMatch.score_status || null,
    kickoff_time_ms: kickoffTimeMs || null,
  });

  // Start polling this match
  pollMatchDetails(matchId);
}

function mergeSnapshotWithFallback(fallbackMatch, payloadMatch) {
  const merged = { ...(fallbackMatch && typeof fallbackMatch === "object" ? fallbackMatch : {}) };
  const payload = payloadMatch && typeof payloadMatch === "object" ? payloadMatch : {};

  Object.entries(payload).forEach(([key, value]) => {
    if (value === undefined) return;
    if (value === null) {
      if (SNAPSHOT_NULL_CLEAR_FIELDS.has(key)) {
        merged[key] = null;
      }
      return;
    }
    if (typeof value === "string" && !String(value).trim()) return;
    merged[key] = value;
  });

  return merged;
}

async function fetchInitialMatchSnapshot(matchId, fallbackMatch) {
  const fallback = fallbackMatch && typeof fallbackMatch === "object" ? fallbackMatch : {};
  const url = `${apiBaseURL}/matches/${matchId}`;

  try {
    const response = await fetch(url);
    if (!response.ok) {
      logDecision("monitor_seed_snapshot", {
        match_id: matchId,
        result: "fallback_response_not_ok",
        status_code: response.status,
      });
      return { ...fallback };
    }

    const payload = await response.json();
    if (!payload || typeof payload !== "object") {
      logDecision("monitor_seed_snapshot", {
        match_id: matchId,
        result: "fallback_invalid_payload",
      });
      return { ...fallback };
    }

    const merged = mergeSnapshotWithFallback(fallback, payload);
    logDecision("monitor_seed_snapshot", {
      match_id: matchId,
      result: "seeded_from_match_details",
      score_status: merged.score_status || null,
      goals_home: countGoals(merged.home_goal_scorers),
      goals_away: countGoals(merged.away_goal_scorers),
    });
    return merged;
  } catch (error) {
    logDecision("monitor_seed_snapshot", {
      match_id: matchId,
      result: "fallback_fetch_error",
      error: error.message || String(error),
    });
    return { ...fallback };
  }
}

/**
 * Poll match details and detect changes
 */
async function pollMatchDetails(matchId) {
  if (!isMonitoring) return;

  const monitorState = monitoredMatches.get(matchId);
  if (!monitorState) return;

  const url = `${apiBaseURL}/matches/${matchId}`;

  try {
    const response = await fetch(url);
    if (!response.ok) {
      console.error(`[MatchMonitor] Failed to fetch match ${matchId}: ${response.status}`);
      scheduleNextPoll(matchId);
      return;
    }

    const currentPayload = await response.json();

    if (!currentPayload || typeof currentPayload !== "object") {
      console.warn(`[MatchMonitor] No match data for ${matchId}`);
      scheduleNextPoll(matchId);
      return;
    }
    const currentMatch = mergeSnapshotWithFallback(monitorState.lastState, currentPayload);

    // Detect changes and trigger notifications
    await detectAndNotifyChanges(matchId, monitorState, monitorState.lastState, currentMatch);

    // Update state
    monitorState.lastState = currentMatch;
    monitorState.lastPollTime = Date.now();
    appendMonitorHistorySnapshot(monitorState, currentMatch, monitorState.lastPollTime);
    logDecision("poll_snapshot", {
      match_id: matchId,
      home_team: currentMatch.home_team,
      away_team: currentMatch.away_team,
      score_status: currentMatch.score_status || null,
      home_score: toNumericScore(currentMatch.home_score),
      away_score: toNumericScore(currentMatch.away_score),
      goals_home: countGoals(currentMatch.home_goal_scorers),
      goals_away: countGoals(currentMatch.away_goal_scorers),
    });

    const statusToken = normalizeStatusToken(currentMatch.score_status);

    // Stop monitoring once the match is finished.
    if (isFinishedMatchStatus(statusToken) || isPenaltyShootoutStatus(statusToken)) {
      console.log(`[MatchMonitor] Match ${matchId} finished (${currentMatch.score_status}), stopping monitoring`);
      logDecision("monitor_stop", {
        match_id: matchId,
        reason: "terminal_status",
        score_status: currentMatch.score_status || null,
      });
      monitorState.finishedAtMs = monitorState.lastPollTime;
      if (monitorState.lifecycle) {
        monitorState.lifecycle.fulltimeAtMs = monitorState.lastPollTime;
      }
      retainFinishedMatchForLiveActivity(matchId, monitorState, monitorState.lastPollTime);
      finishedMatchIds.add(matchId);
      stopMonitoringMatch(matchId, "terminal_status");
      return;
    }

    // Don't prematurely mark finished for transient status regressions.
    const stopDecision = evaluateStopMonitoringDecision(currentMatch, monitorState);
    if (stopDecision.stop) {
      console.log(`[MatchMonitor] Match ${matchId} exceeded monitoring window without a finish status, stopping monitoring`);
      logDecision("monitor_stop", {
        match_id: matchId,
        reason: stopDecision.reason,
        score_status: currentMatch.score_status || null,
        deadline_ms: stopDecision.deadline_ms || null,
      });
      stopMonitoringMatch(matchId, stopDecision.reason);
      return;
    }

    // Schedule next poll
    scheduleNextPoll(matchId);
  } catch (error) {
    console.error(`[MatchMonitor] Error polling match ${matchId}:`, error.message);
    scheduleNextPoll(matchId);
  }
}

/**
 * Schedule the next poll for a match
 */
function scheduleNextPoll(matchId) {
  const monitorState = monitoredMatches.get(matchId);
  if (!monitorState) return;

  if (monitorState.pollTimer) {
    clearTimeout(monitorState.pollTimer);
  }

  monitorState.pollTimer = setTimeout(() => {
    pollMatchDetails(matchId);
  }, POLL_INTERVAL_MS);
}

/**
 * Stop monitoring a specific match
 */
function stopMonitoringMatch(matchId, reason = "unspecified") {
  const monitorState = monitoredMatches.get(matchId);
  if (monitorState && monitorState.pollTimer) {
    clearTimeout(monitorState.pollTimer);
  }
  if (monitorState) {
    addMonitorStopDiagnostic({
      match_id: matchId,
      reason: String(reason || "unspecified"),
      home_team:
        monitorState.lastState && monitorState.lastState.home_team
          ? monitorState.lastState.home_team
          : null,
      away_team:
        monitorState.lastState && monitorState.lastState.away_team
          ? monitorState.lastState.away_team
          : null,
      score_status:
        monitorState.lastState && monitorState.lastState.score_status
          ? monitorState.lastState.score_status
          : null,
      started_at_ms: Number.isFinite(monitorState.startedAtMs) ? monitorState.startedAtMs : null,
      last_poll_time_ms: Number.isFinite(monitorState.lastPollTime) ? monitorState.lastPollTime : null,
    });
  }
  monitoredMatches.delete(matchId);
}

/**
 * Detect changes between old and new match state and trigger notifications
 */
async function detectAndNotifyChanges(matchId, monitorState, oldMatch, newMatch) {
  const nowMs = Date.now();
  const events = buildMatchEvents(oldMatch, newMatch, monitorState, nowMs, { matchId });
  const reversionState = updateScoreReversionState(monitorState, oldMatch, newMatch, nowMs);
  const confirmedVarDisallowedGoal = await confirmVarDisallowedGoal(matchId, newMatch, reversionState);
  if (confirmedVarDisallowedGoal) {
    events.push(buildVarDisallowedGoalEvent(matchId, newMatch, confirmedVarDisallowedGoal, reversionState));
    monitorState.scoreReversionState = null;
  }
  const scoreChangeEvent = buildScoreChangeEvent(oldMatch, newMatch);

  if (scoreChangeEvent) {
    await persistMatchEventHistory(matchId, newMatch, scoreChangeEvent, "score_change_poll");
  }

  if (events.length > 0) {
    console.log(`[MatchMonitor] Detected ${events.length} events for match ${matchId}`);
    for (const event of events) {
      await persistMatchEventHistory(matchId, newMatch, event, "event_detection");
      await sendNotificationForEvent(matchId, newMatch, event);
    }
  }
}

/**
 * Send notification for a match event to all interested users
 */
async function sendNotificationForEvent(matchId, match, event) {
  try {
    // Get all user preferences
    const allUsers = await getAllUserPreferences();
    console.log(`[MatchMonitor] Checking ${allUsers.length} users for ${event.type} event: ${match.home_team} vs ${match.away_team}`);

    // Filter users who should receive this notification
    const interestedUsers = [];
    for (const user of allUsers) {
      const decision = evaluateUserNotificationDecision(user, match, event);
      logDecision("user_eligibility", {
        match_id: matchId,
        event_type: event.type,
        event_key: event.eventKey || null,
        user_device_short: shortDeviceToken(user.deviceToken),
        eligible: decision.shouldNotify,
        reason: decision.reason,
        delay_minutes: decision.delayMinutes,
      });
      if (decision.shouldNotify) {
        interestedUsers.push(user);
      }
    }

    logDecision("event_dispatch_summary", {
      match_id: matchId,
      event_type: event.type,
      event_key: event.eventKey || null,
      users_total: allUsers.length,
      users_interested: interestedUsers.length,
    });

    if (interestedUsers.length === 0) {
      console.log(`[MatchMonitor] ✗ No users interested in ${event.type} event for ${match.home_team} vs ${match.away_team}`);
      return;
    }

    console.log(
      `[MatchMonitor] ✓ Sending ${event.type} notification to ${interestedUsers.length} user(s) for ${match.home_team} vs ${match.away_team}`
    );

    // Send notifications to all interested users (with delays if configured)
    for (const user of interestedUsers) {
      await scheduleNotificationForUser(user, matchId, match, event);
    }
  } catch (error) {
    console.error(`[MatchMonitor] Error sending notifications for event:`, error);
  }
}

/**
 * Determine if a user should be notified about a match event
 */
function evaluateUserNotificationDecision(user, match, event) {
  const prefs = user.preferences || {};
  const delayMinutes = Number(prefs.notificationDelayMinutes || 0);

  // Check if notifications are enabled
  if (!prefs.notificationsEnabled) {
    return {
      shouldNotify: false,
      reason: "notifications_disabled",
      delayMinutes,
    };
  }

  // Check if user has an APNS token
  if (!user.apnsToken) {
    return {
      shouldNotify: false,
      reason: "missing_apns_token",
      delayMinutes,
    };
  }

  // Check event type filter
  if (prefs.notificationEventTypes && prefs.notificationEventTypes.length > 0) {
    if (!prefs.notificationEventTypes.includes(event.type)) {
      return {
        shouldNotify: false,
        reason: "event_type_filtered_out",
        delayMinutes,
      };
    }
  }

  // Check competition filter
  // When notificationUseViewingFilter is true (or absent), use the viewing competition filter.
  // When false, use the dedicated notification competition filter.
  const useViewingFilter = prefs.notificationUseViewingFilter !== false;
  if (useViewingFilter) {
    if (prefs.competitionFilterEnabled && prefs.selectedLeagues && prefs.selectedLeagues.length > 0) {
      if (!prefs.selectedLeagues.includes(match.league)) {
        return {
          shouldNotify: false,
          reason: "league_filtered_by_viewing_preferences",
          delayMinutes,
        };
      }
    }
  } else if (
    prefs.notificationCompetitionFilterEnabled &&
    prefs.notificationSelectedLeagues &&
    prefs.notificationSelectedLeagues.length > 0
  ) {
    if (!prefs.notificationSelectedLeagues.includes(match.league)) {
      return {
        shouldNotify: false,
        reason: "league_filtered_by_notification_preferences",
        delayMinutes,
      };
    }
  }

  // Check channel filter (only applies to fixtures, but we'll use it for consistency)
  if (prefs.channelFilterEnabled && prefs.selectedChannels && prefs.selectedChannels.length > 0) {
    const matchChannels = match.tv_channels || [];
    const hasMatchingChannel = matchChannels.some((ch) => prefs.selectedChannels.includes(ch));
    if (matchChannels.length > 0 && !hasMatchingChannel) {
      return {
        shouldNotify: false,
        reason: "channel_filtered_out",
        delayMinutes,
      };
    }
  }

  // Check EPL teams filter
  if (prefs.englishPremierLeagueTeamsOnly) {
    const homeInPremierLeague = isEnglishPremierLeagueTeam(match && match.home_team);
    const awayInPremierLeague = isEnglishPremierLeagueTeam(match && match.away_team);
    if (!homeInPremierLeague && !awayInPremierLeague) {
      return {
        shouldNotify: false,
        reason: "premier_league_team_filter",
        delayMinutes,
      };
    }
  }

  return {
    shouldNotify: true,
    reason: "eligible",
    delayMinutes,
  };
}

function normalizeTextToken(value) {
  return String(value || "").trim().toLowerCase();
}

function normalizeChannelSelection(selection) {
  const normalized = normalizeTextToken(selection);
  if (!normalized) return "";
  if (normalized.includes("amazon")) return "amazon";
  if (normalized.includes("bbc")) return "bbc";
  if (normalized.includes("itv")) return "itv";
  if (normalized.includes("sky")) return "sky";
  if (normalized.includes("tnt")) return "tnt";
  return normalized;
}

function channelMatchesSelection(channelName, selection) {
  const normalizedChannel = normalizeTextToken(channelName);
  const normalizedSelection = normalizeChannelSelection(selection);
  if (!normalizedChannel || !normalizedSelection) return false;
  if (normalizedSelection === normalizedChannel) return true;
  return normalizedChannel.includes(normalizedSelection);
}

function liveActivityStatusSortBucket(match) {
  const status = match && match.score_status;
  if (isLiveMatchStatus(status)) return 0;
  if (isFinishedMatchStatus(status) || isPenaltyShootoutStatus(status)) return 1;
  return 2;
}

function liveActivityPremierLeagueSortBucket(match) {
  const homeInPremierLeague = isEnglishPremierLeagueTeam(match && match.home_team);
  const awayInPremierLeague = isEnglishPremierLeagueTeam(match && match.away_team);
  if (homeInPremierLeague && awayInPremierLeague) return 0;
  if (homeInPremierLeague || awayInPremierLeague) return 1;
  return 2;
}

function compareLiveActivityMatches(lhs, rhs) {
  const lhsStatusBucket = liveActivityStatusSortBucket(lhs);
  const rhsStatusBucket = liveActivityStatusSortBucket(rhs);
  if (lhsStatusBucket !== rhsStatusBucket) return lhsStatusBucket - rhsStatusBucket;

  const lhsPremierLeagueBucket = liveActivityPremierLeagueSortBucket(lhs);
  const rhsPremierLeagueBucket = liveActivityPremierLeagueSortBucket(rhs);
  if (lhsPremierLeagueBucket !== rhsPremierLeagueBucket) {
    return lhsPremierLeagueBucket - rhsPremierLeagueBucket;
  }

  const lhsTeamScore = liveActivityTeamScoreTotal(lhs);
  const rhsTeamScore = liveActivityTeamScoreTotal(rhs);
  if (lhsTeamScore !== rhsTeamScore) return rhsTeamScore - lhsTeamScore;
  const leftKickoff = Number(parseMatchDateTimeMs(lhs) || 0);
  const rightKickoff = Number(parseMatchDateTimeMs(rhs) || 0);
  if (leftKickoff !== rightKickoff) return leftKickoff - rightKickoff;
  const homeCompare = String(lhs && lhs.home_team ? lhs.home_team : "").localeCompare(
    String(rhs && rhs.home_team ? rhs.home_team : ""),
    undefined,
    { sensitivity: "base" }
  );
  if (homeCompare !== 0) return homeCompare;
  const awayCompare = String(lhs && lhs.away_team ? lhs.away_team : "").localeCompare(
    String(rhs && rhs.away_team ? rhs.away_team : ""),
    undefined,
    { sensitivity: "base" }
  );
  if (awayCompare !== 0) return awayCompare;
  return String(lhs && lhs.match_details_id ? lhs.match_details_id : "").localeCompare(
    String(rhs && rhs.match_details_id ? rhs.match_details_id : ""),
    undefined,
    { sensitivity: "base" }
  );
}

function isEligibleForLiveActivityByPreferences(user, match) {
  const prefs = user && user.preferences && typeof user.preferences === "object" ? user.preferences : {};
  if (!match || typeof match !== "object") {
    return {
      eligible: false,
      reason: "invalid_match",
    };
  }

  if (prefs.competitionFilterEnabled && Array.isArray(prefs.selectedLeagues) && prefs.selectedLeagues.length > 0) {
    if (!prefs.selectedLeagues.includes(match.league)) {
      return {
        eligible: false,
        reason: "league_filtered_out",
      };
    }
  }

  if (prefs.channelFilterEnabled && Array.isArray(prefs.selectedChannels) && prefs.selectedChannels.length > 0) {
    const channels = Array.isArray(match.tv_channels) ? match.tv_channels : [];
    if (channels.length > 0) {
      const hasMatchingChannel = channels.some((channel) =>
        prefs.selectedChannels.some((selection) => channelMatchesSelection(channel, selection))
      );
      if (!hasMatchingChannel) {
        return {
          eligible: false,
          reason: "channel_filtered_out",
        };
      }
    }
  }

  return {
    eligible: true,
    reason: "eligible",
  };
}

function buildActivityMatchSnapshot(match) {
  if (!match || typeof match !== "object") return null;
  return {
    match_details_id: match.match_details_id ? String(match.match_details_id) : null,
    date: match.date || null,
    time: match.time || null,
    league: match.league || null,
    home_team: match.home_team || null,
    away_team: match.away_team || null,
    home_score: toNumericScore(match.home_score),
    away_score: toNumericScore(match.away_score),
    aggregate_home_score: toNumericScore(match.aggregate_home_score),
    aggregate_away_score: toNumericScore(match.aggregate_away_score),
    score_status: match.score_status || null,
    tv_channels: Array.isArray(match.tv_channels) ? match.tv_channels : [],
  };
}

function appendMonitorHistorySnapshot(monitorState, match, timestampMs = Date.now()) {
  if (!monitorState) return;
  const snapshot = buildActivityMatchSnapshot(match);
  if (!snapshot) return;
  if (!Array.isArray(monitorState.history)) {
    monitorState.history = [];
  }
  monitorState.history.push({
    timestampMs: Number.isFinite(Number(timestampMs)) ? Math.floor(Number(timestampMs)) : Date.now(),
    match: snapshot,
  });
  const maxHistory = 720;
  if (monitorState.history.length > maxHistory) {
    monitorState.history.splice(0, monitorState.history.length - maxHistory);
  }
}

function delayedSnapshotForMatch(monitorState, delayMinutes, nowMs = Date.now()) {
  if (!monitorState || delayMinutes <= 0 || !Array.isArray(monitorState.history)) {
    return monitorState && monitorState.lastState ? monitorState.lastState : null;
  }
  const targetMs = nowMs - delayMinutes * 60 * 1000;
  const history = monitorState.history;
  let latestEligible = null;
  let maxHomeScore = null;
  let maxAwayScore = null;
  for (let index = history.length - 1; index >= 0; index -= 1) {
    const entry = history[index];
    if (!entry || !entry.match) continue;
    if (Number(entry.timestampMs) <= targetMs) {
      if (!latestEligible) {
        latestEligible = entry.match;
      }
      const candidateHomeScore = toNumericScore(entry.match.home_score);
      const candidateAwayScore = toNumericScore(entry.match.away_score);
      if (Number.isFinite(candidateHomeScore)) {
        maxHomeScore =
          maxHomeScore === null ? candidateHomeScore : Math.max(maxHomeScore, candidateHomeScore);
      }
      if (Number.isFinite(candidateAwayScore)) {
        maxAwayScore =
          maxAwayScore === null ? candidateAwayScore : Math.max(maxAwayScore, candidateAwayScore);
      }
    }
  }
  if (latestEligible) {
    return {
      ...latestEligible,
      home_score: maxHomeScore === null ? latestEligible.home_score : maxHomeScore,
      away_score: maxAwayScore === null ? latestEligible.away_score : maxAwayScore,
    };
  }
  const first = history[0];
  return first && first.match ? first.match : monitorState.lastState || null;
}

function hasFullDelayBufferForMatch(monitorState, delayMinutes, nowMs = Date.now()) {
  if (delayMinutes <= 0) return true;
  if (!monitorState || !Array.isArray(monitorState.history) || monitorState.history.length === 0) {
    return false;
  }
  const targetMs = nowMs - delayMinutes * 60 * 1000;
  const first = monitorState.history[0];
  const firstTimestampMs = Number(first && first.timestampMs);
  if (!Number.isFinite(firstTimestampMs)) return false;
  return firstTimestampMs <= targetMs;
}

function inferLiveActivityFinishedAtMs(entry, nowMs = Date.now()) {
  const state = entry && entry.state && typeof entry.state === "object" ? entry.state : {};
  const match = entry && entry.match && typeof entry.match === "object" ? entry.match : null;

  const directFinishedAtMs = Number(state.finishedAtMs);
  if (Number.isFinite(directFinishedAtMs)) return directFinishedAtMs;

  const lifecycleFinishedAtMs = Number(state.lifecycle && state.lifecycle.fulltimeAtMs);
  if (Number.isFinite(lifecycleFinishedAtMs)) return lifecycleFinishedAtMs;

  if (Array.isArray(state.history)) {
    for (let index = state.history.length - 1; index >= 0; index -= 1) {
      const historyEntry = state.history[index];
      const historyMatch = historyEntry && historyEntry.match ? historyEntry.match : null;
      if (!historyMatch) continue;
      if (
        isFinishedMatchStatus(historyMatch.score_status) ||
        isPenaltyShootoutStatus(historyMatch.score_status)
      ) {
        const historyTimestampMs = Number(historyEntry.timestampMs);
        if (Number.isFinite(historyTimestampMs)) {
          return historyTimestampMs;
        }
      }
    }
  }

  const updatedAtMs = Date.parse(String(match && match.updated_at ? match.updated_at : "").trim());
  if (Number.isFinite(updatedAtMs)) return updatedAtMs;

  if (
    match &&
    (isFinishedMatchStatus(match.score_status) || isPenaltyShootoutStatus(match.score_status))
  ) {
    return nowMs;
  }

  return null;
}

function shouldRetainFinishedMatchForLiveActivity(entry, nowMs = Date.now()) {
  const finishedAtMs = inferLiveActivityFinishedAtMs(entry, nowMs);
  return Number.isFinite(finishedAtMs) && nowMs - finishedAtMs < LIVE_ACTIVITY_FINISHED_RETENTION_MS;
}

function retainFinishedMatchForLiveActivity(matchId, monitorState, nowMs = Date.now()) {
  if (!matchId || !monitorState || !monitorState.lastState) return;
  retainedFinishedMatches.set(matchId, {
    ...monitorState,
    lastState: { ...monitorState.lastState },
    history: Array.isArray(monitorState.history)
      ? monitorState.history.map((entry) => ({
        timestampMs: entry && entry.timestampMs,
        match: entry && entry.match ? { ...entry.match } : null,
      }))
      : [],
    finishedAtMs: Number.isFinite(Number(monitorState.finishedAtMs))
      ? Number(monitorState.finishedAtMs)
      : nowMs,
  });
}

function cleanupRetainedFinishedMatches(nowMs = Date.now()) {
  for (const [matchId, state] of retainedFinishedMatches.entries()) {
    const entry = {
      matchId,
      state,
      match: state && state.lastState ? state.lastState : null,
    };
    if (!shouldRetainFinishedMatchForLiveActivity(entry, nowMs)) {
      retainedFinishedMatches.delete(matchId);
    }
  }
}

function monitoredMatchStatesSnapshot(nowMs = Date.now()) {
  cleanupRetainedFinishedMatches(nowMs);

  const entries = [
    ...Array.from(monitoredMatches.entries()),
    ...Array.from(retainedFinishedMatches.entries()),
  ];

  return entries
    .map(([matchId, state]) => ({
      matchId,
      state,
      match: state && state.lastState ? state.lastState : null,
    }))
    .filter((entry) => entry.match);
}

function displayStatusToken(status) {
  const value = String(status || "").trim();
  if (!value) return null;
  if (MATCH_STATUS_MINUTE_PATTERN.test(value)) {
    return value.includes("'") ? value : `${value}'`;
  }
  return value.toUpperCase();
}

function liveActivityDelayMinutesFromPreferences(prefs) {
  if (!prefs || typeof prefs !== "object") return 0;
  if (prefs.liveActivityDelayMinutes !== undefined && prefs.liveActivityDelayMinutes !== null) {
    return Math.max(0, Number(prefs.liveActivityDelayMinutes || 0));
  }
  return Math.max(0, Number(prefs.notificationDelayMinutes || 0));
}

function liveActivityModeForMatches(liveMatches, finishedMatches, upcomingMatches) {
  const liveAndFinishedCount = liveMatches.length + finishedMatches.length;
  if (liveAndFinishedCount > 1) return liveMatches.length > 0 ? "multi_live" : "multi_finished";
  if (liveAndFinishedCount === 1) return liveMatches.length > 0 ? "single_live" : "single_finished";
  if (upcomingMatches.length > 1) return "multi_upcoming";
  if (upcomingMatches.length === 1) return "single_upcoming";
  return null;
}

function sanitizeAggregateForLiveActivity(match) {
  if (!match || typeof match !== "object") return match;

  const aggregateHomeScore = toNumericScore(match.aggregate_home_score);
  const aggregateAwayScore = toNumericScore(match.aggregate_away_score);
  if (!Number.isFinite(aggregateHomeScore) || !Number.isFinite(aggregateAwayScore)) {
    return match;
  }
  if (aggregateHomeScore !== 0 || aggregateAwayScore !== 0) {
    return match;
  }

  return {
    ...match,
    aggregate_home_score: null,
    aggregate_away_score: null,
  };
}

function buildLiveActivityContentState(mode, matches, delayMinutes, nowMs = Date.now()) {
  const delayLabel = delayMinutes > 0 && (mode === "single_live" || mode === "multi_live")
    ? `Delayed ${delayMinutes} m`
    : null;
  const normalizedMatches = matches.map((match) => ({
    matchId: String(match.match_details_id || ""),
    date: String(match.date || ""),
    time: String(match.time || ""),
    league: String(match.league || ""),
    leagueSubcategory:
      match && match.league_subcategory !== undefined && match.league_subcategory !== null
        ? String(match.league_subcategory)
        : null,
    homeTeam: String(match.home_team || ""),
    awayTeam: String(match.away_team || ""),
    homeScore: toNumericScore(match.home_score),
    awayScore: toNumericScore(match.away_score),
    aggregateHomeScore: toNumericScore(match.aggregate_home_score),
    aggregateAwayScore: toNumericScore(match.aggregate_away_score),
    matchTime: displayStatusToken(match.score_status),
    homeTeamScore: toNumericScore(match.home_team_score),
    awayTeamScore: toNumericScore(match.away_team_score),
    totalTeamScore: toNumericScore(match.total_team_score),
    tvChannels: Array.isArray(match.tv_channels) ? match.tv_channels.slice(0, 3) : [],
  }));

  return {
    mode,
    generatedAtEpochSeconds: Math.floor(nowMs / 1000),
    delayMinutes: Number(delayMinutes || 0),
    delayLabel,
    matches: normalizedMatches,
  };
}

function liveActivityPayloadMetrics(contentState) {
  const contentStateJSON = JSON.stringify(contentState);
  const archiveEstimateJSON = JSON.stringify({
    attributes: LIVE_ACTIVITY_ATTRIBUTES,
    "content-state": contentState,
  });

  return {
    contentStateBytes: Buffer.byteLength(contentStateJSON),
    archiveEstimateBytes: Buffer.byteLength(archiveEstimateJSON),
    matchCount: Array.isArray(contentState && contentState.matches) ? contentState.matches.length : 0,
  };
}

function logLiveActivityPayloadDiagnostics(user, event, presentation, contentState, nowMs, payloadHash) {
  const metrics = liveActivityPayloadMetrics(contentState);
  liveActivityMetrics.recordPayloadSample({
    event,
    isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
    kind: "content_state",
    bytes: metrics.contentStateBytes,
  });
  liveActivityMetrics.recordPayloadSample({
    event,
    isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
    kind: "archive_estimate",
    bytes: metrics.archiveEstimateBytes,
  });
  const staleAtEpochSeconds = Math.floor(nowMs / 1000) + LIVE_ACTIVITY_DEFAULT_STALE_AFTER_SECONDS;
  const diagnostics = {
    user_device_short: shortDeviceToken(user.deviceToken),
    event,
    mode: presentation && presentation.mode ? presentation.mode : null,
    match_count: metrics.matchCount,
    content_state_bytes: metrics.contentStateBytes,
    archive_estimate_bytes: metrics.archiveEstimateBytes,
    payload_hash_prefix: payloadHash ? String(payloadHash).slice(0, 12) : null,
    delay_minutes: Number(presentation && presentation.delayMinutes ? presentation.delayMinutes : 0),
    stale_at: new Date(staleAtEpochSeconds * 1000).toISOString(),
    seconds_until_stale: LIVE_ACTIVITY_DEFAULT_STALE_AFTER_SECONDS,
  };

  console.log(`[MatchMonitor] Live Activity payload ${JSON.stringify(diagnostics)}`);

  if (
    metrics.contentStateBytes >= LIVE_ACTIVITY_PAYLOAD_WARN_BYTES ||
    metrics.archiveEstimateBytes >= LIVE_ACTIVITY_PAYLOAD_WARN_BYTES
  ) {
    console.warn(
      `[MatchMonitor] Live Activity payload nearing limit ${JSON.stringify({
        ...diagnostics,
        warning_threshold_bytes: LIVE_ACTIVITY_PAYLOAD_WARN_BYTES,
        hard_limit_bytes: LIVE_ACTIVITY_PAYLOAD_HARD_LIMIT_BYTES,
      })}`
    );
  }
}

function stableHash(value) {
  const normalized = JSON.stringify(value);
  return crypto.createHash("sha1").update(normalized).digest("hex");
}

function isTerminalLiveActivityError(result) {
  const message = String(result && result.error ? result.error : "").toLowerCase();
  if (!message) return false;
  return (
    message.includes("baddevicetoken") ||
    message.includes("unregistered") ||
    message.includes("device token not for topic")
  );
}

async function persistLiveActivityPatch(user, patch = {}) {
  if (!user || !user.deviceToken) return;
  if (!patch || typeof patch !== "object" || Object.keys(patch).length === 0) return;
  try {
    await updateUserLiveActivityState(user.deviceToken, patch);
  } catch (error) {
    console.warn(
      `[MatchMonitor] Failed persisting live activity patch for ${shortDeviceToken(
        user.deviceToken
      )}:`,
      error.message || error
    );
  }
}

function shouldSkipLiveActivityUpdate(state, payloadHash, mode, forceDispatch = false) {
  if (forceDispatch) return false;
  return state.lastPayloadHash === payloadHash && state.lastMode === mode;
}

function shouldPreserveExistingLiveActivityOnEmpty(activityPushToken, options = {}) {
  return Boolean(
    options &&
      options.preserveExistingOnEmpty &&
      activityPushToken &&
      String(activityPushToken).trim()
  );
}

async function dispatchLiveActivityForUser(user, presentation, nowMs = Date.now(), options = {}) {
  const state = user && user.liveActivity && typeof user.liveActivity === "object" ? user.liveActivity : {};
  const forceDispatch = Boolean(options && options.forceDispatch);
  const preserveExistingOnEmpty = Boolean(options && options.preserveExistingOnEmpty);
  const pushToStartToken = String(state.pushToStartToken || "").trim();
  const activityPushToken = String(state.currentActivityPushToken || "").trim();
  const pendingStartAtMs = Date.parse(String(state.pendingStartAt || ""));
  const hasPendingStart = Number.isFinite(pendingStartAtMs);
  const pendingAgeMs = hasPendingStart ? nowMs - pendingStartAtMs : 0;
  const testHoldUntilMs = Date.parse(String(state.testHoldUntil || ""));
  const isTestHoldActive = Number.isFinite(testHoldUntilMs) && nowMs < testHoldUntilMs;
  const shouldDisplay = Boolean(presentation && presentation.mode && presentation.matches.length > 0);

  if (!shouldDisplay) {
    if (shouldPreserveExistingLiveActivityOnEmpty(activityPushToken, { preserveExistingOnEmpty })) {
      return;
    }
    if (isTestHoldActive) {
      return;
    }
    if (hasPendingStart) {
      await persistLiveActivityPatch(user, {
        pendingStartAt: null,
        lastPayloadHash: null,
        lastMode: null,
      });
    }
    if (!activityPushToken) return;
    const result = await sendLiveActivityPush({
      token: activityPushToken,
      event: "end",
      contentState: {
        mode: "ended",
        generatedAtEpochSeconds: Math.floor(nowMs / 1000),
        delayMinutes: 0,
        delayLabel: null,
        matches: [],
      },
      dismissalDate: Math.floor(nowMs / 1000),
      isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
    });
    liveActivityMetrics.recordPush({
      event: "end",
      status: result.success ? "success" : "failure",
      isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
    });
    const patch = {
      currentActivityPushToken: null,
      currentActivityId: null,
      pendingStartAt: null,
      lastPayloadHash: null,
      lastMode: null,
      lastDispatchAt: new Date(nowMs).toISOString(),
      lastEndedAt: new Date(nowMs).toISOString(),
      testHoldUntil: null,
    };
    if (result.success) {
      liveActivityMetrics.markActivityInactive({ deviceToken: user.deviceToken });
      liveActivityMetrics.recordEnd({
        isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
        reason: "no_matches",
      });
    }
    if (!result.success && !isTerminalLiveActivityError(result)) {
      return;
    }
    await persistLiveActivityPatch(user, patch);
    return;
  }

  const contentState = buildLiveActivityContentState(
    presentation.mode,
    presentation.matches,
    presentation.delayMinutes,
    nowMs
  );
  const payloadHash = stableHash(contentState);

  if (activityPushToken) {
    if (shouldSkipLiveActivityUpdate(state, payloadHash, presentation.mode, forceDispatch)) {
      return;
    }
    logLiveActivityPayloadDiagnostics(user, "update", presentation, contentState, nowMs, payloadHash);
    const updateResult = await sendLiveActivityPush({
      token: activityPushToken,
      event: "update",
      contentState,
      staleDate: Math.floor(nowMs / 1000) + LIVE_ACTIVITY_DEFAULT_STALE_AFTER_SECONDS,
      isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
    });
    liveActivityMetrics.recordPush({
      event: "update",
      status: updateResult.success ? "success" : "failure",
      isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
    });
    if (updateResult.success) {
      await persistLiveActivityPatch(user, {
        lastPayloadHash: payloadHash,
        lastMode: presentation.mode,
        lastDispatchAt: new Date(nowMs).toISOString(),
      });
      return;
    }
    if (isTerminalLiveActivityError(updateResult)) {
      if (liveActivityMetrics.markActivityInactive({ deviceToken: user.deviceToken })) {
        liveActivityMetrics.recordEnd({
          isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
          reason: "terminal_error",
        });
      }
      await persistLiveActivityPatch(user, {
        currentActivityPushToken: null,
        currentActivityId: null,
        lastPayloadHash: null,
        lastMode: null,
      });
    }
    return;
  }

  if (!pushToStartToken) return;
  if (hasPendingStart && pendingAgeMs < LIVE_ACTIVITY_PENDING_MAX_MS) {
    // A start push already succeeded; wait for activity push token from app and avoid duplicate starts.
    return;
  }
  if (hasPendingStart && pendingAgeMs >= LIVE_ACTIVITY_PENDING_MAX_MS) {
    // Stale lock recovery for extreme edge cases (e.g. token callback never arrives).
    await persistLiveActivityPatch(user, {
      pendingStartAt: null,
      lastPayloadHash: null,
      lastMode: null,
    });
  }

  const first = presentation.matches[0];
  const title = presentation.mode.includes("live")
    ? "Live now"
    : presentation.mode.includes("finished")
    ? "Full time"
    : "Kick-off soon";
  const body = first
    ? `${first.home_team} vs ${first.away_team}`
    : "Top Scores";
  logLiveActivityPayloadDiagnostics(user, "start", presentation, contentState, nowMs, payloadHash);
  const startResult = await sendLiveActivityPush({
    token: pushToStartToken,
    event: "start",
    attributesType: LIVE_ACTIVITY_ATTRIBUTES_TYPE,
    attributes: LIVE_ACTIVITY_ATTRIBUTES,
    contentState,
    staleDate: Math.floor(nowMs / 1000) + LIVE_ACTIVITY_DEFAULT_STALE_AFTER_SECONDS,
    alert: {
      title,
      body,
    },
    isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
  });
  liveActivityMetrics.recordPush({
    event: "start",
    status: startResult.success ? "success" : "failure",
    isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
  });
  if (startResult.success) {
    liveActivityMetrics.recordStart({
      isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
    });
    await persistLiveActivityPatch(user, {
      pendingStartAt: new Date(nowMs).toISOString(),
      lastStartAt: new Date(nowMs).toISOString(),
      lastPayloadHash: payloadHash,
      lastMode: presentation.mode,
      lastDispatchAt: new Date(nowMs).toISOString(),
    });
    return;
  }

  if (isTerminalLiveActivityError(startResult)) {
    await persistLiveActivityPatch(user, {
      pushToStartToken: null,
      pushToStartTokenUpdatedAt: null,
      pendingStartAt: null,
      lastPayloadHash: null,
      lastMode: null,
      lastDispatchAt: new Date(nowMs).toISOString(),
      testHoldUntil: null,
    });
  }
}

function buildLiveActivityPresentationForUser(user, entries, nowMs = Date.now()) {
  const prefs = user && user.preferences && typeof user.preferences === "object" ? user.preferences : {};
  const delayMinutes = liveActivityDelayMinutesFromPreferences(prefs);
  const eligible = [];

  for (const entry of entries) {
    const match = entry && entry.match ? entry.match : null;
    if (!match) continue;
    const eligibility = isEligibleForLiveActivityByPreferences(user, match);
    if (!eligibility.eligible) continue;
    eligible.push(entry);
  }

  if (eligible.length === 0) {
    return {
      mode: null,
      matches: [],
      delayMinutes,
    };
  }

  const liveMatches = [];
  const finishedMatches = [];
  const upcomingMatches = [];

  for (const entry of eligible) {
    const state = entry.state || null;
    const currentMatch = entry.match;
    const kickoffMs = parseMatchDateTimeMs(currentMatch);
    const status = currentMatch ? currentMatch.score_status : null;

    if (isLikelyTerminalStaleLiveMatch(currentMatch, kickoffMs, nowMs)) {
      continue;
    }

    if (isLiveMatchStatus(status)) {
      const delayed = delayedSnapshotForMatch(state, delayMinutes, nowMs) || currentMatch;
      const delayedLiveState = buildDelayedLiveState(currentMatch, delayed, delayMinutes);

      if (!hasFullDelayBufferForMatch(state, delayMinutes, nowMs)) {
        if (delayedLiveState) {
          liveMatches.push(sanitizeAggregateForLiveActivity({
            ...currentMatch,
            home_score: delayedLiveState.home_score,
            away_score: delayedLiveState.away_score,
            score_status: delayedLiveState.score_status,
            aggregate_home_score: null,
            aggregate_away_score: null,
          }));
          continue;
        }

        // Avoid spoilers when we cannot safely reconstruct the delayed live state yet.
        upcomingMatches.push(sanitizeAggregateForLiveActivity({
          ...currentMatch,
          home_score: null,
          away_score: null,
          score_status: null,
          aggregate_home_score: null,
          aggregate_away_score: null,
        }));
        continue;
      }
      const delayedHasAggregateHome =
        delayed && Object.prototype.hasOwnProperty.call(delayed, "aggregate_home_score");
      const delayedHasAggregateAway =
        delayed && Object.prototype.hasOwnProperty.call(delayed, "aggregate_away_score");
      const delayedScoreOverride = delayedScoreOverrideFromTimeline(currentMatch, delayed);
      const currentClearsAggregateHome =
        currentMatch &&
        Object.prototype.hasOwnProperty.call(currentMatch, "aggregate_home_score") &&
        currentMatch.aggregate_home_score === null;
      const currentClearsAggregateAway =
        currentMatch &&
        Object.prototype.hasOwnProperty.call(currentMatch, "aggregate_away_score") &&
        currentMatch.aggregate_away_score === null;
      liveMatches.push(sanitizeAggregateForLiveActivity({
        ...currentMatch,
        home_score:
          delayedLiveState && delayedLiveState.home_score !== undefined
            ? delayedLiveState.home_score
            : delayedScoreOverride && Number.isFinite(delayedScoreOverride.home_score)
            ? delayedScoreOverride.home_score
            : delayed.home_score,
        away_score:
          delayedLiveState && delayedLiveState.away_score !== undefined
            ? delayedLiveState.away_score
            : delayedScoreOverride && Number.isFinite(delayedScoreOverride.away_score)
            ? delayedScoreOverride.away_score
            : delayed.away_score,
        score_status:
          delayedLiveState && delayedLiveState.score_status
            ? delayedLiveState.score_status
            : delayed.score_status || currentMatch.score_status,
        // Keep aggregate values on the same delayed timeline as primary scores/status.
        aggregate_home_score: currentClearsAggregateHome
          ? null
          : delayedHasAggregateHome
          ? delayed.aggregate_home_score
          : null,
        aggregate_away_score: currentClearsAggregateAway
          ? null
          : delayedHasAggregateAway
          ? delayed.aggregate_away_score
          : null,
      }));
      continue;
    }

    if (isFinishedMatchStatus(status) || isPenaltyShootoutStatus(status)) {
      if (shouldRetainFinishedMatchForLiveActivity(entry, nowMs)) {
        finishedMatches.push(sanitizeAggregateForLiveActivity(currentMatch));
      }
      continue;
    }

    if (Number.isFinite(kickoffMs)) {
      const diff = kickoffMs - nowMs;
      if (diff > 0 && diff <= UPCOMING_MONITOR_WINDOW_MS) {
        upcomingMatches.push(sanitizeAggregateForLiveActivity(currentMatch));
      }
    }
  }

  const sortedLive = liveMatches
    .map(annotateMatchWithLiveActivityTeamRatings)
    .sort(compareLiveActivityMatches);
  const sortedFinished = finishedMatches
    .map(annotateMatchWithLiveActivityTeamRatings)
    .sort(compareLiveActivityMatches);
  const sortedLiveAndFinished = [...sortedLive, ...sortedFinished].slice(0, LIVE_ACTIVITY_MAX_MATCHES);
  const sortedUpcoming = upcomingMatches
    .map(annotateMatchWithLiveActivityTeamRatings)
    .sort(compareLiveActivityMatches)
    .slice(0, LIVE_ACTIVITY_MAX_MATCHES);
  const mode = liveActivityModeForMatches(sortedLive, sortedFinished, sortedUpcoming);
  if (!mode) {
    return {
      mode: null,
      matches: [],
      delayMinutes,
    };
  }

  return {
    mode,
    matches: mode.includes("upcoming") ? sortedUpcoming : sortedLiveAndFinished,
    delayMinutes,
  };
}

async function evaluateAndDispatchLiveActivities(options = {}) {
  if (!isMonitoring) return;
  if (liveActivityEvalInFlight) return;
  liveActivityEvalInFlight = true;
  const nowMs = Date.now();
  const forceDispatch = Boolean(options && options.forceDispatch);
  const preserveExistingOnEmpty = Boolean(options && options.preserveExistingOnEmpty);

  try {
    await ensureLiveActivityTeamRatingCache(nowMs);
    const entries = monitoredMatchStatesSnapshot();
    const users = await getAllUserPreferences();
    if (!Array.isArray(users) || users.length === 0) return;

    for (const user of users) {
      const liveActivityState =
        user && user.liveActivity && typeof user.liveActivity === "object" ? user.liveActivity : {};
      const hasStartToken = Boolean(
        liveActivityState.pushToStartToken && String(liveActivityState.pushToStartToken).trim()
      );
      const hasActivityToken = Boolean(
        liveActivityState.currentActivityPushToken &&
          String(liveActivityState.currentActivityPushToken).trim()
      );
      if (!hasStartToken && !hasActivityToken) continue;

      const presentation = buildLiveActivityPresentationForUser(user, entries, nowMs);
      try {
        await dispatchLiveActivityForUser(user, presentation, nowMs, {
          forceDispatch,
          preserveExistingOnEmpty,
        });
      } catch (userError) {
        console.warn(
          `[MatchMonitor] Live Activity dispatch failed for ${shortDeviceToken(
            user.deviceToken
          )}:`,
          userError && userError.message ? userError.message : userError
        );
      }
    }
  } catch (error) {
    console.warn("[MatchMonitor] evaluateAndDispatchLiveActivities error:", error.message || error);
  } finally {
    liveActivityEvalInFlight = false;
  }
}

async function runLiveActivityEvaluationNow(options = {}) {
  await evaluateAndDispatchLiveActivities(options);
  return {
    success: true,
    isMonitoring,
    monitoredMatchCount: monitoredMatches.size,
  };
}

/**
 * Schedule a notification for a user (with delay if configured)
 */
async function scheduleNotificationForUser(user, matchId, match, event) {
  const prefs = user.preferences || {};
  const delayMinutes = prefs.notificationDelayMinutes || 0;
  const delayMs = delayMinutes * 60 * 1000;

  // Create unique notification ID to prevent duplicates
  const notificationId = buildNotificationId(user, matchId, event);

  // Check if we've already sent this notification recently
  if (sentNotifications.has(notificationId)) {
    console.log(`[MatchMonitor] Skipping duplicate notification: ${notificationId}`);
    logDecision("notification_schedule", {
      match_id: matchId,
      event_type: event.type,
      event_key: event.eventKey || null,
      user_device_short: shortDeviceToken(user.deviceToken),
      notification_id: notificationId,
      result: "dedupe_skipped",
      delay_minutes: delayMinutes,
    });
    return;
  }

  // Mark as sent
  sentNotifications.add(notificationId);

  // Schedule removal from dedup set after window expires
  setTimeout(() => {
    sentNotifications.delete(notificationId);
  }, NOTIFICATION_DEDUP_WINDOW_MS);

  // Schedule the notification
  if (delayMs > 0) {
    console.log(
      `[MatchMonitor] Scheduling notification for user ${user.deviceToken.substring(0, 12)}... with ${delayMinutes} minute delay`
    );
    logDecision("notification_schedule", {
      match_id: matchId,
      event_type: event.type,
      event_key: event.eventKey || null,
      user_device_short: shortDeviceToken(user.deviceToken),
      notification_id: notificationId,
      result: "scheduled_delayed",
      delay_minutes: delayMinutes,
    });

    const timeout = setTimeout(async () => {
      logDecision("notification_schedule", {
        match_id: matchId,
        event_type: event.type,
        event_key: event.eventKey || null,
        user_device_short: shortDeviceToken(user.deviceToken),
        notification_id: notificationId,
        result: "delayed_dispatch_start",
        delay_minutes: delayMinutes,
      });
      await sendNotificationToUser(user, matchId, match, event, {
        notificationId,
        delayMinutes,
        dispatchMode: "delayed",
      });
      scheduledNotifications.delete(notificationId);
    }, delayMs);

    scheduledNotifications.set(notificationId, timeout);
  } else {
    // Send immediately
    logDecision("notification_schedule", {
      match_id: matchId,
      event_type: event.type,
      event_key: event.eventKey || null,
      user_device_short: shortDeviceToken(user.deviceToken),
      notification_id: notificationId,
      result: "dispatch_immediate",
      delay_minutes: 0,
    });
    await sendNotificationToUser(user, matchId, match, event, {
      notificationId,
      delayMinutes: 0,
      dispatchMode: "immediate",
    });
  }
}

/**
 * Send notification to a specific user
 */
async function sendNotificationToUser(user, matchId, match, event, notificationMeta = {}) {
  try {
    const notificationId =
      notificationMeta && notificationMeta.notificationId
        ? String(notificationMeta.notificationId)
        : buildNotificationId(user, matchId, event);

    const idempotency = await claimBbcNotificationIdempotency(notificationId, {
      context: {
        match_id: matchId,
        event_type: event && event.type ? event.type : null,
        event_key: event && event.eventKey ? event.eventKey : null,
        device_token: shortDeviceToken(user && user.deviceToken),
      },
    });

    if (!idempotency.claimed) {
      logDecision("notification_send_result", {
        match_id: matchId,
        event_type: event.type,
        event_key: event.eventKey || null,
        user_device_short: shortDeviceToken(user.deviceToken),
        success: false,
        dedupe_skipped: true,
        notification_id: notificationId,
        idempotency_source: idempotency.source || null,
      });
      await persistNotificationHistory({
        user,
        matchId,
        match,
        event,
        notificationId,
        delayMinutes: notificationMeta.delayMinutes,
        dispatchMode: notificationMeta.dispatchMode,
        result: null,
        error: null,
        status: "dedupe_skipped",
        idempotencySource: idempotency.source || null,
      });
      return;
    }

    const payload = {
      event_type: event.type,
      match_id: matchId,
    };
    if (event.eventKey) payload.event_key = event.eventKey;
    if (event.goalTime) payload.goal_time = event.goalTime;
    if (event.disallowedByVar) payload.disallowed_by_var = true;
    if (event.varDecisionTime) payload.var_decision_time = event.varDecisionTime;

    const result = await sendNotification(
      user.apnsToken,
      event.title,
      event.body,
      payload,
      user.isDevelopmentBuild || false
    );
    await persistNotificationHistory({
      user,
      matchId,
      match,
      event,
      notificationId,
      delayMinutes: notificationMeta.delayMinutes,
      dispatchMode: notificationMeta.dispatchMode,
      result,
      error: null,
      idempotencySource: idempotency.source || null,
    });
    logDecision("notification_send_result", {
      match_id: matchId,
      event_type: event.type,
      event_key: event.eventKey || null,
      user_device_short: shortDeviceToken(user.deviceToken),
      success: Boolean(result && result.success),
      environment: result && result.environment ? result.environment : null,
      error: result && result.error ? String(result.error) : null,
    });
  } catch (error) {
    console.error(
      `[MatchMonitor] Error sending notification to user ${user.deviceToken.substring(0, 12)}...:`,
      error.message
    );
    logDecision("notification_send_result", {
      match_id: matchId,
      event_type: event.type,
      event_key: event.eventKey || null,
      user_device_short: shortDeviceToken(user.deviceToken),
      success: false,
      environment: null,
      error: error.message,
    });
    await persistNotificationHistory({
      user,
      matchId,
      match,
      event,
      notificationId:
        notificationMeta && notificationMeta.notificationId
          ? notificationMeta.notificationId
          : buildNotificationId(user, matchId, event),
      delayMinutes: notificationMeta.delayMinutes,
      dispatchMode: notificationMeta.dispatchMode,
      result: null,
      error,
    });
  }
}

/**
 * Helper functions
 */

function countGoals(goalScorers) {
  if (!goalScorers || !Array.isArray(goalScorers)) return 0;
  return goalScorers.reduce((total, scorer) => {
    const regularGoals = Array.isArray(scorer.goal_times) ? scorer.goal_times.length : 0;
    const ownGoals = Array.isArray(scorer.own_goal_times) ? scorer.own_goal_times.length : 0;
    return total + regularGoals + ownGoals;
  }, 0);
}

function countRedCards(redCards) {
  if (!redCards || !Array.isArray(redCards)) return 0;
  return redCards.reduce((total, card) => {
    return total + (card.red_card_times ? card.red_card_times.length : 0);
  }, 0);
}

function getLatestRedCard(redCards) {
  if (!redCards || redCards.length === 0) return null;
  const lastCard = redCards[redCards.length - 1];
  return lastCard.player || null;
}

function getLatestRedCardTime(redCards) {
  if (!redCards || redCards.length === 0) return null;
  const lastCard = redCards[redCards.length - 1];
  const times = lastCard.red_card_times;
  return times && times.length > 0 ? times[times.length - 1] : null;
}

/**
 * Cleanup old data and finished matches
 */
function cleanup() {
  const now = Date.now();
  const MAX_ERROR_POLL_AGE_MS = 30 * 60 * 1000; // Stop if we haven't updated state due repeated fetch failures

  cleanupRetainedFinishedMatches(now);

  for (const [matchId, state] of monitoredMatches) {
    if (now - state.lastPollTime > MAX_ERROR_POLL_AGE_MS) {
      console.log(`[MatchMonitor] Cleaning up stale match ${matchId}`);
      stopMonitoringMatch(matchId, "stale_poll_cleanup");
      continue;
    }

    if (shouldStopMonitoringAsIrrelevant(state.lastState, state, now)) {
      console.log(`[MatchMonitor] Cleaning up out-of-window match ${matchId}`);
      stopMonitoringMatch(matchId, "out_of_window_cleanup");
    }
  }

  console.log(`[MatchMonitor] Cleanup: ${monitoredMatches.size} matches being monitored, ${retainedFinishedMatches.size} finished matches retained, ${sentNotifications.size} notifications in dedup set, ${scheduledNotifications.size} notifications scheduled`);
}

/**
 * Get monitoring status
 */
function normalizeRecentLimit(value, fallback = 50, max = 500) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  const normalized = Math.floor(parsed);
  if (normalized < 1) return fallback;
  if (normalized > max) return max;
  return normalized;
}

function getStatus(options = {}) {
  const matchIdFilter = String(options && options.matchId ? options.matchId : "").trim();
  const recentLimit = normalizeRecentLimit(options && options.limitRecent, 50, 500);
  const monitoredEntries = Array.from(monitoredMatches.entries())
    .map(([matchId, state]) => ({
      match_id: matchId,
      home_team: state && state.lastState && state.lastState.home_team ? state.lastState.home_team : null,
      away_team: state && state.lastState && state.lastState.away_team ? state.lastState.away_team : null,
      score_status:
        state && state.lastState && state.lastState.score_status ? state.lastState.score_status : null,
      started_at_ms: Number.isFinite(state && state.startedAtMs) ? state.startedAtMs : null,
      last_poll_time_ms: Number.isFinite(state && state.lastPollTime) ? state.lastPollTime : null,
      kickoff_time_ms: Number.isFinite(state && state.kickoffTimeMs) ? state.kickoffTimeMs : null,
    }))
    .filter((entry) => !matchIdFilter || entry.match_id === matchIdFilter)
    .sort((lhs, rhs) => lhs.match_id.localeCompare(rhs.match_id));

  const filterByMatchId = (entry) =>
    !matchIdFilter || String(entry && entry.match_id ? entry.match_id : "") === matchIdFilter;
  const recentDecisions = monitorDiagnostics.recentDecisions
    .filter(filterByMatchId)
    .slice(-recentLimit)
    .reverse();
  const recentMonitorStarts = monitorDiagnostics.recentMonitorStarts
    .filter(filterByMatchId)
    .slice(-recentLimit)
    .reverse();
  const recentMonitorStops = monitorDiagnostics.recentMonitorStops
    .filter(filterByMatchId)
    .slice(-recentLimit)
    .reverse();
  const lastCheck = monitorDiagnostics.lastCheck && typeof monitorDiagnostics.lastCheck === "object"
    ? monitorDiagnostics.lastCheck
    : null;

  const expectedActiveMatchIdsRaw =
    lastCheck && Array.isArray(lastCheck.expected_active_match_ids)
      ? lastCheck.expected_active_match_ids
      : [];
  const actualActiveMatchIdsRaw =
    lastCheck && Array.isArray(lastCheck.actual_active_match_ids)
      ? lastCheck.actual_active_match_ids
      : [];
  const missingActiveMatchIdsRaw =
    lastCheck && Array.isArray(lastCheck.missing_active_match_ids)
      ? lastCheck.missing_active_match_ids
      : [];
  const unexpectedActiveMatchIdsRaw =
    lastCheck && Array.isArray(lastCheck.unexpected_active_match_ids)
      ? lastCheck.unexpected_active_match_ids
      : [];

  const applyMatchFilter = (items) => (
    matchIdFilter
      ? items.filter((item) => String(item || "") === matchIdFilter)
      : items
  );
  const expectedActiveMatchIds = applyMatchFilter(expectedActiveMatchIdsRaw);
  const actualActiveMatchIds = applyMatchFilter(actualActiveMatchIdsRaw);
  const missingActiveMatchIds = applyMatchFilter(missingActiveMatchIdsRaw);
  const unexpectedActiveMatchIds = applyMatchFilter(unexpectedActiveMatchIdsRaw);
  const coverageRatio = expectedActiveMatchIds.length === 0
    ? 1
    : (expectedActiveMatchIds.length - missingActiveMatchIds.length) / expectedActiveMatchIds.length;

  return {
    isMonitoring,
    monitoredMatchCount: monitoredMatches.size,
    monitoredMatchIds: monitoredEntries.map((entry) => entry.match_id),
    monitoredMatches: monitoredEntries,
    finishedMatchCount: finishedMatchIds.size,
    scheduledNotificationCount: scheduledNotifications.size,
    dedupSetSize: sentNotifications.size,
    diagnostics: {
      filter: {
        match_id: matchIdFilter || null,
        limit_recent: recentLimit,
      },
      last_check: lastCheck,
      last_error: monitorDiagnostics.lastError,
      coverage_summary: {
        expected_active_match_count: expectedActiveMatchIds.length,
        actual_active_match_count: actualActiveMatchIds.length,
        missing_active_match_count: missingActiveMatchIds.length,
        unexpected_active_match_count: unexpectedActiveMatchIds.length,
        expected_active_match_ids: expectedActiveMatchIds,
        actual_active_match_ids: actualActiveMatchIds,
        missing_active_match_ids: missingActiveMatchIds,
        unexpected_active_match_ids: unexpectedActiveMatchIds,
        coverage_ratio: coverageRatio,
      },
      recent_decisions: recentDecisions,
      recent_monitor_starts: recentMonitorStarts,
      recent_monitor_stops: recentMonitorStops,
    },
  };
}

module.exports = {
  initialize,
  startMonitoring,
  stopMonitoring,
  getStatus,
  runLiveActivityEvaluationNow,
  __testHooks: {
    annotateMatchWithLiveActivityTeamRatings,
    buildMatchEvents,
    buildScoreChangeEvent,
    buildNotificationId,
    buildVarDisallowedGoalEvent,
    confirmVarDisallowedGoal,
    countGoals,
    detectScoreReversion,
    diffRemovedGoalEvents,
    mergeSnapshotWithFallback,
    diffGoalEvents,
    isMatchRelevant,
    isLiveMatchStatus,
    isFinishedMatchStatus,
    isPenaltyShootoutStatus,
    shouldStopMonitoringAsIrrelevant,
    buildLiveActivityPresentationForUser,
    compareLiveActivityMatches,
    evaluateUserNotificationDecision,
    isEnglishPremierLeagueTeam,
    isLikelyTerminalStaleLiveMatch,
    shouldSkipLiveActivityUpdate,
    shouldPreserveExistingLiveActivityOnEmpty,
    updateScoreReversionState,
  },
};
