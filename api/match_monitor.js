const { getAllUserPreferences } = require("./redis_client");
const { sendNotification } = require("./apns_client");

// Configuration
const POLL_INTERVAL_MS = 10 * 1000; // Poll every 10 seconds for in-progress matches
const DAILY_MATCHES_CHECK_INTERVAL_MS = 15 * 1000; // Check for today's matches every 15 seconds
const CLEANUP_INTERVAL_MS = 5 * 60 * 1000; // Clean up every 5 minutes

// State tracking
const monitoredMatches = new Map(); // matchId -> matchState
const scheduledNotifications = new Map(); // notificationId -> timeout handle
const sentNotifications = new Set(); // Set of notification IDs to prevent duplicates
const finishedMatchIds = new Set(); // Match IDs that have been fully processed — never restart these
const NOTIFICATION_DEDUP_WINDOW_MS = 5 * 60 * 1000; // 5 minute dedup window

// Match status helpers - mirrors server.js MATCH_STATUS_* constants
const MATCH_STATUS_MINUTE_PATTERN = /^\d{1,3}(?:\+\d{1,2})?'?$/;
const MATCH_STATUS_COMPLETE_TOKENS = new Set(["FT", "AET"]);
const MATCH_STATUS_IN_PROGRESS_TOKENS = new Set(["LIVE", "HT", "ET", "PENS", "PEN", "PEN."]);

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
  for (const [notifId, timeout] of scheduledNotifications) {
    clearTimeout(timeout);
  }
  scheduledNotifications.clear();
  monitoredMatches.clear();
  finishedMatchIds.clear();
}

/**
 * Check for today's matches and start monitoring in-progress ones
 */
async function checkTodaysMatches() {
  const today = new Date().toISOString().split("T")[0]; // YYYY-MM-DD
  const url = `${apiBaseURL}/matches?start=${today}&end=${today}`;

  try {
    const response = await fetch(url);
    if (!response.ok) {
      console.error(`[MatchMonitor] Failed to fetch today's matches: ${response.status}`);
      return;
    }

    const matches = await response.json();

    if (!Array.isArray(matches)) {
      console.error(`[MatchMonitor] Invalid response format - expected array, got:`, typeof matches);
      return;
    }

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

      // Check if match is in progress or upcoming
      const isRelevant = isMatchRelevant(match);
      console.log(`[MatchMonitor] Match ${match.home_team} vs ${match.away_team} (${matchId}): score_status=${match.score_status}, relevant=${isRelevant}`);

      if (match.score_status && isRelevant) {
        if (!monitoredMatches.has(matchId)) {
          console.log(`[MatchMonitor] ✓ Starting to monitor match: ${match.home_team} vs ${match.away_team} (status: ${match.score_status})`);
          monitorMatch(matchId, match);
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
 * Determine if a match is relevant for monitoring (in progress or upcoming soon)
 */
function isMatchRelevant(match) {
  // If has score status, check if in progress
  if (match.score_status) {
    if (isLiveMatchStatus(match.score_status)) return true;
    // Finished matches are only relevant while already being monitored
    // (the polling loop stops them after one post-finish poll).
    // Don't pick up already-finished matches as new monitoring targets.
  }

  // Check if match is upcoming soon (within 15 minutes)
  if (match.date && match.time) {
    try {
      const matchDateTime = new Date(`${match.date}T${match.time}:00`);
      const now = new Date();
      const diffMs = matchDateTime - now;
      if (diffMs > 0 && diffMs <= 15 * 60 * 1000) {
        return true; // Upcoming within 15 minutes
      }
    } catch (error) {
      // Invalid date/time format
    }
  }

  return false;
}

/**
 * Monitor a specific match for changes
 */
async function monitorMatch(matchId, initialMatch) {
  // Store initial state without score_status so the first poll detects the
  // kick-off transition even when the match is already in progress when first seen.
  const seedState = { ...initialMatch, score_status: undefined };
  monitoredMatches.set(matchId, {
    lastState: seedState,
    pollTimer: null,
    lastPollTime: Date.now(),
  });

  // Start polling this match
  pollMatchDetails(matchId);
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

    if (!currentMatch || typeof currentMatch !== 'object') {
      console.warn(`[MatchMonitor] No match data for ${matchId}`);
      scheduleNextPoll(matchId);
      return;
    }

    // Detect changes and trigger notifications
    await detectAndNotifyChanges(matchId, monitorState.lastState, currentMatch);

    // Update last state
    monitorState.lastState = currentMatch;
    monitorState.lastPollTime = Date.now();

    // Stop monitoring once the match is finished — we've already processed the
    // FT/AET/PENS transition in detectAndNotifyChanges above.
    // Record in finishedMatchIds to prevent checkTodaysMatches from restarting it.
    if (isFinishedMatchStatus(currentMatch.score_status) ||
        ["PENS", "PEN", "PEN."].includes((currentMatch.score_status || "").toUpperCase())) {
      console.log(`[MatchMonitor] Match ${matchId} finished (${currentMatch.score_status}), stopping monitoring`);
      finishedMatchIds.add(matchId);
      stopMonitoringMatch(matchId);
      return;
    }

    // Check if we should stop monitoring this match (e.g. became irrelevant for other reasons)
    if (!isMatchRelevant(currentMatch)) {
      console.log(`[MatchMonitor] Match ${matchId} is no longer relevant, stopping monitoring`);
      finishedMatchIds.add(matchId);
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
async function detectAndNotifyChanges(matchId, oldMatch, newMatch) {
  const events = [];

  // Detect kick-off (match just started)
  // Fire when score_status transitions from absent to any live status.
  // Exclude completed statuses (FT/AET) in case data first appears after the match ends.
  if (!oldMatch.score_status && newMatch.score_status) {
    if (isLiveMatchStatus(newMatch.score_status)) {
      events.push({
        type: "kickoff",
        title: "Kick off",
        body: `${newMatch.home_team} vs ${newMatch.away_team}`,
      });
    }
  }

  // Detect half-time
  if (oldMatch.score_status !== "HT" && newMatch.score_status === "HT") {
    const homeScore = newMatch.home_score ?? 0;
    const awayScore = newMatch.away_score ?? 0;
    events.push({
      type: "halftime",
      title: "HT",
      body: `${newMatch.home_team} ${homeScore} - ${awayScore} ${newMatch.away_team}`,
    });
  }

  // Detect full-time
  const oldStatus = (oldMatch.score_status || "").toUpperCase();
  const newStatus = (newMatch.score_status || "").toUpperCase();
  if (
    (newStatus === "FT" || newStatus === "AET" || newStatus === "PENS" || newStatus === "PEN" || newStatus === "PEN.") &&
    oldStatus !== newStatus
  ) {
    const homeScore = newMatch.home_score ?? 0;
    const awayScore = newMatch.away_score ?? 0;
    let ftBody = `${newMatch.home_team} ${homeScore} - ${awayScore} ${newMatch.away_team}`;

    if (newStatus === "AET") {
      ftBody += " (AET)";
    }
    if ((newStatus === "PENS" || newStatus === "PEN" || newStatus === "PEN.") && newMatch.penalty_result) {
      ftBody += ` (${newMatch.penalty_result} on penalties)`;
    }

    events.push({
      type: "fulltime",
      title: newStatus === "AET" ? "AET" : (newStatus === "PENS" || newStatus === "PEN" || newStatus === "PEN.") ? "FT (Pens)" : "FT",
      body: ftBody,
    });
  }

  // Detect goals
  const oldHomeGoals = countGoals(oldMatch.home_goal_scorers);
  const newHomeGoals = countGoals(newMatch.home_goal_scorers);
  const oldAwayGoals = countGoals(oldMatch.away_goal_scorers);
  const newAwayGoals = countGoals(newMatch.away_goal_scorers);

  if (newHomeGoals > oldHomeGoals) {
    const lastGoalScorer = getLatestGoalScorer(newMatch.home_goal_scorers);
    const goalTime = getLatestGoalTime(newMatch.home_goal_scorers);
    const assister = getLatestAssister(newMatch.home_assists, newMatch.home_goal_scorers);
    let goalTitle = "Goal";
    if (goalTime) goalTitle += ` ${goalTime}`;
    let goalBody = `${newMatch.home_team} ${newMatch.home_score} - ${newMatch.away_score} ${newMatch.away_team}`;
    if (lastGoalScorer) {
      goalBody += ` (${lastGoalScorer}`;
      if (assister) {
        goalBody += `, assist: ${assister}`;
      }
      goalBody += ")";
    }
    events.push({
      type: "goal",
      team: "home",
      title: goalTitle,
      body: goalBody,
    });
  }

  if (newAwayGoals > oldAwayGoals) {
    const lastGoalScorer = getLatestGoalScorer(newMatch.away_goal_scorers);
    const goalTime = getLatestGoalTime(newMatch.away_goal_scorers);
    const assister = getLatestAssister(newMatch.away_assists, newMatch.away_goal_scorers);
    let goalTitle = "Goal";
    if (goalTime) goalTitle += ` ${goalTime}`;
    let goalBody = `${newMatch.home_team} ${newMatch.home_score} - ${newMatch.away_score} ${newMatch.away_team}`;
    if (lastGoalScorer) {
      goalBody += ` (${lastGoalScorer}`;
      if (assister) {
        goalBody += `, assist: ${assister}`;
      }
      goalBody += ")";
    }
    events.push({
      type: "goal",
      team: "away",
      title: goalTitle,
      body: goalBody,
    });
  }

  // Detect red cards
  const oldHomeRedCards = countRedCards(oldMatch.home_red_cards);
  const newHomeRedCards = countRedCards(newMatch.home_red_cards);
  const oldAwayRedCards = countRedCards(oldMatch.away_red_cards);
  const newAwayRedCards = countRedCards(newMatch.away_red_cards);

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
    });
  }

  // Send notifications for detected events
  if (events.length > 0) {
    console.log(`[MatchMonitor] Detected ${events.length} events for match ${matchId}`);
    for (const event of events) {
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
    const interestedUsers = allUsers.filter((user) => {
      const shouldNotify = shouldNotifyUser(user, match, event);
      if (!shouldNotify) {
        console.log(`[MatchMonitor]   - User ${user.deviceToken.substring(0, 12)}...: notifications=${user.preferences?.notificationsEnabled}, hasAPNS=${!!user.apnsToken}, match filters...`);
      }
      return shouldNotify;
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
      await scheduleNotificationForUser(user, match, event);
    }
  } catch (error) {
    console.error(`[MatchMonitor] Error sending notifications for event:`, error);
  }
}

/**
 * Determine if a user should be notified about a match event
 */
function shouldNotifyUser(user, match, event) {
  const prefs = user.preferences || {};
  const deviceShort = user.deviceToken.substring(0, 12) + "...";

  // Check if notifications are enabled
  if (!prefs.notificationsEnabled) {
    console.log(`[MatchMonitor]   ${deviceShort}: ✗ notifications disabled`);
    return false;
  }

  // Check if user has an APNS token
  if (!user.apnsToken) {
    console.log(`[MatchMonitor]   ${deviceShort}: ✗ no APNS token`);
    return false;
  }

  // Check event type filter
  if (prefs.notificationEventTypes && prefs.notificationEventTypes.length > 0) {
    if (!prefs.notificationEventTypes.includes(event.type)) {
      console.log(`[MatchMonitor]   ${deviceShort}: ✗ event type "${event.type}" not in notification event types`);
      return false;
    }
  }

  // Check competition filter
  // When notificationUseViewingFilter is true (or absent), use the viewing competition filter.
  // When false, use the dedicated notification competition filter.
  const useViewingFilter = prefs.notificationUseViewingFilter !== false;
  if (useViewingFilter) {
    if (prefs.competitionFilterEnabled && prefs.selectedLeagues && prefs.selectedLeagues.length > 0) {
      if (!prefs.selectedLeagues.includes(match.league)) {
        console.log(`[MatchMonitor]   ${deviceShort}: ✗ league "${match.league}" not in selected leagues [${prefs.selectedLeagues.join(", ")}]`);
        return false;
      }
    }
  } else {
    if (prefs.notificationCompetitionFilterEnabled && prefs.notificationSelectedLeagues && prefs.notificationSelectedLeagues.length > 0) {
      if (!prefs.notificationSelectedLeagues.includes(match.league)) {
        console.log(`[MatchMonitor]   ${deviceShort}: ✗ league "${match.league}" not in notification selected leagues [${prefs.notificationSelectedLeagues.join(", ")}]`);
        return false;
      }
    }
  }

  // Check channel filter (only applies to fixtures, but we'll use it for consistency)
  if (prefs.channelFilterEnabled && prefs.selectedChannels && prefs.selectedChannels.length > 0) {
    const matchChannels = match.tv_channels || [];
    const hasMatchingChannel = matchChannels.some((ch) => prefs.selectedChannels.includes(ch));
    if (matchChannels.length > 0 && !hasMatchingChannel) {
      console.log(`[MatchMonitor]   ${deviceShort}: ✗ no matching channels`);
      return false;
    }
  }

  // Check EPL teams filter
  if (prefs.englishPremierLeagueTeamsOnly) {
    // This would require checking if either team is in the EPL
    // For now, we'll skip this check as it requires loading EPL teams data
    // You can implement this later if needed
  }

  console.log(`[MatchMonitor]   ${deviceShort}: ✓ should notify (delay: ${prefs.notificationDelayMinutes || 0}min)`);
  return true;
}

/**
 * Schedule a notification for a user (with delay if configured)
 */
async function scheduleNotificationForUser(user, match, event) {
  const prefs = user.preferences || {};
  const delayMinutes = prefs.notificationDelayMinutes || 0;
  const delayMs = delayMinutes * 60 * 1000;

  // Create unique notification ID to prevent duplicates
  const notificationId = `${user.deviceToken}:${match.match_details_id}:${event.type}:${match.home_score ?? 0}:${match.away_score ?? 0}`;

  // Check if we've already sent this notification recently
  if (sentNotifications.has(notificationId)) {
    console.log(`[MatchMonitor] Skipping duplicate notification: ${notificationId}`);
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

    const timeout = setTimeout(async () => {
      await sendNotificationToUser(user, event);
      scheduledNotifications.delete(notificationId);
    }, delayMs);

    scheduledNotifications.set(notificationId, timeout);
  } else {
    // Send immediately
    await sendNotificationToUser(user, event);
  }
}

/**
 * Send notification to a specific user
 */
async function sendNotificationToUser(user, event) {
  try {
    await sendNotification(
      user.apnsToken,
      event.title,
      event.body,
      { event_type: event.type },
      user.isDevelopmentBuild || false
    );
  } catch (error) {
    console.error(
      `[MatchMonitor] Error sending notification to user ${user.deviceToken.substring(0, 12)}...:`,
      error.message
    );
  }
}

/**
 * Helper functions
 */

function countGoals(goalScorers) {
  if (!goalScorers || !Array.isArray(goalScorers)) return 0;
  return goalScorers.reduce((total, scorer) => {
    return total + (scorer.goal_times ? scorer.goal_times.length : 0);
  }, 0);
}

function countRedCards(redCards) {
  if (!redCards || !Array.isArray(redCards)) return 0;
  return redCards.reduce((total, card) => {
    return total + (card.red_card_times ? card.red_card_times.length : 0);
  }, 0);
}

function getLatestGoalScorer(goalScorers) {
  if (!goalScorers || goalScorers.length === 0) return null;
  const lastScorer = goalScorers[goalScorers.length - 1];
  return lastScorer.player || null;
}

function getLatestGoalTime(goalScorers) {
  if (!goalScorers || goalScorers.length === 0) return null;
  const lastScorer = goalScorers[goalScorers.length - 1];
  const times = lastScorer.goal_times;
  return times && times.length > 0 ? times[times.length - 1] : null;
}

function getLatestAssister(assists, goalScorers) {
  if (!assists || assists.length === 0) return null;
  if (!goalScorers || goalScorers.length === 0) return null;

  // Find the assister for the latest goal
  const lastScorer = goalScorers[goalScorers.length - 1];
  const lastGoalTime = lastScorer.goal_times ? lastScorer.goal_times[lastScorer.goal_times.length - 1] : null;

  if (!lastGoalTime) return null;

  // Try to find an assist at the same time
  for (const assister of assists) {
    if (assister.assist_times && assister.assist_times.includes(lastGoalTime)) {
      return assister.player;
    }
  }

  return null;
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
  const MAX_MONITOR_AGE_MS = 30 * 60 * 1000; // Stop monitoring after 30 minutes of no updates

  // Clean up monitored matches that haven't been updated in a while
  for (const [matchId, state] of monitoredMatches) {
    if (now - state.lastPollTime > MAX_MONITOR_AGE_MS) {
      console.log(`[MatchMonitor] Cleaning up stale match ${matchId}`);
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
};
