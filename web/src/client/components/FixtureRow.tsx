import { memo, useState } from "react";
import { Link } from "react-router-dom";
import { matchPath, ukChannels } from "../football";
import { aggregateSummary, displayStatus, isMatchLive } from "../matchState";
import type { Match } from "../types";

export function TeamCrest({
  name,
  large = false,
}: {
  name: string;
  large?: boolean;
}) {
  const [missing, setMissing] = useState(false);
  return missing ? (
    <span
      className={`crest-fallback${large ? " large" : ""}`}
      aria-hidden="true"
    >
      {name
        .split(/\s+/)
        .slice(0, 2)
        .map((word) => word[0])
        .join("")}
    </span>
  ) : (
    <img
      className={`team-crest${large ? " large" : ""}`}
      src={`/logos/team?name=${encodeURIComponent(name)}`}
      width={large ? 64 : 24}
      height={large ? 64 : 24}
      alt=""
      loading="lazy"
      decoding="async"
      onError={() => setMissing(true)}
    />
  );
}

export const FixtureRow = memo(function FixtureRow({
  match,
}: {
  match: Match;
}) {
  const live = isMatchLive(match);
  const channels = ukChannels(match.tvChannels);
  const scored =
    typeof match.homeScore === "number" && typeof match.awayScore === "number";
  const aggregate = aggregateSummary(match);
  return (
    <Link
      to={matchPath(match)}
      state={{ match }}
      className={`fixture-row${live ? " is-live" : ""}`}
    >
      <span className="fixture-state">
        {live && <span className="live-dot" />}
        <span>{displayStatus(match)}</span>
      </span>
      <span className="fixture-teams">
        <span className="fixture-team">
          <TeamCrest name={match.homeTeam} />
          <span>{match.homeTeam}</span>
          <strong key={`h-${match.homeScore}`}>
            {scored ? match.homeScore : "–"}
          </strong>
        </span>
        <span className="fixture-team">
          <TeamCrest name={match.awayTeam} />
          <span>{match.awayTeam}</span>
          <strong key={`a-${match.awayScore}`}>
            {scored ? match.awayScore : "–"}
          </strong>
        </span>
        {(aggregate || match.penaltyResult) && (
          <span className="fixture-note">
            {match.penaltyResult || aggregate}
          </span>
        )}
      </span>
      <span
        className={`fixture-broadcast${channels.length ? " has-channel" : ""}`}
      >
        {channels.length ? (
          <>
            <span className="tv-symbol" aria-hidden="true">
              ▣
            </span>
            <span>
              {channels[0].name}
              {channels.length > 1 && <small> +{channels.length - 1}</small>}
            </span>
          </>
        ) : (
          <span>No UK listing</span>
        )}
      </span>
      <span className="fixture-arrow" aria-hidden="true">
        ↗
      </span>
    </Link>
  );
});
