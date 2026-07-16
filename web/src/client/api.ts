import {
  channelApiQueryValues,
  selectableChannels,
  type CompetitionWeightEntry,
  type LeagueTable,
  type LeagueTableGroup,
  type LeagueTableRow,
  type LeagueTablesPayload,
  type MatchAssistProvider,
  type MatchDetails,
  type MatchGoalScorer,
  type MatchLineupPlayer,
  type MatchLineupSubstitution,
  type MatchRedCardEvent,
  type MatchSocialItem,
  type MatchTeamLineup,
  type MatchTeamLineups,
  type Match,
  type MatchesMode,
  type MatchesPayload,
  type PlayerDetails,
  type Preferences,
  type TeamRankingEntry,
  type MatchYellowCardEvent,
  type MatchVarEvent,
} from "./types";

let competitionsPromise: Promise<string[]> | null = null;
let channelsPromise: Promise<string[]> | null = null;
let teamRankingsPromise: Promise<TeamRankingEntry[]> | null = null;
let competitionWeightsPromise: Promise<CompetitionWeightEntry[]> | null = null;
let competitionsCache: string[] | null = null;
let channelsCache: string[] | null = null;
let teamRankingsCache: TeamRankingEntry[] | null = null;
let competitionWeightsCache: CompetitionWeightEntry[] | null = null;

// Team badge catalog — populated lazily when TEAM_LOGO_SOURCE === "tsdb".
// Maps idTeam → badge URL. A null map means catalog not loaded yet.
let teamBadgesByIdCache: Map<string, string> | null = null;
// Maps idTeam → TSDB brand colours (strColour1/strColour2).
let teamColorsByIdCache: Map<string, { primary: string | null; secondary: string | null }> | null = null;
let teamBadgesETag: string | null = null;
let teamBadgesLoading = false;

export function teamBadgeUrl(teamId: string | null | undefined): string | null {
  if (!teamId || !teamBadgesByIdCache) return null;
  return teamBadgesByIdCache.get(teamId) ?? null;
}

// Primary brand colour (TSDB strColour1) for a team, as `#RRGGBB`, or null.
export function teamAccentColor(teamId: string | null | undefined): string | null {
  if (!teamId || !teamColorsByIdCache) return null;
  return teamColorsByIdCache.get(teamId)?.primary ?? null;
}

export async function warmTeamBadges(): Promise<void> {
  if (teamBadgesLoading) return;
  teamBadgesLoading = true;
  try {
    const configRes = await fetch("/api/v1/teams/config");
    if (!configRes.ok) return;
    const config = await configRes.json() as Record<string, unknown>;
    if (String(config.team_logo_source ?? "") !== "tsdb") return;

    const headers: Record<string, string> = {};
    if (teamBadgesETag) headers["If-None-Match"] = teamBadgesETag;
    const res = await fetch("/api/v1/teams/badges", { headers });
    if (res.status === 304) return;
    if (!res.ok) return;

    const etag = res.headers.get("ETag");
    const payload = await res.json() as {
      teams?: Record<string, { badge_url?: string; color_primary?: string | null; color_secondary?: string | null }>;
    };
    const teams = payload.teams ?? {};
    const map = new Map<string, string>();
    const colorMap = new Map<string, { primary: string | null; secondary: string | null }>();
    for (const [id, entry] of Object.entries(teams)) {
      if (entry.badge_url) map.set(id, entry.badge_url);
      if (entry.color_primary || entry.color_secondary) {
        colorMap.set(id, { primary: entry.color_primary ?? null, secondary: entry.color_secondary ?? null });
      }
    }
    teamBadgesByIdCache = map;
    teamColorsByIdCache = colorMap;
    if (etag) teamBadgesETag = etag;
  } catch {
    // non-fatal: fall back to bundled logos
  } finally {
    teamBadgesLoading = false;
  }
}
const matchDetailsCache = new Map<string, MatchDetails>();
const matchDetailsPromises = new Map<string, Promise<MatchDetails>>();
const matchSocialCache = new Map<string, MatchSocialItem[]>();
const matchSocialPromises = new Map<string, Promise<MatchSocialItem[]>>();
const playerDetailsCache = new Map<string, PlayerDetails>();
const playerDetailsPromises = new Map<string, Promise<PlayerDetails>>();
const OPEN_ENDED_FIXTURE_END_DATE = "9999-12-31";
const RESULTS_HISTORY_YEARS = 1;

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
    page,
    hasMore: false,
  };
}

export async function fetchMatchesPage(
  mode: MatchesMode,
  preferences: Preferences,
  page: number,
  signal?: AbortSignal
): Promise<MatchesPayload> {
  const params = buildMatchQuery(mode, preferences, page);
  const response = await fetch(`/api/v1/matches?${params.toString()}`, {
    signal,
    cache: "no-store",
  });
  if (!response.ok) {
    throw new Error(`Failed to load ${mode}: ${response.status}`);
  }

  const matches = (await response.json()).map(normalizeMatch);
  return {
    matches,
    lastUpdated: response.headers.get("X-Last-Updated"),
    totalCount: Number(response.headers.get("X-Total-Count") || matches.length),
    page: Number(response.headers.get("X-Page") || page),
    hasMore: response.headers.get("X-Has-More") === "true" && matches.length > 0,
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

export function fetchCompetitionWeights(): Promise<CompetitionWeightEntry[]> {
  if (competitionWeightsCache) {
    return Promise.resolve(competitionWeightsCache);
  }

  competitionWeightsPromise ||= requestJson<unknown[]>("/competition-weights")
    .then((items) =>
      items
        .filter(
          (item): item is { name: string; weight: number } =>
            typeof (item as Record<string, unknown>)?.name === "string" &&
            typeof (item as Record<string, unknown>)?.weight === "number"
        )
        .map((item) => ({ name: item.name, weight: item.weight }))
    )
    .then((items) => {
      competitionWeightsCache = items;
      return items;
    })
    .catch((error) => {
      competitionWeightsPromise = null;
      throw error;
    });
  return competitionWeightsPromise;
}

export function fetchMatchDetails(matchDetailsId: string): Promise<MatchDetails> {
  return fetchMatchDetailsInternal(matchDetailsId, false);
}

export function fetchMatchSocial(matchDetailsId: string): Promise<MatchSocialItem[]> {
  const normalizedId = matchDetailsId.trim();
  if (!normalizedId) {
    return Promise.reject(new Error("Missing match details id"));
  }

  const cached = matchSocialCache.get(normalizedId);
  if (cached) {
    return Promise.resolve(cached);
  }

  const inFlight = matchSocialPromises.get(normalizedId);
  if (inFlight) {
    return inFlight;
  }

  const request = requestJson<unknown[]>(
    `/api/v1/matches/${encodeURIComponent(normalizedId)}/social`,
    undefined,
    { cache: "no-store" }
  )
    .then(normalizeMatchSocialItems)
    .then((items) => {
      if (items.length > 0) {
        matchSocialCache.set(normalizedId, items);
      } else {
        matchSocialCache.delete(normalizedId);
      }
      matchSocialPromises.delete(normalizedId);
      return items;
    })
    .catch((error) => {
      matchSocialPromises.delete(normalizedId);
      throw error;
    });

  matchSocialPromises.set(normalizedId, request);
  return request;
}

export function fetchPlayerDetails(playerId: string): Promise<PlayerDetails> {
  const normalizedId = playerId.trim();
  if (!normalizedId) {
    return Promise.reject(new Error("Missing player id"));
  }

  const cached = playerDetailsCache.get(normalizedId);
  if (cached) {
    return Promise.resolve(cached);
  }

  const inFlight = playerDetailsPromises.get(normalizedId);
  if (inFlight) {
    return inFlight;
  }

  const request = requestJson<Record<string, unknown>>(
    `/api/v1/players/${encodeURIComponent(normalizedId)}`,
    undefined,
    { cache: "no-store" }
  )
    .then(normalizePlayerDetails)
    .then((details) => {
      playerDetailsCache.set(normalizedId, details);
      playerDetailsPromises.delete(normalizedId);
      return details;
    })
    .catch((error) => {
      playerDetailsPromises.delete(normalizedId);
      throw error;
    });

  playerDetailsPromises.set(normalizedId, request);
  return request;
}

export function clearMatchDetailsCache(matchDetailsId: string): void {
  const id = matchDetailsId.trim();
  if (id) {
    matchDetailsCache.delete(id);
    matchDetailsPromises.delete(id);
  }
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
  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;

  if (mode === "fixtures") {
    params.set("sort", "asc");
  } else {
    params.set("sort", "desc");
  }

  params.set(
    "start",
    mode === "fixtures" ? formatDateParam(fixtureLiveOverlapStartDate(today)) : formatDateParam(resultHistoryStartDate(today))
  );
  params.set("end", mode === "fixtures" ? OPEN_ENDED_FIXTURE_END_DATE : formatDateParam(today));
  params.set("page", String(page));
  params.set("page_size", "200");
  if (timeZone) {
    params.set("time_zone", timeZone);
  }

  if (mode === "fixtures" && preferences.channelFilterEnabled) {
    for (const channel of channelApiQueryValues(preferences.selectedChannels)) {
      params.append("channel", channel);
    }
  }

  if (preferences.englishPremierLeagueTeamsOnly) {
    params.set("epl_only", "true");
  }
  if (preferences.englishPremierLeagueTeamsOnly && preferences.majorUEFAClubGamesEnabled) {
    params.set("major_uefa", "true");
  }
  if (preferences.englishPremierLeagueTeamsOnly && preferences.homeNationsFilterEnabled) {
    params.set("home_nations", "true");
  }
  if (preferences.englishPremierLeagueTeamsOnly && preferences.majorTournamentsFilterEnabled) {
    params.set("major_tournaments", "true");
  }

  return params;
}

function resultHistoryStartDate(today: Date): Date {
  const startDate = new Date(today);
  startDate.setFullYear(startDate.getFullYear() - RESULTS_HISTORY_YEARS);
  return startDate;
}

function fixtureLiveOverlapStartDate(today: Date): Date {
  const startDate = new Date(today);
  startDate.setDate(startDate.getDate() - 1);
  return startDate;
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
    homeTeamId: optionalString(raw.home_team_id),
    awayTeamId: optionalString(raw.away_team_id),
    homeShortName: optionalString(raw.home_short_name),
    awayShortName: optionalString(raw.away_short_name),
    league,
    leagueId: optionalString(raw.league_id),
    leagueSubcategory: optionalString(raw.league_subcategory),
    tvChannels: Array.isArray(raw.tv_channels)
      ? raw.tv_channels.flatMap((item) => {
          if (typeof item === "string") {
            // Legacy flat-string format — wrap in structured shape.
            return [{ name: item, country: null, countryCode: null, logo: null }];
          }
          if (item && typeof item === "object" && typeof item.name === "string" && item.name) {
            return [{ name: item.name, country: item.country ?? null, countryCode: item.countryCode ?? null, logo: item.logo ?? null }];
          }
          return [];
        })
      : [],
    homeScore: optionalNumber(raw.home_score),
    awayScore: optionalNumber(raw.away_score),
    aggregateHomeScore: optionalNumber(raw.aggregate_home_score),
    aggregateAwayScore: optionalNumber(raw.aggregate_away_score),
    firstLegHomeScore: optionalNumber(raw.first_leg_home_score),
    firstLegAwayScore: optionalNumber(raw.first_leg_away_score),
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
    homeShortName: optionalString(raw.home_short_name),
    awayShortName: optionalString(raw.away_short_name),
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
    homeVarEvents: normalizeVarEvents(raw.home_var_events),
    awayVarEvents: normalizeVarEvents(raw.away_var_events),
    teamLineups: normalizeTeamLineups(raw.team_lineups),
    penaltyResult: optionalString(raw.penalty_result),
    inProgress: optionalBoolean(raw.in_progress),
    updatedAt: optionalString(raw.updated_at),
  };
}

function normalizePlayerDetails(raw: Record<string, unknown>): PlayerDetails {
  return {
    id: asString(raw.id),
    name: asString(raw.name),
    team: optionalString(raw.team),
    born: optionalString(raw.born),
    description: optionalString(raw.description),
    side: optionalString(raw.side),
    position: optionalString(raw.position),
    birthLocation: optionalString(raw.birth_location),
    cutoutUrl: optionalString(raw.cutout_url),
    thumbUrl: optionalString(raw.thumb_url),
    renderUrl: optionalString(raw.render_url),
  };
}

function normalizeMatchSocialItems(value: unknown): MatchSocialItem[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.flatMap((item) => {
    const source = typeof item === "object" && item ? (item as Record<string, unknown>) : {};
    const url = asString(source.url).trim();
    const title = asString(source.title).trim();
    if (!url || !title) {
      return [];
    }

    const account = typeof source.account === "object" && source.account
      ? (source.account as Record<string, unknown>)
      : null;

    return [{
      id: asString(source.id) || url,
      type: optionalString(source.type),
      url,
      title,
      text: optionalString(source.text),
      thumbnail: optionalString(source.thumbnail),
      publishedAt: optionalString(source.published_at),
      account: account
        ? {
            handle: optionalString(account.handle),
            name: optionalString(account.name),
          }
        : null,
    }];
  });
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
      realtime: source.realtime === true,
      groups: normalizeLeagueTableGroups(source.groups),
      rows: normalizeLeagueTableRows(source.rows),
    };
  });
}

function normalizeLeagueTableGroups(value: unknown): LeagueTableGroup[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.reduce<LeagueTableGroup[]>((groups, item) => {
    const source = typeof item === "object" && item ? (item as Record<string, unknown>) : {};
    const rows = normalizeLeagueTableRows(source.rows);
    if (rows.length === 0) {
      return groups;
    }

    groups.push({
      name: optionalString(source.name),
      rows,
    });
    return groups;
  }, []);
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
      live: source.live === true,
      previousPosition: optionalNumber(source.previous_position) ?? null,
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

function normalizeVarEvents(value: unknown): MatchVarEvent[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.reduce<MatchVarEvent[]>((acc, item) => {
    const source = typeof item === "object" && item ? (item as Record<string, unknown>) : {};
    const detail = optionalString(source.detail);
    if (!detail) return acc;
    acc.push({
      player: optionalString(source.player),
      minute: optionalString(source.minute),
      detail,
      cutoutUrl: optionalString(source.cutout_url),
      idPlayer: optionalString(source.id_player),
    });
    return acc;
  }, []);
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
      idPlayer: optionalString(source.id_player),
      positionCategory: optionalString(source.position_category),
      position: optionalString(source.position),
      positionShort: optionalString(source.position_short),
      cutoutUrl: optionalString(source.cutout_url),
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
    idPlayer: optionalString(source.id_player),
    positionCategory: optionalString(source.position_category),
    position: optionalString(source.position),
    positionShort: optionalString(source.position_short),
    cutoutUrl: optionalString(source.cutout_url),
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
