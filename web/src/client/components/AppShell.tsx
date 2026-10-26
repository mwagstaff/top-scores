import { Link, NavLink, useLocation } from "react-router-dom";
import { useEffect, useState, type PropsWithChildren } from "react";
import { competitionPath, dateLabel, localDate, validDate } from "../football";
import { useInitialSeed } from "../bootstrap";
import { normalizeMatch } from "../api";
import { loadDay } from "../dayStore";
import { countCompetitions } from "../football";
import { loadCompetitions, type Competition } from "../catalog";
import { competitionLogo } from "../competitionLogos";
import { isMatchAbandoned, isMatchFinished, isMatchLive } from "../matchState";
import { ScrollPosition } from "./ScrollPosition";

export function AppShell({ children }: PropsWithChildren) {
  const location = useLocation();
  const [competitions, setCompetitions] = useState<Competition[]>([]);
  const [catalogError, setCatalogError] = useState(false);
  useEffect(() => { let active = true; loadCompetitions().then(items => { if (active) setCompetitions(items); }).catch(() => { if (active) setCatalogError(true); }); return () => { active = false; }; }, []);
  const seed = useInitialSeed();
  const requestedDate = new URLSearchParams(location.search).get("date");
  const selectedDate = validDate(requestedDate) ? requestedDate : null;
  const activityDate = selectedDate || localDate();
  const activityDateLabel = activityDate === localDate() ? "today" : `on ${dateLabel(activityDate)}`;
  const [activity, setActivity] = useState(() => {
    const matches = seed?.date === activityDate && seed.matches
      ? seed.matches.map(normalizeMatch)
      : [];
    return {
      date: activityDate,
      counts: countCompetitions(matches),
      liveCounts: countCompetitions(matches.filter(isMatchLive)),
      finishedCounts: countCompetitions(matches.filter((match) => isMatchFinished(match) || isMatchAbandoned(match))),
    };
  });
  useEffect(() => {
    let cancelled = false,
      running = false;
    const update = async () => {
      if (document.visibilityState !== "visible" || running || cancelled) return;
      running = true;
      const date = selectedDate || localDate();
      try {
        let day = await loadDay(date);
        while (day.hasMore && !cancelled)
          day = await loadDay(date, false, true, day.page + 1);
        if (!cancelled)
          setActivity({
            date,
            counts: countCompetitions(day.matches),
            liveCounts: countCompetitions(day.matches.filter(isMatchLive)),
            finishedCounts: countCompetitions(day.matches.filter((match) => isMatchFinished(match) || isMatchAbandoned(match))),
          });
      } catch {
        /* Keep the last known activity if a refresh fails. */
      } finally {
        running = false;
      }
    };
    void update();
    const timer = window.setInterval(update, 60_000);
    document.addEventListener("visibilitychange", update);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", update);
    };
  }, [selectedDate]);
  useEffect(() => {
    document.documentElement.dataset.theme = "dark";
  }, []);
  const nav = [
    { to: "/", label: "Scores & fixtures", mark: "◷" },
    { to: "/tv", label: "On TV", mark: "▣" },
    { to: "/results", label: "Results", mark: "↙" },
    { to: "/tables", label: "Tables", mark: "≡" },
  ];
  return (
    <div className="football-app" onMouseOver={prefetchTeam} onFocus={prefetchTeam}>
      <ScrollPosition />
      <a className="skip-link" href="#main-content">
        Skip to matches
      </a>
      <header className="site-header">
        <div className="site-header-inner">
          <Link
            to="/"
            className="wordmark"
            aria-label="Top Scores home"
          >
            <img
              src="/generated-assets/app-icon.png?v=2"
              width="44"
              height="44"
              alt=""
            />
            <span>Top Scores</span>
          </Link>
          <nav className="main-nav" aria-label="Primary">
            {nav.map((item) => (
              <NavLink key={item.to} to={item.to}>
                <span aria-hidden="true">{item.mark}</span>
                <span>{item.label}</span>
              </NavLink>
            ))}
          </nav>
        </div>
      </header>
      <div className="site-layout">
        <aside className="league-rail" aria-label="Competitions">
          <span className="eyebrow">Competitions</span>
          {catalogError && <p>Competitions unavailable. Reload to retry.</p>}
          {competitions.map(({ id, name, aliases }, index) => {
            const names = [name, ...aliases];
            const count = activity.date === activityDate
              ? names.reduce((total, alias) => total + (activity.counts[alias] || 0), 0)
              : 0;
            const live = names.some((alias) => (activity.liveCounts[alias] || 0) > 0);
            const finished = count > 0 && names.reduce((total, alias) => total + (activity.finishedCounts[alias] || 0), 0) === count;
            return (
              <Link
                key={name}
                className={
                  location.pathname === competitionPath(name) ? "selected" : ""
                }
                to={`${competitionPath(name)}${selectedDate ? `?date=${selectedDate}` : ""}`}
              >
                <span className="league-number">
                  {competitionLogo(id, name) ? <img src={competitionLogo(id, name)} width="26" height="26" alt="" loading="lazy" /> : String(index + 1).padStart(2, "0")}
                </span>
                <span className="league-name">{name.replace("UEFA ", "")}</span>
                {count > 0 && (
                  <span
                    className={`competition-count${live ? " is-live" : finished ? " is-finished" : ""}`}
                    aria-label={`${count} ${count === 1 ? "match" : "matches"} ${activityDateLabel}${live ? ", live match in progress" : finished ? ", all matches finished" : ""}`}
                    title={`${count} ${count === 1 ? "match" : "matches"} ${activityDateLabel}${live ? " · live match in progress" : finished ? " · all matches finished" : ""}`}
                  >
                    {count}
                  </span>
                )}
              </Link>
            );
          })}
        </aside>
        <main id="main-content" className="site-main" tabIndex={-1}>
          {children}
        </main>
      </div>
      <footer className="site-footer">
        <span>Top Scores</span>
        <a href="https://skynolimit.dev/">Developed by Sky No Limit</a>
      </footer>
    </div>
  );
}

function prefetchTeam(event: { target: EventTarget | null }) {
  const link = (event.target as HTMLElement)?.closest?.('a[href^="/teams/"]');
  if (!link) return;
  const url = new URL(link.getAttribute('href')!, window.location.origin);
  void import('../teamData').then(({ loadTeam }) => loadTeam(decodeURIComponent(url.pathname.slice(7)), url.searchParams.get('id') || undefined));
  void import('./TeamPage');
}
