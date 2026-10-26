import { createContext, useContext } from "react";

export interface Seed {
  rendered?: boolean;
  locale?: string;
  date?: string;
  matches?: Record<string, unknown>[];
  match?: Record<string, unknown>;
  fetchedAt: number;
  hasMore?: boolean;
  lastUpdated?: string | null;
}
export const initialSeed: Seed | null = (() => {
  try {
    if (Intl.DateTimeFormat().resolvedOptions().timeZone !== "Europe/London") return null;
    const seed: Seed | null = JSON.parse(
      document.getElementById("football-seed")?.textContent || "null",
    );
    if (seed?.rendered && seed.locale !== Intl.DateTimeFormat().resolvedOptions().locale) return null;
    return seed;
  } catch {
    return null;
  }
})();

export const SeedContext = createContext<Seed | null>(initialSeed);
export const useInitialSeed = () => useContext(SeedContext);
