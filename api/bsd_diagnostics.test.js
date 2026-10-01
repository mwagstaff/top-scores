"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { createDiagnostics } = require("./bsd_diagnostics");
const { installTimestampedConsole } = require("./runtime_logging");

test("timestamps preserve formatting and prefix every line without double installation", () => {
  const lines = [];
  const target = Object.fromEntries(["log", "info", "warn", "error", "debug", "trace"].map((key) => [key, (value) => lines.push(value)]));
  installTimestampedConsole(target, () => new Date("2026-09-30T17:47:00Z"));
  installTimestampedConsole(target);
  target.error("failed %s\nnext", "request");
  assert.equal(lines[0], `2026-09-30T17:47:00.000Z [pid=${process.pid}] failed request\n2026-09-30T17:47:00.000Z [pid=${process.pid}] next`);
});

test("diagnostics correlate overlapping jobs, record failures and release active state", async () => {
  const records = [];
  let heapUsed = 100;
  let tick = 0;
  const diagnostics = createDiagnostics({ write: (r) => records.push(r),
    now: () => tick, memory: () => ({ heapUsed, rss: heapUsed * 2 }) });
  diagnostics.start();
  let release;
  const pending = diagnostics.run("events", () => new Promise((resolve) => { release = resolve; }));
  const error = new Error("original failure");
  await assert.rejects(diagnostics.run("projection", async () => {
    await diagnostics.run("mongo_read", async () => {
      tick = 2500;
      heapUsed = 200;
      diagnostics.sample();
      throw error;
    }, { collection: "bsd_events" }, { quiet: true });
  }), (e) => e === error);
  const sample = records.find((r) => r.event === "sample" && r.active.length === 3);
  assert.ok(sample);
  const child = sample.active.find((r) => r.name === "mongo_read");
  assert.equal(child.parentId, sample.active.find((r) => r.name === "projection").id);
  release(42);
  assert.equal(await pending, 42);
  diagnostics.sample();
  assert.deepEqual(records.at(-1).active, []);
  assert.equal(records.find((r) => r.event === "end" && r.name === "mongo_read").status, "rejected");
  diagnostics.stop();
});

test("quiet reads log large counts, suppress small reads, and request logs exclude secrets", async () => {
  const records = [];
  const diagnostics = createDiagnostics({ write: (r) => records.push(r) });
  diagnostics.start();
  await diagnostics.run("small", async () => [1], {}, { quiet: true });
  await diagnostics.run("large", async () => new Array(1000), {}, { quiet: true });
  assert.equal(records.some((r) => r.name === "small"), false);
  assert.equal(records.find((r) => r.name === "large").count, 1000);
  await diagnostics.run("catalogue", async () => diagnostics.request({
    url: "https://sports.bzzoiro.com/api/v2/teams/?offset=200&token=SECRET",
    durationMs: 2500, responseBytes: 42, statusCode: 200, attempt: 2,
    headers: { Authorization: "SECRET" }, body: "SECRET",
  }));
  const request = records.find((r) => r.event === "request");
  assert.equal(request.operationId, records.find((r) => r.name === "catalogue").id);
  assert.deepEqual(request.query, { offset: "200" });
  assert.equal(JSON.stringify(records).includes("SECRET"), false);
  diagnostics.stop();
});

test("disabled diagnostics and broken log sinks preserve results", async () => {
  const diagnostics = createDiagnostics({ write: () => { throw new Error("sink unavailable"); } });
  assert.equal(await diagnostics.run("disabled", async () => 1), 1);
  diagnostics.start();
  assert.equal(await diagnostics.run("enabled", async () => 2), 2);
  diagnostics.stop();
});
