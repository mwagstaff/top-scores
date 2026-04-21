import { NavLink } from "react-router-dom";
import { type PropsWithChildren, useEffect, useState } from "react";

// ── Theme management ─────────────────────────────────────────────
// Three states: "auto" follows system preference, "light"/"dark" are explicit.
// Persisted to localStorage so the choice survives page reloads.

type Theme = "auto" | "light" | "dark";

function useTheme() {
  const [theme, setTheme] = useState<Theme>(() => {
    return (localStorage.getItem("ts-theme") as Theme) ?? "auto";
  });

  useEffect(() => {
    const root = document.documentElement;
    if (theme === "auto") {
      root.removeAttribute("data-theme");
    } else {
      root.setAttribute("data-theme", theme);
    }
    localStorage.setItem("ts-theme", theme);
  }, [theme]);

  // Cycle: auto → dark → light → auto
  // (Starting with dark so that a single tap from auto gives explicit dark)
  const toggle = () =>
    setTheme((current) => {
      if (current === "auto") return "dark";
      if (current === "dark") return "light";
      return "auto";
    });

  return { theme, toggle };
}

// ── Nav tab definitions ──────────────────────────────────────────

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

// ── Theme toggle icon ────────────────────────────────────────────

function ThemeIcon({ theme }: { theme: Theme }) {
  if (theme === "light") {
    // Sun – switch to auto
    return (
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <circle cx="12" cy="12" r="4" />
        <path d="M12 2v2M12 20v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M2 12h2M20 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42" />
      </svg>
    );
  }
  if (theme === "dark") {
    // Moon – switch to light
    return (
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <path d="M21 12.79A9 9 0 1 1 11.21 3a7 7 0 0 0 9.79 9.79Z" />
      </svg>
    );
  }
  // Auto – half moon / system
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="9" />
      <path d="M12 3v18" />
      <path d="M12 3a9 9 0 0 1 0 18Z" fill="currentColor" stroke="none" opacity="0.25" />
    </svg>
  );
}

function themeLabel(theme: Theme) {
  if (theme === "auto")  return "Appearance: system";
  if (theme === "dark")  return "Appearance: dark";
  return "Appearance: light";
}

// ── AppShell ─────────────────────────────────────────────────────

export function AppShell({ children }: PropsWithChildren) {
  const { theme, toggle } = useTheme();

  return (
    <div className="app-shell">
      {/* Sticky header: brand · tabs (desktop) · theme toggle */}
      <header className="app-header">
        <div className="brand">
          <a href="/">
            <img src="/generated-assets/app-icon.png" alt="" className="brand-logo" />
          </a>
          <span className="brand-name">Top Scores</span>
        </div>

        {/* Desktop navigation – hidden on mobile via CSS */}
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

        <button
          type="button"
          className="theme-toggle"
          onClick={toggle}
          aria-label={themeLabel(theme)}
          title={themeLabel(theme)}
        >
          <ThemeIcon theme={theme} />
        </button>
      </header>

      <main className="app-content">{children}</main>

      {/* Mobile bottom dock – hidden on desktop via CSS */}
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
