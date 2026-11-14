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
    bsdLineupsSetStage,
  },
} = require("./mongo_client");

// Evaluate only the Mongo expression operators used by the atomic lineup write.
function evaluateLineupExpression(value, document) {
  if (typeof value === "string" && value.startsWith("$")) return value.slice(1).split(".").reduce((v, k) => v?.[k], document);
  if (!value || typeof value !== "object" || value instanceof Date) return value;
  if ("$literal" in value) return value.$literal;
  const evaluate = v => evaluateLineupExpression(v, document);
  if ("$convert" in value) { const date = new Date(evaluate(value.$convert.input)); return Number.isFinite(+date) ? date : null; }
  if ("$cond" in value) return evaluate(value.$cond[evaluate(value.$cond[0]) ? 1 : 2]);
  if ("$or" in value) return value.$or.some(evaluate);
  if ("$and" in value) return value.$and.every(evaluate);
  if ("$eq" in value) return evaluate(value.$eq[0]) === evaluate(value.$eq[1]);
  if ("$ne" in value) return evaluate(value.$ne[0]) !== evaluate(value.$ne[1]);
  if ("$gt" in value) return evaluate(value.$gt[0]) > evaluate(value.$gt[1]);
  throw new Error("Unsupported expression");
}

test("atomic lineup writes promote confirmed data and reject delayed predictions or older corrections", () => {
  const prediction = { event_id: 42, lineup_status: "predicted", updated_at: "2026-11-14T15:00:00Z" };
  const confirmed = { event_id: 42, lineup_status: "confirmed", updated_at: "2026-11-14T14:59:00Z" };
  const newer = { ...confirmed, updated_at: "2026-11-14T15:01:00Z" };
  const merge = (existing, incoming) => evaluateLineupExpression(bsdLineupsSetStage(incoming, {}, "now").payload, { payload: existing });
  assert.deepEqual(merge(undefined, prediction), prediction);
  assert.deepEqual(merge(prediction, confirmed), confirmed);
  assert.deepEqual(merge(confirmed, prediction), confirmed);
  assert.deepEqual(merge(confirmed, newer), newer);
  assert.deepEqual(merge(newer, confirmed), newer);
  assert.deepEqual(merge(confirmed, { event_id: 42, lineup_status: "unavailable" }), confirmed);
});

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
