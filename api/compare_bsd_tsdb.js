#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// Compare ingested BSD events against the TSDB canonical `matches` collection.
//
// Joins by match date (UTC day, +/-1 day tolerance for timezone skew) and
// team-name equivalence (team_identity aliases). For matched pairs it reports
// score agreement, goal-count agreement, and lineup coverage on both sides.
//
// Run: MONGODB_URI_TOP_SCORES=... node api/compare_bsd_tsdb.js [outputPath]
// Output: console summary + JSON report (default ./bsd_vs_tsdb_report.json).
// ---------------------------------------------------------------------------

const fs = require("fs");
const path = require("path");

const {
  getBsdRecords,
  getAllOperationalMatchDetails,
  closeMongoConnection,
} = require("./mongo_client");
const { teamNamesEquivalent } = require("./team_identity");

const DEFAULT_OUTPUT = path.resolve(process.cwd(), "bsd_vs_tsdb_report.json");

function utcDay(value) {
  if (!value) return null;
  const ms = Date.parse(String(value));
  if (!Number.isFinite(ms)) return null;
  return new Date(ms).toISOString().slice(0, 10);
}

function adjacentDays(day) {
  if (!day) return [];
  const ms = Date.parse(`${day}T00:00:00Z`);
  if (!Number.isFinite(ms)) return [day];
  const dayMs = 86_400_000;
  return [-1, 0, 1].map((delta) => new Date(ms + delta * dayMs).toISOString().slice(0, 10));
}

// Count goals in a BSD incidents document.
function bsdGoalCount(incidentsDoc) {
  const incidents =
    incidentsDoc && incidentsDoc.payload && Array.isArray(incidentsDoc.payload.incidents)
      ? incidentsDoc.payload.incidents
      : [];
  return incidents.filter((inc) => inc && inc.type === "goal").length;
}

function tsdbGoalCount(match) {
  const home = Array.isArray(match.home_goal_scorers) ? match.home_goal_scorers : [];
  const away = Array.isArray(match.away_goal_scorers) ? match.away_goal_scorers : [];
  const flatten = (list) =>
    list.reduce((sum, entry) => {
      const times = entry && Array.isArray(entry.goal_times) ? entry.goal_times.length : 1;
      return sum + Math.max(1, times);
    }, 0);
  return flatten(home) + flatten(away);
}

function hasNumber(value) {
  return value != null && Number.isFinite(Number(value));
}

async function run(outputPath = DEFAULT_OUTPUT) {
  const [bsdEvents, bsdIncidents, bsdLineups, tsdbDetails] = await Promise.all([
    getBsdRecords("bsd_events"),
    getBsdRecords("bsd_incidents"),
    getBsdRecords("bsd_lineups"),
    getAllOperationalMatchDetails(),
  ]);

  const incidentsByEvent = new Map(bsdIncidents.map((doc) => [String(doc._id), doc]));
  const lineupsByEvent = new Map(bsdLineups.map((doc) => [String(doc._id), doc]));

  // Index TSDB matches by date for cheap candidate lookup.
  const tsdbRecords = (tsdbDetails && tsdbDetails.records) || {};
  const tsdbByDay = new Map();
  Object.values(tsdbRecords).forEach((match) => {
    const day = match && match.date ? String(match.date).slice(0, 10) : null;
    if (!day) return;
    if (!tsdbByDay.has(day)) tsdbByDay.set(day, []);
    tsdbByDay.get(day).push(match);
  });

  const matchedTsdb = new Set();
  const matched = [];
  const unmatchedBsd = [];

  bsdEvents.forEach((doc) => {
    const event = doc.payload || {};
    const day = utcDay(event.event_date);
    const homeBsd = event.home_team;
    const awayBsd = event.away_team;
    if (!day || !homeBsd || !awayBsd) {
      unmatchedBsd.push({ id: doc._id, reason: "missing date/teams", home: homeBsd, away: awayBsd });
      return;
    }

    let found = null;
    for (const candidateDay of adjacentDays(day)) {
      const candidates = tsdbByDay.get(candidateDay) || [];
      found = candidates.find(
        (m) =>
          teamNamesEquivalent(homeBsd, m.home_team) &&
          teamNamesEquivalent(awayBsd, m.away_team)
      );
      if (found) break;
    }

    if (!found) {
      unmatchedBsd.push({ id: doc._id, date: day, home: homeBsd, away: awayBsd });
      return;
    }

    const tsdbId = found.id || `${found.date}:${found.home_team}:${found.away_team}`;
    matchedTsdb.add(tsdbId);

    const bsdHasScores = hasNumber(event.home_score) && hasNumber(event.away_score);
    const tsdbHasScores = hasNumber(found.home_score) && hasNumber(found.away_score);
    const scoreComparable = bsdHasScores && tsdbHasScores;
    const scoreAgrees =
      scoreComparable &&
      Number(event.home_score) === Number(found.home_score) &&
      Number(event.away_score) === Number(found.away_score);

    const bsdGoals = bsdGoalCount(incidentsByEvent.get(String(doc._id)));
    const tsdbGoals = tsdbGoalCount(found);

    const bsdLineup = Boolean(
      lineupsByEvent.get(String(doc._id)) &&
        lineupsByEvent.get(String(doc._id)).payload &&
        lineupsByEvent.get(String(doc._id)).payload.lineups
    );
    const tsdbLineup = Boolean(found.team_lineups);

    matched.push({
      bsd_id: doc._id,
      tsdb_id: tsdbId,
      date: day,
      home: homeBsd,
      away: awayBsd,
      bsd_status: event.status || null,
      tsdb_status: found.score_status || null,
      bsd_score: bsdHasScores ? `${event.home_score}-${event.away_score}` : null,
      tsdb_score: tsdbHasScores ? `${found.home_score}-${found.away_score}` : null,
      score_comparable: scoreComparable,
      score_agrees: scoreAgrees,
      bsd_goals: bsdGoals,
      tsdb_goals: tsdbGoals,
      goal_count_agrees: bsdGoals === tsdbGoals,
      bsd_lineup: bsdLineup,
      tsdb_lineup: tsdbLineup,
    });
  });

  const unmatchedTsdb = Object.values(tsdbRecords)
    .filter((m) => {
      const id = m.id || `${m.date}:${m.home_team}:${m.away_team}`;
      return !matchedTsdb.has(id);
    })
    .map((m) => ({ id: m.id || null, date: m.date || null, home: m.home_team, away: m.away_team }));

  const comparableScores = matched.filter((m) => m.score_comparable);
  const scoreAgreeCount = comparableScores.filter((m) => m.score_agrees).length;
  const goalAgreeCount = comparableScores.filter((m) => m.goal_count_agrees).length;

  const summary = {
    generated_at: new Date().toISOString(),
    bsd_events_total: bsdEvents.length,
    tsdb_matches_total: Object.keys(tsdbRecords).length,
    matched: matched.length,
    unmatched_bsd: unmatchedBsd.length,
    unmatched_tsdb: unmatchedTsdb.length,
    score_comparable: comparableScores.length,
    score_agreement_pct:
      comparableScores.length > 0
        ? Math.round((scoreAgreeCount / comparableScores.length) * 1000) / 10
        : null,
    goal_count_agreement_pct:
      comparableScores.length > 0
        ? Math.round((goalAgreeCount / comparableScores.length) * 1000) / 10
        : null,
    bsd_lineup_coverage: matched.filter((m) => m.bsd_lineup).length,
    tsdb_lineup_coverage: matched.filter((m) => m.tsdb_lineup).length,
  };

  const report = { summary, matched, unmatched_bsd: unmatchedBsd, unmatched_tsdb: unmatchedTsdb };
  fs.writeFileSync(outputPath, JSON.stringify(report, null, 2));

  console.log("[bsd-compare] summary:");
  console.log(JSON.stringify(summary, null, 2));
  console.log(`[bsd-compare] full report written to ${outputPath}`);

  await closeMongoConnection();
  return report;
}

if (require.main === module) {
  const outputPath = process.argv[2] ? path.resolve(process.argv[2]) : DEFAULT_OUTPUT;
  run(outputPath).catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

module.exports = { run, utcDay, adjacentDays, bsdGoalCount, tsdbGoalCount };
