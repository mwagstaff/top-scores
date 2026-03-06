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
  type Preferences,
} from "./types";

const storageKey = "top-scores.web.preferences.v1";

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

    return normalizePreferences(JSON.parse(raw) as Partial<Preferences>);
  } catch {
    return defaultPreferences;
  }
}
