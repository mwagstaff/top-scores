"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { mkdtempSync, readFileSync, rmSync } = require("node:fs");
const { join } = require("node:path");
const { tmpdir } = require("node:os");
const { execFileSync } = require("node:child_process");
const { database } = require("./private_prediction_leagues.test-helper");
const { registerPredictionGameRoutes, __private: gameHelpers } = require("./prediction_game");
const { __private: p } = require("./private_prediction_leagues");
const PREFIX = "/api/v1/prediction-game";
const DAY = 86400000;

async function context({ rateLimits = false, future = DAY, matchCount = 12, gameCenter } = {}) {
  let clock = Date.now();
  const players = ["Owner", "Friend", "Outsider"].map((displayName) => ({ _id: crypto.randomUUID(), displayName, gameCenterSubject: `verified:${displayName}`, statsDirty: false }));
  const events = Array.from({ length: matchCount + 1 }, (_, index) => ({ _id: String(100 + index), league_id: 1, event_date: new Date(clock + future + index * 60000).toISOString(), payload: {
    id: 100 + index, league_id: 1, season_id: 203, round_number: index === matchCount ? 5 : 4,
    home_team: `Home ${index}`, away_team: `Away ${index}`, status: "notstarted", event_date: new Date(clock + future + (index === matchCount ? 7 * DAY : index * 60000)).toISOString(),
  } }));
  const predictions = events.map((event) => ({ event: { id: event.payload.id }, markets: { score: { most_likely: "2-1" } } }));
  const db = database({ pg_players: players, bsd_events: events, bsd_predictions: [{ _id: "1", payload: predictions }] }, () => clock);
  const handlers = new Map(); const app = Object.fromEntries(["get", "post", "put", "patch", "delete"].map((method) => [method, (path, handler) => handlers.set(`${method.toUpperCase()} ${path}`, handler)]));
  const registration = registerPredictionGameRoutes(app, { getDb: async () => db, now: () => clock, disableWorker: true, disableRateLimits: !rateLimits, gameCenter });
  const credentials = await Promise.all(players.map((player) => gameHelpers.issueSession(db, player._id, player.gameCenterSubject, clock)));
  async function request(method, path, player = 0, body = {}, query = {}, credential = null) {
    const match = [...handlers].find(([key]) => {
      const [verb, route] = key.split(" ");
      return verb === method && new RegExp(`^${route.replace(/:[^/]+/g, "([^/]+)")}$`).test(`${PREFIX}${path}`);
    });
    assert.ok(match, `Registered route ${method} ${path}`);
    const route = match[0].split(" ")[1]; const values = `${PREFIX}${path}`.match(new RegExp(`^${route.replace(/:[^/]+/g, "([^/]+)")}$`));
    const params = Object.fromEntries([...route.matchAll(/:([^/]+)/g)].map((part, index) => [part[1], values[index + 1]]));
    const req = { method, headers: { authorization: `Bearer ${credential || credentials[player]}` }, params, body, query, ip: "127.0.0.1" };
    const res = { statusCode: 200, headers: {}, set(key, value) { this.headers[key] = value; return this; }, status(code) { this.statusCode = code; return this; }, json(value) { this.body = value; return this; } };
    await match[1](req, res); return res;
  }
  async function create() { const response = await request("POST", "/mini-leagues", 0, { name: "Saturday Legends", competitionId: "1" }); assert.equal(response.statusCode, 201, JSON.stringify(response.body)); return response.body.league; }
  async function invite(league, player = 0) { const response = await request("POST", `/mini-leagues/${league.id}/invitations`, player); assert.equal(response.statusCode, 201, JSON.stringify(response.body)); return response.body.invitation; }
  async function join(league, player = 1) { const invitation = await invite(league); const response = await request("POST", "/mini-league-invitations/redeem", player, { code: invitation.code }); assert.equal(response.statusCode, 200, JSON.stringify(response.body)); return response.body.league; }
  async function save(player, fixtureId = "100", score = [2, 1]) {
    const fixture = (await request("GET", "/fixtures", player, {}, { ids: fixtureId })).body.fixtures[0];
    return request("PUT", `/predictions/${fixtureId}`, player, { homeScore: score[0], awayScore: score[1], expectedAIRevision: fixture.ai.sourceRevision });
  }
  return { db, players, events, predictions, credentials, request, create, invite, join, save, service: registration.privateLeagues,
    get now() { return clock; }, setNow(value) { clock = value; }, async renewSessions() { for (let index = 0; index < players.length; index += 1) credentials[index] = await gameHelpers.issueSession(db, players[index]._id, players[index].gameCenterSubject, clock); } };
}

test("private APIs require a current proof-bound credential, not a linked guest token or claimed player ID", async () => {
  const c = await context(); const league = await c.create();
  const guest = await gameHelpers.issueSession(c.db, c.players[0]._id);
  const rejected = await c.request("GET", "/my-leagues", 0, { playerId: c.players[0]._id }, {}, guest);
  assert.equal(rejected.statusCode, 401); assert.equal(rejected.body.code, "game_center_required");
  assert.equal((await c.request("PUT", "/predictions/100", 0, { homeScore: 9, awayScore: 9 }, {}, guest)).statusCode, 401);
  assert.equal((await c.request("GET", `/mini-leagues/${league.id}`, 2, { playerId: c.players[0]._id })).statusCode, 404);
  c.setNow(c.now + DAY + 1);
  assert.equal((await c.request("GET", "/my-leagues")).statusCode, 401);
  const replacement = await gameHelpers.issueSession(c.db, c.players[0]._id, "other-account", c.now);
  assert.equal((await c.request("GET", "/my-leagues", 0, {}, {}, replacement)).statusCode, 401);
});

test("all official AI-supported fixtures open 48 hours before kickoff; shared benchmark never drifts", async () => {
  const c = await context(); const league = await c.create();
  assert.equal(league.currentRound.fixtureCount, 12, "not capped to public ten-match challenge");
  const original = (await c.request("GET", `/mini-leagues/${league.id}/fixtures`)).body;
  assert.equal(original.sharedAI[0].ai.homeScore, 2);
  c.db.tables.get("bsd_predictions")[0].payload[0].markets.score.most_likely = "4-0";
  await c.service.publish(c.db, "1");
  const refreshed = (await c.request("GET", `/mini-leagues/${league.id}/fixtures`)).body;
  assert.equal(refreshed.sharedAI[0].ai.homeScore, 2);
  assert.equal(refreshed.fixtures[0].ai.homeScore, 4, "personal first-save AI stays separate");
  assert.equal(c.db.tables.get("pg_mini_league_rounds").length, 1, "next week's round has not opened");
  const early = await context({ future: 3 * DAY });
  const earlyLeague = await early.create(); assert.equal(earlyLeague.currentRound, null);
  early.setNow(early.now + DAY + 1); await early.renewSessions();
  assert.equal((await early.request("GET", `/mini-leagues/${earlyLeague.id}`)).body.league.currentRound.fixtureCount, 12);
});

test("invitation preview is read-only, codes are hashed, reusable, seven-day and revocable", async () => {
  const c = await context(); const league = await c.create(); const invitation = await c.invite(league);
  assert.equal(invitation.code.length, 12); assert.equal(Date.parse(invitation.expiresAt) - c.now, 7 * DAY);
  assert.ok(invitation.url.startsWith("https://top-scores.skynolimit.dev/invite/"));
  const rawStorage = JSON.stringify([...c.db.tables]); assert.equal(rawStorage.includes(invitation.code), false);
  const preview = await c.request("POST", "/mini-league-invitations/preview", 1, { code: invitation.code });
  assert.equal(preview.body.invitation.leagueName, league.name);
  assert.equal((await c.request("GET", "/my-leagues", 1)).body.leagues.length, 0);
  for (const player of [1, 2, 1]) assert.equal((await c.request("POST", "/mini-league-invitations/redeem", player, { code: invitation.code })).statusCode, 200);
  assert.equal(c.db.tables.get("pg_mini_leagues")[0].members.length, 3);
  assert.equal((await c.request("DELETE", `/mini-leagues/${league.id}/invitations/${invitation.id}`, 1)).statusCode, 403);
  assert.equal((await c.request("DELETE", `/mini-leagues/${league.id}/invitations/${invitation.id}`)).statusCode, 200);
  assert.equal((await c.request("POST", "/mini-league-invitations/preview", 1, { code: invitation.code })).statusCode, 404);
  const replacement = await c.invite(league); c.setNow(c.now + 7 * DAY); await c.renewSessions();
  assert.equal((await c.request("POST", "/mini-league-invitations/redeem", 1, { code: replacement.code })).statusCode, 404);
});

test("a replacement invite atomically invalidates the old code and attempts survive route re-registration", async () => {
  const c = await context({ rateLimits: true }); const league = await c.create(); const first = await c.invite(league); const second = await c.invite(league);
  assert.notEqual(first.code, second.code);
  assert.equal((await c.request("POST", "/mini-league-invitations/preview", 1, { code: first.code })).statusCode, 404);
  for (let count = 0; count < 29; count += 1) await c.request("POST", "/mini-league-invitations/preview", 1, { code: "BAD" });
  const denied = await c.request("POST", "/mini-league-invitations/preview", 1, { code: second.code });
  assert.equal(denied.statusCode, 429); assert.equal(denied.headers["Retry-After"], "600");
  await assert.rejects(c.service.limitInvitationAttempts(c.db, { ip: "127.0.0.2" }, c.players[1]), (error) => error.status === 429);
});

test("peer scorelines and penalty choices stay hidden until each individual match locks, including from owner", async () => {
  const c = await context(); const league = await c.create(); await c.join(league);
  assert.equal((await c.save(1, "100", [3, 2])).statusCode, 200);
  assert.equal((await c.save(1, "101", [1, 0])).statusCode, 200);
  const before = (await c.request("GET", `/mini-leagues/${league.id}/predictions`)).body;
  assert.ok(before.matches.every((match) => match.predictions.length === 0));
  const table = (await c.request("GET", `/mini-leagues/${league.id}/standings`)).body;
  assert.ok(table.rows.every((row) => row.predicted === 0));
  assert.equal(JSON.stringify(table).includes("playerId"), false);
  c.setNow(Date.parse(c.events[0].payload.event_date)); await c.renewSessions();
  const after = (await c.request("GET", `/mini-leagues/${league.id}/predictions`)).body;
  assert.deepEqual(after.matches[0].predictions.map((pick) => [pick.homeScore, pick.awayScore]), [[3, 2]]);
  assert.equal(after.matches[1].predictions.length, 0);
  assert.equal((await c.save(1, "100", [4, 0])).statusCode, 409, "server deadline applies regardless of client lock flag");
  assert.equal((await c.save(1, "101", [4, 0])).statusCode, 200);
});

test("one canonical pick counts across leagues; point totals replace idempotently after result correction and cancellation", async () => {
  const c = await context(); const first = await c.create(); const second = await c.create();
  await c.join(first); await c.join(second); assert.equal((await c.save(1)).statusCode, 200);
  assert.equal(c.db.tables.get("pg_entries").filter((entry) => entry.playerId === c.players[1]._id).length, 1);
  c.setNow(c.now + DAY + 1); await c.renewSessions();
  const event = c.db.tables.get("bsd_events")[0]; Object.assign(event.payload, { status: "finished", home_score: 2, away_score: 1 });
  const table = async (league) => (await c.request("GET", `/mini-leagues/${league.id}/standings`)).body.rows;
  for (const league of [first, second]) for (let retry = 0; retry < 2; retry += 1) {
    const rows = await table(league); assert.equal(rows.find((row) => row.displayName === "Friend").points, 3);
    assert.equal(rows.find((row) => row.displayName === "Friend").exactScores, 1);
    assert.equal(rows.find((row) => row.isAI).points, 3);
  }
  Object.assign(event.payload, { home_score: 3, away_score: 1 });
  assert.equal((await table(first)).find((row) => row.displayName === "Friend").points, 1);
  assert.equal((await table(first)).find((row) => row.displayName === "Friend").exactScores, 0);
  Object.assign(event.payload, { status: "cancelled" });
  const voidRows = await table(first); assert.ok(voidRows.every((row) => row.points === 0 && row.played === 0));
  assert.equal(c.db.tables.get("pg_mini_league_standings")[0].rebuildPending, false);
});

test("late joiners start next full round without importing earlier points; league created mid-round also starts next", async () => {
  const c = await context(); const league = await c.create();
  assert.equal((await c.save(1)).statusCode, 200);
  c.setNow(Date.parse(c.events[0].payload.event_date) + 1); await c.renewSessions(); await c.join(league);
  Object.assign(c.db.tables.get("bsd_events")[0].payload, { status: "finished", home_score: 2, away_score: 1 });
  const table = (await c.request("GET", `/mini-leagues/${league.id}/standings`)).body;
  assert.equal(table.rows.find((row) => row.displayName === "Friend").points, 0);
  assert.equal(table.rows.find((row) => row.displayName === "Friend").played, 0);
  const lateLeague = await c.create(); assert.equal(lateLeague.currentRound, null);
  c.setNow(c.now + 5 * DAY); await c.renewSessions();
  const detail = (await c.request("GET", `/mini-leagues/${league.id}`)).body;
  assert.equal(detail.rounds.length, 2);
  assert.equal((await c.save(1, "112")).statusCode, 200);
  c.setNow(Date.parse(c.events.at(-1).payload.event_date) + 1); await c.renewSessions();
  Object.assign(c.db.tables.get("bsd_events").at(-1).payload, { status: "finished", home_score: 2, away_score: 1 });
  const season = (await c.request("GET", `/mini-leagues/${league.id}/standings`, 1, {}, { scope: "season" })).body;
  assert.equal(season.rows.find((row) => row.isYou).points, 3);
});

test("owner controls enforce role, removal revokes access and invitations cannot bypass it", async () => {
  const c = await context(); const league = await c.create(); const joined = await c.join(league);
  const invitation = await c.invite(league);
  assert.equal((await c.request("POST", `/mini-leagues/${league.id}/transfer`, 1, { memberId: joined.myMemberId })).statusCode, 403);
  assert.equal((await c.request("DELETE", `/mini-leagues/${league.id}/membership`)).body.code, "owner_transfer_required");
  assert.equal((await c.request("DELETE", `/mini-leagues/${league.id}/members/${joined.myMemberId}`)).statusCode, 200);
  for (const suffix of ["", "/standings", "/fixtures", "/predictions", "/invitations"]) assert.equal((await c.request("GET", `/mini-leagues/${league.id}${suffix}`, 1)).statusCode, 404);
  assert.equal((await c.request("POST", "/mini-league-invitations/redeem", 1, { code: invitation.code })).statusCode, 403);
  assert.equal((await c.request("POST", `/mini-leagues/${league.id}/members/${joined.myMemberId}/reinstate`)).statusCode, 200);
  assert.equal((await c.request("POST", "/mini-league-invitations/redeem", 1, { code: invitation.code })).statusCode, 200);
  assert.equal((await c.request("POST", `/mini-leagues/${league.id}/transfer`, 0, { memberId: joined.myMemberId })).statusCode, 200);
  assert.equal((await c.request("POST", `/mini-leagues/${league.id}/invitations`)).statusCode, 403);
  assert.equal((await c.request("POST", "/mini-league-invitations/preview", 2, { code: invitation.code })).statusCode, 404, "ownership transfer revokes former owner's invitations");
  assert.equal((await c.request("DELETE", `/mini-leagues/${league.id}/membership`)).statusCode, 200);
});

test("leaving preserves locked match history, stops future scoring and rejoin cannot recover missed rounds", async () => {
  const c = await context(); const league = await c.create(); await c.join(league);
  await c.save(1, "100"); await c.save(1, "101");
  c.setNow(Date.parse(c.events[0].payload.event_date) + 1); await c.renewSessions();
  assert.equal((await c.request("DELETE", `/mini-leagues/${league.id}/membership`, 1)).statusCode, 200);
  for (const event of c.db.tables.get("bsd_events").slice(0, 2)) Object.assign(event.payload, { status: "finished", home_score: 2, away_score: 1 });
  const table = (await c.request("GET", `/mini-leagues/${league.id}/standings`)).body;
  const former = table.rows.find((row) => row.displayName === "Friend"); assert.equal(former.points, 3); assert.equal(former.status, "left");
  await c.join(league);
  const rejoined = (await c.request("GET", `/mini-leagues/${league.id}/standings`)).body.rows.find((row) => row.displayName === "Friend");
  assert.equal(rejoined.points, 3);
});

test("postponements retain their round and canceled fixtures never reveal pre-deadline picks", async () => {
  const c = await context(); const league = await c.create(); await c.join(league); await c.save(1);
  const event = c.db.tables.get("bsd_events")[0];
  Object.assign(event.payload, { status: "postponed", event_date: new Date(c.now + 10 * DAY).toISOString() });
  await c.service.publish(c.db, "1");
  assert.equal((await c.request("GET", `/mini-leagues/${league.id}/fixtures`)).body.fixtures.length, 12);
  event.payload.status = "cancelled";
  const disclosures = (await c.request("GET", `/mini-leagues/${league.id}/predictions`)).body.matches[0];
  assert.equal(disclosures.locked, false); assert.deepEqual(disclosures.predictions, []);
});

test("a closed league is read-only, keeps its history and cannot be joined", async () => {
  const c = await context(); const league = await c.create(); const invitation = await c.invite(league);
  assert.equal((await c.request("POST", `/mini-leagues/${league.id}/close`, 2)).statusCode, 404);
  assert.equal((await c.request("POST", `/mini-leagues/${league.id}/close`)).statusCode, 200);
  assert.equal((await c.request("GET", `/mini-leagues/${league.id}`)).body.league.status, "closed");
  assert.equal((await c.request("PATCH", `/mini-leagues/${league.id}`, 0, { name: "Renamed" })).statusCode, 409);
  assert.equal((await c.request("POST", "/mini-league-invitations/redeem", 2, { code: invitation.code })).statusCode, 404);
});

test("rank ties share places after points and exact scores; AI does not take a human podium position", () => {
  const rows = p.rankRows([{ memberId: "a", displayName: "A", points: 8, exactScores: 2 }, { memberId: "b", displayName: "B", points: 8, exactScores: 1 },
    { memberId: "c", displayName: "C", points: 8, exactScores: 2 }, { memberId: "d", displayName: "D", points: 7, exactScores: 2 }]);
  assert.deepEqual(rows.map((row) => row.rank), [1, 1, 3, 4]);
});

test("full invitation URLs accept only the app's exact HTTPS/native destinations", () => {
  const code = "ABCD2345EFGH";
  assert.equal(p.normalizeCode(`https://top-scores.skynolimit.dev/invite/${code}`), code);
  assert.equal(p.normalizeCode(`topscores://invite/${code}`), code);
  for (const url of [`https://attacker.example/invite/${code}`, `http://top-scores.skynolimit.dev/invite/${code}`, `https://user@top-scores.skynolimit.dev/invite/${code}`, `topscores://invite/${code}?playerId=owner`, `https://top-scores.skynolimit.dev/invite/${code}#fragment`]) assert.equal(p.normalizeCode(url), "");
});

test("invitation limiter trusts only the local reverse proxy's nearest forwarded address", () => {
  assert.equal(p.invitationClientIP({ socket: { remoteAddress: "::ffff:127.0.0.1" }, headers: { "x-forwarded-for": "1.2.3.4, 5.6.7.8" } }), "5.6.7.8");
  assert.equal(p.invitationClientIP({ socket: { remoteAddress: "8.8.8.8" }, headers: { "x-forwarded-for": "1.2.3.4" } }), "8.8.8.8");
  assert.equal(p.invitationClientIP({ socket: { remoteAddress: "127.0.0.1" }, headers: { "x-forwarded-for": "not-an-address" } }), "127.0.0.1");
});

test("a postponed old round cannot block the next round, and moved fixtures cannot score twice", async () => {
  const c = await context(); const league = await c.create(); const originalRound = league.currentRound.id;
  Object.assign(c.db.tables.get("bsd_events")[0].payload, { status: "postponed", round_number: 5, event_date: c.events.at(-1).payload.event_date });
  c.setNow(c.now + 6 * DAY); await c.renewSessions();
  const detail = (await c.request("GET", `/mini-leagues/${league.id}`)).body;
  assert.notEqual(detail.league.currentRound.id, originalRound);
  const round = c.db.tables.get("pg_mini_league_rounds").find((item) => item._id === detail.league.currentRound.id);
  assert.deepEqual(round.fixtureIds, ["112"]);
  assert.equal(c.db.tables.get("pg_mini_league_rounds").filter((item) => item.fixtureIds.includes("100")).length, 1);
});

test("joining and creating across the kickoff boundary cannot backdate round eligibility", async () => {
  const c = await context(); const league = await c.create(); const invitation = await c.invite(league);
  const originalCollection = c.db.collection.bind(c.db);
  let delayJoin = true;
  c.db.collection = (name) => {
    const collection = originalCollection(name);
    if (name !== "pg_mini_leagues") return collection;
    return { ...collection, updateOne: async (filter, update, options) => {
      if (delayJoin && filter.$expr && update.$set?.members?.length === 2) { delayJoin = false; c.setNow(Date.parse(c.events[0].payload.event_date)); }
      return collection.updateOne(filter, update, options);
    } };
  };
  const delayed = await c.request("POST", "/mini-league-invitations/redeem", 1, { code: invitation.code });
  assert.equal(delayed.statusCode, 409);
  assert.equal(c.db.tables.get("pg_mini_leagues")[0].members.length, 1);
  await c.renewSessions();
  assert.equal((await c.request("POST", "/mini-league-invitations/redeem", 1, { code: invitation.code })).statusCode, 200);
  assert.equal((await c.request("GET", `/mini-leagues/${league.id}/fixtures`, 1)).body.scoringEligible, false);
  const fresh = await context(); const collectionForFresh = fresh.db.collection.bind(fresh.db);
  fresh.db.collection = (name) => {
    const collection = collectionForFresh(name);
    return name !== "pg_mini_leagues" ? collection : { ...collection, updateOne: async (filter, update, options) => {
      if (filter.status === "creating") fresh.setNow(Date.parse(fresh.events[0].payload.event_date));
      return collection.updateOne(filter, update, options);
    } };
  };
  const created = await fresh.request("POST", "/mini-leagues", 0, { name: "Too late", competitionId: "1" });
  assert.equal(created.statusCode, 409); assert.equal(fresh.db.tables.get("pg_mini_leagues").length, 0);
});

test("a kickoff moved earlier excludes that already-started round for new leagues and new members", async () => {
  const c = await context(); const league = await c.create();
  Object.assign(c.db.tables.get("bsd_events")[0].payload, { status: "started", event_date: new Date(c.now - 1000).toISOString() });
  await c.join(league);
  assert.equal((await c.request("GET", `/mini-leagues/${league.id}/fixtures`, 1)).body.scoringEligible, false);
  const fresh = await c.create(); assert.equal(fresh.currentRound, null);
});

test("an interrupted standings write leaves durable recovery intent and retry replaces its totals", async () => {
  const c = await context(); const league = await c.create(); await c.save(0);
  Object.assign(c.db.tables.get("bsd_events")[0].payload, { status: "finished", home_score: 2, away_score: 1 });
  const original = c.db.collection.bind(c.db); let crash = true;
  c.db.collection = (name) => {
    const collection = original(name);
    return name !== "pg_mini_league_standings" ? collection : { ...collection, updateOne: async (filter, update, options) => {
      if (crash && update.$set?.rebuildPending === false) { crash = false; throw Error("simulated process interruption"); }
      return collection.updateOne(filter, update, options);
    } };
  };
  const stored = c.db.tables.get("pg_mini_leagues")[0];
  await assert.rejects(c.service.standings(c.db, stored, c.players[0]), /simulated process interruption/);
  assert.equal(c.db.tables.get("pg_mini_league_standings")[0].rebuildPending, true);
  await c.service.sync();
  const recovered = c.db.tables.get("pg_mini_league_standings").find((row) => row.scope === "round");
  assert.equal(recovered.rebuildPending, false); assert.equal(recovered.rows.find((row) => !row.isAI).points, 3);
  const revision = recovered.revision; await c.service.sync();
  assert.equal(c.db.tables.get("pg_mini_league_standings").find((row) => row.scope === "round").revision, revision, "unchanged recovery never awards twice");
});

test("standings reads are serialized before source snapshots, so a stale concurrent rebuild cannot replace a correction", async () => {
  const c = await context(); const league = await c.create(); await c.save(0);
  Object.assign(c.db.tables.get("bsd_events")[0].payload, { status: "finished", home_score: 2, away_score: 1 });
  const original = c.db.collection.bind(c.db); let release; let started;
  const paused = new Promise((resolve) => { started = resolve; }); let pause = true;
  c.db.collection = (name) => {
    const collection = original(name);
    return name !== "pg_entries" ? collection : { ...collection, find: (filter, options) => {
      const cursor = collection.find(filter, options); const get = cursor.toArray.bind(cursor);
      cursor.toArray = async () => { if (pause) { pause = false; started(); await new Promise((resolve) => { release = resolve; }); } return get(); }; return cursor;
    } };
  };
  const stored = c.db.tables.get("pg_mini_leagues")[0];
  const first = c.service.standings(c.db, stored, c.players[0]); await paused;
  Object.assign(c.db.tables.get("bsd_events")[0].payload, { home_score: 3 });
  await assert.rejects(c.service.standings(c.db, stored, c.players[0]), (error) => error.code === "fixture_busy");
  release(); await first;
  const corrected = await c.service.standings(c.db, stored, c.players[0]);
  assert.equal(corrected.rows.find((row) => row.isYou).points, 1);
  assert.equal(c.db.tables.get("pg_mini_league_standings")[0].rows.find((row) => !row.isAI).points, 1);
});

test("round reads load only the requested fixture set, season history remains separate", async () => {
  const c = await context(); const league = await c.create();
  const existing = c.db.tables.get("pg_mini_league_rounds")[0];
  c.db.tables.get("pg_mini_league_rounds").push({ ...structuredClone(existing), _id: "old-season", seasonId: "old", startsAt: new Date(c.now + 500).toISOString(), fixtureIds: ["old-match"], fixtureSnapshots: [{ ...existing.fixtureSnapshots[0], _id: "old-match" }] });
  const original = c.db.collection.bind(c.db); const entryFilters = [];
  c.db.collection = (name) => { const collection = original(name); return name !== "pg_entries" ? collection : { ...collection, find: (filter, options) => { entryFilters.push(filter); return collection.find(filter, options); } }; };
  const response = await c.request("GET", `/mini-leagues/${league.id}/standings`, 0, {}, { scope: "round", roundId: existing._id });
  assert.equal(response.statusCode, 200);
  assert.ok(entryFilters.every((filter) => !filter.fixtureId.$in.includes("old-match")));
  const before = c.db.tables.get("pg_mini_league_standings").length;
  assert.equal((await c.request("GET", `/mini-leagues/${league.id}/standings`, 0, {}, { scope: "season", seasonId: "invented" })).statusCode, 404);
  assert.equal(c.db.tables.get("pg_mini_league_standings").length, before);
});

test("private request limits and invitation expiry are enforced at the database boundary", async () => {
  const c = await context({ rateLimits: true }); const league = await c.create(); const invitation = await c.invite(league);
  for (let index = 0; index < 40; index += 1) await c.service.limitRequests(c.db, { method: "POST" }, c.players[2]);
  await assert.rejects(c.service.limitRequests(c.db, { method: "POST" }, c.players[2]), (error) => error.status === 429);
  const original = c.db.collection.bind(c.db);
  c.db.collection = (name) => {
    const collection = original(name);
    return name !== "pg_mini_leagues" ? collection : { ...collection, updateOne: async (filter, update, options) => {
      if (filter.$expr && update.$set?.members?.length === 2) c.setNow(Date.parse(invitation.expiresAt));
      return collection.updateOne(filter, update, options);
    } };
  };
  assert.equal((await c.request("POST", "/mini-league-invitations/redeem", 1, { code: invitation.code })).statusCode, 409);
  assert.equal(c.db.tables.get("pg_mini_leagues")[0].members.length, 1);
});

test("concurrent Game Center proofs cannot overwrite another verified account's identity", async () => {
  const dir = mkdtempSync(join(tmpdir(), "private-league-gc-"));
  try {
    const keyPath = join(dir, "key.pem"); const certPath = join(dir, "cert.pem");
    execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", keyPath, "-out", certPath, "-days", "1", "-subj", "/CN=Private league test"], { stdio: "ignore" });
    const timestamp = Date.now(); const salt = crypto.randomBytes(32); const time = Buffer.alloc(8); time.writeBigUInt64BE(BigInt(timestamp));
    const bodies = ["account-a", "account-b"].map((teamPlayerId) => ({ teamPlayerId, timestamp, salt: salt.toString("base64"),
      signature: crypto.sign("RSA-SHA256", Buffer.concat([Buffer.from(teamPlayerId), Buffer.from("private.test"), time, salt]), readFileSync(keyPath)).toString("base64"),
      publicKeyUrl: `https://static.gc.apple.com/public-key/${crypto.randomUUID()}.cer` }));
    const c = await context({ gameCenter: { bundleId: "private.test", fetch: async () => ({ ok: true, arrayBuffer: async () => readFileSync(certPath), headers: new Headers() }) } });
    delete c.db.tables.get("pg_players")[0].gameCenterSubject;
    const original = c.db.collection.bind(c.db); const pending = []; let allArrived;
    const barrier = new Promise((resolve) => { allArrived = resolve; });
    c.db.collection = (name) => {
      const collection = original(name);
      return name !== "pg_players" ? collection : { ...collection, updateOne: async (filter, update, options) => {
        if (!update.$set?.gameCenterSubject) return collection.updateOne(filter, update, options);
        return new Promise((resolve) => { pending.push(async () => resolve(await collection.updateOne(filter, update, options))); if (pending.length === 2) allArrived(); });
      } };
    };
    const first = c.request("POST", "/game-center", 0, bodies[0]); const second = c.request("POST", "/game-center", 0, bodies[1]);
    await barrier; await pending[0](); await pending[1]();
    const responses = await Promise.all([first, second]);
    assert.deepEqual(responses.map((response) => response.statusCode).sort(), [200, 409]);
    const accepted = responses.find((response) => response.statusCode === 200).body;
    assert.ok(accepted.credential); assert.equal(accepted.restoredExisting, false); assert.equal(Date.parse(accepted.privateSessionExpiresAt) - c.now, DAY);
    assert.equal((await c.request("GET", "/my-leagues", 0, {}, {}, accepted.credential)).statusCode, 200);
    assert.equal(c.db.tables.get("pg_players")[0].gameCenterSubject, c.db.tables.get("pg_sessions").find((session) => session._id === accepted.credential.split(".")[0]).verifiedGameCenterSubject);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
