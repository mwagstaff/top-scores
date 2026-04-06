const fs = require("fs");
const path = require("path");

const TEAM_COLORS_CONFIG_PATH =
  process.env.TEAM_COLORS_CONFIG_PATH || path.join(__dirname, "team_colors.json");
const TEAM_ALIASES_CONFIG_PATH =
  process.env.TEAM_ALIASES_CONFIG_PATH || path.join(__dirname, "team_aliases.json");
const CONFIG_STAT_TTL_MS = 5 * 1000;

let cachedConfig = Object.freeze({
  updatedAt: null,
  default: Object.freeze({
    primary: "#111111",
    secondary: "#FFFFFF",
    scheme: "default-dark",
  }),
  teams: Object.freeze([]),
  identityGroups: Object.freeze([]),
});
let cachedIndex = buildIdentityIndex(cachedConfig);
let cachedTeamColorsMtimeMs = null;
let cachedTeamAliasesMtimeMs = null;
let lastStatCheckAtMs = 0;

function safeStatMtimeMs(filePath) {
  try {
    const stat = fs.statSync(filePath);
    const mtimeMs = Number(stat && stat.mtimeMs);
    return Number.isFinite(mtimeMs) ? mtimeMs : null;
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return null;
    }
    return null;
  }
}

function readJsonObject(filePath) {
  try {
    const raw = fs.readFileSync(filePath, "utf8");
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch (_error) {
    return {};
  }
}

function mergedIdentityEntries(entries) {
  const byCanonicalKey = new Map();

  entries.forEach((entry) => {
    const normalized = normalizeIdentityEntry(entry, null);
    if (!normalized) return;

    const canonicalKey = normalizeTeamIdentityKey(normalized.name);
    if (!canonicalKey) return;

    const existing = byCanonicalKey.get(canonicalKey);
    if (!existing) {
      byCanonicalKey.set(canonicalKey, {
        name: normalized.name,
        aliases: [...normalized.aliases],
      });
      return;
    }

    normalized.aliases.forEach((alias) => {
      if (!existing.aliases.includes(alias)) {
        existing.aliases.push(alias);
      }
    });
  });

  return Object.freeze(
    Array.from(byCanonicalKey.values()).map((entry) =>
      Object.freeze({
        name: entry.name,
        aliases: Object.freeze(entry.aliases),
        primary: null,
        secondary: null,
        scheme: null,
      })
    )
  );
}

function aliasConfigIdentityEntries(parsed) {
  const entries = [];

  if (Array.isArray(parsed.identity_groups)) {
    entries.push(...parsed.identity_groups);
  }

  if (parsed.aliases && typeof parsed.aliases === "object" && !Array.isArray(parsed.aliases)) {
    const grouped = new Map();

    Object.entries(parsed.aliases).forEach(([alias, canonicalName]) => {
      const trimmedAlias = String(alias || "").trim();
      const trimmedCanonicalName = String(canonicalName || "").trim();
      if (!trimmedAlias || !trimmedCanonicalName) return;

      const canonicalKey = normalizeTeamIdentityKey(trimmedCanonicalName);
      if (!canonicalKey) return;

      const existing = grouped.get(canonicalKey) || {
        name: trimmedCanonicalName,
        aliases: [],
      };
      if (
        normalizeTeamIdentityKey(trimmedAlias) !== canonicalKey &&
        !existing.aliases.includes(trimmedAlias)
      ) {
        existing.aliases.push(trimmedAlias);
      }
      grouped.set(canonicalKey, existing);
    });

    entries.push(...grouped.values());
  }

  return entries;
}

function loadTeamIdentityConfig() {
  const nowMs = Date.now();
  if (nowMs - lastStatCheckAtMs < CONFIG_STAT_TTL_MS) {
    return cachedConfig;
  }
  lastStatCheckAtMs = nowMs;

  const teamColorsMtimeMs = safeStatMtimeMs(TEAM_COLORS_CONFIG_PATH);
  const teamAliasesMtimeMs = safeStatMtimeMs(TEAM_ALIASES_CONFIG_PATH);
  if (
    cachedTeamColorsMtimeMs === teamColorsMtimeMs &&
    cachedTeamAliasesMtimeMs === teamAliasesMtimeMs
  ) {
    return cachedConfig;
  }

  try {
    const parsed = readJsonObject(TEAM_COLORS_CONFIG_PATH);
    const parsedAliases = readJsonObject(TEAM_ALIASES_CONFIG_PATH);

    const fallbackDefault = {
      primary: "#111111",
      secondary: "#FFFFFF",
      scheme: "default-dark",
    };
    const parsedDefault =
      parsed.default && typeof parsed.default === "object" && !Array.isArray(parsed.default)
        ? parsed.default
        : fallbackDefault;
    const defaultStyle = Object.freeze({
      primary: String(parsedDefault.primary || fallbackDefault.primary).trim() || fallbackDefault.primary,
      secondary:
        String(parsedDefault.secondary || fallbackDefault.secondary).trim() || fallbackDefault.secondary,
      scheme: String(parsedDefault.scheme || fallbackDefault.scheme).trim() || fallbackDefault.scheme,
    });

    const teams = Object.freeze(
      (Array.isArray(parsed.teams) ? parsed.teams : [])
        .map((entry) => normalizeIdentityEntry(entry, defaultStyle))
        .filter(Boolean)
    );
    const identityGroups = mergedIdentityEntries([
      ...(Array.isArray(parsed.identity_groups) ? parsed.identity_groups : []),
      ...aliasConfigIdentityEntries(parsedAliases),
    ]);
    const latestMtimeMs = Math.max(teamColorsMtimeMs || 0, teamAliasesMtimeMs || 0);
    cachedConfig = Object.freeze({
      updatedAt:
        String(parsedAliases.updatedAt || parsed.updatedAt || "").trim() ||
        (latestMtimeMs > 0 ? new Date(latestMtimeMs).toISOString() : new Date().toISOString()),
      default: defaultStyle,
      teams,
      identityGroups,
    });
    cachedIndex = buildIdentityIndex(cachedConfig);
    cachedTeamColorsMtimeMs = teamColorsMtimeMs;
    cachedTeamAliasesMtimeMs = teamAliasesMtimeMs;
  } catch (_error) {
    cachedTeamColorsMtimeMs = teamColorsMtimeMs;
    cachedTeamAliasesMtimeMs = teamAliasesMtimeMs;
  }

  if (!cachedConfig || !cachedIndex) {
    cachedConfig = Object.freeze({
      updatedAt: new Date().toISOString(),
      default: cachedConfig.default,
      teams: Object.freeze([]),
      identityGroups: Object.freeze([]),
    });
    cachedIndex = buildIdentityIndex(cachedConfig);
  }

  return cachedConfig;
}

function normalizeIdentityEntry(entry, defaultStyle) {
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
    return null;
  }
  const name = String(entry.name || "").trim();
  if (!name) {
    return null;
  }

  const aliases = Array.isArray(entry.aliases)
    ? Array.from(
        new Set(
          entry.aliases
            .map((alias) => String(alias || "").trim())
            .filter((alias) => alias && normalizeTeamIdentityKey(alias) !== normalizeTeamIdentityKey(name))
        )
      )
    : [];

  return Object.freeze({
    name,
    aliases,
    primary: defaultStyle ? String(entry.primary || "").trim() || defaultStyle.primary : null,
    secondary: defaultStyle ? String(entry.secondary || "").trim() || defaultStyle.secondary : null,
    scheme: defaultStyle ? String(entry.scheme || "").trim() || null : null,
  });
}

function buildIdentityIndex(config) {
  const canonicalNameByKey = new Map();
  const namesByCanonicalKey = new Map();
  const exactToCanonicalKey = new Map();

  for (const entry of [...(config.teams || []), ...(config.identityGroups || [])]) {
    const canonicalKey = normalizeTeamIdentityKey(entry.name);
    if (!canonicalKey) {
      continue;
    }

    if (!canonicalNameByKey.has(canonicalKey)) {
      canonicalNameByKey.set(canonicalKey, entry.name);
    }

    const names = namesByCanonicalKey.get(canonicalKey) || [];
    for (const candidate of [entry.name, ...(entry.aliases || [])]) {
      if (!candidate) continue;
      if (!names.includes(candidate)) {
        names.push(candidate);
      }
      const key = normalizeTeamIdentityKey(candidate);
      if (key && !exactToCanonicalKey.has(key)) {
        exactToCanonicalKey.set(key, canonicalKey);
      }
    }
    namesByCanonicalKey.set(canonicalKey, names);
  }

  return {
    canonicalNameByKey,
    namesByCanonicalKey,
    exactToCanonicalKey,
  };
}

function normalizeTeamIdentityName(value) {
  if (!value) return "";
  return String(value)
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/&/g, " and ")
    .replace(/'/g, "")
    .replace(/\./g, " ")
    .replace(/[-_]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeTeamIdentityKey(value) {
  return normalizeTeamIdentityName(value).replace(/[^a-z0-9]+/g, "");
}

function canonicalTeamName(value) {
  const trimmed = String(value || "").trim();
  if (!trimmed) return trimmed;
  loadTeamIdentityConfig();

  const key = normalizeTeamIdentityKey(trimmed);
  const canonicalKey = cachedIndex.exactToCanonicalKey.get(key);
  if (!canonicalKey) {
    return trimmed;
  }
  return cachedIndex.canonicalNameByKey.get(canonicalKey) || trimmed;
}

function teamIdentityNames(value) {
  const trimmed = String(value || "").trim();
  if (!trimmed) return [];
  loadTeamIdentityConfig();

  const key = normalizeTeamIdentityKey(trimmed);
  const canonicalKey = cachedIndex.exactToCanonicalKey.get(key);
  if (!canonicalKey) {
    return [trimmed];
  }

  const names = cachedIndex.namesByCanonicalKey.get(canonicalKey) || [];
  return Array.from(new Set([cachedIndex.canonicalNameByKey.get(canonicalKey), ...names, trimmed].filter(Boolean)));
}

function teamIdentityKeys(value) {
  return Array.from(
    new Set(
      teamIdentityNames(value)
        .map((name) => normalizeTeamIdentityKey(name))
        .filter(Boolean)
    )
  );
}

function teamNamesEquivalent(lhs, rhs) {
  const left = new Set(teamIdentityKeys(lhs));
  const right = teamIdentityKeys(rhs);
  return right.some((key) => left.has(key));
}

function buildFantasyShortNameMappings() {
  const config = loadTeamIdentityConfig();
  const mappings = {};

  for (const entry of [...(config.teams || []), ...(config.identityGroups || [])]) {
    for (const alias of entry.aliases || []) {
      const trimmed = String(alias || "").trim();
      if (!/^[A-Z]{2,5}$/.test(trimmed)) {
        continue;
      }
      mappings[trimmed] = entry.name;
    }
  }

  return Object.freeze(mappings);
}

module.exports = {
  loadTeamIdentityConfig,
  normalizeTeamIdentityName,
  normalizeTeamIdentityKey,
  canonicalTeamName,
  teamIdentityNames,
  teamIdentityKeys,
  teamNamesEquivalent,
  buildFantasyShortNameMappings,
};
