import { useEffect, useMemo, useReducer, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { fetchMatches, fetchTeamRankings, fetchCompetitionWeights, fetchCompetitions } from "../api";
import { usePreferences } from "../preferences";
import { CompetitionWeightLookup, TeamRatingLookup, groupMatches } from "../matchGrouping";
import { useShouldUseShortTeamNames } from "../useResponsiveTeamNames";
import { MatchCard } from "./MatchCard";
import type { ChangeEvent } from "react";
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
  const [searchText, setSearchText]   = useState("");
  const [showSearch, setShowSearch]   = useState(false);
  const [state, setState]             = useState<ScreenState>(initialState);
  const [reloadToken, reload]         = useReducer((v) => v + 1, 0);
  const useShortTeamNames             = useShouldUseShortTeamNames();

  // Client-side competition filter – null means "show all", string[] means "show only these".
  // This is intentionally NOT part of server preferences: the server always fetches the
  // full set (or EPL-only), and we filter the results here. This avoids fragile server-side
  // league-name matching when many leagues are sent as params.
  const [customCompetitions, setCustomCompetitions] = useState<string[] | null>(null);

  const requestKey = JSON.stringify({ mode, preferences, reloadToken });

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

  // Build a lowercase set for O(1) lookups when a custom filter is active.
  const customCompetitionSet = useMemo(
    () => (customCompetitions !== null ? new Set(customCompetitions.map((c) => c.toLowerCase())) : null),
    [customCompetitions]
  );

  // Filter matches by search query (min 3 chars) and client-side competition selection.
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
              // Client-side competition filter
              if (customCompetitionSet && !customCompetitionSet.has(match.league.toLowerCase())) {
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
  }, [mode, searchText, state.groups, customCompetitionSet]);

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

        {/* Competitions dropdown */}
        <CompetitionsDropdown
          customCompetitions={customCompetitions}
          onCustomCompetitionsChange={setCustomCompetitions}
        />

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
                        useShortTeamNames={useShortTeamNames}
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

interface PanelPos { top: number; right: number }

interface CompetitionsDropdownProps {
  customCompetitions: string[] | null;
  onCustomCompetitionsChange: (value: string[] | null) => void;
}

function CompetitionsDropdown({ customCompetitions, onCustomCompetitionsChange }: CompetitionsDropdownProps) {
  const { preferences, setPreferences } = usePreferences();
  const [isOpen, setIsOpen] = useState(false);
  const [competitions, setCompetitions] = useState<string[]>([]);
  const [panelPos, setPanelPos] = useState<PanelPos>({ top: 0, right: 0 });
  const triggerRef = useRef<HTMLButtonElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);

  const eplOnly = preferences.englishPremierLeagueTeamsOnly;
  const majorUEFAClubGamesEnabled = preferences.majorUEFAClubGamesEnabled;
  const customFilter = customCompetitions !== null;

  useEffect(() => {
    void fetchCompetitions().then(setCompetitions).catch(() => {});
  }, []);

  useEffect(() => {
    if (!isOpen) return;

    const handlePointerDown = (e: PointerEvent) => {
      const target = e.target as Node;
      if (!triggerRef.current?.contains(target) && !panelRef.current?.contains(target)) {
        setIsOpen(false);
      }
    };

    // Dismiss on scroll/resize, but NOT when the user scrolls inside the panel itself.
    const handleScroll = (e: Event) => {
      if (panelRef.current?.contains(e.target as Node)) return;
      setIsOpen(false);
    };

    const handleResize = () => setIsOpen(false);

    document.addEventListener("pointerdown", handlePointerDown);
    window.addEventListener("scroll", handleScroll, { capture: true, passive: true });
    window.addEventListener("resize", handleResize, { passive: true });
    return () => {
      document.removeEventListener("pointerdown", handlePointerDown);
      window.removeEventListener("scroll", handleScroll, { capture: true });
      window.removeEventListener("resize", handleResize);
    };
  }, [isOpen]);

  const openDropdown = () => {
    if (triggerRef.current) {
      const rect = triggerRef.current.getBoundingClientRect();
      setPanelPos({
        top: rect.bottom + 5,
        right: window.innerWidth - rect.right,
      });
    }
    setIsOpen((v) => !v);
  };

  // Option 1: show all matches, no EPL filter, no competition filter.
  const handleSelectAll = () => {
    setPreferences({ englishPremierLeagueTeamsOnly: false });
    onCustomCompetitionsChange(null);
  };

  // Option 2: EPL teams only server filter – does NOT touch the competition filter.
  const handleSelectEplOnly = () => {
    setPreferences({ englishPremierLeagueTeamsOnly: true });
  };

  const handleToggleMajorUEFAClubGames = (event: ChangeEvent<HTMLInputElement>) => {
    setPreferences({ majorUEFAClubGamesEnabled: event.target.checked });
  };

  // Toggle a single competition in the client-side filter.
  // When not yet in custom mode, initialise from the full list and remove (or add) the tapped item.
  const handleToggleCompetition = (competition: string) => {
    const base = customFilter
      ? new Set(customCompetitions)
      : new Set(competitions); // treat all as checked when no custom filter active

    if (base.has(competition)) {
      base.delete(competition);
    } else {
      base.add(competition);
    }

    const newSelected = [...base];
    // If every competition is back to checked, revert to "no filter" state.
    const allChecked = newSelected.length === competitions.length;
    onCustomCompetitionsChange(allChecked ? null : newSelected);
  };

  let label: string;
  if (eplOnly && customFilter) {
    const n = customCompetitions.length;
    label = n === 1 ? "PL teams · 1 competition" : `PL teams · ${n} competitions`;
  } else if (eplOnly) {
    label = "Premier League teams";
  } else if (customFilter) {
    const n = customCompetitions.length;
    label = n === 1 ? "1 competition" : `${n} competitions`;
  } else {
    label = "All competitions";
  }

  const panel = (
    <div
      ref={panelRef}
      className="comp-dropdown-panel"
      role="dialog"
      aria-label="Filter competitions"
      style={{ top: panelPos.top, right: panelPos.right }}
    >
      <label className="comp-option">
        <input
          type="radio"
          name="comp-mode"
          checked={!eplOnly}
          onChange={handleSelectAll}
        />
        <span>All matches across all competitions</span>
      </label>

      <label className="comp-option comp-option--epl">
        <input
          type="radio"
          name="comp-mode"
          checked={eplOnly}
          onChange={handleSelectEplOnly}
        />
        <img
          src="/generated-assets/fpl-lion.png"
          alt=""
          aria-hidden="true"
          className="epl-toggle-lion"
        />
        <span>Matches with Premier League teams only</span>
      </label>

      <div className="comp-dropdown-sep" />

      <label className="comp-option comp-option--major-uefa">
        <input
          type="checkbox"
          checked={majorUEFAClubGamesEnabled}
          onChange={handleToggleMajorUEFAClubGames}
        />
        <span>Major UEFA games</span>
      </label>

      {competitions.length > 0 && <div className="comp-dropdown-sep" />}

      {competitions.length > 0 && (
        <div className="comp-list">
          {competitions.map((comp) => {
            const isChecked = !customFilter || customCompetitions.includes(comp);
            return (
              <label key={comp} className="comp-option">
                <input
                  type="checkbox"
                  checked={isChecked}
                  onChange={() => handleToggleCompetition(comp)}
                />
                <span>{comp}</span>
              </label>
            );
          })}
        </div>
      )}
    </div>
  );

  return (
    <div className="comp-dropdown">
      <button
        ref={triggerRef}
        type="button"
        className={`epl-toggle-btn comp-dropdown-trigger${eplOnly || customFilter ? " is-active" : ""}`}
        onClick={openDropdown}
        aria-haspopup="true"
        aria-expanded={isOpen}
      >
        <img
          src="/generated-assets/fpl-lion.png"
          alt=""
          aria-hidden="true"
          className="epl-toggle-lion"
        />
        <span className="epl-toggle-label">{label}</span>
        <svg
          className="comp-dropdown-chevron"
          viewBox="0 0 24 24"
          aria-hidden="true"
          style={{ transform: isOpen ? "rotate(180deg)" : undefined }}
        >
          <path d="m6 9 6 6 6-6" />
        </svg>
      </button>

      {isOpen && createPortal(panel, document.body)}
    </div>
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
