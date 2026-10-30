import "../styles.css";
import { useEffect, useState } from "react";
import { Link, useLocation, useParams } from "react-router-dom";
import { cachedMatch, loadDay } from "../dayStore";
import { normalizeMatch, normalizeMatchDetails } from "../api";
import { browserTimeZone, competitionPath, dateLabel, displayTime, ukChannels, validDate } from "../football";
import {
  aggregateSummary,
  displayStatus,
  isMatchLive,
  isMatchFinished,
  isMatchAbandoned,
} from "../matchState";
import { teamPath } from "../catalog";
import type { Match } from "../types";
import { CompactMatchEvents } from "./CompactMatchEvents";
import { MatchCard } from "./MatchCard";
import { ChannelLogo, TeamCrest, WatchabilityRating } from "./FixtureRow";
import { StadiumBackdrop } from "./StadiumBackdrop";
import { PageMeta } from "./PageMeta";
import { useInitialSeed } from "../bootstrap";

export default function MatchPage() {
  const { id = "" } = useParams();
  const location = useLocation();
  const initialSeed = useInitialSeed();
  const seedMatch =
    initialSeed?.match && normalizeMatch(initialSeed.match).id === id
      ? {
          ...normalizeMatch(initialSeed.match),
          matchDetails: initialSeed.match.match_details_id
            ? normalizeMatchDetails(initialSeed.match)
            : null,
        }
      : undefined;
  const [match, setMatch] = useState<Match | undefined>(
    () => seedMatch || location.state?.match || cachedMatch(id),
  );
  const [error, setError] = useState("");
  const [retry, setRetry] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    let timer = 0;
    let inFlight = false;
    setMatch(seedMatch || location.state?.match || cachedMatch(id));
    setError("");
    const run = async () => {
      if (controller.signal.aborted || inFlight) return;
      if (document.visibilityState !== "visible") {
        timer = window.setTimeout(run, 60_000);
        return;
      }
      inFlight = true;
      let interval = 30_000;
      try {
        if (id.includes("|")) {
          const day = id.split("|")[0];
          if (!validDate(day)) throw new Error("Match unavailable.");
          const payload = await loadDay(day);
          const summary = payload.matches.find((match) => match.id === id);
          if (!summary) throw new Error("This fixture is no longer available.");
          if (!controller.signal.aborted) {
            setMatch(summary);
            setError("");
          }
          interval = 60_000;
          return;
        }
        const response = await fetch(
          `/api/v1/matches/${encodeURIComponent(id)}?time_zone=${encodeURIComponent(browserTimeZone())}`,
          {
            signal: AbortSignal.any([
              controller.signal,
              AbortSignal.timeout(15_000),
            ]),
            cache: "no-store",
          },
        );
        if (!response.ok)
          throw new Error(
            response.status === 404
              ? "Match details aren’t available yet."
              : "Unable to refresh this match.",
          );
        const raw = await response.json();
        const next = {
          ...normalizeMatch(raw),
          matchDetails: normalizeMatchDetails(raw),
        };
        if (controller.signal.aborted) return;
        // Detail responses can omit the API rating supplied by fixture lists.
        next.watchabilityIndex ??= cachedMatch(id)?.watchabilityIndex
          ?? seedMatch?.watchabilityIndex ?? location.state?.match?.watchabilityIndex;
        setMatch(next);
        setError("");
        interval = isMatchLive(next) ? 10_000 : 60_000;
        if (!next.watchabilityIndex && validDate(next.date) && ukChannels(next.tvChannels).length && !isMatchFinished(next) && !isMatchAbandoned(next)) {
          try {
            let day = await loadDay(next.date);
            while (!controller.signal.aborted && !day.matches.some(candidate => candidate.id === id) && day.hasMore) {
              day = await loadDay(next.date, false, true, day.page + 1);
            }
            const rating = day.matches.find(candidate => candidate.id === id)?.watchabilityIndex;
            if (!controller.signal.aborted && rating) setMatch({ ...next, watchabilityIndex: rating });
          } catch { /* Keep the available details if the fixture rating cannot load. */ }
        }
      } catch (error) {
        if (!controller.signal.aborted)
          setError(
            error instanceof Error
              ? error.message
              : "Unable to load this match.",
          );
      } finally {
        inFlight = false;
        if (!controller.signal.aborted) {
          window.clearTimeout(timer);
          timer = window.setTimeout(run, interval);
        }
      }
    };
    const activate = () => {
      if (document.visibilityState === "visible") void run();
    };
    void run();
    document.addEventListener("visibilitychange", activate);
    window.addEventListener("online", activate);
    return () => {
      controller.abort();
      window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", activate);
      window.removeEventListener("online", activate);
    };
  }, [id, retry]);
  if (!match)
    return (
      <section className="football-empty">
        <Link to="/">← Back to football</Link>
        <h1>{error ? "Match unavailable" : "Loading match…"}</h1>
        {error && (
          <>
            <p>{error}</p>
            <button onClick={() => setRetry((v) => v + 1)}>Try again</button>
          </>
        )}
      </section>
    );
  const channels = ukChannels(match.tvChannels);
  const live = isMatchLive(match);
  return (
    <article className="match-page">
      <PageMeta
        title={`${match.homeTeam} v ${match.awayTeam}`}
        description={`${match.homeTeam} v ${match.awayTeam}: scores, match updates and UK TV coverage. ${match.league}.`}
      />
      <div className="breadcrumbs">
        <Link to={`/?date=${match.date}`}>← Matches</Link>
        <span>/</span>
        <Link to={competitionPath(match.league)}>{match.league}</Link>
      </div>
      <header className="match-hero">
        <StadiumBackdrop teamName={match.homeTeam} teamId={match.homeTeamId} />
        <div className="match-hero-content">
          <span className="eyebrow">
            {match.league}
            {match.leagueSubcategory ? ` · ${match.leagueSubcategory}` : ""}
          </span>
          <h1 className="sr-only">
            {match.homeTeam} v {match.awayTeam}
          </h1>
          <div className="hero-scoreline">
            <div className="hero-team">
              <TeamCrest
                name={match.homeTeam}
                shortName={match.homeShortName}
                large
              />
              <h2><Link to={teamPath(match.homeTeam, match.homeTeamId, match.league)}>{match.homeTeam}</Link></h2>
            </div>
            <div className="hero-score">
              <strong>
                {typeof match.homeScore === "number"
                  ? `${match.homeScore} – ${match.awayScore ?? "–"}`
                  : displayTime(match.time)}
              </strong>
              <span className={live ? "is-live" : ""}>
                {live && <span className="live-dot" />}
                {typeof match.homeScore === "number" || match.scoreStatus
                  ? displayStatus(match)
                  : "KICK-OFF"}
              </span>
            </div>
            <div className="hero-team">
              <TeamCrest
                name={match.awayTeam}
                shortName={match.awayShortName}
                large
              />
              <h2><Link to={teamPath(match.awayTeam, match.awayTeamId, match.league)}>{match.awayTeam}</Link></h2>
            </div>
          </div>
          {(live || isMatchFinished(match) || isMatchAbandoned(match)) && (
            <CompactMatchEvents details={match.matchDetails} homeTeam={match.homeTeam} awayTeam={match.awayTeam} className="hero-goal-summary" />
          )}
          <p className="hero-match-date">
            {validDate(match.date) ? dateLabel(match.date) : match.date}
            {match.penaltyResult
              ? ` · ${match.penaltyResult}`
              : aggregateSummary(match)
                ? ` · ${aggregateSummary(match)}`
                : ""}
          </p>
          {isMatchAbandoned(match) && <p className="hero-match-date">Match abandoned · score does not count</p>}
        </div>
      </header>
      {error && (
        <div className="refresh-notice" role="status">
          {error} Showing the last available match information.{" "}
          <button onClick={() => setRetry((v) => v + 1)}>Try again</button>
        </div>
      )}
      {!isMatchFinished(match) && !isMatchAbandoned(match) && (
        <section className="uk-broadcast-panel">
          <div>
            <span className="eyebrow">Where to watch</span>
            {match.watchabilityIndex && <h2><WatchabilityRating match={match} variant="label" /></h2>}
          </div>
          <div className="broadcast-channels">
            {channels.length ? (
              channels.map((channel) => (
                <span className="broadcast-chip" key={channel.name}>
                  <ChannelLogo channel={channel} />
                </span>
              ))
            ) : (
              <p>No UK broadcast confirmed.</p>
            )}
          </div>
        </section>
      )}
      <MatchCard key={id} match={match} detailOnly />
    </article>
  );
}
