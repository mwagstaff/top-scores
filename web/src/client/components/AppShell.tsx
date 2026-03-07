import { NavLink } from "react-router-dom";
import type { PropsWithChildren } from "react";

const tabs = [
  {
    to: "/fixtures",
    label: "Fixtures",
    icon: (
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <path d="M7 2v3M17 2v3M4 8h16M5 5h14a1 1 0 0 1 1 1v13a3 3 0 0 1-3 3H7a3 3 0 0 1-3-3V6a1 1 0 0 1 1-1Z" />
      </svg>
    ),
  },
  {
    to: "/results",
    label: "Results",
    icon: (
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <path d="M12 6v6l4 2M21 12a9 9 0 1 1-9-9a9 9 0 0 1 9 9Z" />
      </svg>
    ),
  },
  {
    to: "/tables",
    label: "Tables",
    icon: (
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <path d="M4 5h16v14H4zM4 10h16M9 5v14M15 5v14" />
      </svg>
    ),
  },
  {
    to: "/preferences",
    label: "Preferences",
    icon: (
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <path d="M4 7h8M4 17h5M15 17h5M12 7h8M10 4v6M14 14v6" />
      </svg>
    ),
  },
];

export function AppShell({ children }: PropsWithChildren) {
  return (
    <div className="app-shell">
      <header className="app-header">
        <div className="brand">
          <img src="/generated-assets/app-icon.png" alt="" className="brand-logo" />
          <div>
            <div className="brand-kicker">Top Scores</div>
            <h1>Web client</h1>
          </div>
        </div>
        <p className="brand-copy">
          Fixtures, results, tables, and local browser preferences with the same core model as the iOS app.
        </p>
        <nav className="tab-strip tab-strip-desktop" aria-label="Primary">
          {tabs.map((tab) => (
            <NavLink
              key={tab.to}
              to={tab.to}
              className={({ isActive }) => `tab-link${isActive ? " is-active" : ""}`}
            >
              {tab.icon}
              <span>{tab.label}</span>
            </NavLink>
          ))}
        </nav>
      </header>

      <main className="app-content">{children}</main>

      <nav className="tab-strip tab-strip-mobile" aria-label="Primary">
        {tabs.map((tab) => (
          <NavLink
            key={tab.to}
            to={tab.to}
            className={({ isActive }) => `tab-link${isActive ? " is-active" : ""}`}
          >
            {tab.icon}
            <span>{tab.label}</span>
          </NavLink>
        ))}
      </nav>
    </div>
  );
}
