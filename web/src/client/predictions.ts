// Predicted scores for upcoming fixtures, derived from BSD's markets data.
// Mirrors the iOS app's prediction pipeline (MatchesView.swift):
//   - a prediction is computed once per match and frozen in local storage,
//     so it stays valid to compare against the eventual real result;
//   - predictions are precomputed in the background as fixtures load, not
//     on demand, so the UI never has to wait for one.

import { fetchPredictions } from "./api";
import { parseKickoff } from "./matchGrouping";
import type { Match, MatchDayGroup, PredictionMarkets, PredictionMatchResultMarket, StoredPrediction } from "./types";

const STORAGE_KEY = "topScores.predictions.v1";
const TOGGLE_KEY = "topScores.showPredictedScores";

// ── Frozen prediction store (localStorage, keyed by match id) ──────

let cachedIndex: Record<string, StoredPrediction> | null = null;
const changeListeners = new Set<() => void>();

function loadIndex(): Record<string, StoredPrediction> {
  if (cachedIndex) return cachedIndex;
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    cachedIndex = raw ? (JSON.parse(raw) as Record<string, StoredPrediction>) : {};
  } catch {
    cachedIndex = {};
  }
  return cachedIndex;
}

export function getAllPredictions(): Record<string, StoredPrediction> {
  return loadIndex();
}

export function getPrediction(matchId: string): StoredPrediction | null {
  return loadIndex()[matchId] ?? null;
}

function savePredictions(predictions: StoredPrediction[]): void {
  if (predictions.length === 0) return;
  const index = loadIndex();
  for (const prediction of predictions) {
    index[prediction.matchId] = prediction;
  }
  cachedIndex = index;
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(index));
  } catch {
    // localStorage unavailable/full — predictions still hold for this session
  }
  changeListeners.forEach((listener) => listener());
}

export function clearAllPredictions(): void {
  cachedIndex = {};
  try {
    window.localStorage.removeItem(STORAGE_KEY);
  } catch {
    // ignore
  }
  changeListeners.forEach((listener) => listener());
}

export function subscribeToPredictionChanges(listener: () => void): () => void {
  changeListeners.add(listener);
  return () => changeListeners.delete(listener);
}

// ── "Show predicted scores" toggle (persisted, purely a display setting) ──

export function loadShowPredictedScores(): boolean {
  try {
    return window.localStorage.getItem(TOGGLE_KEY) === "1";
  } catch {
    return false;
  }
}

export function saveShowPredictedScores(value: boolean): void {
  try {
    window.localStorage.setItem(TOGGLE_KEY, value ? "1" : "0");
  } catch {
    // ignore
  }
}

// ── Pending day tracking (drives the brief "calculating" spinner) ──────

const pendingDateKeys = new Set<string>();

export function isPredictionPending(dateKey: string): boolean {
  return pendingDateKeys.has(dateKey);
}

// ── Score prediction (ported 1:1 from the iOS MarketsScorePredictor) ───

const FALLBACK_EXPECTED_GOALS = 1.275;

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(value, max));
}

function samplePoisson(lambda: number): number {
  if (lambda <= 0) return 0;
  const threshold = Math.exp(-lambda);
  let product = 1;
  let count = 0;
  do {
    count += 1;
    product *= Math.random();
  } while (product > threshold);
  return Math.max(0, count - 1);
}

function outcomeProbabilities(matchResult: PredictionMatchResultMarket | null | undefined): [number, number, number] {
  if (!matchResult) return [0.33, 0.34, 0.33];
  const home = Math.max(0, matchResult.probHome) / 100;
  const draw = Math.max(0, matchResult.probDraw) / 100;
  const away = Math.max(0, matchResult.probAway) / 100;
  const total = home + draw + away;
  if (total <= 0) return [0.33, 0.34, 0.33];
  return [home / total, draw / total, away / total];
}

function predictScoreline(markets: PredictionMarkets): Omit<StoredPrediction, "matchId"> {
  const baseHome = Math.max(0.15, markets.expectedGoals?.home ?? FALLBACK_EXPECTED_GOALS);
  const baseAway = Math.max(0.15, markets.expectedGoals?.away ?? FALLBACK_EXPECTED_GOALS);

  let lambdaHome = baseHome * (0.88 + Math.random() * 0.32);
  let lambdaAway = baseAway * (0.88 + Math.random() * 0.32);

  // Inject occasional volatility so underdogs still produce upset scorelines.
  if (Math.random() < 0.10) {
    const swing = 0.12 + Math.random() * 0.30;
    if (baseHome >= baseAway) {
      lambdaHome *= 1 - swing;
      lambdaAway *= 1 + swing;
    } else {
      lambdaHome *= 1 + swing;
      lambdaAway *= 1 - swing;
    }
  }

  lambdaHome = clamp(lambdaHome, 0.12, 4.80);
  lambdaAway = clamp(lambdaAway, 0.12, 4.80);

  const homeGoals = samplePoisson(lambdaHome);
  const awayGoals = samplePoisson(lambdaAway);
  const [homeWinProbability, drawProbability, awayWinProbability] = outcomeProbabilities(markets.matchResult);

  return { homeGoals, awayGoals, homeWinProbability, drawProbability, awayWinProbability };
}

// ── Background warm-up ──────────────────────────────────────────────

function joinKey(home: string, away: string, date: string): string {
  return `${home.trim().toLowerCase()}|${away.trim().toLowerCase()}|${date}`;
}

function isPostponed(match: Match): boolean {
  return (match.scoreStatus || "").trim().toUpperCase() === "POSTPONED";
}

/**
 * Precomputes and freezes predictions for any of the given days that have
 * upcoming, not-yet-predicted fixtures. Idempotent per match: a match that
 * already has a stored prediction is never recomputed, so once frozen it
 * stays comparable against the eventual real result.
 */
export async function warmPredictionsForDays(days: MatchDayGroup[]): Promise<void> {
  const now = Date.now();
  const index = loadIndex();

  const toQueue = days.filter((day) => {
    if (pendingDateKeys.has(day.dateKey)) return false;
    return day.leagues.some((league) =>
      league.matches.some((match) => {
        if (index[match.id]) return false;
        if (isPostponed(match)) return false;
        const kickoff = parseKickoff(match);
        return kickoff !== null && kickoff.getTime() > now;
      })
    );
  });
  if (toQueue.length === 0) return;

  toQueue.forEach((day) => pendingDateKeys.add(day.dateKey));
  changeListeners.forEach((listener) => listener());

  try {
    const leagues = await fetchPredictions();
    const marketsByEventId = new Map<string, PredictionMarkets>();
    const marketsByTeamsAndDate = new Map<string, PredictionMarkets>();
    for (const league of leagues) {
      for (const fixture of league.fixtures) {
        if (!fixture.markets) continue;
        marketsByEventId.set(fixture.eventId, fixture.markets);
        if (fixture.date) {
          marketsByTeamsAndDate.set(joinKey(fixture.homeTeam, fixture.awayTeam, fixture.date), fixture.markets);
        }
      }
    }

    for (const day of toQueue) {
      const matches = day.leagues.flatMap((league) => league.matches);
      const newPredictions: StoredPrediction[] = [];

      for (const match of matches) {
        if (index[match.id] || isPostponed(match)) continue;
        const kickoff = parseKickoff(match);
        if (!kickoff || kickoff.getTime() <= now) continue;

        const markets =
          (match.matchDetailsId && marketsByEventId.get(match.matchDetailsId)) ||
          marketsByTeamsAndDate.get(joinKey(match.homeTeam, match.awayTeam, match.date));
        if (!markets) continue;

        const estimate = predictScoreline(markets);
        newPredictions.push({ matchId: match.id, ...estimate });
      }

      savePredictions(newPredictions);
      pendingDateKeys.delete(day.dateKey);
      changeListeners.forEach((listener) => listener());
    }
  } finally {
    toQueue.forEach((day) => pendingDateKeys.delete(day.dateKey));
    changeListeners.forEach((listener) => listener());
  }
}
