import { useEffect, useMemo, useRef, useState } from "react";
import { fetchMatchDetails, shouldRetryMatchDetails } from "../api";
import {
  aggregateSummary,
  displayStatus,
  isMatchFinished,
  isMatchLive,
  parseKickoff,
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
  const [isExpanded, setIsExpanded] = useState(false);
  const [details, setDetails] = useState<MatchDetails | null>(match.matchDetails ?? null);
  const [detailsLoading, setDetailsLoading] = useState(false);
  const [detailsError, setDetailsError] = useState<string | null>(null);
  const retriedIncompleteDetailsIdRef = useRef<string | null>(null);

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
  const isExpandable = Boolean(match.matchDetailsId);
  const detailPanelId = `match-details-${match.id.replace(/[^a-zA-Z0-9_-]/g, "-")}`;

  useEffect(() => {
    setDetails(match.matchDetails ?? null);
    setDetailsLoading(false);
    setDetailsError(null);
    retriedIncompleteDetailsIdRef.current = null;
  }, [match.id]);

  useEffect(() => {
    if (!match.matchDetails) {
      return;
    }

    setDetails(match.matchDetails);
    setDetailsLoading(false);
    setDetailsError(null);
  }, [match.matchDetails]);

  useEffect(() => {
    let cancelled = false;

    if (!isExpanded || !match.matchDetailsId || details || detailsError) {
      return () => {
        cancelled = true;
      };
    }

    setDetailsLoading(true);
    setDetailsError(null);

    void fetchMatchDetails(match.matchDetailsId)
      .then((payload) => {
        if (!cancelled) {
          setDetails(payload);
        }
      })
      .catch((error) => {
        if (!cancelled) {
          if (
            error &&
            typeof error === "object" &&
            "status" in error &&
            error.status === 404
          ) {
            setDetailsError("Match details are not available for this fixture yet.");
          } else {
            setDetailsError(
              error instanceof Error ? error.message : "Match details unavailable."
            );
          }
        }
      })
      .finally(() => {
        if (!cancelled) {
          setDetailsLoading(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [details, detailsError, isExpanded, match.matchDetailsId]);

  useEffect(() => {
    let cancelled = false;

    if (
      !isExpanded ||
      !match.matchDetailsId ||
      !details ||
      !shouldRetryMatchDetails(details) ||
      retriedIncompleteDetailsIdRef.current === match.matchDetailsId
    ) {
      return () => {
        cancelled = true;
      };
    }

    retriedIncompleteDetailsIdRef.current = match.matchDetailsId;
    const retryTimer = window.setTimeout(() => {
      void fetchMatchDetails(match.matchDetailsId)
        .then((payload) => {
          if (!cancelled) {
            setDetails(payload);
            setDetailsError(null);
          }
        })
        .catch((error) => {
          if (!cancelled) {
            setDetailsError(
              error instanceof Error ? error.message : "Match details unavailable."
            );
          }
        });
    }, 1500);

    return () => {
      cancelled = true;
      window.clearTimeout(retryTimer);
    };
  }, [details, isExpanded, match.matchDetailsId]);

  const summary = (
    <>
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
        <div className="match-footer-right">
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
          {isExpandable && (
            <span className={`match-chevron${isExpanded ? " is-expanded" : ""}`} aria-hidden="true">
              <svg viewBox="0 0 20 20">
                <path d="m5 7 5 5 5-5" />
              </svg>
            </span>
          )}
        </div>
      </div>
    </>
  );

  return (
    <article className={`match-card${highlightToday ? " is-highlighted" : ""}`}>
      {isExpandable ? (
        <button
          type="button"
          className="match-summary-button"
          onClick={() => setIsExpanded((current) => !current)}
          aria-expanded={isExpanded}
          aria-controls={detailPanelId}
        >
          {summary}
        </button>
      ) : (
        <div className="match-summary-static">{summary}</div>
      )}

      {isExpandable && isExpanded && (
        <div className="match-details-panel" id={detailPanelId}>
          {detailsLoading ? (
            <div className="match-details-message">Loading match details...</div>
          ) : detailsError ? (
            <div className="match-details-message is-error">{detailsError}</div>
          ) : details ? (
            <ExpandedMatchDetails details={details} />
          ) : (
            <div className="match-details-message">No additional match details available.</div>
          )}
        </div>
      )}
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
      src={`/logos/team?name=${encodeURIComponent(teamName)}`}
      alt=""
      onError={onMissing}
    />
  );
}

interface ExpandedMatchDetailsProps {
  details: MatchDetails;
}

function ExpandedMatchDetails({ details }: ExpandedMatchDetailsProps) {
  const timelineEntries = useMemo(() => buildTimelineEntries(details), [details]);
  const hasCompleteLineups = hasRenderableTeamLineups(details.teamLineups);

  if (timelineEntries.length === 0 && !hasCompleteLineups) {
    return <div className="match-details-message">No additional match details available.</div>;
  }

  return (
    <div className="match-details-body">
      {timelineEntries.length > 0 && (
        <section className="details-section">
          <div className="details-section-title">Key events</div>
          <div className="timeline-list">
            {timelineEntries.map((entry) => (
              <div
                className={`timeline-row timeline-row-${entry.side}`}
                key={`${entry.side}-${entry.kind}-${entry.minute}-${entry.player}`}
              >
                <span className="timeline-minute">{entry.minute}</span>
                <span className={`timeline-kind timeline-kind-${entry.kind}`}>{entry.icon}</span>
                <span className="timeline-text">{entry.text}</span>
              </div>
            ))}
          </div>
        </section>
      )}

      {hasCompleteLineups && <LineupSection details={details} teamLineups={details.teamLineups} />}
    </div>
  );
}

interface LineupSectionProps {
  details: MatchDetails;
  teamLineups: MatchTeamLineups;
}

function LineupSection({ details, teamLineups }: LineupSectionProps) {
  const homeLineup = teamLineups.home!;
  const awayLineup = teamLineups.away!;
  const homeLookup = buildLineupEventLookup({
    goals: details.homeGoalScorers,
    assists: details.homeAssists,
    yellowCards: details.homeYellowCards,
    redCards: details.homeRedCards,
    substitutions: homeLineup.substitutions,
  });
  const awayLookup = buildLineupEventLookup({
    goals: details.awayGoalScorers,
    assists: details.awayAssists,
    yellowCards: details.awayYellowCards,
    redCards: details.awayRedCards,
    substitutions: awayLineup.substitutions,
  });

  return (
    <section className="details-section lineup-section">
      <div className="details-section-title">Starting Line-ups</div>
      <div className="lineup-formations">
        <div className="lineup-formation-chip">
          <span className="lineup-formation-team">{homeLineup.team || details.homeTeam || "Home"}</span>
          <span className="lineup-formation-value">{homeLineup.formation || "Formation TBC"}</span>
        </div>
        <div className="lineup-formation-chip lineup-formation-chip-away">
          <span className="lineup-formation-team">{awayLineup.team || details.awayTeam || "Away"}</span>
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
            teamName={homeLineup.team || details.homeTeam || "Home"}
            starters={homeLineup.startingLineup}
            lookup={homeLookup}
            side="home"
          />
          <LineupHalf
            teamName={awayLineup.team || details.awayTeam || "Away"}
            starters={awayLineup.startingLineup}
            lookup={awayLookup}
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

interface LineupHalfProps {
  teamName: string;
  starters: MatchLineupPlayer[];
  lookup: MatchLineupEventLookup;
  side: "home" | "away";
}

function LineupHalf({ teamName, starters, lookup, side }: LineupHalfProps) {
  const groupedRows = buildDisplayLineupRows(starters, side);

  return (
    <div className={`lineup-half lineup-half-${side}`}>
      {side === "away" && <div className="lineup-half-spacer" aria-hidden="true" />}

      {side === "home" && <div className="lineup-team-label">{teamName.toUpperCase()}</div>}

      <div className="lineup-half-rows">
        {groupedRows.map((row, rowIndex) => (
          <div
            className="lineup-row"
            key={`${side}-${rowIndex}`}
            style={{ gridTemplateColumns: `repeat(${row.players.length}, minmax(0, 1fr))` }}
          >
            {row.players.map((player) => (
              <LineupPlayerMarker
                key={`${side}-${player.number}-${player.name}`}
                player={player}
                summary={lookup.summaryFor(player)}
                replacementSummary={lookup.replacementSummaryFor(player)}
                side={side}
              />
            ))}
          </div>
        ))}
      </div>

      {side === "home" ? (
        <div className="lineup-half-spacer" aria-hidden="true" />
      ) : (
        <div className="lineup-team-label lineup-team-label-away">{teamName.toUpperCase()}</div>
      )}
    </div>
  );
}

interface LineupPlayerMarkerProps {
  player: MatchLineupPlayer;
  summary: MatchLineupPlayerEventSummary;
  replacementSummary: MatchLineupPlayerEventSummary | null;
  side: "home" | "away";
}

function LineupPlayerMarker({
  player,
  summary,
  replacementSummary,
  side,
}: LineupPlayerMarkerProps) {
  const replacementPlayer = summary.substitution?.playerOn ?? null;
  const badgeItems = buildPlayerBadgeItems(summary);
  const replacementBadgeItems = replacementSummary ? buildPlayerBadgeItems(replacementSummary) : [];

  return (
    <div className="lineup-player">
      <div className={`lineup-player-number lineup-player-number-${side}`}>{player.number}</div>

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
                {condensedLineupPlayerName(replacementPlayer.name)} ({formattedMatchMinute(summary.substitution?.minute || "")})
              </span>
            </div>
            {replacementBadgeItems.length > 0 && (
              <div className="lineup-player-badges">
                {replacementBadgeItems.map((badge) => (
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

interface LineupSubstitutesTableProps {
  lineup: MatchTeamLineup;
}

function LineupSubstitutesTable({ lineup }: LineupSubstitutesTableProps) {
  return (
    <section className="lineup-substitutes-table">
      <div className="lineup-substitutes-title">{(lineup.team || "Team").toUpperCase()} SUBSTITUTES</div>

      <div className="lineup-substitutes-card">
        {lineup.substitutes.map((substitute, index) => {
          const substitution =
            lineup.substitutions.find((item) => item.playerOn.number === substitute.number) || null;
          return (
            <div className="lineup-substitute-row" key={`${lineup.team}-${substitute.number}-${substitute.name}`}>
              <div className="lineup-substitute-number">{substitute.number}</div>
              <div className="lineup-substitute-copy">
                <div className="lineup-substitute-name">{condensedLineupPlayerName(substitute.name)}</div>
                {substitution && (
                  <div className="lineup-substitute-meta">
                    <span className="lineup-sub-arrow lineup-sub-arrow-on">↑</span>
                    <span>
                      {formattedMatchMinute(substitution.minute)} for {condensedLineupPlayerName(substitution.playerOff.name)}
                    </span>
                  </div>
                )}
              </div>
              {index < lineup.substitutes.length - 1 && <div className="lineup-substitute-divider" />}
            </div>
          );
        })}
      </div>
    </section>
  );
}

interface LineupEventBadgeDescriptor {
  kind: "goal" | "assist" | "yellow-card" | "red-card";
  count: number;
}

function LineupEventBadge({ badge }: { badge: LineupEventBadgeDescriptor }) {
  const label = badge.kind === "goal" ? "⚽" : badge.kind === "assist" ? "A" : "";
  const cardClass =
    badge.kind === "yellow-card"
      ? " lineup-event-badge-card-yellow"
      : badge.kind === "red-card"
        ? " lineup-event-badge-card-red"
        : "";

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

function hasRenderableTeamLineups(
  teamLineups: MatchTeamLineups | null | undefined
): teamLineups is MatchTeamLineups & { home: MatchTeamLineup; away: MatchTeamLineup } {
  return Boolean(
    teamLineups?.home &&
      teamLineups.away &&
      teamLineups.home.startingLineup.length === 11 &&
      teamLineups.away.startingLineup.length === 11
  );
}

interface LineupRow {
  players: MatchLineupPlayer[];
  slotCount: number;
}

function buildDisplayLineupRows(starters: MatchLineupPlayer[], side: "home" | "away") {
  const rows = buildLineupRows(starters);
  return side === "home" ? rows : [...rows].reverse();
}

function buildLineupRows(starters: MatchLineupPlayer[]): LineupRow[] {
  const playersWithFormationRows = starters.filter(
    (player) =>
      typeof player.formationRowIndex === "number" && typeof player.formationSlotIndex === "number"
  );

  if (playersWithFormationRows.length === starters.length) {
    const groupedByRow = new Map<number, MatchLineupPlayer[]>();
    for (const player of starters) {
      const rowIndex = player.formationRowIndex ?? 0;
      const row = groupedByRow.get(rowIndex) ?? [];
      row.push(player);
      groupedByRow.set(rowIndex, row);
    }

    return Array.from(groupedByRow.entries())
      .sort((left, right) => left[0] - right[0])
      .map(([, row]) => {
        const players = [...row].sort((left, right) => {
          const leftSlot = left.formationSlotIndex ?? 0;
          const rightSlot = right.formationSlotIndex ?? 0;
          if (leftSlot !== rightSlot) {
            return leftSlot - rightSlot;
          }
          return left.number - right.number;
        });
        return {
          players,
          slotCount: Math.max(...players.map((player) => player.formationRowSize ?? players.length), players.length),
        };
      });
  }

  const goalkeepers = starters.filter((player) => player.positionCategory === "goalkeeper");
  const defenders = starters.filter((player) => player.positionCategory === "defender");
  const midfielders = starters.filter((player) => player.positionCategory === "midfielder");
  const attackers = starters.filter((player) => player.positionCategory === "attacker");
  return [goalkeepers, defenders, midfielders, attackers]
    .filter((row) => row.length > 0)
    .map((players) => ({ players, slotCount: players.length }));
}

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
  goals,
  assists,
  yellowCards,
  redCards,
  substitutions,
}: {
  goals: MatchGoalScorer[];
  assists: MatchAssistProvider[];
  yellowCards: MatchYellowCardEvent[];
  redCards: MatchRedCardEvent[];
  substitutions: MatchLineupSubstitution[];
}): MatchLineupEventLookup {
  const goalEntries = goals.map((goal) => ({
    count: goal.goalTimes.length,
    lookup: buildPlayerNameLookup(goal.player),
  }));
  const assistEntries = assists.map((assist) => ({
    count: assist.assistTimes.length,
    lookup: buildPlayerNameLookup(assist.player),
  }));
  const yellowCardEntries = yellowCards.map((card) => ({
    count: card.yellowCardTimes.length,
    lookup: buildPlayerNameLookup(card.player),
  }));
  const redCardEntries = redCards.map((card) => ({
    count: card.redCardTimes.length,
    lookup: buildPlayerNameLookup(card.player),
  }));

  const bestCount = (playerName: string, entries: Array<{ count: number; lookup: MatchPlayerNameLookup }>) => {
    const lookup = buildPlayerNameLookup(playerName);
    const best = entries.reduce<{ count: number; score: number } | null>((current, entry) => {
      const score = matchPlayerNameLookup(lookup, entry.lookup);
      if (score <= 0) {
        return current;
      }
      if (!current || score > current.score || (score === current.score && entry.count > current.count)) {
        return { count: entry.count, score };
      }
      return current;
    }, null);

    return best?.count ?? 0;
  };

  return {
    summaryFor(player) {
      return {
        goals: bestCount(player.name, goalEntries),
        assists: bestCount(player.name, assistEntries),
        yellowCards: bestCount(player.name, yellowCardEntries),
        redCards: bestCount(player.name, redCardEntries),
        substitution: substitutions.find((item) => item.playerOff.number === player.number) || null,
      };
    },
    replacementSummaryFor(player) {
      const substitution = substitutions.find((item) => item.playerOff.number === player.number);
      if (!substitution) {
        return null;
      }

      return {
        goals: bestCount(substitution.playerOn.name, goalEntries),
        assists: bestCount(substitution.playerOn.name, assistEntries),
        yellowCards: bestCount(substitution.playerOn.name, yellowCardEntries),
        redCards: bestCount(substitution.playerOn.name, redCardEntries),
        substitution: null,
      };
    },
  };
}

function buildPlayerBadgeItems(summary: MatchLineupPlayerEventSummary): LineupEventBadgeDescriptor[] {
  const badges: LineupEventBadgeDescriptor[] = [];
  if (summary.goals > 0) {
    badges.push({ kind: "goal", count: summary.goals });
  }
  if (summary.assists > 0) {
    badges.push({ kind: "assist", count: summary.assists });
  }
  if (summary.yellowCards > 0) {
    badges.push({ kind: "yellow-card", count: summary.yellowCards });
  }
  if (summary.redCards > 0) {
    badges.push({ kind: "red-card", count: summary.redCards });
  }
  return badges;
}

function buildTimelineEntries(details: MatchDetails) {
  const homeAssistLookup = buildAssistLookup(details.homeAssists);
  const awayAssistLookup = buildAssistLookup(details.awayAssists);
  const entries: Array<{
    side: "home" | "away";
    minute: string;
    player: string;
    text: string;
    kind: string;
    icon: string;
    baseMinute: number;
    extraMinute: number;
    sequence: number;
  }> = [];
  let sequence = 0;

  for (const scorer of details.homeGoalScorers) {
    for (const minute of scorer.goalTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      const assist = homeAssistLookup.get(parsed.lookupKey) || homeAssistLookup.get(String(parsed.base));
      entries.push({
        side: "home",
        minute: parsed.display,
        player: scorer.player,
        text: formatGoalText(scorer.player, assist, parsed.isPenalty),
        kind: "goal",
        icon: "⚽",
        baseMinute: parsed.base,
        extraMinute: parsed.extra,
        sequence: sequence++,
      });
    }
    for (const minute of scorer.ownGoalTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      entries.push({
        side: "home",
        minute: parsed.display,
        player: scorer.player,
        text: `${abbreviatePlayerName(scorer.player)} (OG)`,
        kind: "own-goal",
        icon: "⚽",
        baseMinute: parsed.base,
        extraMinute: parsed.extra,
        sequence: sequence++,
      });
    }
    for (const minute of scorer.disallowedGoalTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      const assist = homeAssistLookup.get(parsed.lookupKey) || homeAssistLookup.get(String(parsed.base));
      entries.push({
        side: "home",
        minute: parsed.display,
        player: scorer.player,
        text: formatDisallowedGoalText(scorer.player, assist, parsed.isPenalty),
        kind: "disallowed-goal",
        icon: "⚽",
        baseMinute: parsed.base,
        extraMinute: parsed.extra,
        sequence: sequence++,
      });
    }
  }

  for (const scorer of details.awayGoalScorers) {
    for (const minute of scorer.goalTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      const assist = awayAssistLookup.get(parsed.lookupKey) || awayAssistLookup.get(String(parsed.base));
      entries.push({
        side: "away",
        minute: parsed.display,
        player: scorer.player,
        text: formatGoalText(scorer.player, assist, parsed.isPenalty),
        kind: "goal",
        icon: "⚽",
        baseMinute: parsed.base,
        extraMinute: parsed.extra,
        sequence: sequence++,
      });
    }
    for (const minute of scorer.ownGoalTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      entries.push({
        side: "away",
        minute: parsed.display,
        player: scorer.player,
        text: `${abbreviatePlayerName(scorer.player)} (OG)`,
        kind: "own-goal",
        icon: "⚽",
        baseMinute: parsed.base,
        extraMinute: parsed.extra,
        sequence: sequence++,
      });
    }
    for (const minute of scorer.disallowedGoalTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      const assist = awayAssistLookup.get(parsed.lookupKey) || awayAssistLookup.get(String(parsed.base));
      entries.push({
        side: "away",
        minute: parsed.display,
        player: scorer.player,
        text: formatDisallowedGoalText(scorer.player, assist, parsed.isPenalty),
        kind: "disallowed-goal",
        icon: "⚽",
        baseMinute: parsed.base,
        extraMinute: parsed.extra,
        sequence: sequence++,
      });
    }
  }

  for (const card of details.homeRedCards) {
    for (const minute of card.redCardTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      entries.push({
        side: "home",
        minute: parsed.display,
        player: card.player,
        text: abbreviatePlayerName(card.player),
        kind: "red-card",
        icon: "🟥",
        baseMinute: parsed.base,
        extraMinute: parsed.extra,
        sequence: sequence++,
      });
    }
  }

  for (const card of details.awayRedCards) {
    for (const minute of card.redCardTimes) {
      const parsed = parseMinute(minute);
      if (!parsed) continue;
      entries.push({
        side: "away",
        minute: parsed.display,
        player: card.player,
        text: abbreviatePlayerName(card.player),
        kind: "red-card",
        icon: "🟥",
        baseMinute: parsed.base,
        extraMinute: parsed.extra,
        sequence: sequence++,
      });
    }
  }

  return entries.sort((left, right) => {
    if (left.baseMinute !== right.baseMinute) {
      return left.baseMinute - right.baseMinute;
    }
    if (left.extraMinute !== right.extraMinute) {
      return left.extraMinute - right.extraMinute;
    }
    return left.sequence - right.sequence;
  });
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
  if (isPenalty) {
    return `${name} (pen)`;
  }
  if (assist) {
    return `${name} (${assist})`;
  }
  return name;
}

function formatDisallowedGoalText(player: string, assist: string | undefined, isPenalty: boolean) {
  return `Goal disallowed for ${formatGoalText(player, assist, isPenalty)}`;
}

function abbreviatePlayerName(fullName: string) {
  const trimmed = fullName.trim();
  const parts = trimmed.split(/\s+/).filter(Boolean);
  if (parts.length <= 1) {
    return trimmed;
  }

  return `${parts.slice(0, -1).map((part) => `${part[0]}.`).join(" ")} ${parts.at(-1)}`;
}

function formattedMatchMinute(rawValue: string) {
  const trimmed = rawValue.trim();
  if (!trimmed) {
    return "-";
  }
  return trimmed.includes("'") ? trimmed : `${trimmed}'`;
}

function condensedLineupPlayerName(value: string) {
  const trimmed = value.trim();
  if (!trimmed) {
    return trimmed;
  }

  const hasCaptainSuffix = /\(c\)/i.test(trimmed);
  const baseName = trimmed.replace(/\(c\)/gi, "").trim();
  const parts = baseName.split(/\s+/).filter(Boolean);
  const last = parts.at(-1);
  if (!last) {
    return trimmed;
  }

  const particles = new Set([
    "al",
    "bin",
    "bint",
    "da",
    "de",
    "del",
    "della",
    "den",
    "der",
    "di",
    "dos",
    "du",
    "el",
    "la",
    "le",
    "st",
    "ten",
    "ter",
    "van",
    "von",
  ]);

  const surnameParts = [last];
  for (let index = parts.length - 2; index >= 0; index -= 1) {
    const candidate = parts[index].toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
    if (!particles.has(candidate)) {
      break;
    }
    surnameParts.unshift(parts[index]);
  }

  const condensed = surnameParts.join(" ");
  return hasCaptainSuffix ? `${condensed} (c)` : condensed;
}

interface MatchPlayerNameLookup {
  full: string;
  initialAndLast: string;
  last: string;
}

function buildPlayerNameLookup(name: string): MatchPlayerNameLookup {
  const cleaned = name.replace(/\(c\)/gi, "");
  const normalized = cleaned
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
  const tokens = normalized.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const first = tokens[0] ?? "";
  const last = tokens.at(-1) ?? "";

  return {
    full: tokens.join(" "),
    initialAndLast: first && last ? `${first[0]} ${last}` : tokens.join(" "),
    last,
  };
}

function matchPlayerNameLookup(left: MatchPlayerNameLookup, right: MatchPlayerNameLookup) {
  if (!left.full || !right.full) {
    return 0;
  }
  if (left.full === right.full) {
    return 3;
  }
  if (left.initialAndLast && left.initialAndLast === right.initialAndLast) {
    return 2;
  }
  if (left.last && left.last === right.last) {
    return 1;
  }
  return 0;
}

function parseMinute(rawValue: string) {
  const normalized = rawValue.trim();
  if (!normalized) {
    return null;
  }

  const isPenalty = normalized.toLowerCase().includes("pen");
  const match = normalized.match(/(\d{1,3})(?:\s*')?(?:\+\s*(\d{1,2}))?/);
  if (!match) {
    return null;
  }

  const base = Number(match[1]);
  const extra = match[2] ? Number(match[2]) : 0;
  const display = extra > 0 ? `${base}+${extra}'` : `${base}'`;

  return {
    base,
    extra,
    display,
    lookupKey: extra > 0 ? `${base}+${extra}` : String(base),
    isPenalty,
  };
}
