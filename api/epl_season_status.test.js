"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { __private } = require("./epl_season_status");

const { eventSeasonStatus, parseEventDateMs } = __private;

test("parseEventDateMs parses BSD event timestamps", () => {
  assert.equal(
    new Date(parseEventDateMs("2026-05-24T15:00:00+00:00")).toISOString(),
    "2026-05-24T15:00:00.000Z"
  );
});

test("eventSeasonStatus is active when latest finished and next notstarted share season_id", () => {
  const status = eventSeasonStatus(
    [
      { payload: { id: 1, status: "finished", season_id: 337, event_date: "2026-03-01T15:00:00+00:00" } },
      { payload: { id: 2, status: "finished", season_id: 337, event_date: "2026-03-08T15:00:00+00:00" } },
      { payload: { id: 3, status: "notstarted", season_id: 337, event_date: "2026-03-15T15:00:00+00:00" } },
      { payload: { id: 4, status: "notstarted", season_id: 337, event_date: "2026-03-22T15:00:00+00:00" } },
    ],
    Date.parse("2026-03-10T12:00:00Z")
  );

  assert.equal(status.active, true);
  assert.equal(status.lastFinished.id, 2);
  assert.equal(status.nextNotStarted.id, 3);
});

test("eventSeasonStatus is inactive between seasons when season_id differs", () => {
  const status = eventSeasonStatus(
    [
      { payload: { id: 379, status: "finished", season_id: 337, event_date: "2026-05-24T15:00:00+00:00" } },
      { payload: { id: 209908, status: "notstarted", season_id: 1058, event_date: "2026-08-15T11:30:00+00:00" } },
    ],
    Date.parse("2026-06-28T12:00:00Z")
  );

  assert.equal(status.active, false);
  assert.equal(status.lastFinished.seasonId, "337");
  assert.equal(status.nextNotStarted.seasonId, "1058");
});

test("eventSeasonStatus ignores past notstarted and future finished records", () => {
  const status = eventSeasonStatus(
    [
      { payload: { id: 1, status: "notstarted", season_id: 336, event_date: "2026-01-01T15:00:00+00:00" } },
      { payload: { id: 2, status: "finished", season_id: 337, event_date: "2026-03-08T15:00:00+00:00" } },
      { payload: { id: 3, status: "notstarted", season_id: 337, event_date: "2026-03-15T15:00:00+00:00" } },
      { payload: { id: 4, status: "finished", season_id: 999, event_date: "2026-04-01T15:00:00+00:00" } },
    ],
    Date.parse("2026-03-10T12:00:00Z")
  );

  assert.equal(status.active, true);
  assert.equal(status.lastFinished.id, 2);
  assert.equal(status.nextNotStarted.id, 3);
});

test("eventSeasonStatus is inactive when either comparison event is missing", () => {
  assert.equal(
    eventSeasonStatus(
      [{ payload: { id: 1, status: "finished", season_id: 337, event_date: "2026-05-24T15:00:00+00:00" } }],
      Date.parse("2026-06-28T12:00:00Z")
    ).active,
    false
  );
  assert.equal(
    eventSeasonStatus(
      [{ payload: { id: 2, status: "notstarted", season_id: 1058, event_date: "2026-08-15T15:00:00+00:00" } }],
      Date.parse("2026-06-28T12:00:00Z")
    ).active,
    false
  );
});
