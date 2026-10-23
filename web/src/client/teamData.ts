import { fetchLeagueTables, normalizeMatch } from './api';
import { moveDate, ukDate } from './football';
import { isMatchFinished } from './matchState';
import type { LeagueTablesPayload, Match } from './types';
export interface SquadPlayer { id: string; name: string; jersey_number?: number; nationality?: string; specific_position?: string; position?: string; market_value_gbp?: number; cutout_url?: string; fpl_profile_url?: string; availability?: string; injury_type?: string }
export interface TeamManager { id: string; name: string; country?: string; preferred_formation?: string; tactical_profile?: string; image_url?: string; matches_total?: number; wins?: number; draws?: number; losses?: number; win_pct?: number }
export interface TeamData { id?: string; names: string[]; fixtures: Match[]; results: Match[]; tables?: LeagueTablesPayload; players: SquadPlayer[]; manager?: TeamManager; errors: string[]; pending?: string[] }
const cache = new Map<string, { time: number; value: Promise<TeamData> }>();
const snapshots = new Map<string, TeamData>();
const listeners = new Map<string, Set<(data: TeamData) => void>>();
export function cachedTeam(name: string, id?: string) { return snapshots.get(`${name}:${id || ''}`); }
export function watchTeam(name: string, id: string | undefined, listener: (data: TeamData) => void) {
  const key = `${name}:${id || ''}`;
  const group = listeners.get(key) || new Set(); group.add(listener); listeners.set(key, group);
  const snapshot = snapshots.get(key); if (snapshot) listener(snapshot);
  return () => { group.delete(listener); if (!group.size) listeners.delete(key); };
}
const json = async (path: string) => { const response = await fetch(`/api/v1/${path}`, { signal: AbortSignal.timeout(15000) }); if (!response.ok) throw new Error(`Request failed (${response.status})`); return response.json(); };
export const teamNameKey = (name: string) => name.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9]/g, '');
export function loadTeam(name: string, suppliedId?: string, refresh = false): Promise<TeamData> {
  const key = `${name}:${suppliedId || ''}`;
  const existing = cache.get(key);
  if (!refresh && existing && Date.now() - existing.time < 60000) return existing.value;
  const value = (async () => {
    const result: TeamData = { id: suppliedId, names: [name], fixtures: [], results: [], players: [], errors: [], pending: ['Current season', 'Upcoming fixtures', 'Previous matches', 'Players', 'Manager'] };
    const publish = (section?: string) => { if (section) result.pending = result.pending?.filter(item => item !== section); const snapshot = { ...result, errors: [...result.errors] }; snapshots.set(key, snapshot); listeners.get(key)?.forEach(listener => listener(snapshot)); };
    publish();
    const today = ukDate();
    const matches = async (mode: string) => {
      const query = new URLSearchParams({ team: name, mode, start: mode === 'fixtures' ? today : moveDate(today, -365), end: mode === 'fixtures' ? '9999-12-31' : today, sort: mode === 'fixtures' ? 'asc' : 'desc', filter_mode: 'intersection', page_size: '200', page: '1', time_zone: 'Europe/London' });
      const raw = await json(`matches?${query}`);
      return (Array.isArray(raw) ? raw : raw.matches || []).map(normalizeMatch).filter((match: Match) => mode === 'results' ? isMatchFinished(match) : !isMatchFinished(match));
    };
    const tasks = [
      matches('fixtures').then(data => { result.fixtures = data; }).catch(() => result.errors.push('Upcoming fixtures')).finally(() => publish('Upcoming fixtures')),
      matches('results').then(data => { result.results = data; }).catch(() => result.errors.push('Previous matches')).finally(() => publish('Previous matches')),
      fetchLeagueTables(AbortSignal.timeout(15000)).then(data => { result.tables = data; }).catch(() => result.errors.push('Current season')).finally(() => publish('Current season')),
      (async () => {
        const catalogTask = (async () => { try {
          const catalog = await json(`teams/catalog?${new URLSearchParams({ q: name, limit: '200' })}`);
          const entry = catalog.teams.find((team: { name: string; aliases: string[] }) => [team.name, ...team.aliases].some(alias => teamNameKey(alias) === teamNameKey(name)));
          if (entry) { result.names = [name, entry.name, ...entry.aliases]; result.id ||= entry.source_team_ids?.find((id: string) => /^\d+$/.test(id)); }
        } catch { /* Supplied BSD identifiers still allow squad and manager loading. */ }
        })();
        if (!result.id) await catalogTask;
        if (!result.id || !/^\d+$/.test(result.id)) { result.errors.push('Players and manager'); publish('Players'); publish('Manager'); await catalogTask; return; }
        await Promise.all([
          json(`teams/${result.id}/squad`).then(data => { result.players = data.players || []; }).catch(() => result.errors.push('Players')).finally(() => publish('Players')),
          json(`teams/${result.id}/manager`).then(data => { result.manager = data; }).catch(() => result.errors.push('Manager')).finally(() => publish('Manager')),
        ]);
        await catalogTask;
      })(),
    ];
    await Promise.all(tasks);
    publish();
    return result;
  })();
  cache.set(key, { time: Date.now(), value });
  if (cache.size > 20) { const oldest = cache.keys().next().value!; cache.delete(oldest); snapshots.delete(oldest); }
  return value;
}
