import { useState } from "react";
import { MatchMomentumCard } from "./MatchMomentumCard";
import { momentumColors, type MatchMomentum } from "../momentum";
import { statShare, summaryStats, type MatchStats, type MatchStatRow } from "../matchStats";
import { useTeamColorCatalog } from "../teamColors";

export function MatchAnalysisCard({ momentum, stats, homeTeam, awayTeam, isLive, refreshFailed = false }: {
  momentum?: MatchMomentum | null; stats?: MatchStats | null;
  homeTeam: string; awayTeam: string; isLive: boolean; refreshFailed?: boolean;
}) {
  const [view, setView] = useState("momentum");
  const [periodID, setPeriodID] = useState("all");
  const [expanded, setExpanded] = useState(false);
  const catalog = useTeamColorCatalog();
  const colors = momentumColors(catalog.lineupColors(homeTeam, awayTeam, "home"), catalog.lineupColors(awayTeam, homeTeam, "away"));
  const hasMomentum = momentum?.status === "available" && !!momentum.segments.length;
  const showingStats = view === "stats" || !hasMomentum;
  const period = stats?.periods.find(p => p.id === periodID) ?? stats?.periods[0];
  const summary = summaryStats(stats);
  const hasExtra = period?.rows.some(r => !r.headline) && period.rows.some(r => r.headline);
  const rows = period?.rows.filter(r => expanded || r.headline) ?? [];
  // Thin coverage can contain only secondary counters; don't hide useful data.
  const visibleRows = rows.length ? rows : period?.rows ?? [];
  const updated = Date.parse(stats?.updated_at ?? "");
  const stale = isLive && Number.isFinite(updated) && Date.now() - updated > 180_000;
  if (!hasMomentum && !stats) return null;

  const row = (r: MatchStatRow, bars = true) => {
    const share = statShare(r);
    const display = (side: "home" | "away") => `${r[`${side}_display`]}${r[`${side}_estimated`] ? " est." : ""}`;
    const spoken = (side: "home" | "away") => r[side] == null ? "not available" : `${r[`${side}_display`]}${r[`${side}_estimated`] ? " estimated" : ""}`;
    return <div key={r.id} className="match-stat-row" role="group"
      aria-label={`${r.label}: ${homeTeam} ${spoken("home")}, ${awayTeam} ${spoken("away")}`}>
      <div className="match-stat-values" aria-hidden="true"><strong>{display("home")}</strong><span>{r.label}</span><strong>{display("away")}</strong></div>
      {bars && <div className="match-stat-bar" aria-hidden="true">{share != null && <>
        <i style={{ width: `${share}%`, background: colors.home.background }} />
        <i style={{ width: `${100 - share}%`, background: colors.away.background }} />
      </>}</div>}
    </div>;
  };
  return <section className="match-analysis-card" aria-label="Match analysis">
    {hasMomentum && stats ? <div className="match-feed-picker" role="group" aria-label="Match analysis view">
      <button type="button" aria-pressed={!showingStats} onClick={() => setView("momentum")}>Momentum</button>
      <button type="button" aria-pressed={showingStats} onClick={() => setView("stats")}>Match stats</button>
    </div> : showingStats ? <h3>Match stats</h3> : null}
    {!showingStats && momentum ? <>
      <MatchMomentumCard momentum={momentum} homeTeam={homeTeam} awayTeam={awayTeam} isLive={isLive && !stats} embedded hideHeading={!!stats} />
      {summary.length > 0 && <div className="match-stats-summary">{summary.map(r => row(r, false))}
        <button className="match-stats-more" type="button" onClick={() => setView("stats")}>View match stats →</button>
      </div>}
    </> : <>
      {(stats?.periods.length ?? 0) > 1 && <div className="match-feed-picker match-stats-periods" role="group" aria-label="Statistics period">
        {stats!.periods.map(p => <button key={p.id} type="button" aria-pressed={period?.id === p.id} onClick={() => setPeriodID(p.id)}>{p.label}</button>)}
      </div>}
      {stats?.periods.length === 1 && period?.id !== "all" && <p className="momentum-note">{period?.label}</p>}
      {period ? <>
        <div className="momentum-teams"><span><i aria-hidden="true" style={{ background: colors.home.background }} />{homeTeam}</span><span>{awayTeam}<i aria-hidden="true" style={{ background: colors.away.background }} /></span></div>
        {visibleRows.map((r, i) => <div key={r.id}>
          {expanded && !r.headline && visibleRows[i - 1]?.group !== r.group && <h4 className="match-stats-group">{r.group}</h4>}
          {row(r)}
        </div>)}
        {hasExtra && <button type="button" className="match-stats-more" aria-expanded={expanded} onClick={() => setExpanded(!expanded)}>{expanded ? "Show key stats" : "Show all stats"} {expanded ? "⌃" : "⌄"}</button>}
        {period.rows.some(r => r.home == null || r.away == null) && <p className="momentum-note">— Not available</p>}
      </> : <p className="momentum-note">{stats?.status === "pending" ? "Waiting for match stats." : "Match stats aren’t available for this match."}</p>}
    </>}
    {(showingStats ? period?.rows : summary)?.some(r => r.home_estimated || r.away_estimated) && <p className="momentum-note">est. = estimated xG</p>}
    {stats?.periods.length && (refreshFailed || stale || (isLive && Number.isFinite(updated))) ? <p className="momentum-note" role={refreshFailed || stale ? "status" : undefined}>
      {refreshFailed || stale ? "Showing the last available stats. " : ""}
      {isLive && Number.isFinite(updated) ? `Updated ${new Date(updated).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}` : ""}
    </p> : null}
  </section>;
}
