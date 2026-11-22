type Side = "home" | "no_goal" | "away";
export type NextGoal = {
  status: "available" | "updating" | "warming_up" | "settled";
  message: string | null;
  score: { home: number; away: number } | null;
  shares: { side: Side; value: number }[];
  minute: number | null;
  shots: string | null;
  expiresAt: number | null;
  calls: string[];
  refresh_after_seconds: number | null;
};

const object = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" ? value as Record<string, unknown> : {};
const count = (value: unknown): value is number => typeof value === "number" && Number.isInteger(value) && value >= 0;

export function normalizeNextGoal(value: unknown): NextGoal | null {
  const raw = object(value);
  const { status } = raw;
  if (status !== "available" && status !== "updating" && status !== "warming_up" && status !== "settled") return null;
  const shares: NextGoal["shares"] = [];
  if (status === "available" || status === "updating") {
    const p = object(raw.probabilities);
    for (const side of ["home", "no_goal", "away"] as const) {
      const n = p[side];
      if (side === "no_goal" && n === null) continue;
      if (typeof n !== "number" || !Number.isFinite(n) || n < 0 || n > 1) return null;
      shares.push({ side, value: n });
    }
    const total = shares.reduce((sum, s) => sum + s.value, 0);
    if (!total || (shares.length === 3 && Math.abs(total - 1) > 0.01)) return null;
    shares.forEach(s => { s.value /= total; });
  }
  const calls = status === "settled" && Array.isArray(raw.calls) ? raw.calls.map(c => object(c).summary).filter((s): s is string => typeof s === "string" && !!s) : [];
  if (status === "settled" && !calls.length) return null;
  const { shots_home_10m: home, shots_away_10m: away } = object(raw.evidence);
  const seen = typeof raw.last_seen_at === "string" ? Date.parse(raw.last_seen_at) : NaN;
  const score = object(raw.score);
  return { status, score: count(score.home) && count(score.away) ? { home: score.home, away: score.away } : null,
    expiresAt: status === "available" && Number.isFinite(seen) ? seen + 180_000 : null,
    message: typeof raw.message === "string" ? raw.message : null, calls, shares,
    minute: count(raw.minute) ? raw.minute : null, shots: count(home) && count(away) ? `Shots, last 10′: ${home}–${away}` : null,
    refresh_after_seconds: count(raw.refresh_after_seconds) && raw.refresh_after_seconds > 0 ? raw.refresh_after_seconds : null };
}
