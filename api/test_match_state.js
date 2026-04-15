// Shared test match state module
// This module holds the current simulated test match in memory
// Both the main API server and the test harness server import this module

function generateTestMatchId() {
  const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
  let id = "test";
  for (let i = 0; i < 8; i++) {
    id += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return id;
}

const TEST_MATCH_TIME_ZONE = "Europe/London";
const londonDateFormatter = new Intl.DateTimeFormat("en-CA", {
  timeZone: TEST_MATCH_TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});
const londonTimeFormatter = new Intl.DateTimeFormat("en-GB", {
  timeZone: TEST_MATCH_TIME_ZONE,
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
});

function formatLondonDate(date) {
  return londonDateFormatter.format(date);
}

function formatLondonTime(date) {
  return londonTimeFormatter.format(date);
}

class TestMatchState {
  constructor() {
    this.matches = new Map(); // Map of matchId -> match data
    this.timers = new Map(); // Map of matchId -> { simulationTimer, cleanupTimer }
  }

  cloneMatch(match) {
    if (!match || typeof match !== "object") return null;
    return JSON.parse(JSON.stringify(match));
  }

  timestampValue(value) {
    if (!value) return null;
    if (value instanceof Date) {
      const time = value.getTime();
      return Number.isFinite(time) ? time : null;
    }
    const time = new Date(value).getTime();
    return Number.isFinite(time) ? time : null;
  }

  recalculateAggregateScores(match) {
    if (!match) return;
    const firstLegHomeScore = Number(match.first_leg_home_score);
    const firstLegAwayScore = Number(match.first_leg_away_score);
    const homeScore = Number(match.home_score);
    const awayScore = Number(match.away_score);
    if (
      Number.isFinite(firstLegHomeScore) &&
      Number.isFinite(firstLegAwayScore) &&
      Number.isFinite(homeScore) &&
      Number.isFinite(awayScore)
    ) {
      match.aggregate_home_score = firstLegHomeScore + homeScore;
      match.aggregate_away_score = firstLegAwayScore + awayScore;
    }
  }

  parseMinuteStatus(status) {
    const normalized = String(status || "").trim().replace(/'$/, "");
    const match = normalized.match(/^(\d{1,3})(?:\+(\d{1,2}))?$/);
    if (!match) return null;
    const base = Number(match[1]);
    const extra = Number(match[2] || 0);
    if (!Number.isFinite(base) || !Number.isFinite(extra) || base < 0 || extra < 0) {
      return null;
    }
    return {
      base,
      extra,
      total: base + extra,
    };
  }

  sanitizeMatch(match) {
    if (!match || typeof match !== "object") return match;

    const rawMinute = Number(match.matchMinute);
    if (match.in_progress && (!Number.isFinite(rawMinute) || rawMinute <= 0)) {
      match.matchMinute = 1;
    }

    const currentStatus = String(match.score_status || "").trim();
    const hasNegativeMinuteStatus = /^-\d+(?:\+\d+)?'?$/.test(currentStatus);
    if (!hasNegativeMinuteStatus) {
      return match;
    }

    if (match.in_progress) {
      const phase = this.getMatchPhaseForMatch(match);
      match.score_status = this.getScoreStatusForMatch(match, phase);
    } else if (Number.isFinite(Number(match.matchMinute)) && Number(match.matchMinute) > 0) {
      match.score_status = `${Math.floor(Number(match.matchMinute))}'`;
    } else {
      match.score_status = null;
    }

    return match;
  }

  getAllMatches() {
    return Array.from(this.matches.values()).map((match) =>
      this.cloneMatch(this.sanitizeMatch(match))
    );
  }

  getRecentMatches(options = {}) {
    const sinceMs = this.timestampValue(options && options.since);
    const limit =
      options && Number.isInteger(options.limit) && options.limit > 0 ? options.limit : null;

    const matches = Array.from(this.matches.values())
      .filter((match) => {
        if (!match) return false;
        if (sinceMs === null) return true;
        const matchTimestamp = this.timestampValue(match.created_at || match.updated_at);
        return matchTimestamp !== null && matchTimestamp >= sinceMs;
      })
      .sort((left, right) => {
        const leftTimestamp = this.timestampValue(left && (left.created_at || left.updated_at)) || 0;
        const rightTimestamp =
          this.timestampValue(right && (right.created_at || right.updated_at)) || 0;
        return rightTimestamp - leftTimestamp;
      });

    return (limit ? matches.slice(0, limit) : matches).map((match) =>
      this.cloneMatch(this.sanitizeMatch(match))
    );
  }

  getMatch(matchId) {
    if (!matchId) {
      // Return the first/most recent match if no ID specified (for backwards compatibility)
      const matches = Array.from(this.matches.values());
      return matches.length > 0 ? this.sanitizeMatch(matches[matches.length - 1]) : null;
    }
    return this.sanitizeMatch(this.matches.get(matchId) || null);
  }

  getMatchConfig(matchId) {
    const match = this.getMatch(matchId);
    return match ? match.config : null;
  }

  isActive(matchId) {
    if (!matchId) {
      return this.matches.size > 0;
    }
    return this.matches.has(matchId);
  }

  createMatch(params) {
    const now = new Date();
    const nowIso = now.toISOString();
    const kickoffTime = params.kickoffNow
      ? now
      : new Date(params.kickoffTime || now);

    const dateStr = formatLondonDate(kickoffTime);
    const timeStr = formatLondonTime(kickoffTime);

    const matchId = generateTestMatchId();
    const homeScore = Number(params.homeScore) || 0;
    const awayScore = Number(params.awayScore) || 0;
    const aggregateHomeScore = Number.isFinite(Number(params.aggregateHomeScore))
      ? Number(params.aggregateHomeScore)
      : null;
    const aggregateAwayScore = Number.isFinite(Number(params.aggregateAwayScore))
      ? Number(params.aggregateAwayScore)
      : null;
    const hasAggregateBaseline = aggregateHomeScore !== null && aggregateAwayScore !== null;

    const match = {
      id: matchId,
      date: dateStr,
      time: timeStr,
      home_team: params.homeTeam,
      away_team: params.awayTeam,
      league: params.league,
      league_subcategory: params.leagueSubcategory || null,
      details_url: null,
      match_details_id: matchId,
      tv_channels: [],
      home_score: homeScore,
      away_score: awayScore,
      aggregate_home_score: hasAggregateBaseline ? aggregateHomeScore : null,
      aggregate_away_score: hasAggregateBaseline ? aggregateAwayScore : null,
      first_leg_home_score: hasAggregateBaseline ? aggregateHomeScore - homeScore : null,
      first_leg_away_score: hasAggregateBaseline ? aggregateAwayScore - awayScore : null,
      score_status: null, // Will be set when match starts
      home_goal_scorers: [],
      away_goal_scorers: [],
      home_assists: [],
      away_assists: [],
      home_red_cards: [],
      away_red_cards: [],
      penalty_result: null,
      live_text_entries: [],
      in_progress: false,
      is_test_match: true,
      created_at: nowIso,
      updated_at: nowIso,
      config: {
        matchSpeedMs: params.matchSpeedMs != null ? params.matchSpeedMs : 10000,
        homeExpectedGoals: params.homeExpectedGoals || 2,
        awayExpectedGoals: params.awayExpectedGoals || 2,
        firstHalfStoppageTime:
          params.firstHalfStoppageTime !== undefined
            ? params.firstHalfStoppageTime
            : Math.floor(Math.random() * 6),
        secondHalfStoppageTime:
          params.secondHalfStoppageTime !== undefined
            ? params.secondHalfStoppageTime
            : Math.floor(Math.random() * 11),
        simulateExtraTime: params.simulateExtraTime || false,
        simulatePenalties: params.simulatePenalties || false,
      },
      matchMinute: 0,
      isPaused: false,
    };

    this.matches.set(matchId, match);

    // Set up auto-cleanup after 2 hours
    const cleanupTimer = setTimeout(() => {
      this.deleteMatch(matchId);
      console.log(`[Test Match] Auto-deleted test match ${matchId} after 2 hours`);
    }, 2 * 60 * 60 * 1000);

    this.timers.set(matchId, {
      simulationTimer: null,
      cleanupTimer: cleanupTimer,
      actionTimers: [],
    });

    return match;
  }

  startSimulation(matchId) {
    const match = this.getMatch(matchId);
    if (!match) return;

    // Get the actual matchId (in case null was passed and we got the first match)
    const actualMatchId = match.id;
    const timers = this.timers.get(actualMatchId);
    if (!timers || timers.simulationTimer) return;

    match.in_progress = true;
    match.score_status = "1'";
    match.matchMinute = 1;
    match.updated_at = new Date().toISOString();

    timers.simulationTimer = setInterval(() => {
      if (match.isPaused) return;
      this.advanceMinute(actualMatchId);
    }, match.config.matchSpeedMs);
  }

  advanceMinute(matchId) {
    const match = this.getMatch(matchId);
    if (!match) return;

    match.matchMinute++;

    // Determine current match phase
    const phase = this.getMatchPhaseForMatch(match);

    // Update score status
    match.score_status = this.getScoreStatusForMatch(match, phase);

    // Check for red cards (1/30 chance per minute)
    if (Math.random() < 1 / 30) {
      const isHome = Math.random() < 0.5;
      this.addRedCard(matchId, isHome);
    }

    // Check for goals based on expected goals
    this.checkForGoal(matchId);

    // Check if match should end
    if (this.shouldEndMatch(matchId, phase)) {
      this.endMatch(matchId, phase);
    }

    match.updated_at = new Date().toISOString();
  }

  getMatchPhaseForMatch(match) {
    if (!match) return "full_time";

    const firstHalfEnd = 45 + match.config.firstHalfStoppageTime;
    const secondHalfEnd = 90 + match.config.secondHalfStoppageTime;
    const extraTimeEnd = match.config.simulateExtraTime
      ? secondHalfEnd + 30
      : secondHalfEnd;

    if (match.matchMinute <= 45) return "first_half";
    if (match.matchMinute <= firstHalfEnd) return "first_half_stoppage";
    if (match.matchMinute === firstHalfEnd + 1) return "half_time";
    if (match.matchMinute <= 90) return "second_half";
    if (match.matchMinute <= secondHalfEnd) return "second_half_stoppage";
    if (
      match.config.simulateExtraTime &&
      match.home_score === match.away_score
    ) {
      if (match.matchMinute <= extraTimeEnd) return "extra_time";
    }
    return "full_time";
  }

  getMatchPhase(matchId) {
    return this.getMatchPhaseForMatch(this.getMatch(matchId));
  }

  getScoreStatusForMatch(match, phase) {
    if (!match) return "FT";

    const firstHalfEnd = 45 + match.config.firstHalfStoppageTime;
    const halfTimeMinute = firstHalfEnd + 1;

    switch (phase) {
      case "first_half":
        return `${match.matchMinute}'`;
      case "first_half_stoppage":
        return `45+${match.matchMinute - 45}'`;
      case "half_time":
        return "HT";
      case "second_half":
        if (match.matchMinute <= halfTimeMinute + 45) {
          return `${match.matchMinute - halfTimeMinute}'`;
        }
        return `${match.matchMinute - halfTimeMinute}'`;
      case "second_half_stoppage":
        return `90+${match.matchMinute - 90}'`;
      case "extra_time":
        return "ET";
      case "full_time":
        if (
          match.config.simulateExtraTime &&
          match.home_score !== match.away_score
        ) {
          return "AET";
        }
        return "FT";
      default:
        return "FT";
    }
  }

  getScoreStatus(matchId, phase) {
    return this.getScoreStatusForMatch(this.getMatch(matchId), phase);
  }

  shouldEndMatch(matchId, phase) {
    const match = this.getMatch(matchId);
    if (!match) return true;

    const firstHalfEnd = 45 + match.config.firstHalfStoppageTime;
    const secondHalfEnd = 90 + match.config.secondHalfStoppageTime;

    if (phase === "first_half_stoppage" && match.matchMinute > firstHalfEnd) {
      return false; // Move to half time
    }

    if (phase === "second_half_stoppage" && match.matchMinute > secondHalfEnd) {
      return true;
    }

    if (phase === "extra_time") {
      const extraTimeEnd = secondHalfEnd + 30;
      if (match.matchMinute > extraTimeEnd) {
        return true;
      }
    }

    if (phase === "full_time") {
      return true;
    }

    return false;
  }

  endMatch(matchId, phase) {
    const match = this.getMatch(matchId);
    if (!match) return;

    const isExtraTime = phase === "extra_time";
    const isLevel = match.home_score === match.away_score;

    if (isExtraTime && isLevel && match.config.simulatePenalties) {
      this.simulatePenaltyShootout(matchId);
      match.score_status = "PENS";
    } else if (isExtraTime) {
      match.score_status = "AET";
    } else {
      match.score_status = "FT";
    }

    match.in_progress = false;
    this.stopSimulation(matchId);
  }

  checkForGoal(matchId) {
    const match = this.getMatch(matchId);
    if (!match) return;

    // Calculate goal probability based on expected goals
    // Assume 90 minutes = full match, so probability per minute = xG / 90
    const homeGoalProb = match.config.homeExpectedGoals / 90;
    const awayGoalProb = match.config.awayExpectedGoals / 90;

    // Add some randomness (±30%)
    const homeRandom = homeGoalProb * (0.7 + Math.random() * 0.6);
    const awayRandom = awayGoalProb * (0.7 + Math.random() * 0.6);

    if (Math.random() < homeRandom) {
      this.addGoal(matchId, true);
    }

    if (Math.random() < awayRandom) {
      this.addGoal(matchId, false);
    }
  }

  currentEventMinuteLabel(match) {
    if (!match) return "1'";
    const minuteStatus = this.parseMinuteStatus(match.score_status);
    return minuteStatus ? match.score_status : `${Math.max(1, Number(match.matchMinute) || 1)}'`;
  }

  minuteLabelToValue(minuteLabel) {
    const normalized = String(minuteLabel || "").trim().replace(/'/g, "");
    const match = normalized.match(/^(\d+)(?:\+(\d+))?/);
    if (!match) return null;
    const base = Number(match[1]);
    const extra = Number(match[2] || 0);
    if (!Number.isFinite(base) || !Number.isFinite(extra)) return null;
    return base + extra;
  }

  minuteValueToLabel(minuteValue) {
    const numeric = Number(minuteValue);
    if (!Number.isFinite(numeric) || numeric <= 0) return "1'";
    return `${Math.floor(numeric)}'`;
  }

  prependLiveTextEntry(matchId, minuteLabel, text) {
    const match = this.getMatch(matchId);
    if (!match || !text) return;
    if (!Array.isArray(match.live_text_entries)) {
      match.live_text_entries = [];
    }
    match.live_text_entries.unshift({
      minute: minuteLabel,
      minute_value: this.minuteLabelToValue(minuteLabel),
      text,
    });
    if (match.live_text_entries.length > 24) {
      match.live_text_entries = match.live_text_entries.slice(0, 24);
    }
  }

  addGoal(matchId, isHome, playerName = null, assisterName = null, options = {}) {
    const match = this.getMatch(matchId);
    if (!match) return null;

    const goalTime = options.goalTime || this.currentEventMinuteLabel(match);
    const isPenalty =
      typeof options.isPenalty === "boolean" ? options.isPenalty : Math.random() < 0.1;
    const hasAssist =
      options.forceAssist === true
        ? true
        : options.forceAssist === false
          ? false
          : !isPenalty && Math.random() < 0.8; // 80% chance of assist (if not penalty)

    const scorer = playerName || this.generatePlayerName();
    const assister = hasAssist ? assisterName || this.generatePlayerName() : null;

    if (isHome) {
      match.home_score++;
      this.addGoalScorer(matchId, true, scorer, goalTime, isPenalty);
      if (assister) {
        this.addAssist(matchId, true, assister, goalTime);
      }
    } else {
      match.away_score++;
      this.addGoalScorer(matchId, false, scorer, goalTime, isPenalty);
      if (assister) {
        this.addAssist(matchId, false, assister, goalTime);
      }
    }

    this.recalculateAggregateScores(match);
    match.updated_at = new Date().toISOString();
    return {
      isHome,
      scorer,
      assister,
      goalTime,
      isPenalty,
    };
  }

  addGoalScorer(matchId, isHome, playerName, goalTime, isPenalty = false) {
    const match = this.getMatch(matchId);
    if (!match) return;

    const scorers = isHome
      ? match.home_goal_scorers
      : match.away_goal_scorers;
    const existing = scorers.find((s) => s.player === playerName);

    const timeLabel = isPenalty ? `${goalTime} (pen)` : goalTime;

    if (existing) {
      existing.goal_times.push(timeLabel);
    } else {
      scorers.push({
        player: playerName,
        goal_times: [timeLabel],
        own_goal_times: [],
        disallowed_goal_times: [],
      });
    }
  }

  addAssist(matchId, isHome, playerName, assistTime) {
    const match = this.getMatch(matchId);
    if (!match) return;

    const assists = isHome ? match.home_assists : match.away_assists;
    const existing = assists.find((a) => a.player === playerName);

    if (existing) {
      existing.assist_times.push(assistTime);
    } else {
      assists.push({
        player: playerName,
        assist_times: [assistTime],
      });
    }
  }

  addRedCard(matchId, isHome, playerName = null) {
    const match = this.getMatch(matchId);
    if (!match) return;

    // Use score_status if it's a minute indicator (contains numbers), otherwise use matchMinute
    const minuteStatus = this.parseMinuteStatus(match.score_status);
    const redCardTime = minuteStatus ? match.score_status : `${match.matchMinute}'`;
    const player = playerName || this.generatePlayerName();

    const redCards = isHome
      ? match.home_red_cards
      : match.away_red_cards;
    const existing = redCards.find((r) => r.player === player);

    if (existing) {
      existing.red_card_times.push(redCardTime);
    } else {
      redCards.push({
        player: player,
        red_card_times: [redCardTime],
      });
    }

    match.updated_at = new Date().toISOString();
  }

  disallowGoalByVar(matchId, isHome, options = {}) {
    const match = this.getMatch(matchId);
    if (!match) return null;

    const scorers = isHome ? match.home_goal_scorers : match.away_goal_scorers;
    const assists = isHome ? match.home_assists : match.away_assists;
    const scoreKey = isHome ? "home_score" : "away_score";
    const goalTime = String(options.goalTime || "").trim();
    const scorerName = String(options.playerName || "").trim();
    const assisterName = String(options.assisterName || "").trim();

    let targetScorer = null;
    if (scorerName) {
      targetScorer = scorers.find((entry) => entry.player === scorerName) || null;
    }
    if (!targetScorer && goalTime) {
      targetScorer = scorers.find((entry) => Array.isArray(entry.goal_times) && entry.goal_times.includes(goalTime)) || null;
    }
    if (!targetScorer) {
      return null;
    }

    const removableTimes = Array.isArray(targetScorer.goal_times) ? targetScorer.goal_times : [];
    const selectedGoalTime = goalTime || removableTimes[removableTimes.length - 1];
    if (!selectedGoalTime) {
      return null;
    }

    targetScorer.goal_times = removableTimes.filter((entry) => entry !== selectedGoalTime);
    if (!Array.isArray(targetScorer.disallowed_goal_times)) {
      targetScorer.disallowed_goal_times = [];
    }
    if (!targetScorer.disallowed_goal_times.includes(selectedGoalTime)) {
      targetScorer.disallowed_goal_times.push(selectedGoalTime);
    }

    const currentScore = Number(match[scoreKey] || 0);
    match[scoreKey] = Math.max(0, currentScore - 1);
    this.recalculateAggregateScores(match);

    if (assisterName) {
      const assistEntry = assists.find((entry) => entry.player === assisterName);
      if (assistEntry) {
        if (!Array.isArray(assistEntry.assist_times)) {
          assistEntry.assist_times = [];
        }
        if (!assistEntry.assist_times.includes(selectedGoalTime)) {
          assistEntry.assist_times.push(selectedGoalTime);
        }
      } else {
        assists.push({
          player: assisterName,
          assist_times: [selectedGoalTime],
        });
      }
    }

    const goalMinuteValue = this.minuteLabelToValue(selectedGoalTime);
    const decisionMinuteLabel =
      options.decisionMinute ||
      this.currentEventMinuteLabel(match) ||
      this.minuteValueToLabel(goalMinuteValue !== null ? goalMinuteValue + 2 : null);

    this.prependLiveTextEntry(
      matchId,
      decisionMinuteLabel,
      `VAR Decision: No Goal ${match.home_team} ${match.home_score}-${match.away_score} ${match.away_team}.`
    );
    this.prependLiveTextEntry(
      matchId,
      selectedGoalTime,
      `GOAL OVERTURNED BY VAR: ${targetScorer.player} (${isHome ? match.home_team : match.away_team}) scores but the goal is ruled out after a VAR review.`
    );

    match.updated_at = new Date().toISOString();
    return {
      scorer: targetScorer.player,
      assister: assisterName || null,
      goalTime: selectedGoalTime,
      decisionMinute: decisionMinuteLabel,
      team: isHome ? "home" : "away",
    };
  }

  simulateVarDisallowedGoal(matchId, isHome, options = {}) {
    const match = this.getMatch(matchId);
    if (!match) return null;

    const revertDelayMs = Math.max(1000, Number(options.revertDelayMs) || 12000);
    const actualMatchId = match.id;
    const goal = this.addGoal(actualMatchId, isHome, options.playerName, options.assisterName, {
      isPenalty: false,
      forceAssist: options.assisterName ? true : undefined,
    });
    if (!goal) {
      return null;
    }

    const timers = this.timers.get(actualMatchId);
    const actionTimer = setTimeout(() => {
      this.disallowGoalByVar(actualMatchId, isHome, {
        playerName: goal.scorer,
        assisterName: goal.assister,
        goalTime: goal.goalTime,
      });
      if (timers && Array.isArray(timers.actionTimers)) {
        timers.actionTimers = timers.actionTimers.filter((timer) => timer !== actionTimer);
      }
    }, revertDelayMs);

    if (timers) {
      if (!Array.isArray(timers.actionTimers)) {
        timers.actionTimers = [];
      }
      timers.actionTimers.push(actionTimer);
    }

    return {
      goal,
      revertDelayMs,
    };
  }

  simulatePenaltyShootout(matchId) {
    const match = this.getMatch(matchId);
    if (!match) return;

    // Simulate a penalty shootout - random result
    const homeScore = Math.floor(Math.random() * 5) + 1; // 1-5 penalties
    const awayScore =
      homeScore === 5
        ? Math.floor(Math.random() * 5)
        : homeScore + (Math.random() < 0.5 ? -1 : 1);

    match.penalty_result = `${homeScore}-${Math.max(0, awayScore)}`;
    match.updated_at = new Date().toISOString();
  }

  generatePlayerName() {
    const firstNames = [
      "James",
      "Mohamed",
      "Kevin",
      "Raheem",
      "Harry",
      "Marcus",
      "Mason",
      "Declan",
      "Phil",
      "Jack",
      "Bukayo",
      "Bruno",
      "Cristiano",
      "Erling",
      "Darwin",
      "Gabriel",
      "Martin",
      "Son",
      "Ivan",
      "Bernardo",
    ];
    const lastNames = [
      "Smith",
      "Salah",
      "De Bruyne",
      "Sterling",
      "Kane",
      "Rashford",
      "Mount",
      "Rice",
      "Foden",
      "Grealish",
      "Saka",
      "Fernandes",
      "Ronaldo",
      "Haaland",
      "Nunez",
      "Jesus",
      "Odegaard",
      "Heung-min",
      "Toney",
      "Silva",
    ];

    const firstName = firstNames[Math.floor(Math.random() * firstNames.length)];
    const lastName = lastNames[Math.floor(Math.random() * lastNames.length)];
    return `${firstName} ${lastName}`;
  }

  jumpToHalfTime(matchId) {
    const match = this.getMatch(matchId);
    if (!match || !match.in_progress) return;

    match.matchMinute = 45 + match.config.firstHalfStoppageTime + 1;
    match.score_status = "HT";
    match.updated_at = new Date().toISOString();
  }

  jumpToFullTime(matchId) {
    const match = this.getMatch(matchId);
    if (!match || !match.in_progress) return;

    const phase = this.getMatchPhase(matchId);
    if (phase.includes("extra_time")) {
      match.score_status = "AET";
    } else {
      match.score_status = "FT";
    }

    match.in_progress = false;
    this.stopSimulation(matchId);
    match.updated_at = new Date().toISOString();
  }

  setMatchSpeed(matchId, speedMs) {
    const match = this.getMatch(matchId);
    if (!match) return;

    const actualMatchId = match.id;
    match.config.matchSpeedMs = speedMs;

    // If the simulation is currently running, restart the timer with the new speed
    const timers = this.timers.get(actualMatchId);
    if (timers && timers.simulationTimer) {
      clearInterval(timers.simulationTimer);
      timers.simulationTimer = setInterval(() => {
        if (match.isPaused) return;
        this.advanceMinute(actualMatchId);
      }, speedMs);
    }
  }

  pauseSimulation(matchId) {
    const match = this.getMatch(matchId);
    if (!match) return;
    match.isPaused = true;
  }

  resumeSimulation(matchId) {
    const match = this.getMatch(matchId);
    if (!match) return;
    match.isPaused = false;
  }

  stopSimulation(matchId) {
    const match = this.getMatch(matchId);
    if (!match) return;

    const actualMatchId = match.id;
    const timers = this.timers.get(actualMatchId);
    if (timers && timers.simulationTimer) {
      clearInterval(timers.simulationTimer);
      timers.simulationTimer = null;
    }
  }

  restartMatch(matchId) {
    const match = this.getMatch(matchId);
    if (!match) return;

    this.stopSimulation(matchId);
    const timers = this.timers.get(match.id);
    if (timers && Array.isArray(timers.actionTimers)) {
      timers.actionTimers.forEach((timer) => clearTimeout(timer));
      timers.actionTimers = [];
    }
    match.home_score = 0;
    match.away_score = 0;
    match.home_goal_scorers = [];
    match.away_goal_scorers = [];
    match.home_assists = [];
    match.away_assists = [];
    match.home_red_cards = [];
    match.away_red_cards = [];
    match.live_text_entries = [];
    match.penalty_result = null;
    match.in_progress = false;
    match.score_status = null;
    match.matchMinute = 0;
    match.isPaused = false;
    this.recalculateAggregateScores(match);
    match.updated_at = new Date().toISOString();
  }

  deleteMatch(matchId) {
    const match = this.getMatch(matchId);
    if (!match) return;

    const actualMatchId = match.id;
    this.stopSimulation(actualMatchId);

    // Clear cleanup timer
    const timers = this.timers.get(actualMatchId);
    if (timers && timers.cleanupTimer) {
      clearTimeout(timers.cleanupTimer);
    }
    if (timers && Array.isArray(timers.actionTimers)) {
      timers.actionTimers.forEach((timer) => clearTimeout(timer));
    }

    this.timers.delete(actualMatchId);
    this.matches.delete(actualMatchId);
  }
}

// Singleton instance
const testMatchState = new TestMatchState();

module.exports = testMatchState;
module.exports.TestMatchState = TestMatchState;
