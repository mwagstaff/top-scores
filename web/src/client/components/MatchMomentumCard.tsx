import { useEffect, useRef, useState } from "react";
import { annotationLanes, momentumPath, momentumSymbol, momentumColors, type MatchMomentum, type MomentumAnnotation } from "../momentum";
import { useTeamColorCatalog } from "../teamColors";

export function MatchMomentumCard({ momentum, homeTeam, awayTeam, isLive }: {
  momentum: MatchMomentum; homeTeam: string; awayTeam: string; isLive: boolean;
}) {
  const catalog = useTeamColorCatalog();
  const plot = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(280);
  const [selected, setSelected] = useState<string | null>(null);
  useEffect(() => {
    if (!plot.current) return;
    const observer = new ResizeObserver(entries => setWidth(entries[0].contentRect.width));
    observer.observe(plot.current);
    return () => observer.disconnect();
  }, [momentum.status]);
  if (momentum.status !== "available" || !momentum.segments.length) return null;
  const colors = momentumColors(catalog.lineupColors(homeTeam, awayTeam, "home"), catalog.lineupColors(awayTeam, homeTeam, "away"));
  const names = { home: homeTeam, away: awayTeam };
  const active = momentum.annotations.find(a => a.id === selected);
  const description = (a: MomentumAnnotation) => `${a.time} ${names[a.side]} · ${a.label}`;
  const markerRow = (side: "home" | "away") => {
    const markers = annotationLanes(momentum.annotations, side, width, momentum.end_minute);
    const lanes = Math.max(0, ...markers.map(m => m.lane + 1));
    return <div className="momentum-markers" style={{ height: lanes * 44 }}>
      {markers.map(({ annotation: a, x, lane }) => <button key={a.id} type="button"
        className={`momentum-marker momentum-marker-${a.kind}`} style={{ left: x, top: lane * 44 }}
        aria-label={description(a)} aria-pressed={a.id === selected} title={description(a)}
        onClick={() => setSelected(a.id === selected ? null : a.id)}
        onKeyDown={e => { if (e.key === "Escape") setSelected(null); }}>
        <span aria-hidden="true">{momentumSymbol(a.kind)}</span>
      </button>)}
    </div>;
  };
  return <section className="momentum-card" aria-label="Match momentum">
    <div className="momentum-heading"><h3>Momentum</h3><span>Relative pressure</span></div>
    <div className="momentum-teams">
      {(["home", "away"] as const).map(side => <span key={side}>
        <i aria-hidden="true" style={{ background: colors[side].background, borderColor: colors[side].foreground }} />
        {names[side]} <small>{side === "home" ? "↑" : "↓"}</small>
      </span>)}
    </div>
    <div className="momentum-plot" ref={plot}>
      {markerRow("home")}
      <svg viewBox="0 0 1000 140" preserveAspectRatio="none" role="img"
        aria-label={`Relative pressure over the match. ${homeTeam} above the centre line; ${awayTeam} below. Gaps indicate missing data.`}>
        {momentum.ticks.slice(1, -1).map(t => <line key={t.minute} x1={t.minute / momentum.end_minute * 1000} x2={t.minute / momentum.end_minute * 1000} y1="0" y2="140" className="momentum-divider" />)}
        {momentum.segments.map(s => <path key={s.id} d={momentumPath(s, momentum.end_minute, momentum.scale)}
          fill={colors[s.side].background} stroke={colors[s.side].foreground} strokeWidth="0.65" vectorEffect="non-scaling-stroke" />)}
        <line x1="0" x2="1000" y1="70" y2="70" className="momentum-baseline" />
      </svg>
      {markerRow("away")}
      <div className="momentum-axis">{momentum.ticks.map(t => <span key={t.minute}
        style={{ left: `${t.minute / momentum.end_minute * 100}%` }}>{t.label}</span>)}</div>
    </div>
    {active ? <div className="momentum-event" role="status">{description(active)}
      <button type="button" onClick={() => setSelected(null)} aria-label="Close event details">×</button>
    </div> : <p className="momentum-note">{momentum.annotations.length ? "Select an event marker for details. " : ""}Above: home · Below: away</p>}
    {isLive && momentum.updated_at && <p className="momentum-note">Updated {new Date(momentum.updated_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</p>}
  </section>;
}
