import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { fetchLeagueTables } from "../api";
import type { LeagueTable, Match } from "../types";

interface PositionEntry {
  id: string;
  leagueID: string;
  teamName: string;
  position: number;
}

// Shown directly below the live score row in the expanded match panel: each
// team currently in a tracked league table gets a tappable chip with its
// current position, jumping to that team's row on the Tables screen.
export function MatchTeamLeaguePositionsLink({ match }: { match: Match }) {
  const navigate = useNavigate();
  const [entries, setEntries] = useState<PositionEntry[]>([]);

  useEffect(() => {
    const controller = new AbortController();

    fetchLeagueTables(controller.signal)
      .then((payload) => {
        if (controller.signal.aborted) return;
        setEntries(resolveEntries(payload.leagues, match));
      })
      .catch(() => {
        if (!controller.signal.aborted) setEntries([]);
      });

    return () => controller.abort();
  }, [match.league, match.homeTeam, match.awayTeam]);

  if (entries.length === 0) {
    return null;
  }

  return (
    <div className="match-league-position-links">
      {entries.map((entry) => (
        <button
          key={entry.id}
          type="button"
          className="match-league-position-chip"
          onClick={() =>
            navigate(`/tables?league=${encodeURIComponent(entry.leagueID)}&team=${encodeURIComponent(entry.teamName)}`)
          }
        >
          <span className="match-league-position-team">{entry.teamName}</span>
          <span className="match-league-position-rank">{ordinal(entry.position)}</span>
          <svg className="match-league-position-chevron" viewBox="0 0 20 20" aria-hidden="true">
            <path d="m7 4 6 6-6 6" />
          </svg>
        </button>
      ))}
    </div>
  );
}

function resolveEntries(leagues: LeagueTable[], match: Match): PositionEntry[] {
  const league = leagues.find(
    (candidate) => candidate.leagueName.localeCompare(match.league, undefined, { sensitivity: "base" }) === 0
  );
  if (!league) return [];

  const allRows = league.rows.length > 0 ? league.rows : league.groups.flatMap((group) => group.rows);

  return [match.homeTeam, match.awayTeam]
    .map((teamName) => {
      const row = allRows.find(
        (candidate) => candidate.team.localeCompare(teamName, undefined, { sensitivity: "base" }) === 0
      );
      if (!row) return null;
      return {
        id: `${league.leagueID}-${teamName}`,
        leagueID: league.leagueID,
        teamName,
        position: row.position,
      };
    })
    .filter((entry): entry is PositionEntry => entry !== null);
}

function ordinal(value: number): string {
  const remainder100 = value % 100;
  if (remainder100 >= 11 && remainder100 <= 13) {
    return `${value}th`;
  }
  switch (value % 10) {
    case 1: return `${value}st`;
    case 2: return `${value}nd`;
    case 3: return `${value}rd`;
    default: return `${value}th`;
  }
}
