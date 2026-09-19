"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const {
  EVENT_STATUSES,
  INCREMENTAL_FINISHED_DAYS,
  RECENT_FINISHED_DETAIL_WINDOW_MS,
  RECENT_FINISHED_DETAIL_REFRESH_MS,
  hasUnknownOutsideTimelineCardIncident,
  eventToRecord,
  isRecentFinishedEvent,
  needsRecentFinishedDetailRefresh,
  selectIncrementalEvents,
  usableHydratedVenueIds,
  isPlayed,
} = require("./fetch_bsd_events");

function ingestionFixture({ candidates = [], upcoming = [], lookup } = {}) {
  const writes = [];
  const deleted = [];
  const lookups = [];
  const queries = [];
  const errors = [];
  const sandbox = {
    module: { exports: {} },
    process: { env: {} },
    console: { log() {}, error(message) { errors.push(message); } },
    require(name) {
      if (name === "./bsd_client") return {
        async getEvents({ status }) { return status === "notstarted" ? upcoming : []; },
        async getEvent(id, options) {
          assert.equal(options.query?.limit, undefined, "BSD detail endpoints reject pagination parameters");
          lookups.push(id);
          return lookup(id);
        },
      };
      if (name === "./bsd_config") return { BSD_LEAGUE_ALLOWLIST: ["12"] };
      if (name === "./mongo_client") return {
        async upsertBsdRecords(collection, records) {
          assert.equal(collection, "bsd_events");
          writes.push(...records);
        },
        async getBsdRecords(collection, filter, options) {
          assert.equal(collection, "bsd_events");
          queries.push(JSON.parse(JSON.stringify({ filter, options })));
          return candidates.map(String).filter((id) => (
            !filter._id.$nin.includes(id) && !deleted.includes(id)
          ))
            .slice(0, options.limit).map((id) => ({ _id: id }));
        },
        async deleteBsdRecord(collection, id) {
          assert.equal(collection, "bsd_events");
          deleted.push(String(id));
          return true;
        },
      };
      throw new Error(`Unexpected dependency: ${name}`);
    },
  };
  vm.runInNewContext(fs.readFileSync(require.resolve("./fetch_bsd_events"), "utf8"), sandbox);
  return {
    ingest: sandbox.module.exports.ingestLeagueIncrementalEvents,
    writes,
    deleted,
    lookups,
    queries,
    errors,
  };
}

function detailHydrationFixture(incidentDocs = []) {
  const queries = [];
  const requests = [];
  const sandbox = {
    module: { exports: {} },
    process: { env: {} },
    console: { log() {}, error() {} },
    require(name) {
      if (name === "./bsd_client") return {
        async getIncidents(id) { requests.push(["incidents", id]); return { event_id: id, incidents: [] }; },
        async getLineups(id) { requests.push(["lineups", id]); return { event_id: id }; },
      };
      if (name === "./bsd_config") return { BSD_LEAGUE_ALLOWLIST: ["12"] };
      if (name === "./mongo_client") return {
        async getBsdRecords(collection, filter, options) {
          queries.push(JSON.parse(JSON.stringify({ collection, filter, options })));
          return incidentDocs.filter((doc) => filter._id.$in.includes(String(doc._id)));
        },
        async upsertBsdRecord() {},
      };
      throw new Error(`Unexpected dependency: ${name}`);
    },
  };
  vm.runInNewContext(fs.readFileSync(require.resolve("./fetch_bsd_events"), "utf8"), sandbox);
  return { hydrate: sandbox.module.exports.hydrateMissingDetails, queries, requests };
}

test("detail hydration reads only the current played events while preserving settle and stale-card refreshes", async () => {
  const nowMs = Date.parse("2026-09-19T18:00:00Z");
  const recentDate = new Date(nowMs - 60 * 60 * 1000).toISOString();
  const staleDate = new Date(nowMs - RECENT_FINISHED_DETAIL_REFRESH_MS - 1_000).toISOString();
  const fixture = detailHydrationFixture([
    { _id: "1", updated_at: new Date(nowMs).toISOString(), payload: { incidents: [] } },
    { _id: "2", updated_at: staleDate, payload: { incidents: [] } },
    { _id: "3", updated_at: staleDate, payload: { incidents: [] } },
    { _id: "4", updated_at: staleDate, payload: { incidents: [{ type: "card", minute: -1, player: "Unknown" }] } },
    { _id: "unrelated-history", payload: { incidents: [{ type: "card", minute: -1, player: "Unknown" }] } },
  ]);
  await fixture.hydrate([
    { id: 1, status: "finished", event_date: recentDate },
    { id: 2, status: "finished", event_date: recentDate },
    { id: 3, status: "finished", event_date: "2026-01-01T15:00:00Z" },
    { id: 4, status: "finished", event_date: "2026-01-01T15:00:00Z" },
    { id: 5, status: "finished", event_date: recentDate },
    { id: 6, status: "notstarted", event_date: recentDate },
    { id: 7, status: "cancelled", event_date: recentDate },
  ], nowMs);
  assert.deepEqual(fixture.queries, [{
    collection: "bsd_incidents",
    filter: { _id: { $in: ["1", "2", "3", "4", "5"] } },
    options: { projection: {
      _id: 1, updated_at: 1, "payload.incidents.type": 1,
      "payload.incidents.minute": 1, "payload.incidents.player": 1,
    } },
  }]);
  assert.deepEqual(fixture.requests, [
    ["incidents", 2], ["lineups", 2], ["incidents", 5], ["lineups", 5],
    ["incidents", 4], ["lineups", 4],
  ]);
});

test("detail hydration skips Mongo entirely when the refresh has no played events", async () => {
  const fixture = detailHydrationFixture();
  await fixture.hydrate([{ id: 1, status: "notstarted" }, { id: 2, status: "postponed" }]);
  assert.deepEqual(fixture.queries, []);
  assert.deepEqual(fixture.requests, []);
});

test("incremental ingestion refreshes withdrawn Wolves fixtures while preserving the replacement", async () => {
  const replacement = {
    id: 601933, league_id: 12, home_team: "Wolverhampton", away_team: "Portsmouth",
    status: "notstarted", event_date: "2026-10-20T18:45:00+00:00",
  };
  const fixture = ingestionFixture({
    upcoming: [replacement], candidates: [214044, 601853],
    lookup: (id) => ({
      ...replacement, id: Number(id),
      status: id === "214044" ? "cancelled" : "postponed",
      event_date: id === "214044" ? "2026-09-09T18:45:00+00:00" : "2026-09-16T18:45:00+00:00",
    }),
  });
  const events = await fixture.ingest("12", Date.parse("2026-09-09T22:00:00Z"));
  assert.deepEqual(fixture.lookups, ["214044", "601853"]);
  assert.equal(events.length, 3);
  assert.deepEqual(fixture.writes.map((record) => [record.id, record.extra.status]), [
    [601933, "notstarted"], [214044, "cancelled"], [601853, "postponed"],
  ]);
  assert.equal(fixture.writes[0].payload.event_date, replacement.event_date);
  assert.equal(fixture.writes[1].payload.status, "cancelled");
  assert.equal(fixture.writes[1].extra.event_date, "2026-09-09T18:45:00+00:00");
});

test("reconciliation limits queries to stale nearby scheduled fixtures absent from the fetched lists", async () => {
  const fixture = ingestionFixture({ upcoming: [{ id: 601933, status: "notstarted" }] });
  await fixture.ingest("12", Date.parse("2026-09-09T22:00:00Z"));
  assert.deepEqual(fixture.queries, [{
    filter: {
      league_id: { $in: ["12", 12] }, _id: { $nin: ["601933"] },
      event_date: { $gte: "2026-09-02", $lt: "2026-10-10" },
      $or: [
        { status: "notstarted", updated_at: { $lte: "2026-09-09T21:45:00.000Z" } },
        { status: "postponed", updated_at: { $lte: "2026-09-09T16:00:00.000Z" } },
      ],
    },
    options: { projection: { _id: 1 }, sort: { updated_at: 1, _id: 1 }, limit: 20 },
  }]);
});

test("absence from capped lists never cancels a valid fixture and same-ID rescheduling is persisted", async () => {
  const fixture = ingestionFixture({
    candidates: [1, 2],
    lookup: (id) => ({
      id: Number(id), league_id: 12, status: "notstarted",
      event_date: id === "1" ? "2026-09-10T18:45:00Z" : "2026-11-20T19:45:00Z",
    }),
  });
  await fixture.ingest("12", Date.parse("2026-09-09T22:00:00Z"));
  assert.deepEqual(fixture.writes.map((record) => [record.extra.status, record.extra.event_date]), [
    ["notstarted", "2026-09-10T18:45:00Z"], ["notstarted", "2026-11-20T19:45:00Z"],
  ]);
});

test("404 lookups remove stale fixtures while other failures preserve them", async () => {
  const valid = { id: 6, league_id: 12, status: "cancelled", event_date: "2026-09-09T18:45:00Z" };
  const fixture = ingestionFixture({
    candidates: [1, 2, 3, 4, 5, 6],
    lookup: (id) => {
      if (id === "1") throw new Error("HTTP 429 after retries");
      if (id === "2") {
        const error = new Error("HTTP 404");
        error.statusCode = 404;
        error.code = "HTTP_404";
        throw error;
      }
      if (id === "3") return { ...valid, id: 99 };
      if (id === "4") return { ...valid, id: 4, event_date: null };
      if (id === "5") return { ...valid, id: 5, league_id: 40 };
      return valid;
    },
  });
  await fixture.ingest("12", Date.parse("2026-09-09T22:00:00Z"));
  assert.equal(fixture.errors.length, 4);
  assert.deepEqual(fixture.deleted, ["2"]);
  assert.deepEqual(fixture.writes.map((record) => record.id), [6]);

  await fixture.ingest("12", Date.parse("2026-09-10T23:00:00Z"));
  assert.equal(fixture.lookups.filter((id) => id === "2").length, 1);
});

test("cancelled and postponed fixtures do not trigger incidents or lineup hydration", () => {
  for (const status of ["notstarted", "postponed", "cancelled", "canceled", "void"]) {
    assert.equal(isPlayed({ status }), false, status);
  }
  assert.equal(isPlayed({ status: "finished" }), true);
  assert.equal(isPlayed({ status: "started" }), true);
});

test("a full batch of failed lookups cannot starve the next cancellation", async () => {
  const nowMs = Date.parse("2026-09-09T22:00:00Z");
  const fixture = ingestionFixture({
    candidates: Array.from({ length: 21 }, (_, index) => index + 1),
    lookup: (id) => {
      if (id !== "21") throw new Error("HTTP 404");
      return { id: 21, league_id: 12, status: "cancelled", event_date: "2026-09-09T18:45:00Z" };
    },
  });
  await fixture.ingest("12", nowMs);
  assert.equal(fixture.lookups.length, 20);
  assert.equal(fixture.writes.length, 0);
  await fixture.ingest("12", nowMs + 15 * 60 * 1000);
  assert.equal(fixture.lookups.length, 21);
  assert.deepEqual(fixture.writes.map((record) => record.id), [21]);
  await fixture.ingest("12", nowMs + 60 * 60 * 1000);
  assert.equal(fixture.lookups.length, 41, "failed lookups become eligible after cooldown");
});

test("eventToRecord indexes season and venue ids for current-season Mongo queries", () => {
  const record = eventToRecord({
    id: 1,
    league_id: 27,
    season_id: 2026,
    venue_id: 273,
    status: "finished",
  });
  assert.equal(record.extra.season_id, 2026);
  assert.equal(record.extra.venue_id, 273);
});

test("EVENT_STATUSES excludes historical started results; live events use /events/live", () => {
  assert.deepEqual(EVENT_STATUSES, ["notstarted", "finished"]);
});

test("usableHydratedVenueIds excludes incomplete venue cache records", () => {
  assert.deepEqual(
    [...usableHydratedVenueIds([
      { _id: "7", payload: { name: "Stadium of Light" } },
      { _id: "9", payload: null },
      { _id: "198", payload: { name: "  " } },
      { _id: "2", payload: { name: "Vitality Stadium" } },
    ])],
    ["7", "2"]
  );
});

test("isRecentFinishedEvent retains only finished events inside the incremental window", () => {
  const nowMs = Date.parse("2026-08-14T12:00:00Z");
  const insideWindow = new Date(
    nowMs - (INCREMENTAL_FINISHED_DAYS * 24 * 60 * 60 * 1000) + 1_000
  ).toISOString();
  const outsideWindow = new Date(
    nowMs - (INCREMENTAL_FINISHED_DAYS * 24 * 60 * 60 * 1000) - 1_000
  ).toISOString();

  assert.equal(isRecentFinishedEvent({ status: "finished", event_date: insideWindow }, nowMs), true);
  assert.equal(isRecentFinishedEvent({ status: "finished", event_date: outsideWindow }, nowMs), false);
  assert.equal(isRecentFinishedEvent({ status: "notstarted", event_date: insideWindow }, nowMs), false);
  assert.equal(isRecentFinishedEvent({ status: "finished", event_date: null }, nowMs), false);
});

test("selectIncrementalEvents preserves the newest finished event outside the recent window", () => {
  const nowMs = Date.parse("2026-08-14T12:00:00Z");
  const events = [
    { id: 1, status: "finished", event_date: "2026-05-01T12:00:00Z" },
    { id: 2, status: "finished", event_date: "2026-05-24T12:00:00Z" },
  ];

  assert.deepEqual(selectIncrementalEvents(events, nowMs), [events[1]]);
});

test("needsRecentFinishedDetailRefresh revisits recent results after the settle interval", () => {
  const nowMs = Date.parse("2026-08-15T18:00:00Z");
  const recentEvent = {
    status: "finished",
    event_date: new Date(nowMs - RECENT_FINISHED_DETAIL_WINDOW_MS + 1_000).toISOString(),
  };
  const staleIncidentDoc = {
    updated_at: new Date(nowMs - RECENT_FINISHED_DETAIL_REFRESH_MS - 1_000).toISOString(),
  };
  const freshIncidentDoc = {
    updated_at: new Date(nowMs - RECENT_FINISHED_DETAIL_REFRESH_MS + 1_000).toISOString(),
  };

  assert.equal(needsRecentFinishedDetailRefresh(recentEvent, staleIncidentDoc, nowMs), true);
  assert.equal(needsRecentFinishedDetailRefresh(recentEvent, freshIncidentDoc, nowMs), false);
  assert.equal(
    needsRecentFinishedDetailRefresh(
      { status: "finished", event_date: new Date(nowMs - RECENT_FINISHED_DETAIL_WINDOW_MS - 1).toISOString() },
      staleIncidentDoc,
      nowMs
    ),
    false
  );
  assert.equal(
    needsRecentFinishedDetailRefresh({ ...recentEvent, status: "notstarted" }, staleIncidentDoc, nowMs),
    false
  );
});

test("hasUnknownOutsideTimelineCardIncident detects stale manager card payloads", () => {
  assert.equal(
    hasUnknownOutsideTimelineCardIncident({
      payload: {
        incidents: [
          { type: "card", minute: -5, player: "Unknown", card_type: "yellow" },
        ],
      },
    }),
    true
  );

  assert.equal(
    hasUnknownOutsideTimelineCardIncident({
      payload: {
        incidents: [
          { type: "card", minute: -5, player: "J. Nagelsmann", card_type: "yellow" },
          { type: "card", minute: 33, player: "Player Name", card_type: "yellow" },
        ],
      },
    }),
    false
  );
});
