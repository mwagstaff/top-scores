import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useState,
  type PropsWithChildren,
} from "react";
import {
  defaultPreferences,
  normalizePreferences,
  type MatchGroupSortOrder,
  type Preferences,
} from "./types";

const storageKey = "top-scores.web.preferences.v1";
const legacyDefaultPreferences = normalizePreferences({
  selectedLeagues: [
    "Premier League",
    "FIFA World Cup 2026",
    "UEFA Champions League",
    "UEFA Conference League",
    "UEFA Europa League",
  ],
  selectedChannels: ["Amazon (all)", "BBC (all)", "ITV (all)", "Sky (all)", "TNT (all)"],
  competitionFilterEnabled: true,
  channelFilterEnabled: true,
  englishPremierLeagueTeamsOnly: false,
  refreshIntervalMinutes: 10,
  matchGroupSortOrder: "alphabetical" as MatchGroupSortOrder,
});

interface PreferencesContextValue {
  preferences: Preferences;
  setPreferences: (updater: Partial<Preferences> | ((current: Preferences) => Preferences)) => void;
  resetPreferences: () => void;
}

const PreferencesContext = createContext<PreferencesContextValue | null>(null);

export function PreferencesProvider({ children }: PropsWithChildren) {
  const [preferences, setPreferencesState] = useState<Preferences>(() => loadPreferences());

  useEffect(() => {
    window.localStorage.setItem(storageKey, JSON.stringify(preferences));
  }, [preferences]);

  const value = useMemo<PreferencesContextValue>(
    () => ({
      preferences,
      setPreferences(updater) {
        setPreferencesState((current) => {
          if (typeof updater === "function") {
            return normalizePreferences(updater(current));
          }
          return normalizePreferences({ ...current, ...updater });
        });
      },
      resetPreferences() {
        setPreferencesState(defaultPreferences);
      },
    }),
    [preferences]
  );

  return <PreferencesContext.Provider value={value}>{children}</PreferencesContext.Provider>;
}

export function usePreferences() {
  const context = useContext(PreferencesContext);
  if (!context) {
    throw new Error("usePreferences must be used inside a PreferencesProvider");
  }

  return context;
}

function loadPreferences(): Preferences {
  if (typeof window === "undefined") {
    return defaultPreferences;
  }

  try {
    const raw = window.localStorage.getItem(storageKey);
    if (!raw) {
      return defaultPreferences;
    }

    const parsed = normalizePreferences(JSON.parse(raw) as Partial<Preferences>);
    return preferencesEqual(parsed, legacyDefaultPreferences) ? defaultPreferences : parsed;
  } catch {
    return defaultPreferences;
  }
}

function preferencesEqual(left: Preferences, right: Preferences): boolean {
  return (
    left.competitionFilterEnabled === right.competitionFilterEnabled &&
    left.channelFilterEnabled === right.channelFilterEnabled &&
    left.englishPremierLeagueTeamsOnly === right.englishPremierLeagueTeamsOnly &&
    left.refreshIntervalMinutes === right.refreshIntervalMinutes &&
    left.matchGroupSortOrder === right.matchGroupSortOrder &&
    arrayEqual(left.selectedLeagues, right.selectedLeagues) &&
    arrayEqual(left.selectedChannels, right.selectedChannels)
  );
}

function arrayEqual(left: string[], right: string[]): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}
