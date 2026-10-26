import { normalizeMatch } from './api';
import { isMatchFinished, isMatchLive } from './matchState';
import { teamIdentityKeys } from './teamColors';
import { browserTimeZone } from './football';
import type { Match } from './types';

export interface TableScore {
  match: Match;
  scored: number;
  conceded: number;
  outcome: 'win' | 'loss' | 'draw';
  label: string;
}

export async function fetchTableMatches(names: string[], date: string, signal: AbortSignal): Promise<Match[]> {
  const matches: Match[] = [];
  for (let page = 1; ; page++) {
    const query = new URLSearchParams({ league: names.join(','), start: date, end: date,
      page: String(page), page_size: '200', time_zone: browserTimeZone(), filter_mode: 'intersection' });
    const response = await fetch(`/api/v1/matches?${query}`, { signal, cache: 'no-store' });
    if (!response.ok) throw new Error('Today’s scores are unavailable.');
    const raw = await response.json();
    const items = Array.isArray(raw) ? raw : raw.matches || [];
    matches.push(...items.map(normalizeMatch));
    if (response.headers.get('X-Has-More') !== 'true' || items.length === 0) return matches;
  }
}

export function tableScoresByTeam(matches: Match[], date: string): Map<string, TableScore> {
  const scores = new Map<string, TableScore>();
  // A live match takes precedence over an earlier result for the same team.
  const eligible = matches.filter(match => match.date === date && (isMatchLive(match) || isMatchFinished(match)))
    .sort((a, b) => Number(isMatchLive(a)) - Number(isMatchLive(b)) || a.time.localeCompare(b.time));
  for (const match of eligible) {
    if (typeof match.homeScore !== 'number' || typeof match.awayScore !== 'number') continue;
    for (const [team, scored, conceded] of [
      [match.homeTeam, match.homeScore, match.awayScore],
      [match.awayTeam, match.awayScore, match.homeScore],
    ] as const) {
      const outcome = scored > conceded ? 'win' : scored < conceded ? 'loss' : 'draw';
      const result = isMatchLive(match)
        ? { win: 'Winning', loss: 'Losing', draw: 'Drawing' }[outcome]
        : { win: 'Won', loss: 'Lost', draw: 'Drew' }[outcome];
      const score: TableScore = { match, scored, conceded, outcome, label: `${isMatchLive(match) ? 'Live' : 'Full time'}: ${result} ${scored} to ${conceded}` };
      for (const key of teamIdentityKeys(team)) scores.set(key, score);
    }
  }
  return scores;
}
