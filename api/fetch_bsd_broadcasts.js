#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

// ---------------------------------------------------------------------------
// Ingest BSD TV broadcasts into Mongo (bsd_broadcasts, one doc per event).
//
// The /broadcasts endpoint returns one row per channel-per-event. We fetch the
// full GB snapshot (the website/app are UK-only), group rows by event_id, and
// upsert one doc per event:
//
//   { _id: <event_id>, payload: { event_id, channels: [...] }, ... }
//
// Because it's a full daily snapshot, events absent from the latest pull are
// pruned so a fixture that drops all its listings doesn't keep stale channels.
//
// Run: BSD_API_KEY=... MONGODB_URI_TOP_SCORES=... node api/fetch_bsd_broadcasts.js
// ---------------------------------------------------------------------------

const bsd = require("./bsd_client");
const {
  upsertBsdRecords,
  deleteBsdRecordsNotIn,
  closeMongoConnection,
} = require("./mongo_client");

const BROADCASTS_COUNTRY_CODE = String(process.env.BSD_BROADCASTS_COUNTRY_CODE || "GB").trim();

// Groups raw broadcast rows by event_id into a Map<eventId:string, payload>,
// deduplicating channels within an event by channel name (case-insensitive).
function groupBroadcastsByEvent(rows) {
  const byEvent = new Map();
  (Array.isArray(rows) ? rows : []).forEach((row) => {
    if (!row || typeof row !== "object") return;
    const eventId = row.event_id != null ? String(row.event_id).trim() : "";
    if (!eventId) return;
    const channelName = String(row.channel_name || "").trim();
    if (!channelName) return;

    if (!byEvent.has(eventId)) {
      byEvent.set(eventId, { event_id: eventId, channels: [] });
    }
    const entry = byEvent.get(eventId);
    const dupeKey = channelName.toLowerCase();
    if (entry.channels.some((c) => c.channel_name.toLowerCase() === dupeKey)) return;
    entry.channels.push({
      channel_id: row.channel_id != null ? row.channel_id : null,
      channel_name: channelName,
      channel_link: String(row.channel_link || "").trim() || null,
    });
  });
  return byEvent;
}

// Converts the grouped map into the { id, payload, extra } records that
// upsertBsdRecords expects.
function broadcastsToUpsertRecords(byEvent) {
  return Array.from(byEvent.values()).map((payload) => ({
    id: payload.event_id,
    payload,
    extra: { event_id: payload.event_id, channel_count: payload.channels.length },
  }));
}

// Full broadcasts refresh: fetch the GB snapshot, upsert per-event docs, prune
// events no longer present. Shared by the CLI entry point and the bsd runtime.
async function refreshAllBroadcasts(options = {}) {
  const countryCode = options.countryCode || BROADCASTS_COUNTRY_CODE;
  const rows = await bsd.getBroadcasts(
    { countryCode },
    { initiator: options.initiator || "fetch_bsd_broadcasts" }
  );
  const byEvent = groupBroadcastsByEvent(rows);
  const records = broadcastsToUpsertRecords(byEvent);
  if (records.length > 0) {
    await upsertBsdRecords("bsd_broadcasts", records);
  }
  const deleted = await deleteBsdRecordsNotIn(
    "bsd_broadcasts",
    records.map((r) => r.id)
  );
  console.log(
    `[bsd] broadcasts (${countryCode}): fetched ${rows.length} rows, ` +
      `upserted ${records.length} events, pruned ${deleted}`
  );
  return { fetched: rows.length, events: records.length, pruned: deleted };
}

async function runCli() {
  await refreshAllBroadcasts();
  await closeMongoConnection();
}

if (require.main === module) {
  runCli().catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

module.exports = {
  groupBroadcastsByEvent,
  broadcastsToUpsertRecords,
  refreshAllBroadcasts,
};
