import { normalizeMatch } from './api';
import { isMatchAbandoned, isMatchFinished, isMatchLive } from './matchState';
import { browserTimeZone, ukChannels, moveDate, dateLabel } from './football';
import type { Match } from './types';
type DateFilters = { scope?: false | 'top' | 'epl'; tv?: boolean; query?: string; leagues?: string[] };
function matchesFilters(match: Match, names: string[], results: boolean, filters: DateFilters) {
  const finished = isMatchFinished(match) || isMatchAbandoned(match);
  return (!names.length || names.includes(match.league))
    && (!filters.leagues || filters.leagues.includes(match.league))
    && (!results || finished)
    && (!filters.tv || (!finished && ukChannels(match.tvChannels).length > 0))
    && `${match.homeTeam} ${match.awayTeam} ${match.league} ${match.tvChannels.map(c => c.name).join(' ')}`.toLowerCase().includes((filters.query || '').toLowerCase().trim());
}
function applyScope(query: URLSearchParams, filters: DateFilters) {
  if (filters.scope === 'top') query.set('view_option', 'preset:top-teams');
  if (filters.scope === 'epl') query.set('epl_only', 'true');
}

export function nextMatchDateLabel(date: string, today: string) {
  if (date === today) return 'today';
  if (date === moveDate(today, 1)) return 'tomorrow';
  if (date > today && date <= moveDate(today, 6)) return `this ${new Date(`${date}T12:00:00`).toLocaleDateString(undefined, { weekday: 'long' })}`;
  return dateLabel(date, true);
}

export async function nextMatchDate(names: string[], after: string, end: string, results: boolean, filters: DateFilters, active = () => true) {
  const query = new URLSearchParams({ start: moveDate(after, 1), end, sort: 'asc', page: '1', page_size: '200', time_zone: browserTimeZone(), filter_mode: 'intersection' });
  if (names.length) query.set('league', names.join(','));
  if (results) query.set('mode', 'results');
  applyScope(query, filters);
  for (let page = 1; active(); page++) {
    query.set('page', String(page));
    const response = await fetch(`/api/v1/matches?${query}`, { signal: AbortSignal.timeout(15000) });
    if (!response.ok) throw new Error('Next match date unavailable');
    const raw = await response.json();
    const matches = (Array.isArray(raw) ? raw : raw.matches || []).map(normalizeMatch);
    const match = matches.find((match: Match) => match.date > after && match.date <= end && matchesFilters(match, names, results, filters));
    if (match) return match.date;
    if (!matches.length || response.headers.get('X-Has-More') !== 'true') return undefined;
  }
}
type DateActivity = { counts: Record<string, number>; liveDates: Record<string, boolean>; finishedDates: Record<string, boolean> };
const cache = new Map<string, { time: number; promise: Promise<DateActivity> }>();
export function competitionDateCounts(names: string[], start: string, end: string, results: boolean, filters: DateFilters = {}) {
  const key = JSON.stringify([names, start, end, results, filters]);
  const cached = cache.get(key);
  if (cached && Date.now() - cached.time < 60000) return cached.promise;
  const promise = (async () => {
    const counts: Record<string, number> = {};
    const liveDates: Record<string, boolean> = {};
    const finishedDates: Record<string, boolean> = {};
    const seen = new Set<string>();
    let page = 1;
    while (true) {
      const query = new URLSearchParams({ league: names.join(','), start, end, page: String(page), page_size: '200', time_zone: browserTimeZone(), filter_mode: 'intersection' });
      applyScope(query, filters);
      const response = await fetch(`/api/v1/matches?${query}`, { signal: AbortSignal.timeout(15000) });
      if (!response.ok) throw new Error('Date counts unavailable');
      const raw = await response.json();
      for (const item of Array.isArray(raw) ? raw : raw.matches || []) {
        const match = normalizeMatch(item);
        if (seen.has(match.id) || !matchesFilters(match, names, results, filters)) continue;
        seen.add(match.id);
        if (isMatchLive(match)) liveDates[match.date] = true;
        finishedDates[match.date] = (finishedDates[match.date] ?? true) && (isMatchFinished(match) || isMatchAbandoned(match));
        if (results && !isMatchFinished(match) && !isMatchAbandoned(match)) continue;
        counts[match.date] = (counts[match.date] || 0) + 1;
      }
      if (response.headers.get('X-Has-More') !== 'true') break;
      page++;
    }
    return { counts, liveDates, finishedDates };
  })().catch(error => { cache.delete(key); throw error; });
  cache.set(key, { time: Date.now(), promise });
  if (cache.size > 20) cache.delete(cache.keys().next().value!);
  return promise;
}

// One row per lookup avoids downloading a season just to select its next date.
export async function preferredCompetitionDate(names: string[], today: string, results = false) {
  const lookup = async (future: boolean) => {
    const query = new URLSearchParams({ league: names.join(','), start: future ? today : '1900-01-01', end: future ? '9999-12-31' : today, sort: future ? 'asc' : 'desc', page_size: '1', page: '1', time_zone: browserTimeZone(), filter_mode: 'intersection', ...(results ? { mode: 'results' } : {}) });
    const response = await fetch(`/api/v1/matches?${query}`, { signal: AbortSignal.timeout(15000) });
    if (!response.ok) throw new Error('Competition dates unavailable');
    const raw = await response.json();
    return (Array.isArray(raw) ? raw : raw.matches || [])[0]?.date as string | undefined;
  };
  if (!results) { const next = await lookup(true); if (next) return next; }
  return lookup(false);
}
