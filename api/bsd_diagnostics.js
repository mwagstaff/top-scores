"use strict";

const { AsyncLocalStorage } = require("node:async_hooks");
const { performance, monitorEventLoopDelay, PerformanceObserver } = require("node:perf_hooks");

function createDiagnostics({ memory = () => process.memoryUsage(), now = () => performance.now(),
  write = (record) => console.log(`[bsd-diagnostics] ${JSON.stringify(record)}`) } = {}) {
  const context = new AsyncLocalStorage();
  const active = new Map();
  let enabled = false;
  let sequence = 0;
  let timer;
  let delay;
  let observer;
  let gcCount = 0;
  let gcDurationMs = 0;
  const emit = (record) => {
    // Diagnostics must never change ingestion success/failure.
    try { write(record); } catch (_) { /* best effort */ }
  };

  async function run(name, work, details = {}, { quiet = false } = {}) {
    if (!enabled) return work();
    const id = ++sequence;
    const parentId = context.getStore() || null;
    const started = now();
    const before = memory();
    active.set(id, { id, parentId, name, started, ...details });
    if (!quiet) emit({ event: "start", id, parentId, name, ...details, memory: before });
    let status = "fulfilled";
    let count;
    try {
      return await context.run(id, async () => {
        const result = await work();
        if (Array.isArray(result)) count = result.length;
        return result;
      });
    } catch (error) {
      status = "rejected";
      throw error;
    } finally {
      const after = memory();
      const durationMs = Math.round(now() - started);
      const heapDeltaBytes = after.heapUsed - before.heapUsed;
      active.delete(id);
      if (!quiet || status === "rejected" || count >= 1000 || durationMs >= 2000 || heapDeltaBytes >= 32 * 1024 * 1024) {
        emit({ event: "end", id, parentId, name, ...details, status, count, durationMs,
          heapDeltaBytes, rssDeltaBytes: after.rss - before.rss, memory: after });
      }
    }
  }

  function request(event) {
    if (!enabled) return;
    if (event.errorCode || event.durationMs >= 2000 || event.responseBytes >= 1024 * 1024) {
      // Only API identity/filter fields; never headers, response bodies or arbitrary query values.
      const url = new URL(event.url);
      const query = {};
      for (const key of ["limit", "offset", "league_id", "team_id", "season_id", "status"]) {
        if (url.searchParams.has(key)) query[key] = url.searchParams.get(key);
      }
      emit({ event: "request", operationId: context.getStore() || null, path: url.pathname,
        query, source: event.source, initiator: event.initiator, attempt: event.attempt,
        statusCode: event.statusCode, errorCode: event.errorCode, durationMs: event.durationMs,
        responseBytes: event.responseBytes, resultCount: event.resultCount, memory: memory() });
    }
  }

  function sample(state = {}) {
    if (!enabled) return;
    emit({ event: "sample", memory: memory(), ...state,
      active: [...active.values()].map(({ started, ...job }) => ({ ...job, ageMs: Math.round(now() - started) })),
      eventLoopMaxMs: delay ? Math.round(delay.max / 1e6) : 0, gcCount, gcDurationMs: Math.round(gcDurationMs) });
    delay?.reset();
    gcCount = 0;
    gcDurationMs = 0;
  }

  function start(getState = () => ({}), { intervalMs = 10000 } = {}) {
    if (enabled) return;
    enabled = true;
    delay = monitorEventLoopDelay({ resolution: 20 });
    delay.enable();
    observer = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) { gcCount += 1; gcDurationMs += entry.duration; }
    });
    observer.observe({ entryTypes: ["gc"] });
    sample(getState());
    timer = setInterval(() => sample(getState()), intervalMs);
    timer.unref();
  }

  function stop() {
    clearInterval(timer);
    delay?.disable();
    observer?.disconnect();
    enabled = false;
    active.clear();
  }

  return { run, request, sample, start, stop };
}

module.exports = createDiagnostics();
module.exports.createDiagnostics = createDiagnostics;
