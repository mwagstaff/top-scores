import { useEffect, useMemo, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { cachedDay, loadDay } from "../dayStore";
import {
  competitionPath,
  dateLabel,
  isUKRelevant,
  matchPath,
  moveDate,
  ukChannels,
  ukDate,
  validDate,
} from "../football";
import { isMatchFinished, isMatchLive } from "../matchState";
import { usePreferences } from "../preferences";
import { FixtureRow } from "./FixtureRow";
import { PageMeta } from "./PageMeta";
import { StadiumBackdrop } from "./StadiumBackdrop";
import type { Match, MatchesMode } from "../types";
import { useInitialSeed } from "../bootstrap";
import { normalizeMatch } from "../api";
import { fetchTeamRankings } from "../api";

export function MatchesScreen({
  mode = "fixtures",
  tv = false,
  competition,
}: {
  mode?: MatchesMode;
  tv?: boolean;
  competition?: string;
}) {
  const [params, setParams] = useSearchParams();
  const { preferences } = usePreferences();
  const today = ukDate();
  const requestedDate = params.get("date");
  const date = validDate(requestedDate)
    ? requestedDate
    : mode === "results"
      ? moveDate(today, -1)
      : today;
  const scope =
    params.get("scope") ||
    (competition
      ? "all"
      : preferences.englishPremierLeagueTeamsOnly
        ? "epl"
        : "uk");
  const epl = scope === "epl" && !competition;
  const dayScope = epl
    ? new URLSearchParams({
        major_uefa: String(preferences.majorUEFAClubGamesEnabled),
        home_nations: String(preferences.homeNationsFilterEnabled),
        major_tournaments: String(preferences.majorTournamentsFilterEnabled),
      }).toString()
    : false;
  const filter = tv ? "tv" : params.get("view") || "all";
  const seed = useInitialSeed();
  const seededDay = useMemo(
    () =>
      !epl && seed?.date === date && seed.matches
        ? {
            matches: seed.matches.map(normalizeMatch),
            fetchedAt: seed.fetchedAt,
            page: 1,
            hasMore: Boolean(seed.hasMore),
            lastUpdated: seed.lastUpdated || null,
            totalCount: seed.matches.length,
          }
        : undefined,
    [seed, date, epl],
  );
  const [query, setQuery] = useState("");
  const [searchOpen, setSearchOpen] = useState(false);
  const [data, setData] = useState(() => ({
    key: `${date}:${dayScope}`,
    value:
      seededDay || (seed?.rendered ? undefined : cachedDay(date, dayScope)),
  }));
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const [rating, setRating] = useState<((name: string) => number) | null>(null);
  const key = `${date}:${dayScope}`;
  const payload = data.key === key ? data.value : cachedDay(date, dayScope);
  useEffect(() => {
    if (!preferences.matchGroupSortOrder.toLowerCase().includes("teamscore"))
      return;
    let cancelled = false;
    void Promise.all([import("../matchGrouping"), fetchTeamRankings()])
      .then(([module, entries]) => {
        const lookup = new module.TeamRatingLookup(entries);
        if (!cancelled)
          setRating(() => (name: string) => lookup.resolvedRating(name));
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [preferences.matchGroupSortOrder]);
  useEffect(() => {
    let cancelled = false,
      inFlight = false;
    let timer = 0;
    setError("");
    const run = async () => {
      if (inFlight || cancelled) return;
      if (document.visibilityState !== "visible") {
        timer = window.setTimeout(run, 60_000);
        return;
      }
      inFlight = true;
      setBusy(true);
      try {
        const value = await loadDay(date, dayScope, refresh > 0);
        if (!cancelled) {
          setData({ key, value });
          setError("");
        }
      } catch (error) {
        if (!cancelled)
          setError(
            error instanceof Error
              ? error.message
              : "Scores are temporarily unavailable.",
          );
      } finally {
        inFlight = false;
        if (!cancelled) {
          setBusy(false);
          window.clearTimeout(timer);
          timer = window.setTimeout(
            run,
            date === ukDate()
              ? 10_000
              : preferences.refreshIntervalMinutes * 60_000,
          );
        }
      }
    };
    const activate = () => {
      if (document.visibilityState === "visible") void run();
    };
    void run();
    window.addEventListener("online", activate);
    document.addEventListener("visibilitychange", activate);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
      window.removeEventListener("online", activate);
      document.removeEventListener("visibilitychange", activate);
    };
  }, [key, refresh, preferences.refreshIntervalMinutes]);
  useEffect(() => {
    if (!payload) return;
    const connection = (
      navigator as Navigator & {
        connection?: { saveData?: boolean; effectiveType?: string };
      }
    ).connection;
    if (connection?.saveData || /2g/.test(connection?.effectiveType || ""))
      return;
    const timer = window.setTimeout(() => {
      void loadDay(moveDate(date, -1), dayScope).catch(() => {});
      void loadDay(moveDate(date, 1), dayScope).catch(() => {});
    }, 1500);
    return () => window.clearTimeout(timer);
  }, [key, Boolean(payload)]);
  const change = (values: Record<string, string>) =>
    setParams((current) => {
      const next = new URLSearchParams(current);
      for (const [key, value] of Object.entries(values)) {
        if (value) next.set(key, value);
        else next.delete(key);
      }
      return next;
    });
  const relevant = useMemo(
    () =>
      (payload?.matches || []).filter((match) => {
        if (competition && match.league !== competition) return false;
        const legacyComps = params.get("comps")?.split(",");
        if (legacyComps && !legacyComps.includes(match.league)) return false;
        if (!competition && scope === "uk" && !isUKRelevant(match))
          return false;
        if (
          !competition &&
          preferences.competitionFilterEnabled &&
          !preferences.selectedLeagues.includes(match.league)
        )
          return false;
        if (mode === "results" && !isMatchFinished(match)) return false;
        if (
          preferences.channelFilterEnabled &&
          mode === "fixtures" &&
          !match.tvChannels.some((channel) =>
            preferences.selectedChannels.some((selected) =>
              channel.name
                .toLowerCase()
                .includes(selected.replace(" (all)", "").toLowerCase()),
            ),
          )
        )
          return false;
        return true;
      }),
    [payload, competition, scope, mode, preferences, params],
  );
  const matches = useMemo(
    () =>
      relevant.filter((match) => {
        if (filter === "live" && !isMatchLive(match)) return false;
        if (filter === "tv" && !ukChannels(match.tvChannels).length)
          return false;
        return `${match.homeTeam} ${match.awayTeam} ${match.league} ${match.tvChannels.map((c) => c.name).join(" ")}`
          .toLowerCase()
          .includes(query.toLowerCase().trim());
      }),
    [relevant, filter, query],
  );
  const groups = useMemo(() => {
    const groups = new Map<string, Match[]>();
    for (const match of matches)
      groups.set(match.league, [...(groups.get(match.league) || []), match]);
    return [...groups]
      .sort(
        (a, b) =>
          (b[1][0].competitionWeight || 0) - (a[1][0].competitionWeight || 0) ||
          a[0].localeCompare(b[0]),
      )
      .map(
        ([league, games]) =>
          [
            league,
            [...games].sort((a, b) =>
              preferences.matchGroupSortOrder === "alphabetical"
                ? a.homeTeam.localeCompare(b.homeTeam)
                : (preferences.matchGroupSortOrder !== "teamScore"
                    ? a.time.localeCompare(b.time)
                    : 0) ||
                  (rating &&
                  preferences.matchGroupSortOrder
                    .toLowerCase()
                    .includes("teamscore")
                    ? rating(b.homeTeam) +
                      rating(b.awayTeam) -
                      rating(a.homeTeam) -
                      rating(a.awayTeam)
                    : 0) ||
                  a.homeTeam.localeCompare(b.homeTeam),
            ),
          ] as const,
      );
  }, [matches, preferences.matchGroupSortOrder, rating]);
  const tvMatches = relevant
    .filter(
      (match) => ukChannels(match.tvChannels).length && !isMatchFinished(match),
    )
    .slice(0, 3);
  const title =
    competition ||
    (tv
      ? "Football on TV"
      : mode === "results"
        ? "The final whistle."
        : "Your football. Today.");
  const loading = !payload && !error;
  return (
    <>
      {!competition && (
        <PageMeta
          title={
            tv
              ? "Football on UK TV"
              : mode === "results"
                ? "Football results"
                : "Live scores & fixtures"
          }
          description="Today’s football scores, fixtures and UK TV channels. Find your match and where to watch with Top Scores."
        />
      )}
      {!competition && (
        <header className="football-heading">
          <StadiumBackdrop ready={Boolean(payload)} />
          <div className="heading-copy">
            <span className="eyebrow">
              {tv
                ? "The UK TV guide"
                : mode === "results"
                  ? "Results & scorelines"
                  : "The beautiful game, at a glance"}
            </span>
            <h1>{title}</h1>
            <p>
              {tv
                ? "Every listed UK broadcast. Find your next match."
                : mode === "results"
                  ? "Every goal. Every result. All in one place."
                  : "The scores you follow. The matches you’ll watch."}
            </p>
          </div>
        </header>
      )}
      <div className="scores-layout">
        <section
          className="scores-primary"
          aria-label={
            competition ? `${competition} matches` : "Football matches"
          }
        >
          <div className="date-navigator">
            <button
              aria-label="Previous day"
              onClick={() => change({ date: moveDate(date, -1) })}
            >
              ←
            </button>
            <div className="date-shortcuts">
              {[-1, 0, 1].map((offset) => (
                <button
                  key={offset}
                  aria-pressed={date === moveDate(today, offset)}
                  onClick={() => change({ date: moveDate(today, offset) })}
                >
                  {offset < 0 ? "Yesterday" : offset > 0 ? "Tomorrow" : "Today"}
                </button>
              ))}
            </div>
            <button
              aria-label="Next day"
              onClick={() => change({ date: moveDate(date, 1) })}
            >
              →
            </button>
            <label className="date-picker">
              <span className="sr-only">Choose a date</span>
              <input
                aria-label="Choose a date"
                type="date"
                value={date}
                onChange={(e) => {
                  if (validDate(e.target.value))
                    change({ date: e.target.value });
                }}
              />
            </label>
          </div>
          <div className="match-filter-bar">
            <div className="filter-tabs" role="group" aria-label="Match view">
              {(tv
                ? [["tv", "On UK TV"]]
                : [
                    ["all", "All matches"],
                    ["live", "Live"],
                    ["tv", "On UK TV"],
                  ]
              ).map(([value, label]) => (
                <button
                  key={value}
                  aria-pressed={filter === value}
                  onClick={() => change({ view: value })}
                >
                  {value === "live" && <span className="live-dot" />}
                  {label}
                  {value === "live" && (
                    <span className="filter-count">
                      {relevant.filter(isMatchLive).length}
                    </span>
                  )}
                </button>
              ))}
            </div>
            <button
              className="refresh-button"
              disabled={busy}
              onClick={() => setRefresh((v) => v + 1)}
              aria-label="Refresh matches"
            >
              ↻
            </button>
          </div>
          <div className="match-search-row">
            <button
              className="search-toggle"
              aria-label="Search matches"
              aria-expanded={searchOpen}
              onClick={() => {
                setSearchOpen((v) => !v);
                setQuery("");
              }}
            >
              ⌕ <span>Search</span>
            </button>
            {searchOpen && (
              <label className="match-search-field">
                <span aria-hidden="true">⌕</span>
                <input
                  type="search"
                  aria-label="Search teams, competitions or channels"
                  placeholder="Find a team, competition or channel"
                  autoFocus
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                />
              </label>
            )}
            {!competition && (
              <select
                aria-label="Competition scope"
                value={scope}
                onChange={(e) => change({ scope: e.target.value, comps: "" })}
              >
                <option value="uk">UK favourites + TV</option>
                <option value="all">All competitions</option>
                <option value="epl">Premier League focus</option>
              </select>
            )}
          </div>
          <div className="fixture-date-heading">
            <h2>{dateLabel(date)}</h2>
            <span>
              {loading ? "Finding matches…" : `${matches.length} matches`}
            </span>
          </div>
          {error && (
            <div className="refresh-notice" role="status">
              {payload
                ? "Unable to refresh. Showing saved scores."
                : "We couldn’t load these matches."}{" "}
              <button onClick={() => setRefresh((v) => v + 1)}>
                Try again
              </button>
            </div>
          )}
          {loading ? (
            <div
              className="fixture-skeleton"
              role="status"
              aria-label="Loading matches"
            >
              {[0, 1, 2, 3].map((i) => (
                <div key={i}>
                  <span />
                  <span />
                </div>
              ))}
            </div>
          ) : groups.length ? (
            groups.map(([league, games]) => (
              <section className="fixture-competition" key={league}>
                <div className="competition-heading">
                  <Link to={competitionPath(league)}>
                    <span className="competition-mark" aria-hidden="true">
                      {league
                        .replace(/^UEFA /, "")
                        .split(" ")
                        .slice(0, 2)
                        .map((w) => w[0])
                        .join("")}
                    </span>
                    <h3>{league}</h3>
                    <span aria-hidden="true">↗</span>
                  </Link>
                  <span>{games.length}</span>
                </div>
                {games.map((match) => (
                  <FixtureRow match={match} key={match.id} />
                ))}
              </section>
            ))
          ) : (
            !error && (
              <div className="football-empty">
                <span aria-hidden="true">◷</span>
                <h3>
                  {filter === "live"
                    ? "No matches live right now"
                    : query
                      ? "No matches found"
                      : filter === "tv"
                        ? "No UK broadcasts listed"
                        : "A quiet day for football"}
                </h3>
                <p>
                  {query
                    ? "Try another team or channel, or widen your filters."
                    : "Choose another day or explore all competitions."}
                </p>
                <button
                  onClick={() => {
                    setQuery("");
                    change({
                      date: today,
                      view: "all",
                      scope: "all",
                      comps: "",
                    });
                  }}
                >
                  Show today’s matches
                </button>
              </div>
            )
          )}
          {payload?.hasMore && (
            <button
              className="load-more"
              disabled={busy}
              onClick={async () => {
                setBusy(true);
                try {
                  const value = await loadDay(
                    date,
                    dayScope,
                    true,
                    payload.page + 1,
                  );
                  setData({ key, value });
                } catch {
                  setError("Unable to load more matches.");
                } finally {
                  setBusy(false);
                }
              }}
            >
              {busy ? "Loading…" : "Load more matches"}
            </button>
          )}
          <div className="scores-footnote">
            <span>All times UK · TV listings may change</span>
            {payload?.lastUpdated && (
              <span>
                Updated{" "}
                {new Intl.DateTimeFormat("en-GB", {
                  timeZone: "Europe/London",
                  hour: "2-digit",
                  minute: "2-digit",
                }).format(new Date(payload.lastUpdated))}
              </span>
            )}
          </div>
        </section>
        {!competition && (
          <aside className="watch-sidebar" aria-label="UK viewing guide">
            <span className="eyebrow">Make a night of it</span>
            <h2>
              On the box<span className="brand-period">.</span>
            </h2>
            <p>
              UK broadcasts for{" "}
              {date === today ? "today" : dateLabel(date, true)}.
            </p>
            {tvMatches.map((match) => (
              <Link
                className="watch-pick"
                to={matchPath(match)}
                state={{ match }}
                key={match.id}
              >
                <span className="watch-time">
                  {match.time}
                  <span>UK</span>
                </span>
                <strong>
                  {match.homeTeam}
                  <small>v</small>
                  {match.awayTeam}
                </strong>
                <span className="watch-channel">
                  {ukChannels(match.tvChannels)
                    .map((channel) => channel.name)
                    .join(" · ")}
                </span>
              </Link>
            ))}
            {!tvMatches.length && (
              <p className="watch-empty">
                {loading
                  ? "Finding broadcasts…"
                  : "No upcoming UK broadcasts listed for this selection."}
              </p>
            )}
            <Link className="text-link" to={`/tv?date=${date}`}>
              Full TV guide <span aria-hidden="true">→</span>
            </Link>
            <div className="sidebar-note">
              <span className="eyebrow">Follow the football</span>
              <p>From the first whistle to the last kick.</p>
              <Link to="/tables">Explore the tables →</Link>
            </div>
          </aside>
        )}
      </div>
    </>
  );
}
