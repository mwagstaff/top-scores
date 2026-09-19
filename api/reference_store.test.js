"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { createReferenceStore } = require("./reference_store");
const { dataset } = require("./reference_test_helpers");

test("metadata-only catalogue reads skip squad payloads while normal readers receive them", async () => {
  const value = dataset();
  const queried = [];
  const store = createReferenceStore(async () => ({ collection(name) {
    return { find(filter) {
      queried.push({ name, filter });
      return { async toArray() {
        if (name === "bsd_reference_competitions") return value.manifests.map((payload) => ({ payload }));
        if (name === "bsd_reference_status") return value.statuses;
        if (name === "bsd_reference_teams") return value.rows;
        throw new Error(`Unexpected collection: ${name}`);
      } };
    } };
  } }));
  const metadata = await store.load(["1"], { includeRows: false });
  assert.deepEqual(metadata, { manifests: value.manifests, statuses: value.statuses, rows: [] });
  assert.deepEqual(queried.map((query) => query.name), ["bsd_reference_competitions", "bsd_reference_status"]);
  const full = await store.load(["1"]);
  assert.deepEqual(full, value);
  assert.deepEqual(queried.at(-1), {
    name: "bsd_reference_teams", filter: { snapshot_id: { $in: ["snapshot-1"] } },
  });
});

test("a team write failure cannot update the active competition manifest", async () => {
  let replaced = false;
  const store = createReferenceStore(async () => ({ collection(name) {
    if (name === "bsd_reference_teams") return { async insertMany() { throw new Error("disk full"); } };
    return { async replaceOne() { replaced = true; } };
  } }));
  const value = dataset();
  await assert.rejects(store.publish(value.manifests[0], [value.rows[0].payload]), /disk full/);
  assert.equal(replaced, false);
});

test("pruning excludes every active snapshot, even if older than the retention window", async () => {
  let filter;
  const store = createReferenceStore(async () => ({ collection(name) {
    if (name === "bsd_reference_competitions") return { find() { return { async toArray() { return [{ payload: { snapshot_id: "old-but-active" } }]; } }; } };
    return { async deleteMany(value) { filter = value; } };
  } }));
  await store.prune();
  assert.deepEqual(filter.snapshot_id, { $nin: ["old-but-active"] });
  assert.ok(filter.updated_at.$lt);
});

test("concurrent lease contention skips rather than starting another upstream sweep", async () => {
  const store = createReferenceStore(async () => ({ collection() { return { async updateOne() { throw Object.assign(new Error("duplicate"), { code: 11000 }); } }; } }));
  assert.equal(await store.acquireLease("second-worker"), false);
});
