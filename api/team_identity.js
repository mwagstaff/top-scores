const fs = require("fs");
const path = require("path");

const TEAM_COLORS_CONFIG_PATH =
  process.env.TEAM_COLORS_CONFIG_PATH || path.join(__dirname, "team_colors.json");
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
let cachedMtimeMs = null;
let lastStatCheckAtMs = 0;

function loadTeamIdentityConfig() {
  const nowMs = Date.now();
  if (nowMs - lastStatCheckAtMs < CONFIG_STAT_TTL_MS) {
    return cachedConfig;
  }
  lastStatCheckAtMs = nowMs;

  let stat = null;
  try {
    stat = fs.statSync(TEAM_COLORS_CONFIG_PATH);
  } catch (error) {
    if (error && error.code === "ENOENT") {
      cachedConfig = Object.freeze({
        updatedAt: new Date().toISOString(),
        default: cachedConfig.default,
        teams: Object.freeze([]),
        identityGroups: Object.freeze([]),
      });
      cachedIndex = buildIdentityIndex(cachedConfig);
      cachedMtimeMs = null;
      return cachedConfig;
    }
    return cachedConfig;
  }

  const mtimeMs = Number(stat && stat.mtimeMs);
  if (Number.isFinite(mtimeMs) && cachedMtimeMs === mtimeMs) {
    return cachedConfig;
  }

  try {
    const raw = fs.readFileSync(TEAM_COLORS_CONFIG_PATH, "utf8");
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("Team colors config must be a JSON object.");
    }

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
    const identityGroups = Object.freeze(
      (Array.isArray(parsed.identity_groups) ? parsed.identity_groups : [])
        .map((entry) => normalizeIdentityEntry(entry, null))
        .filter(Boolean)
    );
    cachedConfig = Object.freeze({
      updatedAt:
        String(parsed.updatedAt || "").trim() ||
        (Number.isFinite(mtimeMs) ? new Date(mtimeMs).toISOString() : new Date().toISOString()),
      default: defaultStyle,
      teams,
      identityGroups,
    });
    cachedIndex = buildIdentityIndex(cachedConfig);
    cachedMtimeMs = Number.isFinite(mtimeMs) ? mtimeMs : Date.now();
  } catch (_error) {
    cachedMtimeMs = Number.isFinite(mtimeMs) ? mtimeMs : Date.now();
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
