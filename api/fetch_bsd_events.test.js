"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

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
} = require("./fetch_bsd_events");

test("eventToRecord indexes season id for current-season Mongo queries", () => {
  const record = eventToRecord({ id: 1, league_id: 27, season_id: 2026, status: "finished" });
  assert.equal(record.extra.season_id, 2026);
});

test("EVENT_STATUSES excludes historical started results; live events use /events/live", () => {
  assert.deepEqual(EVENT_STATUSES, ["notstarted", "finished"]);
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
