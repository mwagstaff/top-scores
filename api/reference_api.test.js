"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("http");
const express = require("express");
const Ajv = require("ajv/dist/2020");
const addFormats = require("ajv-formats");
const { createReferenceApp } = require("./reference_api");
const { createReferenceService } = require("./reference_service");
const { schemas, operations, openApi } = require("./reference_contract");
const { dataset, memoryStore, time } = require("./reference_test_helpers");

const ajv = new Ajv({ strict: false, allErrors: true });
addFormats(ajv);
ajv.addSchema({ $id: "https://top-scores.test/contract", components: { schemas } });
function validate(model, payload) {
  const validator = ajv.getSchema(`https://top-scores.test/contract#/components/schemas/${model}`);
  assert.equal(validator(payload), true, JSON.stringify(validator.errors));
}
async function harness(t, options = {}) {
  const store = options.store || memoryStore(dataset());
  const service = options.service || createReferenceService({ store, competitionIds: ["1", "27"], now: () => Date.parse(time) });
  // Isolated router only: never load server.js, start pollers or use live storage.
  const referenceApp = createReferenceApp({ service, rateLimit: 10000, now: () => Date.parse(time), ...options });
  const root = express();
  root.get("/existing-endpoint", (_req, res) => res.json({ existing: true }));
  root.use(options.prefix || "/", referenceApp);
  const server = http.createServer(root);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise((resolve) => { server.closeAllConnections(); server.close(resolve); }));
  const base = `http://127.0.0.1:${server.address().port}${options.prefix || ""}`;
  return { base, store, service, get: (path, init) => fetch(`${base}${path}`, init) };
}

test("every documented operation returns a response matching its published schema", async (t) => {
  const { get } = await harness(t);
  for (const operation of operations) {
    const id = operation.path.startsWith("/players") ? "363" : operation.path.startsWith("/teams") ? "19" : "1";
    const response = await get(operation.path.replace("{id}", id));
    assert.equal(response.status, 200, operation.path);
    validate(operation.responseModel, await response.json());
  }
});

test("game export includes colours, full profiles, rating scale and consistent snapshot identity", async (t) => {
  const { get } = await harness(t);
  const response = await get("/competitions/1/export");
  const body = await response.json();
  assert.equal(body.meta.snapshot_id, "snapshot-1");
  assert.equal(body.data.teams[0].team.colours.primary, "#FFFFFF");
  assert.equal(body.data.teams[0].squad.players[0].player.rating, 78);
  assert.equal(body.data.coverage.snapshot_id, body.meta.snapshot_id);
  assert.equal(response.headers.get("access-control-allow-origin"), "*");
  const conditional = await get("/competitions/1/export", { cache: "no-cache", headers: { "If-None-Match": response.headers.get("etag") } });
  assert.equal(conditional.status, 304);
  assert.equal(await conditional.text(), "");
});

test("invalid IDs, historical seasons, repeated/unknown filters and version drift fail clearly", async (t) => {
  const { get } = await harness(t);
  for (const url of ["/players/nope", "/players?limit=201", "/players?limit=0", "/players?offset=-1", "/players?offset=1.2", "/players?limit=1&limit=2", "/players?team_id[x]=19", "/players?unexpected=true", "/competitions/1/teams?season_id=99"]) {
    const response = await get(url);
    assert.equal(response.status, 400, url);
    validate("Error", await response.json());
  }
  assert.equal((await get("/players?catalogue_version=old")).status, 409);
  assert.equal((await get("/competitions/999")).status, 404);
  assert.equal((await get("/players/999")).status, 404);
  assert.equal((await get("/competitions/27")).status, 503);
});

test("search and paging return stable IDs with continuation metadata", async (t) => {
  const { get } = await harness(t);
  const first = await (await get("/players?team_id=19&search=rOdOn&limit=1")).json();
  assert.deepEqual(first.data.map((player) => player.id), ["363"]);
  assert.equal(first.pagination.next_offset, null);
  const next = await (await get(`/players?offset=1&catalogue_version=${first.meta.catalogue_version}`)).json();
  assert.equal(next.data.length, 0);
  assert.equal(next.pagination.total, 1);
  const teams = await (await get("/teams?search=LEEDS")).json();
  assert.equal(teams.data[0].id, "19");
});

test("coverage lists uncollected competitions and missing ratings/colours", async (t) => {
  const value = dataset();
  value.rows[0].payload.squad.players[0].player.rating = null;
  value.rows[0].payload.team.colours = { primary: null, secondary: null, source: "unavailable", is_fallback: true };
  const { get } = await harness(t, { store: memoryStore(value) });
  const body = await (await get("/coverage")).json();
  assert.deepEqual(body.data[0].missing_rating_player_ids, ["363"]);
  assert.deepEqual(body.data[0].missing_colour_team_ids, ["19"]);
  assert.equal(body.data[1].status, "not_collected");
});

test("empty database returns coverage, while data endpoints return 503 without calling upstream", async (t) => {
  const { get } = await harness(t, { store: memoryStore() });
  assert.equal((await get("/coverage")).status, 200);
  const response = await get("/players");
  assert.equal(response.status, 503);
  assert.equal(response.headers.get("retry-after"), "60");
});

test("project keys can lock down all data and leave docs public", async (t) => {
  const { get } = await harness(t, { keys: ["game-secret"] });
  assert.equal((await get("/players")).status, 401);
  assert.equal((await get("/players", { headers: { Authorization: "Bearer wrong" } })).status, 401);
  assert.equal((await get("/players", { headers: { Authorization: "Bearer game-secret" } })).status, 200);
  const contract = await (await get("/openapi.json")).json();
  assert.deepEqual(contract.security, [{ projectKey: [] }]);
  assert.equal((await get("/docs/quickstart.md")).status, 200);
});

test("rate limits cannot be bypassed with spoofed forwarded IPs and apply extra export cost", async (t) => {
  let now = Date.parse(time);
  const { get } = await harness(t, { rateLimit: 10, now: () => now });
  assert.equal((await get("/competitions/1/export")).status, 200);
  const blocked = await get("/players", { headers: { "X-Forwarded-For": "1.2.3.4" } });
  assert.equal(blocked.status, 429);
  assert.equal(blocked.headers.get("retry-after"), "60");
  now += 60_000;
  assert.equal((await get("/players")).status, 200);
});

test("docs are generated, Swagger assets are local and modifying methods are rejected", async (t) => {
  const { get } = await harness(t);
  const contract = await (await get("/openapi.json")).json();
  assert.equal(contract.openapi, "3.1.0");
  assert.deepEqual(contract.security, []);
  assert.equal(contract.components.schemas.Player.properties.rating.maximum, 200);
  const markdown = await (await get("/docs/reference.md")).text();
  for (const operation of operations) assert.ok(markdown.includes(operation.operationId));
  assert.ok((await (await get("/docs/quickstart.md")).text()).includes("snapshot_id"));
  assert.ok((await (await get("/llms.txt")).text()).includes("docs/reference.md"));
  assert.equal((await get("/docs/assets/swagger-ui-bundle.js")).status, 200);
  assert.ok((await (await get("/docs/")).text()).includes("assets/swagger-ui.css"));
  const redirect = await get("/docs", { redirect: "manual" });
  assert.equal(redirect.headers.get("location"), "docs/");
  assert.equal((await get("/players", { method: "POST" })).status, 405);
  assert.equal((await get("/players", { method: "OPTIONS" })).status, 204);
});

test("OpenAPI includes only read operations and unique identifiers", () => {
  const contract = openApi(".");
  assert.equal(new Set(operations.map((value) => value.operationId)).size, operations.length);
  for (const value of Object.values(contract.paths)) assert.deepEqual(Object.keys(value), ["get"]);
});

test("mounted API and documentation preserve the deployment prefix and existing routes", async (t) => {
  const { base, get } = await harness(t, { prefix: "/top-scores/api/v1/reference" });
  const redirected = await get("/docs");
  assert.equal(redirected.url, `${base}/docs/`);
  const spec = await (await get("/openapi.json")).json();
  assert.equal(new URL(spec.servers[0].url, `${base}/openapi.json`).href, `${base}/`);
  assert.equal((await get("/docs/assets/swagger-ui.css")).status, 200);
  assert.equal((await get("/players/363")).status, 200);
  assert.deepEqual(await (await fetch(`${new URL(base).origin}/existing-endpoint`)).json(), { existing: true });
});
