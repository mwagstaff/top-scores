export interface MatchStatRow {
  id: string; label: string; group: string; headline: boolean;
  home: number | null; away: number | null;
  home_display: string; away_display: string;
  home_estimated: boolean; away_estimated: boolean;
}
export interface MatchStatsPeriod { id: string; label: string; rows: MatchStatRow[] }
export interface MatchStats {
  status: string; periods: MatchStatsPeriod[]; updated_at: string | null; refresh_after_seconds: number | null;
}
export function normalizeMatchStats(value: unknown): MatchStats | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as MatchStats;
  if (!["available", "pending", "unavailable"].includes(raw.status) || !Array.isArray(raw.periods)) return null;
  const validNumber = (n: unknown) => n === null || (typeof n === "number" && Number.isFinite(n));
  const ids = new Set<string>();
  const periods = raw.periods.filter(p => p && ["all", "first_half", "second_half"].includes(p.id) &&
    typeof p.label === "string" && Array.isArray(p.rows)).map(p => {
      const rows = new Set<string>();
      return { ...p, rows: p.rows.filter(r => r && typeof r.id === "string" && !rows.has(r.id) &&
        typeof r.label === "string" && typeof r.group === "string" && typeof r.headline === "boolean" &&
        validNumber(r.home) && validNumber(r.away) && (r.home != null || r.away != null) &&
        typeof r.home_display === "string" && typeof r.away_display === "string" && !!rows.add(r.id)) };
    }).filter(p => p.rows.length && !ids.has(p.id) && !!ids.add(p.id));
  return { status: raw.status, periods,
    updated_at: typeof raw.updated_at === "string" ? raw.updated_at : null,
    refresh_after_seconds: typeof raw.refresh_after_seconds === "number" && Number.isFinite(raw.refresh_after_seconds) && raw.refresh_after_seconds > 0 ? raw.refresh_after_seconds : null };
}
export function statShare(row: MatchStatRow): number | null {
  if (row.home == null || row.away == null || row.home < 0 || row.away < 0 || row.home + row.away <= 0) return null;
  return row.home / (row.home + row.away) * 100;
}
export function summaryStats(stats?: MatchStats | null): MatchStatRow[] {
  return (stats?.periods.find(p => p.id === "all")?.rows ?? [])
    .filter(r => ["ball_possession", "xg", "shots_on_target"].includes(r.id));
}
