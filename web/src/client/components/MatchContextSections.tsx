import { Link } from "react-router-dom";
import { useState } from "react";
import type { MatchContext } from "../matchContext";

export function MatchPreview({ context, prematch }: { context?: MatchContext | null; prematch: boolean }) {
  const [expanded, setExpanded] = useState(false);
  if (!prematch || !context?.match_preview) return null;
  const preview = context.match_preview.text;
  const intro = preview.split(/\n\s*\n/)[0];
  const canExpand = intro.length < preview.length;
  return <section className="details-section match-preview-section">
    <div className="details-section-title">Match preview</div>
    <div className="match-context-attribution">✦ AI-generated</div>
    <p>{expanded || !canExpand ? preview : intro}</p>
    {canExpand && <button className="match-preview-toggle" type="button" aria-expanded={expanded} onClick={() => setExpanded(value => !value)}>{expanded ? "Show less" : "Read full preview"}</button>}
  </section>;
}

export function LineupStatusBadge({ status }: { status?: MatchContext["lineup_status"] }) {
  if (status !== "predicted" && status !== "confirmed") return null;
  return <span className={`lineup-status-badge is-${status}`} role="status">
    <span aria-hidden="true">{status === "predicted" ? "✦" : "✓"}</span> {status === "predicted" ? "AI predicted" : "Confirmed"}
  </span>;
}

export function HeadToHead({ context, homeTeam, awayTeam }: {
  context?: MatchContext | null; homeTeam: string; awayTeam: string;
}) {
  const data = context?.head_to_head;
  if (!data) return null;
  return <section className="details-section match-h2h-section">
    <div className="details-section-title">Head-to-head</div>
    {data.total_matches === 0 ? <p className="match-context-note">No meetings available.</p> : <>
      <p className="match-context-note">{data.total_matches} recorded {data.total_matches === 1 ? "meeting" : "meetings"}</p>
      <div className="match-h2h-summary">
        <div><strong>{data.home_wins ?? "–"}</strong><span>{homeTeam} wins</span></div>
        <div><strong>{data.draws ?? "–"}</strong><span>Draws</span></div>
        <div><strong>{data.away_wins ?? "–"}</strong><span>{awayTeam} wins</span></div>
      </div>
      {data.recent_matches.length > 0 && <>
        <h3 className="match-context-subtitle">Latest {data.recent_matches.length} {data.recent_matches.length === 1 ? "meeting" : "meetings"}</h3>
        <ol className="match-h2h-list">{data.recent_matches.map((row, index) => {
          const content = <><time dateTime={row.date}>{new Date(row.date).toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" })}</time>
            <span className="match-h2h-home">{row.home_team}</span><strong>{row.home_score === null || row.away_score === null ? "–" : `${row.home_score}–${row.away_score}`}</strong><span>{row.away_team}</span></>;
          return <li key={row.event_id || `${row.date}-${index}`}>
            {row.match_id ? <Link className="match-h2h-row" to={`/matches/${row.match_id}`}>{content}<span className="match-h2h-chevron" aria-hidden="true">›</span></Link> : <div className="match-h2h-row">{content}</div>}
          </li>;
        })}</ol>
      </>}
    </>}
  </section>;
}

export function FunFacts({ context }: { context?: MatchContext | null }) {
  if (!context?.fun_facts.length) return null;
  return <section className="details-section match-fun-facts">
    <div className="details-section-title">Fun facts</div>
    <ul>{context.fun_facts.map(fact => <li key={fact}>{fact}</li>)}</ul>
  </section>;
}
