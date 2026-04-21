import { useEffect, useMemo, useReducer, useState } from "react";
import { fetchMatches, fetchTeamRankings, fetchCompetitionWeights } from "../api";
import { usePreferences } from "../preferences";
import { CompetitionWeightLookup, TeamRatingLookup, groupMatches } from "../matchGrouping";
import { MatchCard } from "./MatchCard";
import type { MatchDayGroup, MatchesMode } from "../types";

interface MatchesScreenProps {
  mode: MatchesMode;
}

interface ScreenState {
  loading: boolean;
  refreshing: boolean;
  error: string | null;
  groups: MatchDayGroup[];
  totalCount: number;
  lastUpdated: string | null;
}

const initialState: ScreenState = {
  loading: true,
  refreshing: false,
  error: null,
  groups: [],
  totalCount: 0,
  lastUpdated: null,
};

export function MatchesScreen({ mode }: MatchesScreenProps) {
  const { preferences, setPreferences } = usePreferences();
  const [searchText, setSearchText]   = useState("");
  const [showSearch, setShowSearch]   = useState(false);
  const [state, setState]             = useState<ScreenState>(initialState);
  const [reloadToken, reload]         = useReducer((v) => v + 1, 0);

  const requestKey = JSON.stringify({ mode, preferences, reloadToken });

  const eplOnly = preferences.englishPremierLeagueTeamsOnly;
  const toggleEplFilter = () =>
    setPreferences({ englishPremierLeagueTeamsOnly: !eplOnly });

  useEffect(() => {
    const controller    = new AbortController();
    let refreshTimeoutId = 0;
    let loadInFlight     = false;

    const load = async (manual = false) => {
      if (loadInFlight) return;
      loadInFlight = true;

      setState((current) => ({
        ...current,
        loading:    current.groups.length === 0,
        refreshing: manual || current.groups.length > 0,
        error:      null,
      }));

      try {
        const rankingsPromise =
          preferences.matchGroupSortOrder === "teamScore" ||
          preferences.matchGroupSortOrder === "kickoffThenTeamScore"
            ? fetchTeamRankings()
            : Promise.resolve([]);

        const [rankings, weights, payload] = await Promise.all([
          rankingsPromise,
          fetchCompetitionWeights().catch(() => []),
          fetchMatches(mode, preferences, controller.signal),
        ]);

        if (controller.signal.aborted) return;

        const grouped = groupMatches(
          payload.matches,
          mode,
          preferences.matchGroupSortOrder,
          new TeamRatingLookup(rankings),
          new CompetitionWeightLookup(weights)
        );

        setState({
          loading: false, refreshing: false, error: null,
          groups: grouped,
          totalCount: payload.totalCount,
          lastUpdated: payload.lastUpdated,
        });
      } catch (error) {
        if (controller.signal.aborted) return;
        setState((current) => ({
          ...current,
          loading: false, refreshing: false,
          error: error instanceof Error ? error.message : "Unable to load matches.",
        }));
      } finally {
        loadInFlight = false;
        if (!controller.signal.aborted) scheduleRefresh();
      }
    };

    const scheduleRefresh = () => {
      window.clearTimeout(refreshTimeoutId);
      refreshTimeoutId = window.setTimeout(() => {
        if (document.visibilityState === "visible") {
          void load(true);
        } else {
          scheduleRefresh();
        }
      }, preferences.refreshIntervalMinutes * 60_000);
    };

    const handleWindowActive = () => {
      if (document.visibilityState === "visible") void load(true);
    };

    void load();
    window.addEventListener("focus", handleWindowActive);
    document.addEventListener("visibilitychange", handleWindowActive);

    return () => {
      controller.abort();
      window.clearTimeout(refreshTimeoutId);
      window.removeEventListener("focus", handleWindowActive);
      document.removeEventListener("visibilitychange", handleWindowActive);
    };
  }, [requestKey]);

  // Filter matches by search query (min 3 chars to trigger)
  const displayedGroups = useMemo(() => {
    const query = searchText.trim().toLowerCase();

    return state.groups
      .map((day) => ({
        ...day,
        leagues: day.leagues
          .map((league) => ({
            ...league,
            matches: league.matches.filter((match) => {
              if (mode === "fixtures" && (match.scoreStatus || "").trim().toUpperCase() === "POSTPONED") {
                return false;
              }
              if (query.length < 3) return true;
              const haystack = [
                match.homeTeam, match.awayTeam,
                match.league, match.leagueSubcategory ?? "",
                match.tvChannels.join(" "),
              ].join(" ").toLowerCase();
              return haystack.includes(query);
            }),
          }))
          .filter((league) => league.matches.length > 0),
      }))
      .filter((day) => day.leagues.length > 0);
  }, [mode, searchText, state.groups]);

  const title = mode === "fixtures" ? "Fixtures" : "Results";

  return (
    <section className="screen-panel">
      {/* ── Minimal toolbar: search + refresh icons ── */}
      <div className="match-controls">
        {showSearch && (
          <span style={{ flex: 1, marginRight: "0.25rem", fontSize: "0.75rem", color: "var(--text-muted)", alignSelf: "center" }}>
            {searchText.trim().length >= 3 && displayedGroups.length === 0
              ? "No matches"
              : searchText.trim().length >= 3
              ? `${displayedGroups.reduce((n, d) => n + d.leagues.reduce((m, l) => m + l.matches.length, 0), 0)} match${displayedGroups.reduce((n, d) => n + d.leagues.reduce((m, l) => m + l.matches.length, 0), 0) === 1 ? "" : "es"}`
              : null}
          </span>
        )}

        {/* EPL / All competitions toggle */}
        <button
          type="button"
          className={`epl-toggle-btn${eplOnly ? " is-active" : ""}`}
          onClick={toggleEplFilter}
          aria-label={eplOnly ? "Showing matches with Premier League teams only – click for all competitions" : "Showing all competitions – click for matches with Premier League teams only"}
          title={eplOnly ? "Show matches for all competitions" : "Show only matches involving Premier League teams"}
        >
          <img
            src="/generated-assets/fpl-lion.png"
            alt=""
            aria-hidden="true"
            className="epl-toggle-lion"
          />
          <span className="epl-toggle-label">{eplOnly ? "Matches with Premier League teams" : "Showing matches for all competitions"}</span>
        </button>

        {/* Search toggle */}
        <button
          type="button"
          className={`control-btn${showSearch ? " is-active" : ""}`}
          onClick={() => {
            setShowSearch((v) => {
              if (v) setSearchText(""); // clear on close
              return !v;
            });
          }}
          aria-label={showSearch ? "Close search" : "Search"}
          style={showSearch ? { color: "var(--accent)", borderColor: "var(--accent-border)", background: "var(--accent-soft)" } : undefined}
        >
          {/* Magnifier icon */}
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <circle cx="11" cy="11" r="7" />
            <path d="m16.5 16.5 4 4" />
          </svg>
        </button>

        {/* Refresh */}
        <button
          type="button"
          className={`control-btn${state.refreshing ? " is-spinning" : ""}`}
          onClick={() => reload()}
          disabled={state.refreshing}
          aria-label={state.refreshing ? "Refreshing…" : `Refresh ${title.toLowerCase()}`}
        >
          {/* Refresh / rotate icon */}
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M4 4v5h.582m15.356 2A8.001 8.001 0 0 0 4.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 0 1-15.357-2m15.357 2H15" />
          </svg>
        </button>
      </div>

      {/* ── Collapsible search field ── */}
      {showSearch && (
        <div className="match-search">
          <input
            type="search"
            placeholder="Search teams, leagues, channels…"
            value={searchText}
            onChange={(e) => setSearchText(e.target.value)}
            // eslint-disable-next-line jsx-a11y/no-autofocus
            autoFocus
          />
        </div>
      )}

      {/* ── Match list ── */}
      {state.loading ? (
        <div className="empty-state">Loading {title.toLowerCase()}…</div>
      ) : state.error ? (
        <div className="empty-state is-error">{state.error}</div>
      ) : displayedGroups.length === 0 ? (
        <div className="empty-state">
          {searchText.trim().length >= 3
            ? `No ${title.toLowerCase()} matched that search.`
            : `No ${title.toLowerCase()} to show.`}
        </div>
      ) : (
        <div className="match-day-stack">
          {displayedGroups.map((day) => (
            <section className="day-section" key={day.id}>
              <div className="day-section-header">
                <h3>{day.displayDate}</h3>
              </div>

              {day.leagues.map((league) => (
                <div className="league-group" key={league.id}>
                  <div className="league-title">{league.league}</div>
                  <div className="match-card-list">
                    {league.matches.map((match) => (
                      <MatchCard
                        key={match.id}
                        match={match}
                        highlightToday={day.isToday}
                      />
                    ))}
                  </div>
                </div>
              ))}
            </section>
          ))}
        </div>
      )}

      {/* ── Last updated footer ── */}
      {state.lastUpdated && (
        <div className="match-list-footer">
          Updated {formatLastUpdated(state.lastUpdated)}
        </div>
      )}
    </section>
  );
}

function formatLastUpdated(value: string | null): string {
  if (!value) return "";
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return value;
  return new Intl.DateTimeFormat(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    month: "short",
    day: "numeric",
  }).format(parsed);
}
