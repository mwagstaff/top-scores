import { compareCompetitions } from "../competitionOrdering";
import "../styles.css";
import "../tableScores.css";
import { competitionLogo } from "../competitionLogos";
import { useEffect, useMemo, useReducer, useState, useRef } from "react";
import { loadCompetitions, type Competition } from "../catalog";
import { teamPath } from "../catalog";
import { Link, useSearchParams } from "react-router-dom";
import { fetchLeagueTables } from "../api";
import type { LeagueTable, LeagueTableRow, LeagueTableZone } from "../types";
import { fetchTableMatches, tableScoresByTeam, type TableScore } from "../tableScores";
import { matchPath, localDate } from "../football";
import { teamIdentityKeys, useTeamColorCatalog } from "../teamColors";
import type { Match } from "../types";
import { PageMeta } from "./PageMeta";
import { saveMatchViewPreferences, useMatchViewPreferences } from "../matchViewPreferences";
import { StadiumBackdrop } from "./StadiumBackdrop";

interface TablesState {
  loading: boolean;
  refreshing: boolean;
  error: string | null;
  leagues: LeagueTable[];
  lastUpdated: string | null;
}

const initialState: TablesState = {
  loading: true,
  refreshing: false,
  error: null,
  leagues: [],
  lastUpdated: null,
};

export function TablesScreen({ competition }: { competition?: string }) {
  useTeamColorCatalog();
  const [scoreMatches, setScoreMatches] = useState<{ leagueID: string; matches: Match[] } | null>(null);
  const [scoresError, setScoresError] = useState<string | null>(null);
  const [catalog, setCatalog] = useState<Competition[]>([]);
  useEffect(() => { let active = true; loadCompetitions().then(items => { if (active) setCatalog(items); }).catch(() => {}); return () => { active = false; }; }, []);
  const carousel = useRef<HTMLElement>(null);
  const [state, setState] = useState<TablesState>(initialState);
  const [reloadToken, reload] = useReducer((value) => value + 1, 0);
  const [searchParams, setSearchParams] = useSearchParams();
  const [highlightedRowId, setHighlightedRowId] = useState<string | null>(null);
  const { showStats } = useMatchViewPreferences();
  const [carouselEdges, setCarouselEdges] = useState({ start: true, end: true });

  useEffect(() => {
    const controller = new AbortController();

    const load = async (manual = false) => {
      setState((current) => ({
        ...current,
        loading: current.leagues.length === 0,
        refreshing: manual || current.leagues.length > 0,
        error: null,
      }));

      try {
        const payload = await fetchLeagueTables(controller.signal);
        if (controller.signal.aborted) {
          return;
        }

        setState({
          loading: false,
          refreshing: false,
          error: null,
          leagues: payload.leagues,
          lastUpdated: payload.lastUpdated,
        });
      } catch (error) {
        if (controller.signal.aborted) {
          return;
        }

        setState((current) => ({
          ...current,
          loading: false,
          refreshing: false,
          error: error instanceof Error ? error.message : "Unable to load tables.",
        }));
      }
    };

    void load(reloadToken > 0);

    return () => {
      controller.abort();
    };
  }, [reloadToken]);

  // While the Tables tab is open, refresh on a live cadence so in-progress
  // scores flow into the standings within ~30s. The endpoint is cached
  // server-side (stale-while-revalidate), so this stays cheap.
  useEffect(() => {
    const id = window.setInterval(() => { if (document.visibilityState === "visible") reload(); }, 30_000);
    return () => window.clearInterval(id);
  }, []);

  // Deep link from MatchTeamLeaguePositionsLink (?league=&team=): select the
  // league, scroll to + briefly highlight the team's row, keeping the league URL.
  useEffect(() => {
    const leagueID = searchParams.get("league");
    const teamName = searchParams.get("team");
    if (!leagueID || !teamName || state.leagues.length === 0) {
      return;
    }

    const league = state.leagues.find((candidate) => candidate.leagueID === leagueID);
    setSearchParams((current) => {
      const next = new URLSearchParams(current);
      next.delete("team");
      return next;
    }, { replace: true });
    if (!league) return;

    const allRows = league.rows.length > 0 ? league.rows : league.groups.flatMap((group) => group.rows);
    const row = allRows.find(
      (candidate) => candidate.team.localeCompare(teamName, undefined, { sensitivity: "base" }) === 0
    );

    if (row) {
      window.setTimeout(() => {
        document.getElementById(`table-row-${row.id}`)?.scrollIntoView({ behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth", block: "center" });
        setHighlightedRowId(row.id);
        window.setTimeout(() => setHighlightedRowId((current) => (current === row.id ? null : current)), 2500);
      }, 200);
    }
  }, [searchParams, state.leagues, setSearchParams]);

  const sortedLeagues = useMemo(
    () =>
      [...state.leagues].sort((left, right) =>
        compareCompetitions(orderEntry(left, catalog), orderEntry(right, catalog))
      ),
    [state.leagues, catalog]
  );

  const selectedLeagueID = resolveLeagueID(sortedLeagues, searchParams.get("league") || "premier-league");
  const selectedLeague =
    (competition ? sortedLeagues.find(league => league.leagueName.toLowerCase() === competition.toLowerCase()) : sortedLeagues.find((league) => league.leagueID === selectedLeagueID) || sortedLeagues[0]) || null;
  useEffect(() => {
    const rail = carousel.current;
    const selected = rail?.querySelector<HTMLElement>('[aria-pressed="true"]');
    if (rail && selected) rail.scrollLeft += selected.getBoundingClientRect().left - rail.getBoundingClientRect().left - (rail.clientWidth - selected.clientWidth) / 2;
  }, [selectedLeague?.leagueID, catalog]);

  useEffect(() => {
    const rail = carousel.current;
    if (!rail) return;
    const updateEdges = () => {
      const start = rail.scrollLeft <= 1;
      const end = rail.scrollLeft + rail.clientWidth >= rail.scrollWidth - 1;
      setCarouselEdges(current => current.start === start && current.end === end ? current : { start, end });
    };
    updateEdges();
    rail.addEventListener("scroll", updateEdges, { passive: true });
    const observer = new ResizeObserver(updateEdges);
    observer.observe(rail);
    return () => {
      rail.removeEventListener("scroll", updateEdges);
      observer.disconnect();
    };
  }, [sortedLeagues.length, selectedLeague?.leagueID, catalog]);

  const scoreDate = localDate();
  const scoreLeagueID = selectedLeague?.leagueID;
  const scoreLeagueName = selectedLeague?.leagueName;
  const scoreLeagueNames = JSON.stringify([...new Set([scoreLeagueName, ...(catalog.find(item => item.id === scoreLeagueID || item.name === scoreLeagueName || item.aliases.includes(scoreLeagueName || ""))?.aliases || [])].filter((name): name is string => Boolean(name)))]);
  useEffect(() => {
    if (!scoreLeagueID) return;
    const controller = new AbortController();
    setScoresError(null);
    void fetchTableMatches(JSON.parse(scoreLeagueNames), scoreDate, controller.signal)
      .then(matches => {
        if (!controller.signal.aborted) setScoreMatches({ leagueID: scoreLeagueID, matches });
      })
      .catch(() => {
        if (!controller.signal.aborted) {
          setScoreMatches(null);
          setScoresError('Today’s scores are unavailable.');
        }
      });
    return () => controller.abort();
  }, [scoreLeagueID, scoreLeagueNames, scoreDate, reloadToken]);
  const scores = tableScoresByTeam(scoreMatches && scoreMatches.leagueID === scoreLeagueID ? scoreMatches.matches : [], scoreDate);

  const scrollCompetitions = (direction: number) => {
    const rail = carousel.current;
    rail?.scrollBy({
      left: direction * Math.max(140, rail.clientWidth * 0.8),
      behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth",
    });
  };

  return (
    <section className="screen-panel tables-screen">
      <StadiumBackdrop ready={Boolean(selectedLeague)} homes={selectedLeague ? [...selectedLeague.rows, ...selectedLeague.groups.flatMap(group => group.rows)].map(row => ({ name: row.team })) : undefined} />
      {!competition && <PageMeta title="League tables" description="Football standings and live positions. Follow the title race and relegation battle with Top Scores." />}
      {!competition && <header className="screen-header"><div><span className="eyebrow">Every point matters</span><h1>League tables</h1></div></header>}
      {state.error && <div className="refresh-notice" role="status">{state.error} <button onClick={() => reload()}>Try again</button></div>}
      {state.loading ? (
        <div className="empty-state tables-loading" role="status">Loading tables...</div>
      ) : sortedLeagues.length === 0 ? (
        <div className="empty-state">
          <strong>No tables to show.</strong>
          <div>League tables will appear here once available.</div>
        </div>
      ) : (
        <div className="tables-stack">
          {!competition && <div className="table-competition-navigator">
            <button type="button" className="table-carousel-arrow" aria-label="Previous competitions" aria-controls="table-competitions" disabled={carouselEdges.start} onClick={() => scrollCompetitions(-1)}>←</button>
            <nav id="table-competitions" ref={carousel} className="table-competition-carousel" aria-label="Choose a competition">
            {sortedLeagues.map(league => <button type="button" key={league.leagueID} aria-pressed={selectedLeague?.leagueID === league.leagueID} onClick={() => setSearchParams(current => {
              const next = new URLSearchParams(current);
              next.set("league", league.leagueID);
              next.delete("team");
              return next;
            }, { preventScrollReset: true })}>
              {competitionLogo(league.leagueID, league.leagueName) && <img src={competitionLogo(league.leagueID, league.leagueName)} width="40" height="40" alt="" loading="lazy" />}
              <span>{league.leagueName}</span>
            </button>)}
            </nav>
            <button type="button" className="table-carousel-arrow" aria-label="Next competitions" aria-controls="table-competitions" disabled={carouselEdges.end} onClick={() => scrollCompetitions(1)}>→</button>
          </div>}

          {selectedLeague ? (
            <>
              <LeagueTableHero league={selectedLeague} showStats={showStats} onShowStatsChange={value => saveMatchViewPreferences({ showStats: value })} />
              {leagueHasLiveRows(selectedLeague) ? (
                <div className="tables-live-note">
                  <span className="tables-live-dot" aria-hidden="true" />
                  Live in-play standings. Provisional, subject to change.
                </div>
              ) : null}
              {scoresError && <div className="refresh-notice" role="status">{scoresError} <button onClick={() => reload()}>Try again</button></div>}
              <LeagueTableCard league={selectedLeague} highlightedRowId={highlightedRowId} showStats={showStats} scores={scores} />
              {state.lastUpdated ? (
                <div className="tables-updated">Updated {formatLastUpdated(state.lastUpdated)}</div>
              ) : null}
            </>
          ) : <div className="football-empty">Standings aren’t available for this competition.</div>}
        </div>
      )}
    </section>
  );
}

function LeagueTableHero({ league, showStats, onShowStatsChange }: { league: LeagueTable; showStats: boolean; onShowStatsChange: (value: boolean) => void }) {
  const visibleStageName = normalizeStageName(league.stageName);
  const logo = competitionLogo(league.leagueID, league.leagueName);

  return (
    <section className="league-hero">
      <div className={`league-hero-mark${logo?.includes("FantasyPremierLeagueLion") ? " light-crest" : ""}`}>
        {logo ? <img src={logo} alt={`${league.leagueName} crest`} width="48" height="48" /> : <span aria-hidden="true">{league.leagueName.split(" ").map(word => word[0]).slice(0, 3).join("")}</span>}
      </div>
      <div className="league-hero-title">
        <h2>{league.leagueName}</h2>
        {visibleStageName ? <p>{visibleStageName}</p> : null}
      </div>
      <label className="tables-stats-toggle">
        <input type="checkbox" role="switch" checked={showStats} onChange={event => onShowStatsChange(event.target.checked)} />
        <span>Show stats</span>
      </label>
    </section>
  );
}

function leagueHasLiveRows(league: LeagueTable | null): boolean {
  if (!league) return false;
  if (league.rows.some((row) => row.live)) return true;
  return league.groups.some((group) => group.rows.some((row) => row.live));
}

function PositionTrend({ row }: { row: LeagueTableRow }) {
  const previous = row.previousPosition;
  if (previous == null) return null;
  if (previous > row.position) {
    return <span className="table-trend is-up" aria-label="Up" title="Up">▲</span>;
  }
  if (previous < row.position) {
    return <span className="table-trend is-down" aria-label="Down" title="Down">▼</span>;
  }
  return <span className="table-trend is-same" aria-label="No change" title="No change">–</span>;
}

function LeagueTableCard({
  league,
  highlightedRowId = null,
  showStats,
  scores,
}: {
  league: LeagueTable;
  highlightedRowId?: string | null;
  showStats: boolean;
  scores: Map<string, TableScore>;
}) {
  const [expandedRows, setExpandedRows] = useState<Set<string>>(new Set());
  const visibleStageName = normalizeStageName(league.stageName);
  const logo = competitionLogo(league.leagueID, league.leagueName);
  const groups = league.groups.length > 0
    ? league.groups
    : [{ name: visibleStageName, rows: league.rows }];

  useEffect(() => {
    setExpandedRows(new Set());
  }, [league.id]);

  const toggleRow = (rowID: string) => {
    setExpandedRows((current) => {
      const next = new Set(current);
      if (next.has(rowID)) {
        next.delete(rowID);
      } else {
        next.add(rowID);
      }
      return next;
    });
  };

  return (

      <div className="league-table-scroll" role="region" aria-label={`${league.leagueName} standings${showStats ? ", scroll horizontally for all statistics" : ""}`} tabIndex={showStats ? 0 : undefined}>
      <div className={`league-table${showStats ? " has-stats" : ""}${scores.size ? " has-scores" : ""}`}>
        <div className="league-table-heading">
          <span className="table-cell table-cell-position" aria-hidden="true" />
          <span className="table-cell table-cell-logo" aria-hidden="true" />
          <span className="table-cell table-cell-team">Team</span>
          {scores.size > 0 && <span className="table-cell table-cell-score">Today</span>}
          <span className="table-cell table-cell-played" title="Played">P</span>
          {showStats && <>
            <span className="table-cell table-cell-stat" title="Won">W</span>
            <span className="table-cell table-cell-stat" title="Drawn">D</span>
            <span className="table-cell table-cell-stat" title="Lost">L</span>
            <span className="table-cell table-cell-stat" title="Goals scored">GF</span>
            <span className="table-cell table-cell-stat" title="Goals conceded">GA</span>
          </>}
          <span className="table-cell table-cell-goal-difference" title="Goal difference">GD</span>
          <span className="table-cell table-cell-points" title="Points">Pts</span>
          <span className="table-cell table-cell-chevron" aria-hidden="true" />
        </div>

        <div className="table-divider" />

        {groups.map((group, groupIndex) => (
          <div className="league-table-group" key={`${group.name || "table"}-${groupIndex}`}>
            {group.name ? (
              <div className="league-table-group-title">
                {visibleStageName && !group.name.toLowerCase().includes("phase")
                  ? `${visibleStageName} ${group.name}`
                  : group.name}
              </div>
            ) : null}

            {group.rows.map((row, index) => {
              const score = teamIdentityKeys(row.team).map(key => scores.get(key)).find(Boolean);
              const isExpanded = expandedRows.has(row.id);
              const boundary = isBenefitBoundary(group.rows, index);
              const activeZone = zoneAtPosition(league.zones, row.position);
              const startingZones = league.zones.filter(
                (zone) => zoneUsesLookDownBoundary(zone) && zone.from === row.position,
              );
              const endingZones = league.zones.filter(
                (zone) => !zoneUsesLookDownBoundary(zone) && zone.to === row.position,
              );
              const nextRow = group.rows[index + 1];
              const nextStartsLookDownZone = nextRow
                ? league.zones.some(
                    (zone) => zoneUsesLookDownBoundary(zone) && zone.from === nextRow.position,
                  )
                : false;

              return (
                <div className="league-table-row-wrap" key={`${groupIndex}-${row.id}`}>
                  {startingZones.map((zone) => (
                    <TableZoneBoundary zone={zone} key={zoneBoundaryKey(zone)} />
                  ))}

                  <div
                    id={`table-row-${row.id}`}
                    className={`league-table-row${row.live ? " is-live" : ""}${row.id === highlightedRowId ? " is-highlighted" : ""}`}
                  >
                    <span className="table-cell table-cell-position">
                      {league.zones.length > 0 ? (
                        <span
                          className={`table-zone-rail ${zoneClassName(activeZone)}`}
                          aria-hidden="true"
                        />
                      ) : null}
                      {league.realtime ? <PositionTrend row={row} /> : null}
                      {row.position}
                    </span>
                    <TableTeamLogo teamName={row.team} />
                    <Link to={teamPath(row.team, undefined, league.leagueName)} className="table-cell table-cell-team table-team-name">{row.team}</Link>
                    {scores.size > 0 && <span className="table-cell table-cell-score">
                      {score && <Link to={matchPath(score.match)} state={{ match: score.match }} className={`table-score-pill is-${score.outcome}`} aria-label={`${row.team}, ${score.label}`}>
                        {score.scored}-{score.conceded}
                      </Link>}
                    </span>}
                    <span className="table-cell table-cell-played">{row.played}</span>
                    {showStats && <>
                      <span className="table-cell table-cell-stat">{row.won}</span>
                      <span className="table-cell table-cell-stat">{row.drawn}</span>
                      <span className="table-cell table-cell-stat">{row.lost}</span>
                      <span className="table-cell table-cell-stat">{row.goalsFor}</span>
                      <span className="table-cell table-cell-stat">{row.goalsAgainst}</span>
                    </>}
                    <span className="table-cell table-cell-goal-difference table-cell-muted">
                      {signedNumber(row.goalDifference)}
                    </span>
                    <span className="table-cell table-cell-points table-cell-strong">{row.points}</span>
                    <button type="button" onClick={() => toggleRow(row.id)} aria-expanded={isExpanded} aria-label={`Statistics for ${row.team}`} className={`table-expand-chevron${isExpanded ? " is-expanded" : ""}`}>
                      <svg viewBox="0 0 20 20">
                        <path d="m5 7 5 5 5-5" />
                      </svg>
                    </button>
                  </div>

                  {isExpanded ? <LeagueTableExpandedRow row={row} /> : null}

                  {endingZones.map((zone) => (
                    <TableZoneBoundary zone={zone} key={zoneBoundaryKey(zone)} />
                  ))}

                  {endingZones.length === 0 && index < group.rows.length - 1 && !nextStartsLookDownZone ? (
                    <div className={`table-divider${boundary ? " is-thick" : ""}`} />
                  ) : null}
                </div>
              );
            })}

            {groupIndex < groups.length - 1 ? <div className="table-divider is-group-divider" /> : null}
          </div>
        ))}
      </div>
      </div>
  );
}

function TableZoneBoundary({ zone }: { zone: LeagueTableZone }) {
  const label = zoneDisplayLabel(zone);
  return (
    <div
      className={`table-zone-boundary ${zoneClassName(zone)}`}
      role="separator"
      aria-label={`${label} positions ${zone.from} to ${zone.to}`}
    >
      <span>{label}</span>
      <span className="table-zone-boundary-icon" aria-hidden="true">
        {zoneUsesLookDownBoundary(zone) ? "⌄" : "⌃"}
      </span>
    </div>
  );
}

function LeagueTableExpandedRow({ row }: { row: LeagueTableRow }) {
  const formEntries = row.form.slice(-5).map((code) => {
    switch (code.toUpperCase()) {
      case "W":
        return { label: "Win", shortLabel: "W", symbol: "✅" };
      case "L":
        return { label: "Loss", shortLabel: "L", symbol: "❌" };
      default:
        return { label: "Draw", shortLabel: "D", symbol: "➖" };
    }
  });

  return (
    <div className="league-table-expanded">
      <div className="table-expanded-section">
        <div className="table-expanded-title">Stats</div>
        <div className="table-stat-grid">
          <ExpandedStatTile title="Won" shortTitle="W" value={row.won} />
          <ExpandedStatTile title="Drawn" shortTitle="D" value={row.drawn} />
          <ExpandedStatTile title="Lost" shortTitle="L" value={row.lost} />
          <ExpandedStatTile title="Goals For" shortTitle="GF" value={row.goalsFor} />
          <ExpandedStatTile title="Goals Against" shortTitle="GA" value={row.goalsAgainst} />
        </div>
      </div>

      <div className="table-expanded-section">
        <div className="table-expanded-title">Recent form</div>
        {formEntries.length === 0 ? (
          <div className="details-empty">No recent form available</div>
        ) : (
          <div className="table-form-grid">
            {formEntries.map((entry, index) => (
              <FormResultTile
                key={`${row.id}-${index}-${entry.shortLabel}`}
                label={entry.label}
                shortLabel={entry.shortLabel}
                symbol={entry.symbol}
              />
            ))}
          </div>
        )}
      </div>

      {row.rankStatus ? <div className="table-rank-status">{row.rankStatus}</div> : null}
    </div>
  );
}

function ExpandedStatTile({
  title,
  shortTitle,
  value,
}: {
  title: string;
  shortTitle: string;
  value: number;
}) {
  return (
    <div className="table-detail-tile">
      <span className="table-detail-tile-label">
        <span className="table-detail-label-wide">{title}</span>
        <span className="table-detail-label-compact">{shortTitle}</span>
      </span>
      <strong>{value}</strong>
    </div>
  );
}

function FormResultTile({
  label,
  shortLabel,
  symbol,
}: {
  label: string;
  shortLabel: string;
  symbol: string;
}) {
  return (
    <div className="table-detail-tile table-form-tile">
      <span className="table-form-symbol">{symbol}</span>
      <span className="table-detail-tile-label">
        <span className="table-detail-label-wide">{label}</span>
        <span className="table-detail-label-compact">{shortLabel}</span>
      </span>
    </div>
  );
}

function TableTeamLogo({ teamName }: { teamName: string }) {
  const [missing, setMissing] = useState(false);
  const initials = teamName
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((token) => token[0]?.toUpperCase() ?? "")
    .join("");

  if (missing) {
    return <div className="table-team-logo team-logo-fallback">{initials || "?"}</div>;
  }

  return (
    <img
      className="table-team-logo"
      src={`/logos/team?name=${encodeURIComponent(teamName)}`}
      alt=""
      onError={() => setMissing(true)}
    />
  );
}

function normalizeStageName(value: string | null | undefined): string | null {
  const trimmed = String(value || "").trim();
  if (!trimmed || trimmed.localeCompare("Regular Season", undefined, { sensitivity: "base" }) === 0) {
    return null;
  }

  return trimmed;
}

function resolveLeagueID(leagues: LeagueTable[], currentSelection: string): string {
  if (leagues.some((league) => league.leagueID === currentSelection)) {
    return currentSelection;
  }
  const premierLeague = leagues.find(league => league.leagueName.toLowerCase() === "premier league");
  if (premierLeague) return premierLeague.leagueID;

  return [...leagues]
    .sort((left, right) => left.leagueName.localeCompare(right.leagueName, undefined, { sensitivity: "base" }))
    .at(0)?.leagueID || "premier-league";
}

function normalizeRankStatus(value: string | null | undefined): string {
  return String(value || "").trim().toLowerCase();
}

function zoneAtPosition(zones: LeagueTableZone[], position: number): LeagueTableZone | null {
  return zones.find((zone) => position >= zone.from && position <= zone.to) || null;
}

function zoneDescriptor(zone: LeagueTableZone): string {
  return `${zone.key} ${zone.label} ${zone.type}`.toLowerCase();
}

function zoneUsesLookDownBoundary(zone: LeagueTableZone): boolean {
  return zoneDescriptor(zone).includes("releg");
}

function zoneBoundaryKey(zone: LeagueTableZone): string {
  return `${zone.key}-${zone.from}-${zone.to}`;
}

function zoneClassName(zone: LeagueTableZone | null): string {
  if (!zone) return "is-neutral";
  const descriptor = zoneDescriptor(zone);
  if (descriptor.includes("playoff") || descriptor.includes("play-off")) {
    return descriptor.includes("releg") ? "is-relegation-playoff" : "is-playoff";
  }
  if (descriptor.includes("releg")) return "is-relegation";
  if (descriptor.includes("promo")) return "is-promotion";
  return "is-other";
}

function zoneDisplayLabel(zone: LeagueTableZone): string {
  const descriptor = zoneDescriptor(zone);
  if (descriptor.includes("playoff") || descriptor.includes("play-off")) {
    return descriptor.includes("releg") ? "Relegation play-off" : "Play-offs";
  }
  return zone.label;
}

function isBenefitBoundary(rows: LeagueTableRow[], index: number): boolean {
  if (index < 0 || index >= rows.length - 1) {
    return false;
  }

  return normalizeRankStatus(rows[index].rankStatus) !== normalizeRankStatus(rows[index + 1].rankStatus);
}

function signedNumber(value: number): string {
  return value > 0 ? `+${value}` : String(value);
}

function formatLastUpdated(value: string): string {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return value;
  }

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(parsed);
}

function orderEntry(league: LeagueTable, catalog: Competition[]) {
  const entry = catalog.find(item => item.id === league.leagueID || [item.name, ...item.aliases].some(alias => alias.toLowerCase() === league.leagueName.toLowerCase()));
  return { id: entry?.id || league.leagueID, name: entry?.name || league.leagueName, weight: entry?.weight };
}
