import { type CSSProperties, useEffect, useMemo, useRef, useState } from "react";
import { fetchMatchDetails, shouldRetryMatchDetails } from "../api";
import {
  aggregateSummary,
  displayStatus,
  isMatchFinished,
  isMatchLive,
} from "../matchGrouping";
import { type ResolvedTeamColors, useTeamColorCatalog } from "../teamColors";
import type {
  Match,
  MatchAssistProvider,
  MatchDetails,
  MatchGoalScorer,
  MatchLineupPlayer,
  MatchLineupSubstitution,
  MatchTeamLineup,
  MatchTeamLineups,
  MatchRedCardEvent,
  MatchYellowCardEvent,
} from "../types";

interface MatchCardProps {
  match: Match;
  highlightToday?: boolean;
}

export function MatchCard({ match, highlightToday = false }: MatchCardProps) {
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
  const hasTvLogo  = match.tvChannels.length > 0;
  // Show TV logo in centre for upcoming fixtures; for live matches with scores, show flanking scores instead
  const showTvOnly = !hasScore && hasTvLogo;
  const showLiveScore = isLive && hasScore;
  // Right column: penalty result overrides; otherwise the status string (FT / AET / 45' / 15:00)
  const rightText  = match.penaltyResult ?? status;

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
        {match.homeTeam}
      </div>

      {/* Centre column: score OR TV logos */}
      <div className="match-center">
        {showLiveScore ? (
          <div className="mc-score">
            <span className="mc-num">{match.homeScore}</span>
            {hasTvLogo ? (
              <img
                key={`${match.id}-tv-0`}
                src={`/logos/tv/${encodeURIComponent(match.tvChannels[0])}`}
                alt=""
                className="mc-tv-logo"
                onError={(e) => { e.currentTarget.style.display = "none"; }}
              />
            ) : (
              <span className="mc-sep">—</span>
            )}
            <span className="mc-num">{match.awayScore}</span>
          </div>
        ) : showTvOnly ? (
          <div className="mc-tv">
            <img
              key={`${match.id}-tv-0`}
              src={`/logos/tv/${encodeURIComponent(match.tvChannels[0])}`}
              alt=""
              className="mc-tv-logo"
              onError={(e) => { e.currentTarget.style.display = "none"; }}
            />
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
        {match.awayTeam}
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
            <ExpandedMatchDetails details={details} tvChannels={match.tvChannels} isFinished={isMatchFinished(match)} />
          ) : (
            <div className="match-details-message">No additional match details available.</div>
          )}
        </div>
      )}
    </article>
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

function ExpandedMatchDetails({ details, tvChannels = [], isFinished = false }: { details: MatchDetails; tvChannels?: string[]; isFinished?: boolean }) {
  const timelineEntries   = useMemo(() => buildTimelineEntries(details), [details]);
  const hasCompleteLineups = hasRenderableTeamLineups(details.teamLineups);

  const showTvSection = !isFinished && tvChannels.length > 0;

  if (timelineEntries.length === 0 && !hasCompleteLineups && !showTvSection) {
    return <div className="match-details-message">No additional match details available.</div>;
  }

  return (
    <div className="match-details-body">
      {showTvSection && (
        <section className="details-section">
          <div className="details-section-title">TV Coverage</div>
          <div className="details-tv-channels">
            {tvChannels.map((channel) => (
              <div key={channel} className="details-tv-channel-row">
                <img
                  src={`/logos/tv/${encodeURIComponent(channel)}`}
                  alt=""
                  className="details-tv-channel-logo"
                  onError={(e) => { e.currentTarget.style.display = "none"; }}
                />
                <span className="details-tv-channel-name">{channel}</span>
              </div>
            ))}
          </div>
        </section>
      )}
      {timelineEntries.length > 0 && (
        <section className="details-section">
          <div className="details-section-title">Key events</div>
          <div className="timeline-list">
            {timelineEntries.map((entry) => (
              <div
                key={`${entry.side}-${entry.kind}-${entry.minute}-${entry.player}`}
                className={`timeline-row timeline-row-${entry.side}`}
              >
                <span className="timeline-minute">{entry.minute}</span>
                <span className={`timeline-kind timeline-kind-${entry.kind}`}>{entry.icon}</span>
                <span className="timeline-text">{entry.text}</span>
              </div>
            ))}
          </div>
        </section>
      )}

      {hasCompleteLineups && <LineupSection details={details} teamLineups={details.teamLineups!} />}
    </div>
  );
}


// ── Lineup section ────────────────────────────────────────────────

interface LineupSectionProps {
  details: MatchDetails;
  teamLineups: MatchTeamLineups;
}

function LineupSection({ details, teamLineups }: LineupSectionProps) {
  const teamColorCatalog = useTeamColorCatalog();
  const homeLineup       = teamLineups.home!;
  const awayLineup       = teamLineups.away!;

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
  const homeNumberColors = teamColorCatalog.lineupColors(homeTeamName, awayTeamName, "home");
  const awayNumberColors = teamColorCatalog.lineupColors(awayTeamName, homeTeamName, "away");

  return (
    <section className="details-section lineup-section">
      <div className="details-section-title">Starting Line-ups</div>

      <div className="lineup-formations">
        <div className="lineup-formation-chip">
          <span className="lineup-formation-team">{homeTeamName}</span>
          <span className="lineup-formation-value">{homeLineup.formation || "Formation TBC"}</span>
        </div>
        <div className="lineup-formation-chip lineup-formation-chip-away">
          <span className="lineup-formation-team">{awayTeamName}</span>
          <span className="lineup-formation-value">{awayLineup.formation || "Formation TBC"}</span>
        </div>
      </div>

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
            numberColors={homeNumberColors}
            side="home"
          />
          <LineupHalf
            teamName={awayTeamName}
            starters={awayLineup.startingLineup}
            lookup={awayLookup}
            numberColors={awayNumberColors}
            side="away"
          />
        </div>
      </div>

      <div className="lineup-substitutes-grid">
        <LineupSubstitutesTable lineup={homeLineup} />
        <LineupSubstitutesTable lineup={awayLineup} />
      </div>
    </section>
  );
}


// ── Lineup half ───────────────────────────────────────────────────

interface LineupHalfProps {
  teamName: string;
  starters: MatchLineupPlayer[];
  lookup: MatchLineupEventLookup;
  numberColors: ResolvedTeamColors;
  side: "home" | "away";
}

function LineupHalf({ teamName, starters, lookup, numberColors, side }: LineupHalfProps) {
  const groupedRows = buildDisplayLineupRows(starters, side);

  return (
    <div className={`lineup-half lineup-half-${side}`}>
      {side === "away" && <div className="lineup-half-spacer" aria-hidden="true" />}
      {side === "home" && <div className="lineup-team-label">{teamName.toUpperCase()}</div>}

      <div className="lineup-half-rows">
        {groupedRows.map((row, rowIndex) => (
          <div
            key={`${side}-${rowIndex}`}
            className="lineup-row"
            style={{ gridTemplateColumns: `repeat(${row.players.length}, minmax(0, 1fr))` }}
          >
            {row.players.map((player) => (
              <LineupPlayerMarker
                key={`${side}-${player.number}-${player.name}`}
                player={player}
                summary={lookup.summaryFor(player)}
                replacementSummary={lookup.replacementSummaryFor(player)}
                numberColors={numberColors}
              />
            ))}
          </div>
        ))}
      </div>

      {side === "home"
        ? <div className="lineup-half-spacer" aria-hidden="true" />
        : <div className="lineup-team-label lineup-team-label-away">{teamName.toUpperCase()}</div>
      }
    </div>
  );
}


// ── Player marker ─────────────────────────────────────────────────

interface LineupPlayerMarkerProps {
  player: MatchLineupPlayer;
  summary: MatchLineupPlayerEventSummary;
  replacementSummary: MatchLineupPlayerEventSummary | null;
  numberColors: ResolvedTeamColors;
}

function LineupPlayerMarker({ player, summary, replacementSummary, numberColors }: LineupPlayerMarkerProps) {
  const replacementPlayer = summary.substitution?.playerOn ?? null;
  const badgeItems        = buildPlayerBadgeItems(summary);
  const replacementBadges = replacementSummary ? buildPlayerBadgeItems(replacementSummary) : [];

  const numberStyle = {
    "--lineup-player-number-bg":     numberColors.background,
    "--lineup-player-number-fg":     numberColors.foreground,
    "--lineup-player-number-stroke": numberColors.outlineColor ?? "transparent",
  } as CSSProperties;

  return (
    <div className="lineup-player">
      <div className="lineup-player-number" style={numberStyle}>{player.number}</div>

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
          <span className="lineup-player-name">{condensedLineupPlayerName(player.name)}</span>
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


// ── Guard: only render lineup when both teams have 11 starters ────

function hasRenderableTeamLineups(
  teamLineups: MatchTeamLineups | null | undefined
): teamLineups is MatchTeamLineups & { home: MatchTeamLineup; away: MatchTeamLineup } {
  return Boolean(
    teamLineups?.home && teamLineups.away &&
    teamLineups.home.startingLineup.length === 11 &&
    teamLineups.away.startingLineup.length === 11
  );
}


// ── Lineup row building ───────────────────────────────────────────

interface LineupRow {
  players: MatchLineupPlayer[];
  slotCount: number;
}

function buildDisplayLineupRows(starters: MatchLineupPlayer[], side: "home" | "away") {
  const rows = buildLineupRows(starters);
  return side === "home" ? rows : [...rows].reverse();
}

function buildLineupRows(starters: MatchLineupPlayer[]): LineupRow[] {
  const withFormation = starters.filter(
    (p) => typeof p.formationRowIndex === "number" && typeof p.formationSlotIndex === "number"
  );

  if (withFormation.length === starters.length) {
    const groupedByRow = new Map<number, MatchLineupPlayer[]>();
    for (const player of starters) {
      const rowIndex = player.formationRowIndex ?? 0;
      const row      = groupedByRow.get(rowIndex) ?? [];
      row.push(player);
      groupedByRow.set(rowIndex, row);
    }

    return Array.from(groupedByRow.entries())
      .sort(([a], [b]) => a - b)
      .map(([, row]) => {
        const players = [...row].sort((l, r) => {
          const ls = l.formationSlotIndex ?? 0;
          const rs = r.formationSlotIndex ?? 0;
          return ls !== rs ? ls - rs : l.number - r.number;
        });
        return {
          players,
          slotCount: Math.max(...players.map((p) => p.formationRowSize ?? players.length), players.length),
        };
      });
  }

  // Fallback: group by position category
  const goalkeepers = starters.filter((p) => p.positionCategory === "goalkeeper");
  const defenders   = starters.filter((p) => p.positionCategory === "defender");
  const midfielders = starters.filter((p) => p.positionCategory === "midfielder");
  const attackers   = starters.filter((p) => p.positionCategory === "attacker");
  return [goalkeepers, defenders, midfielders, attackers]
    .filter((row) => row.length > 0)
    .map((players) => ({ players, slotCount: players.length }));
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
        substitution: substitutions.find((s) => s.playerOff.number === player.number) ?? null,
      };
    },
    replacementSummaryFor(player) {
      const sub = substitutions.find((s) => s.playerOff.number === player.number);
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

function buildTimelineEntries(details: MatchDetails) {
  const homeAssistLookup = buildAssistLookup(details.homeAssists);
  const awayAssistLookup = buildAssistLookup(details.awayAssists);

  type Entry = {
    side: "home" | "away"; minute: string; player: string;
    text: string; kind: string; icon: string;
    baseMinute: number; extraMinute: number; sequence: number;
  };

  const entries: Entry[] = [];
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
        entries.push({ side, minute: parsed.display, player: scorer.player,
          text: formatGoalText(scorer.player, assist, parsed.isPenalty),
          kind: "goal", icon: "⚽",
          baseMinute: parsed.base, extraMinute: parsed.extra, sequence: sequence++ });
      }
      for (const minute of scorer.ownGoalTimes) {
        const parsed = parseMinute(minute);
        if (!parsed) continue;
        entries.push({ side, minute: parsed.display, player: scorer.player,
          text: `${abbreviatePlayerName(scorer.player)} (OG)`,
          kind: "own-goal", icon: "⚽",
          baseMinute: parsed.base, extraMinute: parsed.extra, sequence: sequence++ });
      }
      for (const minute of scorer.disallowedGoalTimes) {
        const parsed = parseMinute(minute);
        if (!parsed) continue;
        const assist = assistLookup.get(parsed.lookupKey) ?? assistLookup.get(String(parsed.base));
        entries.push({ side, minute: parsed.display, player: scorer.player,
          text: formatDisallowedGoalText(scorer.player, assist, parsed.isPenalty),
          kind: "disallowed-goal", icon: "⚽",
          baseMinute: parsed.base, extraMinute: parsed.extra, sequence: sequence++ });
      }
    }
  };

  addGoals(details.homeGoalScorers, "home", homeAssistLookup);
  addGoals(details.awayGoalScorers, "away", awayAssistLookup);

  for (const card of details.homeRedCards) {
    for (const minute of card.redCardTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      entries.push({ side: "home", minute: parsed.display, player: card.player,
        text: abbreviatePlayerName(card.player), kind: "red-card", icon: "🟥",
        baseMinute: parsed.base, extraMinute: parsed.extra, sequence: sequence++ });
    }
  }

  for (const card of details.awayRedCards) {
    for (const minute of card.redCardTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      entries.push({ side: "away", minute: parsed.display, player: card.player,
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
