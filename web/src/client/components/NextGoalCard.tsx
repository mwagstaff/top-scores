import { useEffect, useState } from "react";
import { momentumColors } from "../momentum";
import type { NextGoal } from "../nextGoal";
import { useTeamColorCatalog } from "../teamColors";

export function NextGoalCard({ goal, homeTeam, awayTeam, homeScore, awayScore }: {
  goal: NextGoal; homeTeam: string; awayTeam: string; homeScore?: number | null; awayScore?: number | null;
}) {
  const catalog = useTeamColorCatalog();
  const colors = momentumColors(catalog.lineupColors(homeTeam, awayTeam, "home"), catalog.lineupColors(awayTeam, homeTeam, "away"));
  const labels = { home: homeTeam, no_goal: "No further goal", away: awayTeam };
  const fills = { home: colors.home.background, no_goal: "#91a3b8", away: colors.away.background };
  const leader = Math.max(...goal.shares.map(s => s.value));
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (goal.expiresAt == null) return;
    const timer = window.setTimeout(() => setNow(Date.now()), Math.max(0, goal.expiresAt - Date.now() + 1));
    return () => window.clearTimeout(timer);
  }, [goal.expiresAt]);
  const expired = goal.expiresAt != null && Math.max(now, Date.now()) >= goal.expiresAt;
  const changedScore = goal.shares.length > 0 && goal.score && homeScore != null && awayScore != null &&
    (goal.score.home !== homeScore || goal.score.away !== awayScore);
  const updating = goal.status === "updating" || expired || Boolean(changedScore);
  const message = changedScore ? "Updating after goal…" : expired ? "Updating…" : goal.message;
  return <section className="match-analysis-card next-goal" aria-label="Next goal">
    <div className="momentum-heading"><h3>Next goal</h3>{goal.status !== "warming_up" && message && <span>{message}</span>}</div>
    {goal.status === "warming_up" && <p className="momentum-note">{goal.message}</p>}
    {goal.shares.length > 0 && <>
      <div className="next-goal-bar" aria-hidden="true" data-updating={updating}>
        {goal.shares.map(s => <i key={s.side} style={{ width: `${s.value * 100}%`, background: fills[s.side] }} />)}
      </div>
      <div className="next-goal-labels" role="img" aria-label={`Next-goal chances: ${goal.shares.map(s => `${labels[s.side]} ${Math.round(s.value * 100)}%`).join(", ")}.`}>
        {goal.shares.map(s => <div key={s.side} aria-hidden="true" style={{ fontWeight: leader === s.value ? 700 : 400 }}>
          <span>{labels[s.side]}</span><span>{Math.round(s.value * 100)}%</span>
        </div>)}
      </div>
      {updating && goal.minute != null ? <p className="momentum-note">Last estimate · {goal.minute}′</p> : goal.shots && <p className="momentum-note">{goal.shots}</p>}
    </>}
    {goal.calls.map((call, i) => <p key={i}>{call}</p>)}
  </section>;
}
