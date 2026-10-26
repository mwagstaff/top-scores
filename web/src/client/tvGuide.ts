import { loadDay, type DayEntry } from "./dayStore";
import { moveDate, rankedTVMatches } from "./football";
import type { Match } from "./types";

export async function nextTVGuideDay(
  date: string,
  firstDay: DayEntry,
  scope: boolean | string,
  includes: (match: Match) => boolean,
  daysAhead = 14,
  isActive = () => true,
): Promise<{ date: string; matches: Match[] } | null> {
  for (let offset = 0; offset <= daysAhead; offset++) {
    if (!isActive()) return null;
    const day = moveDate(date, offset);
    let entry = offset === 0 ? firstDay : await loadDay(day, scope);
    while (entry.hasMore && isActive())
      entry = await loadDay(day, scope, false, entry.page + 1);
    if (!isActive()) return null;
    const matches = rankedTVMatches(entry.matches.filter(includes));
    if (matches.length) return { date: day, matches };
  }
  return null;
}
