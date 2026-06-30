import { useEffect, useMemo, useReducer, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { fetchLeagueTables } from "../api";
import type { LeagueTable, LeagueTableRow } from "../types";

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

export function TablesScreen() {
  const [selectedLeagueID, setSelectedLeagueID] = useState("premier-league");
  const [state, setState] = useState<TablesState>(initialState);
  const [reloadToken, reload] = useReducer((value) => value + 1, 0);
  const [searchParams, setSearchParams] = useSearchParams();
  const [highlightedRowId, setHighlightedRowId] = useState<string | null>(null);

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
        setSelectedLeagueID((current) => resolveLeagueID(payload.leagues, current));
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
    const id = window.setInterval(() => reload(), 30_000);
    return () => window.clearInterval(id);
  }, []);

  // Deep link from MatchTeamLeaguePositionsLink (?league=&team=): select the
  // league, scroll to + briefly highlight the team's row, then clear the params.
  useEffect(() => {
    const leagueID = searchParams.get("league");
    const teamName = searchParams.get("team");
    if (!leagueID || !teamName || state.leagues.length === 0) {
      return;
    }

    const league = state.leagues.find((candidate) => candidate.leagueID === leagueID);
    if (!league) {
      setSearchParams({}, { replace: true });
      return;
    }

    const allRows = league.rows.length > 0 ? league.rows : league.groups.flatMap((group) => group.rows);
    const row = allRows.find(
      (candidate) => candidate.team.localeCompare(teamName, undefined, { sensitivity: "base" }) === 0
    );

    setSelectedLeagueID(leagueID);
    setSearchParams({}, { replace: true });

    if (row) {
      window.setTimeout(() => {
        document.getElementById(`table-row-${row.id}`)?.scrollIntoView({ behavior: "smooth", block: "center" });
        setHighlightedRowId(row.id);
        window.setTimeout(() => setHighlightedRowId((current) => (current === row.id ? null : current)), 2500);
      }, 200);
    }
  }, [searchParams, state.leagues, setSearchParams]);

  const sortedLeagues = useMemo(
    () =>
      [...state.leagues].sort((left, right) =>
        left.leagueName.localeCompare(right.leagueName, undefined, { sensitivity: "base" })
      ),
    [state.leagues]
  );

  const selectedLeague =
    sortedLeagues.find((league) => league.leagueID === selectedLeagueID) || sortedLeagues[0] || null;

  return (
    <section className="screen-panel">
      {state.loading ? (
        <div className="empty-state">Loading tables...</div>
      ) : sortedLeagues.length === 0 ? (
        <div className="empty-state">
          <strong>No tables to show.</strong>
          <div>League tables will appear here once available.</div>
        </div>
      ) : (
        <div className="tables-stack">
          <label className="field-stack tables-competition-field">
            <select
              className="select-field"
              value={selectedLeague?.leagueID || ""}
              onChange={(event) => setSelectedLeagueID(event.target.value)}
            >
              {sortedLeagues.map((league) => (
                <option key={league.leagueID} value={league.leagueID}>
                  {league.leagueName}
                </option>
              ))}
            </select>
          </label>

          {selectedLeague ? (
            <>
              <LeagueTableHero league={selectedLeague} />
              {leagueHasLiveRows(selectedLeague) ? (
                <div className="tables-live-note">
                  <span className="tables-live-dot" aria-hidden="true" />
                  Positions update live from in-progress scores and are provisional.
                </div>
              ) : null}
              <LeagueTableCard league={selectedLeague} highlightedRowId={highlightedRowId} />
              {state.lastUpdated ? (
                <div className="tables-updated">Updated {formatLastUpdated(state.lastUpdated)}</div>
              ) : null}
            </>
          ) : null}
        </div>
      )}
    </section>
  );
}

function LeagueTableHero({ league }: { league: LeagueTable }) {
  const visibleStageName = normalizeStageName(league.stageName);

  return (
    <section className="league-hero">
      <div className="league-hero-mark">
        {league.leagueName.toLowerCase().includes("premier league") ? (
          <img src="/generated-assets/app-icon.png" alt="" />
        ) : (
          <span aria-hidden="true">*</span>
        )}
      </div>
      <div className="league-hero-title">
        <h2>{league.leagueName}</h2>
        {visibleStageName ? <p>{visibleStageName}</p> : null}
      </div>
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
}: {
  league: LeagueTable;
  highlightedRowId?: string | null;
}) {
  const [expandedRows, setExpandedRows] = useState<Set<string>>(new Set());
  const visibleStageName = normalizeStageName(league.stageName);
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

      <div className="league-table">
        <div className="league-table-heading">
          <span className="table-cell table-cell-position" aria-hidden="true" />
          <span className="table-cell table-cell-logo" aria-hidden="true" />
          <span className="table-cell table-cell-team">Team</span>
          <span className="table-cell table-cell-played">P</span>
          <span className="table-cell table-cell-goal-difference">GD</span>
          <span className="table-cell table-cell-points">Pts</span>
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
              const isExpanded = expandedRows.has(row.id);
              const boundary = isBenefitBoundary(group.rows, index);

              return (
                <div className="league-table-row-wrap" key={`${groupIndex}-${row.id}`}>
                  <button
                    type="button"
                    id={`table-row-${row.id}`}
                    className={`league-table-row${row.live ? " is-live" : ""}${row.id === highlightedRowId ? " is-highlighted" : ""}`}
                    onClick={() => toggleRow(row.id)}
                    aria-expanded={isExpanded}
                  >
                    <span className="table-cell table-cell-position">
                      {league.realtime ? <PositionTrend row={row} /> : null}
                      {row.position}
                    </span>
                    <TableTeamLogo teamName={row.team} />
                    <span className="table-cell table-cell-team table-team-name">{row.team}</span>
                    <span className="table-cell table-cell-played">{row.played}</span>
                    <span className="table-cell table-cell-goal-difference table-cell-muted">
                      {signedNumber(row.goalDifference)}
                    </span>
                    <span className="table-cell table-cell-points table-cell-strong">{row.points}</span>
                    <span className={`table-expand-chevron${isExpanded ? " is-expanded" : ""}`} aria-hidden="true">
                      <svg viewBox="0 0 20 20">
                        <path d="m5 7 5 5 5-5" />
                      </svg>
                    </span>
                  </button>

                  {isExpanded ? <LeagueTableExpandedRow row={row} /> : null}

                  {index < group.rows.length - 1 ? (
                    <div className={`table-divider${boundary ? " is-thick" : ""}`} />
                  ) : null}
                </div>
              );
            })}

            {groupIndex < groups.length - 1 ? <div className="table-divider is-group-divider" /> : null}
          </div>
        ))}
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
  if (leagues.some((league) => league.leagueID === "premier-league")) {
    return "premier-league";
  }

  return [...leagues]
    .sort((left, right) => left.leagueName.localeCompare(right.leagueName, undefined, { sensitivity: "base" }))
    .at(0)?.leagueID || "premier-league";
}

function normalizeRankStatus(value: string | null | undefined): string {
  return String(value || "").trim().toLowerCase();
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
