import { useSyncExternalStore } from "react";

export type MatchScope = "all" | "top" | "epl";
export type MatchViewPreferences = {
  scope: MatchScope;
  showDetails: boolean;
  showStats: boolean;
};

const storageKey = "top-scores.match-view.v1";
const defaults: MatchViewPreferences = { scope: "all", showDetails: false, showStats: true };
let cachedRaw: string | null | undefined;
let cached: MatchViewPreferences = defaults;
let storageUnavailable = false;
const listeners = new Set<() => void>();

function parse(raw: string | null): MatchViewPreferences {
  if (!raw) return defaults;
  try {
    const value = JSON.parse(raw);
    return {
      scope: value.scope === "top" || value.scope === "epl" ? value.scope : "all",
      showDetails: value.showDetails === true,
      showStats: value.showStats !== false,
    };
  } catch {
    return defaults;
  }
}

function snapshot(): MatchViewPreferences {
  if (storageUnavailable || typeof localStorage === "undefined") return cached;
  try {
    const raw = localStorage.getItem(storageKey);
    if (raw !== cachedRaw) {
      cachedRaw = raw;
      cached = parse(raw);
    }
  } catch {
    storageUnavailable = true;
  }
  return cached;
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  const onStorage = (event: StorageEvent) => {
    if (event.key === storageKey || event.key === null) listener();
  };
  if (typeof window !== "undefined") window.addEventListener("storage", onStorage);
  return () => {
    listeners.delete(listener);
    if (typeof window !== "undefined") window.removeEventListener("storage", onStorage);
  };
}

export function useMatchViewPreferences(): MatchViewPreferences {
  return useSyncExternalStore(subscribe, snapshot, () => defaults);
}

export function readMatchViewPreferences(): MatchViewPreferences {
  return snapshot();
}

export function saveMatchViewPreferences(changes: Partial<MatchViewPreferences>) {
  const next = { ...snapshot(), ...changes };
  cached = next;
  cachedRaw = JSON.stringify(next);
  if (!storageUnavailable) {
    try { localStorage.setItem(storageKey, cachedRaw); } catch { storageUnavailable = true; }
  }
  listeners.forEach(listener => listener());
}
