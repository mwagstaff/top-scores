export type MatchesMode = "fixtures" | "results";

export type MatchGroupSortOrder =
  | "alphabetical"
  | "teamScore"
  | "kickoffThenAlphabetical"
  | "kickoffThenTeamScore";

export interface Preferences {
  selectedLeagues: string[];
  selectedChannels: string[];
  competitionFilterEnabled: boolean;
  channelFilterEnabled: boolean;
  englishPremierLeagueTeamsOnly: boolean;
  majorUEFAClubGamesEnabled: boolean;
  homeNationsFilterEnabled: boolean;
  majorTournamentsFilterEnabled: boolean;
  refreshIntervalMinutes: number;
  matchGroupSortOrder: MatchGroupSortOrder;
}

export interface TvChannel {
  name: string;
  country: string | null;
  countryCode: string | null;
  logo: string | null;
}

export interface Match {
  id: string;
  date: string;
  time: string;
  homeTeam: string;
  awayTeam: string;
  homeTeamId?: string | null;
  awayTeamId?: string | null;
  homeShortName?: string | null;
  awayShortName?: string | null;
  league: string;
  leagueId?: string | null;
  leagueSubcategory?: string | null;
  tvChannels: TvChannel[];
  homeScore?: number | null;
  awayScore?: number | null;
  aggregateHomeScore?: number | null;
  aggregateAwayScore?: number | null;
  firstLegHomeScore?: number | null;
  firstLegAwayScore?: number | null;
  scoreStatus?: string | null;
  penaltyResult?: string | null;
  detailsUrl?: string | null;
  matchDetailsId?: string | null;
  matchDetails?: MatchDetails | null;
}

export interface MatchGoalScorer {
  player: string;
  goalTimes: string[];
  ownGoalTimes: string[];
  disallowedGoalTimes: string[];
}

export interface MatchAssistProvider {
  player: string;
  assistTimes: string[];
}

export interface MatchRedCardEvent {
  player: string;
  redCardTimes: string[];
}

export interface MatchYellowCardEvent {
  player: string;
  yellowCardTimes: string[];
}

export interface MatchVarEvent {
  player: string | null;
  minute: string | null;
  detail: string;
  cutoutUrl?: string | null;
  idPlayer?: string | null;
}

export interface MatchLineupPlayer {
  number: number;
  name: string;
  idPlayer?: string | null;
  positionCategory?: string | null;
  position?: string | null;
  positionShort?: string | null;
  cutoutUrl?: string | null;
  formationRowIndex?: number | null;
  formationSlotIndex?: number | null;
  formationRowSize?: number | null;
}

export interface PlayerDetails {
  id: string;
  name: string;
  team?: string | null;
  born?: string | null;
  description?: string | null;
  side?: string | null;
  position?: string | null;
  birthLocation?: string | null;
  cutoutUrl?: string | null;
  thumbUrl?: string | null;
  renderUrl?: string | null;
}

export interface MatchSocialItem {
  id: string;
  type?: string | null;
  url: string;
  title: string;
  text?: string | null;
  thumbnail?: string | null;
  publishedAt?: string | null;
  account?: {
    handle?: string | null;
    name?: string | null;
  } | null;
}

export interface MatchLineupSubstitution {
  minute: string;
  playerOff: MatchLineupPlayer;
  playerOn: MatchLineupPlayer;
}

export interface MatchTeamLineup {
  team?: string | null;
  manager?: string | null;
  formation?: string | null;
  startingLineup: MatchLineupPlayer[];
  substitutes: MatchLineupPlayer[];
  substitutions: MatchLineupSubstitution[];
}

export interface MatchTeamLineups {
  home?: MatchTeamLineup | null;
  away?: MatchTeamLineup | null;
}

export interface MatchDetails {
  id: string;
  detailsUrl?: string | null;
  date?: string | null;
  time?: string | null;
  league?: string | null;
  homeTeam?: string | null;
  awayTeam?: string | null;
  homeShortName?: string | null;
  awayShortName?: string | null;
  homeScore?: number | null;
  awayScore?: number | null;
  aggregateHomeScore?: number | null;
  aggregateAwayScore?: number | null;
  scoreStatus?: string | null;
  homeGoalScorers: MatchGoalScorer[];
  awayGoalScorers: MatchGoalScorer[];
  homeAssists: MatchAssistProvider[];
  awayAssists: MatchAssistProvider[];
  homeYellowCards: MatchYellowCardEvent[];
  awayYellowCards: MatchYellowCardEvent[];
  homeRedCards: MatchRedCardEvent[];
  awayRedCards: MatchRedCardEvent[];
  homeVarEvents: MatchVarEvent[];
  awayVarEvents: MatchVarEvent[];
  teamLineups?: MatchTeamLineups | null;
  penaltyResult?: string | null;
  inProgress?: boolean | null;
  updatedAt?: string | null;
}

export interface MatchLeagueGroup {
  id: string;
  league: string;
  matches: Match[];
}

export interface MatchDayGroup {
  id: string;
  dateKey: string;
  displayDate: string;
  isToday: boolean;
  isTomorrow: boolean;
  leagues: MatchLeagueGroup[];
}

export interface MatchesPayload {
  matches: Match[];
  lastUpdated: string | null;
  totalCount: number;
  page: number;
  hasMore: boolean;
}

export interface LeagueTableRow {
  id: string;
  position: number;
  team: string;
  played: number;
  won: number;
  drawn: number;
  lost: number;
  goalsFor: number;
  goalsAgainst: number;
  goalDifference: number;
  points: number;
  form: string[];
  rankStatus?: string | null;
  /** True while this team is in an in-progress match (live overlay → pulse). */
  live?: boolean;
  /** Pre-overlay rank, present only on a live/realtime table (drives the trend arrow). */
  previousPosition?: number | null;
}

export interface LeagueTableGroup {
  name?: string | null;
  rows: LeagueTableRow[];
}

export interface LeagueTableZone {
  key: string;
  label: string;
  type: string;
  from: number;
  to: number;
}

export interface LeagueTable {
  id: string;
  leagueID: string;
  leagueName: string;
  stageName?: string | null;
  sourceUrl?: string | null;
  updatedAt?: string | null;
  /** True when live/just-finished results have been overlaid (positions are provisional). */
  realtime?: boolean;
  zones: LeagueTableZone[];
  groups: LeagueTableGroup[];
  rows: LeagueTableRow[];
}

export interface LeagueTablesPayload {
  leagues: LeagueTable[];
  lastUpdated: string | null;
}

export interface TeamRankingEntry {
  name: string;
  points: number | null;
  aliases: string[];
}

export interface CompetitionWeightEntry {
  name: string;
  weight: number;
}

export const defaultPreferences: Preferences = {
  selectedLeagues: [
    "Premier League",
    "FIFA World Cup 2026",
    "FIFA World Cup Qualifying - European",
    "UEFA Champions League",
    "UEFA Conference League",
    "UEFA Europa League",
    "UEFA Super Cup",
  ],
  selectedChannels: ["Amazon (all)", "BBC (all)", "ITV (all)", "Sky (all)", "TNT (all)"],
  competitionFilterEnabled: false,
  channelFilterEnabled: false,
  englishPremierLeagueTeamsOnly: true,
  majorUEFAClubGamesEnabled: true,
  homeNationsFilterEnabled: true,
  majorTournamentsFilterEnabled: true,
  refreshIntervalMinutes: 10,
  matchGroupSortOrder: "kickoffThenTeamScore",
};

export const channelGroupOptions = ["Amazon (all)", "BBC (all)", "ITV (all)", "Sky (all)", "TNT (all)"];

const specialChannelKeywords: Record<string, string> = {
  "Amazon (all)": "amazon",
  "BBC (all)": "bbc",
  "ITV (all)": "itv",
  "Sky (all)": "sky",
  "TNT (all)": "tnt",
};

export function normalizeText(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .trim();
}

export function canonicalChannelOption(selection: string): string | null {
  const normalizedSelection = normalizeText(selection);

  return (
    channelGroupOptions.find((option) => {
      const normalizedOption = normalizeText(option);
      const normalizedBase = normalizeText(option.replace("(all)", ""));
      return (
        normalizedSelection === normalizedOption ||
        normalizedSelection === normalizedBase
      );
    }) || null
  );
}

export function normalizeSelectedChannels(selections: string[]): string[] {
  const deduped = new Map<string, string>();

  for (const selection of selections) {
    const trimmed = selection.trim();
    if (!trimmed) {
      continue;
    }

    const canonical = canonicalChannelOption(trimmed) || trimmed;
    deduped.set(normalizeText(canonical), canonical);
  }

  return Array.from(deduped.values()).sort((left, right) =>
    left.localeCompare(right, undefined, { sensitivity: "base" })
  );
}

export function selectableChannels(channels: string[]): string[] {
  const all = new Set<string>(channelGroupOptions);
  for (const channel of normalizeSelectedChannels(channels)) {
    all.add(channel);
  }

  return Array.from(all).sort((left, right) =>
    left.localeCompare(right, undefined, { sensitivity: "base" })
  );
}

export function channelApiQueryValues(selections: string[]): string[] {
  return normalizeSelectedChannels(selections).map((selection) => {
    const canonical = canonicalChannelOption(selection);
    if (!canonical) {
      return selection;
    }

    return canonical.replace("(all)", "").trim();
  });
}

export function normalizePreferences(preferences: Partial<Preferences>): Preferences {
  return {
    ...defaultPreferences,
    ...preferences,
    selectedLeagues: [...(preferences.selectedLeagues ?? defaultPreferences.selectedLeagues)].sort(
      (left, right) => left.localeCompare(right, undefined, { sensitivity: "base" })
    ),
    selectedChannels: normalizeSelectedChannels(
      preferences.selectedChannels ?? defaultPreferences.selectedChannels
    ),
    refreshIntervalMinutes: Math.max(
      1,
      Math.min(60, preferences.refreshIntervalMinutes ?? defaultPreferences.refreshIntervalMinutes)
    ),
    matchGroupSortOrder:
      preferences.matchGroupSortOrder ?? defaultPreferences.matchGroupSortOrder,
  };
}

export const matchOrderOptions: Array<{
  value: MatchGroupSortOrder;
  label: string;
  description: string;
}> = [
  {
    value: "alphabetical",
    label: "Alphabetical",
    description: "Competition groups stay stable and teams sort A-Z.",
  },
  {
    value: "teamScore",
    label: "Team score",
    description: "Higher combined Elo-style team strength rises to the top.",
  },
  {
    value: "kickoffThenAlphabetical",
    label: "Kick-off then alphabetical",
    description: "Show earliest matches first, then A-Z within ties.",
  },
  {
    value: "kickoffThenTeamScore",
    label: "Kick-off then team score",
    description: "Show earliest matches first, then stronger fixtures first.",
  },
];

// ── Predictions (BSD markets) ───────────────────────────────────────
// Mirrors the iOS app's Prediction.swift — the /api/v1/predictions endpoint
// serves the same BSD projection to both clients.

export interface PredictionMatchResultMarket {
  probHome: number;
  probDraw: number;
  probAway: number;
}

export interface PredictionExpectedGoalsMarket {
  home: number;
  away: number;
}

export interface PredictionMarkets {
  matchResult?: PredictionMatchResultMarket | null;
  expectedGoals?: PredictionExpectedGoalsMarket | null;
}

export interface PredictionFixture {
  eventId: string;
  homeTeam: string;
  awayTeam: string;
  date: string | null;
  time: string | null;
  markets: PredictionMarkets | null;
}

export interface PredictionLeague {
  leagueId: string;
  leagueName: string;
  fixtures: PredictionFixture[];
}

// A single match's frozen, comparable-later prediction. Stored locally
// keyed by match id — see predictions.ts.
export interface StoredPrediction {
  matchId: string;
  homeGoals: number;
  awayGoals: number;
  homeWinProbability: number;
  drawProbability: number;
  awayWinProbability: number;
}
