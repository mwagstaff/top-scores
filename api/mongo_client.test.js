"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    hasBsdEventRoundName,
    shouldPreserveExistingBsdEventRoundName,
    shouldPreserveExistingBsdPreviousLegId,
    shouldMergeExistingBsdEventMetadata,
    bsdUpsertSetStage,
  },
} = require("./mongo_client");

test("hasBsdEventRoundName detects meaningful round names", () => {
  assert.equal(hasBsdEventRoundName({ round_name: "Round of 32" }), true);
  assert.equal(hasBsdEventRoundName({ round_name: "  " }), false);
  assert.equal(hasBsdEventRoundName({}), false);
  assert.equal(hasBsdEventRoundName(null), false);
});

test("shouldPreserveExistingBsdEventRoundName only applies to bsd_events without incoming round_name", () => {
  assert.equal(
    shouldPreserveExistingBsdEventRoundName("bsd_events", { id: 8359, status: "halftime" }),
    true
  );
  assert.equal(
    shouldPreserveExistingBsdEventRoundName("bsd_events", { id: 8359, round_name: "Round of 32" }),
    false
  );
  assert.equal(
    shouldPreserveExistingBsdEventRoundName("bsd_lineups", { id: 8359 }),
    false
  );
});

test("previous_leg_event_id is preserved only when a reduced event omits the field", () => {
  assert.equal(
    shouldPreserveExistingBsdPreviousLegId("bsd_events", { id: 224835, status: "inprogress" }),
    true
  );
  assert.equal(
    shouldPreserveExistingBsdPreviousLegId(
      "bsd_events",
      { id: 224835, previous_leg_event_id: 224834 }
    ),
    false
  );
  assert.equal(
    shouldPreserveExistingBsdPreviousLegId(
      "bsd_events",
      { id: 224834, previous_leg_event_id: null }
    ),
    false
  );
  assert.equal(shouldPreserveExistingBsdPreviousLegId("bsd_lineups", { id: 224835 }), false);
});

test("bsdUpsertSetStage preserves existing round_name when a live event payload omits it", () => {
  const incomingPayload = {
    id: 8359,
    status: "halftime",
    home_score: 0,
    away_score: 0,
    previous_leg_event_id: null,
  };
  const stage = bsdUpsertSetStage(
    "bsd_events",
    incomingPayload,
    { status: "halftime", league_id: 27 },
    "2026-06-28T20:50:00.000Z"
  );

  assert.deepEqual(stage.payload, {
    $cond: [
      {
        $and: [
          { $ne: ["$payload.round_name", null] },
          { $ne: ["$payload.round_name", ""] },
        ],
      },
      {
        $mergeObjects: [
          { $literal: incomingPayload },
          { round_name: "$payload.round_name" },
        ],
      },
      { $literal: incomingPayload },
    ],
  });
  assert.deepEqual(stage.status, { $literal: "halftime" });
  assert.deepEqual(stage.league_id, { $literal: 27 });
});

test("bsdUpsertSetStage replaces payload normally when incoming event has round_name", () => {
  const incomingPayload = {
    id: 8360,
    status: "notstarted",
    round_name: "Round of 32",
    previous_leg_event_id: null,
  };
  const stage = bsdUpsertSetStage("bsd_events", incomingPayload, {}, "2026-06-28T20:50:00.000Z");

  assert.deepEqual(stage.payload, { $literal: incomingPayload });
});

test("bsdUpsertSetStage preserves a linked previous leg across reduced live payloads", () => {
  const incomingPayload = {
    id: 224835,
    status: "inprogress",
    round_name: "Playoff round",
    home_score: 4,
    away_score: 1,
  };
  const stage = bsdUpsertSetStage(
    "bsd_events",
    incomingPayload,
    { status: "inprogress", league_id: 7 },
    "2026-08-25T20:50:00.000Z"
  );

  assert.equal(shouldMergeExistingBsdEventMetadata("bsd_events", incomingPayload), true);
  assert.deepEqual(stage.payload, {
    $mergeObjects: [
      { $literal: incomingPayload },
      {
        previous_leg_event_id: {
          $ifNull: ["$payload.previous_leg_event_id", null],
        },
      },
    ],
  });
});
