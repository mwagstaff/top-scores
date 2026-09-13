"use strict";

// Beat the AI is deliberately independent of Goal Guesser and the scores API.
// BSD remains the only sports-data source. All game records survive BSD retention.
const crypto = require("crypto");
const { getDb } = require("./mongo_client");
const {
  BSD_LEAGUE_NAME_MAP,
  __private: {
    bsdEventScoreIncludingExtraTime,
    canonicalBsdTeamName,
    extractBsdPeriodSummary,
    mapBsdStatus,
  },
} = require("./bsd_adapter");

const PREFIX = "/api/v1/prediction-game";
const DAY = 86400000;
const MODEL_VERSION = "top-scores-xg-rounded-v2";
const SCORING_RULES_VERSION = 2;
const PRESTART = new Set(["notstarted", "not_started", "ns", "scheduled", "postponed"]);
const VOID = new Set(["cancelled", "canceled", "void", "abandoned"]);
const FINAL = new Set(["finished", "ft", "aet"]);
const ACHIEVEMENTS = [
  ["firstWhistle", "First Whistle", "Complete your first scored prediction.", 1],
  ["bullseye", "Bullseye", "Make your first perfect prediction.", 1],
  ["sharpShooter", "Sharp Shooter", "Make 10 perfect predictions.", 10],
  ["readingTheGame", "Reading the Game", "Predict 25 results correctly.", 25],
  ["humanOneAiZero", "Human 1, AI 0", "Beat the AI on one match.", 1],
  ["tenStepsAhead", "Ten Steps Ahead", "Build a 10-point advantage over the AI.", 10],
  ["cleanSweep", "Clean Sweep", "Predict every result in a completed weekly challenge.", 1],
  ["seasonedPro", "Seasoned Pro", "Complete challenge predictions in two seasons.", 2],
];

class GameError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}
const iso = (now = Date.now()) => new Date(now).toISOString();
const digest = (value) => crypto.createHash("sha256").update(value).digest("hex");
const scoreInteger = (value) => typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= 20;
const outcome = (home, away) => home === away ? "draw" : home > away ? "home" : "away";
const cleanId = (value) => String(value || "").replace(/^bsd:/, "");
const validFixtureId = (value) => /^\d{1,16}$/.test(value);
const competitionId = (record) => String(record?.competitionId || "1");
const competitionName = (record) => record?.competitionName || BSD_LEAGUE_NAME_MAP[competitionId(record)] || (competitionId(record) === "1" ? "Premier League" : `Competition ${competitionId(record)}`);
const competitionFields = (record) => ({ competitionId: competitionId(record), competitionName: competitionName(record) });
// Rows written before the all-competition release belong to the Premier League.
const competitionFilter = (id) => ({ competitionId: id === "1" ? { $in: ["1", null] } : id });
const scopedId = (id, key) => id === "1" ? key : `competition:${id}:${key}`;
function requestedCompetition(value) {
  const id = value == null ? "1" : String(value);
  if (!/^[1-9]\d{0,15}$/.test(id)) throw new GameError(400, "invalid_competition", "Choose a valid competition.");
  return id;
}

async function availableCompetitions(db, playerId) {
  const [predictions, entries] = await Promise.all([
    db.collection("bsd_predictions").find({}, { projection: { "payload.markets.expected_goals": 1, "payload.markets.score.most_likely": 1 } }).toArray(),
    db.collection("pg_entries").find({ playerId, ai: { $exists: true } }, { projection: { competitionId: 1, competitionName: 1 } }).toArray(),
  ]);
  const names = new Map([["1", "Premier League"]]);
  for (const doc of predictions) if (Array.isArray(doc.payload) && doc.payload.some((item) => aiPrediction(item))) names.set(String(doc._id), competitionName({ competitionId: String(doc._id) }));
  for (const entry of entries) names.set(competitionId(entry), competitionName(entry));
  const leagues = await db.collection("bsd_leagues").find({ _id: { $in: [...names.keys()] } }).toArray();
  for (const league of leagues) if (league.payload?.name) names.set(String(league._id), String(league.payload.name));
  names.set("1", "Premier League");
  return [...names].map(([id, name]) => ({ id, name })).sort((a, b) => a.id === "1" ? -1 : b.id === "1" ? 1 : a.name.localeCompare(b.name));
}

async function predictionMap(db, ids) {
  const docs = await db.collection("bsd_predictions").find({ _id: { $in: [...new Set(ids)] } }).toArray();
  return new Map(docs.flatMap((doc) => (Array.isArray(doc.payload) ? doc.payload : []).map((item) => [String(item.event?.id), aiPrediction(item)])));
}

function pointsFor(prediction, result) {
  if (!prediction || !result || ![prediction.homeScore, prediction.awayScore, result.homeScore, result.awayScore].every(scoreInteger)) return null;
  const actualOutcome = result.penaltyWinner || outcome(result.homeScore, result.awayScore);
  const normalOutcome = outcome(prediction.homeScore, prediction.awayScore);
  const predictedOutcome = result.penaltyWinner ? prediction.penaltyWinner || normalOutcome : normalOutcome;
  if (predictedOutcome !== actualOutcome) return 0;
  return prediction.homeScore === result.homeScore && prediction.awayScore === result.awayScore ? 3 : 1;
}

function aiPrediction(item) {
  if (!item?.markets) return null;
  // The modal score collapses a wide range of goal expectations to 1–1.
  // Project BSD's team-specific goal means to the nearest integer instead;
  // these already account for each side, with no random or blanket goal boost.
  const goals = item.markets.expected_goals;
  const usableGoals = goals && [goals.home, goals.away].every((value) => typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 20);
  const score = usableGoals ? null : String(item.markets.score?.most_likely || "").match(/^(\d{1,2})\s*[-–:]\s*(\d{1,2})$/);
  const homeScore = usableGoals ? Math.round(goals.home) : score ? Number(score[1]) : null;
  const awayScore = usableGoals ? Math.round(goals.away) : score ? Number(score[2]) : null;
  if (![homeScore, awayScore].every(scoreInteger)) return null;
  const modelVersion = `${MODEL_VERSION}:${item.model?.version || "unknown"}`;
  // A local model change must also require first-time players to review the AI.
  const resultMarket = item.markets.match_result;
  const awayFavoured = usableGoals ? goals.away > goals.home
    : [resultMarket?.prob_home, resultMarket?.prob_away].every((value) => typeof value === "number" && Number.isFinite(value)) && resultMarket.prob_away > resultMarket.prob_home;
  const penaltyWinner = awayFavoured ? "away" : "home";
  return { homeScore, awayScore, penaltyWinner, modelVersion,
    sourceRevision: digest(JSON.stringify({ modelVersion, item, penaltyWinner })), frozenAt: null };
}

// Friday–Thursday, in London calendar dates (including British Summer Time).
function weekId(kickoffAt) {
  const date = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/London", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(kickoffAt));
  const day = new Date(`${date}T12:00:00Z`);
  day.setUTCDate(day.getUTCDate() - (day.getUTCDay() + 2) % 7);
  return `epl-${day.toISOString().slice(0, 10)}`;
}

function seasonLabel(kickoffAt) {
  const date = new Date(kickoffAt);
  const year = date.getUTCFullYear() - (date.getUTCMonth() < 6 ? 1 : 0);
  return `${year}/${String(year + 1).slice(-2)}`;
}

function fixtureFromEvent(doc, previous = null, prediction = null) {
  const e = doc?.payload;
  if (!e || !/^[1-9]\d{0,15}$/.test(String(e.league_id)) || !validFixtureId(String(e.id)) || !Number.isFinite(Date.parse(e.event_date))) return null;
  const id = String(e.league_id);
  const status = String(e.status || "").trim().toLowerCase();
  const incidentPayload = doc._predictionGameIncidents;
  const periods = extractBsdPeriodSummary(Array.isArray(incidentPayload) ? incidentPayload : incidentPayload?.incidents);
  const shootout = periods.penaltyShootout || e.penalty_shootout;
  // A completed PEN period can precede BSD's final status, and BSD sometimes
  // replaces the top-level goals with shootout totals. ET/FT period scores are
  // the complete on-field score in this case (not additive extra-time goals).
  const finalScore = shootout && (periods.extraTimeScore || periods.fullTimeScore)
    ? periods.extraTimeScore || periods.fullTimeScore : bsdEventScoreIncludingExtraTime(e);
  const displayStatus = mapBsdStatus(e, { periodSummary: periods });
  const liveScore = displayStatus && !["FT", "AET", "POSTPONED"].includes(displayStatus) && finalScore
    ? { homeScore: finalScore.home, awayScore: finalScore.away, status: displayStatus }
    : null;
  const penaltyWinner = shootout && [shootout.home, shootout.away].every(scoreInteger) && shootout.home !== shootout.away
    ? outcome(shootout.home, shootout.away) : null;
  // Never award draw points while a reported shootout has no confirmed winner.
  const result = (FINAL.has(status) || periods.penaltyShootout) && finalScore && [finalScore.home, finalScore.away].every(scoreInteger) && (!shootout || penaltyWinner)
    ? { homeScore: finalScore.home, awayScore: finalScore.away, ...(penaltyWinner ? { penaltyWinner } : {}) } : null;
  // Seeing play once is permanent; a later provider regression cannot reopen it.
  const started = previous?.started === true || status === "abandoned" || (!PRESTART.has(status) && !VOID.has(status) && status !== "");
  const kickoffAt = iso(Date.parse(e.event_date));
  return {
    _id: String(e.id), competitionId: id, competitionName: e.league_name || previous?.competitionName || BSD_LEAGUE_NAME_MAP[id] || (id === "1" ? "Premier League" : `Competition ${id}`), homeTeam: canonicalBsdTeamName(e.home_team_id, e.home_team), awayTeam: canonicalBsdTeamName(e.away_team_id, e.away_team),
    seasonId: e.season_id != null ? String(e.season_id) : previous?.seasonId || scopedId(id, `epl-${seasonLabel(kickoffAt)}`),
    seasonLabel: previous?.seasonLabel || seasonLabel(kickoffAt), kickoffAt, status, started,
    isSecondLeg: Object.prototype.hasOwnProperty.call(e, "previous_leg_event_id")
      ? e.previous_leg_event_id != null && /^[1-9]\d*$/.test(String(e.previous_leg_event_id))
      : previous?.isSecondLeg === true,
    roundNumber: Number.isInteger(Number(e.round_number)) && Number(e.round_number) > 0 ? Number(e.round_number) : previous?.roundNumber || null,
    void: VOID.has(status), liveScore, result, resultRevision: digest(JSON.stringify({ status, result })),
    ai: started ? previous?.ai || null : prediction || previous?.ai || null,
    challengeId: previous?.challengeId || null, sourceUpdatedAt: doc.updated_at || null, updatedAt: iso(),
  };
}

function isLocked(fixture, now = Date.now()) {
  return fixture.started || fixture.void || !PRESTART.has(fixture.status) || Date.parse(fixture.kickoffAt) <= now;
}

function fixtureResponse(fixture, entry, now = Date.now()) {
  const active = entry && !entry.withdrawn;
  return {
    id: fixture._id, ...competitionFields(fixture), homeTeam: fixture.homeTeam, awayTeam: fixture.awayTeam,
    seasonId: fixture.seasonId, seasonLabel: fixture.seasonLabel, kickoffAt: fixture.kickoffAt,
    isSecondLeg: fixture.isSecondLeg === true, status: fixture.status, locked: isLocked(fixture, now), settled: Boolean(fixture.result) && !fixture.void,
    void: fixture.void, challengeId: fixture.challengeId || null,
    ai: entry?.ai || fixture.ai || null, result: fixture.result,
    prediction: active ? { homeScore: entry.homeScore, awayScore: entry.awayScore, ...(entry.penaltyWinner ? { penaltyWinner: entry.penaltyWinner } : {}), savedAt: entry.updatedAt,
      youPoints: entry.youPoints ?? null, aiPoints: entry.aiPoints ?? null, outcome: entry.outcome || null } : null,
  };
}

function predictionGameweek(fixture) {
  if (fixture.roundNumber) return { id: scopedId(competitionId(fixture), `${fixture.seasonId}:round:${fixture.roundNumber}`), label: `Gameweek ${fixture.roundNumber}` };
  const week = weekId(fixture.kickoffAt);
  const label = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", timeZone: "Europe/London" }).format(new Date(`${week.slice(4)}T12:00:00Z`));
  return { id: scopedId(competitionId(fixture), `${fixture.seasonId}:week:${week}`), label: `Week of ${label}` };
}

async function eventDocsWithResults(db, docs) {
  const ids = docs.filter((doc) => { const status = String(doc.payload?.status || "").toLowerCase(); return status && !PRESTART.has(status) && !VOID.has(status); }).map((doc) => String(doc._id));
  if (!ids.length) return docs;
  const incidents = await db.collection("bsd_incidents").find({ _id: { $in: ids } }).toArray();
  const byId = new Map(incidents.map((doc) => [String(doc._id), doc.payload]));
  return docs.map((doc) => byId.has(String(doc._id)) ? { ...doc, _predictionGameIncidents: byId.get(String(doc._id)) } : doc);
}

async function gameFixtureBatch(db, playerId, ids, now = Date.now) {
  if (!ids.length) return [];
  // Interactive reads need only these fixtures and this player's entries. They
  // never wait for the global settlement worker or require a warm game cache.
  const [source, cached, entries] = await Promise.all([
    db.collection("bsd_events").find({ _id: { $in: ids } }).toArray(),
    db.collection("pg_fixtures").find({ _id: { $in: ids } }).toArray(),
    db.collection("pg_entries").find({ playerId, fixtureId: { $in: ids } }).toArray(),
  ]);
  const sourceById = new Map((await eventDocsWithResults(db, source)).map((doc) => [String(doc._id), doc]));
  const previousById = new Map(cached.map((fixture) => [fixture._id, fixture]));
  const entriesById = new Map(entries.map((entry) => [entry.fixtureId, entry]));
  const aiById = await predictionMap(db, source.map((doc) => String(doc.payload?.league_id)).concat(cached.map(competitionId)));
  const responseNow = typeof now === "function" ? now() : now;
  return ids.map((id) => {
    const doc = sourceById.get(id); const previous = previousById.get(id);
    const fixture = doc ? fixtureFromEvent(doc, previous, aiById.get(id)) : previous;
    return fixture ? fixtureResponse(fixture, entriesById.get(id), responseNow) : null;
  }).filter(Boolean).sort((a, b) => a.kickoffAt.localeCompare(b.kickoffAt) || a.id.localeCompare(b.id));
}

async function gameweekFixtures(db, context) {
  const group = predictionGameweek(context);
  const startYear = Number(context.seasonLabel.slice(0, 4));
  const start = context.roundNumber ? Date.UTC(startYear, 6, 1) : Date.parse(`${weekId(context.kickoffAt).slice(4)}T00:00:00Z`) - DAY;
  const end = context.roundNumber ? Date.UTC(startYear + 1, 7, 1) : start + 9 * DAY;
  const cached = await db.collection("pg_fixtures").find({ ...competitionFilter(competitionId(context)), seasonId: context.seasonId,
    ...(context.roundNumber ? { roundNumber: context.roundNumber } : { kickoffAt: { $gte: iso(start), $lt: iso(end) } }) }).toArray();
  const scheduleGroup = context.roundNumber && /^\d+$/.test(context.seasonId)
    ? { "payload.season_id": { $in: [context.seasonId, Number(context.seasonId)] }, "payload.round_number": { $in: [context.roundNumber, String(context.roundNumber)] } }
    : { event_date: { $gte: iso(start), $lt: iso(end) }, ...(context.roundNumber ? { "payload.round_number": { $in: [context.roundNumber, String(context.roundNumber)] } } : {}) };
  const source = await db.collection("bsd_events").find({ league_id: { $in: [Number(competitionId(context)), competitionId(context)] }, $or: [
    { _id: { $in: cached.map((f) => f._id) } }, scheduleGroup,
  ] }).toArray();
  const fixtures = new Map(cached.map((f) => [f._id, f]));
  for (const doc of await eventDocsWithResults(db, source)) {
    const fixture = fixtureFromEvent(doc, fixtures.get(String(doc._id)));
    if (fixture) fixtures.set(fixture._id, fixture);
  }
  return [...fixtures.values()].filter((f) => predictionGameweek(f).id === group.id).sort((a, b) => a.kickoffAt.localeCompare(b.kickoffAt) || a._id.localeCompare(b._id));
}

async function recentGameweeks(db, playerId, seasonId = null, selectedCompetition = "1", limit = 5) {
  const competitionScope = selectedCompetition == null ? {} : competitionFilter(selectedCompetition);
  const entries = await db.collection("pg_entries").find({ playerId, ...competitionScope, withdrawn: false, ai: { $exists: true }, ...(seasonId ? { seasonId } : {}) }).toArray();
  if (!entries.length) return [];
  const ids = entries.map((e) => e.fixtureId);
  const [cached, source] = await Promise.all([
    db.collection("pg_fixtures").find({ _id: { $in: ids } }).toArray(),
    db.collection("bsd_events").find({ _id: { $in: ids } }).toArray(),
  ]);
  const byId = new Map(cached.map((f) => [f._id, f]));
  for (const doc of await eventDocsWithResults(db, source)) {
    const fixture = fixtureFromEvent(doc, byId.get(String(doc._id)));
    if (fixture) byId.set(fixture._id, fixture);
  }
  const fixtures = [...byId.values()];
  const groups = new Map();
  for (const fixture of fixtures) {
    const id = predictionGameweek(fixture).id;
    if (!groups.has(id) || fixture.kickoffAt < groups.get(id).kickoffAt) groups.set(id, fixture);
  }
  const selected = [...groups.values()].sort((a, b) => b.kickoffAt.localeCompare(a.kickoffAt)).slice(0, limit);
  const entryById = new Map(entries.map((e) => [e.fixtureId, e]));
  return Promise.all(selected.map(async (context) => {
    const group = predictionGameweek(context); const matches = await gameweekFixtures(db, context);
    const eligible = matches.filter((f) => !f.void);
    const predicted = eligible.filter((f) => entryById.has(f._id));
    const played = predicted.filter((f) => f.result != null);
    return { id: group.id, ...competitionFields(context), label: group.label, startsAt: matches[0]?.kickoffAt || context.kickoffAt,
      latestPlayedAt: played.reduce((latest, fixture) => !latest || fixture.kickoffAt > latest ? fixture.kickoffAt : latest, null),
      youPoints: played.reduce((sum, f) => sum + pointsFor(entryById.get(f._id), f.result), 0),
      aiPoints: played.reduce((sum, f) => sum + pointsFor(entryById.get(f._id).ai, f.result), 0),
      played: played.length, predicted: predicted.length, totalMatches: eligible.length,
      completed: matches.length > 0 && matches.every((f) => f.void || f.result != null) };
  }));
}

async function latestCompletedGameweek(db, playerId) {
  const rounds = await recentGameweeks(db, playerId, null, null, 10);
  return rounds.filter((round) => round.completed && round.played > 0)
    .sort((a, b) => String(b.latestPlayedAt || b.startsAt).localeCompare(String(a.latestPlayedAt || a.startsAt)))[0] || null;
}

async function inPlayGameweek(db, playerId, selectedCompetition = "1", now = Date.now()) {
  const queryNow = typeof now === "function" ? now() : now;
  const source = await db.collection("bsd_events").find({
    league_id: { $in: [Number(selectedCompetition), selectedCompetition] },
    event_date: { $gte: iso(queryNow - 2 * DAY), $lte: iso(queryNow + DAY) },
  }).toArray();
  if (!source.length) return null;
  const cached = await db.collection("pg_fixtures").find({ _id: { $in: source.map((doc) => String(doc._id)) } }).toArray();
  const previousById = new Map(cached.map((fixture) => [fixture._id, fixture]));
  const live = (await eventDocsWithResults(db, source)).map((doc) => fixtureFromEvent(doc, previousById.get(String(doc._id))))
    .filter((fixture) => fixture?.liveScore)
    .sort((a, b) => a.kickoffAt.localeCompare(b.kickoffAt) || a._id.localeCompare(b._id));
  if (!live.length) return null;

  const context = live[0]; const group = predictionGameweek(context);
  const matches = await gameweekFixtures(db, context);
  const entries = await db.collection("pg_entries").find({
    playerId, fixtureId: { $in: matches.map((fixture) => fixture._id) },
    withdrawn: false, ai: { $exists: true },
  }).toArray();
  const entryById = new Map(entries.map((entry) => [entry.fixtureId, entry]));
  const supportedLive = matches.filter((fixture) => fixture.liveScore && (fixture.ai || entryById.get(fixture._id)?.ai));
  if (!supportedLive.length || !entries.length) return null;
  const scored = matches.flatMap((fixture) => {
    const entry = entryById.get(fixture._id); const score = fixture.result || fixture.liveScore;
    if (!entry || !score) return [];
    const youPoints = pointsFor(entry, score); const aiPoints = pointsFor(entry.ai, score);
    return Number.isInteger(youPoints) && Number.isInteger(aiPoints) ? [{ youPoints, aiPoints }] : [];
  });
  if (!scored.length) return null;
  return {
    id: group.id, ...competitionFields(context), label: group.label,
    youPoints: scored.reduce((sum, item) => sum + item.youPoints, 0),
    aiPoints: scored.reduce((sum, item) => sum + item.aiPoints, 0),
    scoredMatches: scored.length, liveMatches: supportedLive.length,
    totalMatches: matches.filter((fixture) => !fixture.void).length,
  };
}

async function nextPredictionSet(db, playerId, contextId = null, now = Date.now, includeLocked = false, selectedCompetition = null) {
  if (contextId != null && !validFixtureId(contextId)) throw new GameError(404, "fixture_not_found", "Match not found.");
  if (selectedCompetition == null && contextId) {
    const source = await db.collection("bsd_events").findOne({ _id: contextId });
    const cached = source ? null : await db.collection("pg_fixtures").findOne({ _id: contextId });
    selectedCompetition = source?.payload?.league_id != null ? String(source.payload.league_id) : competitionId(cached);
  }
  selectedCompetition = requestedCompetition(selectedCompetition);
  const queryNow = typeof now === "function" ? now() : now;
  // Query the durable fixture schedule, independently of a visible date filter,
  // the state endpoint's 30-day window, or the current weekly challenge.
  const [eventDocs, predictionDoc, contextDoc] = await Promise.all([
    db.collection("bsd_events").find({ league_id: { $in: [Number(selectedCompetition), selectedCompetition] }, event_date: { $gt: iso(queryNow) } }).sort({ event_date: 1, _id: 1 }).batchSize(200).toArray(),
    db.collection("bsd_predictions").findOne({ _id: selectedCompetition }),
    contextId ? db.collection("bsd_events").findOne({ _id: contextId }) : null,
  ]);
  const ids = [...new Set([...eventDocs.map((d) => String(d._id)), ...(contextId ? [contextId] : [])])];
  const [cached, entries] = await Promise.all([
    db.collection("pg_fixtures").find({ _id: { $in: ids } }).toArray(),
    db.collection("pg_entries").find({ playerId, fixtureId: { $in: ids } }).toArray(),
  ]);
  const previousById = new Map(cached.map((f) => [f._id, f]));
  const entriesById = new Map(entries.map((entry) => [entry.fixtureId, entry]));
  const aiById = new Map((Array.isArray(predictionDoc?.payload) ? predictionDoc.payload : []).map((p) => [String(p.event?.id), aiPrediction(p)]));
  const responseNow = typeof now === "function" ? now() : now;
  const project = (doc) => fixtureFromEvent(doc, previousById.get(String(doc?._id)), aiById.get(String(doc?._id)));
  const eligible = eventDocs.map(project).filter((f) => f && !isLocked(f, responseNow) && (entriesById.get(f._id)?.ai || f.ai))
    .sort((a, b) => a.kickoffAt.localeCompare(b.kickoffAt) || a._id.localeCompare(b._id));
  const context = contextId ? (contextDoc ? project(contextDoc) : previousById.get(contextId)) : eligible[0];
  if (contextId && (!context || competitionId(context) !== selectedCompetition)) throw new GameError(404, "fixture_not_found", "Match not found.");
  if (!context) return { ...competitionFields({ competitionId: selectedCompetition }), serverTime: iso(responseNow), gameweekId: null, gameweekLabel: null, fixtures: [] };
  const group = predictionGameweek(context);
  if (includeLocked) {
    const all = await gameweekFixtures(db, context);
    const fixtures = await gameFixtureBatch(db, playerId, all.map((f) => f._id), now);
    return { ...competitionFields(context), serverTime: iso(typeof now === "function" ? now() : now), gameweekId: group.id, gameweekLabel: group.label, fixtures };
  }
  return {
    ...competitionFields(context), serverTime: iso(responseNow), gameweekId: group.id, gameweekLabel: group.label,
    // Saved predictions remain reviewable; the client excludes its current and
    // visited fixtures while progressing, so Save and next cannot cycle.
    fixtures: eligible.filter((f) => predictionGameweek(f).id === group.id).map((f) => fixtureResponse(f, entriesById.get(f._id), responseNow)),
  };
}

function buildSummary(entries) {
  const settled = entries.filter((e) => !e.withdrawn && !e.void && Number.isInteger(e.youPoints) && Number.isInteger(e.aiPoints));
  const summary = { played: settled.length, youPoints: 0, aiPoints: 0, wins: 0, draws: 0, losses: 0, exactScores: 0, aiExactScores: 0, correctResults: 0, aiCorrectResults: 0 };
  for (const entry of settled) {
    summary.youPoints += entry.youPoints; summary.aiPoints += entry.aiPoints;
    summary[entry.youPoints > entry.aiPoints ? "wins" : entry.youPoints < entry.aiPoints ? "losses" : "draws"] += 1;
    if (entry.youPoints === 3) summary.exactScores += 1;
    if (entry.aiPoints === 3) summary.aiExactScores += 1;
    if (entry.youPoints > 0) summary.correctResults += 1;
    if (entry.aiPoints > 0) summary.aiCorrectResults += 1;
  }
  const ratio = (n, multiplier = 1) => summary.played ? Math.round(n / summary.played * multiplier * 100) / 100 : 0;
  return { ...summary, winPercentage: ratio(summary.wins, 100), resultAccuracy: ratio(summary.correctResults, 100), aiResultAccuracy: ratio(summary.aiCorrectResults, 100), averagePoints: ratio(summary.youPoints), aiAveragePoints: ratio(summary.aiPoints) };
}

function buildAchievements(entries, challenges, fixtures) {
  const summary = buildSummary(entries);
  const active = entries.filter((e) => !e.withdrawn && !e.void && Number.isInteger(e.youPoints));
  const entryMap = new Map(active.map((e) => [e.fixtureId, e]));
  const fixtureMap = new Map(fixtures.map((f) => [f._id, f]));
  let lead = 0; let bestLead = 0;
  for (const entry of [...active].sort((a, b) => String(a.kickoffAt).localeCompare(String(b.kickoffAt)) || a.fixtureId.localeCompare(b.fixtureId))) {
    lead += entry.youPoints - entry.aiPoints;
    bestLead = Math.max(bestLead, lead);
  }
  const cleanSweeps = challenges.filter((c) => {
    const eligible = c.fixtureIds.filter((id) => !fixtureMap.get(id)?.void);
    return eligible.length > 0 && eligible.every((id) => fixtureMap.get(id)?.result && entryMap.get(id)?.youPoints > 0);
  }).length;
  const seasonsByCompetition = new Map();
  for (const entry of active.filter((e) => e.challengeId)) {
    const id = competitionId(entry);
    if (!seasonsByCompetition.has(id)) seasonsByCompetition.set(id, new Set());
    seasonsByCompetition.get(id).add(entry.seasonId);
  }
  const seasonedSeasons = Math.max(0, ...[...seasonsByCompetition.values()].map((seasons) => seasons.size));
  const values = [summary.played, summary.exactScores, summary.exactScores, summary.correctResults, summary.wins,
    bestLead, cleanSweeps, seasonedSeasons];
  return ACHIEVEMENTS.map(([id, title, description, target], index) => ({ id, title, description, target, progress: Math.min(100, values[index] / target * 100), unlocked: values[index] >= target }));
}

function publicPlayer(player) { return { id: player._id, displayName: player.displayName, gameCenterLinked: Boolean(player.gameCenterSubject) }; }

async function issueSession(db, playerId, verifiedSubject = null, now = Date.now()) {
  const id = crypto.randomUUID(); const secret = crypto.randomBytes(32).toString("base64url");
  await db.collection("pg_sessions").insertOne({ _id: id, playerId, secretHash: digest(secret), createdAt: iso(now), updatedAt: iso(now),
    ...(verifiedSubject ? { verifiedGameCenterSubject: verifiedSubject, privateExpiresAt: new Date(now + DAY) } : {}) });
  return `${id}.${secret}`;
}

async function authenticateCredential(db, header, requireVerified = false, now = Date.now()) {
  const match = String(header || "").match(/^Bearer ([a-f0-9-]{36})\.([A-Za-z0-9_-]{43})$/);
  if (!match) throw new GameError(401, "unauthorized", "Open Beat the AI to start or restore your game.");
  const session = await db.collection("pg_sessions").findOne({ _id: match[1] });
  const expected = Buffer.from(session?.secretHash || "0".repeat(64), "hex");
  if (expected.length !== 32 || !crypto.timingSafeEqual(Buffer.from(digest(match[2]), "hex"), expected)) throw new GameError(401, "unauthorized", "Your game session could not be verified.");
  const player = await db.collection("pg_players").findOne({ _id: session.playerId });
  if (!player) throw new GameError(401, "unauthorized", "Your game session could not be verified.");
  if (requireVerified && (!session.verifiedGameCenterSubject || session.verifiedGameCenterSubject !== player.gameCenterSubject || +new Date(session.privateExpiresAt) <= now || !Number.isFinite(+new Date(session.privateExpiresAt)))) {
    throw new GameError(401, "game_center_required", "Game Center needs a fresh verification to open your private leagues.");
  }
  return player;
}

// A short distributed mutex serializes source updates and player writes for a
// fixture, even with several API processes; no Mongo replica-set prerequisite.
async function withFixtureLock(db, fixtureId, action) {
  const token = crypto.randomUUID();
  const lease = { _id: fixtureId, token, expiresAt: new Date(Date.now() + 15000), updatedAt: iso() };
  try {
    await db.collection("pg_locks").updateOne({ _id: fixtureId, expiresAt: { $lte: new Date() } }, { $set: lease }, { upsert: true });
  } catch (error) {
    if (error.code === 11000) throw new GameError(409, "fixture_busy", "This match is updating. Please try again.");
    throw error;
  }
  let lost = false; let renewing = null;
  const renew = async () => {
    if (lost) throw new GameError(409, "fixture_busy", "This match is updating. Please try again.");
    if (!renewing) renewing = db.collection("pg_locks").updateOne({ _id: fixtureId, token, expiresAt: { $gt: new Date() } }, { $set: { expiresAt: new Date(Date.now() + 15000) } }, { maxTimeMS: 3000 })
      .then((result) => { if (result.matchedCount !== 1) lost = true; }).catch(() => { lost = true; }).finally(() => { renewing = null; });
    await renewing;
    if (lost) throw new GameError(409, "fixture_busy", "This match is updating. Please try again.");
  };
  const timer = setInterval(() => renew().catch(() => {}), 3000); timer.unref();
  try { return await action(renew); }
  finally { clearInterval(timer); if (renewing) await renewing; await db.collection("pg_locks").deleteOne({ _id: fixtureId, token }); }
}

async function markStatsDirty(db, playerId) {
  await db.collection("pg_players").updateOne({ _id: playerId }, { $set: { statsDirty: true, updatedAt: iso() }, $inc: { statsRevision: 1 } });
}

async function drainPendingStats(db, playerId = null) {
  const entries = await db.collection("pg_entries").find({ statsPending: true, ...(playerId ? { playerId } : {}) }).toArray();
  for (const entry of entries) {
    await markStatsDirty(db, entry.playerId);
    await db.collection("pg_entries").updateOne({ _id: entry._id, version: entry.version }, { $set: { statsPending: false } });
  }
}

async function persistFixture(db, doc, prediction, renew = async () => {}, settle = true) {
  const previous = await db.collection("pg_fixtures").findOne({ _id: String(doc.payload?.id) });
  const fixture = fixtureFromEvent((await eventDocsWithResults(db, [doc]))[0], previous, prediction);
  if (!fixture) return null;
  await renew();
  const changed = await db.collection("pg_fixtures").updateOne({ _id: fixture._id, ...(previous ? { version: previous.version } : {}) }, { $set: fixture, $setOnInsert: { createdAt: iso() }, $inc: { version: 1 } }, { upsert: !previous, maxTimeMS: 3000 });
  if (previous && !changed.matchedCount) throw new GameError(409, "fixture_busy", "This match is updating. Please try again.");
  if (!settle) return fixture;
  // Pending/crashed settlements are retried regardless of source revision.
  const entries = await db.collection("pg_entries").find({ fixtureId: fixture._id, resultRevision: { $ne: fixture.resultRevision } }).toArray();
  for (const entry of entries) {
    if (!entry.ai) continue;
    const youPoints = fixture.void || entry.withdrawn ? null : pointsFor(entry, fixture.result);
    const aiPoints = fixture.void || entry.withdrawn ? null : pointsFor(entry.ai, fixture.result);
    await renew();
    const settled = await db.collection("pg_entries").updateOne({ _id: entry._id, version: entry.version }, { $set: {
      youPoints, aiPoints, outcome: youPoints == null ? null : youPoints > aiPoints ? "win" : youPoints < aiPoints ? "loss" : "draw",
      void: fixture.void, resultRevision: fixture.resultRevision, settledAt: youPoints == null ? null : iso(),
      ...competitionFields(fixture), kickoffAt: fixture.kickoffAt, seasonId: fixture.seasonId, seasonLabel: fixture.seasonLabel, challengeId: fixture.challengeId, statsPending: true,
    }, $inc: { version: 1 } }, { maxTimeMS: 3000 });
    if (settled.matchedCount !== 1) throw new GameError(409, "fixture_busy", "This match is updating. Please try again.");
    // statsPending lives in the same write as the new points; a process crash
    // before marking the player dirty can therefore never lose a correction.
  }
  return fixture;
}

async function publishChallenges(db, now = Date.now()) {
  const fixtures = await db.collection("pg_fixtures").find({ kickoffAt: { $gte: iso(now - 7 * DAY), $lte: iso(now + 21 * DAY) } }).sort({ kickoffAt: 1, _id: 1 }).toArray();
  const published = await db.collection("pg_challenges").find({ fixtureIds: { $in: fixtures.map((f) => f._id) } }).toArray();
  const publishedById = new Map(published.map((c) => [c._id, c]));
  const claimedIds = new Set(published.flatMap((c) => c.fixtureIds));
  const groups = new Map();
  for (const f of fixtures) {
    const id = competitionId(f) === "1" ? weekId(f.kickoffAt) : scopedId(competitionId(f), `${f.seasonId}:${weekId(f.kickoffAt)}`);
    if (!groups.has(id)) groups.set(id, []);
    groups.get(id).push(f);
  }
  for (const [id, all] of groups) {
    let challenge = await db.collection("pg_challenges").findOne({ _id: id });
    if (!challenge) {
      // Never create a retrospective contest once any fixture in its week began.
      if (all.some((f) => f.ai && isLocked(f, now) && !f.void)) continue;
      const chosen = all.filter((f) => f.ai && !f.void && !f.challengeId && !claimedIds.has(f._id)).slice(0, 10);
      if (!chosen.length) continue;
      challenge = { _id: id, ...competitionFields(chosen[0]), title: `Weekly ${competitionName(chosen[0])} Challenge`, seasonId: chosen[0].seasonId,
        startsAt: chosen[0].kickoffAt, endsAt: iso(Date.parse(chosen.at(-1).kickoffAt) + DAY),
        fixtureIds: chosen.map((f) => f._id), publishedAt: iso(now), updatedAt: iso(now) };
      try { await db.collection("pg_challenges").updateOne({ _id: id }, { $setOnInsert: challenge }, { upsert: true }); }
      catch (error) { if (error.code !== 11000) throw error; }
      challenge = await db.collection("pg_challenges").findOne({ _id: id });
      if (!challenge) continue; // Another publisher claimed these fixtures first.
    }
    publishedById.set(challenge._id, challenge);
    challenge.fixtureIds.forEach((fixtureId) => claimedIds.add(fixtureId));
  }
  for (const challenge of publishedById.values()) {
    // Published membership is the authority, including after a crash before
    // these denormalized fields were written. Version bumps fence stale writers.
    await db.collection("pg_fixtures").updateMany({ _id: { $in: challenge.fixtureIds }, challengeId: null }, { $set: { challengeId: challenge._id }, $inc: { version: 1 } });
    await db.collection("pg_entries").updateMany({ fixtureId: { $in: challenge.fixtureIds }, challengeId: null }, { $set: { challengeId: challenge._id, statsPending: true }, $inc: { version: 1 } });
  }
}

async function rebuildPlayer(db, playerId) {
  const player = await db.collection("pg_players").findOne({ _id: playerId });
  const revision = player.statsRevision || 0;
  const entries = await db.collection("pg_entries").find({ playerId, ai: { $exists: true } }).toArray();
  // A new guest has no history. Do not scan every archived challenge and write
  // hundreds of zero-score leaderboard rows before activation can complete.
  const challenges = entries.length ? await db.collection("pg_challenges").find({ fixtureIds: { $in: entries.map((entry) => entry.fixtureId) } }).toArray() : [];
  const relevantIds = [...new Set([...entries.map((e) => e.fixtureId), ...challenges.flatMap((c) => c.fixtureIds)])];
  const fixtures = await db.collection("pg_fixtures").find({ _id: { $in: relevantIds } }).toArray();
  const summarize = (selectedEntries, selectedChallenges, selectedFixtures) => {
    const seasons = [...new Map(selectedEntries.map((e) => [e.seasonId, { id: e.seasonId, label: e.seasonLabel, ...competitionFields(e) }])).values()].sort((a, b) => b.label.localeCompare(a.label));
    const summary = buildSummary(selectedEntries); const achievements = buildAchievements(selectedEntries, selectedChallenges, selectedFixtures);
    const bySeason = Object.fromEntries(seasons.map((season) => [season.id, buildSummary(selectedEntries.filter((e) => e.seasonId === season.id))]));
    const ranks = selectedChallenges.map((c) => ({ challengeId: c._id, seasonId: c.seasonId, ...competitionFields(c), ...buildSummary(selectedEntries.filter((e) => c.fixtureIds.includes(e.fixtureId))) }));
    return { summary, achievements, seasons, bySeason, ranks };
  };
  const byCompetition = {};
  for (const id of new Set(["1", ...entries.map(competitionId)])) {
    byCompetition[id] = summarize(entries.filter((e) => competitionId(e) === id), challenges.filter((c) => competitionId(c) === id), fixtures.filter((f) => competitionId(f) === id));
  }
  // Global achievement progress is retained for the existing Apple identifiers.
  // Every visible record, challenge and ranked total is competition-specific.
  const summary = buildSummary(entries); const achievements = buildAchievements(entries, challenges, fixtures);
  const ranks = Object.values(byCompetition).flatMap((value) => value.ranks);
  const seasons = Object.values(byCompetition).flatMap((value) => value.seasons);
  const bySeason = byCompetition["1"].bySeason;
  await db.collection("pg_stats").updateOne({ _id: playerId }, { $setOnInsert: { revision: -1 } }, { upsert: true });
  await db.collection("pg_stats").updateOne({ _id: playerId, revision: { $lte: revision } }, { $set: { summary, bySeason, seasons, achievements, ranks, byCompetition, revision, updatedAt: iso() } });
  const boardValues = ranks.map((r) => ({ ...competitionFields(r), scope: scopedId(competitionId(r), `weekly:${r.challengeId}`), points: r.youPoints }));
  for (const season of seasons) {
    const id = competitionId(season);
    const seasonRanks = ranks.filter((r) => competitionId(r) === id && r.seasonId === season.id);
    boardValues.push({ ...competitionFields(season), scope: scopedId(id, `season:${season.id}`), points: seasonRanks.reduce((sum, r) => sum + r.youPoints, 0) });
    boardValues.push({ ...competitionFields(season), scope: scopedId(id, `perfect:${season.id}`), points: seasonRanks.reduce((sum, r) => sum + r.exactScores, 0) });
  }
  for (const board of boardValues) {
    const id = `${board.scope}:${playerId}`;
    await db.collection("pg_leaderboards").updateOne({ _id: id }, { $setOnInsert: { revision: -1 } }, { upsert: true });
    await db.collection("pg_leaderboards").updateOne({ _id: id, revision: { $lte: revision } }, { $set: { ...board, playerId, displayName: player.displayName,
      published: Boolean(player.gameCenterSubject), revision, updatedAt: iso() } });
  }
  // A crash or concurrent settlement leaves the dirty revision discoverable.
  // Older rebuilds cannot replace a more recent cache or leaderboard row.
  await db.collection("pg_players").updateOne({ _id: playerId, statsRevision: revision }, { $set: { statsDirty: false } });
  return { summary, seasons, achievements, bySeason, ranks, byCompetition };
}

function createPredictionGame(options = {}) {
  let syncPromise = null; let lastSync = 0; let sourceCursor = null;
  const database = options.getDb || getDb;
  const now = options.now || Date.now;
  async function sync(force = false) {
    if (syncPromise) return syncPromise;
    if (!force && now() - lastSync < 15000) return;
    syncPromise = (async () => {
      const db = await database();
      if (!db) throw new GameError(503, "unavailable", "The prediction game is temporarily unavailable.");
      const startedAt = iso();
      const predictionDocs = await db.collection("bsd_predictions").find({}).toArray();
      const predictions = new Map(predictionDocs.flatMap((doc) => (Array.isArray(doc.payload) ? doc.payload : []).map((p) => [String(p.event?.id), aiPrediction(p)]).filter(([, ai]) => ai)));
      const known = await db.collection("pg_fixtures").find({}, { projection: { _id: 1 } }).toArray();
      // Import only AI-supported or previously played fixtures, never every
      // historical event across every competition on a cold worker start.
      const ids = [...new Set([...predictions.keys(), ...known.map((f) => f._id)])];
      const knownIds = new Set(known.map((f) => f._id));
      const changedIncidents = sourceCursor ? await db.collection("bsd_incidents").find({ _id: { $in: [...knownIds] }, updated_at: { $gte: sourceCursor } }, { projection: { _id: 1 } }).toArray() : [];
      const filter = { _id: { $in: ids }, ...(sourceCursor ? { $or: [{ updated_at: { $gte: sourceCursor } }, { _id: { $in: [...predictions.keys()].filter((id) => !knownIds.has(id)).concat(changedIncidents.map((doc) => String(doc._id))) } }] } : {}) };
      const cursor = db.collection("bsd_events").find(filter).sort({ _id: 1 }).batchSize(200);
      let skipped = false;
      for await (const doc of cursor) {
        try { await withFixtureLock(db, String(doc.payload?.id), (renew) => persistFixture(db, doc, predictions.get(String(doc.payload?.id)), renew)); }
        catch (error) { if (error.code === "fixture_busy") { skipped = true; continue; } throw error; }
      }
      // Retry unsettled entries and refresh future predictions when market data
      // changes without an event update. This also repairs interrupted writes.
      const active = await db.collection("pg_fixtures").find({ $or: [ { kickoffAt: { $gte: iso(now()) } }, { result: null, void: false } ] }).toArray();
      for (const fixture of active) {
        const doc = await db.collection("bsd_events").findOne({ _id: fixture._id });
        if (!doc) continue;
        try { await withFixtureLock(db, fixture._id, (renew) => persistFixture(db, doc, predictions.get(fixture._id), renew)); }
        catch (error) { if (error.code === "fixture_busy") { skipped = true; continue; } throw error; }
      }
      await publishChallenges(db, now());
      await drainPendingStats(db);
      const dirty = await db.collection("pg_players").find({ statsDirty: true }).toArray();
      for (const player of dirty) {
        try { await rebuildPlayer(db, player._id); }
        catch (error) { await db.collection("pg_players").updateOne({ _id: player._id }, { $set: { statsDirty: true } }); throw error; }
      }
      if (!skipped) sourceCursor = startedAt;
      lastSync = now();
    })().finally(() => { syncPromise = null; });
    return syncPromise;
  }

  async function save(db, player, fixtureId, body, withdrawn = false, authorize = async () => {}) {
    if (!validFixtureId(fixtureId)) throw new GameError(404, "fixture_not_found", "Match not found.");
    if (!withdrawn && body?.penaltyWinner != null && !["home", "away"].includes(body.penaltyWinner)) throw new GameError(400, "invalid_penalty_winner", "Choose a team to win on penalties.");
    if (!withdrawn && ![body?.homeScore, body?.awayScore].every(scoreInteger)) throw new GameError(400, "invalid_score", "Enter whole-number scores from 0 to 20.");
    return withFixtureLock(db, fixtureId, async (renew) => {
      await authorize();
      const doc = await db.collection("bsd_events").findOne({ _id: fixtureId });
      if (!doc || !/^[1-9]\d{0,15}$/.test(String(doc.payload?.league_id))) throw new GameError(404, "fixture_not_found", "Match not found.");
      const predictionDoc = await db.collection("bsd_predictions").findOne({ _id: String(doc.payload.league_id) });
      const predictionItem = (Array.isArray(predictionDoc?.payload) ? predictionDoc.payload : []).find((p) => String(p.event?.id) === fixtureId);
      const fixture = await persistFixture(db, doc, aiPrediction(predictionItem), renew, false);
      if (!fixture || isLocked(fixture, now())) throw new GameError(409, "prediction_locked", "Predictions lock at kick-off.");
      const id = `${player._id}:${fixtureId}`;
      const previous = await db.collection("pg_entries").findOne({ _id: id });
      if (!previous?.ai && withdrawn) return fixtureResponse(fixture, null, now());
      const ai = previous?.ai || fixture.ai;
      if (!ai) throw new GameError(409, "ai_unavailable", "The AI prediction is not ready for this match yet.");
      if (!previous?.ai && body.expectedAIRevision !== ai.sourceRevision) throw new GameError(409, "ai_changed", "The AI prediction has changed. Review it before saving your prediction.");
      // A database-side clock check prevents a request received before kick-off
      // but delayed in processing from committing after the deadline.
      // MongoDB forbids $expr in an upsert. This inert placeholder cannot appear
      // in stats/history and does not freeze the AI until the guarded write.
      if (!previous) await db.collection("pg_entries").updateOne({ _id: id }, { $setOnInsert: { playerId: player._id, fixtureId, version: 0, withdrawn: true } }, { upsert: true, maxTimeMS: 3000 });
      const filter = { _id: id, version: previous?.version || 0, $expr: { $lt: ["$$NOW", new Date(fixture.kickoffAt)] } };
      const savedAt = iso(now());
      const fields = { homeScore: withdrawn ? previous.homeScore : body.homeScore, awayScore: withdrawn ? previous.awayScore : body.awayScore,
         penaltyWinner: withdrawn ? previous.penaltyWinner || null : body.homeScore === body.awayScore || fixture.isSecondLeg ? body.penaltyWinner || null : null,
        ...competitionFields(fixture), withdrawn, updatedAt: savedAt, kickoffAt: fixture.kickoffAt, seasonId: fixture.seasonId, seasonLabel: fixture.seasonLabel,
        challengeId: fixture.challengeId, resultRevision: null, youPoints: null, aiPoints: null, outcome: null, void: false, statsPending: true };
      if (!previous?.ai) Object.assign(fields, { ai: { ...ai, frozenAt: savedAt }, scoringRulesVersion: SCORING_RULES_VERSION, createdAt: savedAt });
      try {
        await renew();
        await authorize();
        const changed = await db.collection("pg_entries").updateOne(filter, { $set: fields, $inc: { version: 1 } }, { maxTimeMS: 3000 });
        if (!changed.matchedCount) throw new GameError(409, "prediction_locked", "Predictions lock at kick-off.");
      } catch (error) {
        if (error.code === 11000) throw new GameError(409, "prediction_locked", "The prediction changed or kick-off has passed. Refresh and try again.");
        throw error;
      }
      const entry = await db.collection("pg_entries").findOne({ _id: id });
      await drainPendingStats(db, player._id);
      return fixtureResponse(fixture, entry, now());
    });
  }
  async function refresh() {
    // Even the first refresh must not put a full historical import on an
    // interactive request's critical path. Source reads work with an empty cache.
    sync().catch((error) => console.warn("[Prediction game] refresh:", error.message));
  }
  return { sync, refresh, save, database, now };
}

// Game Center verification uses an Apple-hosted key over authenticated HTTPS.
// The URL is constrained before any network request, with redirects disabled.
const keyCache = new Map();
function gameCenterKeyUrl(value) {
  let url; try { url = new URL(value); } catch (_) { return null; }
  return url.protocol === "https:" && url.hostname === "static.gc.apple.com" && !url.port && !url.username && !url.password && !url.search && !url.hash && /^\/public-key\/[A-Za-z0-9_.-]+\.cer$/.test(url.pathname) ? url.toString() : null;
}

async function verifyGameCenter(body, options = {}) {
  const bundleId = options.bundleId || process.env.PREDICTION_GAME_BUNDLE_ID || "topscores.dev.skynolimit";
  const timestamp = Number(body?.timestamp); const current = options.now?.() ?? Date.now();
  if (!Number.isSafeInteger(timestamp) || timestamp < current - 5 * 60000 || timestamp > current + 60000) throw new GameError(401, "invalid_identity", "Game Center verification expired. Please connect again.");
  const subject = String(body?.teamPlayerId || "");
  const url = gameCenterKeyUrl(body?.publicKeyUrl);
  if (!subject || subject.length > 256 || !url || !/^[A-Za-z0-9+/]+={0,2}$/.test(body?.signature || "") || !/^[A-Za-z0-9+/]+={0,2}$/.test(body?.salt || "")) throw new GameError(401, "invalid_identity", "Game Center identity could not be verified.");
  const signature = Buffer.from(body.signature, "base64"); const salt = Buffer.from(body.salt, "base64");
  if (salt.length < 1 || salt.length > 128 || signature.length < 128 || signature.length > 1024) throw new GameError(401, "invalid_identity", "Game Center identity could not be verified.");
  let cached = keyCache.get(url);
  if (!cached || cached.expiresAt <= current) {
    const response = await (options.fetch || fetch)(url, { redirect: "error", signal: AbortSignal.timeout(5000) });
    if (!response.ok) throw new GameError(503, "game_center_unavailable", "Game Center verification is temporarily unavailable.");
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.length > 16384) throw new GameError(401, "invalid_identity", "Game Center signing key is invalid.");
    const certificate = new crypto.X509Certificate(bytes);
    if (Date.parse(certificate.validFrom) > current || Date.parse(certificate.validTo) <= current) throw new GameError(401, "invalid_identity", "Game Center signing key has expired.");
    const maxAge = Number(response.headers.get("cache-control")?.match(/max-age=(\d+)/)?.[1] || 300);
    cached = { key: certificate.publicKey, expiresAt: Math.min(Date.parse(certificate.validTo), current + Math.min(86400, maxAge) * 1000) };
    keyCache.set(url, cached);
  }
  const timestampBytes = Buffer.alloc(8); timestampBytes.writeBigUInt64BE(BigInt(timestamp));
  const message = Buffer.concat([Buffer.from(subject), Buffer.from(bundleId), timestampBytes, salt]);
  if (!crypto.verify("RSA-SHA256", message, cached.key, signature)) throw new GameError(401, "invalid_identity", "Game Center identity could not be verified.");
  return { subject: digest(`${bundleId}:${subject}`), assertionId: digest(Buffer.concat([message, signature])), expiresAt: new Date(timestamp + 5 * 60000) };
}

function gameCenterLeaderboardConfiguration() {
  let configured = {}; try { configured = JSON.parse(process.env.PREDICTION_GAME_GC_LEADERBOARDS || "{}"); } catch (_) { /* Fail closed. */ }
  const items = Object.entries(configured).flatMap(([scope, id]) => {
    const match = scope.match(/^(?:competition:([1-9]\d*):)?(weekly|season|perfect):(.+)$/);
    if (!match || typeof id !== "string" || !id.trim()) return [];
    const selectedCompetition = match[1] || "1";
    return [{ id, competitionId: selectedCompetition, category: match[2], key: match[3], scope: scopedId(selectedCompetition, `${match[2]}:${match[3]}`) }];
  });
  // Sharing an Apple identifier would overwrite another competition or week.
  // Reject every ambiguous mapping rather than silently combining its totals.
  return items.filter((item) => items.filter((other) => other.id === item.id).length === 1);
}

function registerPredictionGameRoutes(app, options = {}) {
  const game = createPredictionGame(options);
  const buckets = new Map();
  const route = (handler, authenticated = true) => async (req, res) => {
    try {
      res.set("Cache-Control", "no-store");
      if (options.enabled === false) throw new GameError(503, "unavailable", "Beat the AI is not available yet.");
      const db = await game.database();
      if (!db) throw new GameError(503, "unavailable", "The prediction game is temporarily unavailable.");
      const player = authenticated ? await authenticateCredential(db, req.headers.authorization) : null;
      if (!options.disableRateLimits) {
        const key = `${player?._id || req.ip}:${req.method === "GET" ? "read" : "write"}`;
        const period = Math.floor(Date.now() / 60000); const prior = buckets.get(key);
        const bucket = prior?.period === period ? prior : { period, count: 0 };
        bucket.count += 1; buckets.set(key, bucket);
        if (buckets.size > 10000) for (const [k, v] of buckets) if (v.period < period) buckets.delete(k);
        if (bucket.count > (req.method === "GET" ? 120 : authenticated ? 60 : 10)) { res.set("Retry-After", "60"); throw new GameError(429, "rate_limited", "Please wait a moment and try again."); }
      }
      return await handler(req, res, db, player);
    } catch (error) {
      if (!error.status) console.warn("[Prediction game]", error.message);
      return res.status(error.status || 503).json({ error: error.status ? error.message : "The prediction game is temporarily unavailable. Please try again.", code: error.code && typeof error.code === "string" ? error.code : "unavailable" });
    }
  };
  async function stats(db, playerId) {
    await drainPendingStats(db, playerId);
    const player = await db.collection("pg_players").findOne({ _id: playerId });
    const cached = await db.collection("pg_stats").findOne({ _id: playerId });
    return cached?.byCompetition && !player.statsDirty ? cached : rebuildPlayer(db, playerId);
  }

  app.post(`${PREFIX}/players`, route(async (req, res, db) => {
    const displayName = String(req.body?.displayName || "Player").trim().replace(/\s+/g, " ").slice(0, 32) || "Player";
    const player = { _id: crypto.randomUUID(), displayName, statsDirty: true, statsRevision: 0, createdAt: iso(), updatedAt: iso() };
    await db.collection("pg_players").insertOne(player);
    res.status(201).json({ player: publicPlayer(player), credential: await issueSession(db, player._id) });
  }, false));

  app.get(`${PREFIX}/fixtures`, route(async (req, res, db, player) => {
    const ids = [...new Set(String(req.query.ids || "").split(",").map(cleanId).filter(validFixtureId))].slice(0, 200);
    const fixtures = await gameFixtureBatch(db, player._id, ids, game.now);
    res.json({ fixtures, serverTime: iso(game.now()) });
  }));

  app.get(`${PREFIX}/in-play`, route(async (req, res, db, player) => {
    const selectedCompetition = requestedCompetition(req.query.competitionId);
    await game.refresh();
    res.json({
      competitionId: selectedCompetition,
      round: await inPlayGameweek(db, player._id, selectedCompetition, game.now),
      serverTime: iso(game.now()),
    });
  }));

  app.get(`${PREFIX}/next-predictions`, route(async (req, res, db, player) => {
    res.json(await nextPredictionSet(db, player._id, req.query.fixtureId == null ? null : cleanId(req.query.fixtureId), game.now, req.query.includeLocked === "true", req.query.competitionId == null ? null : requestedCompetition(req.query.competitionId)));
  }));

  app.get(`${PREFIX}/state`, route(async (req, res, db, player) => {
    const selectedCompetition = requestedCompetition(req.query.competitionId);
    await game.refresh();
    const now = game.now();
    const challenges = await db.collection("pg_challenges").find({ ...competitionFilter(selectedCompetition), endsAt: { $gte: iso(now) } }).sort({ startsAt: 1 }).limit(1).toArray();
    const current = challenges[0] || null;
    const [events, cached, allTotals, recent, latestResult, competitions] = await Promise.all([
      db.collection("bsd_events").find({ league_id: { $in: [Number(selectedCompetition), selectedCompetition] }, $or: [{ event_date: { $gte: iso(now - DAY), $lte: iso(now + 30 * DAY) } }, { _id: { $in: current?.fixtureIds || [] } }] }, { projection: { _id: 1 } }).toArray(),
      db.collection("pg_fixtures").find({ ...competitionFilter(selectedCompetition), $or: [{ kickoffAt: { $gte: iso(now - DAY), $lte: iso(now + 30 * DAY) } }, { _id: { $in: current?.fixtureIds || [] } }] }, { projection: { _id: 1 } }).toArray(),
      stats(db, player._id),
      recentGameweeks(db, player._id, null, selectedCompetition),
      latestCompletedGameweek(db, player._id),
      availableCompetitions(db, player._id),
    ]);
    const totals = allTotals.byCompetition[selectedCompetition] || { summary: buildSummary([]), seasons: [], achievements: buildAchievements([], [], []) };
    const ids = [...new Set([...events.map((doc) => String(doc._id)), ...cached.map((f) => f._id)])];
    const items = await gameFixtureBatch(db, player._id, ids, game.now);
    const challengeItems = items.filter((f) => current?.fixtureIds.includes(f.id));
    const challenge = current ? { id: current._id, ...competitionFields(current), title: current.title, seasonId: current.seasonId, startsAt: current.startsAt, endsAt: current.endsAt,
      fixtureIds: current.fixtureIds, youPoints: challengeItems.reduce((s, f) => s + (f.prediction?.youPoints || 0), 0), aiPoints: challengeItems.reduce((s, f) => s + (f.prediction?.aiPoints || 0), 0),
      completed: challengeItems.length === current.fixtureIds.length && challengeItems.every((f) => f.settled || f.void) } : null;
    const seasons = [...new Map([...totals.seasons, ...items.map((f) => ({ id: f.seasonId, label: f.seasonLabel, ...competitionFields(f) }))].map((season) => [season.id, season])).values()].sort((a, b) => b.label.localeCompare(a.label));
    res.json({ competitionId: selectedCompetition, competitionName: competitions.find((c) => c.id === selectedCompetition)?.name || competitionName({ competitionId: selectedCompetition }), competitions,
      player: publicPlayer(player), serverTime: iso(game.now()), summary: totals.summary, seasons, achievements: totals.achievements, challenge, fixtures: items, recentGameweeks: recent, latestResult });
  }));

  async function saveForRequest(req, db, player, withdrawn = false) {
    // Joining a private league and saving a pick use the same player lease.
    // A formerly guest credential cannot race a join to affect private scores.
    return withFixtureLock(db, `private-player:${player._id}`, async (renew) => game.save(db, player, cleanId(req.params.fixtureId), withdrawn ? {} : req.body, withdrawn, async () => {
      await renew();
      if (await db.collection("pg_mini_leagues").findOne({ activePlayerIds: player._id, status: "active" })) await authenticateCredential(db, req.headers.authorization, true, game.now());
    }));
  }
  app.put(`${PREFIX}/predictions/:fixtureId`, route(async (req, res, db, player) => {
    const fixture = await saveForRequest(req, db, player);
    res.json({ fixture, serverTime: iso(game.now()) });
  }));
  app.delete(`${PREFIX}/predictions/:fixtureId`, route(async (req, res, db, player) => {
    const fixture = await saveForRequest(req, db, player, true);
    res.json({ fixture, serverTime: iso(game.now()) });
  }));
  app.get(`${PREFIX}/stats`, route(async (req, res, db, player) => {
    const selectedCompetition = requestedCompetition(req.query.competitionId);
    await game.refresh(); const allTotals = await stats(db, player._id);
    const totals = allTotals.byCompetition[selectedCompetition] || { summary: buildSummary([]), bySeason: {}, seasons: [], achievements: buildAchievements([], [], []) };
    const competitions = await availableCompetitions(db, player._id);
    res.json({ competitionId: selectedCompetition, competitionName: competitions.find((c) => c.id === selectedCompetition)?.name || competitionName({ competitionId: selectedCompetition }), competitions, summary: req.query.seasonId ? totals.bySeason[req.query.seasonId] || buildSummary([]) : totals.summary, seasons: totals.seasons, achievements: totals.achievements,
      recentGameweeks: await recentGameweeks(db, player._id, req.query.seasonId ? String(req.query.seasonId) : null, selectedCompetition) });
  }));
  app.get(`${PREFIX}/history`, route(async (req, res, db, player) => {
    await game.refresh();
    const offset = Math.max(0, Math.min(100000, parseInt(req.query.offset, 10) || 0));
    const limit = Math.max(1, Math.min(100, parseInt(req.query.limit, 10) || 50));
    const selectedCompetition = requestedCompetition(req.query.competitionId);
    const filter = { playerId: player._id, ...competitionFilter(selectedCompetition), withdrawn: false, ...(req.query.seasonId ? { seasonId: String(req.query.seasonId) } : {}) };
    const [entries, total] = await Promise.all([db.collection("pg_entries").find(filter).sort({ kickoffAt: -1, fixtureId: 1 }).skip(offset).limit(limit).toArray(), db.collection("pg_entries").countDocuments(filter)]);
    const fixtures = await db.collection("pg_fixtures").find({ _id: { $in: entries.map((e) => e.fixtureId) } }).toArray();
    const map = new Map(fixtures.map((f) => [f._id, f]));
    res.json({ ...competitionFields({ competitionId: selectedCompetition }), fixtures: entries.filter((e) => map.has(e.fixtureId)).map((e) => fixtureResponse(map.get(e.fixtureId), e, game.now())), total, offset, hasMore: offset + entries.length < total });
  }));

  app.get(`${PREFIX}/leaderboards`, route(async (req, res, db, player) => {
    const selectedCompetition = requestedCompetition(req.query.competitionId);
    await game.refresh();
    const category = ["weekly", "season", "perfect"].includes(req.query.category) ? req.query.category : "weekly";
    const candidates = req.query.challengeId ? [] : await db.collection("pg_challenges").find({ ...competitionFilter(selectedCompetition), endsAt: { $gte: iso(game.now()) } }).sort({ startsAt: 1 }).limit(1).toArray();
    const challengeId = String(req.query.challengeId || candidates[0]?._id || scopedId(selectedCompetition, weekId(iso(game.now()))));
    const current = await db.collection("pg_challenges").findOne({ _id: challengeId });
    if (current && competitionId(current) !== selectedCompetition) throw new GameError(400, "wrong_competition", "Choose a challenge from this competition.");
    const seasonId = String(req.query.seasonId || current?.seasonId || "");
    await stats(db, player._id);
    const scope = scopedId(selectedCompetition, `${category}:${category === "weekly" ? challengeId : seasonId}`);
    const records = await db.collection("pg_leaderboards").find({ ...competitionFilter(selectedCompetition), scope, $or: [{ published: true }, { playerId: player._id }] },
      { projection: { playerId: 1, displayName: 1, points: 1 } }).sort({ points: -1, displayName: 1, playerId: 1 }).limit(100).toArray();
    const rows = records.map((r) => ({ playerId: r.playerId, displayName: r.displayName, points: r.points, isYou: r.playerId === player._id }));
    rows.forEach((r, index) => { r.rank = index && rows[index - 1].points === r.points ? rows[index - 1].rank : index + 1; });
    const gameCenterLeaderboardId = gameCenterLeaderboardConfiguration().find((item) => item.scope === scope)?.id || null;
    res.json({ ...competitionFields({ competitionId: selectedCompetition, competitionName: current?.competitionName }), category, rows: rows.slice(0, 100), challengeId, seasonId, gameCenterLeaderboardId });
  }));

  app.post(`${PREFIX}/game-center`, route(async (req, res, db, player) => {
    const verified = await verifyGameCenter(req.body, options.gameCenter || {});
    const owner = await db.collection("pg_players").findOne({ gameCenterSubject: verified.subject });
    if (owner && owner._id !== player._id && req.body.restoreExisting !== true) throw new GameError(409, "existing_game_center_player", "Game Center already has a saved game. Restore it to continue; this guest game's history will remain separate.");
    if (player.gameCenterSubject && player.gameCenterSubject !== verified.subject && !owner) throw new GameError(409, "different_game_center_player", "This game is linked to a different Game Center account.");
    try { await db.collection("pg_assertions").insertOne({ _id: verified.assertionId, playerId: player._id, expiresAt: verified.expiresAt, updatedAt: iso() }); }
    catch (error) { if (error.code === 11000) throw new GameError(401, "identity_replayed", "Please connect Game Center again to get a fresh verification."); throw error; }
    if (owner && owner._id !== player._id) return res.json({ player: publicPlayer(owner), restoredExisting: true, credential: await issueSession(db, owner._id, verified.subject, game.now()), privateSessionExpiresAt: iso(game.now() + DAY) });
    const displayName = String(req.body.displayName || player.displayName).trim().slice(0, 32) || "Player";
    try {
      const linked = await db.collection("pg_players").updateOne({ _id: player._id, gameCenterSubject: { $in: [null, verified.subject] } }, { $set: { gameCenterSubject: verified.subject, displayName, updatedAt: iso() } });
      if (linked.matchedCount !== 1) throw new GameError(409, "different_game_center_player", "This game was linked to a different Game Center account. Open your own saved game to continue.");
    }
    catch (error) { if (error.code === 11000) throw new GameError(409, "existing_game_center_player", "Game Center already has a saved game. Connect again to restore it."); throw error; }
    await markStatsDirty(db, player._id);
    res.json({ player: publicPlayer({ ...player, displayName, gameCenterSubject: verified.subject }), restoredExisting: false, credential: await issueSession(db, player._id, verified.subject, game.now()), privateSessionExpiresAt: iso(game.now() + DAY) });
  }));

  app.get(`${PREFIX}/game-center/submissions`, route(async (_req, res, db, player) => {
    if (!player.gameCenterSubject) throw new GameError(409, "game_center_required", "Connect Game Center first.");
    await game.refresh(); const totals = await stats(db, player._id);
    // IDs are provisioned in App Store Connect. Never publish a guessed ID or
    // send a client-supplied gamePlayerId to Apple's server submission endpoint.
    const leaderboards = gameCenterLeaderboardConfiguration().map(({ id, competitionId: selectedCompetition, category, key }) => {
      const ranks = totals.ranks.filter((r) => competitionId(r) === selectedCompetition && (category === "weekly" ? r.challengeId === key : r.seasonId === key));
      return { id, score: ranks.reduce((sum, r) => sum + (category === "perfect" ? r.exactScores : r.youPoints), 0) };
    });
    const prefix = process.env.PREDICTION_GAME_GC_ACHIEVEMENT_PREFIX || "";
    res.json({ leaderboards, achievements: prefix ? totals.achievements.map((a) => ({ id: `${prefix}${a.id}`, percentComplete: a.progress })) : [] });
  }));

  const privateLeagues = require("./private_prediction_leagues").registerPrivatePredictionLeagueRoutes(app, {
    ...options, game, authenticateCredential,
    helpers: { GameError, fixtureFromEvent, fixtureResponse, isLocked, pointsFor, predictionMap, gameFixtureBatch, availableCompetitions, withFixtureLock, eventDocsWithResults },
  });

  // Settlement and recovery are independent of someone opening the game.
  let timer = null;
  if (!options.disableWorker && options.enabled !== false) {
    timer = setInterval(() => game.sync(true).then(() => privateLeagues.sync()).catch((error) => console.warn("[Prediction game] settlement:", error.message)), 60000);
    timer.unref();
  }
  return { ...game, privateLeagues, stop: () => timer && clearInterval(timer) };
}

module.exports = { registerPredictionGameRoutes, createPredictionGame, pointsFor, aiPrediction,
  __private: { GameError, fixtureFromEvent, fixtureResponse, isLocked, weekId, buildSummary, buildAchievements, publishChallenges,
    persistFixture, rebuildPlayer, authenticateCredential, issueSession, verifyGameCenter, gameCenterKeyUrl, withFixtureLock, nextPredictionSet, predictionGameweek, gameFixtureBatch, recentGameweeks, latestCompletedGameweek, inPlayGameweek, availableCompetitions, gameCenterLeaderboardConfiguration } };
