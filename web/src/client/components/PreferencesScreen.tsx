import { useEffect, useMemo, useState } from "react";
import { fetchChannels, fetchCompetitions } from "../api";
import { usePreferences } from "../preferences";
import {
  matchOrderOptions,
  type MatchGroupSortOrder,
} from "../types";

export function PreferencesScreen() {
  const { preferences, setPreferences, resetPreferences } = usePreferences();
  const [leagueSearch, setLeagueSearch] = useState("");
  const [channelSearch, setChannelSearch] = useState("");
  const [availableLeagues, setAvailableLeagues] = useState<string[]>([]);
  const [availableChannels, setAvailableChannels] = useState<string[]>([]);
  const [loadingLeagues, setLoadingLeagues] = useState(true);
  const [loadingChannels, setLoadingChannels] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    void Promise.all([
      fetchCompetitions()
        .then(setAvailableLeagues)
        .finally(() => setLoadingLeagues(false)),
      fetchChannels()
        .then(setAvailableChannels)
        .finally(() => setLoadingChannels(false)),
    ]).catch((caughtError) => {
      if (
        caughtError instanceof Error &&
        (caughtError.name === "AbortError" || caughtError.message.includes("aborted"))
      ) {
        return;
      }
      setError(caughtError instanceof Error ? caughtError.message : "Failed to load preferences data.");
    });
  }, []);

  const filteredLeagues = useMemo(
    () => filterOptions(availableLeagues, leagueSearch),
    [availableLeagues, leagueSearch]
  );
  const filteredChannels = useMemo(
    () => filterOptions(availableChannels, channelSearch),
    [availableChannels, channelSearch]
  );

  return (
    <section className="screen-panel">
      <header className="screen-header">
        <div>
          <div className="screen-kicker">Preferences</div>
          <h2>Preferences</h2>
          <p>
            Saved in browser storage for now. A future login plus Redis sync can reuse the same
            preference model.
          </p>
        </div>
        <button type="button" className="ghost-button" onClick={resetPreferences}>
          Reset defaults
        </button>
      </header>

      <div className="preferences-grid">
        <section className="settings-card">
          <h3>Refresh</h3>
          <label className="field-stack">
            <span>Refresh every {preferences.refreshIntervalMinutes} min</span>
            <input
              type="range"
              min={1}
              max={60}
              value={preferences.refreshIntervalMinutes}
              onChange={(event) =>
                setPreferences({ refreshIntervalMinutes: Number(event.target.value) })
              }
            />
          </label>
          <p className="field-copy">
            During active browsing, fixtures and results poll automatically at this interval.
          </p>
        </section>

        <section className="settings-card">
          <h3>Sorting</h3>
          <div className="choice-stack">
            {matchOrderOptions.map((option) => (
              <button
                key={option.value}
                type="button"
                className={`choice-row${
                  preferences.matchGroupSortOrder === option.value ? " is-selected" : ""
                }`}
                onClick={() =>
                  setPreferences({ matchGroupSortOrder: option.value as MatchGroupSortOrder })
                }
              >
                <div>
                  <strong>{option.label}</strong>
                  <p>{option.description}</p>
                </div>
              </button>
            ))}
          </div>
        </section>

        <section className="settings-card">
          <h3>Filters</h3>
          <label className="toggle-row">
            <span>Premier League teams only</span>
            <input
              type="checkbox"
              checked={preferences.englishPremierLeagueTeamsOnly}
              onChange={(event) =>
                setPreferences({ englishPremierLeagueTeamsOnly: event.target.checked })
              }
            />
          </label>
          <p className="field-copy">
            Restricts fixtures and results to matches involving BBC Premier League clubs.
          </p>

          <label className="toggle-row">
            <span>Enable competition filter</span>
            <input
              type="checkbox"
              checked={preferences.competitionFilterEnabled}
              onChange={(event) =>
                setPreferences({ competitionFilterEnabled: event.target.checked })
              }
            />
          </label>

          <label className="toggle-row">
            <span>Enable TV channel filter</span>
            <input
              type="checkbox"
              checked={preferences.channelFilterEnabled}
              onChange={(event) =>
                setPreferences({ channelFilterEnabled: event.target.checked })
              }
            />
          </label>
          <p className="field-copy">Channel filtering applies to Fixtures only, matching iOS.</p>
        </section>

        <section className="settings-card">
          <h3>Competitions</h3>
          {preferences.competitionFilterEnabled ? (
            <>
              <label className="field-stack">
                <span>Search competitions</span>
                <input
                  type="search"
                  value={leagueSearch}
                  onChange={(event) => setLeagueSearch(event.target.value)}
                  placeholder="Premier League, Champions League..."
                />
              </label>

              {loadingLeagues ? (
                <div className="inline-message">Loading competitions...</div>
              ) : (
                <SelectionList
                  options={filteredLeagues}
                  selected={preferences.selectedLeagues}
                  onToggle={(league) =>
                    setPreferences({
                      selectedLeagues: toggleSelection(preferences.selectedLeagues, league),
                    })
                  }
                  emptyMessage="No competitions loaded."
                />
              )}
            </>
          ) : (
            <div className="inline-message">
              Competition filtering is off. Fixtures and results include every competition.
            </div>
          )}
        </section>

        <section className="settings-card">
          <h3>Channels</h3>
          {preferences.channelFilterEnabled ? (
            <>
              <label className="field-stack">
                <span>Search channels</span>
                <input
                  type="search"
                  value={channelSearch}
                  onChange={(event) => setChannelSearch(event.target.value)}
                  placeholder="Sky Sports, TNT, BBC..."
                />
              </label>

              {loadingChannels ? (
                <div className="inline-message">Loading channels...</div>
              ) : (
                <SelectionList
                  options={filteredChannels}
                  selected={preferences.selectedChannels}
                  onToggle={(channel) =>
                    setPreferences({
                      selectedChannels: toggleSelection(preferences.selectedChannels, channel),
                    })
                  }
                  emptyMessage="No channels loaded."
                />
              )}
            </>
          ) : (
            <div className="inline-message">
              TV channel filtering is off. Fixture lists include every broadcast source.
            </div>
          )}
        </section>
      </div>

      {error && <div className="inline-message is-error">{error}</div>}
    </section>
  );
}

interface SelectionListProps {
  options: string[];
  selected: string[];
  onToggle: (value: string) => void;
  emptyMessage: string;
}

function SelectionList({ options, selected, onToggle, emptyMessage }: SelectionListProps) {
  if (options.length === 0) {
    return <div className="inline-message">{emptyMessage}</div>;
  }

  return (
    <div className="selection-list">
      {options.map((option) => {
        const isSelected = selected.includes(option);
        return (
          <button
            key={option}
            type="button"
            className={`selection-row${isSelected ? " is-selected" : ""}`}
            onClick={() => onToggle(option)}
          >
            <span>{option}</span>
            <span>{isSelected ? "Selected" : "Select"}</span>
          </button>
        );
      })}
    </div>
  );
}

function toggleSelection(current: string[], value: string): string[] {
  return current.includes(value)
    ? current.filter((item) => item !== value)
    : [...current, value].sort((left, right) =>
        left.localeCompare(right, undefined, { sensitivity: "base" })
      );
}

function filterOptions(options: string[], query: string): string[] {
  const normalized = query.trim().toLowerCase();
  if (normalized.length < 2) {
    return options;
  }

  return options.filter((option) => option.toLowerCase().includes(normalized));
}
