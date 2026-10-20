const test = require("node:test");
const assert = require("node:assert/strict");
const { createEloImportRunner } = require("./elo_import_job");
function harness(overrides = {}) {
  const requests = [], delays = [];
  const run = createEloImportRunner({
    alertmanagerUrls: ["http://email:9093", "http://push:19093"],
    fetchImpl: async (url, options) => { requests.push({ url, alert: JSON.parse(options.body)[0] }); return { ok: true, text: async () => "" }; },
    wait: async ms => delays.push(ms), random: () => 0,
    now: () => Date.parse("2026-10-18T20:00:00Z"), host: "sky",
    logger: { warn() {}, error() {} }, ...overrides,
  });
  return { run, requests, delays };
}
test("alerts both channels only after four failed attempts with exponential backoff", async () => {
  const h = harness(); let count = 0;
  const result = await h.run("club_elo_rankings", "Club Elo", async () => {
    count++; assert.equal(h.requests.length, 0);
    return { success: false, error: "stale publication date", updated_at: "2026-10-01" };
  });
  assert.equal(count, 4); assert.deepEqual(h.delays, [5000, 10000, 20000]);
  assert.equal(result.retries_exhausted, true); assert.equal(h.requests.length, 2);
  assert.deepEqual(h.requests.map(r => r.url), ["http://email:9093/api/v2/alerts", "http://push:19093/api/v2/alerts"]);
  assert.match(h.requests[0].alert.annotations.description, /4 attempts.*stale publication date.*2026-10-01/);
  assert.ok(h.requests[0].alert.endsAt > h.requests[0].alert.startsAt);
});
test("transient exceptions recover without any firing notification", async () => {
  const h = harness(); let count = 0;
  const result = await h.run("national_elo_rankings", "National Elo", async () => {
    if (++count < 3) throw new Error("HTTP 502");
    return { success: true };
  });
  assert.equal(result.job_attempts, 3);
  assert.deepEqual(h.delays, [5000, 10000]);
  assert.equal(h.requests.length, 2);
  for (const {alert} of h.requests) assert.equal(alert.endsAt, "2026-10-18T20:00:00.000Z");
});
test("skipped imports do not retry or notify", async () => {
  const h = harness();
  await h.run("club_elo_rankings", "Club Elo", async () => ({ skipped: true, success: false }));
  assert.deepEqual(h.requests, []); assert.deepEqual(h.delays, []);
});
test("holds the overlap guard across backoff", async () => {
  let release; let waiting;
  const paused = new Promise(resolve => { waiting = resolve; });
  const h = harness({ wait: () => { waiting(); return new Promise(resolve => { release = resolve; }); } });
  let count = 0;
  const pending = h.run("club", "Club Elo", async () => ({ success: ++count > 1 }));
  await paused;
  const overlap = await h.run("club", "Club Elo", () => { throw new Error("must not run"); });
  assert.equal(overlap.reason, "update_in_progress"); release(); await pending;
});
test("delivery retries are independent and do not re-run the import", async () => {
  const calls = []; let count = 0;
  const h = harness({ fetchImpl: async url => {
    calls.push(url); if (url.includes("email")) throw new Error("unreachable");
    return {ok:true, text:async()=>""};
  }});
  const result = await h.run("club", "Club Elo", async () => { count++; return {success:false}; });
  assert.equal(count, 4); assert.equal(result.retries_exhausted, true);
  assert.equal(calls.filter(u => u.includes("email")).length, 3);
  assert.equal(calls.filter(u => u.includes("push")).length, 1);
});
test("successful next run resolves the same alert fingerprint", async () => {
  const h = harness();
  await h.run("club", "Club Elo", async () => ({success:false}));
  await h.run("club", "Club Elo", async () => ({success:true}));
  assert.deepEqual(h.requests[0].alert.labels, h.requests[2].alert.labels);
  assert.equal(h.requests[0].alert.startsAt, h.requests[2].alert.startsAt);
  assert.match(h.requests[2].alert.annotations.summary, /recovered/);
});
