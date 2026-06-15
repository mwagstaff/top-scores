import { useEffect, useMemo, useRef, useState, memo } from "react";
import { clearMatchDetailsCache, fetchMatchDetails, fetchPlayerDetails, shouldRetryMatchDetails } from "../api";
import {
  aggregateSummary,
  displayStatus,
  isMatchFinished,
  isMatchLive,
} from "../matchGrouping";
import type {
  Match,
  MatchAssistProvider,
  MatchDetails,
  MatchGoalScorer,
  MatchLineupPlayer,
  MatchLineupSubstitution,
  MatchTeamLineup,
  MatchTeamLineups,
  PlayerDetails,
  MatchRedCardEvent,
  MatchYellowCardEvent,
  TvChannel,
} from "../types";

// ── Locale helpers ────────────────────────────────────────────────
// Derive the user's broadcast country code from the browser locale tag.
// e.g. "en-GB" → "GB",  "en-US" → "US",  "fr-FR" → "FR".
function userCountryCode(): string | null {
  const tag = navigator.language ?? "";
  const parts = tag.split("-");
  return parts.length >= 2 ? parts[parts.length - 1].toUpperCase() : null;
}

function broadcastCountryCode(channel: TvChannel): string | null {
  if (channel.countryCode) return channel.countryCode;
  const name = channel.name.toLowerCase();
  return name.includes("bbc") || name.includes("itv") ? "GB" : null;
}

// Channels that match the user's locale country code.
function localChannels(channels: TvChannel[]): TvChannel[] {
  const code = userCountryCode();
  if (!code) return [];
  return channels.filter((c) => broadcastCountryCode(c) === code);
}

interface MatchCardProps {
  match: Match;
  highlightToday?: boolean;
  useShortTeamNames?: boolean;
  debugMode?: boolean;
}

export function MatchCard({ match, highlightToday = false, useShortTeamNames = false, debugMode = false }: MatchCardProps) {
  const [homeLogoMissing, setHomeLogoMissing] = useState(false);
  const [awayLogoMissing, setAwayLogoMissing] = useState(false);
  const [isExpanded, setIsExpanded]           = useState(false);
  const [details, setDetails]                 = useState<MatchDetails | null>(match.matchDetails ?? null);
  const [detailsLoading, setDetailsLoading]   = useState(false);
  const [detailsError, setDetailsError]       = useState<string | null>(null);
  const retriedIncompleteDetailsIdRef         = useRef<string | null>(null);

  const status        = displayStatus(match);
  const aggregateText = aggregateSummary(match);
  const isLive        = isMatchLive(match);
  const isExpandable  = Boolean(match.matchDetailsId);
  const detailPanelId = `match-details-${match.id.replace(/[^a-zA-Z0-9_-]/g, "-")}`;

  // Derived display state
  const hasScore   = typeof match.homeScore === "number" && typeof match.awayScore === "number";
  // Only show a TV badge for channels matching the user's locale country.
  const localTvChannels = useMemo(() => localChannels(match.tvChannels), [match.tvChannels]);
  const hasTvLogo  = localTvChannels.length > 0;
  // Show TV logo in centre for upcoming fixtures; for live matches with scores, show flanking scores instead
  const showTvOnly = !hasScore && hasTvLogo;
  const showLiveScore = isLive && hasScore;
  // Right column: "P4-3" when decided by penalties; otherwise status (FT / AET / 45' / 15:00)
  const rightText  = match.penaltyResult ? `P${match.penaltyResult}` : status;
  const homeDisplayName = displayTeamName(match.homeTeam, match.homeShortName, useShortTeamNames);
  const awayDisplayName = displayTeamName(match.awayTeam, match.awayShortName, useShortTeamNames);

  // Sync details when match prop updates (e.g. from live polling)
  useEffect(() => {
    setDetails(match.matchDetails ?? null);
    setDetailsLoading(false);
    setDetailsError(null);
    retriedIncompleteDetailsIdRef.current = null;
  }, [match.id]);

  useEffect(() => {
    if (match.matchDetails) {
      setDetails(match.matchDetails);
      setDetailsLoading(false);
      setDetailsError(null);
    }
  }, [match.matchDetails]);

  // Fetch details on expand
  useEffect(() => {
    let cancelled = false;
    if (!isExpanded || !match.matchDetailsId || details || detailsError) {
      return () => { cancelled = true; };
    }

    setDetailsLoading(true);
    setDetailsError(null);

    void fetchMatchDetails(match.matchDetailsId)
      .then((payload) => { if (!cancelled) setDetails(payload); })
      .catch((error) => {
        if (!cancelled) {
          setDetailsError(
            error && typeof error === "object" && "status" in error && error.status === 404
              ? "Match details are not available for this fixture yet."
              : error instanceof Error ? error.message : "Match details unavailable."
          );
        }
      })
      .finally(() => { if (!cancelled) setDetailsLoading(false); });

    return () => { cancelled = true; };
  }, [details, detailsError, isExpanded, match.matchDetailsId]);

  // If the match has since ended but cached details pre-date the final whistle, clear and re-fetch
  useEffect(() => {
    if (!details || !match.matchDetailsId) return;
    const matchFinished = isMatchFinished(match);
    const detailsFinished = ["FT", "AET", "PENS"].includes((details.scoreStatus ?? "").trim().toUpperCase());
    if (matchFinished && !detailsFinished) {
      clearMatchDetailsCache(match.matchDetailsId);
      setDetails(null);
      retriedIncompleteDetailsIdRef.current = null;
    }
  }, [match, details]);

  // Retry once if details came back incomplete
  useEffect(() => {
    let cancelled = false;
    if (
      !isExpanded || !match.matchDetailsId || !details ||
      !shouldRetryMatchDetails(details) ||
      retriedIncompleteDetailsIdRef.current === match.matchDetailsId
    ) {
      return () => { cancelled = true; };
    }

    retriedIncompleteDetailsIdRef.current = match.matchDetailsId;
    const timer = window.setTimeout(() => {
      void fetchMatchDetails(match.matchDetailsId!)
        .then((payload) => { if (!cancelled) { setDetails(payload); setDetailsError(null); } })
        .catch((error) => {
          if (!cancelled) setDetailsError(error instanceof Error ? error.message : "Match details unavailable.");
        });
    }, 1500);

    return () => { cancelled = true; window.clearTimeout(timer); };
  }, [details, isExpanded, match.matchDetailsId]);

  // ── Compact single-row summary ────────────────────────────────
  //
  // Layout (7-column CSS grid):
  //   home-logo | home-name | center (score or TV) | away-name | away-logo | status | chevron
  //
  const rowContent = (
    <>
      {/* Home logo */}
      <TeamBadge
        teamName={match.homeTeam}
        missing={homeLogoMissing}
        onMissing={() => setHomeLogoMissing(true)}
      />

      {/* Home team name – right-aligned */}
      <div className="match-team-name match-team-home" title={match.homeTeam}>
        {homeDisplayName}
      </div>

      {/* Centre column: score OR TV logos */}
      <div className="match-center">
        {showLiveScore ? (
          <div className="mc-score">
            <span className="mc-num">{match.homeScore}</span>
            {hasTvLogo ? (
              <TvBadge channel={localTvChannels[0]} matchId={match.id} />
            ) : (
              <span className="mc-sep">—</span>
            )}
            <span className="mc-num">{match.awayScore}</span>
          </div>
        ) : showTvOnly ? (
          <div className="mc-tv">
            <TvBadge channel={localTvChannels[0]} matchId={match.id} />
          </div>
        ) : hasScore ? (
          <div className="mc-score">
            <span className="mc-num">{match.homeScore}</span>
            <span className="mc-sep">—</span>
            <span className="mc-num">{match.awayScore}</span>
          </div>
        ) : (
          <div className="mc-sep">
            vs
          </div>
        )}
        {/* Two-legged aggregate sub-label */}
        {aggregateText && <div className="mc-agg">{aggregateText}</div>}
      </div>

      {/* Away team name – left-aligned */}
      <div className="match-team-name match-team-away" title={match.awayTeam}>
        {awayDisplayName}
      </div>

      {/* Away logo */}
      <TeamBadge
        teamName={match.awayTeam}
        missing={awayLogoMissing}
        onMissing={() => setAwayLogoMissing(true)}
      />

      {/* Right status: FT / AET / 45' / 15:00 / P 3-4 */}
      <div className={`mc-right${isLive ? " is-live" : ""}`}>
        {rightText}
      </div>

      {/* Expand chevron (always present to keep grid stable; invisible when not expandable) */}
      <div className="mc-chevron-wrap" aria-hidden="true">
        {isExpandable && (
          <svg
            className={`mc-chevron${isExpanded ? " is-expanded" : ""}`}
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            strokeWidth="2.2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <path d="m4 6 4 4 4-4" />
          </svg>
        )}
      </div>
    </>
  );

  return (
    <article className={`match-card${highlightToday ? " is-highlighted" : ""}`}>
      {/* Use a button when expandable so the whole row is keyboard/click accessible */}
      {isExpandable ? (
        <button
          type="button"
          className="match-row"
          onClick={() => setIsExpanded((v) => !v)}
          aria-expanded={isExpanded}
          aria-controls={detailPanelId}
        >
          {rowContent}
        </button>
      ) : (
        <div className="match-row">
          {rowContent}
        </div>
      )}

      {/* Expanded match details panel */}
      {isExpandable && isExpanded && (
        <div className="match-details-panel" id={detailPanelId}>
          {detailsLoading ? (
            <div className="match-details-message">Loading match details…</div>
          ) : detailsError ? (
            <div className="match-details-message is-error">{detailsError}</div>
          ) : details ? (
            <ExpandedMatchDetails details={details} tvChannels={match.tvChannels} />
          ) : (
            <div className="match-details-message">No additional match details available.</div>
          )}
        </div>
      )}
      {/* Debug panel always visible in debug mode, regardless of expand state */}
      {debugMode && (
        <div className="match-details-panel">
          <MatchDebugPanel match={match} />
        </div>
      )}
    </article>
  );
}

// ── Debug panel ───────────────────────────────────────────────────

const TSDB_BASE = "https://www.thesportsdb.com/api/v2/json";

function MatchDebugPanel({ match }: { match: Match }) {
  const eventId  = match.matchDetailsId ?? null;
  const leagueId = match.leagueId ?? null;

  const links: Array<{ label: string; url: string }> = [];

  if (eventId) {
    links.push({ label: `event_timeline/${eventId}`,  url: `${TSDB_BASE}/lookup/event_timeline/${eventId}` });
    links.push({ label: `event_lineup/${eventId}`,    url: `${TSDB_BASE}/lookup/event_lineup/${eventId}` });
  }
  if (leagueId) {
    links.push({ label: `livescore/${leagueId}`,      url: `${TSDB_BASE}/livescore/${leagueId}` });
    links.push({ label: `list/teams/${leagueId}`,     url: `${TSDB_BASE}/list/teams/${leagueId}` });
  }

  return (
    <section className="match-debug-panel">
      <div className="match-debug-title">🐛 Debug</div>
      <table className="match-debug-table">
        <tbody>
          <tr><td>League</td><td>{match.league || "—"}</td></tr>
          <tr><td>League ID</td><td>{leagueId ?? <em>not mapped</em>}</td></tr>
          <tr><td>Event ID</td><td>{eventId ?? <em>none</em>}</td></tr>
          <tr><td>Internal ID</td><td className="match-debug-mono">{match.id}</td></tr>
        </tbody>
      </table>
      {links.length > 0 && (
        <div className="match-debug-links">
          {links.map(({ label, url }) => (
            <a key={label} href={url} target="_blank" rel="noreferrer" className="match-debug-link">
              {label}
            </a>
          ))}
        </div>
      )}
    </section>
  );
}

function displayTeamName(fullName: string, shortName: string | null | undefined, useShortName: boolean): string {
  if (!useShortName) {
    return fullName;
  }

  const trimmed = shortName?.trim() ?? "";
  return trimmed.length > 0 ? trimmed : fullName;
}


// ── Flag emoji from ISO 3166-1 alpha-2 country code ─────────────────
// Regional indicator symbols: 🇦 = U+1F1E6, 🇧 = U+1F1E7, …
function flagEmoji(countryCode: string): string {
  return Array.from(countryCode.toUpperCase())
    .map((c) => String.fromCodePoint(0x1f1e6 + c.charCodeAt(0) - 65))
    .join("");
}

function channelFlagEmoji(channel: TvChannel | undefined): string | null {
  if (!channel) return null;
  const countryCode = broadcastCountryCode(channel);
  return countryCode ? flagEmoji(countryCode) : null;
}

// ── TV badge (single channel logo for the fixture list row) ──────────
function TvBadge({ channel, matchId }: { channel: TvChannel; matchId: string }) {
  const src = channel.logo || `/logos/tv/${encodeURIComponent(channel.name)}`;
  return (
    <img
      key={`${matchId}-tv-badge`}
      src={src}
      alt={channel.name}
      className="mc-tv-logo"
      onError={(e) => { e.currentTarget.style.display = "none"; }}
    />
  );
}

// ── TV logo brand key (mirrors server resolveTvLogo brand detection) ──
function tvLogoBrand(ch: string): string {
  const n = ch.toLowerCase();
  if (n.includes("amazon"))                              return "amazon";
  if (n.includes("apple"))                               return "apple";
  if (n.includes("bbc"))                                 return "bbc";
  if (n.includes("channel 4") || n.includes("channel4")) return "channel4";
  if (n.includes("dazn"))                                return "dazn";
  if (n.includes("disney"))                              return "disney+";
  if (n.includes("hbo"))                                 return "hbo max";
  if (n.includes("itv"))                                 return "itv";
  if (n.includes("laliga"))                              return "laliga tv";
  if (n.includes("premier sports") || n.includes("premiersports")) return "premier sports";
  if (n.includes("sky"))                                 return "sky";
  if (n.includes("tnt"))                                 return "tnt";
  return n;
}

// ── Team badge (logo with initials fallback) ──────────────────────

interface TeamBadgeProps {
  teamName: string;
  missing: boolean;
  onMissing: () => void;
}

function TeamBadge({ teamName, missing, onMissing }: TeamBadgeProps) {
  const initials = teamName
    .split(/\s+/).filter(Boolean)
    .slice(0, 2)
    .map((t) => t[0]?.toUpperCase() ?? "")
    .join("");

  if (missing) {
    return <div className="team-logo-fallback">{initials || "?"}</div>;
  }

  return (
    <img
      className="team-logo"
      src={`/logos/team?name=${encodeURIComponent(teamName)}`}
      alt=""
      onError={onMissing}
    />
  );
}


// ── Expanded match details ────────────────────────────────────────

function WhereToWatch({ channels }: { channels: TvChannel[] }) {
  const [otherExpanded, setOtherExpanded] = useState(false);

  const { local, other } = useMemo(() => {
    const userCode = userCountryCode();
    const localChannels: TvChannel[] = [];
    const otherMap = new Map<string, TvChannel[]>();

    channels.forEach((ch) => {
      const countryCode = broadcastCountryCode(ch);
      if (countryCode === userCode) {
        localChannels.push(ch);
      } else {
        const key = ch.country ?? "Other";
        if (!otherMap.has(key)) otherMap.set(key, []);
        otherMap.get(key)!.push(ch);
      }
    });

    // Sort other countries alphabetically.
    const otherGroups = Array.from(otherMap.entries()).sort(([a], [b]) => a.localeCompare(b));
    return { local: localChannels, other: otherGroups };
  }, [channels]);

  const hasLocal = local.length > 0;
  const hasOther = other.length > 0;
  if (!hasLocal && !hasOther) return null;

  return (
    <section className="details-section">
      <div className="details-section-title">Where to watch</div>
      <div className="details-where-to-watch">
        {hasLocal ? (
          <div className="details-wtw-channels">
            {local.map((ch) => (
              <div key={`${ch.name}-${ch.country}`} className="details-tv-channel-row">
                <img
                  src={ch.logo || `/logos/tv/${encodeURIComponent(ch.name)}`}
                  alt=""
                  className="details-tv-channel-logo"
                  onError={(e) => { e.currentTarget.style.display = "none"; }}
                />
                <span className="details-tv-channel-name">{ch.name}</span>
              </div>
            ))}
          </div>
        ) : (
          <p className="details-wtw-unavailable">Not available in your region</p>
        )}

        {hasOther && (
          <div className="details-wtw-other">
            <button
              type="button"
              className="details-wtw-other-toggle"
              onClick={() => setOtherExpanded((v) => !v)}
              aria-expanded={otherExpanded}
            >
              {otherExpanded ? "Hide other countries" : `Other countries (${other.length})`}
              <span className="details-wtw-chevron">{otherExpanded ? "▲" : "▼"}</span>
            </button>
            {otherExpanded && (
              <div className="details-wtw-other-content">
                {other.map(([country, chs]) => (
                  <div key={country} className="details-wtw-country">
                    <div className="details-wtw-country-header">
                      {channelFlagEmoji(chs[0]) && (
                        <span className="details-wtw-flag">{channelFlagEmoji(chs[0])}</span>
                      )}
                      <span className="details-wtw-country-name">{country}</span>
                    </div>
                    <div className="details-wtw-channels">
                      {chs.map((ch) => (
                        <div key={`${ch.name}-${ch.country}`} className="details-tv-channel-row">
                          <img
                            src={ch.logo || `/logos/tv/${encodeURIComponent(ch.name)}`}
                            alt=""
                            className="details-tv-channel-logo"
                            onError={(e) => { e.currentTarget.style.display = "none"; }}
                          />
                          <span className="details-tv-channel-name">{ch.name}</span>
                        </div>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
      </div>
    </section>
  );
}

function ExpandedMatchDetails({ details, tvChannels = [] }: { details: MatchDetails; tvChannels?: TvChannel[] }) {
  const timelineEntries    = useMemo(() => buildTimelineEntries(details), [details]);
  const hasCompleteLineups = hasRenderableTeamLineups(details.teamLineups);
  const hasTvData          = tvChannels.length > 0;
  const [selectedTimelinePlayer, setSelectedTimelinePlayer] = useState<MatchLineupPlayer | null>(null);

  if (timelineEntries.length === 0 && !hasCompleteLineups && !hasTvData) {
    return <div className="match-details-message">No additional match details available.</div>;
  }

  return (
    <div className="match-details-body">
      {timelineEntries.length > 0 && (
        <section className="details-section">
          <div className="details-section-title">Key events</div>
          <div className="timeline-list">
            {timelineEntries.map((entry) => (
              <button
                key={`${entry.side}-${entry.kind}-${entry.minute}-${entry.player}`}
                type="button"
                className={`timeline-row timeline-row-${entry.side}`}
                onClick={() => entry.lineupPlayer?.idPlayer && setSelectedTimelinePlayer(entry.lineupPlayer)}
                disabled={!entry.lineupPlayer?.idPlayer}
                aria-label={entry.lineupPlayer?.idPlayer ? `Show ${entry.player} details` : entry.text}
              >
                {entry.side === "away" && <TimelinePlayerPortrait player={entry.lineupPlayer} />}
                {entry.side === "home" ? (
                  <>
                    <span className="timeline-minute">{entry.minute}</span>
                    <span className={`timeline-kind timeline-kind-${entry.kind}`}>{entry.icon}</span>
                    <span className="timeline-text">{entry.text}</span>
                    <TimelinePlayerPortrait player={entry.lineupPlayer} />
                  </>
                ) : (
                  <>
                    <span className="timeline-text">{entry.text}</span>
                    <span className={`timeline-kind timeline-kind-${entry.kind}`}>{entry.icon}</span>
                    <span className="timeline-minute">{entry.minute}</span>
                  </>
                )}
              </button>
            ))}
          </div>
        </section>
      )}

      {hasCompleteLineups && <LineupSection details={details} teamLineups={details.teamLineups!} />}
      {hasTvData && <WhereToWatch channels={tvChannels} />}
      {selectedTimelinePlayer && (
        <PlayerDetailsDialog
          player={selectedTimelinePlayer}
          onClose={() => setSelectedTimelinePlayer(null)}
        />
      )}
    </div>
  );
}

function TimelinePlayerPortrait({ player }: { player: MatchLineupPlayer | null }) {
  if (!player) {
    return <span className="lineup-player-portrait timeline-player-portrait-placeholder" aria-hidden="true" />;
  }
  return <LineupPlayerPortrait player={player} />;
}


// ── Lineup section ────────────────────────────────────────────────

interface LineupSectionProps {
  details: MatchDetails;
  teamLineups: MatchTeamLineups;
}

function LineupSection({ details, teamLineups }: LineupSectionProps) {
  const homeLineup       = teamLineups.home!;
  const awayLineup       = teamLineups.away!;
  const [selectedPlayer, setSelectedPlayer] = useState<MatchLineupPlayer | null>(null);

  const homeLookup = buildLineupEventLookup({
    goals: details.homeGoalScorers, assists: details.homeAssists,
    yellowCards: details.homeYellowCards, redCards: details.homeRedCards,
    substitutions: homeLineup.substitutions,
  });
  const awayLookup = buildLineupEventLookup({
    goals: details.awayGoalScorers, assists: details.awayAssists,
    yellowCards: details.awayYellowCards, redCards: details.awayRedCards,
    substitutions: awayLineup.substitutions,
  });

  const homeTeamName     = homeLineup.team || details.homeTeam || "Home";
  const awayTeamName     = awayLineup.team || details.awayTeam || "Away";

  return (
    <section className="details-section lineup-section">
      <div className="details-section-title">Starting Line-ups</div>

      <div className="lineup-pitch">
        <div className="lineup-pitch-markings" aria-hidden="true">
          <div className="lineup-pitch-outline" />
          <div className="lineup-pitch-halfway" />
          <div className="lineup-pitch-centre-circle" />
          <div className="lineup-pitch-centre-spot" />
          <div className="lineup-pitch-penalty lineup-pitch-penalty-top" />
          <div className="lineup-pitch-penalty lineup-pitch-penalty-bottom" />
          <div className="lineup-pitch-six-yard lineup-pitch-six-yard-top" />
          <div className="lineup-pitch-six-yard lineup-pitch-six-yard-bottom" />
        </div>

        <div className="lineup-pitch-content">
          <LineupHalf
            teamName={homeTeamName}
            starters={homeLineup.startingLineup}
            lookup={homeLookup}
            side="home"
            onSelectPlayer={setSelectedPlayer}
          />
          <LineupHalf
            teamName={awayTeamName}
            starters={awayLineup.startingLineup}
            lookup={awayLookup}
            side="away"
            onSelectPlayer={setSelectedPlayer}
          />
        </div>
      </div>
      {selectedPlayer && (
        <PlayerDetailsDialog
          player={selectedPlayer}
          onClose={() => setSelectedPlayer(null)}
        />
      )}
    </section>
  );
}


// ── Lineup half ───────────────────────────────────────────────────

interface LineupHalfProps {
  teamName: string;
  starters: MatchLineupPlayer[];
  lookup: MatchLineupEventLookup;
  side: "home" | "away";
  onSelectPlayer: (player: MatchLineupPlayer) => void;
}

function LineupHalf({ teamName, starters, lookup, side, onSelectPlayer }: LineupHalfProps) {
  const groupedRows = buildDisplayLineupRows(starters, side);

  return (
    <div className={`lineup-half lineup-half-${side}`}>
      {side === "home" && <div className="lineup-team-label">{teamName.toUpperCase()}</div>}

      <div className="lineup-half-rows">
        {groupedRows.map((row, rowIndex) => (
          <div
            key={`${side}-${rowIndex}`}
            className={`lineup-row${row.players.length === 0 ? " lineup-row-empty" : ""}`}
            style={{ gridTemplateColumns: `repeat(${Math.max(row.players.length, 1)}, minmax(0, 1fr))` }}
          >
            {row.players.map((player) => (
              <LineupPlayerMarker
                key={`${side}-${player.idPlayer || player.number}-${player.name}`}
                player={player}
                summary={lookup.summaryFor(player)}
                replacementSummary={lookup.replacementSummaryFor(player)}
                onSelectPlayer={onSelectPlayer}
              />
            ))}
          </div>
        ))}
      </div>

      {side === "away" && <div className="lineup-team-label lineup-team-label-away">{teamName.toUpperCase()}</div>}
    </div>
  );
}


// ── Player marker ─────────────────────────────────────────────────

interface LineupPlayerMarkerProps {
  player: MatchLineupPlayer;
  summary: MatchLineupPlayerEventSummary;
  replacementSummary: MatchLineupPlayerEventSummary | null;
  onSelectPlayer: (player: MatchLineupPlayer) => void;
}

function LineupPlayerMarker({ player, summary, replacementSummary, onSelectPlayer }: LineupPlayerMarkerProps) {
  const replacementPlayer = summary.substitution?.playerOn ?? null;
  const badgeItems        = buildPlayerBadgeItems(summary);
  const replacementBadges = replacementSummary ? buildPlayerBadgeItems(replacementSummary) : [];

  return (
    <button
      className="lineup-player"
      type="button"
      onClick={() => player.idPlayer && onSelectPlayer(player)}
      disabled={!player.idPlayer}
      aria-label={player.idPlayer ? `Show ${player.name} details` : player.name}
    >
      <LineupPlayerPortrait player={player} />

      {badgeItems.length > 0 && (
        <div className="lineup-player-badges">
          {badgeItems.map((badge) => (
            <LineupEventBadge key={`${player.number}-${badge.kind}`} badge={badge} />
          ))}
        </div>
      )}

      <div className="lineup-player-text">
        <div className="lineup-player-name-row">
          {summary.substitution && <span className="lineup-sub-arrow lineup-sub-arrow-off">↓</span>}
          <span className="lineup-player-name">{player.name}</span>
        </div>

        {replacementPlayer && (
          <>
            <div className="lineup-player-name-row lineup-player-name-row-sub">
              <span className="lineup-sub-arrow lineup-sub-arrow-on">↑</span>
              <span className="lineup-player-name">
                {condensedLineupPlayerName(replacementPlayer.name)}{" "}
                ({formattedMatchMinute(summary.substitution?.minute ?? "")})
              </span>
            </div>
            {replacementBadges.length > 0 && (
              <div className="lineup-player-badges">
                {replacementBadges.map((badge) => (
                  <LineupEventBadge key={`${replacementPlayer.number}-${badge.kind}`} badge={badge} />
                ))}
              </div>
            )}
          </>
        )}
      </div>
    </button>
  );
}

function LineupPlayerPortrait({ player }: { player: MatchLineupPlayer }) {
  const initials = playerInitials(player.name);
  return (
    <div className="lineup-player-portrait">
      {player.cutoutUrl ? (
        <img src={player.cutoutUrl} alt="" loading="lazy" onError={(event) => { event.currentTarget.style.display = "none"; }} />
      ) : null}
      <span className="lineup-player-initials">{initials}</span>
    </div>
  );
}

function PlayerDetailsDialog({ player, onClose }: { player: MatchLineupPlayer; onClose: () => void }) {
  const [details, setDetails] = useState<PlayerDetails | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!player.idPlayer) return;
    let cancelled = false;
    setDetails(null);
    setError(null);
    void fetchPlayerDetails(player.idPlayer)
      .then((payload) => {
        if (!cancelled) setDetails(payload);
      })
      .catch(() => {
        if (!cancelled) setError("Player details unavailable.");
      });
    return () => {
      cancelled = true;
    };
  }, [player.idPlayer]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  const display = details ?? null;

  return (
    <div className="player-details-overlay" role="presentation" onClick={onClose}>
      <div className="player-details-card" role="dialog" aria-modal="true" aria-label={`${player.name} details`} onClick={(event) => event.stopPropagation()}>
        <button className="player-details-close" type="button" onClick={onClose} aria-label="Close player details">×</button>

        <div className="player-details-hero">
          <div className="player-details-copy">
            <div className="player-details-position">{display?.position || player.position || "Position"}</div>
            <h3>{display?.name || player.name}</h3>
            {display?.team && <div className="player-details-team">{display.team}</div>}
          </div>
          <PlayerDetailsPhoto player={player} display={display} />
        </div>

        {!display && !error && <div className="player-details-loading">Loading player details…</div>}
        {error && <div className="player-details-loading">{error}</div>}

        {display && (
          <>
            <div className="player-details-facts">
              <PlayerFact label="Age" value={playerAge(display.born)} meta={formatBornDate(display.born)} />
              <PlayerFact label="Side" value={display.side || "Unknown"} />
              <PlayerFact label="Position" value={display.position || player.position || "Unknown"} />
            </div>

            {display.description && (
              <div className="player-details-about">
                <h4>About {display.name}</h4>
                {display.description.split(/\n+/).filter(Boolean).map((paragraph, index) => (
                  <p key={index}>{paragraph}</p>
                ))}
              </div>
            )}

            <div className="player-details-info">
              <div>
                <span>Position</span>
                <strong>{display.position || "Unknown"}</strong>
              </div>
              <div>
                <span>Preferred foot</span>
                <strong>{display.side || "Unknown"}</strong>
              </div>
              <div>
                <span>Birth location</span>
                <strong>{display.birthLocation || "Unknown"}</strong>
              </div>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

function PlayerDetailsPhoto({ player, display }: { player: MatchLineupPlayer; display: PlayerDetails | null }) {
  const imageCandidates = useMemo(
    () => uniqueStrings([display?.renderUrl, display?.cutoutUrl, display?.thumbUrl, player.cutoutUrl]),
    [display?.renderUrl, display?.cutoutUrl, display?.thumbUrl, player.cutoutUrl]
  );
  const imageKey = imageCandidates.join("|");
  const [imageIndex, setImageIndex] = useState(0);

  useEffect(() => {
    setImageIndex(0);
  }, [imageKey]);

  const imageUrl = imageCandidates[imageIndex] ?? null;

  return (
    <div className="player-details-photo">
      {imageUrl ? (
        <img
          key={imageUrl}
          src={imageUrl}
          alt=""
          onError={() => setImageIndex((index) => index + 1)}
        />
      ) : (
        <span>{playerInitials(display?.name || player.name)}</span>
      )}
    </div>
  );
}

function uniqueStrings(values: Array<string | null | undefined>) {
  return Array.from(new Set(values.map((value) => value?.trim() ?? "").filter(Boolean)));
}

function PlayerFact({ label, value, meta }: { label: string; value: string; meta?: string | null }) {
  return (
    <div className="player-details-fact">
      <span>{label}</span>
      <strong>{value}</strong>
      {meta && <small>{meta}</small>}
    </div>
  );
}


// ── Substitutes table ─────────────────────────────────────────────

function LineupSubstitutesTable({ lineup }: { lineup: MatchTeamLineup }) {
  return (
    <section className="lineup-substitutes-table">
      <div className="lineup-substitutes-title">
        {(lineup.team || "Team").toUpperCase()} SUBSTITUTES
      </div>

      <div className="lineup-substitutes-card">
        {lineup.substitutes.map((substitute, index) => {
          const substitution =
            lineup.substitutions.find((item) => item.playerOn.number === substitute.number) ?? null;
          return (
            <div
              key={`${lineup.team}-${substitute.number}-${substitute.name}`}
              className="lineup-substitute-row"
            >
              <div className="lineup-substitute-number">{substitute.number}</div>
              <div className="lineup-substitute-copy">
                <div className="lineup-substitute-name">
                  {condensedLineupPlayerName(substitute.name)}
                </div>
                {substitution && (
                  <div className="lineup-substitute-meta">
                    <span className="lineup-sub-arrow lineup-sub-arrow-on">↑</span>
                    <span>
                      {formattedMatchMinute(substitution.minute)} for{" "}
                      {condensedLineupPlayerName(substitution.playerOff.name)}
                    </span>
                  </div>
                )}
              </div>
              {index < lineup.substitutes.length - 1 && (
                <div className="lineup-substitute-divider" />
              )}
            </div>
          );
        })}
      </div>
    </section>
  );
}


// ── Event badge ───────────────────────────────────────────────────

interface LineupEventBadgeDescriptor {
  kind: "goal" | "assist" | "yellow-card" | "red-card";
  count: number;
}

function LineupEventBadge({ badge }: { badge: LineupEventBadgeDescriptor }) {
  const label     = badge.kind === "goal" ? "⚽" : badge.kind === "assist" ? "A" : "";
  const cardClass =
    badge.kind === "yellow-card" ? " lineup-event-badge-card-yellow" :
    badge.kind === "red-card"    ? " lineup-event-badge-card-red"    : "";

  return (
    <span className="lineup-event-badge">
      {badge.kind === "yellow-card" || badge.kind === "red-card" ? (
        <span className={`lineup-event-badge-card${cardClass}`} aria-hidden="true" />
      ) : (
        <span className="lineup-event-badge-label">{label}</span>
      )}
      {badge.count > 1 && <span className="lineup-event-badge-count">{badge.count}</span>}
    </span>
  );
}


// ── Guard: only render lineup when both teams have starters ───────

function hasRenderableTeamLineups(
  teamLineups: MatchTeamLineups | null | undefined
): teamLineups is MatchTeamLineups & { home: MatchTeamLineup; away: MatchTeamLineup } {
  return Boolean(
    teamLineups?.home && teamLineups.away &&
    teamLineups.home.startingLineup.length > 0 &&
    teamLineups.away.startingLineup.length > 0
  );
}


// ── Lineup row building ───────────────────────────────────────────

interface LineupRow {
  players: MatchLineupPlayer[];
  slotCount: number;
}

function buildDisplayLineupRows(starters: MatchLineupPlayer[], side: "home" | "away") {
  const rows = buildRoleLineupRows(starters);
  return side === "home" ? rows : [...rows].reverse();
}

function buildRoleLineupRows(starters: MatchLineupPlayer[]): LineupRow[] {
  return [
    starters.filter((p) => lineupRole(p) === "goalkeeper"),
    starters.filter((p) => lineupRole(p) === "defender"),
    starters.filter((p) => lineupRole(p) === "midfielder"),
    starters.filter((p) => lineupRole(p) === "forward"),
  ]
    .map((players) => ({
      players: [...players].sort((left, right) => {
        const leftScore = horizontalLineupScore(left);
        const rightScore = horizontalLineupScore(right);
        return leftScore !== rightScore ? leftScore - rightScore : left.number - right.number;
      }),
      slotCount: players.length,
    }));
}

function lineupRole(player: MatchLineupPlayer): "goalkeeper" | "defender" | "midfielder" | "forward" | "unknown" {
  const short = (player.positionShort || "").trim().toUpperCase();
  if (short === "G") return "goalkeeper";
  if (short === "D") return "defender";
  if (short === "M") return "midfielder";
  if (short === "F") return "forward";
  if (player.positionCategory === "goalkeeper") return "goalkeeper";
  if (player.positionCategory === "defender") return "defender";
  if (player.positionCategory === "midfielder") return "midfielder";
  if (player.positionCategory === "attacker") return "forward";
  return "unknown";
}

function horizontalLineupScore(player: MatchLineupPlayer) {
  const position = (player.position || "").toLowerCase();
  if (position.includes("left")) return 0;
  if (position.includes("right")) return 2;
  return 1;
}

function playerInitials(name: string) {
  const tokens = name.replace(/\(c\)/gi, "").split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const first = tokens[0]?.[0] ?? "";
  const last = tokens.length > 1 ? tokens[tokens.length - 1]?.[0] ?? "" : "";
  return `${first}${last}`.toUpperCase() || "?";
}

function playerAge(born: string | null | undefined) {
  if (!born) return "Unknown";
  const birthDate = new Date(`${born}T00:00:00Z`);
  if (Number.isNaN(birthDate.getTime())) return "Unknown";
  const now = new Date();
  let age = now.getUTCFullYear() - birthDate.getUTCFullYear();
  const monthDelta = now.getUTCMonth() - birthDate.getUTCMonth();
  if (monthDelta < 0 || (monthDelta === 0 && now.getUTCDate() < birthDate.getUTCDate())) {
    age -= 1;
  }
  return String(age);
}

function formatBornDate(born: string | null | undefined) {
  if (!born) return null;
  const birthDate = new Date(`${born}T00:00:00Z`);
  if (Number.isNaN(birthDate.getTime())) return null;
  return new Intl.DateTimeFormat(undefined, {
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  }).format(birthDate);
}


// ── Event lookup ──────────────────────────────────────────────────

interface MatchLineupPlayerEventSummary {
  goals: number;
  assists: number;
  yellowCards: number;
  redCards: number;
  substitution: MatchLineupSubstitution | null;
}

interface MatchLineupEventLookup {
  summaryFor(player: MatchLineupPlayer): MatchLineupPlayerEventSummary;
  replacementSummaryFor(player: MatchLineupPlayer): MatchLineupPlayerEventSummary | null;
}

function buildLineupEventLookup({
  goals, assists, yellowCards, redCards, substitutions,
}: {
  goals: MatchGoalScorer[];
  assists: MatchAssistProvider[];
  yellowCards: MatchYellowCardEvent[];
  redCards: MatchRedCardEvent[];
  substitutions: MatchLineupSubstitution[];
}): MatchLineupEventLookup {
  const goalEntries       = goals.map((g)  => ({ count: g.goalTimes.length,       lookup: buildPlayerNameLookup(g.player)  }));
  const assistEntries     = assists.map((a) => ({ count: a.assistTimes.length,     lookup: buildPlayerNameLookup(a.player)  }));
  const yellowCardEntries = yellowCards.map((c) => ({ count: c.yellowCardTimes.length, lookup: buildPlayerNameLookup(c.player) }));
  const redCardEntries    = redCards.map((c)    => ({ count: c.redCardTimes.length,    lookup: buildPlayerNameLookup(c.player) }));

  const substitutionForPlayer = (player: MatchLineupPlayer) => {
    const playerLookup = buildPlayerNameLookup(player.name);
    const nameMatch = substitutions.find((substitution) =>
      matchPlayerNameLookup(playerLookup, buildPlayerNameLookup(substitution.playerOff.name)) > 0.88
    );
    if (nameMatch) return nameMatch;

    if (player.number === null || player.number === undefined) return null;
    const numberMatches = substitutions.filter((substitution) => substitution.playerOff.number === player.number);
    return numberMatches.length === 1 ? numberMatches[0] : null;
  };

  const bestCount = (name: string, entries: Array<{ count: number; lookup: MatchPlayerNameLookup }>) => {
    const lookup = buildPlayerNameLookup(name);
    return entries.reduce<{ count: number; score: number } | null>((best, entry) => {
      const score = matchPlayerNameLookup(lookup, entry.lookup);
      if (score <= 0) return best;
      if (!best || score > best.score || (score === best.score && entry.count > best.count)) {
        return { count: entry.count, score };
      }
      return best;
    }, null)?.count ?? 0;
  };

  return {
    summaryFor(player) {
      return {
        goals:       bestCount(player.name, goalEntries),
        assists:     bestCount(player.name, assistEntries),
        yellowCards: bestCount(player.name, yellowCardEntries),
        redCards:    bestCount(player.name, redCardEntries),
        substitution: substitutionForPlayer(player),
      };
    },
    replacementSummaryFor(player) {
      const sub = substitutionForPlayer(player);
      if (!sub) return null;
      return {
        goals:       bestCount(sub.playerOn.name, goalEntries),
        assists:     bestCount(sub.playerOn.name, assistEntries),
        yellowCards: bestCount(sub.playerOn.name, yellowCardEntries),
        redCards:    bestCount(sub.playerOn.name, redCardEntries),
        substitution: null,
      };
    },
  };
}

function buildPlayerBadgeItems(summary: MatchLineupPlayerEventSummary): LineupEventBadgeDescriptor[] {
  const badges: LineupEventBadgeDescriptor[] = [];
  if (summary.goals       > 0) badges.push({ kind: "goal",        count: summary.goals       });
  if (summary.assists     > 0) badges.push({ kind: "assist",      count: summary.assists     });
  if (summary.yellowCards > 0) badges.push({ kind: "yellow-card", count: summary.yellowCards });
  if (summary.redCards    > 0) badges.push({ kind: "red-card",    count: summary.redCards    });
  return badges;
}


// ── Timeline builder ──────────────────────────────────────────────

interface TimelineEntry {
  side: "home" | "away";
  minute: string;
  player: string;
  lineupPlayer: MatchLineupPlayer | null;
  text: string;
  kind: string;
  icon: string;
  baseMinute: number;
  extraMinute: number;
  sequence: number;
}

function buildTimelineEntries(details: MatchDetails) {
  const homeAssistLookup = buildAssistLookup(details.homeAssists);
  const awayAssistLookup = buildAssistLookup(details.awayAssists);
  const homePlayers = timelinePlayerCandidates(details.teamLineups?.home);
  const awayPlayers = timelinePlayerCandidates(details.teamLineups?.away);
  const playerForEvent = (name: string, side: "home" | "away") =>
    findTimelinePlayer(name, side === "home" ? homePlayers : awayPlayers);

  const entries: TimelineEntry[] = [];
  let sequence = 0;

  const addGoals = (
    scorers: MatchGoalScorer[],
    side: "home" | "away",
    assistLookup: Map<string, string>
  ) => {
    for (const scorer of scorers) {
      for (const minute of scorer.goalTimes) {
        const parsed = parseMinute(minute);
        if (!parsed) continue;
        const assist = assistLookup.get(parsed.lookupKey) ?? assistLookup.get(String(parsed.base));
        const lineupPlayer = playerForEvent(scorer.player, side);
        entries.push({ side, minute: parsed.display, player: scorer.player,
          lineupPlayer,
          text: formatGoalText(scorer.player, assist, parsed.isPenalty),
          kind: "goal", icon: "⚽",
          baseMinute: parsed.base, extraMinute: parsed.extra, sequence: sequence++ });
      }
      for (const minute of scorer.ownGoalTimes) {
        const parsed = parseMinute(minute);
        if (!parsed) continue;
        const lineupPlayer = playerForEvent(scorer.player, side);
        entries.push({ side, minute: parsed.display, player: scorer.player,
          lineupPlayer,
          text: `${abbreviatePlayerName(scorer.player)} (OG)`,
          kind: "own-goal", icon: "⚽",
          baseMinute: parsed.base, extraMinute: parsed.extra, sequence: sequence++ });
      }
      for (const minute of scorer.disallowedGoalTimes) {
        const parsed = parseMinute(minute);
        if (!parsed) continue;
        const assist = assistLookup.get(parsed.lookupKey) ?? assistLookup.get(String(parsed.base));
        const lineupPlayer = playerForEvent(scorer.player, side);
        entries.push({ side, minute: parsed.display, player: scorer.player,
          lineupPlayer,
          text: formatDisallowedGoalText(scorer.player, assist, parsed.isPenalty),
          kind: "disallowed-goal", icon: "⚽",
          baseMinute: parsed.base, extraMinute: parsed.extra, sequence: sequence++ });
      }
    }
  };

  addGoals(details.homeGoalScorers, "home", homeAssistLookup);
  addGoals(details.awayGoalScorers, "away", awayAssistLookup);

  for (const card of details.homeYellowCards) {
    for (const minute of card.yellowCardTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      entries.push({ side: "home", minute: parsed.display, player: card.player,
        lineupPlayer: playerForEvent(card.player, "home"),
        text: abbreviatePlayerName(card.player), kind: "yellow-card", icon: "🟨",
        baseMinute: parsed.base, extraMinute: parsed.extra, sequence: sequence++ });
    }
  }

  for (const card of details.awayYellowCards) {
    for (const minute of card.yellowCardTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      entries.push({ side: "away", minute: parsed.display, player: card.player,
        lineupPlayer: playerForEvent(card.player, "away"),
        text: abbreviatePlayerName(card.player), kind: "yellow-card", icon: "🟨",
        baseMinute: parsed.base, extraMinute: parsed.extra, sequence: sequence++ });
    }
  }

  for (const card of details.homeRedCards) {
    for (const minute of card.redCardTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      entries.push({ side: "home", minute: parsed.display, player: card.player,
        lineupPlayer: playerForEvent(card.player, "home"),
        text: abbreviatePlayerName(card.player), kind: "red-card", icon: "🟥",
        baseMinute: parsed.base, extraMinute: parsed.extra, sequence: sequence++ });
    }
  }

  for (const card of details.awayRedCards) {
    for (const minute of card.redCardTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      entries.push({ side: "away", minute: parsed.display, player: card.player,
        lineupPlayer: playerForEvent(card.player, "away"),
        text: abbreviatePlayerName(card.player), kind: "red-card", icon: "🟥",
        baseMinute: parsed.base, extraMinute: parsed.extra, sequence: sequence++ });
    }
  }

  return entries.sort((l, r) =>
    l.baseMinute  !== r.baseMinute  ? l.baseMinute  - r.baseMinute  :
    l.extraMinute !== r.extraMinute ? l.extraMinute - r.extraMinute :
    l.sequence    - r.sequence
  );
}

function timelinePlayerCandidates(lineup: MatchTeamLineup | null | undefined) {
  if (!lineup) return [];
  return [
    ...lineup.startingLineup,
    ...lineup.substitutes,
    ...lineup.substitutions.flatMap((substitution) => [
      substitution.playerOff,
      substitution.playerOn,
    ]),
  ];
}

function findTimelinePlayer(name: string, candidates: MatchLineupPlayer[]) {
  const lookup = buildPlayerNameLookup(name);
  let best: { player: MatchLineupPlayer; score: number } | null = null;
  for (const player of candidates) {
    const score = matchPlayerNameLookup(lookup, buildPlayerNameLookup(player.name));
    if (score <= 0) continue;
    if (!best || score > best.score) {
      best = { player, score };
    }
  }
  return best?.player ?? null;
}

function buildAssistLookup(assists: MatchAssistProvider[]) {
  const lookup = new Map<string, string>();
  for (const assist of assists) {
    for (const minute of assist.assistTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      lookup.set(parsed.lookupKey, abbreviatePlayerName(assist.player));
      if (!lookup.has(String(parsed.base))) {
        lookup.set(String(parsed.base), abbreviatePlayerName(assist.player));
      }
    }
  }
  return lookup;
}

function formatGoalText(player: string, assist: string | undefined, isPenalty: boolean) {
  const name = abbreviatePlayerName(player);
  if (isPenalty) return `${name} (pen)`;
  if (assist)    return `${name} (${assist})`;
  return name;
}

function formatDisallowedGoalText(player: string, assist: string | undefined, isPenalty: boolean) {
  return `Goal disallowed for ${formatGoalText(player, assist, isPenalty)}`;
}

function abbreviatePlayerName(fullName: string) {
  const trimmed = fullName.trim();
  const parts   = trimmed.split(/\s+/).filter(Boolean);
  if (parts.length <= 1) return trimmed;
  return `${parts.slice(0, -1).map((p) => `${p[0]}.`).join(" ")} ${parts.at(-1)}`;
}

function formattedMatchMinute(rawValue: string) {
  const t = rawValue.trim();
  if (!t) return "-";
  return t.includes("'") ? t : `${t}'`;
}

function condensedLineupPlayerName(value: string) {
  const trimmed       = value.trim();
  if (!trimmed) return trimmed;
  const hasCaptain    = /\(c\)/i.test(trimmed);
  const baseName      = trimmed.replace(/\(c\)/gi, "").trim();
  const parts         = baseName.split(/\s+/).filter(Boolean);
  const last          = parts.at(-1);
  if (!last) return trimmed;

  const particles = new Set([
    "al","bin","bint","da","de","del","della","den","der",
    "di","dos","du","el","la","le","st","ten","ter","van","von",
  ]);

  const surnameParts = [last];
  for (let i = parts.length - 2; i >= 0; i--) {
    const candidate = parts[i].toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
    if (!particles.has(candidate)) break;
    surnameParts.unshift(parts[i]);
  }

  const condensed = surnameParts.join(" ");
  return hasCaptain ? `${condensed} (c)` : condensed;
}


// ── Player name fuzzy matching ────────────────────────────────────

interface MatchPlayerNameLookup { full: string; initialAndLast: string; last: string; }

function buildPlayerNameLookup(name: string): MatchPlayerNameLookup {
  const cleaned    = name.replace(/\(c\)/gi, "");
  const normalized = cleaned.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
  const tokens     = normalized.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const first      = tokens[0] ?? "";
  const last       = tokens.at(-1) ?? "";
  return {
    full:           tokens.join(" "),
    initialAndLast: first && last ? `${first[0]} ${last}` : tokens.join(" "),
    last,
  };
}

function matchPlayerNameLookup(left: MatchPlayerNameLookup, right: MatchPlayerNameLookup) {
  if (!left.full || !right.full)                                         return 0;
  if (left.full === right.full)                                          return 3;
  if (left.initialAndLast && left.initialAndLast === right.initialAndLast) return 2;
  if (left.last && left.last === right.last)                             return 1;
  return 0;
}


// ── Minute parsing ────────────────────────────────────────────────

function parseMinute(rawValue: string) {
  const normalized = rawValue.trim();
  if (!normalized) return null;

  const isPenalty = normalized.toLowerCase().includes("pen");
  const m         = normalized.match(/(\d{1,3})(?:\s*')?(?:\+\s*(\d{1,2}))?/);
  if (!m) return null;

  const base  = Number(m[1]);
  const extra = m[2] ? Number(m[2]) : 0;

  return {
    base,
    extra,
    display:   extra > 0 ? `${base}+${extra}'` : `${base}'`,
    lookupKey: extra > 0 ? `${base}+${extra}` : String(base),
    isPenalty,
  };
}
