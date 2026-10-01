"use strict";

const { format } = require("node:util");

// Install once per process, before loading modules that can emit startup logs.
function installTimestampedConsole(target = console, now = () => new Date()) {
  if (target.__timestamped) return;
  Object.defineProperty(target, "__timestamped", { value: true });
  for (const level of ["log", "info", "warn", "error", "debug", "trace"]) {
    const original = target[level].bind(target);
    target[level] = (...args) => {
      const prefix = `${now().toISOString()} [pid=${process.pid}]`;
      original(format(...args).split("\n").map((line) => `${prefix} ${line}`).join("\n"));
    };
  }
}

module.exports = { installTimestampedConsole };
