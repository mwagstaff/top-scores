"use strict";

const crypto = require("crypto");
const { projectBsdMatches } = require("./bsd_adapter");
const {
  getOperationalDatasetMetadata,
  saveOperationalDataset,
} = require("./mongo_client");

const BSD_CURRENT_MATCHES_DATASET = "bsd_current_matches";

function projectionHash(payload) {
  return crypto.createHash("sha1").update(JSON.stringify(payload)).digest("hex");
}

async function publishBsdCurrentMatchesProjection(reason, options = {}) {
  const matches = await projectBsdMatches();
  const payloadHash = projectionHash(matches);
  let existingHash = options.knownHash || null;
  if (!existingHash) {
    const metadata = await getOperationalDatasetMetadata([BSD_CURRENT_MATCHES_DATASET]);
    existingHash = metadata && metadata[BSD_CURRENT_MATCHES_DATASET]
      ? metadata[BSD_CURRENT_MATCHES_DATASET].payload_hash || null
      : null;
  }
  if (payloadHash === existingHash) {
    return { changed: false, matches, payload_hash: payloadHash };
  }
  await saveOperationalDataset({
    name: BSD_CURRENT_MATCHES_DATASET,
    updated_at: new Date().toISOString(),
    source: options.source || `bsd_poller:${reason}`,
    payload: matches,
    payload_count: matches.length,
    payload_hash: payloadHash,
  });
  return { changed: true, matches, payload_hash: payloadHash };
}

module.exports = {
  BSD_CURRENT_MATCHES_DATASET,
  projectionHash,
  publishBsdCurrentMatchesProjection,
};
