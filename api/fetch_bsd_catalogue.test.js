"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { createCatalogueRefresher } = require("./fetch_bsd_catalogue");
const { createColourResolver, DAY_MS } = require("./reference_model");
const { dataset, memoryStore, rawPlayer, rawTeam, rawLeague, time } = require("./reference_test_helpers");

function fixture(overrides = {}) {
  const calls = [];
  const client = {
    async getLeague(id, options) {
      assert.equal(options.query?.limit, undefined, "BSD rejects limit on detail endpoints");
      calls.push(["league", id]); return rawLeague(Number(id));
    },
    async getTeams({ leagueId, seasonId }, options) { calls.push(["teams", leagueId, seasonId, options]); return [rawTeam()]; },
    async getTeam(id) { calls.push(["team", id]); return rawTeam(Number(id)); },
    async getTeamSquad(id) { return { team_id: Number(id), count: 1, players: [{ id: 363, jersey_number: id === "727" ? 5 : 6 }] }; },
    async getPlayers() { return [rawPlayer()]; },
    async getPlayer(id) { calls.push(["player", id]); return rawPlayer(Number(id)); },
    ...overrides,
  };
  return { client, calls };
}
function refresher(client, store, ids = ["1"], now = () => Date.parse(time) + 2 * DAY_MS) {
  return createCatalogueRefresher({ client, store, competitionIds: ids, now, colourResolver: () => createColourResolver({ teams: [] }) });
}

test("publishes full current squads, keeps rating and uses strict season-filtered pagination", async () => {
  const { client, calls } = fixture();
  const store = memoryStore();
  const result = await refresher(client, store).refresh();
  assert.equal(result.succeeded, 1);
  const saved = await store.load();
  assert.equal(saved.rows[0].payload.squad.players[0].player.rating, 78);
  assert.equal(saved.rows[0].payload.squad.players[0].player.attributes.defending, 15);
  assert.equal(calls.find(([kind]) => kind === "teams")[2], "101");
  assert.equal(calls.find(([kind]) => kind === "teams")[3].strict, true);
  assert.ok(store.sources.some((record) => record.collection === "bsd_players"));
});

test("national squad membership and shirt number survive club-filtered profile lookup", async () => {
  const { client, calls } = fixture({
    async getTeams() { return [rawTeam(727)]; },
    async getPlayers() { return []; },
  });
  const store = memoryStore();
  await refresher(client, store).refresh();
  const member = (await store.load()).rows[0].payload.squad.players[0];
  assert.equal(member.jersey_number, 5);
  assert.equal(member.player.jersey_number, 6);
  assert.equal(member.player.current_team_id, "19");
  assert.ok(calls.some(([kind]) => kind === "player"));
});

test("failed player fetch retains the entire old competition snapshot", async () => {
  const store = memoryStore(dataset());
  const { client } = fixture({ async getPlayers() { return []; }, async getPlayer() { throw new Error("upstream 429 after retries"); } });
  const result = await refresher(client, store).refresh();
  assert.equal(result.failed, 1);
  const saved = await store.load();
  assert.equal(saved.manifests[0].snapshot_id, "snapshot-1");
  assert.equal(saved.rows[0].payload.squad.players[0].player.rating, 78);
  assert.equal(saved.statuses[0].payload.status, "failed");
});

test("one failed competition does not prevent another from publishing", async () => {
  const { client } = fixture({ async getLeague(id) { if (id === "1") throw new Error("timeout"); return rawLeague(Number(id)); } });
  const store = memoryStore();
  const result = await refresher(client, store, ["1", "27"]).refresh();
  assert.deepEqual([result.succeeded, result.failed], [1, 1]);
  assert.equal(store.state.manifests[0].competition.id, "27");
});

test("deduplicates team/profile fetches across competitions and avoids refreshing before 24h", async () => {
  const { client, calls } = fixture();
  const store = memoryStore();
  const worker = refresher(client, store, ["1", "27"]);
  await worker.refresh();
  assert.equal(calls.filter(([kind]) => kind === "team").length, 1);
  const previous = calls.length;
  await worker.refresh();
  assert.equal(calls.length, previous);
});

test("catalogue refresh checks publication age without loading all previous squads", async () => {
  const { client, calls } = fixture();
  const store = memoryStore(dataset());
  const load = store.load;
  store.load = async (ids, options) => {
    assert.deepEqual(ids, ["1"]);
    assert.deepEqual(options, { includeRows: false });
    const value = await load();
    return { ...value, rows: [] };
  };
  const result = await refresher(client, store, ["1"], () => Date.parse(time) + 1_000).refresh();
  assert.deepEqual([result.succeeded, result.failed], [0, 0]);
  assert.deepEqual(calls, []);
});

test("malformed and truncated squads, empty membership and invalid ratings never replace snapshots", async (t) => {
  for (const overrides of [
    { async getTeams() { return []; } },
    { async getTeamSquad() { return { team_id: 19, count: 2, players: [{ id: 363 }] }; } },
    { async getTeamSquad() { return { team_id: 19, count: 2, players: [{ id: 363 }, { id: 363 }] }; } },
    { async getPlayers() { return [rawPlayer(363, 201)]; } },
    { async getTeam() { return rawTeam(727); } },
  ]) await t.test("retains prior publication", async () => {
    const store = memoryStore(dataset());
    const { client } = fixture(overrides);
    assert.equal((await refresher(client, store).refresh()).failed, 1);
    assert.equal(store.state.manifests[0].snapshot_id, "snapshot-1");
  });
});

test("missing ratings and verified empty squads are represented without fabricated data", async () => {
  const { client } = fixture({ async getPlayers() { return [rawPlayer(363, null)]; } });
  const store = memoryStore();
  await refresher(client, store).refresh();
  assert.equal((await store.load()).rows[0].payload.squad.players[0].player.rating, null);
  client.getTeamSquad = async () => ({ team_id: 19, count: 0, players: [] });
  await refresher(client, store).refresh({ force: true });
  assert.equal((await store.load()).rows[0].payload.squad.status, "empty");
});

test("unresolved tournament slots do not trigger squad requests", async () => {
  const { client } = fixture({
    async getTeam() { return { id: 19, name: "W101" }; },
    async getTeamSquad() { throw new Error("must not be called"); },
  });
  const store = memoryStore();
  assert.equal((await refresher(client, store).refresh()).succeeded, 1);
  assert.equal((await store.load()).rows[0].payload.squad.status, "placeholder");
});

test("refresh cancellation releases the lease and cannot publish", async () => {
  const controller = new AbortController();
  const { client } = fixture({ async getTeam() { controller.abort(); return rawTeam(); } });
  const store = memoryStore();
  await assert.rejects(refresher(client, store).refresh({ signal: controller.signal }), /cancelled/);
  assert.equal(store.state.manifests.length, 0);
  assert.equal(await store.acquireLease("new-owner"), true);
});

test("failed snapshot write cannot become the active manifest", async () => {
  const store = memoryStore(dataset());
  store.publish = async () => { throw new Error("storage write failed"); };
  const { client } = fixture();
  assert.equal((await refresher(client, store).refresh()).failed, 1);
  assert.equal(store.state.manifests[0].snapshot_id, "snapshot-1");
});
