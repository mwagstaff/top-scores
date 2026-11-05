import { useCallback, useEffect, useState } from "react";
import type { Match } from "./types";

// English clubs in UEFA competitions are Premier League clubs, so the
// Premier League team catalogue is the source of truth (mirrors iOS
// PremierLeagueTeamsStore).
type EnglishClubs = { ids: Set<string>; names: Set<string> };
type CatalogTeam = { name: string; aliases?: string[]; source_team_ids?: string[] };

const storageKey = "top-scores.premier-league-teams.v1";
const cacheTTL = 6 * 60 * 60 * 1000;
const nameKey = (name: string) => name.normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]/g, "");
const europeanClubKeys = new Set(["uefachampionsleague", "championsleague", "uefaeuropaleague", "europaleague", "uefaconferenceleague", "uefaeuropaconferenceleague", "conferenceleague", "uefasupercup"]);

function build(teams: CatalogTeam[]): EnglishClubs {
  return {
    ids: new Set(teams.flatMap(team => team.source_team_ids || [])),
    names: new Set(teams.flatMap(team => [team.name, ...(team.aliases || [])]).map(nameKey)),
  };
}

function readCache(): { fetchedAt: number; teams: CatalogTeam[] } | undefined {
  try {
    const value = JSON.parse(localStorage.getItem(storageKey) || "null");
    return value && Array.isArray(value.teams) ? value : undefined;
  } catch {
    return undefined;
  }
}

let current: EnglishClubs | undefined;
let request: Promise<EnglishClubs | undefined> | undefined;

function cachedEnglishClubs() {
  const cached = readCache();
  if (cached?.teams.length) current ||= build(cached.teams);
  return cached;
}

function loadEnglishClubs(): Promise<EnglishClubs | undefined> {
  const cached = cachedEnglishClubs();
  if (current && cached && Date.now() - cached.fetchedAt < cacheTTL) return Promise.resolve(current);
  request ||= fetch("/api/v1/teams/catalog?competition_id=premier-league&limit=200", { signal: AbortSignal.timeout(15_000) })
    .then(response => (response.ok ? response.json() : Promise.reject(new Error(`Request failed (${response.status})`))))
    .then(body => {
      const teams: CatalogTeam[] = Array.isArray(body?.teams) ? body.teams : [];
      if (!teams.length) return current;
      current = build(teams);
      try { localStorage.setItem(storageKey, JSON.stringify({ fetchedAt: Date.now(), teams })); } catch { /* Memory copy still applies. */ }
      return current;
    })
    .catch(() => current)
    .finally(() => { request = undefined; });
  return request;
}

export function isEuropeanClubCompetition(league: string) {
  return europeanClubKeys.has(nameKey(league));
}

function isEnglishClub(clubs: EnglishClubs, name: string, id?: string | null) {
  return Boolean(id && clubs.ids.has(id)) || clubs.names.has(nameKey(name));
}

/** Returns a predicate for rows involving English clubs in UEFA club competitions, once the catalogue is known. */
export function useEnglishEuropeanMatcher(needed: boolean): ((match: Match) => boolean) | undefined {
  // Resolved after mount (from the local cache when fresh) so server-rendered markup hydrates cleanly.
  const [clubs, setClubs] = useState<EnglishClubs | undefined>();
  useEffect(() => {
    if (!needed) return;
    let active = true;
    void loadEnglishClubs().then(value => { if (active) setClubs(value); });
    return () => { active = false; };
  }, [needed]);
  const matcher = useCallback((match: Match) => Boolean(clubs) && isEuropeanClubCompetition(match.league) &&
    (isEnglishClub(clubs!, match.homeTeam, match.homeTeamId) || isEnglishClub(clubs!, match.awayTeam, match.awayTeamId)), [clubs]);
  return clubs ? matcher : undefined;
}
