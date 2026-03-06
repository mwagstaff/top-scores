import { useMemo, useState } from "react";
import {
  aggregateSummary,
  displayStatus,
  isMatchFinished,
  isMatchLive,
  parseKickoff,
} from "../matchGrouping";
import type { Match } from "../types";

interface MatchCardProps {
  match: Match;
  highlightToday?: boolean;
}

export function MatchCard({ match, highlightToday = false }: MatchCardProps) {
  const [homeLogoMissing, setHomeLogoMissing] = useState(false);
  const [awayLogoMissing, setAwayLogoMissing] = useState(false);

  const kickoffText = useMemo(() => {
    const kickoff = parseKickoff(match);
    if (!kickoff) {
      return `${match.date} ${match.time}`;
    }

    return new Intl.DateTimeFormat(undefined, {
      hour: "2-digit",
      minute: "2-digit",
      weekday: "short",
      month: "short",
      day: "numeric",
    }).format(kickoff);
  }, [match]);

  const status = displayStatus(match);
  const aggregateText = aggregateSummary(match);
  const isLive = isMatchLive(match);
  const showBroadcastDetails = !isMatchFinished(match);

  return (
    <article className={`match-card${highlightToday ? " is-highlighted" : ""}`}>
      <div className="match-teams">
        <TeamBadge
          teamName={match.homeTeam}
          missing={homeLogoMissing}
          onMissing={() => setHomeLogoMissing(true)}
        />
        <div className="match-scoreboard">
          <div className="match-line">
            <div className="team-name team-name-home">{match.homeTeam}</div>
            <div className={`status-pill${isLive ? " is-live" : ""}`}>
              {typeof match.homeScore === "number" && <span>{match.homeScore}</span>}
              <strong>{status}</strong>
              {typeof match.awayScore === "number" && <span>{match.awayScore}</span>}
            </div>
            <div className="team-name team-name-away">{match.awayTeam}</div>
          </div>

          {aggregateText && <div className="match-meta-center">({aggregateText})</div>}
          {match.penaltyResult && <div className="match-meta-center">{match.penaltyResult}</div>}
        </div>
        <TeamBadge
          teamName={match.awayTeam}
          missing={awayLogoMissing}
          onMissing={() => setAwayLogoMissing(true)}
        />
      </div>

      <div className="match-footer">
        <div className="match-kickoff">{kickoffText}</div>
        {showBroadcastDetails && (
          <div className="broadcast-wrap">
            <div className="broadcast-text">
              {match.tvChannels.length > 0 ? match.tvChannels.join(" • ") : "TV TBA"}
            </div>
            <div className="broadcast-logos" aria-hidden="true">
              {match.tvChannels.map((channel) => (
                <img
                  key={`${match.id}-${channel}`}
                  src={`/logos/tv/${encodeURIComponent(channel)}`}
                  alt=""
                  onError={(event) => {
                    event.currentTarget.style.display = "none";
                  }}
                />
              ))}
            </div>
          </div>
        )}
      </div>
    </article>
  );
}

interface TeamBadgeProps {
  teamName: string;
  missing: boolean;
  onMissing: () => void;
}

function TeamBadge({ teamName, missing, onMissing }: TeamBadgeProps) {
  const initials = teamName
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((token) => token[0]?.toUpperCase() ?? "")
    .join("");

  if (missing) {
    return <div className="team-logo-fallback">{initials || "?"}</div>;
  }

  return (
    <img
      className="team-logo"
      src={`/logos/team/${encodeURIComponent(teamName)}`}
      alt=""
      onError={onMissing}
    />
  );
}
