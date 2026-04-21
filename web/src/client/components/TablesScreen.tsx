import { useEffect, useMemo, useReducer, useState } from "react";
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

          {selectedLeague ? <LeagueTableCard league={selectedLeague} /> : null}
        </div>
      )}
    </section>
  );
}

function LeagueTableCard({ league }: { league: LeagueTable }) {
  const [expandedRows, setExpandedRows] = useState<Set<string>>(new Set());
  const visibleStageName = normalizeStageName(league.stageName);

  useEffect(() => {
    setExpandedRows(new Set());
  }, [league.id]);

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

        {league.rows.map((row, index) => {
          const isExpanded = expandedRows.has(row.id);
          const boundary = isBenefitBoundary(league.rows, index);

          return (
            <div className="league-table-row-wrap" key={row.id}>
              <button
                type="button"
                className="league-table-row"
                onClick={() =>
                  setExpandedRows((current) => {
                    const next = new Set(current);
                    if (next.has(row.id)) {
                      next.delete(row.id);
                    } else {
                      next.add(row.id);
                    }
                    return next;
                  })
                }
                aria-expanded={isExpanded}
              >
                <span className="table-cell table-cell-position">{row.position}</span>
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

              {index < league.rows.length - 1 ? (
                <div className={`table-divider${boundary ? " is-thick" : ""}`} />
              ) : null}
            </div>
          );
        })}
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
