"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  utcDateTimeToZonedDateTime,
  zonedDateTimeToUtcMs,
} = require("./match_time");

test("utcDateTimeToZonedDateTime converts summer UTC kickoffs to Europe/London", () => {
  assert.deepEqual(
    utcDateTimeToZonedDateTime("2026-06-17", "20:00", "Europe/London"),
    { date: "2026-06-17", time: "21:00" }
  );
});

test("utcDateTimeToZonedDateTime moves late summer UTC kickoffs onto the next London date", () => {
  assert.deepEqual(
    utcDateTimeToZonedDateTime("2026-06-17", "23:00", "Europe/London"),
    { date: "2026-06-18", time: "00:00" }
  );
});

test("utcDateTimeToZonedDateTime leaves winter UTC kickoffs unchanged for London", () => {
  assert.deepEqual(
    utcDateTimeToZonedDateTime("2026-12-17", "20:00", "Europe/London"),
    { date: "2026-12-17", time: "20:00" }
  );
});

test("zonedDateTimeToUtcMs parses BST display kickoffs as UTC instants", () => {
  assert.equal(
    new Date(zonedDateTimeToUtcMs("2026-06-17", "21:00", "Europe/London")).toISOString(),
    "2026-06-17T20:00:00.000Z"
  );
});

test("zonedDateTimeToUtcMs parses winter London kickoffs without DST offset", () => {
  assert.equal(
    new Date(zonedDateTimeToUtcMs("2026-12-17", "20:00", "Europe/London")).toISOString(),
    "2026-12-17T20:00:00.000Z"
  );
});
