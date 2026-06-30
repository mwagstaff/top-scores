"use strict";

// ---------------------------------------------------------------------------
// Match data-source resolution.
//
// Precedence (highest first):
//   1. Per-request override  — `?source=` query param or `X-Match-Source` header
//   2. Runtime global default — flippable at runtime (stored in Redis by the
//      server and passed in here), so no restart is needed to switch
//   3. Env default            — SERVER_CONFIG.matchDataSource (MATCH_DATA_SOURCE)
//
// The serving layer applies the per-request override; the monitor only ever
// uses the global/env default (request overrides are serving-only).
// ---------------------------------------------------------------------------

const { normalizeMatchSource, SERVER_CONFIG, MATCH_SOURCE_TSDB } = require("./config");

const HEADER_NAME = "x-match-source";
const QUERY_NAME = "source";

// Extracts a normalised source from an Express-style request, or null if the
// request did not specify one (or specified something unrecognised).
function sourceFromRequest(req) {
  if (!req || typeof req !== "object") return null;
  const fromQuery = req.query ? req.query[QUERY_NAME] : undefined;
  const headerBag = req.headers || {};
  const fromHeader =
    typeof req.get === "function" ? req.get(HEADER_NAME) : headerBag[HEADER_NAME];
  return normalizeMatchSource(fromQuery) || normalizeMatchSource(fromHeader) || null;
}

// The effective default when a request gives no override: runtime global
// default if set, else the env-configured default, else tsdb.
function defaultMatchSource(globalDefault) {
  return (
    normalizeMatchSource(globalDefault) ||
    normalizeMatchSource(SERVER_CONFIG.matchDataSource) ||
    MATCH_SOURCE_TSDB
  );
}

// Resolves the source for a request. `globalDefault` is the runtime flag value
// (e.g. read from Redis); pass null/undefined when unset.
function resolveMatchSource(req, globalDefault) {
  return sourceFromRequest(req) || defaultMatchSource(globalDefault);
}

module.exports = {
  HEADER_NAME,
  QUERY_NAME,
  sourceFromRequest,
  defaultMatchSource,
  resolveMatchSource,
  normalizeMatchSource,
};
