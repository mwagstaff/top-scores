import {
  channelApiQueryValues,
  selectableChannels,
  type LeagueTable,
  type LeagueTableRow,
  type LeagueTablesPayload,
  type MatchAssistProvider,
  type MatchDetails,
  type MatchGoalScorer,
  type MatchLineupPlayer,
  type MatchLineupSubstitution,
  type MatchRedCardEvent,
  type MatchTeamLineup,
  type MatchTeamLineups,
  type Match,
  type MatchesMode,
  type MatchesPayload,
  type Preferences,
  type TeamRankingEntry,
  type MatchYellowCardEvent,
} from "./types";

let competitionsPromise: Promise<string[]> | null = null;
let channelsPromise: Promise<string[]> | null = null;
let teamRankingsPromise: Promise<TeamRankingEntry[]> | null = null;
let competitionsCache: string[] | null = null;
let channelsCache: string[] | null = null;
let teamRankingsCache: TeamRankingEntry[] | null = null;
const matchDetailsCache = new Map<string, MatchDetails>();
const matchDetailsPromises = new Map<string, Promise<MatchDetails>>();

export async function fetchMatches(
  mode: MatchesMode,
  preferences: Preferences,
  signal?: AbortSignal
): Promise<MatchesPayload> {
  let page = 1;
  let lastUpdated: string | null = null;
  let totalCount = 0;
  const matches: Match[] = [];

  while (true) {
    const params = buildMatchQuery(mode, preferences, page);
    const response = await fetch(`/api/v1/matches?${params.toString()}`, {
      signal,
      cache: "no-store",
    });
    if (!response.ok) {
      throw new Error(`Failed to load ${mode}: ${response.status}`);
    }

    lastUpdated = response.headers.get("X-Last-Updated") || lastUpdated;
    totalCount = Number(response.headers.get("X-Total-Count") || totalCount);
    const pageMatches = (await response.json()).map(normalizeMatch);
    matches.push(...pageMatches);

    if (response.headers.get("X-Has-More") !== "true" || pageMatches.length === 0) {
      break;
    }

    page += 1;
  }

  return {
    matches,
    lastUpdated,
    totalCount: totalCount || matches.length,
  };
}

export function fetchCompetitions(): Promise<string[]> {
  if (competitionsCache) {
    return Promise.resolve(competitionsCache);
  }

  competitionsPromise ||= requestJson<string[]>("/api/v1/competitions")
    .then((items) =>
      [...items].sort((left, right) => left.localeCompare(right, undefined, { sensitivity: "base" }))
    )
    .then((items) => {
      competitionsCache = items;
      return items;
    })
    .catch((error) => {
      competitionsPromise = null;
      throw error;
    });
  return competitionsPromise;
}

export function fetchChannels(): Promise<string[]> {
  if (channelsCache) {
    return Promise.resolve(channelsCache);
  }

  channelsPromise ||= requestJson<string[]>("/api/v1/channels")
    .then((items) => selectableChannels(items))
    .then((items) => {
      channelsCache = items;
      return items;
    })
    .catch((error) => {
      channelsPromise = null;
      throw error;
    });
  return channelsPromise;
}

export function fetchTeamRankings(): Promise<TeamRankingEntry[]> {
  if (teamRankingsCache) {
    return Promise.resolve(teamRankingsCache);
  }

  teamRankingsPromise ||= requestJson<unknown[]>("/api/v1/teams?type=club")
    .then((items) => items.map(normalizeTeamRanking))
    .then((items) => {
      teamRankingsCache = items;
      return items;
    })
    .catch((error) => {
      teamRankingsPromise = null;
      throw error;
    });
  return teamRankingsPromise;
}

export function fetchMatchDetails(matchDetailsId: string): Promise<MatchDetails> {
  return fetchMatchDetailsInternal(matchDetailsId, false);
}

function fetchMatchDetailsInternal(matchDetailsId: string, forceRefresh: boolean): Promise<MatchDetails> {
  const normalizedId = matchDetailsId.trim();
  if (!normalizedId) {
    return Promise.reject(new Error("Missing match details id"));
  }

  const cached = forceRefresh ? null : matchDetailsCache.get(normalizedId);
  if (cached) {
    return Promise.resolve(cached);
  }

  const inFlight = forceRefresh ? null : matchDetailsPromises.get(normalizedId);
  if (inFlight) {
    return inFlight;
  }

  const request = requestJson<Record<string, unknown>>(
    `/api/v1/matches/${encodeURIComponent(normalizedId)}`,
    undefined,
    { cache: "no-store" }
  )
    .then(normalizeMatchDetails)
    .then((details) => {
      if (shouldCacheMatchDetails(details)) {
        matchDetailsCache.set(normalizedId, details);
      } else {
        matchDetailsCache.delete(normalizedId);
      }
      if (!forceRefresh) {
        matchDetailsPromises.delete(normalizedId);
      }
      return details;
    })
    .catch((error) => {
      if (!forceRefresh) {
        matchDetailsPromises.delete(normalizedId);
      }
      throw error;
    });

  if (!forceRefresh) {
    matchDetailsPromises.set(normalizedId, request);
  }
  return request;
}

export async function fetchLeagueTables(signal?: AbortSignal): Promise<LeagueTablesPayload> {
  const response = await fetch("/api/v1/tables", { signal });
  if (!response.ok) {
    throw new Error(`Failed to load tables: ${response.status}`);
  }

  const payload = await response.json() as Record<string, unknown>;
  return {
    leagues: normalizeLeagueTables(payload.leagues),
    lastUpdated:
      response.headers.get("X-Last-Updated") ||
      optionalString(payload.updated_at) ||
      null,
  };
}

async function requestJson<T>(url: string, signal?: AbortSignal, init?: RequestInit): Promise<T> {
  const response = await fetch(url, { ...init, signal });
  if (!response.ok) {
    let bodySnippet = "";
    try {
      bodySnippet = await response.text();
    } catch {
      bodySnippet = "";
    }

    const error = new Error(`Request failed: ${response.status}`);
    Object.assign(error, {
      status: response.status,
      bodySnippet,
    });
    throw error;
  }

  return response.json() as Promise<T>;
}

function buildMatchQuery(mode: MatchesMode, preferences: Preferences, page: number): URLSearchParams {
  const params = new URLSearchParams();
  const today = new Date();
  const startDate = new Date(today);
  const endDate = new Date(today);

  if (mode === "fixtures") {
    endDate.setDate(endDate.getDate() + 90);
    params.set("sort", "asc");
  } else {
    startDate.setDate(startDate.getDate() - 30);
    params.set("sort", "desc");
  }

  params.set("start", formatDateParam(mode === "fixtures" ? today : startDate));
  params.set("end", formatDateParam(mode === "fixtures" ? endDate : today));
  params.set("filter_mode", "intersection");
  params.set("page", String(page));
  params.set("page_size", "200");

  if (preferences.competitionFilterEnabled) {
    for (const league of preferences.selectedLeagues) {
      params.append("league", league);
    }
  }

  if (mode === "fixtures" && preferences.channelFilterEnabled) {
    for (const channel of channelApiQueryValues(preferences.selectedChannels)) {
      params.append("channel", channel);
    }
  }

  if (preferences.englishPremierLeagueTeamsOnly) {
    params.set("epl_only", "true");
  }

  return params;
}

function formatDateParam(date: Date): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function normalizeMatch(raw: Record<string, unknown>): Match {
  const date = asString(raw.date);
  const time = asString(raw.time);
  const homeTeam = asString(raw.home_team);
  const awayTeam = asString(raw.away_team);
  const league = asString(raw.league);

  return {
    id: [date, time, league, homeTeam, awayTeam].join("|"),
    date,
    time,
    homeTeam,
    awayTeam,
    league,
    leagueSubcategory: optionalString(raw.league_subcategory),
    tvChannels: Array.isArray(raw.tv_channels)
      ? raw.tv_channels.filter((item): item is string => typeof item === "string")
      : [],
    homeScore: optionalNumber(raw.home_score),
    awayScore: optionalNumber(raw.away_score),
    aggregateHomeScore: optionalNumber(raw.aggregate_home_score),
    aggregateAwayScore: optionalNumber(raw.aggregate_away_score),
    scoreStatus: optionalString(raw.score_status),
    penaltyResult: optionalString(raw.penalty_result),
    detailsUrl: optionalString(raw.details_url),
    matchDetailsId: optionalString(raw.match_details_id),
    matchDetails: null,
  };
}

function normalizeTeamRanking(raw: unknown): TeamRankingEntry {
  const source = typeof raw === "object" && raw ? (raw as Record<string, unknown>) : {};
  return {
    name: asString(source.Name ?? source.name),
    points: optionalNumber(source.Points ?? source.points ?? source.elo ?? source.rating),
    aliases: Array.isArray(source.aliases)
      ? source.aliases.filter((item): item is string => typeof item === "string")
      : Array.isArray(source.Aliases)
        ? source.Aliases.filter((item): item is string => typeof item === "string")
        : [],
  };
}

function normalizeMatchDetails(raw: Record<string, unknown>): MatchDetails {
  return {
    id: asString(raw.id),
    detailsUrl: optionalString(raw.details_url),
    date: optionalString(raw.date),
    time: optionalString(raw.time),
    league: optionalString(raw.league),
    homeTeam: optionalString(raw.home_team),
    awayTeam: optionalString(raw.away_team),
    homeScore: optionalNumber(raw.home_score),
    awayScore: optionalNumber(raw.away_score),
    aggregateHomeScore: optionalNumber(raw.aggregate_home_score),
    aggregateAwayScore: optionalNumber(raw.aggregate_away_score),
    scoreStatus: optionalString(raw.score_status),
    homeGoalScorers: normalizeGoalScorers(raw.home_goal_scorers),
    awayGoalScorers: normalizeGoalScorers(raw.away_goal_scorers),
    homeAssists: normalizeAssistProviders(raw.home_assists),
    awayAssists: normalizeAssistProviders(raw.away_assists),
    homeYellowCards: normalizeYellowCards(raw.home_yellow_cards),
    awayYellowCards: normalizeYellowCards(raw.away_yellow_cards),
    homeRedCards: normalizeRedCards(raw.home_red_cards),
    awayRedCards: normalizeRedCards(raw.away_red_cards),
    teamLineups: normalizeTeamLineups(raw.team_lineups),
    penaltyResult: optionalString(raw.penalty_result),
    inProgress: optionalBoolean(raw.in_progress),
    updatedAt: optionalString(raw.updated_at),
  };
}

function normalizeLeagueTables(value: unknown): LeagueTable[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((item) => {
    const source = typeof item === "object" && item ? (item as Record<string, unknown>) : {};
    const leagueID = asString(source.league_id);
    const leagueName = asString(source.league_name);

    return {
      id: leagueID || leagueName,
      leagueID,
      leagueName,
      stageName: optionalString(source.stage_name),
      sourceUrl: optionalString(source.source_url),
      updatedAt: optionalString(source.updated_at),
      rows: normalizeLeagueTableRows(source.rows),
    };
  });
}

function normalizeLeagueTableRows(value: unknown): LeagueTableRow[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((item) => {
    const source = typeof item === "object" && item ? (item as Record<string, unknown>) : {};
    const position = optionalNumber(source.position) ?? 0;
    const team = asString(source.team);

    return {
      id: `${position}-${team}`,
      position,
      team,
      played: optionalNumber(source.played) ?? 0,
      won: optionalNumber(source.won) ?? 0,
      drawn: optionalNumber(source.drawn) ?? 0,
      lost: optionalNumber(source.lost) ?? 0,
      goalsFor: optionalNumber(source.goals_for) ?? 0,
      goalsAgainst: optionalNumber(source.goals_against) ?? 0,
      goalDifference: optionalNumber(source.goal_difference) ?? 0,
      points: optionalNumber(source.points) ?? 0,
      form: normalizeStringArray(source.form),
      rankStatus: optionalString(source.rank_status),
    };
  });
}

function normalizeGoalScorers(value: unknown): MatchGoalScorer[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((item) => {
    const source = typeof item === "object" && item ? (item as Record<string, unknown>) : {};
    return {
      player: asString(source.player ?? source.player_name),
      goalTimes: normalizeStringArray(source.goal_times),
      ownGoalTimes: normalizeStringArray(source.own_goal_times),
      disallowedGoalTimes: normalizeStringArray(source.disallowed_goal_times),
    };
  });
}

function normalizeAssistProviders(value: unknown): MatchAssistProvider[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((item) => {
    const source = typeof item === "object" && item ? (item as Record<string, unknown>) : {};
    return {
      player: asString(source.player ?? source.player_name),
      assistTimes: normalizeStringArray(source.assist_times),
    };
  });
}

function normalizeRedCards(value: unknown): MatchRedCardEvent[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((item) => {
    const source = typeof item === "object" && item ? (item as Record<string, unknown>) : {};
    return {
      player: asString(source.player ?? source.player_name),
      redCardTimes: normalizeStringArray(source.red_card_times),
    };
  });
}

function normalizeYellowCards(value: unknown): MatchYellowCardEvent[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((item) => {
    const source = typeof item === "object" && item ? (item as Record<string, unknown>) : {};
    return {
      player: asString(source.player ?? source.player_name),
      yellowCardTimes: normalizeStringArray(source.yellow_card_times),
    };
  });
}

function normalizeTeamLineups(value: unknown): MatchTeamLineups | null {
  if (typeof value !== "object" || !value) {
    return null;
  }

  const source = value as Record<string, unknown>;
  const home = normalizeTeamLineup(source.home);
  const away = normalizeTeamLineup(source.away);
  if (!home && !away) {
    return null;
  }

  return { home, away };
}

function normalizeTeamLineup(value: unknown): MatchTeamLineup | null {
  if (typeof value !== "object" || !value) {
    return null;
  }

  const source = value as Record<string, unknown>;
  const team = optionalString(source.team);
  const manager = optionalString(source.manager);
  const formation = optionalString(source.formation);
  const startingLineup = normalizeLineupPlayers(source.starting_lineup);
  const substitutes = normalizeLineupPlayers(source.substitutes);
  const substitutions = normalizeLineupSubstitutions(source.substitutions);

  if (!team && !manager && !formation && startingLineup.length === 0 && substitutes.length === 0) {
    return null;
  }

  return {
    team,
    manager,
    formation,
    startingLineup,
    substitutes,
    substitutions,
  };
}

function normalizeLineupPlayers(value: unknown): MatchLineupPlayer[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((item) => {
    const source = typeof item === "object" && item ? (item as Record<string, unknown>) : {};
    return {
      number: optionalNumber(source.number) ?? 0,
      name: asString(source.name),
      positionCategory: optionalString(source.position_category),
      formationRowIndex: optionalNumber(source.formation_row_index),
      formationSlotIndex: optionalNumber(source.formation_slot_index),
      formationRowSize: optionalNumber(source.formation_row_size),
    };
  });
}

function normalizeLineupSubstitutions(value: unknown): MatchLineupSubstitution[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .map((item) => {
      const source = typeof item === "object" && item ? (item as Record<string, unknown>) : {};
      const playerOff = normalizeLineupPlayer(source.player_off);
      const playerOn = normalizeLineupPlayer(source.player_on);
      if (!playerOff || !playerOn) {
        return null;
      }

      return {
        minute: asString(source.minute),
        playerOff,
        playerOn,
      };
    })
    .filter((item): item is MatchLineupSubstitution => item !== null);
}

function normalizeLineupPlayer(value: unknown): MatchLineupPlayer | null {
  if (typeof value !== "object" || !value) {
    return null;
  }

  const source = value as Record<string, unknown>;
  return {
    number: optionalNumber(source.number) ?? 0,
    name: asString(source.name),
    positionCategory: optionalString(source.position_category),
    formationRowIndex: optionalNumber(source.formation_row_index),
    formationSlotIndex: optionalNumber(source.formation_slot_index),
    formationRowSize: optionalNumber(source.formation_row_size),
  };
}

function shouldCacheMatchDetails(details: MatchDetails): boolean {
  return !isIncompleteFinishedMatchDetails(details);
}

export function shouldRetryMatchDetails(details: MatchDetails): boolean {
  return isIncompleteFinishedMatchDetails(details);
}

function isIncompleteFinishedMatchDetails(details: MatchDetails): boolean {
  if (!isFinishedStatus(details.scoreStatus)) {
    return false;
  }

  const homeScore = details.homeScore ?? 0;
  const awayScore = details.awayScore ?? 0;
  const totalScore = homeScore + awayScore;
  if (totalScore <= 0) {
    return false;
  }

  return countGoalsFromScorers(details.homeGoalScorers) + countGoalsFromScorers(details.awayGoalScorers) < totalScore;
}

function countGoalsFromScorers(goalScorers: MatchGoalScorer[]): number {
  return goalScorers.reduce(
    (total, scorer) => total + scorer.goalTimes.length + scorer.ownGoalTimes.length,
    0
  );
}

function isFinishedStatus(status: string | null | undefined): boolean {
  const normalized = String(status || "").trim().toUpperCase();
  return normalized === "FT" || normalized === "AET" || normalized === "PEN" || normalized === "PENS" || normalized === "PEN.";
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function optionalString(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value : null;
}

function optionalNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function optionalBoolean(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null;
}

function normalizeStringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
}
