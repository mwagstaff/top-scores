import { normalizeMatch } from "./api";
import type { Match, MatchesPayload } from "./types";
import { initialSeed } from "./bootstrap";

export type DayEntry = MatchesPayload & { fetchedAt: number };
const cache = new Map<string, DayEntry>();
const pending = new Map<string, Promise<DayEntry>>();
const storageKey = "top-scores.days.v2";
const keyFor = (date: string, epl: boolean | string) => `${date}:${epl}`;
try {
  for (const [key, value] of JSON.parse(
    sessionStorage.getItem(storageKey) || "[]",
  )) {
    if (
      value &&
      Array.isArray(value.matches) &&
      typeof value.fetchedAt === "number"
    )
      cache.set(key, value);
  }
} catch {
  /* Storage can be unavailable in private browsing. */
}
if (initialSeed?.date && Array.isArray(initialSeed.matches)) {
  cache.set(keyFor(initialSeed.date, false), {
    matches: initialSeed.matches.map(normalizeMatch),
    fetchedAt: initialSeed.fetchedAt,
    page: 1,
    hasMore: Boolean(initialSeed.hasMore),
    lastUpdated: initialSeed.lastUpdated || null,
    totalCount: initialSeed.matches.length,
  });
}

export function cachedDay(
  date: string,
  epl: boolean | string = false,
): DayEntry | undefined {
  return cache.get(keyFor(date, epl));
}
export function cachedMatch(id: string): Match | undefined {
  for (const entry of cache.values()) {
    const match = entry.matches.find(
      (match) => match.matchDetailsId === id || match.id === id,
    );
    if (match) return match;
  }
}
export async function loadDay(
  date: string,
  epl: boolean | string = false,
  force = false,
  page = 1,
): Promise<DayEntry> {
  const key = keyFor(date, epl);
  const current = cache.get(key);
  if (
    !force &&
    page === 1 &&
    current &&
    Date.now() - current.fetchedAt < 10_000
  )
    return current;
  const requestKey = `${key}:${page}`;
  const existing = pending.get(requestKey);
  if (existing) return existing;
  const otherPage = [...pending.entries()].find(([request]) =>
    request.startsWith(`${key}:`),
  );
  if (otherPage)
    return otherPage[1].then(() => loadDay(date, epl, force, page));
  const request = (async () => {
    const query = new URLSearchParams({
      start: date,
      end: date,
      time_zone: "Europe/London",
      page_size: "200",
      page: String(page),
      sort: "asc",
    });
    if (epl === "top") {
      query.set("view_option", "preset:top-teams");
    } else if (epl === "epl") {
      query.set("epl_only", "true");
    } else if (epl) {
      query.set("epl_only", "true");
      const flags = typeof epl === "string" ? new URLSearchParams(epl) : null;
      for (const flag of ["major_uefa", "home_nations", "major_tournaments"]) {
        if (!flags || flags.get(flag) === "true") query.set(flag, "true");
      }
    }
    const response = await fetch(`/api/v1/matches?${query}`, {
      signal: AbortSignal.timeout(15_000),
      cache: "no-store",
    });
    if (!response.ok)
      throw new Error(
        "Scores couldn’t refresh. Your last update is still available.",
      );
    const raw = await response.json();
    if (!Array.isArray(raw))
      throw new Error("Scores are temporarily unavailable.");
    const previous = cache.get(key);
    let resolvedPage = page;
    let hasMore =
      response.headers.get("X-Has-More") === "true" && raw.length > 0;
    // Refresh every page the reader opened, without collapsing the list back to page one.
    if (page === 1 && previous && previous.page > 1) {
      for (let next = 2; next <= previous.page && hasMore; next++) {
        query.set("page", String(next));
        const more = await fetch(`/api/v1/matches?${query}`, {
          signal: AbortSignal.timeout(15_000),
          cache: "no-store",
        });
        if (!more.ok)
          throw new Error(
            "Unable to refresh all matches. Showing saved scores.",
          );
        const items = await more.json();
        if (!Array.isArray(items))
          throw new Error("Scores are temporarily unavailable.");
        raw.push(...items);
        resolvedPage = next;
        hasMore = more.headers.get("X-Has-More") === "true" && items.length > 0;
      }
    }
    const oldMatches = new Map(
      previous?.matches.map((match) => [match.id, match]),
    );
    const matches = raw.map(normalizeMatch).map((match) => {
      const old = oldMatches.get(match.id);
      return old && JSON.stringify(old) === JSON.stringify(match) ? old : match;
    });
    const combined =
      page > 1 ? [...(previous?.matches || []), ...matches] : matches;
    const entry: DayEntry = {
      matches: [
        ...new Map(combined.map((match) => [match.id, match])).values(),
      ],
      lastUpdated:
        response.headers.get("X-Last-Updated") || new Date().toISOString(),
      totalCount: Number(
        response.headers.get("X-Total-Count") || matches.length,
      ),
      page: resolvedPage,
      hasMore,
      fetchedAt: Date.now(),
    };
    cache.delete(key);
    cache.set(key, entry);
    while (cache.size > 12) cache.delete(cache.keys().next().value!);
    try {
      sessionStorage.setItem(storageKey, JSON.stringify([...cache]));
    } catch {
      /* In-memory cache remains usable. */
    }
    return entry;
  })().finally(() => pending.delete(requestKey));
  pending.set(requestKey, request);
  return request;
}
