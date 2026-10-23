import { useEffect, useMemo, useState, useRef } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { competitionDateCounts, preferredCompetitionDate } from "../competitionDates";
import { competitionLogo } from "../competitionLogos";
import { loadCompetitions } from "../catalog";
import { cachedDay, loadDay } from "../dayStore";
import {
  competitionPath,
  rankedTVMatches,
  dateLabel,
  matchPath,
  moveDate,
  ukChannels,
  ukDate,
  validDate,
} from "../football";
import { isMatchFinished } from "../matchState";
import { usePreferences } from "../preferences";
import { BroadcastChannels, FixtureRow, WatchabilityRating } from "./FixtureRow";
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
  const dateRail = useRef<HTMLDivElement>(null);
  const [params, setParams] = useSearchParams();
  const [competitionAliases, setCompetitionAliases] = useState<string[]>([]);
  useEffect(() => { let active = true; if (competition) loadCompetitions().then(items => { if (active) { const entry = items.find(item => item.name === competition || item.aliases.includes(competition)); setCompetitionAliases(entry ? [entry.name, ...entry.aliases] : []); } }).catch(() => {}); return () => { active = false; }; }, [competition]);
  const { preferences } = usePreferences();
  const today = ukDate();
  const seed = useInitialSeed();
  const [todayFinished, setTodayFinished] = useState<boolean | undefined>(() =>
    seed?.date === today && seed.matches ? seed.matches.map(normalizeMatch).some(isMatchFinished) : undefined);
  useEffect(() => {
    if (mode !== "results") return;
    let cancelled = false;
    const check = async () => {
      if (document.visibilityState !== "visible") return;
      try {
        let day = await loadDay(today);
        while (day.hasMore && !day.matches.some(isMatchFinished) && !cancelled)
          day = await loadDay(today, false, true, day.page + 1);
        if (!cancelled) setTodayFinished(day.matches.some(isMatchFinished));
      } catch { /* Do not hide today when its status is unknown. */ }
    };
    void check();
    const timer = window.setInterval(check, 60_000);
    return () => { cancelled = true; window.clearInterval(timer); };
  }, [mode, today]);
  const latestResultDate = todayFinished === false ? moveDate(today, -1) : today;
  const requestedDate = params.get("date");
  const candidateDate = validDate(requestedDate) ? requestedDate : mode === "results" ? latestResultDate : today;
  const date = tv && candidateDate < today ? today : mode === "results" && candidateDate > latestResultDate ? latestResultDate : candidateDate;
  useEffect(() => {
    if (validDate(requestedDate) && requestedDate !== date) {
      setParams(current => { const next = new URLSearchParams(current); next.set("date", date); return next; }, { replace: true });
    }
  }, [requestedDate, date, setParams]);
  const scope = ["top", "epl"].includes(params.get("scope") || "")
    ? params.get("scope")!
    : "all";
  const dayScope = competition || scope === "all" ? false : scope;
  const filteredScope = Boolean(dayScope);
  const filter =
    tv ? "tv" : "all";

  const seededDay = useMemo(
    () =>
      !filteredScope && seed?.date === date && seed.matches
        ? {
            matches: seed.matches.map(normalizeMatch),
            fetchedAt: seed.fetchedAt,
            page: 1,
            hasMore: Boolean(seed.hasMore),
            lastUpdated: seed.lastUpdated || null,
            totalCount: seed.matches.length,
          }
        : undefined,
    [seed, date, filteredScope],
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
  useEffect(() => {
    if (!competition || requestedDate) return;
    let active = true;
    void loadCompetitions().then(items => {
      const entry = items.find(item => item.name === competition || item.aliases.includes(competition));
      return preferredCompetitionDate([...new Set([competition, ...(entry ? [entry.name, ...entry.aliases] : [])])], today, mode === 'results');
    }).then(nextDate => {
      if (active && nextDate) setParams(current => { if (current.has('date')) return current; const next = new URLSearchParams(current); next.set('date', nextDate); return next; }, { replace: true });
    }).catch(() => {});
    return () => { active = false; };
  }, [competition, requestedDate, today, mode, setParams]);
  const [dateCountsReady, setDateCountsReady] = useState(false);
  const [dateCounts, setDateCounts] = useState<Record<string, number>>({});
  useEffect(() => {
    let active = true;
    setDateCounts({});
    setDateCountsReady(false);
    if (competition) {
      const names = [...new Set([competition, ...competitionAliases])];
      void competitionDateCounts(names, moveDate(date, -15), moveDate(date, 15), mode === 'results')
        .then(counts => { if (active) { setDateCounts(counts); setDateCountsReady(true); } }).catch(() => {});
    }
    return () => { active = false; };
  }, [competition, competitionAliases, date, mode]);
  useEffect(() => {
    const rail = dateRail.current;
    const selected = rail?.querySelector<HTMLElement>('[aria-pressed="true"]');
    if (rail && selected) rail.scrollLeft += selected.getBoundingClientRect().left - rail.getBoundingClientRect().left - (rail.clientWidth - selected.clientWidth) / 2;
  }, [date]);
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
        if (competition && match.league !== competition && !competitionAliases.includes(match.league)) return false;
        const legacyComps = params.get("comps")?.split(",");
        if (legacyComps && !legacyComps.includes(match.league)) return false;
        if (mode === "results" && !isMatchFinished(match)) return false;
        if (tv && isMatchFinished(match)) return false;
        return true;
      }),
    [payload, competition, competitionAliases, scope, mode, tv, preferences, params],
  );
  const matches = useMemo(
    () =>
      relevant.filter((match) => {
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
  const tvMatches = rankedTVMatches(relevant).slice(0, 3);
  const otherTVMatches =
    relevant.filter((match) => ukChannels(match.tvChannels).length).length -
    tvMatches.length;
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
        <header className="football-heading compact-heading">
          <StadiumBackdrop ready={Boolean(payload)} homes={mode === "fixtures" && !tv ? relevant.map(match => ({ name: match.homeTeam, id: match.homeTeamId })) : undefined} />
          <h1>
            {tv
              ? "Football on TV"
              : mode === "results"
                ? "Results"
                : "Scores & fixtures"}
          </h1>
        </header>
      )}
      <div
        className={`scores-layout${mode === "results" ? " results-layout" : ""}`}
      >
        <section
          className={`scores-primary${mode === "fixtures" && !tv ? " fixtures-with-side-tv" : ""}`}
          aria-label={
            competition ? `${competition} matches` : "Football matches"
          }
        >
          <div className="date-navigator">
            <button
              aria-label="Previous day"
              disabled={tv && date <= today}
              onClick={() => change({ date: moveDate(date, -1) })}
            >
              ←
            </button>
            <div ref={dateRail} className="date-shortcuts" aria-label="Match dates">
              {Array.from({ length: 31 }, (_, index) => index - 15).map((offset) => {
                const day = moveDate(date, offset);
                if ((tv && day < today) || (mode === "results" && day > latestResultDate)) return null;
                const instant = new Date(`${day}T12:00:00Z`);
                return (
                  <button
                    key={day}
                    disabled={Boolean(competition && (!dateCountsReady || !dateCounts[day]))}
                    className={`date-offset-${Math.abs(offset)}`}
                    aria-label={`${dateLabel(day)}${dateCounts[day] ? `, ${dateCounts[day]} ${dateCounts[day] === 1 ? "match" : "matches"}` : ""}`}
                    aria-pressed={day === date}
                    onClick={() => change({ date: day })}
                  >
                    <span>
                      {day === today
                        ? "Today"
                        : instant.toLocaleDateString("en-GB", {
                            weekday: "short",
                            timeZone: "Europe/London",
                          })}
                    </span>
                    <span>
                      {instant.toLocaleDateString("en-US", {
                        month: "short",
                        day: "numeric",
                        timeZone: "Europe/London",
                      })}
                    </span>
                    {dateCounts[day] > 0 && <span className="date-count" aria-hidden="true">{dateCounts[day]}</span>}
                  </button>
                );
              })}
            </div>
            <button
              aria-label="Next day"
              disabled={mode === "results" && date >= latestResultDate}
              onClick={() => change({ date: moveDate(date, 1) })}
            >
              →
            </button>
            <label className="date-picker">
              <span className="sr-only">Choose a date</span>
              <input
                aria-label="Choose a date"
                type="date"
                min={tv ? today : undefined}
                max={mode === "results" ? latestResultDate : undefined}
                value={date}
                onChange={(e) => {
                  if (validDate(e.target.value) && (!tv || e.target.value >= today) && (mode !== "results" || e.target.value <= latestResultDate))
                    change({ date: e.target.value });
                }}
              />
            </label>
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
              <div className="scope-toggles" role="group" aria-label="Competition scope">
                {[["all", "All competitions"], ["top", "Show top teams"], ["epl", "Show Premier League teams"]].map(([value, label]) => <button key={value} aria-pressed={scope === value} onClick={() => change({ scope: value, comps: "" })}>{value === 'top' && <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" aria-hidden="true"><path d="M7 3h10v5a5 5 0 0 1-10 0V3Zm0 2H3v3a4 4 0 0 0 5 4m9-7h4v3a4 4 0 0 1-5 4M12 13v6m-5 2h10m-8-2h6" /></svg>}{value === 'epl' && <img src="/competition-logos/FantasyPremierLeagueLion.webp" width="22" height="22" alt="" />}<span>{label}</span></button>)}
              </div>
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
            groups.map(([league, games]) => {
              const logo = competitionLogo(games[0].leagueId ?? "", league);
              return (
                <section className="fixture-competition" key={league}>
                  <div className="competition-heading">
                    <Link to={competitionPath(league)}>
                      {logo ? (
                        <img className="competition-logo" src={logo} alt="" width="26" height="26" loading="lazy" />
                      ) : (
                        <span className="competition-mark" aria-hidden="true">
                          {league
                            .replace(/^UEFA /, "")
                            .split(" ")
                            .slice(0, 2)
                            .map((w) => w[0])
                            .join("")}
                        </span>
                      )}
                      <h3>{league}</h3>
                      <span aria-hidden="true">↗</span>
                    </Link>
                    <span>{games.length}</span>
                  </div>
                  {games.map((match) => (
                    <FixtureRow
                      match={match}
                      key={match.id}
                      showBroadcast={mode !== "results"}
                      showRating={tv}
                    />
                  ))}
                </section>
              );
            })
          ) : (
            !error && (
              <div className="football-empty">
                <span aria-hidden="true">◷</span>
                <h3>
                  {query
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
            <span>
              {mode === "results"
                ? "All times UK"
                : "All times UK · TV listings may change"}
            </span>
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
        {!competition && mode !== "results" && (
          <aside className="watch-sidebar" aria-label="UK viewing guide">
            <h2>TV Guide</h2>
            {tvMatches.map((match) => (
              <div className="watch-pick" key={match.id}>
                <Link className="watch-pick-details" to={matchPath(match)} state={{ match }}>
                <span className="watch-time">
                  {match.time}
                  <span>UK</span>
                </span>
                <strong>
                  {match.homeTeam}
                  <small>v</small>
                  {match.awayTeam}
                </strong>
                <WatchabilityRating match={match} />
                </Link>
                <BroadcastChannels channels={ukChannels(match.tvChannels)} matchLabel={`${match.homeTeam} v ${match.awayTeam}`} />
              </div>
            ))}
            {!tvMatches.length && (
              <p className="watch-empty">
                {loading
                  ? "Finding broadcasts…"
                  : "No upcoming UK broadcasts listed for this selection."}
              </p>
            )}
            <Link className="text-link" to={`/tv?date=${date}`}>
              <span>
                Full TV Guide
                {!loading && (
                  <small className="guide-more-count">
                    {otherTVMatches}
                    {payload?.hasMore ? "+" : ""} more{" "}
                    {otherTVMatches === 1 ? "match" : "matches"}{" "}
                    {date === today ? "today" : `on ${dateLabel(date, true)}`}
                  </small>
                )}
              </span>
              <span aria-hidden="true">→</span>
            </Link>
          </aside>
        )}
      </div>
    </>
  );
}
