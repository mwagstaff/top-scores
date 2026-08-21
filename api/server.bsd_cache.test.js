const test = require("node:test");
const assert = require("node:assert/strict");

const redisClient = require("./redis_client");

let releaseMetadata;
let metadataCalls = 0;
let datasetCalls = 0;
let metadataShouldWait = true;
let metadataResponse = {};
let datasetResponse = {
  payload: [{ id: "fixture-1", date: "2026-08-21" }],
  updated_at: "2026-08-21T00:00:00.000Z",
};
let operationalDatasetsResponse = {};

redisClient.getOperationalDatasetMetadata = async () => {
  metadataCalls += 1;
  if (metadataShouldWait) {
    await new Promise((resolve) => {
      releaseMetadata = resolve;
    });
  }
  return metadataResponse;
};

redisClient.getOperationalDataset = async () => {
  datasetCalls += 1;
  return datasetResponse;
};

redisClient.getOperationalDatasets = async () => operationalDatasetsResponse;

const {
  __private: {
    getBsdMatchesForServing,
    hydrateOperationalStateFromRedis,
    refreshBsdMatchesCache,
    reloadOperationalStateDomainsFromRedis,
  },
} = require("./server");

test("cold BSD fixture reads await an in-flight cache refresh", async () => {
  const refreshPromise = refreshBsdMatchesCache();
  const servingPromise = getBsdMatchesForServing();
  let servingResolved = false;
  void servingPromise.then(() => {
    servingResolved = true;
  });

  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(servingResolved, false);
  assert.equal(metadataCalls, 1);

  releaseMetadata();
  await refreshPromise;
  const matches = await servingPromise;

  assert.deepEqual(matches, [{ id: "fixture-1", date: "2026-08-21" }]);
  assert.equal(metadataCalls, 1);
  assert.equal(datasetCalls, 1);
});

test("BSD cache refresh compares the canonical payload hash, not only its timestamp", async () => {
  metadataShouldWait = false;
  metadataResponse = {
    bsd_current_matches: {
      updated_at: "2026-08-21T00:00:00.000Z",
      payload_hash: "canonical-hash-2",
    },
  };
  datasetResponse = {
    payload: [{ id: "fixture-2", date: "2026-08-22" }],
    updated_at: "2026-08-21T00:00:00.000Z",
    payload_hash: "canonical-hash-2",
  };

  await refreshBsdMatchesCache();

  assert.deepEqual(await getBsdMatchesForServing(), [
    { id: "fixture-2", date: "2026-08-22" },
  ]);
  assert.equal(metadataCalls, 2);
  assert.equal(datasetCalls, 2);
});

test("operational hydration and reload cannot replace canonical fixtures with BSD aliases", async () => {
  const canonicalRecord = {
    payload: [{ id: "fixture-3", date: "2026-08-23" }],
    updated_at: "2026-08-21T01:00:00.000Z",
    payload_hash: "canonical-hash-3",
  };
  datasetResponse = canonicalRecord;
  operationalDatasetsResponse = {
    bsd_live_matches: {
      payload: [],
      updated_at: canonicalRecord.updated_at,
    },
    bsd_schedule_matches: {
      payload: [],
      updated_at: canonicalRecord.updated_at,
    },
  };

  await hydrateOperationalStateFromRedis({ skipMatchDetails: true });
  assert.deepEqual(await getBsdMatchesForServing(), canonicalRecord.payload);

  datasetResponse = null;
  operationalDatasetsResponse = {
    bsd_live_matches: {
      payload: [],
      updated_at: "2026-08-21T02:00:00.000Z",
    },
    bsd_schedule_matches: {
      payload: [],
      updated_at: "2026-08-21T02:00:00.000Z",
    },
  };

  await reloadOperationalStateDomainsFromRedis(["matches"]);
  assert.deepEqual(await getBsdMatchesForServing(), canonicalRecord.payload);
});
