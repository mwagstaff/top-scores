import { compareCompetitions } from "./competitionOrdering";
export interface Competition { id: string; name: string; aliases: string[]; weight: number; supports_table?: boolean }
let pending: Promise<Competition[]> | undefined;
export function loadCompetitions() {
  return pending ||= fetch('/api/v1/competitions/catalog', { signal: AbortSignal.timeout(10000) })
    .then(async response => { if (!response.ok) throw new Error('Competitions unavailable'); return ((await response.json()).competitions as Competition[]).sort(compareCompetitions); })
    .catch(error => { pending = undefined; throw error; });
}
export function teamPath(name: string, id?: string | null, competition?: string) {
  const query = new URLSearchParams();
  if (id) query.set('id', id);
  if (competition) query.set('competition', competition);
  return `/teams/${encodeURIComponent(name)}${query.size ? `?${query}` : ''}`;
}
