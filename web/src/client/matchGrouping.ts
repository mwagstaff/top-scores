import {
  type CompetitionWeightEntry,
  type Match,
  type MatchDayGroup,
  type MatchGroupSortOrder,
  type MatchLeagueGroup,
  type TeamRankingEntry,
} from "./types";
import { normalizedTeamKey, teamIdentityNames } from "./teamColors";

const stopWords = new Set(["fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk", "club", "the", "and"]);

export class TeamRatingLookup {
  private readonly exactByKey = new Map<string, number>();
  private readonly candidates: Array<{ key: string; tokens: string[]; rating: number }> = [];

  constructor(entries: TeamRankingEntry[], private readonly defaultPoints = 1000) {
    for (const entry of entries) {
      if (typeof entry.points !== "number" || !Number.isFinite(entry.points)) {
        continue;
      }

      const names = Array.from(
        new Set(
          [entry.name, ...entry.aliases]
            .flatMap((name) => teamIdentityNames(name))
            .filter(Boolean)
        )
      );
      for (const name of names) {
        const key = normalizedKey(name);
        if (!key) {
          continue;
        }

        if (!this.exactByKey.has(key)) {
          this.exactByKey.set(key, entry.points);
        }
        this.candidates.push({
          key,
          tokens: normalizedTokens(name),
          rating: entry.points,
        });
      }
    }
  }

  resolvedRating(teamName: string): number {
    return this.rating(teamName) ?? this.defaultPoints;
  }

  private rating(teamName: string): number | null {
    let bestScore = 0;
    let bestRating: number | null = null;

    for (const variant of teamIdentityNames(teamName)) {
      const key = normalizedKey(variant);
      if (!key) {
        continue;
      }

      if (this.exactByKey.has(key)) {
        return this.exactByKey.get(key) ?? null;
      }

      const sourceTokens = normalizedTokens(variant);
      for (const candidate of this.candidates) {
        const score = similarity(key, candidate.key, sourceTokens, candidate.tokens);
        if (score > bestScore) {
          bestScore = score;
          bestRating = candidate.rating;
        }
      }
    }

    return bestScore >= 0.86 ? bestRating : null;
  }
}

export class CompetitionWeightLookup {
  private readonly exactByKey = new Map<string, number>();

  constructor(entries: CompetitionWeightEntry[]) {
    for (const entry of entries) {
      const key = normalizedKey(entry.name);
      if (key && !this.exactByKey.has(key)) {
        this.exactByKey.set(key, entry.weight);
      }
    }
  }

  weight(leagueName: string): number | null {
    // Try exact normalized match first
    const key = normalizedKey(leagueName);
    if (this.exactByKey.has(key)) {
      return this.exactByKey.get(key) ?? null;
    }

    // Try prefix matching: league name may include a subcategory suffix (e.g. "Premier League: Round 35")
    // Check if any stored key is a prefix of or contained within the query
    const queryTokens = normalizedTokens(leagueName);
    let bestWeight: number | null = null;
    let bestScore = 0;
    let hasPrefixMatch = false;
    for (const [storedKey, storedWeight] of this.exactByKey) {
      if (key.startsWith(storedKey) || storedKey.startsWith(key)) {
        const shorter = Math.min(storedKey.length, key.length);
        const longer = Math.max(storedKey.length, key.length);
        const score = longer > 0 ? shorter / longer : 1;
        if (score > bestScore) {
          bestScore = score;
          bestWeight = storedWeight;
          hasPrefixMatch = true;
        }
        continue;
      }
      // Dice coefficient on tokens for fuzzy fallback
      const storedTokens = normalizedTokens(storedKey);
      const dice = diceCoefficient(queryTokens, storedTokens);
      if (dice > bestScore) {
        bestScore = dice;
        bestWeight = storedWeight;
      }
    }

    // Prefix matches are structural — bypass the fuzzy threshold.
    // Fuzzy (dice) matches require >= 0.7 confidence.
    return hasPrefixMatch || bestScore >= 0.7 ? bestWeight : null;
  }
}

export function groupMatches(
  matches: Match[],
  mode: "fixtures" | "results",
  sortOrder: MatchGroupSortOrder,
  ratingLookup: TeamRatingLookup,
  weightLookup: CompetitionWeightLookup = new CompetitionWeightLookup([])
): MatchDayGroup[] {
  const groupedByDate = new Map<string, Match[]>();

  for (const match of matches) {
    const bucket = groupedByDate.get(match.date) ?? [];
    bucket.push(match);
    groupedByDate.set(match.date, bucket);
  }

  const dateKeys = Array.from(groupedByDate.keys()).sort();
  if (mode === "results") {
    dateKeys.reverse();
  }

  return dateKeys.map((dateKey) => {
    const dateMatches = groupedByDate.get(dateKey) ?? [];
    const parsedDate = parseDateKey(dateKey);
    const displayDate = parsedDate ? displayDateWithRelative(parsedDate) : dateKey;
    const isToday = parsedDate ? isSameDay(parsedDate, new Date()) : false;
    const tomorrow = new Date();
    tomorrow.setDate(tomorrow.getDate() + 1);
    const isTomorrow = parsedDate ? isSameDay(parsedDate, tomorrow) : false;

    const leagues = new Map<string, Match[]>();
    for (const match of dateMatches) {
      const leagueName = displayLeague(match);
      const bucket = leagues.get(leagueName) ?? [];
      bucket.push(match);
      leagues.set(leagueName, bucket);
    }

    const leagueSections = Array.from(leagues.entries())
      .map(([league, leagueMatches]) => {
        const sortedMatches = sortMatchesWithinLeague(leagueMatches, sortOrder, ratingLookup);
        const leader = sortedMatches[0];
        return {
          league,
          matches: sortedMatches,
          competitionWeight: weightLookup.weight(league),
          totalTeamRating: leagueMatches.reduce(
            (total, match) => total + totalTeamRating(match, ratingLookup),
            0
          ),
          leadingMatchRating: leader ? totalTeamRating(leader, ratingLookup) : 0,
          leadingKickoff: leader ? matchSortDate(leader) : Number.POSITIVE_INFINITY,
          leadingHomeTeam: leader?.homeTeam ?? "",
          leadingAwayTeam: leader?.awayTeam ?? "",
        };
      })
      .sort((left, right) => compareLeagueSections(left, right, sortOrder))
      .map<MatchLeagueGroup>((section) => ({
        id: `${dateKey}|${section.league}`,
        league: section.league,
        matches: section.matches,
      }));

    return {
      id: dateKey,
      dateKey,
      displayDate,
      isToday,
      isTomorrow,
      leagues: leagueSections,
    };
  });
}

export function displayLeague(match: Match): string {
  return match.leagueSubcategory ? `${match.league}: ${match.leagueSubcategory}` : match.league;
}

export function displayStatus(match: Match): string {
  const rawStatus = (match.scoreStatus || "").trim();
  if (rawStatus) {
    if (/^\d{1,3}(?:\+\d{1,2})?'?$/.test(rawStatus)) {
      return `${rawStatus.replace(/'/g, "")}'`;
    }
    return rawStatus.toUpperCase();
  }

  if (typeof match.homeScore === "number" && typeof match.awayScore === "number") {
    return "-";
  }

  return match.time;
}

export function isMatchLive(match: Match): boolean {
  const status = (match.scoreStatus || "").trim().toUpperCase();
  if (!status) {
    return false;
  }
  if (/^\d{1,3}(?:\+\d{1,2})?'?$/.test(status)) {
    return true;
  }
  return ["HT", "ET", "LIVE"].includes(status);
}

export function isMatchFinished(match: Match): boolean {
  const status = (match.scoreStatus || "").trim().toUpperCase();
  return ["FT", "AET", "PENS"].includes(status);
}

export function aggregateSummary(match: Match): string | null {
  const firstLegHome = match.firstLegHomeScore;
  const firstLegAway = match.firstLegAwayScore;

  if (typeof firstLegHome === "number" && typeof firstLegAway === "number") {
    const homeScore = typeof match.homeScore === "number" ? match.homeScore : 0;
    const awayScore = typeof match.awayScore === "number" ? match.awayScore : 0;
    const aggHome = firstLegHome + homeScore;
    const aggAway = firstLegAway + awayScore;
    return `Agg: ${aggHome}-${aggAway}`;
  }

  return null;
}

export function parseKickoff(match: Match): Date | null {
  if (!/^\d{2}:\d{2}$/.test(match.time)) {
    return null;
  }

  const [year, month, day] = match.date.split("-").map(Number);
  const [hours, minutes] = match.time.split(":").map(Number);
  if (!year || !month || !day) {
    return null;
  }

  return new Date(year, month - 1, day, hours, minutes);
}

function compareLeagueSections(
  left: {
    league: string;
    competitionWeight: number | null;
    totalTeamRating: number;
    leadingMatchRating: number;
    leadingKickoff: number;
    leadingHomeTeam: string;
    leadingAwayTeam: string;
  },
  right: {
    league: string;
    competitionWeight: number | null;
    totalTeamRating: number;
    leadingMatchRating: number;
    leadingKickoff: number;
    leadingHomeTeam: string;
    leadingAwayTeam: string;
  },
  sortOrder: MatchGroupSortOrder
) {
  // Competition weight is the primary sort key when available — higher weight first.
  // Leagues with a known weight always rank above leagues without one.
  if (left.competitionWeight !== null || right.competitionWeight !== null) {
    const lw = left.competitionWeight ?? -1;
    const rw = right.competitionWeight ?? -1;
    if (lw !== rw) {
      return rw - lw;
    }
  }

  switch (sortOrder) {
    case "kickoffThenTeamScore":
      if (left.leadingKickoff !== right.leadingKickoff) {
        return left.leadingKickoff - right.leadingKickoff;
      }
      if (left.leadingMatchRating !== right.leadingMatchRating) {
        return right.leadingMatchRating - left.leadingMatchRating;
      }
      break;
    case "kickoffThenAlphabetical":
      if (left.leadingKickoff !== right.leadingKickoff) {
        return left.leadingKickoff - right.leadingKickoff;
      }
      if (left.leadingHomeTeam !== right.leadingHomeTeam) {
        return left.leadingHomeTeam.localeCompare(right.leadingHomeTeam, undefined, {
          sensitivity: "base",
        });
      }
      if (left.leadingAwayTeam !== right.leadingAwayTeam) {
        return left.leadingAwayTeam.localeCompare(right.leadingAwayTeam, undefined, {
          sensitivity: "base",
        });
      }
      break;
    case "teamScore":
    case "alphabetical":
      if (left.totalTeamRating !== right.totalTeamRating) {
        return right.totalTeamRating - left.totalTeamRating;
      }
      if (left.leadingMatchRating !== right.leadingMatchRating) {
        return right.leadingMatchRating - left.leadingMatchRating;
      }
      break;
    default:
      break;
  }

  return left.league.localeCompare(right.league, undefined, { sensitivity: "base" });
}

function sortMatchesWithinLeague(
  matches: Match[],
  sortOrder: MatchGroupSortOrder,
  ratingLookup: TeamRatingLookup
): Match[] {
  return [...matches].sort((left, right) => {
    switch (sortOrder) {
      case "teamScore": {
        const leftScore = totalTeamRating(left, ratingLookup);
        const rightScore = totalTeamRating(right, ratingLookup);
        if (leftScore !== rightScore) {
          return rightScore - leftScore;
        }
        break;
      }
      case "alphabetical": {
        const home = left.homeTeam.localeCompare(right.homeTeam, undefined, {
          sensitivity: "base",
        });
        if (home !== 0) {
          return home;
        }
        const away = left.awayTeam.localeCompare(right.awayTeam, undefined, {
          sensitivity: "base",
        });
        if (away !== 0) {
          return away;
        }
        break;
      }
      case "kickoffThenTeamScore": {
        const kickoff = matchSortDate(left) - matchSortDate(right);
        if (kickoff !== 0) {
          return kickoff;
        }
        const leftScore = totalTeamRating(left, ratingLookup);
        const rightScore = totalTeamRating(right, ratingLookup);
        if (leftScore !== rightScore) {
          return rightScore - leftScore;
        }
        break;
      }
      case "kickoffThenAlphabetical": {
        const kickoff = matchSortDate(left) - matchSortDate(right);
        if (kickoff !== 0) {
          return kickoff;
        }
        const home = left.homeTeam.localeCompare(right.homeTeam, undefined, {
          sensitivity: "base",
        });
        if (home !== 0) {
          return home;
        }
        const away = left.awayTeam.localeCompare(right.awayTeam, undefined, {
          sensitivity: "base",
        });
        if (away !== 0) {
          return away;
        }
        break;
      }
      default:
        break;
    }

    return left.id.localeCompare(right.id, undefined, { sensitivity: "base" });
  });
}

function totalTeamRating(match: Match, ratingLookup: TeamRatingLookup): number {
  return ratingLookup.resolvedRating(match.homeTeam) + ratingLookup.resolvedRating(match.awayTeam);
}

function matchSortDate(match: Match): number {
  const kickoff = parseKickoff(match);
  return kickoff ? kickoff.getTime() : Number.POSITIVE_INFINITY;
}

function normalizedTokens(value: string): string[] {
  return value
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[.'’_-]/g, " ")
    .split(/[^a-z0-9]+/g)
    .map((token) => token.trim())
    .filter((token) => token && !stopWords.has(token));
}

function normalizedKey(value: string): string {
  const tokens = normalizedTokens(value);
  if (tokens.length > 0) {
    return tokens.join("");
  }
  return normalizedTeamKey(value);
}

function similarity(
  leftKey: string,
  rightKey: string,
  leftTokens: string[],
  rightTokens: string[]
): number {
  const base = normalizedEditSimilarity(leftKey, rightKey);
  const dice = diceCoefficient(leftTokens, rightTokens);
  const prefix = prefixSimilarity(leftKey, rightKey, leftTokens, rightTokens);
  return Math.max(base, dice, prefix);
}

function normalizedEditSimilarity(left: string, right: string): number {
  const maxLength = Math.max(left.length, right.length);
  if (maxLength === 0) {
    return 1;
  }

  return 1 - levenshtein(left, right) / maxLength;
}

function diceCoefficient(left: string[], right: string[]): number {
  if (left.length === 0 && right.length === 0) {
    return 1;
  }

  const leftSet = new Set(left);
  const rightSet = new Set(right);
  const overlap = Array.from(leftSet).filter((token) => rightSet.has(token)).length;
  return (2 * overlap) / (left.length + right.length);
}

function prefixSimilarity(
  leftKey: string,
  rightKey: string,
  leftTokens: string[],
  rightTokens: string[]
): number {
  if (Math.min(leftTokens.length, rightTokens.length) !== 1) {
    return 0;
  }

  if (leftKey.startsWith(rightKey) || rightKey.startsWith(leftKey)) {
    const shorter = Math.min(leftKey.length, rightKey.length);
    const longer = Math.max(leftKey.length, rightKey.length);
    if (longer === 0) {
      return 1;
    }
    return Math.min(1, shorter / longer + 0.3);
  }

  return 0;
}

function levenshtein(left: string, right: string): number {
  const leftChars = Array.from(left);
  const rightChars = Array.from(right);
  let previous = Array.from({ length: rightChars.length + 1 }, (_, index) => index);

  for (let rowIndex = 0; rowIndex < leftChars.length; rowIndex += 1) {
    const current = [rowIndex + 1];

    for (let colIndex = 0; colIndex < rightChars.length; colIndex += 1) {
      const cost = leftChars[rowIndex] === rightChars[colIndex] ? 0 : 1;
      current[colIndex + 1] = Math.min(
        previous[colIndex + 1] + 1,
        current[colIndex] + 1,
        previous[colIndex] + cost
      );
    }

    previous = current;
  }

  return previous[rightChars.length];
}

function parseDateKey(dateKey: string): Date | null {
  const [year, month, day] = dateKey.split("-").map(Number);
  if (!year || !month || !day) {
    return null;
  }

  return new Date(year, month - 1, day);
}

function displayDateWithRelative(date: Date): string {
  const formatter = new Intl.DateTimeFormat(undefined, {
    weekday: "short",
    month: "short",
    day: "numeric",
    year: "numeric",
  });

  const base = formatter.format(date);
  if (isSameDay(date, new Date())) {
    return `${base} (Today)`;
  }

  const tomorrow = new Date();
  tomorrow.setDate(tomorrow.getDate() + 1);
  if (isSameDay(date, tomorrow)) {
    return `${base} (Tomorrow)`;
  }

  return base;
}

function isSameDay(left: Date, right: Date): boolean {
  return (
    left.getFullYear() === right.getFullYear() &&
    left.getMonth() === right.getMonth() &&
    left.getDate() === right.getDate()
  );
}
