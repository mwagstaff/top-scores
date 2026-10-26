import { goalSummary } from "../goalSummary";
import type { MatchDetails } from "../types";

const minuteKey = (value: string) => value.trim().match(/^\d+(?:\+\d+)?/)?.[0] || "";
const surname = (name: string) => name.trim().split(/\s+/).at(-1) || name;

export function CompactMatchEvents({ details, homeTeam, awayTeam, className = "" }: {
  details: MatchDetails | null | undefined;
  homeTeam: string;
  awayTeam: string;
  className?: string;
}) {
  if (!details) return null;
  const events = (["home", "away"] as const).map(side => {
    const goals = goalSummary(details, side).map(goal => ({ ...goal, kind: "goal" as const }));
    const cards = (side === "home" ? details.homeRedCards : details.awayRedCards)
      .flatMap(card => card.redCardTimes.map(time => {
        const key = minuteKey(time);
        const [minute, added = 0] = key.split("+").map(Number);
        return {
          minute: key ? `${key}'` : "–",
          scorer: surname(card.player),
          assister: undefined,
          label: `${key || "Unknown minute"} ${card.player}, red card`,
          order: key ? minute * 100 + added : Infinity,
          kind: "red-card" as const,
        };
      }));
    return [...goals, ...cards].sort((a, b) => a.order - b.order);
  });
  if (!events.some(side => side.length)) return null;
  return (
    <div className={`compact-match-events ${className}`.trim()}>
      {events.map((side, index) => (
        <ul key={index} aria-label={`${index === 0 ? homeTeam : awayTeam} goals and red cards`}>
          {side.map((event, eventIndex) => (
            <li key={`${event.kind}-${event.minute}-${eventIndex}`} aria-label={event.label}>
              {event.kind === "red-card" && <span className="compact-red-card" aria-hidden="true" />}
              <span className="goal-minute">{event.minute}</span>{" "}
              <span>{event.scorer}</span>{" "}
              {event.assister && <span className="goal-assister">({event.assister})</span>}
            </li>
          ))}
        </ul>
      ))}
    </div>
  );
}
