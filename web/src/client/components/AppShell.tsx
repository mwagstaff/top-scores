import { Link, NavLink, useLocation } from "react-router-dom";
import { useEffect, type PropsWithChildren } from "react";
import { competitionPath, featuredCompetitions } from "../football";
import { ScrollPosition } from "./ScrollPosition";

export function AppShell({ children }: PropsWithChildren) {
  const location = useLocation();
  useEffect(() => {
    document.documentElement.dataset.theme = "dark";
  }, []);
  const nav = [
    { to: "/fixtures", label: "Scores & fixtures", mark: "◷" },
    { to: "/tv", label: "On UK TV", mark: "▣" },
    { to: "/results", label: "Results", mark: "↙" },
    { to: "/tables", label: "Tables", mark: "≡" },
  ];
  return (
    <div className="football-app">
      <ScrollPosition />
      <a className="skip-link" href="#main-content">
        Skip to matches
      </a>
      <header className="site-header">
        <div className="site-header-inner">
          <Link
            to="/fixtures"
            className="wordmark"
            aria-label="Top Scores home"
          >
            <img
              src="/generated-assets/app-icon.png"
              width="36"
              height="36"
              alt=""
            />
            <span>
              top<span className="wordmark-light">scores</span>
              <span className="brand-period">.</span>
            </span>
          </Link>
          <nav className="main-nav" aria-label="Primary">
            {nav.map((item) => (
              <NavLink key={item.to} to={item.to}>
                <span aria-hidden="true">{item.mark}</span>
                <span>{item.label}</span>
              </NavLink>
            ))}
          </nav>
          <Link
            className="settings-link"
            to="/preferences"
            aria-label="Preferences"
          >
            ⚙
          </Link>
          <span className="edition-label">UK EDITION</span>
        </div>
      </header>
      <div className="site-layout">
        <aside className="league-rail" aria-label="Competitions">
          <span className="eyebrow">The competitions</span>
          {featuredCompetitions.map((name, index) => (
            <Link
              key={name}
              className={
                location.pathname === competitionPath(name) ? "selected" : ""
              }
              to={competitionPath(name)}
            >
              <span className="league-number">
                {String(index + 1).padStart(2, "0")}
              </span>
              <span>{name.replace("UEFA ", "")}</span>
            </Link>
          ))}
          <div className="rail-note">
            <span className="live-dot" /> Football, as it happens.
            <small>Scores, fixtures and where to watch in the UK.</small>
          </div>
        </aside>
        <main id="main-content" className="site-main" tabIndex={-1}>
          {children}
        </main>
      </div>
      <footer className="site-footer">
        <span>
          top scores<span className="brand-period">.</span>
        </span>
        <span>Football first. All times UK.</span>
        <Link to="/preferences">Preferences</Link>
      </footer>
    </div>
  );
}
