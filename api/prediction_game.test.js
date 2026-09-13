"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { mkdtempSync, readFileSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { execFileSync } = require("node:child_process");
const { createPredictionGame, registerPredictionGameRoutes, pointsFor, aiPrediction, __private: p } = require("./prediction_game");

// Small Mongo contract fake: real update operators used by the game, including
// Mongo's prohibition of $expr upserts and unique _id collision semantics.
function database(initial = {}, now = () => Date.now()) {
  const tables = new Map(Object.entries(initial).map(([name, rows]) => [name, rows.map((row) => structuredClone(row))]));
  const get = (row, key) => key.split(".").reduce((value, part) => value?.[part], row);
  function compare(actual, expected) {
    if (expected == null) return actual == null;
    if (typeof expected !== "object" || expected instanceof Date) return expected instanceof Date ? +actual === +expected : actual === expected;
    return Object.entries(expected).every(([operator, value]) => {
      if (operator === "$exists") return (actual !== undefined) === value;
      if (operator === "$in") return value.some((v) => Array.isArray(actual) ? actual.some((item) => compare(item, v)) : compare(actual, v));
      if (operator === "$ne") return !compare(actual, value);
      if (operator === "$lt") return actual < value;
      if (operator === "$lte") return actual <= value;
      if (operator === "$gt") return actual > value;
      if (operator === "$gte") return actual >= value;
      throw Error(`Unsupported test query ${operator}`);
    });
  }
  function matches(row, filter) {
    return Object.entries(filter).every(([key, value]) => {
      if (key === "$or") return value.some((clause) => matches(row, clause));
      if (key === "$expr") return now() < +value.$lt[1];
      return compare(get(row, key), value);
    });
  }
  return {
    tables,
    collection(name) {
      if (!tables.has(name)) tables.set(name, []);
      const rows = tables.get(name);
      const collection = {
        async findOne(filter) { return structuredClone(rows.find((row) => matches(row, filter)) || null); },
        find(filter = {}) {
          let found = rows.filter((row) => matches(row, filter)).map((row) => structuredClone(row));
          const cursor = {
            sort(order) { found.sort((a, b) => { for (const [key, direction] of Object.entries(order)) { if (a[key] < b[key]) return -direction; if (a[key] > b[key]) return direction; } return 0; }); return cursor; },
            limit(size) { found = found.slice(0, size); return cursor; },
            skip(size) { found = found.slice(size); return cursor; },
            batchSize() { return cursor; },
            async toArray() { return found; },
            async *[Symbol.asyncIterator]() { for (const row of found) yield row; },
          };
          return cursor;
        },
        async countDocuments(filter) { return rows.filter((row) => matches(row, filter)).length; },
        async insertOne(row) {
          if (rows.some((r) => r._id === row._id)) throw Object.assign(Error("duplicate"), { code: 11000 });
          rows.push(structuredClone(row)); return { insertedId: row._id };
        },
        async updateOne(filter, update, options = {}) {
          if (filter.$expr && options.upsert) throw Error("$expr is not allowed in the query predicate for an upsert");
          let row = rows.find((r) => matches(r, filter)); const existed = Boolean(row);
          if (!row && options.upsert) {
            row = Object.fromEntries(Object.entries(filter).filter(([, value]) => typeof value !== "object" || value === null));
            await collection.insertOne(row); row = rows.at(-1);
          }
          if (!row) return { matchedCount: 0, modifiedCount: 0, upsertedCount: 0 };
          if (!existed) Object.assign(row, structuredClone(update.$setOnInsert || {}));
          Object.assign(row, structuredClone(update.$set || {}));
          for (const [key, amount] of Object.entries(update.$inc || {})) row[key] = (row[key] || 0) + amount;
          return { matchedCount: existed ? 1 : 0, modifiedCount: existed ? 1 : 0, upsertedCount: existed ? 0 : 1 };
        },
        async updateMany(filter, update) { for (const row of rows.filter((r) => matches(r, filter))) await collection.updateOne({ _id: row._id }, update); },
        async deleteOne(filter) { const index = rows.findIndex((r) => matches(r, filter)); if (index >= 0) rows.splice(index, 1); },
      };
      return collection;
    },
  };
}

function context() {
  let clock = Date.now();
  const event = { _id: "123", league_id: 1, updated_at: new Date(clock).toISOString(), payload: {
    id: 123, league_id: 1, season_id: 203, home_team: "Arsenal", away_team: "Chelsea", event_date: new Date(clock + 86400000).toISOString(), status: "notstarted", home_score: null, away_score: null,
  } };
  const market = { event: { id: 123 }, markets: { score: { most_likely: "2-1" } }, model: { version: "v5" } };
  const player = { _id: crypto.randomUUID(), displayName: "Tester", statsDirty: true, statsRevision: 0 };
  const db = database({ bsd_events: [event], bsd_predictions: [{ _id: "1", payload: [market] }], pg_players: [player] }, () => clock);
  const game = createPredictionGame({ getDb: async () => db, now: () => clock });
  const body = { homeScore: 1, awayScore: 1, expectedAIRevision: aiPrediction(market).sourceRevision };
  return { db, game, player, market, body, event, setNow: (value) => { clock = value; } };
}

test("3/1/0 scoring treats draws and both competitors identically", () => {
  const result = { homeScore: 2, awayScore: 1 };
  assert.equal(pointsFor(result, result), 3);
  assert.equal(pointsFor({ homeScore: 3, awayScore: 0 }, result), 1);
  assert.equal(pointsFor({ homeScore: 2, awayScore: 2 }, result), 0);
  assert.equal(pointsFor({ homeScore: 0, awayScore: 0 }, { homeScore: 1, awayScore: 1 }), 1);
  assert.equal(pointsFor(null, result), null);
});

test("fixture responses expose current live scores and clear them at full time", () => {
  const base = {
    id: 123, league_id: 1, season_id: 203, home_team: "Arsenal", away_team: "Chelsea",
    event_date: "2026-09-12T14:00:00Z", status: "inprogress", period: "2nd_half",
    current_minute: 67, home_score: 2, away_score: 1,
  };
  const live = p.fixtureFromEvent({ _id: "123", payload: base });
  assert.deepEqual(live.liveScore, { homeScore: 2, awayScore: 1, status: "67" });
  assert.equal(p.fixtureResponse(live, null).result, null);

  const finished = p.fixtureFromEvent({ _id: "123", payload: { ...base, status: "finished", period: "ft", current_minute: 90 } }, live);
  assert.equal(finished.liveScore, null);
  assert.deepEqual(p.fixtureResponse(finished, null).result, { homeScore: 2, awayScore: 1 });
});

test("prediction-game fixtures resolve team identity by BSD ID", () => {
  const fixture = p.fixtureFromEvent({
    payload: {
      id: 601024,
      league_id: 7,
      season_id: 203,
      home_team_id: 57,
      home_team: "Real Madrid",
      away_team_id: 77,
      away_team: "Inter Club d'Escaldes",
      event_date: "2026-09-08T19:00:00Z",
      status: "finished",
      home_score: 2,
      away_score: 1,
    },
  });

  assert.equal(fixture.homeTeam, "Real Madrid");
  assert.equal(fixture.awayTeam, "Inter Milan");
});

test("Ten Steps Ahead records reaching the milestone even after later losses", () => {
  const entries = Array.from({ length: 5 }, (_, i) => ({ fixtureId: String(i), kickoffAt: `2026-09-1${i}T12:00:00Z`, youPoints: i < 4 ? 3 : 0, aiPoints: i < 4 ? 0 : 3 }));
  const achievement = p.buildAchievements(entries, [], []).find((a) => a.id === "tenStepsAhead");
  assert.equal(achievement.unlocked, true);
  // Correcting an earlier result can remove a milestone never actually reached.
  entries[0].youPoints = 0;
  assert.equal(p.buildAchievements(entries, [], []).find((a) => a.id === "tenStepsAhead").unlocked, false);
});

test("server AI projects BSD expected goals instead of collapsing to the modal score", () => {
  const item = { markets: { score: { most_likely: "1-1" }, expected_goals: { home: 1.96, away: 1.09 } }, model: { version: "v5" } };
  assert.deepEqual(aiPrediction(item), aiPrediction(item));
  assert.equal(aiPrediction(item).homeScore, 2);
  assert.equal(aiPrediction(item).awayScore, 1);
  assert.equal(aiPrediction(item).modelVersion, "top-scores-xg-rounded-v2:v5");
  assert.equal(aiPrediction({ markets: { expected_goals: { home: 1.2, away: 2.8 } } }).awayScore, 3);
  assert.equal(aiPrediction({ markets: { expected_goals: { home: 0, away: 0 } } }).homeScore, 0);
  assert.equal(aiPrediction({ markets: { expected_goals: { home: 0.2, away: 3.6 } } }).awayScore, 4);
  assert.notEqual(aiPrediction(item).sourceRevision, crypto.createHash("sha256").update(JSON.stringify(item)).digest("hex"), "v1 source revisions must not authorize a different v2 score");
});

test("missing or invalid goal expectations fall back to a validated BSD score as a pair", () => {
  for (const expected_goals of [undefined, {}, { home: 1.8 }, { away: 2 }, { home: null, away: 1.8 }, { home: "1.8", away: 1 }, { home: NaN, away: 1 }, { home: Infinity, away: 1 }, { home: -1, away: 1 }, { home: 21, away: 1 }]) {
    const item = { markets: { score: { most_likely: "0-2" }, expected_goals } };
    assert.equal(aiPrediction(item).homeScore, 0);
    assert.equal(aiPrediction(item).awayScore, 2);
    assert.equal(aiPrediction({ markets: { expected_goals } }), null);
  }
  assert.equal(aiPrediction({ markets: {} }), null);
  assert.equal(aiPrediction({ markets: { score: { most_likely: "30-1" } } }), null);
});

test("the reported EPL gameweek reflects BSD goal expectations without a blanket goal bonus", () => {
  // BSD Gameweek 4 snapshot read on 2026-09-09: [home xG, away xG, modal home, modal away].
  const sample = [[1.63, 1.40, 1, 1], [1.55, 1.13, 1, 1], [1.58, 1.38, 1, 1], [1.96, 1.09, 1, 1], [1.85, 1.04, 1, 1], [1.47, 1.21, 1, 1], [0.88, 1.54, 0, 1], [1.76, 1.27, 1, 1], [1.31, 1.65, 1, 1], [1.75, 1.25, 1, 1]];
  const picks = sample.map(([home, away, modalHome, modalAway]) => aiPrediction({ markets: { expected_goals: { home, away }, score: { most_likely: `${modalHome}-${modalAway}` } } }));
  const expectedTotal = sample.reduce((sum, row) => sum + row[0] + row[1], 0);
  const modalTotal = sample.reduce((sum, row) => sum + row[2] + row[3], 0);
  const projectedTotal = picks.reduce((sum, pick) => sum + pick.homeScore + pick.awayScore, 0);
  assert.equal(modalTotal, 19);
  assert.equal(projectedTotal, 29);
  assert.ok(Math.abs(projectedTotal - expectedTotal) < 1);
  assert.equal(picks.filter((pick) => pick.homeScore === 1 && pick.awayScore === 1).length, 1);
  assert.deepEqual(picks.map((pick) => `${pick.homeScore}-${pick.awayScore}`), ["2-1", "2-1", "2-1", "2-1", "2-1", "1-1", "1-2", "2-1", "1-2", "2-1"]);
});

test("all competitions project fixtures; an observed start never reopens after provider regression", () => {
  const { event } = context();
  assert.equal(p.fixtureFromEvent({ payload: { ...event.payload, league_id: 39 } }).competitionId, "39");
  const live = p.fixtureFromEvent({ payload: { ...event.payload, status: "inprogress" } });
  const regression = p.fixtureFromEvent(event, live);
  assert.equal(p.isLocked(regression), true);
  const abandoned = p.fixtureFromEvent({ payload: { ...event.payload, status: "abandoned" } });
  assert.equal(p.isLocked(p.fixtureFromEvent(event, abandoned)), true);
  assert.equal(p.fixtureFromEvent({ payload: { ...event.payload, status: "finished", home_score: null, away_score: 0 } }).result, null);
});

test("first accepted save freezes AI forever across edits and withdrawal", async () => {
  const c = context();
  const first = await c.game.save(c.db, c.player, "123", c.body);
  c.db.tables.get("bsd_predictions")[0].payload[0].markets.score.most_likely = "4-0";
  const edited = await c.game.save(c.db, c.player, "123", { homeScore: 0, awayScore: 2 });
  assert.deepEqual(edited.ai, first.ai);
  await c.game.save(c.db, c.player, "123", {}, true);
  const returned = await c.game.save(c.db, c.player, "123", { homeScore: 3, awayScore: 3 });
  assert.deepEqual(returned.ai, first.ai);
  assert.equal(c.db.tables.get("pg_entries").length, 1);
  assert.equal(c.db.tables.get("pg_entries")[0].scoringRulesVersion, 2);
});

test("first save refuses an AI revision the user has not reviewed", async () => {
  const c = context();
  await assert.rejects(c.game.save(c.db, c.player, "123", { ...c.body, expectedAIRevision: "old" }), { code: "ai_changed" });
  assert.equal(c.db.tables.get("pg_entries")?.length || 0, 0);
});

test("model upgrade preserves saved v1 opponents and requires review only for a new entry", async () => {
  const c = context();
  const item = c.db.tables.get("bsd_predictions")[0].payload[0];
  item.markets = { score: { most_likely: "1-1" }, expected_goals: { home: 1.96, away: 1.09 } };
  const oldRevision = crypto.createHash("sha256").update(JSON.stringify(item)).digest("hex");
  const oldAI = { homeScore: 1, awayScore: 1, modelVersion: "bsd-score-v1:v5", sourceRevision: oldRevision, frozenAt: new Date().toISOString() };
  await assert.rejects(c.game.save(c.db, c.player, "123", { ...c.body, expectedAIRevision: oldRevision }), { code: "ai_changed" });
  const first = await c.game.save(c.db, c.player, "123", { ...c.body, expectedAIRevision: aiPrediction(item).sourceRevision });
  assert.equal(first.ai.homeScore, 2);

  // Simulate an accepted entry persisted by v1 before the API upgrade.
  c.db.tables.get("pg_entries")[0].ai = structuredClone(oldAI);
  assert.deepEqual((await p.gameFixtureBatch(c.db, c.player._id, ["123"]))[0].ai, oldAI);
  assert.deepEqual((await c.game.save(c.db, c.player, "123", { homeScore: 2, awayScore: 2 })).ai, oldAI);
  await c.game.save(c.db, c.player, "123", {}, true);
  assert.deepEqual((await c.game.save(c.db, c.player, "123", { homeScore: 3, awayScore: 1 })).ai, oldAI);

  // A player who has never entered sees the same fresh model in the board and overlay.
  c.db.tables.get("bsd_events")[0].event_date = c.event.payload.event_date;
  const newPlayer = crypto.randomUUID();
  const overlay = (await p.gameFixtureBatch(c.db, newPlayer, ["123"]))[0];
  const board = await p.nextPredictionSet(c.db, newPlayer, null, c.game.now);
  assert.deepEqual(overlay.ai, aiPrediction(item));
  assert.deepEqual(board.fixtures[0].ai, overlay.ai);
});

test("deadline rejects late edits and database delays without freezing a failed first save", async () => {
  const c = context();
  const realCollection = c.db.collection.bind(c.db);
  c.db.collection = (name) => {
    const col = realCollection(name);
    if (name === "pg_entries") {
      const update = col.updateOne;
      col.updateOne = async (filter, fields, options) => {
        if (filter.$expr) c.setNow(Date.parse(c.event.payload.event_date));
        return update(filter, fields, options);
      };
    }
    return col;
  };
  await assert.rejects(c.game.save(c.db, c.player, "123", c.body), { code: "prediction_locked" });
  assert.equal(c.db.tables.get("pg_entries")[0].ai, undefined);
  assert.equal(c.db.tables.get("pg_entries")[0].withdrawn, true);
  await assert.rejects(c.game.save(c.db, c.player, "123", c.body), { code: "prediction_locked" });
});

test("official prestart postponement moves deadline but retains frozen opponent", async () => {
  const c = context(); const first = await c.game.save(c.db, c.player, "123", c.body);
  c.setNow(Date.parse(c.event.payload.event_date) + 1000);
  Object.assign(c.db.tables.get("bsd_events")[0].payload, { status: "postponed", event_date: new Date(Date.parse(c.event.payload.event_date) + 86400000).toISOString() });
  const changed = await c.game.save(c.db, c.player, "123", { homeScore: 2, awayScore: 2 });
  assert.deepEqual(first.ai, changed.ai);
});

test("settlement, corrected score and cancellation rebuild without counting a match twice", async () => {
  const c = context(); await c.game.save(c.db, c.player, "123", c.body);
  const doc = c.db.tables.get("bsd_events")[0];
  Object.assign(doc.payload, { status: "finished", home_score: 1, away_score: 1 });
  await c.game.sync(true);
  assert.equal(c.db.tables.get("pg_stats")[0].summary.youPoints, 3);
  assert.equal(c.db.tables.get("pg_stats")[0].summary.played, 1);
  Object.assign(doc.payload, { home_score: 2, away_score: 1 }); doc.updated_at = new Date(Date.now() + 1000).toISOString();
  await c.game.sync(true);
  assert.equal(c.db.tables.get("pg_stats")[0].summary.youPoints, 0);
  assert.equal(c.db.tables.get("pg_stats")[0].summary.aiPoints, 3);
  Object.assign(doc.payload, { status: "cancelled" }); doc.updated_at = new Date(Date.now() + 2000).toISOString();
  await c.game.sync(true);
  assert.equal(c.db.tables.get("pg_stats")[0].summary.played, 0);
});

test("weekly selection is capped, deterministic and immutable even if fixtures move", async () => {
  const c = context(); const friday = "2030-09-06T12:00:00Z";
  c.db.tables.set("pg_fixtures", Array.from({ length: 12 }, (_, index) => ({ _id: String(index), kickoffAt: new Date(Date.parse(friday) + index * 3600000).toISOString(), status: "notstarted", seasonId: "2030", ai: aiPrediction(c.market), void: false, started: false, challengeId: null })));
  await p.publishChallenges(c.db, Date.parse(friday) - 86400000);
  const first = structuredClone(c.db.tables.get("pg_challenges")[0]);
  assert.equal(first.fixtureIds.length, 10);
  c.db.tables.get("pg_fixtures")[0].kickoffAt = "2030-09-10T12:00:00Z";
  await p.publishChallenges(c.db, Date.parse(friday) - 86400000);
  assert.deepEqual(c.db.tables.get("pg_challenges")[0].fixtureIds, first.fixtureIds);
  assert.equal(p.weekId("2026-10-25T00:30:00Z"), "epl-2026-10-23");
});

test("a postponed challenge match never scores in a second week's challenge", async () => {
  const c = context(); const friday = "2030-09-06T12:00:00Z";
  c.db.tables.set("pg_fixtures", [
    { _id: "1", kickoffAt: friday, status: "notstarted", seasonId: "2030", ai: aiPrediction(c.market), void: false, started: false, challengeId: null },
  ]);
  await p.publishChallenges(c.db, Date.parse(friday) - 86400000);
  c.db.tables.get("pg_fixtures")[0].kickoffAt = "2030-09-13T12:00:00Z";
  c.db.tables.get("pg_fixtures").push({ _id: "2", kickoffAt: "2030-09-13T13:00:00Z", status: "notstarted", seasonId: "2030", ai: aiPrediction(c.market), void: false, started: false, challengeId: null });
  await p.publishChallenges(c.db, Date.parse(friday) - 86400000);
  assert.deepEqual(c.db.tables.get("pg_challenges")[1].fixtureIds, ["2"]);
  assert.deepEqual(c.db.tables.get("pg_challenges")[0].fixtureIds, ["1"]);
});

test("published membership survives missing caches and fences concurrent fixture/entry writers", async () => {
  const c = context(); const firstWeek = "epl-2030-09-06";
  const kickoff = "2030-09-13T12:00:00Z";
  c.db.tables.set("pg_challenges", [{ _id: firstWeek, fixtureIds: ["1"], seasonId: "2030" }]);
  c.db.tables.set("pg_fixtures", [{ _id: "1", kickoffAt: kickoff, status: "notstarted", seasonId: "2030", ai: aiPrediction(c.market), void: false, started: false, challengeId: null, version: 4 }]);
  c.db.tables.set("pg_entries", [{ _id: "entry", fixtureId: "1", challengeId: null, version: 7 }]);
  await p.publishChallenges(c.db, Date.parse(kickoff) - 86400000);
  assert.equal(c.db.tables.get("pg_challenges").length, 1);
  assert.equal(c.db.tables.get("pg_fixtures")[0].challengeId, firstWeek);
  assert.equal(c.db.tables.get("pg_fixtures")[0].version, 5);
  assert.equal(c.db.tables.get("pg_entries")[0].challengeId, firstWeek);
  assert.equal(c.db.tables.get("pg_entries")[0].version, 8);
  assert.equal(c.db.tables.get("pg_entries")[0].statsPending, true);
});

test("dirty statistics remain recoverable after a crash during their rebuild", async () => {
  const c = context(); await c.game.save(c.db, c.player, "123", c.body);
  Object.assign(c.db.tables.get("bsd_events")[0].payload, { status: "finished", home_score: 1, away_score: 1 });
  const original = c.db.collection.bind(c.db); let fail = true;
  c.db.collection = (name) => {
    const col = original(name);
    if (name === "pg_stats") { const update = col.updateOne; col.updateOne = (...args) => { if (fail) { fail = false; throw Error("simulated process failure"); } return update(...args); }; }
    return col;
  };
  await assert.rejects(c.game.sync(true), /simulated process failure/);
  assert.equal(c.db.tables.get("pg_players")[0].statsDirty, true);
  const restarted = createPredictionGame({ getDb: async () => c.db });
  await restarted.sync(true);
  assert.equal(c.db.tables.get("pg_stats")[0].summary.youPoints, 3);
  assert.equal(c.db.tables.get("pg_players")[0].statsDirty, false);
});

test("a score write interrupted before dirty marking is discovered on restart", async () => {
  const c = context(); await c.game.save(c.db, c.player, "123", c.body);
  Object.assign(c.db.tables.get("bsd_events")[0].payload, { status: "finished", home_score: 1, away_score: 1 });
  const fixture = await p.persistFixture(c.db, c.db.tables.get("bsd_events")[0], null);
  const entry = c.db.tables.get("pg_entries")[0];
  assert.equal(entry.statsPending, true);
  assert.equal(entry.resultRevision, fixture.resultRevision);
  c.db.tables.get("pg_players")[0].statsDirty = false;
  await createPredictionGame({ getDb: async () => c.db }).sync(true);
  assert.equal(c.db.tables.get("pg_stats")[0].summary.youPoints, 3);
  assert.equal(entry.statsPending, false);
});

test("a stale rebuild cannot overwrite a newer statistics revision", async () => {
  const c = context(); await c.game.save(c.db, c.player, "123", c.body);
  const entry = c.db.tables.get("pg_entries")[0]; Object.assign(entry, { youPoints: 1, aiPoints: 0, statsPending: false });
  const original = c.db.collection.bind(c.db); let pause = true; let release; let paused;
  const gate = new Promise((resolve) => { release = resolve; }); const reached = new Promise((resolve) => { paused = resolve; });
  c.db.collection = (name) => {
    const col = original(name);
    if (name === "pg_entries") { const find = col.find; col.find = (...args) => {
      const cursor = find(...args); const array = cursor.toArray;
      cursor.toArray = async () => { const rows = await array(); if (pause) { pause = false; paused(); await gate; } return rows; }; return cursor;
    }; }
    return col;
  };
  const stale = p.rebuildPlayer(c.db, c.player._id); await reached;
  entry.youPoints = 3; c.db.tables.get("pg_players")[0].statsRevision += 1;
  await p.rebuildPlayer(c.db, c.player._id); release(); await stale;
  assert.equal(c.db.tables.get("pg_stats")[0].summary.youPoints, 3);
  assert.equal(c.db.tables.get("pg_stats")[0].revision, c.db.tables.get("pg_players")[0].statsRevision);
});

test("an expired fixture lease is fenced before the holder can write", async () => {
  const c = context();
  await assert.rejects(p.withFixtureLock(c.db, "123", async (renew) => {
    c.db.tables.get("pg_locks")[0].token = "new-holder";
    await renew();
    assert.fail("must not reach a mutation after losing ownership");
  }), { code: "fixture_busy" });
  assert.equal(c.db.tables.get("pg_locks")[0].token, "new-holder");
});

test("a busy historical correction remains eligible for the next source refresh", async () => {
  const c = context(); await c.game.save(c.db, c.player, "123", c.body);
  const doc = c.db.tables.get("bsd_events")[0];
  Object.assign(doc.payload, { status: "finished", home_score: 1, away_score: 1 });
  await c.game.sync(true);
  const correctionTime = new Date(Date.now() + 1).toISOString();
  Object.assign(doc.payload, { home_score: 2, away_score: 1 }); doc.updated_at = correctionTime;
  await c.db.collection("pg_locks").insertOne({ _id: "123", token: "other", expiresAt: new Date(Date.now() + 15000) });
  await c.game.sync(true);
  await c.db.collection("pg_locks").deleteOne({ _id: "123" });
  await c.game.sync(true);
  assert.equal(c.db.tables.get("pg_stats")[0].summary.aiPoints, 3);
});

test("a settlement version conflict retries a finished fixture instead of advancing past it", async () => {
  const c = context(); await c.game.save(c.db, c.player, "123", c.body);
  c.setNow(Date.parse(c.event.payload.event_date) + 1000);
  const doc = c.db.tables.get("bsd_events")[0];
  Object.assign(doc.payload, { status: "finished", home_score: 1, away_score: 1 });
  const original = c.db.collection.bind(c.db); let conflict = true;
  c.db.collection = (name) => {
    const col = original(name);
    if (name === "pg_entries") {
      const update = col.updateOne;
      col.updateOne = (filter, fields, options) => {
        if (conflict && fields.$set?.settledAt) { conflict = false; c.db.tables.get("pg_entries")[0].version += 1; }
        return update(filter, fields, options);
      };
    }
    return col;
  };
  await c.game.sync(true);
  assert.equal(c.db.tables.get("pg_entries")[0].youPoints, null);
  await c.game.sync(true);
  assert.equal(c.db.tables.get("pg_entries")[0].youPoints, 3);
  assert.equal(c.db.tables.get("pg_stats")[0].summary.youPoints, 3);
});

function predictionSetContext() {
  const c = context(); const now = Date.parse("2030-08-01T12:00:00Z"); c.setNow(now);
  c.db.tables.set("bsd_events", []);
  c.db.tables.get("bsd_predictions")[0].payload = [];
  function add(id, date, round = 1, extras = {}) {
    const payload = { ...c.event.payload, id, event_date: date, round_number: round, ...extras };
    const doc = { _id: String(id), payload, league_id: payload.league_id, status: payload.status, event_date: payload.event_date };
    c.db.tables.get("bsd_events").push(doc);
    const market = { ...c.market, event: { id } };
    c.db.tables.get("bsd_predictions")[0].payload.push(market);
    return doc;
  }
  return { ...c, now, add };
}

test("next predictions include saved and unentered fixtures beyond visible dates in one BSD gameweek", async () => {
  const c = predictionSetContext();
  c.add(101, "2030-09-02T12:00:00Z", 1);
  c.add(102, "2030-09-20T12:00:00Z", 1); // Same round, postponed beyond a calendar week.
  c.add(103, "2030-09-03T12:00:00Z", 2);
  c.add(104, "2030-09-02T12:30:00Z", 1, { season_id: 204 });
  const frozen = { ...aiPrediction(c.market), frozenAt: "2030-07-01T12:00:00Z" };
  c.db.tables.set("pg_entries", [{ _id: "entry", playerId: c.player._id, fixtureId: "101", homeScore: 3, awayScore: 1, ai: frozen, withdrawn: false, updatedAt: "2030-07-01T12:00:00Z" }]);
  const result = await p.nextPredictionSet(c.db, c.player._id, null, c.now);
  assert.equal(result.gameweekId, "203:round:1");
  assert.equal(result.gameweekLabel, "Gameweek 1");
  assert.deepEqual(result.fixtures.map((f) => f.id), ["101", "102"]);
  assert.equal(result.fixtures[0].prediction.homeScore, 3);
  assert.deepEqual(result.fixtures[0].ai, frozen);
  assert.equal(result.fixtures[1].prediction, null);
  assert.equal(result.serverTime, new Date(c.now).toISOString());
  const otherRound = await p.nextPredictionSet(c.db, c.player._id, "103", c.now);
  assert.deepEqual(otherRound.fixtures.map((f) => f.id), ["103"]);
});

test("next predictions use fresh eligibility and default to EPL without a context", async () => {
  const c = predictionSetContext();
  c.add(101, "2030-08-01T12:00:00Z"); // At the exact server deadline.
  c.add(102, "2030-09-02T12:00:00Z", 1, { status: "inprogress" });
  c.add(103, "2030-09-02T12:00:00Z", 1, { status: "cancelled" });
  c.add(104, "2030-09-02T12:00:00Z", 1, { league_id: 39 });
  c.add(105, "2030-09-02T12:00:00Z");
  c.db.tables.get("bsd_predictions")[0].payload = c.db.tables.get("bsd_predictions")[0].payload.filter((m) => m.event.id !== 105);
  c.add(106, "2030-09-02T12:00:00Z");
  c.db.tables.set("pg_fixtures", [{ _id: "106", started: true }]); // Previously observed play cannot regress.
  assert.deepEqual(await p.nextPredictionSet(c.db, c.player._id, null, c.now), { serverTime: new Date(c.now).toISOString(), gameweekId: null, gameweekLabel: null, fixtures: [], competitionId: "1", competitionName: "Premier League" });
  await assert.rejects(p.nextPredictionSet(c.db, c.player._id, "104", c.now, false, "1"), { code: "fixture_not_found" });
  await assert.rejects(p.nextPredictionSet(c.db, c.player._id, "unknown", c.now), { code: "fixture_not_found" });
});

test("next predictions stay in context when a gameweek completes and isolate missing-round calendar fallback", async () => {
  const c = predictionSetContext();
  c.add(101, "2030-07-01T12:00:00Z", 1, { status: "finished", home_score: 1, away_score: 1 });
  c.add(102, "2030-09-06T12:00:00Z", null);
  c.add(103, "2030-09-12T12:00:00Z", null);
  c.add(104, "2030-09-13T12:00:00Z", null);
  const complete = await p.nextPredictionSet(c.db, c.player._id, "101", c.now);
  assert.equal(complete.gameweekId, "203:round:1");
  assert.deepEqual(complete.fixtures, []);
  const fallback = await p.nextPredictionSet(c.db, c.player._id, "102", c.now);
  assert.equal(fallback.gameweekId, "203:week:epl-2030-09-06");
  assert.deepEqual(fallback.fixtures.map((f) => f.id), ["102", "103"]);
});

test("whole-gameweek boards include finished and unavailable-AI matches without changing default eligibility", async () => {
  const c = predictionSetContext();
  c.add(101, "2030-09-02T12:00:00Z", 1);
  c.add(102, "2030-07-30T12:00:00Z", 1, { status: "finished", home_score: 1, away_score: 1 });
  c.add(103, "2030-09-03T12:00:00Z", 1);
  c.add(104, "2030-09-04T12:00:00Z", 2);
  c.db.tables.get("bsd_predictions")[0].payload = c.db.tables.get("bsd_predictions")[0].payload.filter((p) => p.event.id !== 103);
  const normal = await p.nextPredictionSet(c.db, c.player._id, null, c.now);
  assert.deepEqual(normal.fixtures.map((f) => f.id), ["101"]);
  const board = await p.nextPredictionSet(c.db, c.player._id, null, c.now, true);
  assert.deepEqual(board.fixtures.map((f) => f.id), ["102", "101", "103"]);
  assert.equal(board.fixtures[0].settled, true);
  assert.equal(board.fixtures[0].locked, true);
  assert.equal(board.fixtures[2].ai, null);
});

test("recent gameweeks aggregate beyond a history page and count unfinished participation accurately", async () => {
  const c = predictionSetContext(); const fixtures = []; const entries = [];
  for (let round = 1; round <= 6; round += 1) {
    for (let match = 0; match < 10; match += 1) {
      const id = String(round * 100 + match);
      const kickoff = new Date(Date.parse("2030-08-01T12:00:00Z") + round * 7 * 86400000 + match * 3600000).toISOString();
      const doc = c.add(Number(id), kickoff, round, { status: round === 6 ? "notstarted" : "finished", home_score: round === 6 ? null : 1, away_score: round === 6 ? null : 1 });
      fixtures.push(p.fixtureFromEvent(doc));
      if (round !== 6 || match < 8) entries.push({ _id: id, playerId: c.player._id, fixtureId: id, seasonId: "203", withdrawn: false, homeScore: 1, awayScore: 1, ai: aiPrediction(c.market) });
    }
  }
  c.db.tables.set("pg_fixtures", fixtures); c.db.tables.set("pg_entries", entries);
  assert.equal(entries.length, 58);
  const recent = await p.recentGameweeks(c.db, c.player._id);
  assert.deepEqual(recent.map((w) => w.id), [6, 5, 4, 3, 2].map((r) => `203:round:${r}`));
  assert.deepEqual([recent[0].predicted, recent[0].played, recent[0].totalMatches, recent[0].completed], [8, 0, 10, false]);
  assert.deepEqual([recent[1].youPoints, recent[1].aiPoints, recent[1].played, recent[1].completed], [30, 0, 10, true]);
  assert.deepEqual(await p.recentGameweeks(c.db, c.player._id, "different-season"), []);
});

function routeHarness(c) {
  const routes = new Map();
  const app = Object.fromEntries(["get", "post", "put", "patch", "delete"].map((method) => [method, (path, handler) => routes.set(`${method} ${path}`, handler)]));
  const game = registerPredictionGameRoutes(app, { getDb: async () => c.db, now: c.game.now, disableWorker: true, disableRateLimits: true });
  const response = () => ({ statusCode: 200, set() { return this; }, status(value) { this.statusCode = value; return this; }, json(value) { this.body = value; } });
  return { routes, game, response };
}

test("cold editor request reads only requested fixture IDs without game imports or writes", async () => {
  const c = context(); const credential = await p.issueSession(c.db, c.player._id);
  const original = c.db.collection.bind(c.db); const sourceQueries = [];
  c.db.collection = (name) => {
    const collection = original(name);
    if (name === "bsd_events") {
      const find = collection.find;
      collection.find = (filter, ...args) => { sourceQueries.push(filter); assert.deepEqual(filter, { _id: { $in: ["123"] } }); return find(filter, ...args); };
    }
    for (const method of ["insertOne", "updateOne", "updateMany", "deleteOne"]) collection[method] = () => { assert.fail(`Interactive fixture read attempted ${name}.${method}`); };
    return collection;
  };
  const { routes, response } = routeHarness(c); const res = response();
  await routes.get("get /api/v1/prediction-game/fixtures")({ query: { ids: "123" }, headers: { authorization: `Bearer ${credential}` } }, res);
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.fixtures[0].id, "123");
  assert.equal(res.body.fixtures[0].ai.homeScore, 2);
  assert.equal(c.db.tables.get("pg_fixtures").length, 0);
  assert.equal(sourceQueries.length, 1);
});

test("editor batch preserves frozen AI and permanent locks while reading fresh BSD status", async () => {
  const c = context(); const first = await c.game.save(c.db, c.player, "123", c.body);
  c.db.tables.get("bsd_predictions")[0].payload[0].markets.score.most_likely = "4-0";
  c.db.tables.get("bsd_events")[0].payload.status = "inprogress";
  const live = await p.gameFixtureBatch(c.db, c.player._id, ["123"]);
  assert.deepEqual(live[0].ai, first.ai);
  assert.equal(live[0].prediction.homeScore, 1);
  assert.equal(live[0].locked, true);
  c.db.tables.get("pg_fixtures")[0].started = true;
  c.db.tables.get("bsd_events")[0].payload.status = "notstarted";
  assert.equal((await p.gameFixtureBatch(c.db, c.player._id, ["123"]))[0].locked, true);
});

test("editor and next-match responses use current server time after delayed reads", async () => {
  const c = context(); const credential = await p.issueSession(c.db, c.player._id);
  c.db.tables.get("bsd_events")[0].event_date = c.event.payload.event_date;
  const deadline = Date.parse(c.event.payload.event_date); const original = c.db.collection.bind(c.db);
  c.db.collection = (name) => {
    const collection = original(name);
    if (name === "pg_entries") {
      const find = collection.find;
      collection.find = (...args) => { c.setNow(deadline + 1000); return find(...args); };
    }
    return collection;
  };
  const { routes, response } = routeHarness(c); const res = response();
  await routes.get("get /api/v1/prediction-game/fixtures")({ query: { ids: "123" }, headers: { authorization: `Bearer ${credential}` } }, res);
  assert.equal(res.body.serverTime, new Date(deadline + 1000).toISOString());
  assert.equal(res.body.fixtures[0].locked, true);
  c.setNow(deadline - 1000);
  const next = await p.nextPredictionSet(c.db, c.player._id, null, c.game.now);
  assert.equal(next.serverTime, new Date(deadline + 1000).toISOString());
  assert.deepEqual(next.fixtures, []);
});

test("activation and editor responses finish while the initial historical worker is stalled", async () => {
  const c = context(); const credential = await p.issueSession(c.db, c.player._id);
  c.db.tables.get("bsd_events")[0].event_date = c.event.payload.event_date;
  const original = c.db.collection.bind(c.db); let releaseWorker; let workerStarted;
  const gate = new Promise((resolve) => { releaseWorker = resolve; });
  const started = new Promise((resolve) => { workerStarted = resolve; });
  c.db.collection = (name) => {
    const collection = original(name);
    if (name === "bsd_events") {
      const find = collection.find;
      collection.find = (filter, ...args) => {
        const cursor = find(filter, ...args);
        if (filter._id && !filter.league_id && !filter.event_date && !filter.$or) {
          cursor[Symbol.asyncIterator] = async function* () { workerStarted(); await gate; };
        }
        return cursor;
      };
    }
    return collection;
  };
  const { routes, game, response } = routeHarness(c);
  const worker = game.sync(true); await started;
  const state = response(); const fixture = response(); let stateFinished = false; let fixtureFinished = false;
  const headers = { authorization: `Bearer ${credential}` };
  const stateRequest = routes.get("get /api/v1/prediction-game/state")({ headers, query: {} }, state).then(() => { stateFinished = true; });
  const fixtureRequest = routes.get("get /api/v1/prediction-game/fixtures")({ headers, query: { ids: "123" } }, fixture).then(() => { fixtureFinished = true; });
  try {
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(stateFinished, true, "activation must not join the historical import");
    assert.equal(fixtureFinished, true, "editor must not join the historical import");
    assert.equal(state.statusCode, 200);
    assert.equal(state.body.fixtures[0].id, "123");
    assert.equal(state.body.summary.played, 0);
    assert.equal(fixture.body.fixtures[0].ai.homeScore, 2);
  } finally { releaseWorker(); await Promise.all([worker, stateRequest, fixtureRequest]); }
});

test("new guest statistics avoid all historical challenge scans and zero-score leaderboard writes", async () => {
  const c = context();
  c.db.tables.set("pg_challenges", Array.from({ length: 1000 }, (_, index) => ({ _id: `archive-${index}`, fixtureIds: [String(index)] })));
  const original = c.db.collection.bind(c.db);
  c.db.collection = (name) => {
    assert.notEqual(name, "pg_challenges", "new guests need no historical challenges");
    assert.notEqual(name, "pg_leaderboards", "new guests need no historical leaderboard writes");
    return original(name);
  };
  const result = await p.rebuildPlayer(c.db, c.player._id);
  assert.equal(result.summary.played, 0);
  assert.deepEqual(result.ranks, []);
  assert.deepEqual(result.seasons, []);
});

test("guest secrets are hashed and another credential cannot read the player's game", async () => {
  const c = context(); const credential = await p.issueSession(c.db, c.player._id);
  assert.equal((await p.authenticateCredential(c.db, `Bearer ${credential}`))._id, c.player._id);
  assert.equal(JSON.stringify(c.db.tables.get("pg_sessions")).includes(credential.split(".")[1]), false);
  await assert.rejects(p.authenticateCredential(c.db, `Bearer ${credential.slice(0, -1)}x`), { code: "unauthorized" });
});

test("Game Center rejects SSRF URLs and stale proofs before any network access", async () => {
  for (const url of ["http://static.gc.apple.com/public-key/key.cer", "https://static.gc.apple.com.evil.test/public-key/key.cer", "https://user@static.gc.apple.com/public-key/key.cer", "https://127.0.0.1/public-key/key.cer", "https://static.gc.apple.com/public-key/key.cer?redirect=x"]) assert.equal(p.gameCenterKeyUrl(url), null);
  let requests = 0;
  await assert.rejects(p.verifyGameCenter({ timestamp: 0 }, { bundleId: "test.app", fetch: () => { requests += 1; } }), { code: "invalid_identity" });
  assert.equal(requests, 0);
});

test("Game Center verifies signed team identity, expected bundle and salt; game player metadata is not trusted", async () => {
  const dir = mkdtempSync(join(tmpdir(), "prediction-game-cert-"));
  try {
    const keyPath = join(dir, "key.pem"); const certPath = join(dir, "cert.pem");
    execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", keyPath, "-out", certPath, "-days", "1", "-subj", "/CN=Test Game Center"], { stdio: "ignore" });
    const timestamp = Date.now(); const salt = crypto.randomBytes(32); const time = Buffer.alloc(8); time.writeBigUInt64BE(BigInt(timestamp));
    const signature = crypto.sign("RSA-SHA256", Buffer.concat([Buffer.from("team-player"), Buffer.from("test.app"), time, salt]), readFileSync(keyPath));
    const body = { teamPlayerId: "team-player", gamePlayerId: "untrusted", timestamp, salt: salt.toString("base64"), signature: signature.toString("base64"), publicKeyUrl: "https://static.gc.apple.com/public-key/test-key.cer" };
    const options = { bundleId: "test.app", fetch: async (_url, init) => { assert.equal(init.redirect, "error"); return { ok: true, arrayBuffer: async () => readFileSync(certPath), headers: new Headers() }; } };
    const verified = await p.verifyGameCenter(body, options);
    assert.equal(verified.subject, (await p.verifyGameCenter({ ...body, gamePlayerId: "other" }, options)).subject);
    await assert.rejects(p.verifyGameCenter({ ...body, teamPlayerId: "other" }, options), { code: "invalid_identity" });
    await assert.rejects(p.verifyGameCenter(body, { ...options, bundleId: "other.app" }), { code: "invalid_identity" });
    const previousBundle = process.env.PREDICTION_GAME_BUNDLE_ID;
    try {
      delete process.env.PREDICTION_GAME_BUNDLE_ID;
      const appSignature = crypto.sign("RSA-SHA256", Buffer.concat([Buffer.from("team-player"), Buffer.from("topscores.dev.skynolimit"), time, salt]), readFileSync(keyPath));
      const appBody = { ...body, signature: appSignature.toString("base64") };
      const defaultOptions = { fetch: options.fetch };
      assert.equal((await p.verifyGameCenter(appBody, defaultOptions)).subject, (await p.verifyGameCenter(appBody, { ...options, bundleId: "topscores.dev.skynolimit" })).subject);
      await assert.rejects(p.verifyGameCenter(body, defaultOptions), { code: "invalid_identity" });
      process.env.PREDICTION_GAME_BUNDLE_ID = "test.app";
      assert.equal((await p.verifyGameCenter(body, defaultOptions)).subject, verified.subject);
      await assert.rejects(p.verifyGameCenter(appBody, defaultOptions), { code: "invalid_identity" });
    } finally {
      if (previousBundle === undefined) delete process.env.PREDICTION_GAME_BUNDLE_ID;
      else process.env.PREDICTION_GAME_BUNDLE_ID = previousBundle;
    }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("HTTP contract can create a guest and fetch batches without starting a server", async () => {
  const c = context(); const routes = new Map();
  const app = Object.fromEntries(["get", "post", "put", "patch", "delete"].map((method) => [method, (path, handler) => routes.set(`${method} ${path}`, handler)]));
  registerPredictionGameRoutes(app, { getDb: async () => c.db, disableWorker: true, disableRateLimits: true });
  function response() { return { statusCode: 200, set() { return this; }, status(value) { this.statusCode = value; return this; }, json(value) { this.body = value; } }; }
  const created = response();
  await routes.get("post /api/v1/prediction-game/players")({ body: {}, headers: {} }, created);
  assert.equal(created.statusCode, 201);
  const batch = response();
  await routes.get("get /api/v1/prediction-game/fixtures")({ query: { ids: "123,bsd:123" }, headers: { authorization: `Bearer ${created.body.credential}` } }, batch);
  assert.equal(batch.body.fixtures.length, 1);
  assert.equal(batch.body.fixtures[0].id, "123");
  const unauthorized = response();
  await routes.get("get /api/v1/prediction-game/next-predictions")({ query: {}, headers: {} }, unauthorized);
  assert.equal(unauthorized.statusCode, 401);
});


function multiCompetitionContext() {
  const c = predictionSetContext();
  c.setNow(Date.parse("2030-09-05T12:00:00Z"));
  c.db.tables.set("bsd_predictions", [{ _id: "1", payload: [] }, { _id: "7", payload: [] }]);
  c.db.tables.set("bsd_leagues", [{ _id: "1", payload: { name: "Premier League" } }, { _id: "7", payload: { name: "Champions League" } }]);
  function add(id, league, date = "2030-09-06T12:00:00Z", extra = {}) {
    const payload = { ...c.event.payload, id, league_id: league, league_name: league === 1 ? "Premier League" : "Champions League", event_date: date, round_number: 4, ...extra };
    const doc = { _id: String(id), league_id: league, event_date: date, status: payload.status, updated_at: new Date().toISOString(), payload };
    c.db.tables.get("bsd_events").push(doc);
    const market = { ...c.market, event: { id, league_id: league } };
    c.db.tables.get("bsd_predictions").find((row) => row._id === String(league)).payload.push(market);
    return doc;
  }
  return { ...c, add };
}

async function httpRequest(harness, credential, path, query = {}, body) {
  const response = harness.response();
  await harness.routes.get(`get /api/v1/prediction-game/${path}`)({ headers: { authorization: `Bearer ${credential}` }, query, body }, response);
  return response;
}

test("in-play round totals completed and live predicted matches using the same scoring rules", async () => {
  const c = multiCompetitionContext();
  const finished = c.add(101, 1, "2030-09-06T12:00:00Z");
  const live = c.add(102, 1, "2030-09-06T14:00:00Z");
  await c.game.sync(true);
  const predictionDoc = c.db.tables.get("bsd_predictions").find((row) => row._id === "1");
  await c.game.save(c.db, c.player, "101", {
    homeScore: 1, awayScore: 1,
    expectedAIRevision: aiPrediction(predictionDoc.payload.find((item) => item.event.id === 101)).sourceRevision,
  });
  await c.game.save(c.db, c.player, "102", {
    homeScore: 2, awayScore: 0,
    expectedAIRevision: aiPrediction(predictionDoc.payload.find((item) => item.event.id === 102)).sourceRevision,
  });
  Object.assign(finished.payload, { status: "finished", period: "ft", current_minute: 90, home_score: 1, away_score: 1 });
  Object.assign(live.payload, { status: "inprogress", period: "2nd_half", current_minute: 67, home_score: 2, away_score: 0 });
  c.setNow(Date.parse(live.payload.event_date) + 60 * 60 * 1000);
  await c.game.sync(true);

  const round = await p.inPlayGameweek(c.db, c.player._id, "1", c.game.now);
  assert.equal(round.label, "Gameweek 4");
  assert.equal(round.youPoints, 6);
  assert.equal(round.aiPoints, 1);
  assert.equal(round.scoredMatches, 2);
  assert.equal(round.liveMatches, 1);
  assert.equal(round.totalMatches, 2);
});

test("mixed fixture batches read only the involved prediction competitions and save non-EPL entries", async () => {
  const c = multiCompetitionContext(); c.add(101, 1); c.add(201, 7);
  const unrelated = { _id: "99", payload: [] }; c.db.tables.get("bsd_predictions").push(unrelated);
  const original = c.db.collection.bind(c.db); const predictionQueries = [];
  c.db.collection = (name) => {
    const collection = original(name);
    if (name === "bsd_predictions") {
      const find = collection.find;
      collection.find = (filter) => { predictionQueries.push(filter); return find(filter); };
    }
    return collection;
  };
  const fixtures = await p.gameFixtureBatch(c.db, c.player._id, ["101", "201"]);
  assert.deepEqual(fixtures.map((f) => f.competitionId), ["1", "7"]);
  assert.deepEqual(predictionQueries, [{ _id: { $in: ["1", "7"] } }]);
  const saved = await c.game.save(c.db, c.player, "201", { homeScore: 3, awayScore: 2, expectedAIRevision: fixtures[1].ai.sourceRevision });
  assert.equal(saved.competitionName, "Champions League");
  assert.equal(c.db.tables.get("pg_entries")[0].competitionId, "7");
  const frozen = structuredClone(saved.ai);
  c.db.tables.get("bsd_predictions").find((doc) => doc._id === "7").payload = [];
  assert.deepEqual((await c.game.save(c.db, c.player, "201", { homeScore: 1, awayScore: 0 })).ai, frozen);
});

test("gameweeks and contextual navigation isolate equal season and round IDs between competitions", async () => {
  const c = multiCompetitionContext(); c.add(101, 1); c.add(201, 7); c.add(202, 7, "2030-09-07T12:00:00Z");
  const epl = await p.nextPredictionSet(c.db, c.player._id, null, c.game.now, true, "1");
  const champions = await p.nextPredictionSet(c.db, c.player._id, null, c.game.now, true, "7");
  assert.deepEqual(epl.fixtures.map((f) => f.id), ["101"]);
  assert.deepEqual(champions.fixtures.map((f) => f.id), ["201", "202"]);
  assert.equal(epl.gameweekId, "203:round:4");
  assert.equal(champions.gameweekId, "competition:7:203:round:4");
  assert.equal(champions.competitionName, "Champions League");
  assert.deepEqual((await p.nextPredictionSet(c.db, c.player._id, "201", c.game.now)).fixtures.map((f) => f.id), ["201", "202"]);
  await assert.rejects(p.nextPredictionSet(c.db, c.player._id, "201", c.game.now, false, "1"), { code: "fixture_not_found" });
});

test("weekly challenges independently cap AI-backed fixtures per competition and exclude unavailable opponents", async () => {
  const c = multiCompetitionContext();
  for (const league of [1, 7]) for (let i = 0; i < 12; i += 1) c.add(league * 100 + i, league, new Date(Date.parse("2030-09-06T12:00:00Z") + i * 3600000).toISOString());
  c.add(899, 7);
  c.db.tables.get("bsd_predictions").find((doc) => doc._id === "7").payload = c.db.tables.get("bsd_predictions").find((doc) => doc._id === "7").payload.filter((item) => item.event.id !== 899);
  await c.game.sync(true);
  const challenges = c.db.tables.get("pg_challenges");
  assert.equal(challenges.length, 2);
  for (const challenge of challenges) {
    assert.equal(challenge.fixtureIds.length, 10);
    assert.ok(challenge.fixtureIds.every((id) => Math.floor(Number(id) / 100) === Number(challenge.competitionId)));
    assert.ok(!challenge.fixtureIds.includes("899"));
  }
  assert.equal(c.db.tables.get("pg_fixtures").some((f) => f._id === "899"), false, "a cold worker does not import matches with no AI");
});

test("one friend playing an extra competition cannot change either friend's EPL ranks, record or history", async () => {
  const c = multiCompetitionContext();
  const epl = c.add(101, 1); const champions = c.add(201, 7, "2030-09-08T12:00:00Z");
  const friend = { _id: crypto.randomUUID(), displayName: "EPL Friend", gameCenterSubject: "friend", statsDirty: true, statsRevision: 0 };
  c.db.tables.get("pg_players")[0].gameCenterSubject = "multileague-player";
  await c.db.collection("pg_players").insertOne(friend);
  const credential = await p.issueSession(c.db, c.player._id);
  const harness = routeHarness(c); await harness.game.sync(true);
  await harness.game.save(c.db, c.player, "101", { ...c.body, expectedAIRevision: aiPrediction(c.db.tables.get("bsd_predictions")[0].payload[0]).sourceRevision });
  await harness.game.save(c.db, friend, "101", { ...c.body, homeScore: 0, awayScore: 0, expectedAIRevision: aiPrediction(c.db.tables.get("bsd_predictions")[0].payload[0]).sourceRevision });
  const frozen = structuredClone(c.db.tables.get("pg_entries").find((e) => e.playerId === c.player._id).ai);
  Object.assign(epl.payload, { status: "finished", home_score: 1, away_score: 1 });
  c.setNow(Date.parse(epl.payload.event_date) + 1000); await harness.game.sync(true);
  const eplChallenge = c.db.tables.get("pg_challenges").find((row) => row.competitionId === "1");
  const before = {};
  for (const category of ["weekly", "season", "perfect"]) before[category] = (await httpRequest(harness, credential, "leaderboards", { competitionId: "1", category, challengeId: eplChallenge._id, seasonId: "203" })).body.rows;
  assert.deepEqual(before.season.map((r) => r.points), [3, 1]);
  await harness.game.save(c.db, c.player, "201", { ...c.body, homeScore: 2, awayScore: 1, expectedAIRevision: aiPrediction(c.db.tables.get("bsd_predictions")[1].payload[0]).sourceRevision });
  Object.assign(champions.payload, { status: "finished", home_score: 2, away_score: 1 });
  c.setNow(Date.parse(champions.payload.event_date) + 1000); await harness.game.sync(true);
  for (const category of ["weekly", "season", "perfect"]) assert.deepEqual((await httpRequest(harness, credential, "leaderboards", { competitionId: "1", category, challengeId: eplChallenge._id, seasonId: "203" })).body.rows, before[category]);
  const record = (await httpRequest(harness, credential, "stats", { competitionId: "1", seasonId: "203" })).body;
  assert.equal(record.summary.youPoints, 3);
  assert.equal(record.summary.played, 1);
  assert.equal(record.recentGameweeks.length, 1);
  assert.equal(record.recentGameweeks[0].competitionId, "1");
  assert.deepEqual(record.competitions.map((entry) => entry.id), ["1", "7"]);
  const history = (await httpRequest(harness, credential, "history", { competitionId: "1" })).body;
  assert.deepEqual(history.fixtures.map((f) => f.id), ["101"]);
  const championsBoard = (await httpRequest(harness, credential, "leaderboards", { competitionId: "7", category: "season", seasonId: "203" })).body;
  assert.equal(championsBoard.rows.length, 1);
  assert.equal(championsBoard.rows[0].points, 3);
  assert.equal((await httpRequest(harness, credential, "leaderboards", { competitionId: "7", challengeId: eplChallenge._id })).statusCode, 400);
  assert.deepEqual(c.db.tables.get("pg_entries").find((entry) => entry.fixtureId === "101" && entry.playerId === c.player._id).ai, frozen);
});

test("dashboard latest result crosses competition boundaries without changing the selected competition", async () => {
  const c = multiCompetitionContext();
  const epl = c.add(101, 1, "2030-09-12T12:00:00Z");
  const champions = c.add(201, 7, "2030-09-08T12:00:00Z");
  const credential = await p.issueSession(c.db, c.player._id); const harness = routeHarness(c);
  await harness.game.sync(true);
  const eplAI = aiPrediction(c.db.tables.get("bsd_predictions").find((row) => row._id === "1").payload[0]);
  const championsAI = aiPrediction(c.db.tables.get("bsd_predictions").find((row) => row._id === "7").payload[0]);
  await harness.game.save(c.db, c.player, "101", { ...c.body, expectedAIRevision: eplAI.sourceRevision });
  await harness.game.save(c.db, c.player, "201", { ...c.body, homeScore: 1, awayScore: 1, expectedAIRevision: championsAI.sourceRevision });
  Object.assign(champions.payload, { status: "finished", home_score: 1, away_score: 1 });
  c.setNow(Date.parse(champions.payload.event_date) + 1000); await harness.game.sync(true);

  const dashboard = (await httpRequest(harness, credential, "state", { competitionId: "1" })).body;
  assert.equal(dashboard.competitionId, "1");
  assert.equal(dashboard.recentGameweeks[0].competitionId, "1");
  assert.equal(dashboard.recentGameweeks[0].played, 0);
  assert.equal(dashboard.latestResult.competitionId, "7");
  assert.equal(dashboard.latestResult.id, "competition:7:203:round:4");
  assert.equal(dashboard.latestResult.latestPlayedAt, new Date(champions.payload.event_date).toISOString());
  assert.equal(dashboard.latestResult.completed, true);
  assert.equal(epl.payload.status, "notstarted");
});

test("legacy EPL records and leaderboard identifiers remain readable after the statistics cache upgrade", async () => {
  const c = multiCompetitionContext(); c.add(101, 1);
  const credential = await p.issueSession(c.db, c.player._id); const harness = routeHarness(c);
  await harness.game.sync(true); await harness.game.save(c.db, c.player, "101", { ...c.body, expectedAIRevision: aiPrediction(c.db.tables.get("bsd_predictions")[0].payload[0]).sourceRevision });
  const doc = c.db.tables.get("bsd_events")[0]; Object.assign(doc.payload, { status: "finished", home_score: 1, away_score: 1 });
  await harness.game.sync(true);
  for (const name of ["pg_fixtures", "pg_entries", "pg_challenges", "pg_leaderboards"]) for (const row of c.db.tables.get(name)) { delete row.competitionId; delete row.competitionName; }
  delete c.db.tables.get("pg_stats")[0].byCompetition;
  const oldEntry = structuredClone(c.db.tables.get("pg_entries")[0]);
  const scopes = c.db.tables.get("pg_leaderboards").map((row) => row.scope);
  const record = (await httpRequest(harness, credential, "stats")).body;
  assert.equal(record.summary.youPoints, 3);
  assert.equal(record.competitionId, "1");
  assert.deepEqual(c.db.tables.get("pg_leaderboards").map((row) => row.scope), scopes);
  assert.equal((await httpRequest(harness, credential, "history")).body.fixtures[0].id, "101");
  assert.equal(c.db.tables.get("pg_entries")[0].homeScore, oldEntry.homeScore);
  assert.deepEqual(c.db.tables.get("pg_entries")[0].ai, oldEntry.ai);
  assert.equal(c.db.tables.get("pg_stats")[0].byCompetition["1"].summary.youPoints, 3);
});

test("competition availability retains played history after BSD prediction retention and validates query IDs", async () => {
  const c = multiCompetitionContext(); c.add(201, 7);
  const saved = await c.game.save(c.db, c.player, "201", { ...c.body, expectedAIRevision: aiPrediction(c.db.tables.get("bsd_predictions")[1].payload[0]).sourceRevision });
  assert.equal(saved.competitionId, "7");
  c.db.tables.get("bsd_predictions").find((row) => row._id === "7").payload = [];
  const competitions = await p.availableCompetitions(c.db, c.player._id);
  assert.deepEqual(competitions, [{ id: "1", name: "Premier League" }, { id: "7", name: "Champions League" }]);
  const credential = await p.issueSession(c.db, c.player._id); const harness = routeHarness(c);
  for (const path of ["state", "stats", "history", "next-predictions", "leaderboards"]) assert.equal((await httpRequest(harness, credential, path, { competitionId: "../../bad" })).statusCode, 400);
});

test("Game Center mappings isolate competitions, retain EPL legacy keys and reject reused Apple identifiers", async () => {
  const previous = process.env.PREDICTION_GAME_GC_LEADERBOARDS;
  try {
    process.env.PREDICTION_GAME_GC_LEADERBOARDS = JSON.stringify({ "season:203": "epl.season", "competition:7:season:203": "ucl.season", "competition:7:weekly:competition:7:203:epl-2030-09-06": "ucl.week", "perfect:203": "shared.unsafe", "competition:7:perfect:203": "shared.unsafe" });
    const mappings = p.gameCenterLeaderboardConfiguration();
    assert.deepEqual(mappings.map((m) => [m.competitionId, m.category, m.key, m.id]), [["1", "season", "203", "epl.season"], ["7", "season", "203", "ucl.season"], ["7", "weekly", "competition:7:203:epl-2030-09-06", "ucl.week"]]);
    const c = multiCompetitionContext(); c.db.tables.get("pg_players")[0].gameCenterSubject = "signed-in";
    c.db.tables.get("pg_players")[0].statsDirty = false;
    c.db.tables.set("pg_stats", [{ _id: c.player._id, byCompetition: {}, ranks: [{ competitionId: "1", seasonId: "203", youPoints: 3, exactScores: 1 }, { competitionId: "7", seasonId: "203", challengeId: "competition:7:203:epl-2030-09-06", youPoints: 9, exactScores: 3 }], achievements: [] }]);
    const credential = await p.issueSession(c.db, c.player._id); const harness = routeHarness(c); await harness.game.sync(true);
    const payload = (await httpRequest(harness, credential, "game-center/submissions")).body;
    assert.deepEqual(payload.leaderboards, [{ id: "epl.season", score: 3 }, { id: "ucl.season", score: 9 }, { id: "ucl.week", score: 9 }]);
    const board = (await httpRequest(harness, credential, "leaderboards", { competitionId: "7", category: "season", seasonId: "203" })).body;
    assert.equal(board.gameCenterLeaderboardId, "ucl.season");
  } finally { if (previous === undefined) delete process.env.PREDICTION_GAME_GC_LEADERBOARDS; else process.env.PREDICTION_GAME_GC_LEADERBOARDS = previous; }
});

test("cup scoring requires the shootout winner as well as the exact score, but ordinary draws ignore conditional picks", () => {
  const result = { homeScore: 1, awayScore: 1, penaltyWinner: "home" };
  assert.equal(pointsFor({ homeScore: 1, awayScore: 1, penaltyWinner: "home" }, result), 3);
  assert.equal(pointsFor({ homeScore: 1, awayScore: 1, penaltyWinner: "away" }, result), 0);
  assert.equal(pointsFor({ homeScore: 1, awayScore: 1 }, result), 0);
  assert.equal(pointsFor({ homeScore: 2, awayScore: 2, penaltyWinner: "home" }, result), 1);
  assert.equal(pointsFor({ homeScore: 2, awayScore: 0 }, result), 1);
  assert.equal(pointsFor({ homeScore: 1, awayScore: 1, penaltyWinner: "away" }, { homeScore: 1, awayScore: 1 }), 3);
  const { event } = context();
  const extraTime = p.fixtureFromEvent({ ...event, payload: { ...event.payload, league_id: 7, status: "finished", home_score: 1, away_score: 1, extra_time_score: { home: 2, away: 1 } } });
  assert.deepEqual(extraTime.result, { homeScore: 3, awayScore: 2 });
  const penalties = p.fixtureFromEvent({ ...event, payload: { ...event.payload, league_id: 7, status: "finished", home_score: 1, away_score: 1, extra_time_score: "1-1", penalty_shootout: { home: 5, away: 4 } } });
  assert.deepEqual(penalties.result, { homeScore: 2, awayScore: 2, penaltyWinner: "home" });
  assert.equal(aiPrediction({ markets: { expected_goals: { home: 1.1, away: 1.4 } } }).penaltyWinner, "away");
  assert.equal(aiPrediction({ markets: { score: { most_likely: "1-1" }, match_result: { prob_home: 20, prob_away: 60 } } }).penaltyWinner, "away");
});

test("shootout predictions freeze their AI tiebreaker and resettle after an incident-only correction", async () => {
  const c = multiCompetitionContext(); const event = c.add(201, 7);
  const market = c.db.tables.get("bsd_predictions").find((doc) => doc._id === "7").payload[0];
  market.markets = { expected_goals: { home: 1.1, away: 1.4 } };
  const body = { homeScore: 1, awayScore: 1, penaltyWinner: "home", expectedAIRevision: aiPrediction(market).sourceRevision };
  const saved = await c.game.save(c.db, c.player, "201", body);
  assert.equal(saved.prediction.penaltyWinner, "home");
  assert.equal(saved.ai.penaltyWinner, "away");
  market.markets.expected_goals = { home: 1.4, away: 1.1 };
  assert.equal((await c.game.save(c.db, c.player, "201", body)).ai.penaltyWinner, "away");
  await assert.rejects(c.game.save(c.db, c.player, "201", { ...body, penaltyWinner: "draw" }), { code: "invalid_penalty_winner" });
  Object.assign(event.payload, { status: "finished", home_score: 1, away_score: 1, penalty_shootout: { home: 4, away: 3 } });
  await c.game.sync(true);
  assert.equal(c.db.tables.get("pg_entries")[0].youPoints, 3);
  assert.equal(c.db.tables.get("pg_entries")[0].aiPoints, 0);
  c.db.tables.set("bsd_incidents", [{ _id: "201", updated_at: new Date(Date.now() + 1000).toISOString(), payload: [{ type: "period", text: "PEN", is_live: false, home_score: 3, away_score: 4 }] }]);
  await c.game.sync(true);
  assert.equal(c.db.tables.get("pg_entries")[0].youPoints, 0);
  assert.equal(c.db.tables.get("pg_entries")[0].aiPoints, 3);
  const fixture = (await p.gameFixtureBatch(c.db, c.player._id, ["201"]))[0];
  assert.equal(fixture.result.penaltyWinner, "away");
});


test("a completed penalty period settles the on-field ET score even when the event still says started", async () => {
  const c = multiCompetitionContext(); const event = c.add(201, 7);
  const market = c.db.tables.get("bsd_predictions")[1].payload[0];
  await c.game.save(c.db, c.player, "201", { homeScore: 1, awayScore: 1, penaltyWinner: "away", expectedAIRevision: aiPrediction(market).sourceRevision });
  Object.assign(event.payload, { status: "started", current_minute: 121, home_score: 3, away_score: 4 });
  c.db.tables.set("bsd_incidents", [{ _id: "201", updated_at: new Date().toISOString(), payload: { event_id: 201, incidents: [
    { text: "PEN", type: "period", is_live: false, home_score: 3, away_score: 4 },
    { text: "ET", type: "period", is_live: false, home_score: 1, away_score: 1 },
  ] } }]);
  await c.game.sync(true);
  const fixture = (await p.gameFixtureBatch(c.db, c.player._id, ["201"]))[0];
  assert.deepEqual(fixture.result, { homeScore: 1, awayScore: 1, penaltyWinner: "away" });
  assert.equal(fixture.settled, true);
  assert.equal(fixture.locked, true);
  assert.equal(c.db.tables.get("pg_entries")[0].youPoints, 3);
});

test("Seasoned Pro requires two seasons within a competition, not two simultaneous competition IDs", () => {
  const entries = [{ fixtureId: "1", competitionId: "1", seasonId: "203", seasonLabel: "2026/27", challengeId: "first", youPoints: 1, aiPoints: 1 },
    { fixtureId: "2", competitionId: "7", seasonId: "800", seasonLabel: "2026/27", challengeId: "second", youPoints: 1, aiPoints: 1 }];
  assert.equal(p.buildAchievements(entries, [], []).find((a) => a.id === "seasonedPro").unlocked, false);
  entries.push({ fixtureId: "3", competitionId: "7", seasonId: "801", seasonLabel: "2027/28", challengeId: "third", youPoints: 1, aiPoints: 1 });
  assert.equal(p.buildAchievements(entries, [], []).find((a) => a.id === "seasonedPro").unlocked, true);
});


test("calendar-year competition gameweeks retain postponed matches beyond a July season boundary", async () => {
  const c = multiCompetitionContext(); c.setNow(Date.parse("2030-01-01T12:00:00Z"));
  c.add(201, 7, "2030-01-06T12:00:00Z"); c.add(202, 7, "2030-09-07T12:00:00Z");
  c.add(203, 7, "2030-01-07T12:00:00Z", { season_id: 204 });
  const board = await p.nextPredictionSet(c.db, c.player._id, "201", c.game.now, true);
  assert.deepEqual(board.fixtures.map((f) => f.id), ["201", "202"]);
});


test("second-leg predictions can name the opposite shootout winner even with an exact non-drawn match score", async () => {
  const result = { homeScore: 2, awayScore: 1, penaltyWinner: "away" };
  assert.equal(pointsFor({ homeScore: 2, awayScore: 1, penaltyWinner: "away" }, result), 3);
  assert.equal(pointsFor({ homeScore: 2, awayScore: 1, penaltyWinner: "home" }, result), 0);
  assert.equal(pointsFor({ homeScore: 2, awayScore: 1 }, result), 0);
  assert.equal(pointsFor({ homeScore: 3, awayScore: 1, penaltyWinner: "away" }, result), 1);
  assert.equal(pointsFor({ homeScore: 2, awayScore: 1, penaltyWinner: "away" }, { homeScore: 2, awayScore: 1 }), 3);
  const c = multiCompetitionContext(); const event = c.add(201, 7, "2030-09-06T12:00:00Z", { previous_leg_event_id: 200 });
  const market = c.db.tables.get("bsd_predictions")[1].payload[0];
  market.markets = { score: { most_likely: "2-1" }, match_result: { prob_home: 30, prob_away: 60 } };
  const ai = aiPrediction(market);
  assert.equal(ai.homeScore, 2); assert.equal(ai.penaltyWinner, "away");
  const saved = await c.game.save(c.db, c.player, "201", { homeScore: 2, awayScore: 1, penaltyWinner: "away", expectedAIRevision: ai.sourceRevision });
  assert.equal(saved.isSecondLeg, true);
  assert.equal(saved.prediction.penaltyWinner, "away");
  assert.equal(c.db.tables.get("pg_entries")[0].penaltyWinner, "away");
  delete event.payload.previous_leg_event_id;
  assert.equal((await p.gameFixtureBatch(c.db, c.player._id, ["201"]))[0].isSecondLeg, true, "a partial provider update must retain known second-leg metadata");
  Object.assign(event.payload, { status: "finished", home_score: 2, away_score: 1, penalty_shootout: { home: 3, away: 4 } });
  await c.game.sync(true);
  assert.equal(c.db.tables.get("pg_entries")[0].youPoints, 3);
  assert.equal(c.db.tables.get("pg_entries")[0].aiPoints, 3);
});

test("non-second-leg saves ignore a conditional penalty choice when the predicted score is not drawn", async () => {
  const c = multiCompetitionContext(); c.add(101, 1);
  const market = c.db.tables.get("bsd_predictions")[0].payload[0];
  const saved = await c.game.save(c.db, c.player, "101", { homeScore: 2, awayScore: 1, penaltyWinner: "away", expectedAIRevision: aiPrediction(market).sourceRevision });
  assert.equal(saved.isSecondLeg, false);
  assert.equal(saved.prediction.penaltyWinner, undefined);
  assert.equal(c.db.tables.get("pg_entries")[0].penaltyWinner, null);
  assert.equal(saved.ai.penaltyWinner, "home");
});
