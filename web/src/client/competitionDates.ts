import { normalizeMatch } from './api';
import { isMatchFinished } from './matchState';
const cache = new Map<string, { time: number; promise: Promise<Record<string, number>> }>();
export function competitionDateCounts(names: string[], start: string, end: string, results: boolean) {
  const key = JSON.stringify([names, start, end, results]);
  const cached = cache.get(key);
  if (cached && Date.now() - cached.time < 60000) return cached.promise;
  const promise = (async () => {
    const counts: Record<string, number> = {};
    const seen = new Set<string>();
    let page = 1;
    while (true) {
      const query = new URLSearchParams({ league: names.join(','), start, end, page: String(page), page_size: '200', time_zone: 'Europe/London', filter_mode: 'intersection' });
      const response = await fetch(`/api/v1/matches?${query}`, { signal: AbortSignal.timeout(15000) });
      if (!response.ok) throw new Error('Date counts unavailable');
      const raw = await response.json();
      for (const item of Array.isArray(raw) ? raw : raw.matches || []) {
        const match = normalizeMatch(item);
        if (seen.has(match.id) || !names.includes(match.league) || (results && !isMatchFinished(match))) continue;
        seen.add(match.id); counts[match.date] = (counts[match.date] || 0) + 1;
      }
      if (response.headers.get('X-Has-More') !== 'true') break;
      page++;
    }
    return counts;
  })().catch(error => { cache.delete(key); throw error; });
  cache.set(key, { time: Date.now(), promise });
  if (cache.size > 20) cache.delete(cache.keys().next().value!);
  return promise;
}

// One row per lookup avoids downloading a season just to select its next date.
export async function preferredCompetitionDate(names: string[], today: string, results = false) {
  const lookup = async (future: boolean) => {
    const query = new URLSearchParams({ league: names.join(','), start: future ? today : '1900-01-01', end: future ? '9999-12-31' : today, sort: future ? 'asc' : 'desc', page_size: '1', page: '1', time_zone: 'Europe/London', filter_mode: 'intersection', ...(results ? { mode: 'results' } : {}) });
    const response = await fetch(`/api/v1/matches?${query}`, { signal: AbortSignal.timeout(15000) });
    if (!response.ok) throw new Error('Competition dates unavailable');
    const raw = await response.json();
    return (Array.isArray(raw) ? raw : raw.matches || [])[0]?.date as string | undefined;
  };
  if (!results) { const next = await lookup(true); if (next) return next; }
  return lookup(false);
}
