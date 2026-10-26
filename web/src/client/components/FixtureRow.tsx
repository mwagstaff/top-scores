import { memo, useEffect, useId, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { clearMatchDetailsCache, fetchMatchDetails } from "../api";
import { teamPath } from "../catalog";
import { matchPath, ukChannels } from "../football";
import {
  aggregateSummary,
  displayStatus,
  isMatchLive,
  isMatchFinished,
  isMatchAbandoned,
} from "../matchState";
import type { Match, MatchDetails, TvChannel } from "../types";
import { CompactMatchEvents } from "./CompactMatchEvents";

export function TeamCrest({
  name,
  shortName,
  large = false,
}: {
  name: string;
  shortName?: string | null;
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
      src={`/logos/team?name=${encodeURIComponent(name)}&alt=${encodeURIComponent(shortName || "")}&v=3`}
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
  showBroadcast = true,
  showRating = false,
  showDetails = false,
}: {
  match: Match;
  showBroadcast?: boolean;
  showRating?: boolean;
  showDetails?: boolean;
}) {
  const live = isMatchLive(match);
  const abandoned = isMatchAbandoned(match);
  const broadcastVisible = showBroadcast && !isMatchFinished(match) && !abandoned;
  const channels = broadcastVisible ? ukChannels(match.tvChannels) : [];
  const scored =
    typeof match.homeScore === "number" && typeof match.awayScore === "number";
  const aggregate = aggregateSummary(match);
  const detailsAnchor = useRef<HTMLDivElement>(null);
  const [details, setDetails] = useState<MatchDetails | null>(match.matchDetails ?? null);
  const [detailsError, setDetailsError] = useState(false);
  const shouldLoadDetails = showDetails && (live || isMatchFinished(match) || abandoned) && Boolean(match.matchDetailsId);
  useEffect(() => {
    if (!shouldLoadDetails || details || detailsError) return;
    let active = true;
    const load = () => {
      void fetchMatchDetails(match.matchDetailsId!).then(value => {
        if (active) setDetails(value);
      }).catch(() => {
        if (active) setDetailsError(true);
      });
    };
    const anchor = detailsAnchor.current;
    if (!anchor || !('IntersectionObserver' in window)) load();
    else {
      const observer = new IntersectionObserver(entries => {
        if (entries.some(entry => entry.isIntersecting)) {
          observer.disconnect();
          load();
        }
      }, { rootMargin: '300px' });
      observer.observe(anchor);
      return () => { active = false; observer.disconnect(); };
    }
    return () => { active = false; };
  }, [shouldLoadDetails, details, detailsError, match.matchDetailsId]);
  useEffect(() => {
    if (!showDetails || !live || !details || !match.matchDetailsId) return;
    let active = true;
    const timer = window.setInterval(() => {
      const anchor = detailsAnchor.current;
      if (document.visibilityState !== "visible" || !anchor) return;
      const bounds = anchor.getBoundingClientRect();
      if (bounds.bottom < -300 || bounds.top > window.innerHeight + 300) return;
      clearMatchDetailsCache(match.matchDetailsId!);
      void fetchMatchDetails(match.matchDetailsId!).then(value => {
        if (active) setDetails(value);
      }).catch(() => {});
    }, 30_000);
    return () => { active = false; window.clearInterval(timer); };
  }, [showDetails, live, Boolean(details), match.matchDetailsId]);
  useEffect(() => {
    if (!showDetails) setDetailsError(false);
  }, [showDetails]);
  return (
    <div className={`fixture-row app-fixture${live ? " is-live" : ""}${abandoned ? " is-abandoned" : ""}`}>
      <Link to={matchPath(match)} state={{ match }} className="fixture-details-link" aria-label={`Match details: ${match.homeTeam} v ${match.awayTeam}`} />
      <div className="fixture-match-line">
        <TeamCrest name={match.homeTeam} shortName={match.homeShortName} />
        <Link to={teamPath(match.homeTeam, match.homeTeamId, match.league)} className="fixture-home-name" title={match.homeTeam}>
          <span className="fixture-name-wide">{match.homeTeam}</span>
          <span className="fixture-name-compact">
            {match.homeShortName || match.homeTeam}
          </span>
        </Link>
        <strong className="fixture-score">
          {scored ? match.homeScore : ""}
        </strong>
        <span className="fixture-state">
          {live && <span className="live-dot" />}
          <span>{abandoned ? "ABD" : displayStatus(match)}</span>
        </span>
        <strong className="fixture-score">
          {scored ? match.awayScore : ""}
        </strong>
        <Link to={teamPath(match.awayTeam, match.awayTeamId, match.league)} className="fixture-away-name" title={match.awayTeam}>
          <span className="fixture-name-wide">{match.awayTeam}</span>
          <span className="fixture-name-compact">
            {match.awayShortName || match.awayTeam}
          </span>
        </Link>
        <TeamCrest name={match.awayTeam} shortName={match.awayShortName} />
      </div>
      <BroadcastChannels channels={channels} matchLabel={`${match.homeTeam} v ${match.awayTeam}`} />
      {showDetails && (live || isMatchFinished(match) || abandoned) && (
        <div ref={detailsAnchor} className="fixture-compact-details">
          <CompactMatchEvents details={details} homeTeam={match.homeTeam} awayTeam={match.awayTeam} />
          {shouldLoadDetails && !details && !detailsError && <span className="fixture-details-loading">Loading details…</span>}
          {detailsError && <span className="fixture-details-loading">Details unavailable</span>}
        </div>
      )}
      {showRating && <WatchabilityRating match={match} />}
      {abandoned && <span className="fixture-note">Match abandoned</span>}
      {(aggregate || match.penaltyResult) && (
        <span className="fixture-note">{match.penaltyResult || aggregate}</span>
      )}
    </div>
  );
});

export function BroadcastChannels({ channels, matchLabel }: { channels: TvChannel[]; matchLabel: string }) {
  const [channelsOpen, setChannelsOpen] = useState(false);
  const [channelsRevealed, setChannelsRevealed] = useState(false);
  const channelsId = useId();
  return channels.length > 0 ? (
  <div className="fixture-tv-logos">
    {channels.length > 1 ? (
      <>
        <button
          className="channel-toggle"
          aria-expanded={channelsOpen}
          aria-controls={channelsId}
          aria-label={`${channelsOpen ? "Hide" : "Show"} all ${channels.length} channels for ${matchLabel}`}
          onClick={() => { setChannelsRevealed(true); setChannelsOpen((open) => !open); }}
        >
          <ChannelLogo channel={channels[0]} />
          <span className="channel-toggle-hint">
            +{channels.length - 1}{" "}
            <span aria-hidden="true">{channelsOpen ? "⌃" : "⌄"}</span>
          </span>
        </button>
        <div
          id={channelsId}
          className={`channel-options${channelsOpen ? " is-open" : ""}`}
          aria-hidden={!channelsOpen}
          inert={!channelsOpen}
        >
          <div>
            <ul aria-label="All available TV channels">
              {channelsRevealed && channels.map((channel) => (
                <li key={channel.name}>
                  <ChannelLogo channel={channel} />
                </li>
              ))}
            </ul>
          </div>
        </div>
      </>
    ) : (
      <ChannelLogo channel={channels[0]} />
    )}
  </div>
) : null;
}

export function ChannelLogo({ channel }: { channel: TvChannel }) {
  const [failed, setFailed] = useState(false);
  const bundled =
    /amazon|prime ?video|apple|bbc|channel ?4|dazn|disney|hbo|itv|laliga|now ?tv|premier ?sports|sky|tnt/i.test(
      channel.name,
    );
  const source = bundled
    ? `/logos/tv?name=${encodeURIComponent(channel.name)}`
    : channel.logo;
  return (
    <span className="channel-logo" title={channel.name}>
      {!failed && source && (
        <img
          src={source}
          alt=""
          width="64"
          height="24"
          loading="lazy"
          decoding="async"
          onError={() => setFailed(true)}
        />
      )}
      <span>{channel.name}</span>
    </span>
  );
}

export function WatchabilityRating({ match }: { match: Match }) {
  const rating = match.watchabilityIndex;
  if (!rating) return null;
  const label = rating.tier.replaceAll("_", " ");
  return <span className={`watchability-rating tier-${rating.tier}`} aria-label={`Watchability: ${label}, ${rating.score} out of 100, ${rating.stars} out of 5 stars`}>
    <span className="watchability-label">{label}</span>
    <span className="watchability-score">{rating.score}/100</span>
    <span className="watchability-stars" aria-hidden="true">{"★".repeat(rating.stars)}<span>{"☆".repeat(5 - rating.stars)}</span></span>
  </span>;
}
