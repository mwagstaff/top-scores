import type { Match, TvChannel } from "./types";

export const featuredCompetitions = [
  "Premier League",
  "UEFA Champions League",
  "Championship",
  "UEFA Europa League",
  "Scottish Premiership",
  "Women's Super League",
  "FA Cup",
  "UEFA Conference League",
];

export function ukDate(now = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
}
export function validDate(value: string | null): value is string {
  return Boolean(
    value &&
      /^\d{4}-\d{2}-\d{2}$/.test(value) &&
      Number.isFinite(Date.parse(value)) &&
      new Date(value).toISOString().slice(0, 10) === value,
  );
}
export function moveDate(date: string, days: number): string {
  const next = new Date(`${date}T12:00:00Z`);
  next.setUTCDate(next.getUTCDate() + days);
  return next.toISOString().slice(0, 10);
}
export function dateLabel(date: string, short = false): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "UTC",
    weekday: short ? "short" : "long",
    day: "numeric",
    month: short ? "short" : "long",
  }).format(new Date(`${date}T12:00:00Z`));
}
export function ukChannels(channels: TvChannel[]): TvChannel[] {
  const unique = new Map<string, TvChannel>();
  for (const channel of channels) {
    const code = channel.countryCode?.toUpperCase();
    const country = channel.country?.toLowerCase();
    const explicitUK =
      code === "GB" ||
      code === "UK" ||
      country === "united kingdom" ||
      country === "uk";
    const inferredUK =
      !code &&
      !country &&
      /\b(bbc|itv|sky sports|tnt sports|premier sports|uk)\b/i.test(
        channel.name,
      );
    if (!explicitUK && !inferredUK) continue;
    const name = channel.name.replace(/\s*\(UK\)$/i, "").trim();
    unique.set(name.toLowerCase(), { ...channel, name });
  }
  const streaming = (name: string) =>
    /hbo|max|now|prime|amazon|discovery|dazn|player|youtube|sky go|sky sports app/i.test(
      name,
    )
      ? 1
      : 0;
  return [...unique.values()].sort(
    (a, b) => streaming(a.name) - streaming(b.name),
  );
}
export function isUKRelevant(match: Match): boolean {
  return (
    ukChannels(match.tvChannels).length > 0 ||
    /^(UEFA (?:Champions|Europa|Conference) League|FIFA World Cup|UEFA European Championship|Premier League|(?:EFL )?Championship|(?:EFL )?League (?:One|Two)|FA Cup|EFL Cup|Carabao Cup|Scottish |Women.s Super League|WSL|National League)/i.test(
      match.league,
    ) ||
    /^(England|Scotland|Wales|Northern Ireland)(?: Women)?$/i.test(
      match.homeTeam,
    ) ||
    /^(England|Scotland|Wales|Northern Ireland)(?: Women)?$/i.test(
      match.awayTeam,
    )
  );
}
export function competitionPath(name: string): string {
  return `/competitions/${encodeURIComponent(name)}`;
}
export function matchPath(match: Match): string {
  return `/matches/${encodeURIComponent(match.matchDetailsId || match.id)}?date=${match.date}`;
}
