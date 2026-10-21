import { createContext, useContext } from "react";

export interface Seed {
  rendered?: boolean;
  date?: string;
  matches?: Record<string, unknown>[];
  match?: Record<string, unknown>;
  fetchedAt: number;
  hasMore?: boolean;
  lastUpdated?: string | null;
}
export const initialSeed: Seed | null = (() => {
  try {
    return JSON.parse(
      document.getElementById("football-seed")?.textContent || "null",
    );
  } catch {
    return null;
  }
})();

export const SeedContext = createContext<Seed | null>(initialSeed);
export const useInitialSeed = () => useContext(SeedContext);
