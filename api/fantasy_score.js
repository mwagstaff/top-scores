const MINIMUM_FORMATION = {
  2: 3,
  3: 2,
  4: 1,
};

const BENCH_BOOST_CODES = new Set(["bboost"]);

const context = {
  bootstrap: null,
  fixtures: [],
  live: null,
  currentEventId: 0,
  elementsById: new Map(),
  teamNameByID: new Map(),
  currentFixtures: [],
  teamsWithAnyFixture: new Set(),
  activeTeamIDs: new Set(),
  upcomingTeamIDs: new Set(),
  liveByElementID: new Map(),
  bootstrapUpdatedAt: null,
  fixturesUpdatedAt: null,
  liveUpdatedAt: null,
};

function toFiniteNumber(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function toFiniteInt(value, fallback = 0) {
  return Math.floor(toFiniteNumber(value, fallback));
}

function toPositiveInt(value, fallback = 0) {
  const normalized = toFiniteInt(value, fallback);
  return normalized > 0 ? normalized : fallback;
}

function toBoolean(value, fallback = false) {
  return typeof value === "boolean" ? value : fallback;
}

function normalizeToken(value) {
  return String(value || "").trim();
}

function deriveCurrentEventID(bootstrap, explicitCurrentEventID) {
  const normalizedExplicitCurrentEventID = toPositiveInt(explicitCurrentEventID, 0);
  if (normalizedExplicitCurrentEventID > 0) {
    return normalizedExplicitCurrentEventID;
  }

  const events = Array.isArray(bootstrap && bootstrap.events) ? bootstrap.events : [];
  const currentEvent = events.find((event) => event && event.is_current === true);
  return toPositiveInt(currentEvent && currentEvent.id, 0);
}

function refreshDerivedContext() {
  context.elementsById = new Map();
  context.teamNameByID = new Map();

  const bootstrap = context.bootstrap && typeof context.bootstrap === "object" ? context.bootstrap : null;
  if (bootstrap) {
    const elements = Array.isArray(bootstrap.elements) ? bootstrap.elements : [];
    const teams = Array.isArray(bootstrap.teams) ? bootstrap.teams : [];

    elements.forEach((element) => {
      const elementID = toPositiveInt(element && element.id, 0);
      if (elementID > 0) {
        context.elementsById.set(elementID, element);
      }
    });

    teams.forEach((team) => {
      const teamID = toPositiveInt(team && team.id, 0);
      if (teamID > 0) {
        context.teamNameByID.set(teamID, normalizeToken(team && team.name));
      }
    });
  }

  context.currentEventId = deriveCurrentEventID(context.bootstrap, context.currentEventId);
  context.currentFixtures = Array.isArray(context.fixtures)
    ? context.fixtures.filter((fixture) => {
      const eventID = toPositiveInt(fixture && fixture.event, 0);
      return context.currentEventId > 0 ? eventID === context.currentEventId : true;
    })
    : [];

  context.teamsWithAnyFixture = new Set();
  context.activeTeamIDs = new Set();
  context.upcomingTeamIDs = new Set();

  context.currentFixtures.forEach((fixture) => {
    const teamH = toPositiveInt(fixture && fixture.team_h, 0) || toPositiveInt(fixture && fixture.teamH, 0);
    const teamA = toPositiveInt(fixture && fixture.team_a, 0) || toPositiveInt(fixture && fixture.teamA, 0);
    const started = fixture && fixture.started === true;
    const finished = fixture && (fixture.finished === true || fixture.finished_provisional === true || fixture.finishedProvisional === true);

    if (teamH > 0) context.teamsWithAnyFixture.add(teamH);
    if (teamA > 0) context.teamsWithAnyFixture.add(teamA);

    if (started && !finished) {
      if (teamH > 0) context.activeTeamIDs.add(teamH);
      if (teamA > 0) context.activeTeamIDs.add(teamA);
    } else if (!started && !finished) {
      if (teamH > 0) context.upcomingTeamIDs.add(teamH);
      if (teamA > 0) context.upcomingTeamIDs.add(teamA);
    }
  });

  context.liveByElementID = new Map();
  const liveElements = Array.isArray(context.live && context.live.elements) ? context.live.elements : [];
  liveElements.forEach((entry) => {
    const elementID = toPositiveInt(entry && entry.id, 0);
    if (elementID > 0) {
      context.liveByElementID.set(elementID, entry && entry.stats ? entry.stats : {});
    }
  });
}

function setFantasyScoreContext(nextContext = {}) {
  if (Object.prototype.hasOwnProperty.call(nextContext, "bootstrap")) {
    context.bootstrap =
      nextContext.bootstrap && typeof nextContext.bootstrap === "object" ? nextContext.bootstrap : null;
  }
  if (Object.prototype.hasOwnProperty.call(nextContext, "fixtures")) {
    context.fixtures = Array.isArray(nextContext.fixtures) ? nextContext.fixtures : [];
  }
  if (Object.prototype.hasOwnProperty.call(nextContext, "live")) {
    context.live = nextContext.live && typeof nextContext.live === "object" ? nextContext.live : null;
  }
  if (Object.prototype.hasOwnProperty.call(nextContext, "currentEventId")) {
    context.currentEventId = toPositiveInt(nextContext.currentEventId, 0);
  }
  if (Object.prototype.hasOwnProperty.call(nextContext, "bootstrapUpdatedAt")) {
    context.bootstrapUpdatedAt = normalizeToken(nextContext.bootstrapUpdatedAt) || null;
  }
  if (Object.prototype.hasOwnProperty.call(nextContext, "fixturesUpdatedAt")) {
    context.fixturesUpdatedAt = normalizeToken(nextContext.fixturesUpdatedAt) || null;
  }
  if (Object.prototype.hasOwnProperty.call(nextContext, "liveUpdatedAt")) {
    context.liveUpdatedAt = normalizeToken(nextContext.liveUpdatedAt) || null;
  }

  refreshDerivedContext();
}

function resetFantasyScoreContext() {
  context.bootstrap = null;
  context.fixtures = [];
  context.live = null;
  context.currentEventId = 0;
  context.bootstrapUpdatedAt = null;
  context.fixturesUpdatedAt = null;
  context.liveUpdatedAt = null;
  refreshDerivedContext();
}

function fantasyScoreContextSummary() {
  return {
    currentEventId: context.currentEventId > 0 ? context.currentEventId : null,
    bootstrapUpdatedAt: context.bootstrapUpdatedAt,
    fixturesUpdatedAt: context.fixturesUpdatedAt,
    liveUpdatedAt: context.liveUpdatedAt,
    hasBootstrap: context.elementsById.size > 0,
    hasFixtures: context.currentFixtures.length > 0,
    hasLive: context.liveByElementID.size > 0,
    currentFixturesCount: context.currentFixtures.length,
    activeTeamsCount: context.activeTeamIDs.size,
  };
}

function resolveBootstrapAvailability(element) {
  const availabilityStatus = normalizeToken(element && element.status).toLowerCase();
  const chanceOfPlaying = element && (
    Number.isFinite(Number(element.chance_of_playing_next_round))
      ? Number(element.chance_of_playing_next_round)
      : Number(element.chance_of_playing_this_round)
  );
  const isDefinitelyUnavailable =
    availabilityStatus === "i" ||
    availabilityStatus === "s" ||
    availabilityStatus === "u" ||
    (availabilityStatus === "d" && chanceOfPlaying === 0);

  return {
    isDefinitelyUnavailable,
  };
}

function resolveSquadPlayer(player = {}) {
  const elementID = toPositiveInt(player.elementID, 0);
  const bootstrapElement = context.elementsById.get(elementID) || null;
  const liveStats = context.liveByElementID.get(elementID) || null;
  const teamID = toPositiveInt(bootstrapElement && bootstrapElement.team, 0);
  const availability = resolveBootstrapAvailability(bootstrapElement);

  const rawPoints = liveStats != null && Number.isFinite(Number(liveStats.total_points))
    ? toFiniteInt(liveStats.total_points, 0)
    : toFiniteInt(player.rawPoints, 0);
  const minutesPlayed = liveStats != null && Number.isFinite(Number(liveStats.minutes))
    ? toFiniteInt(liveStats.minutes, 0)
    : toFiniteInt(player.minutesPlayed, 0);
  const multiplier = toFiniteInt(player.multiplier, 1);
  const appliedPoints = rawPoints * multiplier;
  const hasAnyFixtureThisGameweek = teamID > 0
    ? context.teamsWithAnyFixture.has(teamID)
    : toBoolean(player.hasAnyFixtureThisGameweek);
  const hasUpcomingFixtureThisGameweek = teamID > 0
    ? context.upcomingTeamIDs.has(teamID)
    : toBoolean(player.hasUpcomingFixtureThisGameweek);
  const hasActiveFixtureThisGameweek = teamID > 0
    ? context.activeTeamIDs.has(teamID)
    : toBoolean(player.hasActiveFixtureThisGameweek);

  return {
    elementID,
    pickPosition: toPositiveInt(player.pickPosition, 0),
    positionType: toPositiveInt(player.positionType, 0),
    displayName: normalizeToken(player.displayName) || normalizeToken(bootstrapElement && bootstrapElement.web_name),
    fullName:
      normalizeToken(player.fullName) ||
      normalizeToken(
        `${normalizeToken(bootstrapElement && bootstrapElement.first_name)} ${normalizeToken(bootstrapElement && bootstrapElement.second_name)}`
      ) ||
      normalizeToken(player.displayName),
    teamName:
      normalizeToken(player.teamName) ||
      normalizeToken(context.teamNameByID.get(teamID)) ||
      "Unknown",
    rawPoints,
    appliedPoints,
    multiplier,
    isCaptain: toBoolean(player.isCaptain),
    isViceCaptain: toBoolean(player.isViceCaptain),
    isStarter: toBoolean(player.isStarter, toPositiveInt(player.pickPosition, 0) <= 11),
    hasAnyFixtureThisGameweek,
    hasUpcomingFixtureThisGameweek,
    hasActiveFixtureThisGameweek,
    isDefinitelyUnavailable: availability.isDefinitelyUnavailable,
    minutesPlayed,
    usedServerLiveData: Boolean(liveStats),
  };
}

function shouldAutoSubAsNonParticipant(player) {
  if (player.minutesPlayed !== 0) return false;
  if (player.hasActiveFixtureThisGameweek) return true;
  if (player.isDefinitelyUnavailable) return true;
  if (!player.hasAnyFixtureThisGameweek) return true;
  return !player.hasUpcomingFixtureThisGameweek && !player.hasActiveFixtureThisGameweek;
}

function isEligibleAutoSubReplacement(player) {
  return player.minutesPlayed > 0;
}

function calculateFromPlayers(squad) {
  const syncedPlayers = Array.isArray(squad && squad.players) ? squad.players : [];
  if (syncedPlayers.length === 0) {
    return null;
  }

  const players = syncedPlayers
    .map(resolveSquadPlayer)
    .filter((player) => player.elementID > 0 && player.pickPosition > 0)
    .sort((lhs, rhs) => lhs.pickPosition - rhs.pickPosition);
  if (players.length === 0) {
    return null;
  }

  const starters = players.filter((player) => player.isStarter);
  const bench = players.filter((player) => !player.isStarter).sort((lhs, rhs) => lhs.pickPosition - rhs.pickPosition);
  const activeChipCodes = Array.isArray(squad && squad.activeChipCodes)
    ? squad.activeChipCodes.map((code) => normalizeToken(code).toLowerCase()).filter(Boolean)
    : [];
  const hasBenchBoostActive = activeChipCodes.some((code) => BENCH_BOOST_CODES.has(code));
  const contributionsByElementID = new Map();
  const scoreCalculationRulesApplied = [];

  starters.forEach((starter) => {
    contributionsByElementID.set(starter.elementID, starter.appliedPoints);
  });
  bench.forEach((benchPlayer) => {
    contributionsByElementID.set(benchPlayer.elementID, hasBenchBoostActive ? benchPlayer.rawPoints : 0);
  });

  if (hasBenchBoostActive) {
    const benchBoostPoints = bench.reduce((sum, player) => sum + player.rawPoints, 0);
    scoreCalculationRulesApplied.push(
      `Bench Boost active: all bench points count (+${benchBoostPoints} pts).`
    );
  } else {
    const unavailableStartingGoalkeeper = starters.find((player) =>
      player.positionType === 1 && shouldAutoSubAsNonParticipant(player)
    );
    const benchGoalkeeper = bench.find((player) =>
      player.positionType === 1 && isEligibleAutoSubReplacement(player)
    );
    if (unavailableStartingGoalkeeper && benchGoalkeeper) {
      contributionsByElementID.set(unavailableStartingGoalkeeper.elementID, 0);
      contributionsByElementID.set(benchGoalkeeper.elementID, benchGoalkeeper.rawPoints);
      scoreCalculationRulesApplied.push(
        `Goalkeeper auto-sub applied: ${unavailableStartingGoalkeeper.displayName} did not play, so ${benchGoalkeeper.displayName} contributed ${benchGoalkeeper.rawPoints} pts.`
      );
    }

    const activeOutfieldCounts = { 2: 0, 3: 0, 4: 0 };
    starters
      .filter((player) => player.positionType !== 1)
      .forEach((player) => {
        activeOutfieldCounts[player.positionType] = (activeOutfieldCounts[player.positionType] || 0) + 1;
      });

    const nonPlayingOutfieldStarters = starters
      .filter((player) => player.positionType !== 1 && shouldAutoSubAsNonParticipant(player))
      .sort((lhs, rhs) => lhs.pickPosition - rhs.pickPosition);
    const playedOutfieldBench = bench
      .filter((player) => player.positionType !== 1 && isEligibleAutoSubReplacement(player))
      .sort((lhs, rhs) => lhs.pickPosition - rhs.pickPosition);
    const outfieldReplacementNotes = [];

    playedOutfieldBench.forEach((benchPlayer) => {
      if (nonPlayingOutfieldStarters.length === 0) return;

      const replacementIndex = nonPlayingOutfieldStarters.findIndex((starter) => {
        const simulatedCounts = {
          2: activeOutfieldCounts[2] || 0,
          3: activeOutfieldCounts[3] || 0,
          4: activeOutfieldCounts[4] || 0,
        };
        simulatedCounts[starter.positionType] = (simulatedCounts[starter.positionType] || 0) - 1;
        simulatedCounts[benchPlayer.positionType] = (simulatedCounts[benchPlayer.positionType] || 0) + 1;
        return (
          (simulatedCounts[2] || 0) >= MINIMUM_FORMATION[2] &&
          (simulatedCounts[3] || 0) >= MINIMUM_FORMATION[3] &&
          (simulatedCounts[4] || 0) >= MINIMUM_FORMATION[4]
        );
      });

      if (replacementIndex < 0) return;
      const [replacedStarter] = nonPlayingOutfieldStarters.splice(replacementIndex, 1);
      activeOutfieldCounts[replacedStarter.positionType] =
        (activeOutfieldCounts[replacedStarter.positionType] || 0) - 1;
      activeOutfieldCounts[benchPlayer.positionType] =
        (activeOutfieldCounts[benchPlayer.positionType] || 0) + 1;
      contributionsByElementID.set(replacedStarter.elementID, 0);
      contributionsByElementID.set(benchPlayer.elementID, benchPlayer.rawPoints);
      outfieldReplacementNotes.push(
        `${benchPlayer.displayName} (${benchPlayer.rawPoints}) for ${replacedStarter.displayName}`
      );
    });

    if (outfieldReplacementNotes.length > 0) {
      scoreCalculationRulesApplied.push(
        `Outfield auto-subs applied: ${outfieldReplacementNotes.join(", ")}.`
      );
    }
  }

  const captain = starters.find((player) => player.isCaptain && shouldAutoSubAsNonParticipant(player));
  const viceCaptain = players.find((player) => player.isViceCaptain && isEligibleAutoSubReplacement(player));
  if (captain && viceCaptain) {
    contributionsByElementID.set(captain.elementID, 0);
    contributionsByElementID.set(
      viceCaptain.elementID,
      (contributionsByElementID.get(viceCaptain.elementID) || 0) + viceCaptain.rawPoints
    );
    scoreCalculationRulesApplied.push(
      `Vice-captain boost applied: ${captain.displayName} did not play, so ${viceCaptain.displayName} was doubled (+${viceCaptain.rawPoints} pts).`
    );
  }

  const effectiveContributions = players
    .map((player) => {
      const points = contributionsByElementID.get(player.elementID) || 0;
      if (points === 0) return null;
      return {
        elementID: player.elementID,
        displayName: player.displayName,
        fullName: player.fullName || player.displayName,
        teamName: player.teamName,
        points,
      };
    })
    .filter(Boolean);
  const currentScore = effectiveContributions.reduce((sum, contribution) => sum + contribution.points, 0);

  return {
    currentScore,
    effectiveContributions,
    scoreCalculationRulesApplied,
    usedServerLiveData: players.some((player) => player.usedServerLiveData),
    playerCount: players.length,
  };
}

function fallbackFromSyncedState(squad) {
  const effectiveContributions = Array.isArray(squad && squad.effectiveContributions)
    ? squad.effectiveContributions
      .map((contribution) => {
        if (!contribution || typeof contribution !== "object") return null;
        const elementID = toPositiveInt(contribution.elementID, 0);
        const displayName = normalizeToken(contribution.displayName);
        const teamName = normalizeToken(contribution.teamName);
        const points = toFiniteInt(contribution.points, 0);
        if (elementID <= 0 || !displayName || !teamName || points === 0) return null;
        return {
          elementID,
          displayName,
          fullName: normalizeToken(contribution.fullName) || displayName,
          teamName,
          points,
        };
      })
      .filter(Boolean)
    : [];

  if (effectiveContributions.length > 0) {
    return {
      currentScore: effectiveContributions.reduce((sum, contribution) => sum + contribution.points, 0),
      effectiveContributions,
      scoreCalculationRulesApplied: [],
      usedServerLiveData: false,
      playerCount: 0,
    };
  }

  const resolvedCurrentScore = Number(squad && squad.resolvedCurrentScore);
  if (Number.isFinite(resolvedCurrentScore)) {
    return {
      currentScore: Math.floor(resolvedCurrentScore),
      effectiveContributions: [],
      scoreCalculationRulesApplied: [],
      usedServerLiveData: false,
      playerCount: 0,
    };
  }

  const estimatedCurrentScore = Number(squad && squad.estimatedCurrentScore);
  if (squad && squad.isEstimatedScore === true && Number.isFinite(estimatedCurrentScore)) {
    return {
      currentScore: Math.floor(estimatedCurrentScore),
      effectiveContributions: [],
      scoreCalculationRulesApplied: [],
      usedServerLiveData: false,
      playerCount: 0,
    };
  }

  const totalPoints = Number(squad && squad.totalPoints);
  if (Number.isFinite(totalPoints)) {
    return {
      currentScore: Math.floor(totalPoints),
      effectiveContributions: [],
      scoreCalculationRulesApplied: [],
      usedServerLiveData: false,
      playerCount: 0,
    };
  }

  return null;
}

function calculateFantasyScore(input) {
  const squad = input && input.squad && typeof input.squad === "object" ? input.squad : input;
  if (!squad || typeof squad !== "object") return null;

  return calculateFromPlayers(squad) || fallbackFromSyncedState(squad);
}

function calculateFantasyCurrentScore(input) {
  const breakdown = calculateFantasyScore(input);
  return breakdown && Number.isFinite(Number(breakdown.currentScore))
    ? Math.floor(Number(breakdown.currentScore))
    : null;
}

refreshDerivedContext();

module.exports = {
  calculateFantasyCurrentScore,
  calculateFantasyScore,
  fantasyScoreContextSummary,
  resetFantasyScoreContext,
  setFantasyScoreContext,
};
