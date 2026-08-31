"use strict";

const https = require("https");

const FRANKFURTER_RATE_URL = "https://api.frankfurter.dev/v2/rate/EUR/GBP";
const DEFAULT_MAX_AGE_MS = 24 * 60 * 60 * 1000;
const DEFAULT_TIMEOUT_MS = 5_000;

function fetchJson(url, { timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  return new Promise((resolve, reject) => {
    const request = https.get(
      url,
      {
        headers: {
          Accept: "application/json",
          "User-Agent": "TopScoresAPI/1.0",
        },
      },
      (response) => {
        const statusCode = Number(response.statusCode || 0);
        if (statusCode !== 200) {
          response.resume();
          reject(new Error(`Exchange-rate request failed with status ${statusCode}`));
          return;
        }

        const chunks = [];
        let byteCount = 0;
        response.on("data", (chunk) => {
          byteCount += chunk.length;
          if (byteCount > 32_768) {
            response.destroy(new Error("Exchange-rate response exceeded size limit"));
            return;
          }
          chunks.push(chunk);
        });
        response.on("error", reject);
        response.on("end", () => {
          try {
            resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
          } catch (error) {
            reject(new Error(`Exchange-rate response was invalid JSON: ${error.message || error}`));
          }
        });
      }
    );
    request.setTimeout(timeoutMs, () => {
      request.destroy(new Error(`Exchange-rate request timed out after ${timeoutMs}ms`));
    });
    request.on("error", reject);
  });
}

function normalizeRateRecord(value) {
  if (!value || typeof value !== "object") return null;
  const rate = Number(value.rate);
  if (!Number.isFinite(rate) || rate <= 0) return null;
  return {
    rate,
    date: String(value.date || "").trim() || null,
    fetched_at: String(value.fetched_at || value.updated_at || "").trim() || null,
  };
}

function createEurGbpRateService(options = {}) {
  const load = typeof options.load === "function" ? options.load : async () => null;
  const save = typeof options.save === "function" ? options.save : async () => null;
  const request = typeof options.request === "function" ? options.request : fetchJson;
  const now = typeof options.now === "function" ? options.now : Date.now;
  const maxAgeMs = Number.isFinite(options.maxAgeMs) ? options.maxAgeMs : DEFAULT_MAX_AGE_MS;
  let memoryRecord = null;
  let pending = null;
  let loaded = false;
  let loadPending = null;

  async function loadOnce() {
    if (loaded) return memoryRecord;
    if (loadPending) return loadPending;
    loadPending = (async () => {
      memoryRecord = normalizeRateRecord(await load().catch(() => null));
      loaded = true;
      return memoryRecord;
    })().finally(() => {
      loadPending = null;
    });
    return loadPending;
  }

  async function refresh() {
    if (pending) return pending;
    pending = (async () => {
      const payload = await request(FRANKFURTER_RATE_URL, { timeoutMs: DEFAULT_TIMEOUT_MS });
      const normalized = normalizeRateRecord({
        rate: payload && payload.rate,
        date: payload && payload.date,
        fetched_at: new Date(now()).toISOString(),
      });
      if (!normalized) throw new Error("Frankfurter returned an invalid EUR to GBP rate");
      memoryRecord = normalized;
      await save(normalized).catch(() => null);
      return { ...normalized, stale: false, source: "frankfurter" };
    })().finally(() => {
      pending = null;
    });
    return pending;
  }

  async function getRate() {
    const cached = await loadOnce();
    const fetchedAtMs = Date.parse(String(cached && cached.fetched_at || ""));
    if (cached && Number.isFinite(fetchedAtMs) && now() - fetchedAtMs < maxAgeMs) {
      return { ...cached, stale: false, source: "cache" };
    }
    try {
      return await refresh();
    } catch (error) {
      if (cached) return { ...cached, stale: true, source: "stale_cache" };
      throw error;
    }
  }

  return { getRate };
}

module.exports = {
  createEurGbpRateService,
  __private: {
    FRANKFURTER_RATE_URL,
    normalizeRateRecord,
    fetchJson,
  },
};
