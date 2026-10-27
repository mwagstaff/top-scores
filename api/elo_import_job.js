const os = require("node:os");

const DEFAULT_ALERTMANAGERS = ["http://127.0.0.1:19093"];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function createEloImportRunner({
  alertmanagerUrls = (process.env.ELO_ALERTMANAGER_URLS || DEFAULT_ALERTMANAGERS.join(","))
    .split(",").map((value) => value.trim()).filter(Boolean),
  fetchImpl = fetch,
  wait = sleep,
  random = Math.random,
  now = Date.now,
  host = process.env.MONITORING_HOST || (os.hostname() === "ubuntu-4gb-hel1-2" ? "sky" : os.hostname()),
  logger = console,
} = {}) {
  const running = new Set();
  const failures = new Map();

  async function notify(source, label, result, attempts, resolved, failureAlertTtlMs = 24 * 60 * 60 * 1000) {
    const timestamp = now();
    const startsAt = failures.get(source) || new Date(timestamp - (resolved ? 1000 : 0)).toISOString();
    if (!resolved) failures.set(source, startsAt);
    const alert = {
      labels: {
        alertname: "TopScoresEloImportFailed", service: "top-scores",
        service_name: "top-scores", job: "top-scores", host, source, severity: "warning",
      },
      annotations: {
        summary: `${label} import ${resolved ? "recovered" : "failed after retries"}`,
        description: resolved
          ? `${label} imported successfully after ${attempts} attempt(s).`
          : `${label} failed after ${attempts} attempts. Last error: ${String(result.error || "Unknown import failure").slice(0, 1000)}. Last dataset update: ${result.updated_at || "unknown"}.`,
      },
      startsAt,
      // Keep failures active until the next scheduled opportunity to recover.
      endsAt: new Date(timestamp + (resolved ? 0 : failureAlertTtlMs)).toISOString(),
    };
    await Promise.all(alertmanagerUrls.map(async (baseUrl) => {
      for (let attempt = 1; attempt <= 3; attempt += 1) {
        try {
          const response = await fetchImpl(`${baseUrl.replace(/\/+$/, "")}/api/v2/alerts`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify([alert]),
            signal: AbortSignal.timeout(10000),
          });
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          await response.text();
          return;
        } catch (_error) {
          if (attempt < 3) await wait(1000 * 2 ** (attempt - 1));
          else logger.error(`[EloImport] Alert delivery failed for ${source} to ${new URL(baseUrl).host} after 3 attempts`);
        }
      }
    }));
    if (resolved) failures.delete(source);
  }

  return async function runEloImport(source, label, operation, options = {}) {
    if (running.has(source)) return { success: false, skipped: true, reason: "update_in_progress" };
    running.add(source);
    const attempts = 4;
    try {
      let result;
      for (let attempt = 1; attempt <= attempts; attempt += 1) {
        try {
          result = await operation();
        } catch (error) {
          result = { success: false, error: error.message || String(error) };
        }
        if (result.skipped) return result;
        if (result.success) {
          // Also resolve alerts left by a previous process before a restart.
          await notify(source, label, result, attempt, true);
          return { ...result, job_attempts: attempt };
        }
        if (attempt < attempts) {
          const delayMs = 5000 * 2 ** (attempt - 1) + Math.floor(random() * 1000);
          logger.warn(`[EloImport] ${source} attempt ${attempt}/${attempts} failed; retrying in ${delayMs}ms`);
          await wait(delayMs);
        }
      }
      await notify(source, label, result, attempts, false, options.failureAlertTtlMs);
      return { ...result, job_attempts: attempts, retries_exhausted: true };
    } finally {
      running.delete(source);
    }
  };
}

module.exports = { createEloImportRunner };
