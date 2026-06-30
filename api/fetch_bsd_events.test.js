"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  EVENT_STATUSES,
  hasUnknownOutsideTimelineCardIncident,
} = require("./fetch_bsd_events");

test("EVENT_STATUSES includes started so active BSD matches can restore rich event metadata", () => {
  assert.deepEqual(EVENT_STATUSES, ["notstarted", "started", "finished"]);
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
