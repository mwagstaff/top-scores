import type { Match } from "./types";

export function displayStatus(match: Match): string {
  const rawStatus = (match.scoreStatus || "").trim();
  if (rawStatus) {
    const extraTimeMinute = rawStatus.match(/^ET\s+(\d{1,3}(?:\+\d{1,2})?)'?$/i);
    if (extraTimeMinute) {
      return `ET ${extraTimeMinute[1]}'`;
    }
    if (/^\d{1,3}(?:\+\d{1,2})?'?$/.test(rawStatus)) {
      return `${rawStatus.replace(/'/g, "")}'`;
    }
    return rawStatus.toUpperCase();
  }

  if (typeof match.homeScore === "number" && typeof match.awayScore === "number") {
    return "-";
  }

  return match.time;
}

export function isMatchLive(match: Match): boolean {
  const status = (match.scoreStatus || "").trim().toUpperCase();
  if (!status) {
    return false;
  }
  if (/^(?:ET\s+)?\d{1,3}(?:\+\d{1,2})?'?$/.test(status)) {
    return true;
  }
  return ["HT", "ET", "LIVE"].includes(status);
}

export function isMatchFinished(match: Match): boolean {
  const status = (match.scoreStatus || "").trim().toUpperCase();
  return ["FT", "AET", "PENS"].includes(status);
}

export function aggregateSummary(match: Match): string | null {
  const firstLegHome = match.firstLegHomeScore;
  const firstLegAway = match.firstLegAwayScore;

  if (typeof firstLegHome === "number" && typeof firstLegAway === "number") {
    const homeScore = typeof match.homeScore === "number" ? match.homeScore : 0;
    const awayScore = typeof match.awayScore === "number" ? match.awayScore : 0;
    const aggHome = firstLegHome + homeScore;
    const aggAway = firstLegAway + awayScore;
    return `Agg: ${aggHome}-${aggAway}`;
  }

  return null;
}

