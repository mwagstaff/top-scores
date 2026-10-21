"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

// Exercise the registered handler without starting the API or background jobs.
function handler(getMatchCommentary) {
  const source = fs.readFileSync(require.resolve("./server"), "utf8");
  const start = source.indexOf('app.get(`${API_PREFIX}/matches/:matchId/commentary`');
  const end = source.indexOf('app.get(', start + 1);
  let route;
  vm.runInNewContext(source.slice(start, end), {
    API_PREFIX: "/api/v1",
    app: { get: (_path, callback) => { route = callback; } },
    require: () => ({ getMatchCommentary }),
    console: { warn() {} },
  });
  return async id => {
    const result = { status: 200, headers: {} };
    const res = {
      set(name, value) { result.headers[name] = value; return res; },
      status(code) { result.status = code; return res; },
      json(body) { result.body = body; return res; },
    };
    await route({ params: { matchId: id } }, res);
    return result;
  };
}

test("commentary endpoint validates IDs, returns missing matches and disables HTTP caching", async () => {
  const call = handler(async id => id === "123" ? { commentary: [] } : null);
  assert.equal((await call("../123")).status, 400);
  assert.equal((await call("999")).status, 404);
  const result = await call("123");
  assert.equal(result.status, 200);
  assert.equal(result.headers["Cache-Control"], "no-store");
  assert.deepEqual(result.body, { commentary: [] });
});

test("commentary endpoint reports an upstream failure without exposing its details", async () => {
  const call = handler(async () => { throw new Error("private provider error"); });
  const result = await call("123");
  assert.equal(result.status, 502);
  assert.equal(result.body.error, "Commentary is temporarily unavailable.");
});
