"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");

const {
  groupBroadcastsByEvent,
  broadcastsToUpsertRecords,
} = require("./fetch_bsd_broadcasts");

const HELPER_DIR = path.resolve(__dirname, "../.helper_files/bsd_api");
function loadRows() {
  const data = JSON.parse(fs.readFileSync(path.join(HELPER_DIR, "broadcasts.json"), "utf8"));
  return data.results;
}

test("groupBroadcastsByEvent groups rows by event_id", () => {
  const byEvent = groupBroadcastsByEvent(loadRows());
  // 3 distinct events with named channels (event 500 has only a blank channel).
  assert.deepEqual([...byEvent.keys()].sort(), ["363", "9835"]);
  assert.equal(byEvent.get("9835").channels.length, 2);
  assert.equal(byEvent.get("363").channels.length, 2);
});

test("groupBroadcastsByEvent dedupes channels within an event by name", () => {
  const byEvent = groupBroadcastsByEvent(loadRows());
  const names = byEvent.get("363").channels.map((c) => c.channel_name);
  // "Sky Sports Premier League" appears twice in the fixture — kept once.
  assert.deepEqual(names, ["NOW TV UK", "Sky Sports Premier League"]);
});

test("groupBroadcastsByEvent drops rows with no event_id or no channel name", () => {
  const byEvent = groupBroadcastsByEvent([
    { event_id: null, channel_name: "Orphan" },
    { event_id: 7, channel_name: "" },
    { event_id: 7, channel_name: "Valid", channel_id: 3, channel_link: "x" },
  ]);
  assert.deepEqual([...byEvent.keys()], ["7"]);
  assert.equal(byEvent.get("7").channels.length, 1);
  assert.deepEqual(byEvent.get("7").channels[0], {
    channel_id: 3,
    channel_name: "Valid",
    channel_link: "x",
  });
});

test("groupBroadcastsByEvent normalises a blank channel_link to null", () => {
  const byEvent = groupBroadcastsByEvent(loadRows());
  const sky = byEvent.get("363").channels.find((c) => c.channel_name === "NOW TV UK");
  assert.equal(sky.channel_link, null);
  const dazn = byEvent.get("9835").channels.find((c) => c.channel_name === "DAZN UK");
  assert.equal(dazn.channel_link, "https://dazn.prf.hn/click/camref:1110l7JEj");
});

test("broadcastsToUpsertRecords builds id/payload/extra records", () => {
  const byEvent = groupBroadcastsByEvent(loadRows());
  const records = broadcastsToUpsertRecords(byEvent);
  const rec = records.find((r) => r.id === "9835");
  assert.ok(rec);
  assert.equal(rec.payload.event_id, "9835");
  assert.equal(rec.extra.event_id, "9835");
  assert.equal(rec.extra.channel_count, 2);
  assert.equal(rec.payload.channels.length, 2);
});

test("groupBroadcastsByEvent handles empty / non-array input", () => {
  assert.equal(groupBroadcastsByEvent([]).size, 0);
  assert.equal(groupBroadcastsByEvent(null).size, 0);
  assert.equal(groupBroadcastsByEvent(undefined).size, 0);
});
