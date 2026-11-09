export interface Team { id: number; name: string; short_name: string }
export interface Fixture { id: number; event: number; team_h: number; team_a: number; team_h_difficulty: number; team_a_difficulty: number; started: boolean; finished: boolean; finished_provisional: boolean; kickoff_time: string; is_home?: boolean; difficulty?: number }
export interface Player {
  id: number; web_name: string; first_name: string; second_name: string; team: number; element_type: number;
  code: number; now_cost: number; form: string; selected_by_percent: string; points_per_game: string; total_points: number;
  minutes: number; starts: number; ep_next: string | null; news: string; status: string; ict_index: string;
  goals_scored: number; assists: number; clean_sheets: number; bonus: number; expected_goals: string; expected_assists: string;
}
export interface SquadPlayer extends Player { pickPosition: number; isCaptain: boolean; isViceCaptain: boolean; stats: Record<string, number>; rawPoints: number; multiplier: number; fixtures: Fixture[]; started: boolean; inPlay: boolean }
export interface League { id: number; name: string; entry_rank: number; entry_last_rank: number }
export interface Profile { id: number; name: string; player_first_name: string; player_last_name: string; summary_overall_points: number; summary_overall_rank: number; leagues: { classic: League[] } }
export interface Event { id: number; name: string; deadline_time: string; data_checked: boolean; average_entry_score: number; highest_score: number }
export interface Squad {
  totalPlayers: number; profile: Profile; event: Event; events: Event[]; teams: Team[]; players: SquadPlayer[];
  substitutions: { incoming: number; outgoing: number; confirmed: boolean }[]; notes: string[];
  nextExpectedPoints: number | null; grossPoints: number; transferCost: number; points: number; finalized: boolean; chip: string | null;
  history: { total_points: number; overall_rank: number; bank: number; value: number; points: number }; updatedAt: string;
}
export interface Standing { id: number; entry: number; entry_name: string; player_name: string; rank: number; last_rank: number; event_total: number; total: number }
export interface LeagueData { league: { id: number; name: string }; standings: { has_next: boolean; page: number; results: Standing[] } }
export interface PlayerData { player: Player; teams: Team[]; alternatives: Player[]; fixtures: Fixture[]; history: { fixture: number; round: number; opponent_team: number; was_home: boolean; total_points: number; minutes: number; goals_scored: number; assists: number; bonus: number }[] }
export interface Preferences { manager: number | null; rivals: number[]; leagues: { id: number; name: string }[] }
const key = 'top-scores.web.fpl.v1';
export function parseFplID(raw: string, kind: 'entry' | 'league' = 'entry'): number | null {
  const text = raw.trim();
  if (/^\d{1,9}$/.test(text) && Number(text) > 0) return Number(text);
  try {
    const url = new URL(text);
    if (url.hostname !== 'fantasy.premierleague.com' || url.protocol !== 'https:') return null;
    const match = (kind === 'entry' ? /^\/entry\/(\d+)\// : /^\/leagues\/(\d+)\//).exec(url.pathname);
    return match && /^\d{1,9}$/.test(match[1]) && Number(match[1]) > 0 ? Number(match[1]) : null;
  } catch { return null; }
}
export function readPreferences(): Preferences {
  try {
    const value = JSON.parse(localStorage.getItem(key) || '{}');
    const valid = (id: unknown): id is number => typeof id === 'number' && Number.isSafeInteger(id) && id > 0 && id < 1e9;
    return { manager: valid(value.manager) ? value.manager : null,
      rivals: Array.isArray(value.rivals) ? [...new Set<number>(value.rivals.filter(valid))].slice(0, 100) : [],
      leagues: Array.isArray(value.leagues) ? value.leagues.filter((l: { id: number; name: string }) => l && valid(l.id) && typeof l.name === 'string').slice(0, 100) : [] };
  } catch { return { manager: null, rivals: [], leagues: [] }; }
}
export function savePreferences(value: Preferences): boolean {
  try { localStorage.setItem(key, JSON.stringify(value)); return true; } catch { return false; }
}
export async function fetchFantasy<T>(path: string, signal?: AbortSignal): Promise<T> {
  const response = await fetch(path, { signal });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'FPL is temporarily unavailable.');
  return data;
}
export const money = (value: number) => `£${(value / 10).toFixed(1)}m`;
export const teamName = (teams: Team[], id: number, short = false) => { const team = teams.find(t => t.id === id); return (short ? team?.short_name : team?.name) || 'Unknown'; };
export const playerImage = (player: Player) => `https://resources.premierleague.com/premierleague/photos/players/110x140/p${player.code}.png`;
export const chipName = (chip: string) => ({ bboost: 'Bench Boost', '3xc': 'Triple Captain', wildcard: 'Wildcard', freehit: 'Free Hit' }[chip] || chip);
