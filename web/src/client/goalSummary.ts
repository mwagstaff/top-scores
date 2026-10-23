import type { MatchDetails } from "./types";

const minuteKey = (value: string) => value.trim().match(/^\d+(?:\+\d+)?/)?.[0] || "";
const surname = (name: string) => name.trim().split(/\s+/).at(-1) || name;

export function goalSummary(details: MatchDetails | null | undefined, side: "home" | "away") {
  if (!details) return [];
  const scorers = side === "home" ? details.homeGoalScorers : details.awayGoalScorers;
  const opponents = side === "home" ? details.awayGoalScorers : details.homeGoalScorers;
  const assists = side === "home" ? details.homeAssists : details.awayAssists;
  const lookup = new Map(assists.flatMap(assist => assist.assistTimes.map(time => [minuteKey(time), assist.player] as const)));
  const entries = [
    ...scorers.flatMap(scorer => scorer.goalTimes.map(time => ({ time, player: scorer.player, assist: lookup.get(minuteKey(time)), ownGoal: false }))),
    ...opponents.flatMap(scorer => scorer.ownGoalTimes.map(time => ({ time, player: scorer.player, assist: undefined, ownGoal: true }))),
  ];
  return entries.map(entry => {
    const key = minuteKey(entry.time);
    const [minute, added = 0] = key.split("+").map(Number);
    return {
      minute: key ? `${key}'` : "–",
      scorer: surname(entry.player) + (entry.ownGoal ? " (OG)" : ""),
      assister: entry.assist ? surname(entry.assist) : undefined,
      label: `${key || "Unknown minute"} ${entry.player}${entry.ownGoal ? " (own goal)" : ""}${entry.assist ? `, assisted by ${entry.assist}` : ""}`,
      order: key ? minute * 100 + added : Infinity,
    };
  }).sort((a, b) => a.order - b.order);
}
