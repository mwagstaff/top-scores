export interface HeadToHeadMeeting {
  event_id: string | null;
  match_id: string | null;
  date: string;
  home_team: string;
  away_team: string;
  home_team_id: string | null;
  away_team_id: string | null;
  home_score: number | null;
  away_score: number | null;
}

export interface MatchContext {
  kickoff_at: string | null;
  is_upcoming: boolean;
  lineup_status: "predicted" | "confirmed" | "unavailable";
  lineup_updated_at: string | null;
  head_to_head: {
    total_matches: number;
    home_wins: number | null;
    draws: number | null;
    away_wins: number | null;
    recent_matches: HeadToHeadMeeting[];
  } | null;
  match_preview: { text: string; generated_at: string | null } | null;
  fun_facts: string[];
  refresh_after_seconds: number | null;
}

const record = (v: unknown): Record<string, unknown> => v && typeof v === "object" ? v as Record<string, unknown> : {};
const text = (v: unknown): string => typeof v === "string" ? v.trim() : "";
const count = (v: unknown): number | null => typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : null;
const id = (v: unknown): string | null => /^[1-9]\d*$/.test(String(v ?? "")) ? String(v) : null;

export function normalizeMatchContext(value: unknown): MatchContext | null {
  if (!value || typeof value !== "object") return null;
  const raw = record(value), h2h = record(raw.head_to_head), preview = record(raw.match_preview);
  return {
    kickoff_at: text(raw.kickoff_at) || null,
    is_upcoming: raw.is_upcoming === true,
    lineup_status: raw.lineup_status === "predicted" || raw.lineup_status === "confirmed" ? raw.lineup_status : "unavailable",
    lineup_updated_at: text(raw.lineup_updated_at) || null,
    head_to_head: count(h2h.total_matches) === null ? null : {
      total_matches: count(h2h.total_matches)!, home_wins: count(h2h.home_wins),
      draws: count(h2h.draws), away_wins: count(h2h.away_wins),
      recent_matches: (Array.isArray(h2h.recent_matches) ? h2h.recent_matches : []).map(record)
        .filter(row => text(row.home_team) && text(row.away_team) && Number.isFinite(Date.parse(text(row.date))))
        .slice(0, 10).map(row => ({
          event_id: id(row.event_id), match_id: id(row.match_id), date: text(row.date),
          home_team: text(row.home_team), away_team: text(row.away_team),
          home_team_id: id(row.home_team_id), away_team_id: id(row.away_team_id),
          home_score: count(row.home_score), away_score: count(row.away_score),
        })),
    },
    match_preview: text(preview.text) ? { text: text(preview.text), generated_at: text(preview.generated_at) || null } : null,
    fun_facts: [...new Set((Array.isArray(raw.fun_facts) ? raw.fun_facts : []).map(text).filter(Boolean))],
    refresh_after_seconds: count(raw.refresh_after_seconds) && Math.max(15, Math.min(3600, count(raw.refresh_after_seconds)!)),
  };
}

export function isContextPrematch(context: MatchContext | null | undefined, now = Date.now()): boolean {
  return context?.is_upcoming === true && Date.parse(context.kickoff_at || "") > now;
}
