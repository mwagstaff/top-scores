import fs from "node:fs";
import path from "node:path";

const teamLogoAliases = new Map(
  Object.entries({
    "az alkmaar": "AZ",
    "sk sturm graz": "Sturm Graz",
    "club brugge kv": "Club Brugge",
    "rc lens": "Lens",
    "manchester united": "man united",
    "man utd": "man united",
    "manchester utd": "man united",
    "man u": "man united",
    "manchester city": "man city",
    "tottenham hotspur": "tottenham",
    "wolverhampton wanderers": "wolves",
    "sheffield united": "sheff utd",
    "sheffield wednesday": "sheff wed",
    "nottingham forest": "nottm forest",
    "fc bayern münchen": "bayern munich",
    "bayern münchen": "bayern munich",
    "fc bayern munchen": "bayern munich",
    "bayern munchen": "bayern munich",
    "borussia dortmund": "dortmund",
    "borussia m'gladbach": "m'gladbach",
    "athletic club": "athletic",
    "real betis": "betis",
    "fc copenhagen": "copenhagen",
    "fc porto": "porto",
    "paok thessaloniki": "paok",
    "paok thessaloniki fc": "paok",
    "inter milan": "inter",
    "ac milan": "ac milan",
    "bodo/glimt": "bodo-glimt",
    "bodoglimt": "bodo-glimt",
    "rakow": "rakow czestochowa",
    "sigma olomouc": "olomouc",
    "bosnia-herzegovina": "bosnia",
    "bosnia and herzegovina": "bosnia",
  })
);

// Resolve against the same identities bundled by iOS, including standalone web deployments.
export function createTeamLogoResolver(generatedAssetsRoot, teamShortNameEntries = []) {
  const entries = JSON.parse(fs.readFileSync(path.join(generatedAssetsRoot, "team-logo-manifest.json"), "utf8"));
  const teamLogoIndex = entries
    .map((entry) => ({
      name: entry.name,
      normalized: normalizedKey(entry.name),
      core: normalizedCoreKey(entry.name),
      path: path.join(generatedAssetsRoot, entry.relativePath),
    }))
    .filter((entry) => fs.existsSync(entry.path));
  const exactNames = new Map(teamLogoIndex.map((entry) => [entry.name.toLowerCase(), entry]));
  const normalizedNames = new Map(teamLogoIndex.map((entry) => [entry.normalized, entry]));
  const coreNames = new Map();
  for (const entry of teamLogoIndex) {
    const matches = coreNames.get(entry.core) || [];
    matches.push(entry);
    coreNames.set(entry.core, matches);
  }
  const identityNames = new Map();
  for (const entry of entries) {
    for (const name of [entry.name, ...(entry.aliases || [])]) {
      const key = normalizedKey(name);
      const names = identityNames.get(key) || new Set();
      names.add(entry.name);
      identityNames.set(key, names);
    }
  }

  function resolveTeamLogo(teamName, alternateName = "") {
    const trimmed = String(teamName || "").trim();
    if (!trimmed) {
      return null;
    }

    const candidates = [...logoCandidates(trimmed), ...logoCandidates(alternateName)];
    for (const candidate of candidates) {
      const direct = exactNames.get(candidate.toLowerCase());
      if (direct) {
        return direct.path;
      }

      const normalized = normalizedKey(candidate);
      const normalizedMatch = normalizedNames.get(normalized);
      if (normalizedMatch) {
        return normalizedMatch.path;
      }
    }

    for (const candidate of candidates) {
      const core = normalizedCoreKey(candidate);
      const coreMatches = core ? coreNames.get(core) || [] : [];
      if (coreMatches.length === 1) {
        return coreMatches[0].path;
      }
    }

    const normalizedQuery = normalizedKey(trimmed);
    let bestMatch = null;
    let bestScore = 0;
    for (const entry of teamLogoIndex) {
      if (entry.normalized[0] !== normalizedQuery[0]) continue;
      const score = similarity(normalizedQuery, entry.normalized);
      if (score > bestScore) {
        bestScore = score;
        bestMatch = entry;
      }
    }

    if (bestMatch && bestScore >= 0.78) {
      return bestMatch.path;
    }

    return null;
  }

  function logoCandidates(teamName) {
    const output = [];
    const seen = new Set();

    function add(candidate) {
      const trimmed = String(candidate || "").trim();
      if (!trimmed) return;
      const key = trimmed.toLowerCase();
      if (seen.has(key)) return;
      seen.add(key);
      output.push(trimmed);
    }

    const trimmed = String(teamName || "").trim();
    const lowered = trimmed.toLowerCase();
    add(trimmed);
    const identities = identityNames.get(normalizedKey(trimmed));
    if (identities?.size === 1) identities.forEach(add);

    const alias = teamLogoAliases.get(lowered);
    if (alias) {
      add(alias);
    }

    for (const entry of teamShortNameEntries) {
      if (entry.name.toLowerCase() === lowered) {
        add(entry.shortName);
      }
      if (entry.shortName.toLowerCase() === lowered) {
        add(entry.name);
      }
    }

    return output;
  }

  function similarity(left, right) {
    const maxLength = Math.max(left.length, right.length);
    if (maxLength === 0) {
      return 1;
    }

    return 1 - levenshtein(left, right) / maxLength;
  }

  function levenshtein(left, right) {
    const leftChars = Array.from(left);
    const rightChars = Array.from(right);
    let previous = Array.from({ length: rightChars.length + 1 }, (_, index) => index);

    for (let row = 0; row < leftChars.length; row += 1) {
      const current = [row + 1];
      for (let column = 0; column < rightChars.length; column += 1) {
        const cost = leftChars[row] === rightChars[column] ? 0 : 1;
        current[column + 1] = Math.min(
          previous[column + 1] + 1,
          current[column] + 1,
          previous[column] + cost
        );
      }
      previous = current;
    }

    return previous[rightChars.length];
  }

  return resolveTeamLogo;
}

const clubAffixWords = new Set(["city", "town", "united", "rovers", "county", "albion", "wanderers", "hotspur", "saint", "st", "calcio"]);

function normalizedCoreKey(value) {
  return normalizedTokens(value).filter((token) => !clubAffixWords.has(token)).join("");
}

export function normalizedKey(value) {
  const tokens = normalizedTokens(value);
  if (tokens.length > 0) {
    return tokens.join("");
  }

  return stripDiacritics(String(value || ""))
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "");
}

function normalizedTokens(value) {
  const stopWords = new Set(["fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk", "club", "de", "the", "and"]);
  return stripDiacritics(String(value || ""))
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/['’]/g, "")
    .replace(/[._-]/g, " ")
    .split(/[^a-z0-9]+/g)
    .map((token) => /^\d+$/.test(token) ? token.replace(/^0+(?=\d)/, "") : token)
    .filter((token) => token && !stopWords.has(token));
}

function stripDiacritics(value) {
  return value.normalize("NFKD").replace(/[\u0300-\u036f]/g, "");
}
