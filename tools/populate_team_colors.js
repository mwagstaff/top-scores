#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const API_CONFIG_PATH = path.join(ROOT, "api", "team_colors.json");
const IOS_CONFIG_PATH = path.join(
  ROOT,
  "ios",
  "Top Scores",
  "Top Scores",
  "team_colors.json"
);
const LOGO_ASSETS_PATH = path.join(ROOT, "ios", "Top Scores", "Media.xcassets");
const PUBLIC_TEAMS_URL = "https://api.skynolimit.dev/top-scores/api/v1/teams";
const REMOTE_MARKER = "__TOP_SCORES_TEAM_COLOR_DATA__";
const TEAM_ALIASES_PATH = path.join(ROOT, "api", "team_aliases.json");
const REEPE_TEAMS_URL =
  "https://raw.githubusercontent.com/asamory/reepe/main/data/teams.csv";
const KNOWN_SOFA_IDS = new Map([
  ["AO L'Eveil", "1150524"],
  ["Calonne Ricouart FC Cite 6", "399402"],
  ["COBSP St Brieuc", "936327"],
  ["COS Villers Nancy", "452234"],
  ["ES Anzin Saint Aubin", "399403"],
  ["ES Aubance Brissac", "497556"],
  ["ES Bressane Marboz", "129328"],
  ["Espoir Ste Luce", "1150523"],
  ["FC Equeurdreville Hainneville", "497536"],
  ["FC Flerien", "497532"],
  ["FC Lescar", "455543"],
  ["FC Schweighouse Sur Moder", "497553"],
  ["Frontignan AV Sac", "210100"],
  ["Groupe Sportif Avenir Tomblaine", "1141657"],
  ["J3S Amilly", "399436"],
  ["LSK Hansa Lüneburg", "24084"],
  ["Lumbres OL", "334236"],
  ["Marcoussis Nozay VDB", "455454"],
  ["Oldham Town", "47139"],
  ["RC Lons", "334229"],
  ["Roche Saint-Genest FC", "84081"],
  ["Sa Le Quesnoy", "497542"],
  ["Saint Denis US", "497540"],
  ["Saint Esteve Perpignan", "455448"],
  ["Saint-Gregoire USF 35", "455440"],
  ["Squadra Valincu Alta Rocca Rizzanese", "505657"],
  ["St Cyr Collonges au Mont d'Or", "399406"],
  ["Union Zona Norte", "493347"],
  ["US Bleriot Plage", "497548"],
  ["US St. Philbert de Grandlieu", "355467"],
  ["Villenave", "132338"],
]);
const VERIFIED_WEB_COLORS = [
  {
    name: "Aunis Avenir Football Club",
    aliases: ["Aunis AFC"],
    primary: "#1DAEDB",
    secondary: "#322B6F",
  },
  {
    name: "AS Lavernose Lherm",
    aliases: ["Lavernose Lherm"],
    primary: "#D71920",
    secondary: "#FFD100",
  },
  {
    name: "Atletico Lugones",
    aliases: ["Atlético de Lugones SD"],
    primary: "#0057B8",
    secondary: "#FFFFFF",
  },
  {
    name: "CA Éperlecques",
    aliases: ["Cercle Athlétique Éperlecques"],
    primary: "#0057B8",
    secondary: "#FFFFFF",
  },
  {
    name: "FC Seyssins",
    aliases: [],
    primary: "#D71920",
    secondary: "#111111",
  },
  {
    name: "Lumbres OL",
    aliases: ["Olympique Lumbrois"],
    primary: "#C8102E",
    secondary: "#00843D",
  },
  {
    name: "Saint Aubin Guerande FC",
    aliases: ["Saint-Aubin Guérande Football"],
    primary: "#FFD100",
    secondary: "#111111",
  },
  {
    name: "US Mineurs Waziers",
    aliases: ["USM Waziers"],
    primary: "#00843D",
    secondary: "#111111",
  },
  {
    name: "US Premontre St Gobain",
    aliases: [
      "US Premonte St Gobain",
      "US Prémontré Saint-Gobain",
      "Union Sportive Prémontré Saint-Gobain",
    ],
    primary: "#001F3F",
    secondary: "#FFFFFF",
  },
];

function normalizedName(value) {
  return String(value || "")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/&/g, " and ")
    .replace(/[.'’]/g, "")
    .replace(/[-_]/g, " ")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function identityKey(value) {
  return normalizedName(value).replace(/[^a-z0-9]+/g, "");
}

const CORE_STOP_WORDS = new Set([
  "ac",
  "afc",
  "as",
  "calcio",
  "cd",
  "cf",
  "club",
  "fc",
  "fk",
  "rc",
  "rcd",
  "sc",
  "sk",
  "sv",
  "ud",
  "vfb",
  "vfl",
]);

function coreKey(value) {
  return normalizedName(value)
    .split(" ")
    .filter((token) => token && !CORE_STOP_WORDS.has(token))
    .join("");
}

function isPlaceholderTeam(value) {
  const name = String(value || "").trim();
  if (!name || /^tbc$/i.test(name)) return true;
  if (/^CompetitionLogo/i.test(name)) return true;
  if (/^Extranjeros Liga\b/i.test(name)) return true;
  if (/^\d[A-Za-z](?:\/\d[A-Za-z])+$/i.test(name)) return true;
  if (/^[WL]\d+$/i.test(name)) return true;
  if (/^\d[A-Za-z]$/i.test(name)) return true;
  if (/^[A-Za-z]\d+$/i.test(name) && name.length <= 3) return true;
  return false;
}

function levenshtein(left, right) {
  if (left === right) return 0;
  if (!left.length) return right.length;
  if (!right.length) return left.length;

  let previous = Array.from({ length: right.length + 1 }, (_, index) => index);
  for (let leftIndex = 0; leftIndex < left.length; leftIndex += 1) {
    const current = [leftIndex + 1];
    for (let rightIndex = 0; rightIndex < right.length; rightIndex += 1) {
      current.push(
        Math.min(
          current[rightIndex] + 1,
          previous[rightIndex + 1] + 1,
          previous[rightIndex] + (left[leftIndex] === right[rightIndex] ? 0 : 1)
        )
      );
    }
    previous = current;
  }
  return previous[right.length];
}

function similarity(left, right) {
  if (!left || !right) return 0;
  if (left === right) return 1;
  const shorter = left.length <= right.length ? left : right;
  const longer = left.length > right.length ? left : right;
  if (shorter.length >= 5 && longer.includes(shorter)) {
    return Math.max(0.86, shorter.length / longer.length);
  }
  return 1 - levenshtein(left, right) / Math.max(left.length, right.length);
}

function validHex(value) {
  const match = String(value || "").trim().match(/^#?([0-9a-f]{6})$/i);
  return match ? `#${match[1].toUpperCase()}` : null;
}

function hexChannels(value) {
  const hex = validHex(value);
  if (!hex) return null;
  return [
    Number.parseInt(hex.slice(1, 3), 16),
    Number.parseInt(hex.slice(3, 5), 16),
    Number.parseInt(hex.slice(5, 7), 16),
  ];
}

function colorDistance(left, right) {
  const a = hexChannels(left);
  const b = hexChannels(right);
  if (!a || !b) return 0;
  return Math.sqrt(
    (a[0] - b[0]) ** 2 +
      (a[1] - b[1]) ** 2 +
      (a[2] - b[2]) ** 2
  );
}

function normalizedColor(value) {
  const channels = hexChannels(value);
  if (!channels) return null;
  if (channels.every((channel) => channel >= 242)) return "#FFFFFF";
  if (channels.every((channel) => channel <= 18)) return "#000000";
  return validHex(value);
}

function fallbackContrast(primary) {
  const channels = hexChannels(primary) || [17, 17, 17];
  const luminance =
    (0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]) / 255;
  return luminance > 0.62 ? "#111111" : "#FFFFFF";
}

function colorBucket(value) {
  const channels = hexChannels(value);
  if (!channels) return "unknown";
  const [red, green, blue] = channels.map((channel) => channel / 255);
  const maximum = Math.max(red, green, blue);
  const minimum = Math.min(red, green, blue);
  const delta = maximum - minimum;
  const lightness = (maximum + minimum) / 2;
  const saturation = delta === 0 ? 0 : delta / (1 - Math.abs(2 * lightness - 1));

  if (saturation < 0.12) {
    if (lightness < 0.18) return "black";
    if (lightness > 0.86) return "white";
    return "gray";
  }

  let hue = 0;
  if (maximum === red) hue = 60 * (((green - blue) / delta) % 6);
  if (maximum === green) hue = 60 * ((blue - red) / delta + 2);
  if (maximum === blue) hue = 60 * ((red - green) / delta + 4);
  if (hue < 0) hue += 360;

  if (hue < 15 || hue >= 345) return "red";
  if (hue < 45) return "orange";
  if (hue < 70) return "yellow";
  if (hue < 165) return "green";
  if (hue < 195) return "cyan";
  if (hue < 255) return "blue";
  if (hue < 290) return "purple";
  if (hue < 345) return "pink";
  return "red";
}

function styleFromColors(rawPrimary, rawSecondary) {
  const primary = normalizedColor(rawPrimary);
  if (!primary) return null;
  let secondary = normalizedColor(rawSecondary);
  if (!secondary || colorDistance(primary, secondary) < 38) {
    secondary = fallbackContrast(primary);
  }
  return {
    primary,
    secondary,
    scheme: `${colorBucket(primary)}-${colorBucket(secondary)}`,
  };
}

function teamNames(record) {
  return [
    record.strTeam,
    record.strTeamShort,
    ...(String(record.strAlternate || "")
      .split(/[,;/]/)
      .map((value) => value.trim())),
  ].filter(Boolean);
}

function addToIndex(index, key, value) {
  if (!key) return;
  const values = index.get(key) || [];
  if (!values.includes(value)) values.push(value);
  index.set(key, values);
}

function buildRecordIndex(records, nameProvider) {
  const exact = new Map();
  const core = new Map();
  records.forEach((record) => {
    nameProvider(record).forEach((name) => {
      addToIndex(exact, identityKey(name), record);
      addToIndex(core, coreKey(name), record);
    });
  });
  return { exact, core, records };
}

function countryKey(value) {
  return normalizedName(value).replace(/[^a-z0-9]+/g, "");
}

function findBestRecord(name, country, index, nameProvider, options = {}) {
  const exactMatches = index.exact.get(identityKey(name)) || [];
  const expectedCountry = countryKey(country);
  const preferCountry = (records) => {
    if (!expectedCountry) return records;
    const matched = records.filter(
      (record) => countryKey(record.strCountry || record.country) === expectedCountry
    );
    return matched.length ? matched : records;
  };

  const exact = preferCountry(exactMatches);
  if (exact.length === 1) return exact[0];
  if (exact.length > 1) {
    return exact.find((record) => options.accept(record)) || exact[0];
  }

  const coreMatches = preferCountry(index.core.get(coreKey(name)) || []);
  if (coreMatches.length === 1) return coreMatches[0];
  if (coreMatches.length > 1) {
    return coreMatches.find((record) => options.accept(record)) || coreMatches[0];
  }

  const candidates = preferCountry(index.records).filter(options.accept);
  const target = coreKey(name);
  if (target.length < 5) return null;
  let best = null;
  let bestScore = 0;
  let secondScore = 0;
  candidates.forEach((record) => {
    const score = Math.max(
      ...nameProvider(record).map((candidate) => similarity(target, coreKey(candidate)))
    );
    if (score > bestScore) {
      secondScore = bestScore;
      bestScore = score;
      best = record;
    } else if (score > secondScore) {
      secondScore = score;
    }
  });
  return bestScore >= 0.86 && bestScore - secondScore >= 0.025 ? best : null;
}

async function fetchJson(url) {
  const response = await fetch(url, {
    headers: {
      Accept: "application/json",
      "User-Agent": "TopScoresTeamColourImporter/1.0",
    },
  });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} for ${url}`);
  }
  return response.json();
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function fetchText(url) {
  const response = await fetch(url, {
    headers: {
      Accept: "text/csv,text/plain;q=0.9,*/*;q=0.8",
      "User-Agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Safari/537.36",
    },
  });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} for ${url}`);
  }
  return response.text();
}

function parseCsv(text) {
  const rows = [];
  let row = [];
  let value = "";
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (quoted) {
      if (character === '"' && text[index + 1] === '"') {
        value += '"';
        index += 1;
      } else if (character === '"') {
        quoted = false;
      } else {
        value += character;
      }
    } else if (character === '"') {
      quoted = true;
    } else if (character === ",") {
      row.push(value);
      value = "";
    } else if (character === "\n") {
      row.push(value.replace(/\r$/, ""));
      rows.push(row);
      row = [];
      value = "";
    } else {
      value += character;
    }
  }
  if (value || row.length) {
    row.push(value.replace(/\r$/, ""));
    rows.push(row);
  }
  const headers = rows.shift() || [];
  return rows
    .filter((values) => values.some(Boolean))
    .map((values) =>
      Object.fromEntries(headers.map((header, index) => [header, values[index] || ""]))
    );
}

function findExactRegistryRecord(names, country, index) {
  const expectedCountry = countryKey(country);
  const candidates = [];
  for (const name of names) {
    for (const record of index.exact.get(identityKey(name)) || []) {
      if (!candidates.includes(record)) candidates.push(record);
    }
  }
  if (!candidates.length) return null;
  if (expectedCountry) {
    const countryMatches = candidates.filter(
      (record) => countryKey(record.country) === expectedCountry
    );
    if (countryMatches.length === 1) return countryMatches[0];
    if (countryMatches.length > 1) return countryMatches.find(
      (record) => record.key_wikidata || record.key_sofascore
    ) || countryMatches[0];
  }
  if (candidates.length === 1) return candidates[0];
  return candidates.find((record) => record.key_wikidata || record.key_sofascore) || null;
}

function claimValues(entity, property) {
  return (entity?.claims?.[property] || [])
    .map((claim) => claim?.mainsnak?.datavalue?.value)
    .filter((value) => value !== undefined && value !== null);
}

async function fetchWikidataEntities(ids) {
  const entities = {};
  const uniqueIds = [...new Set(ids.filter((id) => /^Q\d+$/.test(id)))];
  for (let index = 0; index < uniqueIds.length; index += 50) {
    const batch = uniqueIds.slice(index, index + 50);
    const query = new URLSearchParams({
      action: "wbgetentities",
      format: "json",
      props: "claims|sitelinks",
      ids: batch.join("|"),
      origin: "*",
    });
    const payload = await fetchJson(`https://www.wikidata.org/w/api.php?${query}`);
    Object.assign(entities, payload.entities || {});
  }
  return entities;
}

function wikidataColorIds(entity) {
  return claimValues(entity, "P6364")
    .concat(claimValues(entity, "P462"))
    .map((value) => value?.id)
    .filter(Boolean);
}

function wikidataHexValues(entity) {
  return claimValues(entity, "P465")
    .map((value) => validHex(value))
    .filter(Boolean);
}

async function paletteFromWikimediaFile(fileName) {
  if (!fileName) return null;
  const url = `https://commons.wikimedia.org/wiki/Special:Redirect/file/${encodeURIComponent(fileName)}?width=300`;
  return paletteFromRemoteLogo(url);
}

async function paletteFromWikipediaPage(entity) {
  const sites = ["enwiki", "frwiki", "eswiki", "dewiki"];
  const site = sites.find((candidate) => entity?.sitelinks?.[candidate]?.title);
  if (!site) return null;
  const language = site.replace(/wiki$/, "");
  const query = new URLSearchParams({
    action: "query",
    format: "json",
    prop: "pageimages",
    piprop: "thumbnail|original",
    pithumbsize: "300",
    titles: entity.sitelinks[site].title,
    origin: "*",
  });
  try {
    const payload = await fetchJson(
      `https://${language}.wikipedia.org/w/api.php?${query}`
    );
    const page = Object.values(payload.query?.pages || {})[0];
    const imageURL = page?.thumbnail?.source || page?.original?.source;
    return imageURL ? paletteFromRemoteLogo(imageURL) : null;
  } catch (_error) {
    return null;
  }
}

async function resolveWithOpenRegistry(unresolved, aliases) {
  if (!unresolved.length) return { resolved: [], unresolved: [] };
  const csv = await fetchText(REEPE_TEAMS_URL);
  const registry = parseCsv(csv).filter((record) => record.name);
  const registryIndex = buildRecordIndex(registry, (record) => [record.name]);
  const linked = unresolved.map((team) => ({
    team,
    record: findExactRegistryRecord(
      searchNamesForTeam(team.name, aliases).concat(team.shortName || []),
      team.country,
      registryIndex
    ),
  }));
  const linkedRecords = linked.map((item) => item.record).filter(Boolean);
  process.stderr.write(
    `Open registry identities ${linkedRecords.length}/${unresolved.length}\n`
  );
  const registryKeyCounts = linkedRecords.reduce((counts, record) => {
    for (const [key, value] of Object.entries(record)) {
      if (key.startsWith("key_") && value) counts[key] = (counts[key] || 0) + 1;
    }
    return counts;
  }, {});
  process.stderr.write(`Open registry keys ${JSON.stringify(registryKeyCounts)}\n`);
  const teamEntities = await fetchWikidataEntities(
    linkedRecords.map((record) => record.key_wikidata)
  );
  const colorEntities = await fetchWikidataEntities(
    Object.values(teamEntities).flatMap(wikidataColorIds)
  );
  const resolved = [];
  const stillUnresolved = [];

  for (let index = 0; index < linked.length; index += 1) {
    const { team, record } = linked[index];
    let style = null;
    let source = null;
    const entity = record?.key_wikidata ? teamEntities[record.key_wikidata] : null;
    const officialColors = [
      ...wikidataHexValues(entity),
      ...wikidataColorIds(entity).flatMap((id) =>
        wikidataHexValues(colorEntities[id])
      ),
    ];
    if (officialColors.length) {
      style = styleFromColors(officialColors[0], officialColors[1]);
      source = "wikidataColors";
    }
    if (!style && record?.key_sofascore) {
      style = await paletteFromRemoteLogo(
        `https://img.sofascore.com/api/v1/team/${record.key_sofascore}/image`
      );
      source = "sofascoreCrest";
    }
    if (!style && record?.key_fotmob) {
      style = await paletteFromRemoteLogo(
        `https://images.fotmob.com/image_resources/logo/teamlogo/${record.key_fotmob}.png`
      );
      source = "fotmobCrest";
    }
    if (!style && record?.key_espn) {
      style = await paletteFromRemoteLogo(
        `https://a.espncdn.com/i/teamlogos/soccer/500/${record.key_espn}.png`
      );
      source = "espnCrest";
    }
    if (!style && record?.key_api_football) {
      style = await paletteFromRemoteLogo(
        `https://media.api-sports.io/football/teams/${record.key_api_football}.png`
      );
      source = "apiFootballCrest";
    }
    if (!style && record?.key_transfermarkt) {
      style = await paletteFromRemoteLogo(
        `https://tmssl.akamaized.net/images/wappen/head/${record.key_transfermarkt}.png`
      );
      source = "transfermarktCrest";
    }
    if (!style && entity) {
      const logo = claimValues(entity, "P154")[0] || claimValues(entity, "P18")[0];
      style = await paletteFromWikimediaFile(logo);
      source = "wikimediaCrest";
    }
    if (!style && entity) {
      style = await paletteFromWikipediaPage(entity);
      source = "wikipediaPageImage";
    }
    if (style) {
      resolved.push({ team, record, style, source });
    } else {
      stillUnresolved.push(team);
    }
    if ((index + 1) % 50 === 0 || index + 1 === linked.length) {
      process.stderr.write(`Open registry teams ${index + 1}/${linked.length}\n`);
    }
  }
  return { resolved, unresolved: stillUnresolved };
}

async function resolveWithFotmobSearch(unresolved, aliases) {
  const resolved = [];
  const stillUnresolved = [];
  for (let index = 0; index < unresolved.length; index += 1) {
    const team = unresolved[index];
    const searchNames = [...new Set(
      searchNamesForTeam(team.name, aliases)
        .concat(team.shortName || [])
        .map((name) => String(name || "").trim())
        .filter((name) => identityKey(name).length >= 5)
    )];
    let match = null;
    for (const searchName of searchNames) {
      try {
        const query = new URLSearchParams({
          hits: "12",
          lang: "en",
          term: searchName,
        });
        const groups = await fetchJson(
          `https://www.fotmob.com/api/data/search/suggest?${query}`
        );
        const candidates = (Array.isArray(groups) ? groups : [])
          .flatMap((group) => group.suggestions || [])
          .filter((candidate) => candidate.type === "team" && candidate.id)
          .filter((candidate, candidateIndex, values) =>
            values.findIndex((value) => String(value.id) === String(candidate.id)) === candidateIndex
          );
        const target = coreKey(team.name);
        match = candidates
          .map((candidate) => ({
            candidate,
            score: similarity(target, coreKey(candidate.name)),
          }))
          .sort((left, right) => right.score - left.score)
          .find((result) => result.score >= 0.86)?.candidate || null;
      } catch (_error) {
        match = null;
      }
      if (match) break;
      await sleep(120);
    }
    let style = null;
    if (match) {
      style = await paletteFromRemoteLogo(
        `https://images.fotmob.com/image_resources/logo/teamlogo/${match.id}.png`
      );
    }
    if (style) {
      resolved.push({ team, match, style, source: "fotmobSearchCrest" });
    } else {
      stillUnresolved.push(team);
    }
    if ((index + 1) % 50 === 0 || index + 1 === unresolved.length) {
      process.stderr.write(`FotMob searches ${index + 1}/${unresolved.length}\n`);
    }
    await sleep(120);
  }
  return { resolved, unresolved: stillUnresolved };
}

async function resolveWithTransfermarktSearch(unresolved, aliases) {
  const resolved = [];
  const stillUnresolved = [];
  for (let index = 0; index < unresolved.length; index += 1) {
    const team = unresolved[index];
    const searchNames = [...new Set(
      searchNamesForTeam(team.name, aliases)
        .concat(team.shortName || [])
        .map((name) => String(name || "").trim())
        .filter((name) => identityKey(name).length >= 5)
    )];
    let match = null;
    for (const searchName of searchNames) {
      try {
        const query = new URLSearchParams({ query: searchName });
        const html = await fetchText(
          `https://www.transfermarkt.com/schnellsuche/ergebnis/schnellsuche?${query}`
        );
        const candidates = [];
        const expression = /\/([^"'<>\s]+)\/startseite\/verein\/(\d+)/g;
        let candidateMatch;
        while ((candidateMatch = expression.exec(html))) {
          const candidate = {
            slug: decodeURIComponent(candidateMatch[1]).replace(/-/g, " "),
            id: candidateMatch[2],
          };
          if (!candidates.some((value) => value.id === candidate.id)) {
            candidates.push(candidate);
          }
        }
        const targets = [coreKey(team.name), ...searchNames.map(coreKey)].filter(Boolean);
        match = candidates
          .map((candidate) => ({
            candidate,
            score: Math.max(
              ...targets.map((target) => similarity(target, coreKey(candidate.slug)))
            ),
          }))
          .sort((left, right) => right.score - left.score)
          .find((result) => result.score >= 0.86)?.candidate || null;
      } catch (_error) {
        match = null;
      }
      if (match) break;
      await sleep(180);
    }
    let style = null;
    if (match) {
      style = await paletteFromRemoteLogo(
        `https://tmssl.akamaized.net/images/wappen/head/${match.id}.png`
      );
    }
    if (style) {
      resolved.push({ team, match, style, source: "transfermarktSearchCrest" });
    } else {
      stillUnresolved.push(team);
    }
    if ((index + 1) % 50 === 0 || index + 1 === unresolved.length) {
      process.stderr.write(`Transfermarkt searches ${index + 1}/${unresolved.length}\n`);
    }
    await sleep(180);
  }
  return { resolved, unresolved: stillUnresolved };
}

function decodedHtml(value) {
  return String(value || "")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;|&apos;|&#x27;/gi, "'")
    .replace(/&nbsp;/g, " ");
}

async function globalSportsArchiveRecords() {
  const seedURLs = [
    "https://globalsportsarchive.com/en/soccer/competition/coupe-de-france-2026-2027/81084",
    "https://globalsportsarchive.com/en/soccer/competition/copa-del-rey-mapfre-2025-2026/76310",
    "https://globalsportsarchive.com/en/soccer/competition/dfb-pokal-2026-2027/80301",
  ];
  const pages = [];
  const pageURLs = new Set(seedURLs);
  for (const seedURL of seedURLs) {
    try {
      const html = await fetchText(seedURL);
      pages.push(html);
      const linkExpression = /\/en\/soccer\/competition\/(?:coupe-de-france|copa-del-rey-mapfre|dfb-pokal)-(\d{4})-\d{4}\/\d+/g;
      let linkMatch;
      while ((linkMatch = linkExpression.exec(html))) {
        if (Number(linkMatch[1]) >= 2014) {
          pageURLs.add(`https://globalsportsarchive.com${linkMatch[0]}`);
        }
      }
    } catch (_error) {
      // Continue with the other indexed competitions.
    }
  }
  const remainingURLs = [...pageURLs].filter((url) => !seedURLs.includes(url));
  for (let index = 0; index < remainingURLs.length; index += 1) {
    try {
      pages.push(await fetchText(remainingURLs[index]));
    } catch (_error) {
      // An unavailable historical season should not abort the import.
    }
    if ((index + 1) % 10 === 0 || index + 1 === remainingURLs.length) {
      process.stderr.write(`Global Sports Archive seasons ${index + 1}/${remainingURLs.length}\n`);
    }
    await sleep(100);
  }
  const records = [
    { id: "67905", name: "Aigles d'Or de Mana" },
    { id: "62058", name: "AS Rosador" },
    { id: "41036", name: "Basque Country" },
    { id: "40226", name: "Catalonia" },
    { id: "40226", name: "Catalunya" },
    { id: "12370", name: "AS Jumeaux de Mzouazia" },
    { id: "12370", name: "Jumeaux Mzouazia" },
  ];
  const imageExpression = /src="https:\/\/(?:www\.)?dsg-images\.com\/clubs\/(?:30x30|50x50)\/(\d+)\.png"\s+alt="logo of ([^"]+)"/g;
  for (const html of pages) {
    let imageMatch;
    while ((imageMatch = imageExpression.exec(html))) {
      const record = { id: imageMatch[1], name: decodedHtml(imageMatch[2]) };
      if (!records.some((value) => value.id === record.id && value.name === record.name)) {
        records.push(record);
      }
    }
  }
  process.stderr.write(`Global Sports Archive club identities ${records.length}\n`);
  return records;
}

async function resolveWithGlobalSportsArchive(unresolved, aliases) {
  if (!unresolved.length) return { resolved: [], unresolved: [] };
  const records = await globalSportsArchiveRecords();
  const index = buildRecordIndex(records, (record) => [record.name]);
  const resolved = [];
  const stillUnresolved = [];
  for (let teamIndex = 0; teamIndex < unresolved.length; teamIndex += 1) {
    const team = unresolved[teamIndex];
    const names = searchNamesForTeam(team.name, aliases).concat(team.shortName || []);
    let match = findExactRegistryRecord(names, "", index);
    if (!match) {
      const fuzzy = names
        .map((name) => findBestRecord(name, "", index, (record) => [record.name], {
          accept: () => true,
        }))
        .find(Boolean);
      const fuzzyScore = fuzzy
        ? Math.max(...names.map((name) => similarity(coreKey(name), coreKey(fuzzy.name))))
        : 0;
      if (fuzzyScore >= 0.9) match = fuzzy;
    }
    const style = match
      ? await paletteFromRemoteLogo(
          `https://www.dsg-images.com/clubs/200x200/${match.id}.png`
        )
      : null;
    if (style) {
      resolved.push({ team, match, style, source: "globalSportsArchiveCrest" });
    } else {
      stillUnresolved.push(team);
    }
    if ((teamIndex + 1) % 20 === 0 || teamIndex + 1 === unresolved.length) {
      process.stderr.write(
        `Global Sports Archive teams ${teamIndex + 1}/${unresolved.length}\n`
      );
    }
  }
  return { resolved, unresolved: stillUnresolved };
}

async function resolveWithKnownWebSources(unresolved) {
  const resolved = [];
  const stillUnresolved = [];
  const coveredKeys = new Set();
  const manualByKey = new Map();
  for (const record of VERIFIED_WEB_COLORS) {
    for (const name of [record.name, ...(record.aliases || [])]) {
      manualByKey.set(identityKey(name), record);
    }
  }
  const sofaByKey = new Map(
    [...KNOWN_SOFA_IDS.entries()].map(([name, id]) => [identityKey(name), { name, id }])
  );

  for (const team of unresolved) {
    const key = identityKey(team.name);
    if (coveredKeys.has(key)) continue;
    const manual = manualByKey.get(key);
    if (manual) {
      const style = styleFromColors(manual.primary, manual.secondary);
      resolved.push({
        team: { ...team, name: manual.name },
        aliases: [...(manual.aliases || []), team.shortName].filter(Boolean),
        style,
        source: "verifiedPublishedColors",
      });
      for (const name of [manual.name, ...(manual.aliases || [])]) {
        coveredKeys.add(identityKey(name));
      }
      continue;
    }
    const sofa = sofaByKey.get(key);
    if (sofa) {
      const style = await paletteFromRemoteLogo(
        `https://img.sofascore.com/api/v1/team/${sofa.id}/image`
      );
      if (style) {
        resolved.push({ team, aliases: [], style, source: "indexedSofascoreCrest" });
        coveredKeys.add(key);
        continue;
      }
    }
    stillUnresolved.push(team);
  }
  return { resolved, unresolved: stillUnresolved };
}

function fetchRemoteProviderData(includeProviderTeams = true) {
  const remoteScript = String.raw`
const REMOTE_MARKER = ${JSON.stringify(REMOTE_MARKER)};
const includeProviderTeams = ${JSON.stringify(includeProviderTeams)};
const { URLSearchParams } = require("url");
const databaseURL = new URL(process.env.MONGODB_URI_TOP_SCORES);
databaseURL.pathname = "/top_scores";
process.env.MONGODB_URI_TOP_SCORES = databaseURL.toString();
const mongo = require("./mongo_client");

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function fetchProviderJSON(url) {
  for (let attempt = 1; attempt <= 4; attempt += 1) {
    const response = await fetch(url, { headers: { Accept: "application/json" } });
    if (response.ok) return response.json();
    if (response.status !== 429 || attempt === 4) {
      throw new Error("TheSportsDB HTTP " + response.status);
    }
    const retryAfter = Number(response.headers.get("retry-after"));
    await sleep(Number.isFinite(retryAfter) ? retryAfter * 1000 : 61000);
  }
  return {};
}

(async () => {
  const documents = await mongo.getBsdRecords("bsd_teams", {}, {
    projection: { name: 1, country: 1, "payload.name": 1, "payload.short_name": 1, "payload.country": 1 }
  });
  const inventory = documents.map((document) => ({
    name: String(document.name || document.payload?.name || "").trim(),
    shortName: String(document.payload?.short_name || "").trim(),
    country: String(document.country || document.payload?.country || "").trim(),
  })).filter((team) => team.name);
  const countries = [...new Set(inventory.map((team) => team.country).filter(Boolean))].sort();
  const providerTeams = [];
  for (let index = 0; includeProviderTeams && index < countries.length; index += 1) {
    const country = countries[index];
    const query = new URLSearchParams({ s: "Soccer", c: country });
    const url = "https://www.thesportsdb.com/api/v1/json/" +
      process.env.THE_SPORTS_DB_API_KEY + "/search_all_teams.php?" + query.toString();
    try {
      const payload = await fetchProviderJSON(url);
      for (const team of payload.teams || []) {
        if (String(team.strSport || "").toLowerCase() === "soccer") {
          providerTeams.push({
            strTeam: team.strTeam,
            strTeamShort: team.strTeamShort,
            strAlternate: team.strAlternate,
            strCountry: team.strCountry,
            strLeague: team.strLeague,
            strColour1: team.strColour1,
            strColour2: team.strColour2,
            strColour3: team.strColour3,
            strBadge: team.strBadge,
          });
        }
      }
    } catch (error) {
      process.stderr.write("Provider lookup failed for " + country + ": " + error.message + "\n");
    }
    if ((index + 1) % 20 === 0 || index + 1 === countries.length) {
      process.stderr.write("Provider countries " + (index + 1) + "/" + countries.length + "\n");
    }
    await sleep(180);
  }
  await mongo.closeMongoConnection();
  console.log(REMOTE_MARKER + JSON.stringify({ inventory, providerTeams }));
})().catch(async (error) => {
  process.stderr.write(String(error && error.stack || error) + "\n");
  await mongo.closeMongoConnection().catch(() => {});
  process.exit(1);
});
`;

  const result = spawnSync(
    "ssh",
    [
      "sky",
      "cd /home/mwagstaff/dev/top-scores && set -a && . ./.env.local >/dev/null 2>&1 && set +a && node",
    ],
    {
      input: remoteScript,
      encoding: "utf8",
      maxBuffer: 80 * 1024 * 1024,
      timeout: 15 * 60 * 1000,
    }
  );

  if (result.stderr) process.stderr.write(result.stderr);
  if (result.status !== 0) {
    throw new Error(`Remote provider audit failed with status ${result.status}`);
  }
  const markerIndex = result.stdout.lastIndexOf(REMOTE_MARKER);
  if (markerIndex < 0) {
    throw new Error("Remote provider audit returned no parseable payload");
  }
  return JSON.parse(result.stdout.slice(markerIndex + REMOTE_MARKER.length).trim());
}

function fetchRemoteDirectProviderData(names) {
  if (!names.length) return [];
  const remoteScript = String.raw`
const REMOTE_MARKER = ${JSON.stringify(REMOTE_MARKER)};
const names = ${JSON.stringify(names)};

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function fetchProviderJSON(url) {
  for (let attempt = 1; attempt <= 4; attempt += 1) {
    const response = await fetch(url, { headers: { Accept: "application/json" } });
    if (response.ok) return response.json();
    if (response.status !== 429 || attempt === 4) {
      throw new Error("TheSportsDB HTTP " + response.status);
    }
    const retryAfter = Number(response.headers.get("retry-after"));
    await sleep(Number.isFinite(retryAfter) ? retryAfter * 1000 : 61000);
  }
  return {};
}

(async () => {
  const results = [];
  for (let index = 0; index < names.length; index += 1) {
    const name = names[index];
    const url = "https://www.thesportsdb.com/api/v1/json/" +
      process.env.THE_SPORTS_DB_API_KEY + "/searchteams.php?t=" + encodeURIComponent(name);
    try {
      const payload = await fetchProviderJSON(url);
      results.push({
        query: name,
        teams: (payload.teams || [])
          .filter((team) => String(team.strSport || "").toLowerCase() === "soccer")
          .map((team) => ({
            strTeam: team.strTeam,
            strTeamShort: team.strTeamShort,
            strAlternate: team.strAlternate,
            strCountry: team.strCountry,
            strLeague: team.strLeague,
            strColour1: team.strColour1,
            strColour2: team.strColour2,
            strColour3: team.strColour3,
            strBadge: team.strBadge,
          })),
      });
    } catch (error) {
      process.stderr.write("Direct provider lookup failed for " + name + ": " + error.message + "\n");
    }
    if ((index + 1) % 50 === 0 || index + 1 === names.length) {
      process.stderr.write("Direct provider teams " + (index + 1) + "/" + names.length + "\n");
    }
    await sleep(650);
  }
  console.log(REMOTE_MARKER + JSON.stringify(results));
})().catch((error) => {
  process.stderr.write(String(error && error.stack || error) + "\n");
  process.exit(1);
});
`;

  const result = spawnSync(
    "ssh",
    [
      "sky",
      "cd /home/mwagstaff/dev/top-scores && set -a && . ./.env.local >/dev/null 2>&1 && set +a && node",
    ],
    {
      input: remoteScript,
      encoding: "utf8",
      maxBuffer: 40 * 1024 * 1024,
      timeout: 20 * 60 * 1000,
    }
  );

  if (result.stderr) process.stderr.write(result.stderr);
  if (result.status !== 0) {
    throw new Error(`Remote direct provider audit failed with status ${result.status}`);
  }
  const markerIndex = result.stdout.lastIndexOf(REMOTE_MARKER);
  if (markerIndex < 0) {
    throw new Error("Remote direct provider audit returned no parseable payload");
  }
  return JSON.parse(result.stdout.slice(markerIndex + REMOTE_MARKER.length).trim());
}

function logoRecords() {
  const records = [];
  const directories = fs
    .readdirSync(LOGO_ASSETS_PATH, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.endsWith(".imageset"));

  directories.forEach((directory) => {
    const assetName = directory.name.slice(0, -".imageset".length);
    if (/^_noTeamLogo/i.test(assetName)) return;
    const directoryPath = path.join(LOGO_ASSETS_PATH, directory.name);
    const contentsPath = path.join(directoryPath, "Contents.json");
    let fileName = null;
    try {
      const contents = JSON.parse(fs.readFileSync(contentsPath, "utf8"));
      fileName = (contents.images || []).map((image) => image.filename).find(Boolean) || null;
    } catch (_error) {
      fileName = null;
    }
    if (!fileName) return;
    const imagePath = path.join(directoryPath, fileName);
    if (!fs.existsSync(imagePath)) return;
    records.push({ name: assetName, imagePath });
  });
  return records;
}

function saturation(red, green, blue) {
  const maximum = Math.max(red, green, blue) / 255;
  const minimum = Math.min(red, green, blue) / 255;
  const delta = maximum - minimum;
  const lightness = (maximum + minimum) / 2;
  return delta === 0 ? 0 : delta / (1 - Math.abs(2 * lightness - 1));
}

function paletteFromImage(input, usesStandardInput = false) {
  const imageArguments = [
    usesStandardInput ? "-" : input,
    "-resize",
    "80x80>",
    "-alpha",
    "on",
    "-colors",
    "12",
    "-format",
    "%c",
    "histogram:info:-",
  ];
  const result = spawnSync(
    "magick",
    imageArguments,
    {
      encoding: "utf8",
      input: usesStandardInput ? input : undefined,
      maxBuffer: 4 * 1024 * 1024,
    }
  );
  if (result.status !== 0) return null;

  const colors = result.stdout
    .split("\n")
    .map((line) => {
      const match = line.match(/^\s*(\d+):.*#([0-9A-F]{16}|[0-9A-F]{8})\b/i);
      if (!match) return null;
      const count = Number(match[1]);
      const raw = match[2].toUpperCase();
      const rgba = raw.length === 16
        ? [0, 4, 8, 12]
            .map((offset) => Math.round(Number.parseInt(raw.slice(offset, offset + 4), 16) / 257))
            .map((channel) => channel.toString(16).padStart(2, "0"))
            .join("")
            .toUpperCase()
        : raw;
      const alpha = Number.parseInt(rgba.slice(6, 8), 16);
      if (alpha < 128) return null;
      const hex = `#${rgba.slice(0, 6)}`;
      const [red, green, blue] = hexChannels(hex);
      return {
        count,
        hex: normalizedColor(hex),
        saturation: saturation(red, green, blue),
        lightness: (Math.max(red, green, blue) + Math.min(red, green, blue)) / 510,
      };
    })
    .filter(Boolean);
  if (!colors.length) return null;

  const chromatic = colors.filter(
    (color) => color.saturation >= 0.18 && color.lightness >= 0.08 && color.lightness <= 0.92
  );
  if (
    !chromatic.length &&
    colors.every((color) => color.saturation < 0.12 && color.lightness > 0.58)
  ) {
    return null;
  }
  const primaryPool = chromatic.length ? chromatic : colors;
  const primaryRecord = primaryPool.reduce((best, color) => {
    const score = color.count * (0.55 + color.saturation);
    return !best || score > best.score ? { color, score } : best;
  }, null).color;

  const secondaryPool = colors.filter(
    (color) => color.hex !== primaryRecord.hex && colorDistance(color.hex, primaryRecord.hex) >= 45
  );
  if (!secondaryPool.length) return styleFromColors(primaryRecord.hex, null);
  const secondaryRecord = secondaryPool.reduce((best, color) => {
    const distance = colorDistance(color.hex, primaryRecord.hex) / 441;
    const score = color.count * (0.45 + distance);
    return !best || score > best.score ? { color, score } : best;
  }, null).color;
  return styleFromColors(primaryRecord.hex, secondaryRecord.hex);
}

function paletteFromLogo(imagePath) {
  return paletteFromImage(imagePath);
}

async function paletteFromRemoteLogo(url) {
  const normalizedURL = String(url || "").trim();
  if (!/^https:\/\//i.test(normalizedURL)) return null;
  try {
    const response = await fetch(normalizedURL, {
      headers: { Accept: "image/*" },
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok) return null;
    const data = Buffer.from(await response.arrayBuffer());
    if (!data.length || data.length > 12 * 1024 * 1024) return null;
    return paletteFromImage(data, true);
  } catch (_error) {
    return null;
  }
}

function providerStyle(record) {
  if (!record) return null;
  const candidates = [record.strColour1, record.strColour2, record.strColour3]
    .map(validHex)
    .filter(Boolean);
  if (!candidates.length) return null;
  const primary = candidates[0];
  const secondary =
    candidates.slice(1).find((candidate) => colorDistance(primary, candidate) >= 38) || null;
  return styleFromColors(primary, secondary);
}

function configuredKeys(config) {
  const keys = new Set();
  [...(config.teams || []), ...(config.identity_groups || [])].forEach((entry) => {
    [entry.name, ...(entry.aliases || [])].forEach((name) => {
      const key = identityKey(name);
      if (key) keys.add(key);
    });
  });
  return keys;
}

function uniqueInventory(records) {
  const byKey = new Map();
  records.forEach((record) => {
    const name = String(record.name || record.Name || "").trim();
    if (isPlaceholderTeam(name)) return;
    const key = identityKey(name);
    if (!key) return;
    const existing = byKey.get(key);
    const next = {
      name,
      shortName: String(record.shortName || "").trim(),
      country: String(record.country || record.Country || "").trim(),
    };
    if (!existing || (!existing.country && next.country)) byKey.set(key, next);
  });
  return [...byKey.values()].sort((left, right) => left.name.localeCompare(right.name));
}

function aliasesFor(name, shortName, provider, logo) {
  const aliases = [];
  const canonicalKey = identityKey(name);
  [
    shortName,
    ...(provider ? teamNames(provider) : []),
    logo ? logo.name : null,
  ].forEach((candidate) => {
    const trimmed = String(candidate || "").trim();
    if (!trimmed || identityKey(trimmed) === canonicalKey) return;
    if (trimmed.length < 3 || aliases.some((alias) => identityKey(alias) === identityKey(trimmed))) {
      return;
    }
    aliases.push(trimmed);
  });
  return aliases;
}

function aliasLookup(config) {
  const canonicalByKey = new Map();
  Object.entries(config.aliases || {}).forEach(([alias, canonical]) => {
    canonicalByKey.set(identityKey(alias), String(canonical || "").trim());
  });
  for (const group of config.identity_groups || []) {
    for (const alias of group.aliases || []) {
      canonicalByKey.set(identityKey(alias), group.name);
    }
  }
  return canonicalByKey;
}

function searchNamesForTeam(name, aliases) {
  const output = [name];
  const canonical = aliases.get(identityKey(name));
  if (canonical && identityKey(canonical) !== identityKey(name)) output.push(canonical);
  return output;
}

async function main() {
  const auditOnly = process.argv.includes("--audit-only");
  const externalOnly = process.argv.includes("--external-only");
  const gsaOnly = process.argv.includes("--gsa-only");
  const knownWebOnly = process.argv.includes("--known-web-only");
  const config = JSON.parse(fs.readFileSync(API_CONFIG_PATH, "utf8"));
  config.teams = config.teams.filter((team) => !isPlaceholderTeam(team.name));
  const initialCount = config.teams.length;
  const aliasesConfig = JSON.parse(fs.readFileSync(TEAM_ALIASES_PATH, "utf8"));
  const aliases = aliasLookup(aliasesConfig);
  const remote = fetchRemoteProviderData(
    !auditOnly && !externalOnly && !gsaOnly && !knownWebOnly
  );
  const publicTeams = await fetchJson(PUBLIC_TEAMS_URL);
  const logos = logoRecords();
  const inventory = uniqueInventory([
    ...remote.inventory,
    ...(Array.isArray(publicTeams) ? publicTeams : []),
    ...logos.map((logo) => ({ name: logo.name })),
  ]);

  if (auditOnly) {
    const knownKeys = configuredKeys(config);
    const unresolved = inventory.filter((team) =>
      searchNamesForTeam(team.name, aliases).every((name) => !knownKeys.has(identityKey(name)))
    );
    process.stdout.write(
      `${JSON.stringify({
        inventory: inventory.length,
        configured: config.teams.length,
        unresolved,
      }, null, 2)}\n`
    );
    return;
  }

  if (gsaOnly) {
    const knownKeys = configuredKeys(config);
    const unresolved = inventory.filter((team) =>
      searchNamesForTeam(team.name, aliases).every((name) => !knownKeys.has(identityKey(name)))
    );
    const gsa = await resolveWithGlobalSportsArchive(unresolved, aliases);
    for (const result of gsa.resolved) {
      const entry = {
        name: result.team.name,
        aliases: aliasesFor(result.team.name, result.team.shortName, null, null),
        primary: result.style.primary,
        secondary: result.style.secondary,
        scheme: result.style.scheme,
      };
      config.teams.push(entry);
    }
    config.updatedAt = new Date().toISOString().slice(0, 10);
    config.teams.sort((left, right) => left.name.localeCompare(right.name));
    const serialized = `${JSON.stringify(config, null, 2)}\n`;
    fs.writeFileSync(API_CONFIG_PATH, serialized);
    fs.writeFileSync(IOS_CONFIG_PATH, serialized);
    process.stdout.write(`${JSON.stringify({
      inventory: inventory.length,
      initial: initialCount,
      added: gsa.resolved.length,
      final: config.teams.length,
      sourceCounts: { globalSportsArchiveCrest: gsa.resolved.length },
      unresolved: gsa.unresolved.map((team) => team.name),
    }, null, 2)}\n`);
    return;
  }

  if (knownWebOnly) {
    const knownKeys = configuredKeys(config);
    const unresolved = inventory.filter((team) =>
      searchNamesForTeam(team.name, aliases).every((name) => !knownKeys.has(identityKey(name)))
    );
    const web = await resolveWithKnownWebSources(unresolved);
    for (const result of web.resolved) {
      const entry = {
        name: result.team.name,
        aliases: [...new Map(
          [...(result.aliases || []), result.team.shortName]
            .map((name) => String(name || "").trim())
            .filter((name) => name && identityKey(name) !== identityKey(result.team.name))
            .map((name) => [identityKey(name), name])
        ).values()],
        primary: result.style.primary,
        secondary: result.style.secondary,
        scheme: result.style.scheme,
      };
      config.teams.push(entry);
    }
    config.updatedAt = new Date().toISOString().slice(0, 10);
    config.teams.sort((left, right) => left.name.localeCompare(right.name));
    const serialized = `${JSON.stringify(config, null, 2)}\n`;
    fs.writeFileSync(API_CONFIG_PATH, serialized);
    fs.writeFileSync(IOS_CONFIG_PATH, serialized);
    const sourceCounts = web.resolved.reduce((counts, result) => {
      counts[result.source] = (counts[result.source] || 0) + 1;
      return counts;
    }, {});
    process.stdout.write(`${JSON.stringify({
      inventory: inventory.length,
      initial: initialCount,
      added: web.resolved.length,
      final: config.teams.length,
      sourceCounts,
      unresolved: web.unresolved.map((team) => team.name),
    }, null, 2)}\n`);
    return;
  }

  if (externalOnly) {
    const knownKeys = configuredKeys(config);
    const unresolved = inventory.filter((team) =>
      searchNamesForTeam(team.name, aliases).every((name) => !knownKeys.has(identityKey(name)))
    );
    const external = await resolveWithOpenRegistry(unresolved, aliases);
    const fotmob = await resolveWithFotmobSearch(external.unresolved, aliases);
    const transfermarkt = await resolveWithTransfermarktSearch(
      fotmob.unresolved,
      aliases
    );
    const globalSportsArchive = await resolveWithGlobalSportsArchive(
      transfermarkt.unresolved,
      aliases
    );
    const knownWeb = await resolveWithKnownWebSources(
      globalSportsArchive.unresolved
    );
    const externalResolved = external.resolved
      .concat(fotmob.resolved)
      .concat(transfermarkt.resolved)
      .concat(globalSportsArchive.resolved)
      .concat(knownWeb.resolved);
    for (const result of externalResolved) {
      const aliasCandidates = [
        result.team.shortName,
        result.record?.name,
        result.match?.name,
        ...(result.aliases || []),
        ...searchNamesForTeam(result.team.name, aliases),
      ];
      const entry = {
        name: result.team.name,
        aliases: [...new Map(aliasCandidates
          .map((name) => String(name || "").trim())
          .filter((name) => name && identityKey(name) !== identityKey(result.team.name))
          .map((name) => [identityKey(name), name])).values()],
        primary: result.style.primary,
        secondary: result.style.secondary,
        scheme: result.style.scheme,
      };
      config.teams.push(entry);
    }
    config.updatedAt = new Date().toISOString().slice(0, 10);
    config.teams.sort((left, right) => left.name.localeCompare(right.name));
    const serialized = `${JSON.stringify(config, null, 2)}\n`;
    fs.writeFileSync(API_CONFIG_PATH, serialized);
    fs.writeFileSync(IOS_CONFIG_PATH, serialized);
    const sourceCounts = externalResolved.reduce((counts, result) => {
      counts[result.source] = (counts[result.source] || 0) + 1;
      return counts;
    }, {});
    process.stdout.write(`${JSON.stringify({
      inventory: inventory.length,
      initial: initialCount,
      added: externalResolved.length,
      final: config.teams.length,
      sourceCounts,
      unresolved: knownWeb.unresolved.map((team) => team.name),
    }, null, 2)}\n`);
    return;
  }

  const providerRecords = remote.providerTeams.filter(
    (team) => String(team.strTeam || "").trim() && String(team.strSport || "Soccer") !== ""
  );
  const providerIndex = buildRecordIndex(providerRecords, teamNames);
  const logoIndex = buildRecordIndex(logos, (logo) => [logo.name]);
  const knownKeys = configuredKeys(config);
  const added = [];
  let unresolved = [];
  const sourceCounts = { provider: 0, crest: 0 };

  for (let index = 0; index < inventory.length; index += 1) {
    const team = inventory[index];
    if (knownKeys.has(identityKey(team.name))) continue;

    const searchNames = searchNamesForTeam(team.name, aliases);
    const provider = searchNames
      .map((name) =>
        findBestRecord(name, team.country, providerIndex, teamNames, {
          accept: () => true,
        })
      )
      .find(Boolean);
    const logo = searchNames
      .map((name) =>
        findBestRecord(name, team.country, logoIndex, (record) => [record.name], {
          accept: () => true,
        })
      )
      .find(Boolean);
    let style = providerStyle(provider);
    let source = "provider";
    if (!style && provider?.strBadge) {
      style = await paletteFromRemoteLogo(provider.strBadge);
      source = "providerCrest";
    }
    if (!style && logo) {
      style = paletteFromLogo(logo.imagePath);
      source = "crest";
    }
    if (!style) {
      unresolved.push(team);
      continue;
    }

    const entry = {
      name: team.name,
      aliases: aliasesFor(
        team.name,
        team.shortName,
        provider,
        logo
      ).concat(
        searchNames.filter(
          (name) =>
            identityKey(name) !== identityKey(team.name) &&
            !aliasesFor(team.name, team.shortName, provider, logo).some(
              (alias) => identityKey(alias) === identityKey(name)
            )
        )
      ),
      primary: style.primary,
      secondary: style.secondary,
      scheme: style.scheme,
    };
    config.teams.push(entry);
    added.push({ name: team.name, source });
    sourceCounts[source] = (sourceCounts[source] || 0) + 1;
    [entry.name, ...entry.aliases].forEach((name) => knownKeys.add(identityKey(name)));

    if ((index + 1) % 200 === 0) {
      process.stderr.write(`Processed ${index + 1}/${inventory.length} team identities\n`);
    }
  }

  if (unresolved.length) {
    const directQueries = [
      ...new Set(
        unresolved.flatMap((team) => searchNamesForTeam(team.name, aliases))
      ),
    ];
    const directResults = fetchRemoteDirectProviderData(directQueries);
    const directByQuery = new Map(
      directResults.map((result) => [identityKey(result.query), result.teams || []])
    );
    const stillUnresolved = [];

    for (let index = 0; index < unresolved.length; index += 1) {
      const team = unresolved[index];
      const searchNames = searchNamesForTeam(team.name, aliases);
      const directCandidates = searchNames.flatMap(
        (name) => directByQuery.get(identityKey(name)) || []
      );
      const directIndex = buildRecordIndex(directCandidates, teamNames);
      const provider = searchNames
        .map((name) =>
          findBestRecord(name, team.country, directIndex, teamNames, {
            accept: () => true,
          })
        )
        .find(Boolean) || directCandidates[0] || null;
      let style = providerStyle(provider);
      let source = "directProvider";
      if (!style && provider?.strBadge) {
        style = await paletteFromRemoteLogo(provider.strBadge);
        source = "directProviderCrest";
      }
      if (!style) {
        stillUnresolved.push(team);
        continue;
      }

      const entryAliases = aliasesFor(team.name, team.shortName, provider, null);
      const entry = {
        name: team.name,
        aliases: entryAliases,
        primary: style.primary,
        secondary: style.secondary,
        scheme: style.scheme,
      };
      config.teams.push(entry);
      added.push({ name: team.name, source });
      sourceCounts[source] = (sourceCounts[source] || 0) + 1;
      [entry.name, ...entry.aliases].forEach((name) => knownKeys.add(identityKey(name)));
      if ((index + 1) % 100 === 0) {
        process.stderr.write(`Resolved direct provider teams ${index + 1}/${unresolved.length}\n`);
      }
    }
    unresolved = stillUnresolved;
  }


  if (unresolved.length) {
    const external = await resolveWithOpenRegistry(unresolved, aliases);
    for (const result of external.resolved) {
      const entryAliases = aliasesFor(
        result.team.name,
        result.team.shortName,
        null,
        null
      );
      if (
        result.record?.name &&
        identityKey(result.record.name) !== identityKey(result.team.name) &&
        !entryAliases.some((name) => identityKey(name) === identityKey(result.record.name))
      ) {
        entryAliases.push(result.record.name);
      }
      const entry = {
        name: result.team.name,
        aliases: entryAliases,
        primary: result.style.primary,
        secondary: result.style.secondary,
        scheme: result.style.scheme,
      };
      config.teams.push(entry);
      added.push({ name: result.team.name, source: result.source });
      sourceCounts[result.source] = (sourceCounts[result.source] || 0) + 1;
      [entry.name, ...entry.aliases].forEach((name) => knownKeys.add(identityKey(name)));
    }
    unresolved = external.unresolved;
  }


  if (unresolved.length) {
    const fotmob = await resolveWithFotmobSearch(unresolved, aliases);
    for (const result of fotmob.resolved) {
      const entryAliases = aliasesFor(
        result.team.name,
        result.team.shortName,
        null,
        null
      );
      if (
        result.match?.name &&
        identityKey(result.match.name) !== identityKey(result.team.name) &&
        !entryAliases.some((name) => identityKey(name) === identityKey(result.match.name))
      ) {
        entryAliases.push(result.match.name);
      }
      const entry = {
        name: result.team.name,
        aliases: entryAliases,
        primary: result.style.primary,
        secondary: result.style.secondary,
        scheme: result.style.scheme,
      };
      config.teams.push(entry);
      added.push({ name: result.team.name, source: result.source });
      sourceCounts[result.source] = (sourceCounts[result.source] || 0) + 1;
      [entry.name, ...entry.aliases].forEach((name) => knownKeys.add(identityKey(name)));
    }
    unresolved = fotmob.unresolved;
  }


  if (unresolved.length) {
    const transfermarkt = await resolveWithTransfermarktSearch(unresolved, aliases);
    for (const result of transfermarkt.resolved) {
      const entry = {
        name: result.team.name,
        aliases: aliasesFor(
          result.team.name,
          result.team.shortName,
          null,
          null
        ),
        primary: result.style.primary,
        secondary: result.style.secondary,
        scheme: result.style.scheme,
      };
      config.teams.push(entry);
      added.push({ name: result.team.name, source: result.source });
      sourceCounts[result.source] = (sourceCounts[result.source] || 0) + 1;
      [entry.name, ...entry.aliases].forEach((name) => knownKeys.add(identityKey(name)));
    }
    unresolved = transfermarkt.unresolved;
  }


  if (unresolved.length) {
    const globalSportsArchive = await resolveWithGlobalSportsArchive(unresolved, aliases);
    for (const result of globalSportsArchive.resolved) {
      const entryAliases = aliasesFor(
        result.team.name,
        result.team.shortName,
        null,
        null
      );
      if (
        result.match?.name &&
        identityKey(result.match.name) !== identityKey(result.team.name) &&
        !entryAliases.some((name) => identityKey(name) === identityKey(result.match.name))
      ) {
        entryAliases.push(result.match.name);
      }
      const entry = {
        name: result.team.name,
        aliases: entryAliases,
        primary: result.style.primary,
        secondary: result.style.secondary,
        scheme: result.style.scheme,
      };
      config.teams.push(entry);
      added.push({ name: result.team.name, source: result.source });
      sourceCounts[result.source] = (sourceCounts[result.source] || 0) + 1;
      [entry.name, ...entry.aliases].forEach((name) => knownKeys.add(identityKey(name)));
    }
    unresolved = globalSportsArchive.unresolved;
  }


  if (unresolved.length) {
    const knownWeb = await resolveWithKnownWebSources(unresolved);
    for (const result of knownWeb.resolved) {
      const entry = {
        name: result.team.name,
        aliases: [...new Map(
          [...(result.aliases || []), result.team.shortName]
            .map((name) => String(name || "").trim())
            .filter((name) => name && identityKey(name) !== identityKey(result.team.name))
            .map((name) => [identityKey(name), name])
        ).values()],
        primary: result.style.primary,
        secondary: result.style.secondary,
        scheme: result.style.scheme,
      };
      config.teams.push(entry);
      added.push({ name: result.team.name, source: result.source });
      sourceCounts[result.source] = (sourceCounts[result.source] || 0) + 1;
      [entry.name, ...entry.aliases].forEach((name) => knownKeys.add(identityKey(name)));
    }
    unresolved = knownWeb.unresolved;
  }

  config.updatedAt = new Date().toISOString().slice(0, 10);
  config.teams.sort((left, right) => left.name.localeCompare(right.name));
  const serialized = `${JSON.stringify(config, null, 2)}\n`;
  fs.writeFileSync(API_CONFIG_PATH, serialized);
  fs.writeFileSync(IOS_CONFIG_PATH, serialized);

  const report = {
    inventory: inventory.length,
    initial: initialCount,
    added: added.length,
    final: config.teams.length,
    sourceCounts,
    unresolved: unresolved.map((team) => team.name),
  };
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
});
