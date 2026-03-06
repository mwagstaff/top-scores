import {
  channelApiQueryValues,
  selectableChannels,
  type Match,
  type MatchesMode,
  type MatchesPayload,
  type Preferences,
  type TeamRankingEntry,
} from "./types";

let competitionsPromise: Promise<string[]> | null = null;
let channelsPromise: Promise<string[]> | null = null;
let teamRankingsPromise: Promise<TeamRankingEntry[]> | null = null;
let competitionsCache: string[] | null = null;
let channelsCache: string[] | null = null;
let teamRankingsCache: TeamRankingEntry[] | null = null;

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
    const response = await fetch(`/api/v1/matches?${params.toString()}`, { signal });
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

async function requestJson<T>(url: string, signal?: AbortSignal): Promise<T> {
  const response = await fetch(url, { signal });
  if (!response.ok) {
    throw new Error(`Request failed: ${response.status}`);
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
