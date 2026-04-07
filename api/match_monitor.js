const {
  getAllUserPreferences,
  getAllOperationalMatchDetails,
  getOperationalDatasets,
  updateUserLiveActivityState,
  saveLiveActivityDebugRecord,
  saveFantasyReminderRecord,
  getFantasyReminderRecord,
  getFantasyReminderRecords,
  getLiveActivityMatchTimelineSnapshotsAt,
  saveBbcMatchEventHistory,
  saveBbcNotificationHistory,
  claimFantasyReminderSendIdempotency,
  claimBbcNotificationIdempotency,
} = require("./redis_client");
const { sendNotification, sendLiveActivityPush } = require("./apns_client");
const { fetchBbcLiveTextEntriesByDetailsUrl } = require("./fetch_bbc_scores");
const liveActivityMetrics = require("./live_activity_metrics");
const fantasyScore = require("./fantasy_score");
const crypto = require("crypto");
const LIVE_ACTIVITY_PREMIER_LEAGUE_TEAMS = require("./bbc_premier_league_teams.json");
const { teamIdentityNames } = require("./team_identity");

// Configuration
const POLL_INTERVAL_MS = 10 * 1000; // Poll every 10 seconds for monitored matches
const DAILY_MATCHES_CHECK_INTERVAL_MS = 15 * 1000; // Check for today's matches every 15 seconds
const CLEANUP_INTERVAL_MS = 5 * 60 * 1000; // Clean up every 5 minutes
const UPCOMING_MONITOR_WINDOW_MS = 15 * 60 * 1000;
const RECENT_KICKOFF_PENDING_GRACE_MS = 20 * 60 * 1000;
const MAX_MONITOR_DURATION_MS = 6 * 60 * 60 * 1000; // Keep monitoring up to 6h after kickoff
const NOTIFICATION_DEDUP_WINDOW_MS = 6 * 60 * 60 * 1000; // Keep event dedupe for a full match window
const KICKOFF_STATUS_MINUTE_THRESHOLD = 15; // Ignore kickoff if first seen too late in the match
const GOAL_TIMELINE_BACKLOG_LIMIT = 64; // Keep bounded unreconciled timeline events per match
// BBC live data can briefly oscillate between reverted and stale scorelines after VAR.
// Requiring five 10s polls delayed confirmation long enough to miss genuine reversals.
const SCORE_REVERSION_CONFIRMATION_POLLS = 3;
// Non-VAR score corrections are more likely to be BBC backend skew than a real correction.
// Hold them longer unless live text explicitly shows an on-pitch cancellation like offside.
const SCORE_CORRECTION_CONFIRMATION_POLLS = 5;
const VAR_DECISION_REVIEW_WINDOW_MINUTES = 5;
const MONITOR_DIAGNOSTICS_RECENT_LIMIT = 300; // Keep a rolling in-memory diagnostics window
const MATCH_MONITOR_DECISION_LOG_ENABLED = process.env.MATCH_MONITOR_DECISION_LOG !== "0";
const LIVE_ACTIVITY_EVAL_INTERVAL_MS = 15 * 1000;
const LIVE_ACTIVITY_NON_SCORE_UPDATE_MIN_INTERVAL_MS = 60 * 1000;
const LIVE_ACTIVITY_EVAL_STALL_TIMEOUT_MS = 30 * 1000;
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
const LIVE_ACTIVITY_DELAY_SNAPSHOT_STALE_TOLERANCE_MS = Math.max(POLL_INTERVAL_MS * 3, 60 * 1000);
const LIVE_ACTIVITY_ATTRIBUTES_TYPE = "TopScoresLiveActivityAttributes";
const LIVE_ACTIVITY_ATTRIBUTES = { appScope: "topscores" };
const FANTASY_DEADLINE_REMINDER_EVAL_INTERVAL_MS = 60 * 1000;
const FANTASY_DEADLINE_REMINDER_LOOKAHEAD_MS = 24 * 60 * 60 * 1000;
const FANTASY_DEADLINE_REMINDER_DEFAULT_TIMEZONE = "Europe/London";
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
let liveActivityMatchDetailsProvider = null;
let liveActivityOperationalMatchesProvider = null;
let canonicalMatchStateWriter = null;

// Match status helpers - mirrors server.js MATCH_STATUS_* constants
const MATCH_STATUS_MINUTE_PATTERN = /^(\d{1,3})(?:\+(\d{1,2}))?'?$/;
const MATCH_STATUS_COMPLETE_TOKENS = new Set(["FT", "AET"]);
const MATCH_STATUS_IN_PROGRESS_TOKENS = new Set(["LIVE", "HT", "ET", "PENS", "PEN", "PEN."]);
const MATCH_STATUS_PENALTY_TOKENS = new Set(["PENS", "PEN", "PEN."]);
const MATCH_STATUS_POSTPONED_TOKENS = new Set(["POSTPONED", "MATCH POSTPONED"]);
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

function selectBestGoalTimeline(primaryGoalScorers, fallbackGoalScorers) {
  const primary = Array.isArray(primaryGoalScorers) ? primaryGoalScorers : null;
  const fallback = Array.isArray(fallbackGoalScorers) ? fallbackGoalScorers : null;
  const primaryGoals = countGoals(primary);
  const fallbackGoals = countGoals(fallback);

  if (primaryGoals > 0 || primary) {
    if (fallbackGoals > primaryGoals) {
      return fallback;
    }
    return primary;
  }

  return fallback;
}

function buildDelayedLiveState(currentMatch, delayedMatch, delayMinutes) {
  if (!currentMatch || typeof currentMatch !== "object") return null;
  const currentMinute = parseStatusMinute(currentMatch.score_status);
  if (!Number.isFinite(currentMinute) || !Number.isFinite(delayMinutes) || delayMinutes <= 0) {
    return null;
  }

  const delayedStatusToken = String(
    delayedMatch && delayedMatch.score_status ? delayedMatch.score_status : ""
  ).trim();
  const computedDelayedMinute = Math.max(0, currentMinute - delayMinutes);
  const delayedMinute = parseStatusMinute(delayedStatusToken);
  const shouldNormalizeFirstHalfStoppageCarryover =
    delayedStatusToken.startsWith("45+") && currentMinute >= 46;
  const resolvedDelayedStatus =
    shouldNormalizeFirstHalfStoppageCarryover || !Number.isFinite(delayedMinute)
      ? String(computedDelayedMinute)
      : delayedStatusToken;

  const resolvedDelayedMinute = Number.isFinite(delayedMinute) && !shouldNormalizeFirstHalfStoppageCarryover
    ? delayedMinute
    : computedDelayedMinute;
  if (resolvedDelayedMinute <= 0) {
    return null;
  }
  const homeGoalTimeline = selectBestGoalTimeline(
    currentMatch.home_goal_scorers,
    delayedMatch && delayedMatch.home_goal_scorers
  );
  const awayGoalTimeline = selectBestGoalTimeline(
    currentMatch.away_goal_scorers,
    delayedMatch && delayedMatch.away_goal_scorers
  );
  const hasGoalTimeline =
    Array.isArray(homeGoalTimeline) || Array.isArray(awayGoalTimeline);
  const timelineHomeGoals = countGoalsUpToMinute(homeGoalTimeline, resolvedDelayedMinute);
  const timelineAwayGoals = countGoalsUpToMinute(awayGoalTimeline, resolvedDelayedMinute);
  const delayedHomeScore = toNumericScore(delayedMatch && delayedMatch.home_score);
  const delayedAwayScore = toNumericScore(delayedMatch && delayedMatch.away_score);
  const currentHomeScore = toNumericScore(currentMatch.home_score);
  const currentAwayScore = toNumericScore(currentMatch.away_score);
  const timelineHomeGoalCount = countGoals(homeGoalTimeline);
  const timelineAwayGoalCount = countGoals(awayGoalTimeline);
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
      score_status: resolvedDelayedStatus,
    };
  }

  if (!delayedMatch || typeof delayedMatch !== "object") {
    return {
      home_score: null,
      away_score: null,
      score_status: resolvedDelayedStatus,
    };
  }

  return {
    home_score: delayedMatch.home_score,
    away_score: delayedMatch.away_score,
    score_status: resolvedDelayedStatus,
  };
}

function delayedScoreOverrideFromTimeline(currentMatch, delayedMatch) {
  const delayedMinute = parseStatusMinute(delayedMatch && delayedMatch.score_status);
  if (!Number.isFinite(delayedMinute)) return null;
  if (!currentMatch || typeof currentMatch !== "object") return null;

  const homeGoalTimeline = selectBestGoalTimeline(
    currentMatch.home_goal_scorers,
    delayedMatch && delayedMatch.home_goal_scorers
  );
  const awayGoalTimeline = selectBestGoalTimeline(
    currentMatch.away_goal_scorers,
    delayedMatch && delayedMatch.away_goal_scorers
  );
  const homeGoalsByMinute = countGoalsUpToMinute(homeGoalTimeline, delayedMinute);
  const awayGoalsByMinute = countGoalsUpToMinute(awayGoalTimeline, delayedMinute);
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

function hasPenaltyShootoutResult(match) {
  return Boolean(String(match && match.penalty_result ? match.penalty_result : "").trim());
}

function penaltyShootoutWinnerSide(match) {
  const penaltyResult = String(match && match.penalty_result ? match.penalty_result : "").trim();
  if (!penaltyResult) return null;

  const winnerSegment = penaltyResult.split(/\bwin\b/i)[0].trim();
  if (!winnerSegment) return null;

  const normalizedWinner = normalizeLiveActivityFixtureToken(winnerSegment);
  const normalizedHomeTeam = normalizeLiveActivityFixtureToken(
    (match && (match.home_team || match.homeTeam)) || ""
  );
  const normalizedAwayTeam = normalizeLiveActivityFixtureToken(
    (match && (match.away_team || match.awayTeam)) || ""
  );

  if (
    normalizedWinner &&
    normalizedHomeTeam &&
    (normalizedWinner === normalizedHomeTeam ||
      normalizedWinner.includes(normalizedHomeTeam) ||
      normalizedHomeTeam.includes(normalizedWinner))
  ) {
    return "home";
  }

  if (
    normalizedWinner &&
    normalizedAwayTeam &&
    (normalizedWinner === normalizedAwayTeam ||
      normalizedWinner.includes(normalizedAwayTeam) ||
      normalizedAwayTeam.includes(normalizedWinner))
  ) {
    return "away";
  }

  return null;
}

function isResolvedPenaltyShootoutMatch(match) {
  return isPenaltyShootoutStatus(match && match.score_status) && hasPenaltyShootoutResult(match);
}

function isTerminalMatchState(match) {
  return isFinishedMatchStatus(match && match.score_status) || isResolvedPenaltyShootoutMatch(match);
}

function isPostponedMatchStatus(status) {
  return MATCH_STATUS_POSTPONED_TOKENS.has(normalizeStatusToken(status));
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
  if (value === undefined || value === null || value === "") return null;
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
          .flatMap((name) => teamIdentityNames(name))
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
  if (!lookup) {
    return null;
  }

  let bestRating = null;
  let bestConfidence = 0;

  for (const variant of teamIdentityNames(teamName)) {
    const key = normalizeLiveActivityTeamKey(variant);
    if (!key) {
      continue;
    }

    if (lookup.exactByKey.has(key)) {
      return lookup.exactByKey.get(key);
    }

    const sourceTokens = normalizeLiveActivityTeamTokens(variant);
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
  }

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
    Array.from(new Set(teamIdentityNames(team))).forEach((name) => {
      const key = normalizeLiveActivityTeamKey(name);
      if (!key) return;
      exactByKey.add(key);
      candidates.push({
        key,
        tokens: normalizeLiveActivityTeamTokens(name),
      });
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
  const lookup = getLiveActivityPremierLeagueTeamLookup();
  let bestConfidence = 0;

  for (const variant of teamIdentityNames(teamName)) {
    const key = normalizeLiveActivityTeamKey(variant);
    if (!key) continue;
    if (lookup.exactByKey.has(key)) return true;

    const sourceTokens = normalizeLiveActivityTeamTokens(variant);
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
  }

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

  if (isResolvedPenaltyShootoutMatch(match)) {
    return {
      relevant: false,
      reason: "terminal_status",
      kickoff_delta_ms: null,
    };
  }

  if (isLiveMatchStatus(status)) {
    return {
      relevant: true,
      reason: "live_status",
      kickoff_delta_ms: null,
    };
  }

  // Avoid starting monitoring for matches already marked complete.
  if (isTerminalMatchState(match)) {
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

  if (diffMs <= 0 && Math.abs(diffMs) <= RECENT_KICKOFF_PENDING_GRACE_MS) {
    return {
      relevant: true,
      reason: "recent_kickoff_grace",
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

  if (isResolvedPenaltyShootoutMatch(match)) {
    return {
      stop: false,
      reason: "status_penalties",
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

function matchesOnPitchScoreCorrection(entryText, newMatch, reversionState, expectedScorer, entryMinute) {
  if (!entryText.includes("offside")) {
    return false;
  }

  const targetGoalMinute =
    reversionState && reversionState.removedGoal && Number.isFinite(reversionState.removedGoal.minute)
      ? reversionState.removedGoal.minute
      : null;
  if (!entryMinuteWithinWindow(entryMinute, targetGoalMinute, 2)) {
    return false;
  }

  const expectedTeamName =
    reversionState && reversionState.affectedTeam === "away"
      ? String(newMatch && newMatch.away_team ? newMatch.away_team : "").trim()
      : String(newMatch && newMatch.home_team ? newMatch.home_team : "").trim();
  const normalizedExpectedScorer = normalizeLiveTextEntryText(expectedScorer);
  const normalizedExpectedTeam = normalizeLiveTextEntryText(expectedTeamName);

  return (
    (normalizedExpectedScorer && entryText.includes(normalizedExpectedScorer)) ||
    (normalizedExpectedTeam && entryText.includes(normalizedExpectedTeam))
  );
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

function buildScoreCorrectionEvent(matchId, newMatch, confirmation, reversionState) {
  const removedGoal = reversionState && reversionState.removedGoal ? reversionState.removedGoal : null;
  const current = scoreSnapshot(newMatch || {});
  const goalTime =
    (removedGoal && removedGoal.goalTime) ||
    (confirmation && confirmation.goalMinuteLabel) ||
    null;
  const scorer =
    (confirmation && confirmation.scorer) ||
    (removedGoal && removedGoal.player) ||
    null;
  const assister =
    removedGoal && removedGoal.assister ? removedGoal.assister : null;
  const team =
    (confirmation && confirmation.team) ||
    (reversionState && reversionState.affectedTeam) ||
    null;

  return {
    type: "goal",
    team,
    title: "Score correction",
    body: formatScoreline(newMatch, current.home_score, current.away_score),
    goalTime,
    scorer,
    assister,
    ownGoal: Boolean(removedGoal && removedGoal.ownGoal),
    scoreCorrection: true,
    eventKey: [
      "score_correction",
      String(team || ""),
      String(goalTime || ""),
      String(scorer || ""),
      String(current.home_score),
      String(current.away_score),
      String(matchId || ""),
    ].join(":"),
  };
}

async function resolveScoreReversion(matchId, newMatch, reversionState, options = {}) {
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
  let nearbyVarEntry = null;
  let onPitchCorrectionEntry = null;
  const varReviewMinute =
    Number.isFinite(targetGoalMinute) ? targetGoalMinute + VAR_DECISION_REVIEW_WINDOW_MINUTES : null;

  entries.forEach((entry) => {
    if (!entry || !entry.text) return;
    const normalizedText = normalizeLiveTextEntryText(entry.text);
    if (
      !nearbyVarEntry &&
      normalizedText.includes("var") &&
      (
        entryMinuteWithinWindow(entry.minute_value, targetGoalMinute, VAR_DECISION_REVIEW_WINDOW_MINUTES) ||
        entryMinuteWithinWindow(entry.minute_value, varReviewMinute, VAR_DECISION_REVIEW_WINDOW_MINUTES)
      )
    ) {
      nearbyVarEntry = entry;
    }

    if (
      !onPitchCorrectionEntry &&
      matchesOnPitchScoreCorrection(normalizedText, newMatch, reversionState, expectedScorer, entry.minute_value)
    ) {
      onPitchCorrectionEntry = entry;
    }

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
        varReviewMinute,
        VAR_DECISION_REVIEW_WINDOW_MINUTES
      )
    ) {
      if (!noGoalEntry) noGoalEntry = entry;
    }
  });

  if (overturnedEntry || noGoalEntry) {
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
    reversionState.resolutionKind = "var_disallowed";
    logDecision("var_disallowed_confirmation", {
      match_id: matchId,
      result: "confirmed",
      goal_minute: goalMinuteLabel || null,
      decision_minute: decisionMinuteLabel || null,
      scorer: scorer || null,
      team: team || null,
    });

    return {
      kind: "var_disallowed",
      team,
      scorer,
      goalMinuteLabel,
      decisionMinuteLabel,
    };
  }

  if (
    !onPitchCorrectionEntry &&
    Number(reversionState.consecutivePolls || 0) < SCORE_CORRECTION_CONFIRMATION_POLLS
  ) {
    logDecision("score_correction_confirmation", {
      match_id: matchId,
      result: "awaiting_stable_reversion",
      consecutive_polls: Number(reversionState.consecutivePolls || 0),
      required_polls: SCORE_CORRECTION_CONFIRMATION_POLLS,
      expected_scorer: expectedScorer || null,
      reverted_home_score: revertedSnapshot.home_score,
      reverted_away_score: revertedSnapshot.away_score,
    });
    return null;
  }

  if (nearbyVarEntry) {
    logDecision("score_correction_confirmation", {
      match_id: matchId,
      result: "awaiting_var_resolution",
      consecutive_polls: Number(reversionState.consecutivePolls || 0),
      var_minute: nearbyVarEntry.minute || null,
      expected_scorer: expectedScorer || null,
    });
    return null;
  }

  const goalMinuteLabel =
    reversionState.removedGoal && reversionState.removedGoal.goalTime
      ? reversionState.removedGoal.goalTime
      : null;
  const correctionMinuteLabel =
    onPitchCorrectionEntry && onPitchCorrectionEntry.minute ? onPitchCorrectionEntry.minute : null;
  const team = reversionState.affectedTeam || null;

  reversionState.confirmedAtMs = Date.now();
  reversionState.resolutionKind = "score_correction";
  logDecision("score_correction_confirmation", {
    match_id: matchId,
    result: "confirmed",
    goal_minute: goalMinuteLabel || null,
    correction_minute: correctionMinuteLabel || null,
    scorer: expectedScorer || null,
    team,
    consecutive_polls: Number(reversionState.consecutivePolls || 0),
  });

  return {
    kind: "score_correction",
    team,
    scorer: expectedScorer || null,
    goalMinuteLabel,
    correctionMinuteLabel,
  };
}

async function confirmVarDisallowedGoal(matchId, newMatch, reversionState, options = {}) {
  const resolution = await resolveScoreReversion(matchId, newMatch, reversionState, options);
  if (!resolution || resolution.kind !== "var_disallowed") {
    return null;
  }
  const { kind, ...confirmation } = resolution;
  return confirmation;
}

async function confirmScoreCorrection(matchId, newMatch, reversionState, options = {}) {
  const resolution = await resolveScoreReversion(matchId, newMatch, reversionState, options);
  if (!resolution || resolution.kind !== "score_correction") {
    return null;
  }
  const { kind, ...confirmation } = resolution;
  return confirmation;
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
  const newIsFulltime = isTerminalMatchState(newMatch);
  if (!lifecycle.fulltimeEmitted && newIsFulltime && oldStatus !== newStatus) {
    const homeScore = toNumericScore(newMatch.home_score) ?? countGoals(newMatch.home_goal_scorers);
    const awayScore = toNumericScore(newMatch.away_score) ?? countGoals(newMatch.away_goal_scorers);
    let ftBody = formatScoreline(newMatch, homeScore, awayScore);

    if (newStatus === "AET") {
      ftBody += " (AET)";
    }
    const penaltySuffix = penaltyResultSuffix(newMatch);
    if (penaltySuffix) {
      ftBody += penaltySuffix;
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

function buildNotificationPayload(matchId, event) {
  const payload = {
    event_type: event && event.type ? event.type : null,
    match_id: matchId,
  };
  if (event && event.eventKey) payload.event_key = event.eventKey;
  if (event && event.goalTime) payload.goal_time = event.goalTime;
  if (event && event.disallowedByVar) payload.disallowed_by_var = true;
  if (event && event.scoreCorrection) payload.score_correction = true;
  if (event && event.varDecisionTime) payload.var_decision_time = event.varDecisionTime;
  return payload;
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
  return ` (agg: ${aggregateHomeScore}-${aggregateAwayScore})`;
}

function formatScoreline(match, homeScore, awayScore) {
  return (
    `${match && match.home_team ? match.home_team : "Home"} ${homeScore} - ${awayScore} ` +
    `${match && match.away_team ? match.away_team : "Away"}${aggregateScoreSuffix(match, homeScore, awayScore)}`
  );
}

function penaltyResultSuffix(match) {
  const penaltyResult = String(match && match.penalty_result ? match.penalty_result : "").trim();
  if (!penaltyResult) {
    return "";
  }
  return ` (${penaltyResult})`;
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
let fantasyDeadlineReminderEvalTimer = null;
let liveActivityEvalInFlight = false;
let liveActivityEvalStartedAtMs = 0;
let fantasyDeadlineReminderEvalInFlight = false;
let fantasyDeadlineReminderLastEvaluationAt = null;
let fantasyDeadlineReminderLastEvaluationError = null;
let fantasyDeadlineReminderLastStats = null;
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

function setLiveActivityMatchDetailsProvider(provider) {
  liveActivityMatchDetailsProvider = typeof provider === "function" ? provider : null;
}

function setLiveActivityOperationalMatchesProvider(provider) {
  liveActivityOperationalMatchesProvider = typeof provider === "function" ? provider : null;
}

function setCanonicalMatchStateWriter(writer) {
  canonicalMatchStateWriter = typeof writer === "function" ? writer : null;
}

function shouldAllowInactiveLiveActivityEvaluation(options = {}) {
  if (!options || typeof options !== "object") return false;
  if (options.forceDispatch) return true;
  return Boolean(String(options.userDeviceToken || "").trim());
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

  // Start fantasy deadline reminder evaluation loop.
  void evaluateFantasyDeadlineReminders({ reason: "startup" });
  fantasyDeadlineReminderEvalTimer = setInterval(() => {
    void evaluateFantasyDeadlineReminders({ reason: "interval" });
  }, FANTASY_DEADLINE_REMINDER_EVAL_INTERVAL_MS);
}

/**
 * Stop monitoring
 */
function stopMonitoring() {
  isMonitoring = false;
  console.log("[MatchMonitor] Stopping match monitoring");
  clearStartupLiveActivityKickTimers();
  liveActivityEvalInFlight = false;
  liveActivityEvalStartedAtMs = 0;

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

  if (fantasyDeadlineReminderEvalTimer) {
    clearInterval(fantasyDeadlineReminderEvalTimer);
    fantasyDeadlineReminderEvalTimer = null;
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
      fulltimeEmitted: isTerminalMatchState(seedMatch),
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

    if (typeof canonicalMatchStateWriter === "function") {
      try {
        await canonicalMatchStateWriter(currentMatch, {
          matchId,
          source: "match_monitor_poll",
          reason: "monitor_poll",
        });
      } catch (error) {
        console.warn(
          `[MatchMonitor] Failed to persist canonical match state for ${matchId}:`,
          error && error.message ? error.message : error
        );
      }
    }

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

    // Stop monitoring once the match is finished.
    if (isTerminalMatchState(currentMatch)) {
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
  const confirmedReversion = await resolveScoreReversion(matchId, newMatch, reversionState);
  if (confirmedReversion && confirmedReversion.kind === "var_disallowed") {
    events.push(buildVarDisallowedGoalEvent(matchId, newMatch, confirmedReversion, reversionState));
    monitorState.scoreReversionState = null;
  } else if (confirmedReversion && confirmedReversion.kind === "score_correction") {
    events.push(buildScoreCorrectionEvent(matchId, newMatch, confirmedReversion, reversionState));
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
    const notificationUsers = dedupePushNotificationUsers(allUsers);
    console.log(
      `[MatchMonitor] Checking ${notificationUsers.length} notification target(s) ` +
      `from ${allUsers.length} stored user preference record(s) for ${event.type} event: ` +
      `${match.home_team} vs ${match.away_team}`
    );

    // Filter users who should receive this notification
    const interestedUsers = [];
    for (const user of notificationUsers) {
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
      users_deduped: notificationUsers.length,
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
      if (!liveActivityPreferenceLeagueMatchesSelectedLeagues(prefs.selectedLeagues, match.league)) {
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
    if (
      !liveActivityPreferenceLeagueMatchesSelectedLeagues(
        prefs.notificationSelectedLeagues,
        match.league
      )
    ) {
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

  // Check notification EPL teams filter
  const notifEplOnly = prefs.notificationPremierLeagueTeamsOnly !== undefined
    ? prefs.notificationPremierLeagueTeamsOnly
    : prefs.englishPremierLeagueTeamsOnly;
  if (notifEplOnly) {
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

function canonicalLiveActivityChannelName(channelName) {
  const normalizedChannel = normalizeTextToken(channelName).replace(/[^a-z0-9]+/g, "");
  if (!normalizedChannel) return null;
  if (
    normalizedChannel.includes("amazonprime") ||
    normalizedChannel.includes("primevideo") ||
    normalizedChannel.includes("amazon")
  ) {
    return "Amazon";
  }
  if (
    normalizedChannel.includes("tntsports") ||
    normalizedChannel === "tnt" ||
    normalizedChannel.includes("btsport")
  ) {
    return "TNT Sports";
  }
  if (normalizedChannel.includes("skysports") || normalizedChannel === "sky") {
    return "Sky Sports";
  }
  if (
    normalizedChannel.includes("mlsseasonpass") ||
    normalizedChannel.includes("appletv") ||
    normalizedChannel === "apple"
  ) {
    return "Apple TV";
  }
  if (normalizedChannel.includes("bbc")) {
    return "BBC";
  }
  if (normalizedChannel.includes("itv")) {
    return "ITV";
  }
  if (normalizedChannel.includes("channel4")) {
    return "Channel 4";
  }
  // Filter out placeholder/unknown strings that aren't real channels
  if (
    normalizedChannel === "tbc" ||
    normalizedChannel === "tbd" ||
    normalizedChannel === "tba" ||
    normalizedChannel === "tobeconfirmed" ||
    normalizedChannel === "tobeannounced"
  ) {
    return null;
  }
  return String(channelName || "").trim() || null;
}

function canonicalLiveActivityChannels(channels) {
  const output = [];
  const seen = new Set();

  for (const channel of Array.isArray(channels) ? channels : []) {
    const canonical = canonicalLiveActivityChannelName(channel);
    if (!canonical) continue;
    const key = canonical.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    output.push(canonical);
  }

  return output;
}

const LIVE_ACTIVITY_FIXTURE_TOKEN_STOP_WORDS = new Set([
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
  "as",
  "kf",
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

function liveActivityMatchIdentity(match) {
  if (!match || typeof match !== "object") return null;
  const explicitId = String(match.match_details_id || match.matchId || match.id || "").trim();
  if (explicitId) return explicitId;

  const date = String(match.date || "").trim();
  const time = String(match.time || "").trim();
  const league = String(match.league || "").trim();
  const homeTeam = String(match.home_team || match.homeTeam || "").trim();
  const awayTeam = String(match.away_team || match.awayTeam || "").trim();
  if (!date || !time || !league || !homeTeam || !awayTeam) return null;

  return [date, time, league, homeTeam, awayTeam].join("|");
}

function liveActivityMatchDedupKeys(match, extraIdentity = null) {
  const keys = new Set();

  const explicitId = String(
    (match && (match.match_details_id || match.matchId || match.id)) || extraIdentity || ""
  ).trim();
  if (explicitId) {
    keys.add(explicitId);
  }

  const date = String(match && match.date ? match.date : "").trim();
  const time = String(match && match.time ? match.time : "").trim();
  const league = String(match && match.league ? match.league : "").trim();
  const homeTeam = String(match && (match.home_team || match.homeTeam) ? match.home_team || match.homeTeam : "").trim();
  const awayTeam = String(match && (match.away_team || match.awayTeam) ? match.away_team || match.awayTeam : "").trim();

  if (date && time && league && homeTeam && awayTeam) {
    keys.add([date, time, league, homeTeam, awayTeam].join("|"));
  }

  return Array.from(keys);
}

function normalizeLiveActivityFixtureToken(value) {
  const normalized = String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
  if (!normalized) return "";
  const tokens = normalized
    .split(" ")
    .map((token) => token.trim())
    .filter((token) => token && !LIVE_ACTIVITY_FIXTURE_TOKEN_STOP_WORDS.has(token));
  return tokens.length > 0 ? tokens.join(" ") : normalized;
}

function liveActivityFixtureDedupKeys(match) {
  const keys = new Set();
  if (!match || typeof match !== "object") return [];

  const date = String(match.date || "").trim();
  const league = normalizeLiveActivityFixtureToken(match.league || "");
  const homeTeam = normalizeLiveActivityFixtureToken(match.home_team || match.homeTeam || "");
  const awayTeam = normalizeLiveActivityFixtureToken(match.away_team || match.awayTeam || "");

  if (date && homeTeam && awayTeam) {
    keys.add(`fixture|${date}|${homeTeam}|${awayTeam}`);
    if (league) {
      keys.add(`fixture|${date}|${league}|${homeTeam}|${awayTeam}`);
    }
  }

  return Array.from(keys);
}

function liveActivityEntryDedupKeys(entry) {
  const match = entry && entry.match ? entry.match : null;
  const matchId = entry && entry.matchId ? String(entry.matchId) : null;
  return Array.from(
    new Set([
      ...liveActivityMatchDedupKeys(match, matchId),
      ...liveActivityFixtureDedupKeys(match),
    ])
  );
}

function liveActivityStateRichness(state) {
  if (!state || typeof state !== "object") return -1;
  let richness = 0;
  if (Array.isArray(state.history)) richness += state.history.length * 10;
  if (state.lastState && typeof state.lastState === "object") richness += 3;
  if (Number.isFinite(Number(state.finishedAtMs))) richness += 2;
  if (state.lifecycle && typeof state.lifecycle === "object") richness += 1;
  return richness;
}

function mergeDuplicateLiveActivityEntries(existingEntry, incomingEntry) {
  if (!existingEntry || !existingEntry.match) return incomingEntry;
  if (!incomingEntry || !incomingEntry.match) return existingEntry;

  const existingMatch = existingEntry.match;
  const incomingMatch = incomingEntry.match;
  const freshness = compareLiveActivitySnapshotFreshness(existingMatch, incomingMatch);
  const preferredEntry = freshness > 0 ? existingEntry : incomingEntry;
  const fallbackEntry = preferredEntry === existingEntry ? incomingEntry : existingEntry;
  const preferredState =
    liveActivityStateRichness(existingEntry.state) >= liveActivityStateRichness(incomingEntry.state)
      ? existingEntry.state
      : incomingEntry.state;
  const mergedMatch = mergeSnapshotWithFallback(fallbackEntry.match, preferredEntry.match);

  const channels = canonicalLiveActivityChannelsForMatch(preferredEntry.match);
  const fallbackChannels = canonicalLiveActivityChannelsForMatch(fallbackEntry.match);
  mergedMatch.tv_channels = channels.length > 0 ? channels : fallbackChannels;
  mergedMatch.match_details_id = String(
    preferredEntry.matchId ||
      preferredEntry.match.match_details_id ||
      fallbackEntry.matchId ||
      fallbackEntry.match.match_details_id ||
      ""
  ).trim() || null;

  return {
    matchId:
      liveActivityMatchIdentity(mergedMatch) ||
      preferredEntry.matchId ||
      fallbackEntry.matchId ||
      null,
    state: preferredState || null,
    match: mergedMatch,
  };
}

function dedupeLiveActivityEntries(entries) {
  const deduped = [];
  const keyToIndex = new Map();

  for (const entry of Array.isArray(entries) ? entries : []) {
    if (!entry || !entry.match) continue;
    const dedupeKeys = liveActivityEntryDedupKeys(entry);
    const existingIndex = dedupeKeys.find((key) => keyToIndex.has(key));

    if (existingIndex === undefined) {
      const nextIndex = deduped.length;
      deduped.push(entry);
      dedupeKeys.forEach((key) => keyToIndex.set(key, nextIndex));
      continue;
    }

    const mergedEntry = mergeDuplicateLiveActivityEntries(
      deduped[keyToIndex.get(existingIndex)],
      entry
    );
    const targetIndex = keyToIndex.get(existingIndex);
    deduped[targetIndex] = mergedEntry;
    liveActivityEntryDedupKeys(mergedEntry).forEach((key) => keyToIndex.set(key, targetIndex));
  }

  return deduped
    .filter((entry) => entry && entry.match)
    .map((entry) => ({
      ...entry,
      matchId:
        entry && entry.matchId
          ? entry.matchId
          : liveActivityMatchIdentity(entry && entry.match ? entry.match : null),
    }));
}

function dedupeLiveActivityMatches(matches) {
  return dedupeLiveActivityEntries(
    (Array.isArray(matches) ? matches : []).map((match) => ({
      matchId: liveActivityMatchIdentity(match),
      state: null,
      match,
    }))
  ).map((entry) => entry.match);
}

function combineLiveActivityOperationalMatches(...collections) {
  return dedupeLiveActivityMatches(
    collections.flatMap((collection) => (Array.isArray(collection) ? collection : []))
  );
}

function buildLiveActivityMatchDetailsLookup(detailsRecords) {
  const lookup = new Map();

  const upsert = (payload) => {
    if (!payload || typeof payload !== "object") return;
    const detailsId = String(payload.id || "").trim();
    const pseudoMatch = {
      match_details_id: detailsId || null,
      date: payload.date || null,
      time: payload.time || null,
      league: payload.league || null,
      home_team: payload.home_team || null,
      away_team: payload.away_team || null,
    };
    const keys = liveActivityEntryDedupKeys({
      matchId: detailsId || null,
      match: pseudoMatch,
      state: null,
    });
    if (keys.length === 0) return;

    keys.forEach((key) => {
      const existing = lookup.get(key);
      if (!existing || compareLiveActivitySnapshotFreshness(existing, payload) < 0) {
        lookup.set(key, payload);
      }
    });
  };

  if (detailsRecords instanceof Map) {
    detailsRecords.forEach((payload) => upsert(payload));
  } else if (detailsRecords && typeof detailsRecords === "object") {
    Object.values(detailsRecords).forEach((payload) => upsert(payload));
  }

  return lookup;
}

function enrichLiveActivityOperationalMatch(match, detailsLookup) {
  if (!match || typeof match !== "object") return null;
  if (!(detailsLookup instanceof Map) || detailsLookup.size === 0) {
    return { ...match };
  }

  const lookupKeys = liveActivityEntryDedupKeys({
    matchId: liveActivityMatchIdentity(match),
    match,
    state: null,
  });
  const detailsPayload = lookupKeys
    .map((key) => detailsLookup.get(key))
    .find((candidate) => candidate && typeof candidate === "object");
  if (!detailsPayload) {
    return { ...match };
  }

  const enriched = mergeSnapshotWithFallback(match, {
    date: detailsPayload.date,
    time: detailsPayload.time,
    league: detailsPayload.league,
    league_subcategory: detailsPayload.league_subcategory,
    home_team: detailsPayload.home_team,
    away_team: detailsPayload.away_team,
    home_score: toNumericScore(detailsPayload.home_score),
    away_score: toNumericScore(detailsPayload.away_score),
    aggregate_home_score: toNumericScore(detailsPayload.aggregate_home_score),
    aggregate_away_score: toNumericScore(detailsPayload.aggregate_away_score),
    first_leg_home_score: toNumericScore(detailsPayload.first_leg_home_score),
    first_leg_away_score: toNumericScore(detailsPayload.first_leg_away_score),
    score_status: String(detailsPayload.score_status || "").trim() || null,
    penalty_result: String(detailsPayload.penalty_result || "").trim() || null,
    updated_at: String(detailsPayload.updated_at || "").trim() || null,
    home_goal_scorers: Array.isArray(detailsPayload.home_goal_scorers)
      ? detailsPayload.home_goal_scorers
      : undefined,
    away_goal_scorers: Array.isArray(detailsPayload.away_goal_scorers)
      ? detailsPayload.away_goal_scorers
      : undefined,
    home_assists: Array.isArray(detailsPayload.home_assists)
      ? detailsPayload.home_assists
      : undefined,
    away_assists: Array.isArray(detailsPayload.away_assists)
      ? detailsPayload.away_assists
      : undefined,
    home_red_cards: Array.isArray(detailsPayload.home_red_cards)
      ? detailsPayload.home_red_cards
      : undefined,
    away_red_cards: Array.isArray(detailsPayload.away_red_cards)
      ? detailsPayload.away_red_cards
      : undefined,
    home_yellow_cards: Array.isArray(detailsPayload.home_yellow_cards)
      ? detailsPayload.home_yellow_cards
      : undefined,
    away_yellow_cards: Array.isArray(detailsPayload.away_yellow_cards)
      ? detailsPayload.away_yellow_cards
      : undefined,
  });

  const detailsId = String(detailsPayload.id || "").trim();
  if (detailsId) {
    enriched.match_details_id = detailsId;
  }

  return enriched;
}

function enrichLiveActivityOperationalMatches(matches, detailsRecords) {
  const detailsLookup = buildLiveActivityMatchDetailsLookup(detailsRecords);
  return (Array.isArray(matches) ? matches : [])
    .map((match) => enrichLiveActivityOperationalMatch(match, detailsLookup))
    .filter(Boolean);
}

function canonicalLiveActivityMatchesFromDetailsRecords(detailsRecords) {
  const records = detailsRecords instanceof Map
    ? Array.from(detailsRecords.values())
    : detailsRecords && typeof detailsRecords === "object"
      ? Object.values(detailsRecords)
      : [];

  return records
    .filter((payload) => payload && typeof payload === "object")
    .map((payload) => {
      const matchId = String(payload.id || payload.match_details_id || "").trim();
      if (!matchId) return null;
      return {
        ...payload,
        match_details_id: matchId,
        tv_channels: Array.isArray(payload.tv_channels) ? payload.tv_channels : [],
      };
    })
    .filter(Boolean);
}

function normalizeLiveActivityCompetitionName(value) {
  return String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-zA-Z0-9]+/g, " ")
    .toLowerCase()
    .trim()
    .replace(/\s+/g, " ");
}

const LIVE_ACTIVITY_COMPETITION_STAGE_PATTERNS = [
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

function normalizeLiveActivityCompetitionFilterName(value) {
  let normalized = String(value || "").replace(/\s+/g, " ").trim();
  if (!normalized) return "";

  let changed = true;
  while (changed) {
    changed = false;
    for (const pattern of LIVE_ACTIVITY_COMPETITION_STAGE_PATTERNS) {
      if (pattern.test(normalized)) {
        normalized = normalized.replace(pattern, "").trim();
        normalized = normalized.replace(/[-:–]\s*$/, "").trim();
        changed = true;
      }
    }
  }

  normalized = normalizeLiveActivityCompetitionName(normalized);
  if (!normalized) return "";
  if (/^fifa world cup(?: 2026)? qualifying\b/.test(normalized)) {
    return "fifa world cup 2026";
  }

  const aliases = {
    "efl cup": "english league cup",
    "carabao cup": "english league cup",
    "uefa europa conference league": "uefa conference league",
  };

  return aliases[normalized] || normalized;
}

function liveActivityPreferenceLeagueMatchesSelectedLeagues(selectedLeagues, leagueName) {
  const normalizedLeague = normalizeLiveActivityCompetitionFilterName(leagueName);
  if (!normalizedLeague) return false;
  return (Array.isArray(selectedLeagues) ? selectedLeagues : []).some(
    (selectedLeague) =>
      normalizeLiveActivityCompetitionFilterName(selectedLeague) === normalizedLeague
  );
}

function liveActivityMatchIsMajorUEFAClubKnockoutFixture(match) {
  const descriptor = [
    normalizeLiveActivityCompetitionName(match && match.league),
    normalizeLiveActivityCompetitionName(match && match.league_subcategory),
  ]
    .filter(Boolean)
    .join(" ");

  if (!descriptor) return false;
  if (
    !/\buefa champions league\b|\buefa europa league\b|\buefa conference league\b/.test(descriptor)
  ) {
    return false;
  }

  return /\b(?:quarter(?:\s|-)?finals?|semi(?:\s|-)?finals?|final)\b/.test(descriptor);
}

function buildLiveActivityOperationalMatches(detailsRecords, fallbackMatches = []) {
  const canonicalMatches = canonicalLiveActivityMatchesFromDetailsRecords(detailsRecords);
  const enrichedFallbackMatches = enrichLiveActivityOperationalMatches(fallbackMatches, detailsRecords);
  return combineLiveActivityOperationalMatches(canonicalMatches, enrichedFallbackMatches);
}

async function resolveLiveActivityMatchDetailsRecords(options = {}) {
  const explicitRecords =
    options && options.matchDetailsRecords && typeof options.matchDetailsRecords === "object"
      ? options.matchDetailsRecords
      : null;
  if (explicitRecords) return explicitRecords;

  if (typeof liveActivityMatchDetailsProvider === "function") {
    try {
      const provided = await liveActivityMatchDetailsProvider();
      if (provided instanceof Map) return provided;
      if (provided && typeof provided === "object") return provided;
    } catch (error) {
      console.warn(
        "[MatchMonitor] Failed resolving live activity match details from provider:",
        error.message || error
      );
    }
  }

  const matchDetailsSnapshot = await getAllOperationalMatchDetails();
  return matchDetailsSnapshot && matchDetailsSnapshot.records && typeof matchDetailsSnapshot.records === "object"
    ? matchDetailsSnapshot.records
    : {};
}

async function resolveLiveActivityOperationalMatches(detailsRecords, options = {}) {
  if (Array.isArray(options && options.operationalMatches)) {
    return buildLiveActivityOperationalMatches(detailsRecords, options.operationalMatches);
  }

  if (typeof liveActivityOperationalMatchesProvider === "function") {
    try {
      const provided = await liveActivityOperationalMatchesProvider();
      if (Array.isArray(provided)) {
        return buildLiveActivityOperationalMatches(detailsRecords, provided);
      }
    } catch (error) {
      console.warn(
        "[MatchMonitor] Failed resolving live activity operational matches from provider:",
        error.message || error
      );
    }
  }

  const datasetRecords = await getOperationalDatasets([
    "merged_matches",
    "bbc_range_matches",
    "recent_matches",
  ]);
  const fallbackMatches = [
    ...(Array.isArray(datasetRecords.merged_matches && datasetRecords.merged_matches.payload)
      ? datasetRecords.merged_matches.payload
      : []),
    ...(Array.isArray(datasetRecords.bbc_range_matches && datasetRecords.bbc_range_matches.payload)
      ? datasetRecords.bbc_range_matches.payload.map((match) => ({ ...match, has_bbc_source: true }))
      : []),
    ...(Array.isArray(datasetRecords.recent_matches && datasetRecords.recent_matches.payload)
      ? datasetRecords.recent_matches.payload
      : []),
  ];

  return buildLiveActivityOperationalMatches(detailsRecords, fallbackMatches);
}

function currentLondonDateKey(nowMs = Date.now()) {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date(nowMs));
}

function isLiveActivityMatchOnCurrentDate(match, nowMs = Date.now()) {
  const dateKey = String(match && match.date ? match.date : "").trim();
  return Boolean(dateKey) && dateKey === currentLondonDateKey(nowMs);
}

function canonicalLiveActivityChannelsForMatch(match) {
  const channels = canonicalLiveActivityChannels(match && match.tv_channels);
  return channels;
}

function filterCanonicalLiveActivityMatchesForUser(matches, user, nowMs = Date.now()) {
  const prefs = user && user.preferences && typeof user.preferences === "object" ? user.preferences : {};
  const englishPremierLeagueTeamsOnly = prefs.englishPremierLeagueTeamsOnly === true;
  const majorUEFAClubGamesEnabled = prefs.majorUEFAClubGamesEnabled === true;

  return (Array.isArray(matches) ? matches : [])
    .filter((match) => match && typeof match === "object")
    .filter((match) => isLiveActivityMatchOnCurrentDate(match, nowMs))
    .filter((match) => !isPostponedMatchStatus(match && match.score_status))
    .filter((match) => {
      if (
        prefs.competitionFilterEnabled &&
        Array.isArray(prefs.selectedLeagues) &&
        prefs.selectedLeagues.length > 0
      ) {
        return liveActivityPreferenceLeagueMatchesSelectedLeagues(
          prefs.selectedLeagues,
          match.league
        );
      }
      return true;
    })
    .map((match) => {
      const canonicalChannels = canonicalLiveActivityChannelsForMatch(match);
      if (
        prefs.channelFilterEnabled &&
        Array.isArray(prefs.selectedChannels) &&
        prefs.selectedChannels.length > 0
      ) {
        const relevantChannels = canonicalChannels.filter((channel) =>
          prefs.selectedChannels.some((selection) => channelMatchesSelection(channel, selection))
        );
        if (relevantChannels.length === 0) {
          return null;
        }
        return {
          ...match,
          tv_channels: relevantChannels,
        };
      }

      return {
        ...match,
        tv_channels: canonicalChannels,
      };
    })
    .filter(Boolean)
    .filter((match) => {
      if (!englishPremierLeagueTeamsOnly) return true;
      if (
        isEnglishPremierLeagueTeam(match && match.home_team) ||
        isEnglishPremierLeagueTeam(match && match.away_team)
      ) {
        return true;
      }
      return majorUEFAClubGamesEnabled && liveActivityMatchIsMajorUEFAClubKnockoutFixture(match);
    });
}

function compareCanonicalFixtureMatchesByKickoffAsc(lhs, rhs) {
  const lhsDate = String(lhs && lhs.date ? lhs.date : "");
  const rhsDate = String(rhs && rhs.date ? rhs.date : "");
  if (lhsDate !== rhsDate) return lhsDate.localeCompare(rhsDate);

  const lhsTime = String(lhs && lhs.time ? lhs.time : "");
  const rhsTime = String(rhs && rhs.time ? rhs.time : "");
  if (lhsTime !== rhsTime) return lhsTime.localeCompare(rhsTime);

  const lhsLeague = String(lhs && lhs.league ? lhs.league : "");
  const rhsLeague = String(rhs && rhs.league ? rhs.league : "");
  if (lhsLeague !== rhsLeague) return lhsLeague.localeCompare(rhsLeague);

  const lhsHome = String(lhs && lhs.home_team ? lhs.home_team : "");
  const rhsHome = String(rhs && rhs.home_team ? rhs.home_team : "");
  if (lhsHome !== rhsHome) return lhsHome.localeCompare(rhsHome);

  const lhsAway = String(lhs && lhs.away_team ? lhs.away_team : "");
  const rhsAway = String(rhs && rhs.away_team ? rhs.away_team : "");
  return lhsAway.localeCompare(rhsAway);
}

function firstFixtureSectionMatches(matches) {
  if (!Array.isArray(matches) || matches.length === 0) return [];
  const firstDate = String(matches[0] && matches[0].date ? matches[0].date : "").trim();
  if (!firstDate) return [];
  return matches.filter((match) => String(match && match.date ? match.date : "").trim() === firstDate);
}

function liveActivityStatusProgressValue(status) {
  const normalized = normalizeStatusToken(status);
  const minute = parseStatusMinute(normalized);
  if (Number.isFinite(minute)) return minute;
  if (normalized === "LIVE") return 1;
  if (normalized === "HT") return 45.5;
  if (normalized === "ET") return 105;
  if (isFinishedMatchStatus(normalized)) return normalized === "AET" ? 190 : 180;
  if (isPenaltyShootoutStatus(normalized)) return 200;
  return -1;
}

function totalKnownMatchScore(match) {
  const homeScore = toNumericScore(match && match.home_score);
  const awayScore = toNumericScore(match && match.away_score);
  if (!Number.isFinite(homeScore) || !Number.isFinite(awayScore)) return null;
  return homeScore + awayScore;
}

function parseUpdatedAtMs(match) {
  const updatedAtMs = Date.parse(String(match && match.updated_at ? match.updated_at : "").trim());
  return Number.isFinite(updatedAtMs) ? updatedAtMs : null;
}

function compareLiveActivitySnapshotFreshness(lhs, rhs) {
  const lhsHasPenaltyResult = hasPenaltyShootoutResult(lhs);
  const rhsHasPenaltyResult = hasPenaltyShootoutResult(rhs);
  if (lhsHasPenaltyResult !== rhsHasPenaltyResult) {
    return lhsHasPenaltyResult ? 1 : -1;
  }

  const lhsProgress = liveActivityStatusProgressValue(lhs && lhs.score_status);
  const rhsProgress = liveActivityStatusProgressValue(rhs && rhs.score_status);
  if (lhsProgress !== rhsProgress) return lhsProgress - rhsProgress;

  const lhsUpdatedAtMs = parseUpdatedAtMs(lhs);
  const rhsUpdatedAtMs = parseUpdatedAtMs(rhs);
  if (lhsUpdatedAtMs !== null && rhsUpdatedAtMs !== null && lhsUpdatedAtMs !== rhsUpdatedAtMs) {
    return lhsUpdatedAtMs - rhsUpdatedAtMs;
  }

  const lhsTotalScore = totalKnownMatchScore(lhs);
  const rhsTotalScore = totalKnownMatchScore(rhs);
  if (lhsTotalScore !== null && rhsTotalScore !== null && lhsTotalScore !== rhsTotalScore) {
    return lhsTotalScore - rhsTotalScore;
  }

  return 0;
}

function mergeCanonicalLiveActivityMatch(canonicalMatch, liveStateMatch) {
  const canonical = canonicalMatch && typeof canonicalMatch === "object" ? canonicalMatch : {};
  const liveState = liveStateMatch && typeof liveStateMatch === "object" ? liveStateMatch : null;
  if (!liveState) {
    return {
      ...canonical,
      tv_channels: canonicalLiveActivityChannelsForMatch(canonical),
    };
  }

  const merged = mergeSnapshotWithFallback(liveState, canonical);

  const canonicalChannels = canonicalLiveActivityChannelsForMatch(canonical);
  const liveStateChannels = canonicalLiveActivityChannelsForMatch(liveState);
  merged.tv_channels = canonicalChannels.length > 0 ? canonicalChannels : liveStateChannels;
  merged.match_details_id =
    String(canonical.match_details_id || liveState.match_details_id || "").trim() || null;

  return merged;
}

function buildLiveActivityEntryLookup(entries) {
  const lookup = new Map();

  for (const entry of Array.isArray(entries) ? entries : []) {
    const match = entry && entry.match ? entry.match : null;
    const matchId = liveActivityMatchIdentity(match) || (entry && entry.matchId ? String(entry.matchId) : null);
    if (!matchId || !match) continue;
    const normalizedEntry = {
      matchId,
      state: entry && entry.state ? entry.state : null,
      match,
    };
    // Index by both exact (ID/time-based) and time-insensitive fixture keys so that canonical
    // matches can find monitored entries even when kickoff times diverge between sources.
    for (const key of liveActivityEntryDedupKeys({ matchId, match, state: null })) {
      if (lookup.has(key)) continue;
      lookup.set(key, normalizedEntry);
    }
  }

  return lookup;
}

function shouldIncludeMonitoredEntryForLiveActivity(entry, user, nowMs = Date.now()) {
  const match = entry && entry.match ? entry.match : null;
  if (!match) return false;
  if (!isLiveActivityMatchOnCurrentDate(match, nowMs)) return false;

  const eligibility = isEligibleForLiveActivityByPreferences(user, match);
  if (!eligibility.eligible) return false;

  const kickoffMs = parseMatchDateTimeMs(match);
  const status = match.score_status;

  if (isPostponedMatchStatus(status)) {
    return false;
  }

  if (isLikelyTerminalStaleLiveMatch(match, kickoffMs, nowMs)) {
    return false;
  }

  if (isResolvedPenaltyShootoutMatch(match)) {
    const hasTrackedState = Boolean(entry && entry.state && typeof entry.state === "object");
    if (!hasTrackedState && parseUpdatedAtMs(match) === null) {
      return false;
    }
    return shouldRetainFinishedMatchForLiveActivity(entry, nowMs);
  }

  if (isLiveMatchStatus(status)) {
    return true;
  }

  if (isFinishedMatchStatus(status) || isPenaltyShootoutStatus(status)) {
    const hasTrackedState = Boolean(entry && entry.state && typeof entry.state === "object");
    if (!hasTrackedState && parseUpdatedAtMs(match) === null) {
      return false;
    }
    return shouldRetainFinishedMatchForLiveActivity(entry, nowMs);
  }

  if (!Number.isFinite(kickoffMs)) {
    return false;
  }

  const diff = kickoffMs - nowMs;
  if (diff > 0 && diff <= UPCOMING_MONITOR_WINDOW_MS) {
    return true;
  }
  if (diff <= 0 && Math.abs(diff) <= RECENT_KICKOFF_PENDING_GRACE_MS) {
    return true;
  }

  return false;
}

function buildLiveActivityEntriesForUser(user, monitoredEntries, operationalMatches, nowMs = Date.now()) {
  const monitoredById = buildLiveActivityEntryLookup(monitoredEntries);
  const canonicalMatches = filterCanonicalLiveActivityMatchesForUser(operationalMatches, user, nowMs)
    .slice()
    .sort(compareCanonicalFixtureMatchesByKickoffAsc);
  const fixtureSectionMatches = firstFixtureSectionMatches(canonicalMatches);
  const entries = [];
  const seenKeys = new Set();

  fixtureSectionMatches.forEach((canonicalMatch) => {
    const matchId = liveActivityMatchIdentity(canonicalMatch);
    // Use fixture-level keys (time-insensitive) in addition to exact keys so that a canonical
    // match already seen via a monitored entry with a drifted kickoff time is not re-added.
    const dedupeKeys = liveActivityEntryDedupKeys({ matchId, match: canonicalMatch });
    if (!matchId || dedupeKeys.some((key) => seenKeys.has(key))) return;

    // Try exact-ID lookup first; fall back to time-insensitive fixture keys so that a monitored
    // entry started under a slightly different kickoff time is still merged into the canonical.
    let monitoredEntry = monitoredById.get(matchId) || null;
    if (!monitoredEntry) {
      for (const fixtureKey of liveActivityFixtureDedupKeys(canonicalMatch)) {
        const found = monitoredById.get(fixtureKey);
        if (found) {
          monitoredEntry = found;
          break;
        }
      }
    }

    const mergedMatch = mergeCanonicalLiveActivityMatch(
      canonicalMatch,
      monitoredEntry && monitoredEntry.match ? monitoredEntry.match : null
    );
    entries.push({
      matchId,
      state: monitoredEntry ? monitoredEntry.state : null,
      match: mergedMatch,
    });
    // Register all keys (including fixture keys) so subsequent monitored entries for the same
    // game with drifted metadata are recognised as duplicates and skipped.
    liveActivityEntryDedupKeys({ matchId, match: mergedMatch }).forEach((key) => seenKeys.add(key));
  });

  for (const monitoredEntry of Array.isArray(monitoredEntries) ? monitoredEntries : []) {
    const monitoredMatch = monitoredEntry && monitoredEntry.match ? monitoredEntry.match : null;
    const matchId =
      liveActivityMatchIdentity(monitoredMatch) ||
      (monitoredEntry && monitoredEntry.matchId ? String(monitoredEntry.matchId) : null);
    // Use fixture-level keys so an entry whose time differs from an already-seen canonical is skipped.
    const dedupeKeys = liveActivityEntryDedupKeys({ matchId, match: monitoredMatch });
    if (!matchId || dedupeKeys.some((key) => seenKeys.has(key))) continue;
    if (!shouldIncludeMonitoredEntryForLiveActivity(monitoredEntry, user, nowMs)) continue;

    const mergedMatch = mergeCanonicalLiveActivityMatch(monitoredMatch, monitoredMatch);
    entries.push({
      matchId,
      state: monitoredEntry && monitoredEntry.state ? monitoredEntry.state : null,
      match: mergedMatch,
    });
    liveActivityEntryDedupKeys({ matchId, match: mergedMatch }).forEach((key) => seenKeys.add(key));
  }

  return dedupeLiveActivityEntries(entries);
}

function collectLiveActivityTimelineCandidateMatchIds(monitoredEntries, operationalMatches) {
  const matchIds = new Set();
  const collectFromMatch = (match) => {
    if (!match || typeof match !== "object") return;
    if (!isLiveMatchStatus(match.score_status)) return;
    const matchId = liveActivityMatchIdentity(match);
    if (!matchId) return;
    matchIds.add(String(matchId).trim().toLowerCase());
  };

  (Array.isArray(monitoredEntries) ? monitoredEntries : []).forEach((entry) => {
    collectFromMatch(entry && entry.match ? entry.match : null);
  });
  (Array.isArray(operationalMatches) ? operationalMatches : []).forEach((match) => {
    collectFromMatch(match);
  });

  return Array.from(matchIds);
}

async function loadRedisDelayedSnapshotsByMatchId(matchIds, delayMinutes, nowMs = Date.now()) {
  const normalizedDelayMinutes = Math.max(0, Number(delayMinutes || 0));
  if (normalizedDelayMinutes <= 0) return {};

  const normalizedMatchIds = Array.from(
    new Set(
      (Array.isArray(matchIds) ? matchIds : [])
        .map((matchId) => String(matchId || "").trim().toLowerCase())
        .filter(Boolean)
    )
  );
  if (normalizedMatchIds.length === 0) return {};

  const targetMs = nowMs - normalizedDelayMinutes * 60 * 1000;
  if (!Number.isFinite(targetMs) || targetMs <= 0) return {};

  return getLiveActivityMatchTimelineSnapshotsAt(normalizedMatchIds, targetMs);
}

function compareLiveActivityMatches(lhs, rhs) {
  const leftKickoff = Number(parseMatchDateTimeMs(lhs) || 0);
  const rightKickoff = Number(parseMatchDateTimeMs(rhs) || 0);
  if (leftKickoff !== rightKickoff) return rightKickoff - leftKickoff;

  const lhsTeamScore = liveActivityTeamScoreTotal(lhs);
  const rhsTeamScore = liveActivityTeamScoreTotal(rhs);
  if (lhsTeamScore !== rhsTeamScore) return rhsTeamScore - lhsTeamScore;
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

function compareUpcomingLiveActivityMatches(lhs, rhs) {
  const leftKickoff = Number(parseMatchDateTimeMs(lhs) || 0);
  const rightKickoff = Number(parseMatchDateTimeMs(rhs) || 0);
  if (leftKickoff !== rightKickoff) return leftKickoff - rightKickoff;

  const lhsTeamScore = liveActivityTeamScoreTotal(lhs);
  const rhsTeamScore = liveActivityTeamScoreTotal(rhs);
  if (lhsTeamScore !== rhsTeamScore) return rhsTeamScore - lhsTeamScore;

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
    if (!liveActivityPreferenceLeagueMatchesSelectedLeagues(prefs.selectedLeagues, match.league)) {
      return {
        eligible: false,
        reason: "league_filtered_out",
      };
    }
  }

  if (prefs.channelFilterEnabled && Array.isArray(prefs.selectedChannels) && prefs.selectedChannels.length > 0) {
    const channels = Array.isArray(match.tv_channels) ? match.tv_channels : [];
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

  if (prefs.englishPremierLeagueTeamsOnly) {
    const homeInPremierLeague = isEnglishPremierLeagueTeam(match && match.home_team);
    const awayInPremierLeague = isEnglishPremierLeagueTeam(match && match.away_team);
    if (
      !homeInPremierLeague &&
      !awayInPremierLeague &&
      !(prefs.majorUEFAClubGamesEnabled && liveActivityMatchIsMajorUEFAClubKnockoutFixture(match))
    ) {
      return {
        eligible: false,
        reason: "premier_league_team_filter",
      };
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
    home_goal_scorers: Array.isArray(match.home_goal_scorers)
      ? match.home_goal_scorers.map((entry) => ({ ...entry }))
      : [],
    away_goal_scorers: Array.isArray(match.away_goal_scorers)
      ? match.away_goal_scorers.map((entry) => ({ ...entry }))
      : [],
    updated_at: match.updated_at || null,
    tv_channels: canonicalLiveActivityChannels(match.tv_channels),
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
  let latestEligibleTimestampMs = null;
  let maxHomeScore = null;
  let maxAwayScore = null;
  for (let index = history.length - 1; index >= 0; index -= 1) {
    const entry = history[index];
    if (!entry || !entry.match) continue;
    if (Number(entry.timestampMs) <= targetMs) {
      if (!latestEligible) {
        latestEligible = entry.match;
        latestEligibleTimestampMs = Number(entry.timestampMs);
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
    if (
      Number.isFinite(latestEligibleTimestampMs) &&
      targetMs - latestEligibleTimestampMs > LIVE_ACTIVITY_DELAY_SNAPSHOT_STALE_TOLERANCE_MS
    ) {
      return null;
    }
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

function calculateFantasyCurrentScore(fantasyState) {
  return fantasyScore.calculateFantasyCurrentScore(fantasyState);
}

function hasConnectedFantasyTeam(fantasyState) {
  const candidateIDs = [
    fantasyState && fantasyState.managerEntryID,
    fantasyState && fantasyState.squad && fantasyState.squad.managerEntryID,
  ];
  return candidateIDs.some((candidateID) => {
    const numericID = Number(candidateID);
    return Number.isInteger(numericID) && numericID > 0;
  });
}

function userRecordUpdatedAtMs(user) {
  const parsed = Date.parse(String(user && user.updatedAt ? user.updatedAt : "").trim());
  return Number.isFinite(parsed) ? parsed : 0;
}

function buildPushNotificationTarget(user) {
  const apnsToken = String(user && user.apnsToken ? user.apnsToken : "").trim();
  if (apnsToken) {
    return {
      targetKey: `apns:${apnsToken}`,
      dedupeBasis: "apns_token",
    };
  }

  const deviceToken = String(user && user.deviceToken ? user.deviceToken : "").trim();
  if (deviceToken) {
    return {
      targetKey: `device:${deviceToken}`,
      dedupeBasis: "device_token",
    };
  }

  return null;
}

function dedupePushNotificationUsers(users) {
  const deduped = new Map();

  (Array.isArray(users) ? users : []).forEach((user) => {
    const target = buildPushNotificationTarget(user);
    if (!target) return;

    const existing = deduped.get(target.targetKey);
    if (!existing || userRecordUpdatedAtMs(user) >= userRecordUpdatedAtMs(existing)) {
      deduped.set(target.targetKey, user);
    }
  });

  return Array.from(deduped.values());
}

function safeIntlDateTimeFormat(locale, options) {
  try {
    return new Intl.DateTimeFormat(locale || undefined, options);
  } catch (_error) {
    return new Intl.DateTimeFormat(undefined, options);
  }
}

function isValidTimeZone(value) {
  const candidate = String(value || "").trim();
  if (!candidate) return false;
  try {
    new Intl.DateTimeFormat("en-GB", { timeZone: candidate }).format(Date.now());
    return true;
  } catch (_error) {
    return false;
  }
}

function userPreferencesForReminder(user) {
  return user && user.preferences && typeof user.preferences === "object" ? user.preferences : {};
}

function resolveFantasyReminderTimeZone(user) {
  const prefs = userPreferencesForReminder(user);
  const candidates = [
    prefs.deviceTimeZone,
    prefs.deviceTimezone,
    prefs.timeZone,
    prefs.timezone,
  ];
  for (const candidate of candidates) {
    if (isValidTimeZone(candidate)) {
      return String(candidate).trim();
    }
  }
  return FANTASY_DEADLINE_REMINDER_DEFAULT_TIMEZONE;
}

function resolveFantasyReminderLocale(user) {
  const prefs = userPreferencesForReminder(user);
  const candidate = String(
    prefs.deviceLocale || prefs.locale || prefs.language || "en-GB"
  ).trim();
  return candidate || "en-GB";
}

function localDateKeyForTimeZone(timestampMs, timeZone) {
  if (!Number.isFinite(timestampMs)) return "";
  return safeIntlDateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(timestampMs);
}

function fantasyDeadlineRelativeDayLabel(deadlineTimeMs, nowMs, timeZone, locale) {
  const deadlineDateKey = localDateKeyForTimeZone(deadlineTimeMs, timeZone);
  if (!deadlineDateKey) return "";
  const todayKey = localDateKeyForTimeZone(nowMs, timeZone);
  if (deadlineDateKey === todayKey) return "today";
  const tomorrowKey = localDateKeyForTimeZone(nowMs + 24 * 60 * 60 * 1000, timeZone);
  if (deadlineDateKey === tomorrowKey) return "tomorrow";
  return safeIntlDateTimeFormat(locale, {
    timeZone,
    weekday: "short",
    day: "2-digit",
    month: "short",
  }).format(deadlineTimeMs);
}

function formatFantasyDeadlineReminderTime(deadlineTimeMs, user, nowMs = Date.now()) {
  const timeZone = resolveFantasyReminderTimeZone(user);
  const locale = resolveFantasyReminderLocale(user);
  const timeLabel = safeIntlDateTimeFormat(locale, {
    timeZone,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(deadlineTimeMs);
  const relativeLabel = fantasyDeadlineRelativeDayLabel(
    deadlineTimeMs,
    nowMs,
    timeZone,
    locale
  );
  return relativeLabel ? `${timeLabel} ${relativeLabel}` : timeLabel;
}

function buildFantasyReminderTarget(user) {
  const apnsToken = String(user && user.apnsToken ? user.apnsToken : "").trim();
  if (apnsToken) {
    return {
      targetKey: `apns:${apnsToken}`,
      dedupeBasis: "apns_token",
    };
  }

  const deviceToken = String(user && user.deviceToken ? user.deviceToken : "").trim();
  if (deviceToken) {
    return {
      targetKey: `device:${deviceToken}`,
      dedupeBasis: "device_token",
    };
  }

  return null;
}

function buildFantasyDeadlineReminderId(targetKey, nextGameweek) {
  const gameweekId = String(nextGameweek && nextGameweek.id ? nextGameweek.id : "unknown").trim();
  const deadlineTime = String(
    nextGameweek && nextGameweek.deadline_time ? nextGameweek.deadline_time : ""
  ).trim();
  const digest = crypto
    .createHash("sha1")
    .update(`${targetKey}|${gameweekId}|${deadlineTime}`)
    .digest("hex");
  return `fantasy_deadline:${gameweekId}:${digest}`;
}

function buildFantasyDeadlineReminderBody(deadlineTimeMs, user, nowMs = Date.now()) {
  return `Reminder: Fantasy Football deadline due soon (${formatFantasyDeadlineReminderTime(
    deadlineTimeMs,
    user,
    nowMs
  )})`;
}

function buildFantasyDeadlineReminderBodyFromRecord(record, nowMs = Date.now()) {
  const deadlineTimeMs = Number(record && record.deadline_time_ms);
  if (!Number.isFinite(deadlineTimeMs)) {
    return String(
      record && record.body ? record.body : "Reminder: Fantasy Football deadline due soon"
    );
  }

  return buildFantasyDeadlineReminderBody(
    deadlineTimeMs,
    {
      preferences: {
        deviceTimeZone:
          record && record.device_time_zone ? String(record.device_time_zone).trim() : undefined,
        deviceLocale:
          record && record.device_locale ? String(record.device_locale).trim() : undefined,
      },
    },
    nowMs
  );
}

function evaluateFantasyDeadlineReminderDecision(user, nextGameweek, nowMs = Date.now()) {
  const prefs = userPreferencesForReminder(user);
  const target = buildFantasyReminderTarget(user);
  const deadlineTimeRaw = String(
    nextGameweek && nextGameweek.deadline_time ? nextGameweek.deadline_time : ""
  ).trim();
  const deadlineTimeMs = Date.parse(deadlineTimeRaw);

  if (!prefs.notificationsEnabled) {
    return { shouldSchedule: false, reason: "notifications_disabled" };
  }
  if (prefs.fantasyDeadlineRemindersEnabled === false) {
    return { shouldSchedule: false, reason: "deadline_reminder_disabled" };
  }
  if (!String(user && user.apnsToken ? user.apnsToken : "").trim()) {
    return { shouldSchedule: false, reason: "missing_apns_token" };
  }
  if (!target) {
    return { shouldSchedule: false, reason: "missing_delivery_target" };
  }
  if (!hasConnectedFantasyTeam(user && user.fantasy)) {
    return { shouldSchedule: false, reason: "missing_fantasy_team" };
  }
  if (!Number.isFinite(deadlineTimeMs)) {
    return { shouldSchedule: false, reason: "invalid_deadline_time" };
  }
  if (deadlineTimeMs <= nowMs) {
    return { shouldSchedule: false, reason: "deadline_passed" };
  }

  return {
    shouldSchedule: true,
    reason: "eligible",
    deadlineTimeMs: Math.floor(deadlineTimeMs),
    scheduledForMs: Math.floor(deadlineTimeMs - FANTASY_DEADLINE_REMINDER_LOOKAHEAD_MS),
    targetKey: target.targetKey,
    dedupeBasis: target.dedupeBasis,
  };
}

function buildFantasyDeadlineReminderRecord(user, nextGameweek, nowMs = Date.now(), decision = null) {
  const resolvedDecision =
    decision && typeof decision === "object"
      ? decision
      : evaluateFantasyDeadlineReminderDecision(user, nextGameweek, nowMs);
  if (!resolvedDecision.shouldSchedule) {
    return null;
  }

  const reminderId = buildFantasyDeadlineReminderId(resolvedDecision.targetKey, nextGameweek);
  const title = "Fantasy Football deadline";
  const body = buildFantasyDeadlineReminderBody(
    resolvedDecision.deadlineTimeMs,
    user,
    resolvedDecision.scheduledForMs
  );
  const deviceTimeZone = resolveFantasyReminderTimeZone(user);
  const deviceLocale = resolveFantasyReminderLocale(user);

  return {
    reminder_id: reminderId,
    kind: "fantasy_deadline",
    source: "fantasy_deadline_reminder",
    status: "scheduled",
    target_key: resolvedDecision.targetKey,
    dedupe_basis: resolvedDecision.dedupeBasis,
    device_token: user && user.deviceToken ? String(user.deviceToken).trim() : null,
    apns_token: user && user.apnsToken ? String(user.apnsToken).trim() : null,
    is_development_build: Boolean(user && user.isDevelopmentBuild),
    user_updated_at: user && user.updatedAt ? String(user.updatedAt) : null,
    gameweek_id:
      nextGameweek && nextGameweek.id !== undefined && nextGameweek.id !== null
        ? Number(nextGameweek.id)
        : null,
    gameweek_name:
      nextGameweek && nextGameweek.name ? String(nextGameweek.name).trim() : null,
    scheduled_for_ms: resolvedDecision.scheduledForMs,
    deadline_time_ms: resolvedDecision.deadlineTimeMs,
    device_time_zone: deviceTimeZone,
    device_locale: deviceLocale,
    title,
    body,
    payload: {
      type: "fantasy_deadline_reminder",
      source: "fantasy_deadline_reminder",
      reminderId,
      gameweekId:
        nextGameweek && nextGameweek.id !== undefined && nextGameweek.id !== null
          ? Number(nextGameweek.id)
          : null,
      gameweekName:
        nextGameweek && nextGameweek.name ? String(nextGameweek.name).trim() : null,
      deadlineTime: new Date(resolvedDecision.deadlineTimeMs).toISOString(),
      scheduledFor: new Date(resolvedDecision.scheduledForMs).toISOString(),
      deviceTimeZone,
      deviceLocale,
    },
  };
}

function dedupeFantasyDeadlineReminderUsers(users, nextGameweek, nowMs = Date.now()) {
  const deduped = new Map();

  (Array.isArray(users) ? users : []).forEach((user) => {
    const decision = evaluateFantasyDeadlineReminderDecision(user, nextGameweek, nowMs);
    if (!decision.shouldSchedule) return;

    const existing = deduped.get(decision.targetKey);
    if (!existing || userRecordUpdatedAtMs(user) >= userRecordUpdatedAtMs(existing.user)) {
      deduped.set(decision.targetKey, { user, decision });
    }
  });

  return Array.from(deduped.values()).map((entry) => ({
    ...entry,
    record: buildFantasyDeadlineReminderRecord(entry.user, nextGameweek, nowMs, entry.decision),
  }));
}

function fantasyReminderStatus(record) {
  return String(record && record.status ? record.status : "").trim().toLowerCase();
}

function isFantasyDeadlineReminderDue(record, nowMs = Date.now()) {
  const status = fantasyReminderStatus(record);
  const scheduledForMs = Number(record && record.scheduled_for_ms);
  const deadlineTimeMs = Number(record && record.deadline_time_ms);
  return (
    status === "scheduled" &&
    Number.isFinite(scheduledForMs) &&
    Number.isFinite(deadlineTimeMs) &&
    scheduledForMs <= nowMs &&
    deadlineTimeMs > nowMs
  );
}

function fantasyCurrentScoreForUser(user) {
  const fantasy = user && user.fantasy && typeof user.fantasy === "object" ? user.fantasy : null;
  if (!hasConnectedFantasyTeam(fantasy)) return null;
  return calculateFantasyCurrentScore(fantasy);
}

function liveActivityModeForMatches(
  liveMatches,
  finishedMatches,
  recentKickoffMatches,
  upcomingMatches
) {
  if (liveMatches.length > 0) {
    const liveAndFinishedCount = liveMatches.length + finishedMatches.length;
    return liveAndFinishedCount > 1 ? "multi_live" : "single_live";
  }
  if (recentKickoffMatches.length > 1) return "multi_upcoming";
  if (recentKickoffMatches.length === 1) return "single_upcoming";
  if (finishedMatches.length > 1) return "multi_finished";
  if (finishedMatches.length === 1) return "single_finished";
  if (upcomingMatches.length > 1) return "multi_upcoming";
  if (upcomingMatches.length === 1) return "single_upcoming";
  return null;
}

function sanitizeAggregateForLiveActivity(match) {
  if (!match || typeof match !== "object") return match;

  const aggregateHomeScore = toNumericScore(match.aggregate_home_score);
  const aggregateAwayScore = toNumericScore(match.aggregate_away_score);
  if (Number.isFinite(aggregateHomeScore) && Number.isFinite(aggregateAwayScore)) {
    return {
      ...match,
      aggregate_home_score: aggregateHomeScore,
      aggregate_away_score: aggregateAwayScore,
    };
  }

  return {
    ...match,
    aggregate_home_score: null,
    aggregate_away_score: null,
  };
}

function resolveLiveActivityAggregateScores(match) {
  if (!match || typeof match !== "object") {
    return { home: null, away: null };
  }

  const aggregateHomeScore = toNumericScore(match.aggregate_home_score);
  const aggregateAwayScore = toNumericScore(match.aggregate_away_score);
  return { home: aggregateHomeScore, away: aggregateAwayScore };
}

function shouldSuppressPreKickoffScoresForLiveActivity(match, nowMs = Date.now()) {
  if (!match || typeof match !== "object") return false;

  const status = match.score_status;
  if (
    isLiveMatchStatus(status) ||
    isFinishedMatchStatus(status) ||
    isPenaltyShootoutStatus(status)
  ) {
    return false;
  }

  const homeScore = toNumericScore(match.home_score);
  const awayScore = toNumericScore(match.away_score);
  const aggregateHomeScore = toNumericScore(match.aggregate_home_score);
  const aggregateAwayScore = toNumericScore(match.aggregate_away_score);
  const hasKnownPrimaryScore = Number.isFinite(homeScore) || Number.isFinite(awayScore);
  const hasKnownAggregateScore =
    Number.isFinite(aggregateHomeScore) || Number.isFinite(aggregateAwayScore);
  if (!hasKnownPrimaryScore && !hasKnownAggregateScore) {
    return false;
  }

  const kickoffMs = parseMatchDateTimeMs(match);
  if (!Number.isFinite(kickoffMs)) {
    return false;
  }

  const diffMs = kickoffMs - nowMs;
  if (diffMs > 0) {
    return true;
  }

  return (
    homeScore === 0 &&
    awayScore === 0 &&
    Math.abs(diffMs) <= RECENT_KICKOFF_PENDING_GRACE_MS
  );
}

function sanitizePreKickoffScoresForLiveActivity(match, nowMs = Date.now(), context = "unknown") {
  if (!shouldSuppressPreKickoffScoresForLiveActivity(match, nowMs)) {
    return match;
  }

  const kickoffMs = parseMatchDateTimeMs(match);
  logDecision("live_activity_pre_kickoff_score_suppressed", {
    context,
    match_id: String(match && match.match_details_id ? match.match_details_id : ""),
    home_team: match && match.home_team ? String(match.home_team) : "",
    away_team: match && match.away_team ? String(match.away_team) : "",
    home_score:
      match && match.home_score !== undefined && match.home_score !== null
        ? Number(match.home_score)
        : null,
    away_score:
      match && match.away_score !== undefined && match.away_score !== null
        ? Number(match.away_score)
        : null,
    aggregate_home_score:
      match && match.aggregate_home_score !== undefined && match.aggregate_home_score !== null
        ? Number(match.aggregate_home_score)
        : null,
    aggregate_away_score:
      match && match.aggregate_away_score !== undefined && match.aggregate_away_score !== null
        ? Number(match.aggregate_away_score)
        : null,
    score_status: match && match.score_status ? String(match.score_status) : null,
    seconds_to_kickoff:
      Number.isFinite(kickoffMs) ? Math.floor((kickoffMs - nowMs) / 1000) : null,
  });

  return {
    ...match,
    home_score: null,
    away_score: null,
    score_status: null,
  };
}

function buildLiveActivityContentState(
  mode,
  matches,
  delayMinutes,
  nowMs = Date.now(),
  fantasyCurrentScore = null
) {
  const delayLabel = delayMinutes > 0 && (mode === "single_live" || mode === "multi_live")
    ? `Delayed ${delayMinutes} m`
    : null;
  const normalizedMatches = dedupeLiveActivityMatches(matches).map((rawMatch) => {
    const match = mode.includes("upcoming")
      ? sanitizePreKickoffScoresForLiveActivity(rawMatch, nowMs, "content_state")
      : rawMatch;
    const aggregate = resolveLiveActivityAggregateScores(match);
    return {
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
    aggregateHomeScore: aggregate.home,
    aggregateAwayScore: aggregate.away,
    firstLegHomeScore: toNumericScore(match.first_leg_home_score),
    firstLegAwayScore: toNumericScore(match.first_leg_away_score),
    matchTime: displayStatusToken(match.score_status),
    penaltyWinner: penaltyShootoutWinnerSide(match),
    homeTeamScore: toNumericScore(match.home_team_score),
    awayTeamScore: toNumericScore(match.away_team_score),
    totalTeamScore: toNumericScore(match.total_team_score),
    tvChannels: canonicalLiveActivityChannels(match.tv_channels).slice(0, 3),
    };
  });

  return {
    mode,
    generatedAtEpochSeconds: Math.floor(nowMs / 1000),
    delayMinutes: Number(delayMinutes || 0),
    delayLabel,
    fantasyCurrentScore:
      fantasyCurrentScore !== null &&
      fantasyCurrentScore !== undefined &&
      Number.isFinite(Number(fantasyCurrentScore))
        ? Number(fantasyCurrentScore)
        : null,
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
  const matchSummaries = Array.isArray(contentState && contentState.matches)
    ? contentState.matches.map((match) => ({
      match_id: String(match && match.matchId ? match.matchId : ""),
      score:
        Number.isFinite(match && match.homeScore) && Number.isFinite(match && match.awayScore)
          ? `${match.homeScore}-${match.awayScore}`
          : null,
      status: match && match.matchTime ? String(match.matchTime) : null,
    }))
    : [];
  const diagnostics = {
    user_device_short: shortDeviceToken(user.deviceToken),
    event,
    mode: presentation && presentation.mode ? presentation.mode : null,
    match_count: metrics.matchCount,
    content_state_bytes: metrics.contentStateBytes,
    archive_estimate_bytes: metrics.archiveEstimateBytes,
    payload_hash_prefix: payloadHash ? String(payloadHash).slice(0, 12) : null,
    delay_minutes: Number(presentation && presentation.delayMinutes ? presentation.delayMinutes : 0),
    matches: matchSummaries,
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

function buildLiveActivityPayloadHash(contentState) {
  if (!contentState || typeof contentState !== "object") {
    return stableHash(null);
  }

  const { generatedAtEpochSeconds, ...stableContentState } = contentState;
  return stableHash(stableContentState);
}

function buildLiveActivityScoreHash(contentState) {
  const matches = Array.isArray(contentState && contentState.matches) ? contentState.matches : [];
  return stableHash({
    mode:
      contentState && Object.prototype.hasOwnProperty.call(contentState, "mode")
        ? contentState.mode
        : null,
    fantasyCurrentScore:
      contentState &&
      contentState.fantasyCurrentScore !== null &&
      contentState.fantasyCurrentScore !== undefined &&
      Number.isFinite(Number(contentState.fantasyCurrentScore))
        ? Number(contentState.fantasyCurrentScore)
        : null,
    matches: matches.map((match) => ({
      matchId: String(match && match.matchId ? match.matchId : ""),
      homeScore: toNumericScore(match && match.homeScore),
      awayScore: toNumericScore(match && match.awayScore),
      aggregateHomeScore: toNumericScore(match && match.aggregateHomeScore),
      aggregateAwayScore: toNumericScore(match && match.aggregateAwayScore),
      penaltyWinner:
        match && Object.prototype.hasOwnProperty.call(match, "penaltyWinner")
          ? String(match.penaltyWinner || "").trim() || null
          : null,
    })),
  });
}

function isLiveActivityLiveMode(mode) {
  return typeof mode === "string" && mode.includes("live");
}

function isLiveActivityUpcomingMode(mode) {
  return typeof mode === "string" && mode.includes("upcoming");
}

function parseLiveActivityDispatchTimeMs(state) {
  const dispatchAtMs = Date.parse(String(state && state.lastDispatchAt ? state.lastDispatchAt : ""));
  return Number.isFinite(dispatchAtMs) ? dispatchAtMs : null;
}

function buildLiveActivityApsPayload(event, contentState, options = {}) {
  const normalizedEvent = String(event || "").trim().toLowerCase();
  const aps = {
    timestamp: Number.isFinite(Number(options.timestamp))
      ? Math.floor(Number(options.timestamp))
      : Math.floor(Date.now() / 1000),
    event: normalizedEvent,
  };

  if (contentState && typeof contentState === "object") {
    aps["content-state"] = contentState;
  }
  if (Number.isFinite(Number(options.staleDate))) {
    aps["stale-date"] = Math.floor(Number(options.staleDate));
  }
  if (normalizedEvent === "start") {
    aps["attributes-type"] = LIVE_ACTIVITY_ATTRIBUTES_TYPE;
    aps.attributes = LIVE_ACTIVITY_ATTRIBUTES;
    if (options.alert && typeof options.alert === "object") {
      aps.alert = options.alert;
    }
  }
  if (normalizedEvent === "end" && Number.isFinite(Number(options.dismissalDate))) {
    aps["dismissal-date"] = Math.floor(Number(options.dismissalDate));
  }

  return { aps };
}

async function persistLiveActivityDebug(user, payload = {}) {
  if (!user || !user.deviceToken) return;
  if (!payload || typeof payload !== "object" || Object.keys(payload).length === 0) return;
  try {
    await saveLiveActivityDebugRecord(user.deviceToken, payload);
  } catch (error) {
    console.warn(
      `[MatchMonitor] Failed persisting live activity debug for ${shortDeviceToken(
        user.deviceToken
      )}:`,
      error.message || error
    );
  }
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

function liveActivitySkipReason(state, payloadHash, mode, forceDispatch = false, options = {}) {
  if (forceDispatch) return null;
  if (state.lastPayloadHash === payloadHash && state.lastMode === mode) {
    return "identical_payload";
  }
  if (state.lastMode !== mode) {
    return null;
  }
  if (!isLiveActivityLiveMode(mode)) {
    return null;
  }

  const scoreHash =
    options && Object.prototype.hasOwnProperty.call(options, "scoreHash") ? options.scoreHash : null;
  if (scoreHash && state.lastScoreHash !== scoreHash) {
    return null;
  }

  const nowMs =
    options && Number.isFinite(Number(options.nowMs)) ? Number(options.nowMs) : Date.now();
  const lastDispatchAtMs = parseLiveActivityDispatchTimeMs(state);
  if (lastDispatchAtMs === null) {
    return null;
  }

  if (nowMs - lastDispatchAtMs < LIVE_ACTIVITY_NON_SCORE_UPDATE_MIN_INTERVAL_MS) {
    return "non_score_throttle";
  }

  return null;
}

function logLiveActivitySkipDiagnostics(user, presentation, contentState, state, reason, options = {}) {
  if (!reason) return;
  const payloadHash = options && options.payloadHash ? String(options.payloadHash) : null;
  const scoreHash = options && options.scoreHash ? String(options.scoreHash) : null;
  const nowMs =
    options && Number.isFinite(Number(options.nowMs)) ? Number(options.nowMs) : Date.now();
  const lastDispatchAtMs = parseLiveActivityDispatchTimeMs(state);
  const diagnostics = {
    user_device_short: shortDeviceToken(user && user.deviceToken),
    reason,
    mode: presentation && presentation.mode ? presentation.mode : null,
    payload_hash_prefix: payloadHash ? payloadHash.slice(0, 12) : null,
    score_hash_prefix: scoreHash ? scoreHash.slice(0, 12) : null,
    previous_payload_hash_prefix:
      state && state.lastPayloadHash ? String(state.lastPayloadHash).slice(0, 12) : null,
    previous_score_hash_prefix:
      state && state.lastScoreHash ? String(state.lastScoreHash).slice(0, 12) : null,
    last_mode: state && state.lastMode ? String(state.lastMode) : null,
    last_dispatch_at: state && state.lastDispatchAt ? String(state.lastDispatchAt) : null,
    seconds_since_last_dispatch:
      lastDispatchAtMs === null ? null : Math.max(0, Math.round((nowMs - lastDispatchAtMs) / 1000)),
    matches: Array.isArray(contentState && contentState.matches)
      ? contentState.matches.map((match) => ({
        match_id: String(match && match.matchId ? match.matchId : ""),
        score:
          Number.isFinite(match && match.homeScore) && Number.isFinite(match && match.awayScore)
            ? `${match.homeScore}-${match.awayScore}`
            : null,
        status: match && match.matchTime ? String(match.matchTime) : null,
      }))
      : [],
  };
  console.log(`[MatchMonitor] Live Activity skip ${JSON.stringify(diagnostics)}`);
}

function shouldSkipLiveActivityUpdate(state, payloadHash, mode, forceDispatch = false, options = {}) {
  return liveActivitySkipReason(state, payloadHash, mode, forceDispatch, options) !== null;
}

function shouldPreserveExistingLiveActivityOnEmpty(activityPushToken, options = {}, state = {}) {
  if (!activityPushToken || !String(activityPushToken).trim()) {
    return false;
  }
  if (options && options.preserveExistingOnEmpty) {
    return true;
  }
  return isLiveActivityUpcomingMode(state && state.lastMode);
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
    if (
      shouldPreserveExistingLiveActivityOnEmpty(
        activityPushToken,
        { preserveExistingOnEmpty },
        state
      )
    ) {
      console.log(
        `[MatchMonitor] Live Activity preserve existing on empty ${JSON.stringify({
          user_device_short: shortDeviceToken(user && user.deviceToken),
          reason: "preserve_existing_on_empty",
          activity_token_present: Boolean(activityPushToken),
          pending_start: hasPendingStart,
          mode: presentation && presentation.mode ? presentation.mode : null,
        })}`
      );
      await persistLiveActivityDebug(user, {
        record_type: "decision",
        decision_type: "preserve_existing_on_empty",
        mode: presentation && presentation.mode ? presentation.mode : null,
        activity_token_present: Boolean(activityPushToken),
        pending_start_present: hasPendingStart,
        preserve_existing_on_empty: preserveExistingOnEmpty,
      });
      return;
    }
    if (isTestHoldActive) {
      console.log(
        `[MatchMonitor] Live Activity hold active ${JSON.stringify({
          user_device_short: shortDeviceToken(user && user.deviceToken),
          reason: "test_hold_active",
          hold_until: state && state.testHoldUntil ? String(state.testHoldUntil) : null,
        })}`
      );
      await persistLiveActivityDebug(user, {
        record_type: "decision",
        decision_type: "test_hold_active",
        hold_until: state && state.testHoldUntil ? String(state.testHoldUntil) : null,
      });
      return;
    }
    if (hasPendingStart) {
      await persistLiveActivityPatch(user, {
        pendingStartAt: null,
        lastPayloadHash: null,
        lastScoreHash: null,
        lastMode: null,
      });
    }
    if (!activityPushToken) return;
    const endedContentState = {
      mode: "ended",
      generatedAtEpochSeconds: Math.floor(nowMs / 1000),
      delayMinutes: 0,
      delayLabel: null,
      matches: [],
    };
    const endRawPayload = buildLiveActivityApsPayload("end", endedContentState, {
      timestamp: Math.floor(nowMs / 1000),
      dismissalDate: Math.floor(nowMs / 1000),
    });
    const endDispatchStartedAtMs = Date.now();
    const result = await sendLiveActivityPush({
      token: activityPushToken,
      event: "end",
      contentState: endedContentState,
      dismissalDate: Math.floor(nowMs / 1000),
      isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
    });
    const endDispatchCompletedAtMs = Date.now();
    liveActivityMetrics.recordPush({
      event: "end",
      status: result.success ? "success" : "failure",
      isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
    });
    await persistLiveActivityDebug(user, {
      record_type: "push",
      dispatch_kind: "end",
      status: result.success ? "success" : "failure",
      mode: "ended",
      environment: result && result.environment ? result.environment : null,
      elapsed_ms: Math.max(0, endDispatchCompletedAtMs - endDispatchStartedAtMs),
      dispatch_started_at: new Date(endDispatchStartedAtMs).toISOString(),
      dispatch_completed_at: new Date(endDispatchCompletedAtMs).toISOString(),
      push_token_kind: "activity",
      current_activity_id: state && state.currentActivityId ? String(state.currentActivityId) : null,
      error: result && result.error ? String(result.error) : null,
      is_terminal: Boolean(result && result.isTerminal),
      raw_payload: endRawPayload,
      content_state: endedContentState,
    });
    const patch = {
      currentActivityPushToken: null,
      currentActivityId: null,
      pendingStartAt: null,
      lastPayloadHash: null,
      lastScoreHash: null,
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
    nowMs,
    presentation.fantasyCurrentScore
  );
  const payloadHash = buildLiveActivityPayloadHash(contentState);
  const scoreHash = buildLiveActivityScoreHash(contentState);

  if (activityPushToken) {
    const skipReason = liveActivitySkipReason(state, payloadHash, presentation.mode, forceDispatch, {
      scoreHash,
      nowMs,
    });
    if (skipReason) {
      logLiveActivitySkipDiagnostics(user, presentation, contentState, state, skipReason, {
        payloadHash,
        scoreHash,
        nowMs,
      });
      await persistLiveActivityDebug(user, {
        record_type: "decision",
        decision_type: "skip",
        decision_reason: skipReason,
        mode: presentation.mode,
        payload_hash: payloadHash,
        score_hash: scoreHash,
        last_mode: state && state.lastMode ? String(state.lastMode) : null,
        last_payload_hash: state && state.lastPayloadHash ? String(state.lastPayloadHash) : null,
        last_score_hash: state && state.lastScoreHash ? String(state.lastScoreHash) : null,
        last_dispatch_at: state && state.lastDispatchAt ? String(state.lastDispatchAt) : null,
        content_state: contentState,
      });
      return;
    }
    logLiveActivityPayloadDiagnostics(user, "update", presentation, contentState, nowMs, payloadHash);
    const updateRawPayload = buildLiveActivityApsPayload("update", contentState, {
      timestamp: Math.floor(nowMs / 1000),
      staleDate: Math.floor(nowMs / 1000) + LIVE_ACTIVITY_DEFAULT_STALE_AFTER_SECONDS,
    });
    const updateDispatchStartedAtMs = Date.now();
    const updateResult = await sendLiveActivityPush({
      token: activityPushToken,
      event: "update",
      contentState,
      staleDate: Math.floor(nowMs / 1000) + LIVE_ACTIVITY_DEFAULT_STALE_AFTER_SECONDS,
      isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
    });
    const updateDispatchCompletedAtMs = Date.now();
    liveActivityMetrics.recordPush({
      event: "update",
      status: updateResult.success ? "success" : "failure",
      isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
    });
    await persistLiveActivityDebug(user, {
      record_type: "push",
      dispatch_kind: "update",
      status: updateResult.success ? "success" : "failure",
      mode: presentation.mode,
      environment: updateResult && updateResult.environment ? updateResult.environment : null,
      elapsed_ms: Math.max(0, updateDispatchCompletedAtMs - updateDispatchStartedAtMs),
      dispatch_started_at: new Date(updateDispatchStartedAtMs).toISOString(),
      dispatch_completed_at: new Date(updateDispatchCompletedAtMs).toISOString(),
      push_token_kind: "activity",
      current_activity_id: state && state.currentActivityId ? String(state.currentActivityId) : null,
      payload_hash: payloadHash,
      score_hash: scoreHash,
      error: updateResult && updateResult.error ? String(updateResult.error) : null,
      is_terminal: Boolean(updateResult && updateResult.isTerminal),
      raw_payload: updateRawPayload,
      content_state: contentState,
    });
    if (updateResult.success) {
      await persistLiveActivityPatch(user, {
        lastPayloadHash: payloadHash,
        lastScoreHash: scoreHash,
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
        lastScoreHash: null,
        lastMode: null,
      });
    }
    return;
  }

  // When the app is in the foreground it calls the reconcile endpoint, which returns a
  // foregroundStart content state so the app can call Activity.request() directly.
  // Skip push-to-start here to avoid a race between the two creation paths that would
  // produce duplicate activities (one of which enforceSingleActiveActivity would then end).
  const trigger = String(options && options.trigger ? options.trigger : "");
  if (trigger === "app_foreground") return;
  if (!pushToStartToken) return;
  if (hasPendingStart && pendingAgeMs < LIVE_ACTIVITY_PENDING_MAX_MS) {
    // A start push already succeeded; wait for activity push token from app and avoid duplicate starts.
    console.log(
      `[MatchMonitor] Live Activity pending start wait ${JSON.stringify({
        user_device_short: shortDeviceToken(user && user.deviceToken),
        reason: "pending_start_wait",
        pending_age_seconds: Math.max(0, Math.round(pendingAgeMs / 1000)),
        pending_max_seconds: Math.round(LIVE_ACTIVITY_PENDING_MAX_MS / 1000),
      })}`
    );
    await persistLiveActivityDebug(user, {
      record_type: "decision",
      decision_type: "pending_start_wait",
      pending_start_at: state && state.pendingStartAt ? String(state.pendingStartAt) : null,
      pending_age_seconds: Math.max(0, Math.round(pendingAgeMs / 1000)),
      pending_max_seconds: Math.round(LIVE_ACTIVITY_PENDING_MAX_MS / 1000),
    });
    return;
  }
  if (hasPendingStart && pendingAgeMs >= LIVE_ACTIVITY_PENDING_MAX_MS) {
    // Stale lock recovery for extreme edge cases (e.g. token callback never arrives).
    await persistLiveActivityPatch(user, {
      pendingStartAt: null,
      lastPayloadHash: null,
      lastScoreHash: null,
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
  const startRawPayload = buildLiveActivityApsPayload("start", contentState, {
    timestamp: Math.floor(nowMs / 1000),
    staleDate: Math.floor(nowMs / 1000) + LIVE_ACTIVITY_DEFAULT_STALE_AFTER_SECONDS,
    alert: {
      title,
      body,
    },
  });
  const startDispatchStartedAtMs = Date.now();
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
  const startDispatchCompletedAtMs = Date.now();
  liveActivityMetrics.recordPush({
    event: "start",
    status: startResult.success ? "success" : "failure",
    isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
  });
  await persistLiveActivityDebug(user, {
    record_type: "push",
    dispatch_kind: "start",
    status: startResult.success ? "success" : "failure",
    mode: presentation.mode,
    trigger: trigger || null,
    environment: startResult && startResult.environment ? startResult.environment : null,
    elapsed_ms: Math.max(0, startDispatchCompletedAtMs - startDispatchStartedAtMs),
    dispatch_started_at: new Date(startDispatchStartedAtMs).toISOString(),
    dispatch_completed_at: new Date(startDispatchCompletedAtMs).toISOString(),
    push_token_kind: "push_to_start",
    payload_hash: payloadHash,
    score_hash: scoreHash,
    error: startResult && startResult.error ? String(startResult.error) : null,
    is_terminal: Boolean(startResult && startResult.isTerminal),
    raw_payload: startRawPayload,
    content_state: contentState,
  });
  if (startResult.success) {
    liveActivityMetrics.recordStart({
      isDevelopmentBuild: Boolean(user.isDevelopmentBuild),
    });
    await persistLiveActivityPatch(user, {
      pendingStartAt: new Date(nowMs).toISOString(),
      lastStartAt: new Date(nowMs).toISOString(),
      lastPayloadHash: payloadHash,
      lastScoreHash: scoreHash,
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
      lastScoreHash: null,
      lastMode: null,
      lastDispatchAt: new Date(nowMs).toISOString(),
      testHoldUntil: null,
    });
  }
}

function buildLiveActivityPresentationForUser(user, entries, nowMs = Date.now(), options = {}) {
  const prefs = user && user.preferences && typeof user.preferences === "object" ? user.preferences : {};
  const delayMinutes = liveActivityDelayMinutesFromPreferences(prefs);
  const delayedSnapshotsByMatchId =
    options && options.delayedSnapshotsByMatchId && typeof options.delayedSnapshotsByMatchId === "object"
      ? options.delayedSnapshotsByMatchId
      : null;
  const fantasyCurrentScore = fantasyCurrentScoreForUser(user);
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
      fantasyCurrentScore,
    };
  }

  const liveMatches = [];
  const finishedMatches = [];
  const recentKickoffMatches = [];
  const upcomingMatches = [];

  for (const entry of dedupeLiveActivityEntries(eligible)) {
    const state = entry.state || null;
    const currentMatch = entry.match;
    const kickoffMs = parseMatchDateTimeMs(currentMatch);
    const status = currentMatch ? currentMatch.score_status : null;

    if (isPostponedMatchStatus(status)) {
      continue;
    }

    if (isLikelyTerminalStaleLiveMatch(currentMatch, kickoffMs, nowMs)) {
      continue;
    }

    if (isLiveMatchStatus(status)) {
      const timelineMatchId =
        liveActivityMatchIdentity(currentMatch) ||
        (entry && entry.matchId ? String(entry.matchId) : "");
      const delayedFromRedis =
        timelineMatchId && delayedSnapshotsByMatchId
          ? delayedSnapshotsByMatchId[String(timelineMatchId).trim().toLowerCase()] || null
          : null;
      const delayed = delayedFromRedis || delayedSnapshotForMatch(state, delayMinutes, nowMs);
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
        upcomingMatches.push(
          sanitizeAggregateForLiveActivity(
            sanitizePreKickoffScoresForLiveActivity(
              {
                ...currentMatch,
                home_score: null,
                away_score: null,
                score_status: null,
                aggregate_home_score: null,
                aggregate_away_score: null,
              },
              nowMs,
              "presentation_live_without_delay_buffer"
            )
          )
        );
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
      if (diff > 0) {
        // Show all today's upcoming matches regardless of how far away they are.
        // Entries are already filtered to today's date by filterCanonicalLiveActivityMatchesForUser.
        upcomingMatches.push(
          sanitizeAggregateForLiveActivity(
            sanitizePreKickoffScoresForLiveActivity(currentMatch, nowMs, "presentation_upcoming")
          )
        );
      } else if (diff <= 0 && Math.abs(diff) <= RECENT_KICKOFF_PENDING_GRACE_MS) {
        recentKickoffMatches.push(
          sanitizeAggregateForLiveActivity(
            sanitizePreKickoffScoresForLiveActivity(
              {
                ...currentMatch,
                home_score: null,
                away_score: null,
                score_status: null,
                aggregate_home_score: null,
                aggregate_away_score: null,
              },
              nowMs,
              "presentation_recent_kickoff"
            )
          )
        );
      }
    }
  }

  const sortedLive = liveMatches
    .map(annotateMatchWithLiveActivityTeamRatings)
    .sort(compareLiveActivityMatches);
  const sortedFinished = finishedMatches
    .map(annotateMatchWithLiveActivityTeamRatings)
    .sort(compareLiveActivityMatches);
  const sortedLiveAndFinished = [...sortedLive, ...sortedFinished]
    .sort(compareLiveActivityMatches)
    .slice(0, LIVE_ACTIVITY_MAX_MATCHES);
  const sortedRecentKickoff = recentKickoffMatches
    .map(annotateMatchWithLiveActivityTeamRatings)
    .sort(compareUpcomingLiveActivityMatches)
    .slice(0, LIVE_ACTIVITY_MAX_MATCHES);
  const sortedUpcoming = upcomingMatches
    .map(annotateMatchWithLiveActivityTeamRatings)
    .sort(compareUpcomingLiveActivityMatches)
    .slice(0, LIVE_ACTIVITY_MAX_MATCHES);
  const mode = liveActivityModeForMatches(
    sortedLive,
    sortedFinished,
    sortedRecentKickoff,
    sortedUpcoming
  );
  if (!mode) {
    return {
      mode: null,
      matches: [],
      delayMinutes,
      fantasyCurrentScore,
    };
  }

  // For live/finished modes, append today's upcoming matches after the live/finished entries
  // so the widget always shows the full picture of today's action.
  const matchesForMode = dedupeLiveActivityMatches(
    mode.includes("upcoming")
      ? (sortedRecentKickoff.length > 0 ? sortedRecentKickoff : sortedUpcoming)
      : [...sortedLiveAndFinished, ...sortedUpcoming].slice(0, LIVE_ACTIVITY_MAX_MATCHES)
  );

  return {
    mode,
    matches: matchesForMode,
    delayMinutes,
    fantasyCurrentScore,
  };
}

async function evaluateAndDispatchLiveActivities(options = {}) {
  if (!isMonitoring && !shouldAllowInactiveLiveActivityEvaluation(options)) return;
  const evalStartMs = Date.now();
  if (liveActivityEvalInFlight) {
    if (
      Number.isFinite(liveActivityEvalStartedAtMs) &&
      liveActivityEvalStartedAtMs > 0 &&
      evalStartMs - liveActivityEvalStartedAtMs > LIVE_ACTIVITY_EVAL_STALL_TIMEOUT_MS
    ) {
      console.warn(
        `[MatchMonitor] Resetting stalled Live Activity evaluation after ${
          evalStartMs - liveActivityEvalStartedAtMs
        }ms`
      );
      liveActivityEvalInFlight = false;
      liveActivityEvalStartedAtMs = 0;
    } else {
      return;
    }
  }
  liveActivityEvalInFlight = true;
  liveActivityEvalStartedAtMs = evalStartMs;
  const nowMs = evalStartMs;
  const forceDispatch = Boolean(options && options.forceDispatch);
  const preserveExistingOnEmpty = Boolean(options && options.preserveExistingOnEmpty);
  const userDeviceTokenFilter = String(options && options.userDeviceToken ? options.userDeviceToken : "").trim();

  try {
    await ensureLiveActivityTeamRatingCache(nowMs);
    const monitoredEntries = monitoredMatchStatesSnapshot(nowMs);
    const detailsRecords = await resolveLiveActivityMatchDetailsRecords(options);
    const operationalMatches = await resolveLiveActivityOperationalMatches(detailsRecords, options);
    const users = await getAllUserPreferences();
    if (!Array.isArray(users) || users.length === 0) return;

    const filteredUsers = userDeviceTokenFilter
      ? users.filter((user) => String(user && user.deviceToken ? user.deviceToken : "") === userDeviceTokenFilter)
      : users;
    const candidateMatchIds = collectLiveActivityTimelineCandidateMatchIds(
      monitoredEntries,
      operationalMatches
    );
    const delayedSnapshotsByDelay = new Map();
    const distinctDelayMinutes = Array.from(
      new Set(
        filteredUsers
          .map((user) =>
            liveActivityDelayMinutesFromPreferences(
              user && user.preferences && typeof user.preferences === "object"
                ? user.preferences
                : {}
            )
          )
          .filter((delayMinutes) => Number(delayMinutes) > 0)
      )
    );
    for (const delayMinutes of distinctDelayMinutes) {
      // eslint-disable-next-line no-await-in-loop
      delayedSnapshotsByDelay.set(
        Number(delayMinutes),
        await loadRedisDelayedSnapshotsByMatchId(candidateMatchIds, Number(delayMinutes), nowMs)
      );
    }

    for (const user of filteredUsers) {
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

      const entries = buildLiveActivityEntriesForUser(user, monitoredEntries, operationalMatches, nowMs);
      const userDelayMinutes = liveActivityDelayMinutesFromPreferences(
        user && user.preferences && typeof user.preferences === "object" ? user.preferences : {}
      );
      const presentation = buildLiveActivityPresentationForUser(user, entries, nowMs, {
        delayedSnapshotsByMatchId:
          delayedSnapshotsByDelay.get(Number(userDelayMinutes)) || null,
      });
      try {
        await dispatchLiveActivityForUser(user, presentation, nowMs, {
          forceDispatch,
          preserveExistingOnEmpty,
          trigger: String(options && options.trigger ? options.trigger : ""),
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
    liveActivityEvalStartedAtMs = 0;
  }
}

async function runLiveActivityEvaluationNow(options = {}) {
  await evaluateAndDispatchLiveActivities(options);
  return {
    success: true,
    isMonitoring,
    monitoredMatchCount: monitoredMatches.size,
    targetedUserDeviceToken:
      options && options.userDeviceToken ? String(options.userDeviceToken) : null,
  };
}

async function sendFantasyDeadlineReminderRecord(record, options = {}) {
  const reminderId = String(record && record.reminder_id ? record.reminder_id : "").trim();
  if (!reminderId) {
    throw new Error("Missing reminder_id");
  }

  const sendNowMs =
    options && Number.isFinite(Number(options.nowMs)) ? Number(options.nowMs) : Date.now();
  const title = String(record && record.title ? record.title : "Fantasy Football deadline");
  const body = buildFantasyDeadlineReminderBodyFromRecord(record, sendNowMs);
  const apnsToken = String(record && record.apns_token ? record.apns_token : "").trim();
  if (!apnsToken) {
    throw new Error("Missing APNS token for fantasy deadline reminder");
  }

  const isTest = options && options.isTest === true;
  let idempotency = { claimed: true, source: "disabled" };
  if (!isTest) {
    idempotency = await claimFantasyReminderSendIdempotency(reminderId, {
      context: {
        reminder_id: reminderId,
        device_token: shortDeviceToken(record && record.device_token),
        gameweek_id: record && record.gameweek_id ? record.gameweek_id : null,
      },
    });
    if (!idempotency.claimed) {
      return {
        success: false,
        dedupeSkipped: true,
        environment:
          record && record.is_development_build ? "sandbox" : "production",
        idempotencySource: idempotency.source || null,
      };
    }
  }

  const payload = {
    ...(record && record.payload && typeof record.payload === "object" ? record.payload : {}),
    reminderId,
    source: isTest ? "fantasy_deadline_reminder_test" : "fantasy_deadline_reminder",
    requestedAt: new Date(sendNowMs).toISOString(),
    test: isTest,
  };
  const result = await sendNotification(
    apnsToken,
    title,
    body,
    payload,
    Boolean(record && record.is_development_build)
  );
  console.info(
    `[MatchMonitor] Fantasy deadline reminder ${isTest ? "test " : ""}delivery ${
      result && result.success ? "sent" : "failed"
    } reminder_id=${reminderId} device=${shortDeviceToken(
      record && record.device_token
    )} environment=${
      result && result.environment
        ? result.environment
        : record && record.is_development_build
          ? "sandbox"
          : "production"
    } error=${result && result.error ? String(result.error) : "none"}`
  );
  const nowIso = new Date(sendNowMs).toISOString();
  const patch = isTest
    ? {
        reminder_id: reminderId,
        body,
        last_test_sent_at: nowIso,
        last_test_sent_at_ms: Date.parse(nowIso),
        last_test_status: result && result.success ? "sent" : "failed",
        last_test_error: result && result.error ? String(result.error) : null,
        last_test_environment:
          result && result.environment
            ? result.environment
            : record && record.is_development_build
              ? "sandbox"
              : "production",
      }
    : {
        reminder_id: reminderId,
        body,
        status: result && result.success ? "sent" : "failed",
        sent_at: nowIso,
        sent_at_ms: Date.parse(nowIso),
        last_delivery_at: nowIso,
        last_delivery_at_ms: Date.parse(nowIso),
        last_error: result && result.error ? String(result.error) : null,
        environment:
          result && result.environment
            ? result.environment
            : record && record.is_development_build
              ? "sandbox"
              : "production",
        apns_result_success: Boolean(result && result.success),
        idempotency_source: idempotency.source || null,
      };

  await saveFantasyReminderRecord(patch, { mergeExisting: true });
  return {
    ...result,
    dedupeSkipped: false,
    idempotencySource: idempotency.source || null,
  };
}

async function evaluateFantasyDeadlineReminders(options = {}) {
  if (fantasyDeadlineReminderEvalInFlight) {
    return {
      success: false,
      skipped: true,
      reason: "evaluation_in_progress",
      stats: fantasyDeadlineReminderLastStats,
    };
  }

  fantasyDeadlineReminderEvalInFlight = true;
  const nowMs =
    options && Number.isFinite(Number(options.nowMs)) ? Number(options.nowMs) : Date.now();
  const nowIso = new Date(nowMs).toISOString();

  try {
    const nextGameweek = await fetchJsonWithTimeout(`${apiBaseURL}/fantasy/gameweek/next`);
    const deadlineTimeMs = Date.parse(
      String(nextGameweek && nextGameweek.deadline_time ? nextGameweek.deadline_time : "").trim()
    );
    if (!Number.isFinite(deadlineTimeMs) || deadlineTimeMs <= nowMs) {
      fantasyDeadlineReminderLastEvaluationAt = nowIso;
      fantasyDeadlineReminderLastEvaluationError = null;
      fantasyDeadlineReminderLastStats = {
        next_gameweek_id:
          nextGameweek && nextGameweek.id !== undefined && nextGameweek.id !== null
            ? Number(nextGameweek.id)
            : null,
        eligible_count: 0,
        due_count: 0,
        sent_count: 0,
        superseded_count: 0,
        expired_count: 0,
      };
      return {
        success: true,
        nextGameweek,
        stats: fantasyDeadlineReminderLastStats,
      };
    }

    const [allUsers, existingRecords] = await Promise.all([
      getAllUserPreferences(),
      getFantasyReminderRecords({ order: "desc" }),
    ]);
    const dedupedTargets = dedupeFantasyDeadlineReminderUsers(allUsers, nextGameweek, nowMs);
    const eligibleRecords = dedupedTargets
      .map((entry) => entry.record)
      .filter((record) => record && typeof record === "object");
    const eligibleReminderIds = new Set(
      eligibleRecords.map((record) => String(record.reminder_id || "").trim()).filter(Boolean)
    );
    const gameweekId = String(nextGameweek && nextGameweek.id ? nextGameweek.id : "").trim();

    let expiredCount = 0;
    for (const record of existingRecords) {
      const status = fantasyReminderStatus(record);
      const recordDeadlineMs = Number(record && record.deadline_time_ms);
      if (status !== "scheduled" || !Number.isFinite(recordDeadlineMs) || recordDeadlineMs > nowMs) {
        continue;
      }
      // eslint-disable-next-line no-await-in-loop
      await saveFantasyReminderRecord(
        {
          reminder_id: record.reminder_id,
          status: "expired",
          expired_at: nowIso,
          expired_at_ms: nowMs,
        },
        { mergeExisting: true }
      );
      expiredCount += 1;
    }

    let supersededCount = 0;
    for (const record of existingRecords) {
      const recordGameweekId = String(record && record.gameweek_id ? record.gameweek_id : "").trim();
      const status = fantasyReminderStatus(record);
      const recordDeadlineMs = Number(record && record.deadline_time_ms);
      if (
        !gameweekId ||
        recordGameweekId !== gameweekId ||
        status !== "scheduled" ||
        !Number.isFinite(recordDeadlineMs) ||
        recordDeadlineMs <= nowMs
      ) {
        continue;
      }
      if (eligibleReminderIds.has(String(record.reminder_id || "").trim())) {
        continue;
      }
      // eslint-disable-next-line no-await-in-loop
      await saveFantasyReminderRecord(
        {
          reminder_id: record.reminder_id,
          status: "superseded",
          superseded_at: nowIso,
          superseded_at_ms: nowMs,
        },
        { mergeExisting: true }
      );
      supersededCount += 1;
    }

    const dueRecords = [];
    for (const record of eligibleRecords) {
      const existingRecord = await getFantasyReminderRecord(record.reminder_id);
      const existingStatus = fantasyReminderStatus(existingRecord);
      if (existingRecord && (existingStatus === "sent" || existingStatus === "failed")) {
        continue;
      }

      const scheduledRecord =
        existingRecord && existingStatus !== "superseded" && existingStatus !== "expired"
          ? {
              ...record,
              ...existingRecord,
              reminder_id: record.reminder_id,
              status: existingStatus || "scheduled",
            }
          : record;

      // eslint-disable-next-line no-await-in-loop
      const savedRecord = await saveFantasyReminderRecord(
        {
          ...record,
          status: scheduledRecord.status || "scheduled",
        },
        { mergeExisting: true }
      );

      if (isFantasyDeadlineReminderDue(savedRecord, nowMs)) {
        dueRecords.push(savedRecord);
      }
    }

    let sentCount = 0;
    for (const dueRecord of dueRecords) {
      try {
        // eslint-disable-next-line no-await-in-loop
        const result = await sendFantasyDeadlineReminderRecord(dueRecord, {
          isTest: false,
          reason: String(options && options.reason ? options.reason : "scheduled_poll"),
        });
        if (result && result.success) {
          sentCount += 1;
        }
      } catch (error) {
        console.warn(
          `[MatchMonitor] Fantasy deadline reminder send failed ${dueRecord.reminder_id}:`,
          error && error.message ? error.message : error
        );
        // eslint-disable-next-line no-await-in-loop
        await saveFantasyReminderRecord(
          {
            reminder_id: dueRecord.reminder_id,
            status: "failed",
            sent_at: nowIso,
            sent_at_ms: nowMs,
            last_delivery_at: nowIso,
            last_delivery_at_ms: nowMs,
            last_error: error && error.message ? error.message : String(error),
          },
          { mergeExisting: true }
        );
      }
    }

    fantasyDeadlineReminderLastEvaluationAt = nowIso;
    fantasyDeadlineReminderLastEvaluationError = null;
    fantasyDeadlineReminderLastStats = {
      next_gameweek_id:
        nextGameweek && nextGameweek.id !== undefined && nextGameweek.id !== null
          ? Number(nextGameweek.id)
          : null,
      next_gameweek_name:
        nextGameweek && nextGameweek.name ? String(nextGameweek.name) : null,
      deadline_time:
        nextGameweek && nextGameweek.deadline_time ? String(nextGameweek.deadline_time) : null,
      eligible_count: eligibleRecords.length,
      due_count: dueRecords.length,
      sent_count: sentCount,
      superseded_count: supersededCount,
      expired_count: expiredCount,
    };

    return {
      success: true,
      nextGameweek,
      stats: fantasyDeadlineReminderLastStats,
    };
  } catch (error) {
    fantasyDeadlineReminderLastEvaluationAt = nowIso;
    fantasyDeadlineReminderLastEvaluationError = error && error.message ? error.message : String(error);
    console.warn(
      "[MatchMonitor] Fantasy deadline reminder evaluation failed:",
      fantasyDeadlineReminderLastEvaluationError
    );
    return {
      success: false,
      error: fantasyDeadlineReminderLastEvaluationError,
      stats: fantasyDeadlineReminderLastStats,
    };
  } finally {
    fantasyDeadlineReminderEvalInFlight = false;
  }
}

async function runFantasyDeadlineReminderEvaluationNow(options = {}) {
  return evaluateFantasyDeadlineReminders({
    ...options,
    reason: String(options && options.reason ? options.reason : "manual"),
  });
}

async function sendFantasyDeadlineReminderNow(reminderId, options = {}) {
  const record = await getFantasyReminderRecord(reminderId);
  if (!record) {
    return {
      success: false,
      error: "Reminder not found",
      reminderId,
    };
  }

  const currentStatus = fantasyReminderStatus(record);
  const deadlineTimeMs = Number(record && record.deadline_time_ms);
  if (
    currentStatus !== "scheduled" ||
    !Number.isFinite(deadlineTimeMs) ||
    deadlineTimeMs <= Date.now()
  ) {
    return {
      success: false,
      error: "Only upcoming scheduled reminders can be test-sent immediately.",
      reminderId,
    };
  }

  const result = await sendFantasyDeadlineReminderRecord(record, {
    ...options,
    isTest: true,
  });
  return {
    reminderId,
    ...result,
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

    const payload = buildNotificationPayload(matchId, event);

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
    fantasyDeadlineReminders: {
      eval_in_flight: fantasyDeadlineReminderEvalInFlight,
      last_evaluation_at: fantasyDeadlineReminderLastEvaluationAt,
      last_evaluation_error: fantasyDeadlineReminderLastEvaluationError,
      stats: fantasyDeadlineReminderLastStats,
    },
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
  setLiveActivityMatchDetailsProvider,
  setLiveActivityOperationalMatchesProvider,
  setCanonicalMatchStateWriter,
  startMonitoring,
  stopMonitoring,
  getStatus,
  runLiveActivityEvaluationNow,
  runFantasyDeadlineReminderEvaluationNow,
  sendFantasyDeadlineReminderNow,
  __testHooks: {
    annotateMatchWithLiveActivityTeamRatings,
    buildMatchEvents,
    buildFantasyDeadlineReminderBody,
    buildFantasyDeadlineReminderBodyFromRecord,
    buildFantasyDeadlineReminderId,
    buildFantasyDeadlineReminderRecord,
    buildNotificationPayload,
    buildScoreCorrectionEvent,
    buildScoreChangeEvent,
    buildNotificationId,
    buildVarDisallowedGoalEvent,
    confirmScoreCorrection,
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
    isResolvedPenaltyShootoutMatch,
    penaltyShootoutWinnerSide,
    shouldStopMonitoringAsIrrelevant,
    buildLiveActivityContentState,
    buildLiveActivityPayloadHash,
    buildLiveActivityScoreHash,
    buildLiveActivityPresentationForUser,
    calculateFantasyCurrentScore,
    setFantasyScoreContext: fantasyScore.setFantasyScoreContext,
    resetFantasyScoreContext: fantasyScore.resetFantasyScoreContext,
    compareLiveActivityMatches,
    compareUpcomingLiveActivityMatches,
    buildLiveActivityEntriesForUser,
    buildLiveActivityOperationalMatches,
    canonicalLiveActivityMatchesFromDetailsRecords,
    collectLiveActivityTimelineCandidateMatchIds,
    combineLiveActivityOperationalMatches,
    dedupeLiveActivityMatches,
    enrichLiveActivityOperationalMatches,
    dedupePushNotificationUsers,
    dedupeFantasyDeadlineReminderUsers,
    evaluateFantasyDeadlineReminderDecision,
    formatFantasyDeadlineReminderTime,
    monitoredMatchStatesSnapshot,
    evaluateUserNotificationDecision,
    filterCanonicalLiveActivityMatchesForUser,
    isEligibleForLiveActivityByPreferences,
    shouldAllowInactiveLiveActivityEvaluation,
    firstFixtureSectionMatches,
    isFantasyDeadlineReminderDue,
    isEnglishPremierLeagueTeam,
    isLikelyTerminalStaleLiveMatch,
    mergeCanonicalLiveActivityMatch,
    loadRedisDelayedSnapshotsByMatchId,
    sanitizePreKickoffScoresForLiveActivity,
    shouldSuppressPreKickoffScoresForLiveActivity,
    shouldSkipLiveActivityUpdate,
    shouldPreserveExistingLiveActivityOnEmpty,
    updateScoreReversionState,
  },
};
