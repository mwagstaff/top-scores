const fs = require("node:fs");
const path = require("node:path");

const normalized = value => String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, "");

function createBroadcastPriorities(configPath, { watch = true } = {}) {
  let config;
  let updatedAt;
  function reload() {
    try {
      const next = JSON.parse(fs.readFileSync(configPath, "utf8"));
      if (!Array.isArray(next.providers) || !Number.isFinite(next.other_priority) ||
          !next.providers.every(provider => Number.isFinite(provider.priority) &&
            Array.isArray(provider.aliases) && provider.aliases.length &&
            provider.aliases.every(alias => typeof alias === "string" && normalized(alias)))) {
        throw new Error("Invalid TV provider priorities");
      }
      config = { ...next, providers: next.providers.map(provider => ({
        ...provider, aliases: provider.aliases.map(normalized),
      })) };
      updatedAt = new Date(Math.max(fs.statSync(configPath).mtimeMs, Date.now())).toISOString();
    } catch (error) {
      if (!config) throw error;
      // Atomic config updates are recommended; retain the last good rules on invalid edits.
      console.warn(`[broadcast-priorities] Keeping previous config: ${error.message}`);
    }
  }
  reload();
  if (watch) fs.watchFile(configPath, { interval: 1000, persistent: false }, reload);
  function priority(channel) {
    const name = normalized(typeof channel === "string" ? channel : channel?.name);
    return config.providers.find(provider => provider.aliases.some(alias => name.startsWith(alias)))?.priority
      ?? config.other_priority;
  }
  function order(channels) {
    return [...channels].sort((a, b) => priority(a) - priority(b));
  }
  function apply(value) {
    if (Array.isArray(value)) return value.map(apply);
    if (!value || typeof value !== "object") return value;
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [
      key, key === "tv_channels" && Array.isArray(item) ? order(item) : apply(item),
    ]));
  }
  return { order, apply, get updatedAt() { return updatedAt; }, close() {
    if (watch) fs.unwatchFile(configPath, reload);
  } };
}

const broadcastPriorities = createBroadcastPriorities(
  process.env.TV_PROVIDER_PRIORITIES_PATH || path.join(__dirname, "tv_provider_priorities.json")
);
module.exports = { createBroadcastPriorities, broadcastPriorities };
