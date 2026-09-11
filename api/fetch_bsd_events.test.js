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
          return candidates.map(String).filter((id) => !filter._id.$nin.includes(id))
            .slice(0, options.limit).map((id) => ({ _id: id }));
        },
      };
      throw new Error(`Unexpected dependency: ${name}`);
    },
  };
  vm.runInNewContext(fs.readFileSync(require.resolve("./fetch_bsd_events"), "utf8"), sandbox);
  return { ingest: sandbox.module.exports.ingestLeagueIncrementalEvents, writes, lookups, queries, errors };
}

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

test("failed or invalid lookups preserve cached fixtures and do not block other corrections", async () => {
  const valid = { id: 6, league_id: 12, status: "cancelled", event_date: "2026-09-09T18:45:00Z" };
  const fixture = ingestionFixture({
    candidates: [1, 2, 3, 4, 5, 6],
    lookup: (id) => {
      if (id === "1") throw new Error("HTTP 429 after retries");
      if (id === "2") throw new Error("HTTP 404");
      if (id === "3") return { ...valid, id: 99 };
      if (id === "4") return { ...valid, id: 4, event_date: null };
      if (id === "5") return { ...valid, id: 5, league_id: 40 };
      return valid;
    },
  });
  await fixture.ingest("12", Date.parse("2026-09-09T22:00:00Z"));
  assert.equal(fixture.errors.length, 5);
  assert.deepEqual(fixture.writes.map((record) => record.id), [6]);
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
