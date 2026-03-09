import { useEffect, useMemo, useState } from "react";
import { fetchMatchDetails } from "../api";
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
  MatchRedCardEvent,
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

      <div className="details-grid">
        <DetailsColumn
          teamName={details.homeTeam || "Home"}
          goals={details.homeGoalScorers}
          assists={details.homeAssists}
          redCards={details.homeRedCards}
        />
        <DetailsColumn
          teamName={details.awayTeam || "Away"}
          goals={details.awayGoalScorers}
          assists={details.awayAssists}
          redCards={details.awayRedCards}
        />
      </div>
    </div>
  );
}

interface DetailsColumnProps {
  teamName: string;
  goals: MatchGoalScorer[];
  assists: MatchAssistProvider[];
  redCards: MatchRedCardEvent[];
}

function DetailsColumn({ teamName, goals, assists, redCards }: DetailsColumnProps) {
  const goalRows = buildGoalRows(goals);
  const assistRows = buildAssistRows(assists);
  const redCardRows = buildRedCardRows(redCards);

  return (
    <section className="details-column">
      <div className="details-column-title">{teamName}</div>
      <DetailList title="Goals" rows={goalRows} emptyLabel="No scorers listed" />
      <DetailList title="Assists" rows={assistRows} emptyLabel="No assists listed" />
      <DetailList title="Red cards" rows={redCardRows} emptyLabel="No red cards listed" />
    </section>
  );
}

interface DetailListProps {
  title: string;
  rows: string[];
  emptyLabel: string;
}

function DetailList({ title, rows, emptyLabel }: DetailListProps) {
  return (
    <div className="details-subsection">
      <div className="details-subsection-title">{title}</div>
      {rows.length > 0 ? (
        <ul className="details-list">
          {rows.map((row) => (
            <li key={`${title}-${row}`}>{row}</li>
          ))}
        </ul>
      ) : (
        <div className="details-empty">{emptyLabel}</div>
      )}
    </div>
  );
}

function buildGoalRows(goals: MatchGoalScorer[]): string[] {
  return goals.flatMap((goal) => {
    const player = abbreviatePlayerName(goal.player);
    const rows: string[] = [];

    if (goal.goalTimes.length > 0) {
      rows.push(`${player} - ${goal.goalTimes.join(", ")}`);
    }
    if (goal.ownGoalTimes.length > 0) {
      rows.push(`${player} (OG) - ${goal.ownGoalTimes.join(", ")}`);
    }

    return rows;
  });
}

function buildAssistRows(assists: MatchAssistProvider[]): string[] {
  return assists.map((assist) => `${abbreviatePlayerName(assist.player)} - ${assist.assistTimes.join(", ")}`);
}

function buildRedCardRows(redCards: MatchRedCardEvent[]): string[] {
  return redCards.map((card) => `${abbreviatePlayerName(card.player)} - ${card.redCardTimes.join(", ")}`);
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
