"use strict";

const { getDb } = require("./mongo_client");
const { DAY_MS } = require("./reference_model");

// Immutable team-sized documents avoid Mongo's 16 MB document limit. A single
// manifest write publishes a competition only after every team has been saved.
function createReferenceStore(database = getDb) {
  async function db() {
    const value = await database();
    if (!value) throw new Error("Reference API requires MongoDB");
    return value;
  }
  return {
    async ensureIndexes() {
      const value = await db();
      await value.collection("bsd_reference_teams").createIndex({ snapshot_id: 1 });
      await value.collection("bsd_reference_teams").createIndex({ updated_at: 1 });
    },
    async acquireLease(owner, now = Date.now()) {
      const value = await db();
      try {
        const result = await value.collection("bsd_reference_control").updateOne(
          { _id: "refresh", $or: [{ expires_at: { $lte: new Date(now) } }, { owner }] },
          { $set: { owner, expires_at: new Date(now + 10 * 60_000), updated_at: new Date(now).toISOString() } },
          { upsert: true }
        );
        return result.matchedCount === 1 || result.upsertedCount === 1;
      } catch (error) {
        if (error.code === 11000) return false;
        throw error;
      }
    },
    async renewLease(owner) {
      const value = await db();
      const result = await value.collection("bsd_reference_control").updateOne(
        { _id: "refresh", owner, expires_at: { $gt: new Date() } },
        { $set: { expires_at: new Date(Date.now() + 10 * 60_000), updated_at: new Date().toISOString() } }
      );
      return result.matchedCount === 1;
    },
    async releaseLease(owner) {
      const value = await db();
      await value.collection("bsd_reference_control").deleteOne({ _id: "refresh", owner });
    },
    async saveSources(collection, records) {
      if (!records.length) return;
      const value = await db();
      await value.collection(collection).bulkWrite(records.map(({ id, payload }) => ({ updateOne: {
        filter: { _id: String(id) }, update: { $set: { payload, updated_at: new Date().toISOString() } }, upsert: true,
      } })), { ordered: false });
    },
    async publish(manifest, teams) {
      const value = await db();
      if (teams.length) {
        await value.collection("bsd_reference_teams").insertMany(teams.map((payload) => ({
          _id: `${manifest.snapshot_id}:${payload.team.id}`, snapshot_id: manifest.snapshot_id,
          payload, updated_at: manifest.published_at,
        })), { ordered: true });
      }
      await value.collection("bsd_reference_competitions").replaceOne(
        { _id: manifest.competition.id }, { _id: manifest.competition.id, payload: manifest, updated_at: manifest.published_at }, { upsert: true }
      );
    },
    async recordAttempt(competitionId, status) {
      const value = await db();
      await value.collection("bsd_reference_status").replaceOne(
        { _id: String(competitionId) }, { _id: String(competitionId), payload: status, updated_at: new Date().toISOString() }, { upsert: true }
      );
    },
    async load(competitionIds, { includeRows = true } = {}) {
      const value = await db();
      const [manifests, statuses] = await Promise.all([
        value.collection("bsd_reference_competitions").find({ _id: { $in: competitionIds } }).toArray(),
        value.collection("bsd_reference_status").find({ _id: { $in: competitionIds } }).toArray(),
      ]);
      const rows = includeRows
        ? await value.collection("bsd_reference_teams").find({ snapshot_id: { $in: manifests.map((doc) => doc.payload.snapshot_id) } }).toArray()
        : [];
      return { manifests: manifests.map((doc) => doc.payload), rows, statuses };
    },
    async prune() {
      const value = await db();
      const active = await value.collection("bsd_reference_competitions").find({}, { projection: { "payload.snapshot_id": 1 } }).toArray();
      // Keep old documents for a week, allowing readers that captured the old
      // manifest to finish. Never expire the last good snapshot during outages.
      await value.collection("bsd_reference_teams").deleteMany({
        snapshot_id: { $nin: active.map((doc) => doc.payload.snapshot_id) },
        updated_at: { $lt: new Date(Date.now() - 7 * DAY_MS).toISOString() },
      });
    },
  };
}

module.exports = { createReferenceStore };
