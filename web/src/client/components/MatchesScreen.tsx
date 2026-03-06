import { useEffect, useMemo, useReducer, useState } from "react";
import { fetchMatches, fetchTeamRankings } from "../api";
import { usePreferences } from "../preferences";
import {
  TeamRatingLookup,
  groupMatches,
} from "../matchGrouping";
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
  const { preferences } = usePreferences();
  const [searchText, setSearchText] = useState("");
  const [state, setState] = useState<ScreenState>(initialState);
  const [reloadToken, reload] = useReducer((value) => value + 1, 0);

  const requestKey = JSON.stringify({
    mode,
    preferences,
    reloadToken,
  });

  useEffect(() => {
    const controller = new AbortController();
    let intervalId = 0;

    const load = async (manual = false) => {
      setState((current) => ({
        ...current,
        loading: current.groups.length === 0,
        refreshing: manual || current.groups.length > 0,
        error: null,
      }));

      try {
        const rankingsPromise =
          preferences.matchGroupSortOrder === "teamScore" ||
          preferences.matchGroupSortOrder === "kickoffThenTeamScore"
            ? fetchTeamRankings()
            : Promise.resolve([]);

        const [rankings, payload] = await Promise.all([
          rankingsPromise,
          fetchMatches(mode, preferences, controller.signal),
        ]);
        if (controller.signal.aborted) {
          return;
        }

        const grouped = groupMatches(
          payload.matches,
          mode,
          preferences.matchGroupSortOrder,
          new TeamRatingLookup(rankings)
        );

        setState({
          loading: false,
          refreshing: false,
          error: null,
          groups: grouped,
          totalCount: payload.totalCount,
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
          error: error instanceof Error ? error.message : "Unable to load matches.",
        }));
      }
    };

    void load();
    intervalId = window.setInterval(() => {
      void load(true);
    }, preferences.refreshIntervalMinutes * 60_000);

    return () => {
      controller.abort();
      window.clearInterval(intervalId);
    };
  }, [requestKey]);

  const displayedGroups = useMemo(() => {
    const query = searchText.trim().toLowerCase();
    if (query.length < 3) {
      return state.groups;
    }

    return state.groups
      .map((day) => ({
        ...day,
        leagues: day.leagues
          .map((league) => ({
            ...league,
            matches: league.matches.filter((match) => {
              const haystack = [
                match.homeTeam,
                match.awayTeam,
                match.league,
                match.leagueSubcategory || "",
                match.tvChannels.join(" "),
              ]
                .join(" ")
                .toLowerCase();
              return haystack.includes(query);
            }),
          }))
          .filter((league) => league.matches.length > 0),
      }))
      .filter((day) => day.leagues.length > 0);
  }, [searchText, state.groups]);

  const title = mode === "fixtures" ? "Fixtures" : "Results";
  const subtitle =
    mode === "fixtures"
      ? "Today onward, grouped by date and competition."
      : "Recent scorelines, newest match-days first.";

  return (
    <section className="screen-panel">
      <header className="screen-header">
        <div>
          <div className="screen-kicker">{title}</div>
          <h2>{title}</h2>
          <p>{subtitle}</p>
        </div>
        <button
          type="button"
          className="ghost-button"
          onClick={() => reload()}
          disabled={state.refreshing}
        >
          {state.refreshing ? "Refreshing..." : `Refresh ${title.toLowerCase()}`}
        </button>
      </header>

      <div className="screen-toolbar">
        <label className="search-field">
          <span>Search</span>
          <input
            type="search"
            placeholder={`Search ${title.toLowerCase()}, team, or channel`}
            value={searchText}
            onChange={(event) => setSearchText(event.target.value)}
          />
        </label>
        <div className="meta-grid">
          <div className="stat-card">
            <span>Matches</span>
            <strong>{state.totalCount}</strong>
          </div>
          <div className="stat-card">
            <span>Last updated</span>
            <strong>{formatLastUpdated(state.lastUpdated)}</strong>
          </div>
        </div>
      </div>

      {state.loading ? (
        <div className="empty-state">Loading {title.toLowerCase()}...</div>
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
    </section>
  );
}

function formatLastUpdated(value: string | null): string {
  if (!value) {
    return "Unknown";
  }

  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return value;
  }

  return new Intl.DateTimeFormat(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    month: "short",
    day: "numeric",
  }).format(parsed);
}
