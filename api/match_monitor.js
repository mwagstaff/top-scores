const {
  getAllUserPreferences,
  saveBbcMatchEventHistory,
  saveBbcNotificationHistory,
  claimBbcNotificationIdempotency,
} = require("./redis_client");
const { sendNotification } = require("./apns_client");

// Configuration
const POLL_INTERVAL_MS = 10 * 1000; // Poll every 10 seconds for monitored matches
const DAILY_MATCHES_CHECK_INTERVAL_MS = 15 * 1000; // Check for today's matches every 15 seconds
const CLEANUP_INTERVAL_MS = 5 * 60 * 1000; // Clean up every 5 minutes
const UPCOMING_MONITOR_WINDOW_MS = 15 * 60 * 1000;
const MAX_MONITOR_DURATION_MS = 6 * 60 * 60 * 1000; // Keep monitoring up to 6h after kickoff
const NOTIFICATION_DEDUP_WINDOW_MS = 6 * 60 * 60 * 1000; // Keep event dedupe for a full match window
const KICKOFF_STATUS_MINUTE_THRESHOLD = 15; // Ignore kickoff if first seen too late in the match
const MATCH_MONITOR_DECISION_LOG_ENABLED = process.env.MATCH_MONITOR_DECISION_LOG !== "0";

// State tracking
const monitoredMatches = new Map(); // matchId -> matchState
const scheduledNotifications = new Map(); // notificationId -> timeout handle
const sentNotifications = new Set(); // Local process dedupe; Redis enforces cross-process idempotency
const finishedMatchIds = new Set(); // Match IDs that have been fully processed - never restart these

// Match status helpers - mirrors server.js MATCH_STATUS_* constants
const MATCH_STATUS_MINUTE_PATTERN = /^(\d{1,3})(?:\+(\d{1,2}))?'?$/;
const MATCH_STATUS_COMPLETE_TOKENS = new Set(["FT", "AET"]);
const MATCH_STATUS_IN_PROGRESS_TOKENS = new Set(["LIVE", "HT", "ET", "PENS", "PEN", "PEN."]);
const MATCH_STATUS_PENALTY_TOKENS = new Set(["PENS", "PEN", "PEN."]);

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

function toNumericScore(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
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

function buildMatchEvents(oldMatch, newMatch, monitorState, nowMs = Date.now(), context = null) {
  const events = [];
  const lifecycle = monitorState.lifecycle;
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
      body: `${newMatch.home_team} ${homeScore} - ${awayScore} ${newMatch.away_team}`,
      eventKey: "halftime",
    });
    lifecycle.halftimeEmitted = true;
  }

  // Full-time (including penalties)
  const newIsFulltime = isFinishedMatchStatus(newStatus) || isPenaltyShootoutStatus(newStatus);
  if (!lifecycle.fulltimeEmitted && newIsFulltime && oldStatus !== newStatus) {
    const homeScore = toNumericScore(newMatch.home_score) ?? countGoals(newMatch.home_goal_scorers);
    const awayScore = toNumericScore(newMatch.away_score) ?? countGoals(newMatch.away_goal_scorers);
    let ftBody = `${newMatch.home_team} ${homeScore} - ${awayScore} ${newMatch.away_team}`;

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
  let newGoalEvents = diffGoalEvents(oldMatch || {}, newMatch || {});

  const homeScoreDelta = currentSnapshot.home_score - previousSnapshot.home_score;
  const awayScoreDelta = currentSnapshot.away_score - previousSnapshot.away_score;
  const expectedGoalDelta = Math.max(0, homeScoreDelta) + Math.max(0, awayScoreDelta);

  // If score did not advance, newly discovered timeline entries are backfill noise.
  if (expectedGoalDelta === 0 && newGoalEvents.length > 0) {
    newGoalEvents = [];
  } else if (expectedGoalDelta > 0 && newGoalEvents.length > expectedGoalDelta) {
    // If timeline data backfills multiple historical goals, keep only the latest goals
    // needed to explain the observed score delta for this poll.
    newGoalEvents = newGoalEvents.slice(newGoalEvents.length - expectedGoalDelta);
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

    let goalBody = `${newMatch.home_team} ${runningHomeScore} - ${runningAwayScore} ${newMatch.away_team}`;
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
    body:
      `${newMatch.home_team || "Home"} ${current.home_score} - ${current.away_score} ` +
      `${newMatch.away_team || "Away"}${statusSuffix}`,
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
let apiBaseURL = "http://localhost:3000/api/v1";

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

  // Start daily matches check
  checkTodaysMatches();
  dailyMatchesCheckTimer = setInterval(checkTodaysMatches, DAILY_MATCHES_CHECK_INTERVAL_MS);

  // Start cleanup timer
  cleanupTimer = setInterval(cleanup, CLEANUP_INTERVAL_MS);
}

/**
 * Stop monitoring
 */
function stopMonitoring() {
  isMonitoring = false;
  console.log("[MatchMonitor] Stopping match monitoring");

  if (dailyMatchesCheckTimer) {
    clearInterval(dailyMatchesCheckTimer);
    dailyMatchesCheckTimer = null;
  }

  if (cleanupTimer) {
    clearInterval(cleanupTimer);
    cleanupTimer = null;
  }

  // Cancel all scheduled notifications
  for (const [, timeout] of scheduledNotifications) {
    clearTimeout(timeout);
  }
  scheduledNotifications.clear();
  monitoredMatches.clear();
  finishedMatchIds.clear();
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

async function checkTodaysMatches() {
  const today = new Date().toISOString().split("T")[0]; // YYYY-MM-DD

  try {
    const matches = await fetchTodaysMatchesWithPagination(today);

    console.log(`[MatchMonitor] Found ${matches.length} matches for ${today}`);

    for (const match of matches) {
      const matchId = match.match_details_id;
      if (!matchId) {
        console.log(`[MatchMonitor] Skipping match without match_details_id: ${match.home_team} vs ${match.away_team}`);
        continue;
      }

      // Skip matches we've already fully processed today
      if (finishedMatchIds.has(matchId)) {
        console.log(`[MatchMonitor] Match ${match.home_team} vs ${match.away_team} (${matchId}): already finished, skipping`);
        continue;
      }

      const relevanceDecision = evaluateMatchRelevance(match);
      const relevant = relevanceDecision.relevant;
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
        if (!monitoredMatches.has(matchId)) {
          console.log(`[MatchMonitor] ✓ Starting to monitor match: ${match.home_team} vs ${match.away_team} (status: ${match.score_status || "none"})`);
          await monitorMatch(matchId, match);
        } else {
          console.log(`[MatchMonitor] Already monitoring: ${match.home_team} vs ${match.away_team}`);
        }
      }
    }
  } catch (error) {
    console.error("[MatchMonitor] Error checking today's matches:", error.message);
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
    lifecycle: {
      // If the first state is already live, don't send a synthetic delayed kickoff later.
      kickoffEmitted: isLiveMatchStatus(initialStatus),
      halftimeEmitted: initialStatus === "HT",
      fulltimeEmitted: isFinishedMatchStatus(initialStatus) || isPenaltyShootoutStatus(initialStatus),
    },
  });
  logDecision("monitor_start", {
    match_id: matchId,
    home_team: seedMatch.home_team,
    away_team: seedMatch.away_team,
    initial_status: seedMatch.score_status || null,
    kickoff_time_ms: kickoffTimeMs,
    kickoff_already_emitted: isLiveMatchStatus(initialStatus),
  });

  // Start polling this match
  pollMatchDetails(matchId);
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

    const merged = { ...fallback, ...payload };
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

    const currentMatch = await response.json();

    if (!currentMatch || typeof currentMatch !== "object") {
      console.warn(`[MatchMonitor] No match data for ${matchId}`);
      scheduleNextPoll(matchId);
      return;
    }

    // Detect changes and trigger notifications
    await detectAndNotifyChanges(matchId, monitorState, monitorState.lastState, currentMatch);

    // Update state
    monitorState.lastState = currentMatch;
    monitorState.lastPollTime = Date.now();
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
      finishedMatchIds.add(matchId);
      stopMonitoringMatch(matchId);
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
      stopMonitoringMatch(matchId);
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
function stopMonitoringMatch(matchId) {
  const monitorState = monitoredMatches.get(matchId);
  if (monitorState && monitorState.pollTimer) {
    clearTimeout(monitorState.pollTimer);
  }
  monitoredMatches.delete(matchId);
}

/**
 * Detect changes between old and new match state and trigger notifications
 */
async function detectAndNotifyChanges(matchId, monitorState, oldMatch, newMatch) {
  const nowMs = Date.now();
  const events = buildMatchEvents(oldMatch, newMatch, monitorState, nowMs, { matchId });
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
    // This would require checking if either team is in the EPL
    // For now, we'll skip this check as it requires loading EPL teams data
    // You can implement this later if needed
  }

  return {
    shouldNotify: true,
    reason: "eligible",
    delayMinutes,
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

  for (const [matchId, state] of monitoredMatches) {
    if (now - state.lastPollTime > MAX_ERROR_POLL_AGE_MS) {
      console.log(`[MatchMonitor] Cleaning up stale match ${matchId}`);
      stopMonitoringMatch(matchId);
      continue;
    }

    if (shouldStopMonitoringAsIrrelevant(state.lastState, state, now)) {
      console.log(`[MatchMonitor] Cleaning up out-of-window match ${matchId}`);
      stopMonitoringMatch(matchId);
    }
  }

  console.log(`[MatchMonitor] Cleanup: ${monitoredMatches.size} matches being monitored, ${sentNotifications.size} notifications in dedup set, ${scheduledNotifications.size} notifications scheduled`);
}

/**
 * Get monitoring status
 */
function getStatus() {
  return {
    isMonitoring,
    monitoredMatchCount: monitoredMatches.size,
    scheduledNotificationCount: scheduledNotifications.size,
    dedupSetSize: sentNotifications.size,
  };
}

module.exports = {
  initialize,
  startMonitoring,
  stopMonitoring,
  getStatus,
  __testHooks: {
    buildMatchEvents,
    buildScoreChangeEvent,
    buildNotificationId,
    countGoals,
    diffGoalEvents,
    isMatchRelevant,
    isLiveMatchStatus,
    isFinishedMatchStatus,
    isPenaltyShootoutStatus,
    shouldStopMonitoringAsIrrelevant,
  },
};
