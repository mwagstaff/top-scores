#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require("fs");
const http = require("http");
const https = require("https");
const path = require("path");
const { URL } = require("url");
const cheerio = require("cheerio");

const DEFAULT_BBC_TABLES_URL = "https://www.bbc.co.uk/sport/football/tables";
const DEFAULT_BBC_PREMIER_LEAGUE_OUTPUT = path.join(
  __dirname,
  "bbc_premier_league_teams.json"
);
let bbcPremierLeagueRequestObserver = null;

function setBbcPremierLeagueRequestObserver(observer) {
  bbcPremierLeagueRequestObserver = typeof observer === "function" ? observer : null;
}

function notifyBbcPremierLeagueRequestObserver(event) {
  if (typeof bbcPremierLeagueRequestObserver !== "function" || !event || typeof event !== "object") {
    return;
  }
  try {
    bbcPremierLeagueRequestObserver(event);
  } catch (_error) {
    // Metrics hooks must never break scraping.
  }
}

const POSITION_KEYS = [
  "position",
  "pos",
  "rank",
  "tablePosition",
  "table_position",
  "place",
  "standing",
  "order",
];

const TEAM_NAME_KEYS = [
  "name",
  "fullName",
  "full_name",
  "shortName",
  "short_name",
  "displayName",
  "display_name",
  "teamName",
  "team_name",
  "clubName",
  "club_name",
  "title",
];

const TEAM_OBJECT_KEYS = ["team", "club", "participant", "competitor", "side"];

function fetchHtml(url) {
  return new Promise((resolve, reject) => {
    const requestedUrl = String(url || "").trim();
    const startedAtMs = Date.now();
    const target = new URL(requestedUrl);
    const lib = target.protocol === "https:" ? https : http;
    let settled = false;

    const complete = ({ statusCode, error, html }) => {
      if (settled) return;
      settled = true;
      notifyBbcPremierLeagueRequestObserver({
        source: "bbc_premier_league_table",
        url: requestedUrl,
        statusCode,
        durationMs: Date.now() - startedAtMs,
        timestampMs: Date.now(),
      });
      if (error) {
        reject(error);
        return;
      }
      resolve(html);
    };

    const req = lib.get(
      target,
      {
        headers: {
          "User-Agent": "Mozilla/5.0 (compatible; BBCTableParser/1.0)",
        },
      },
      (res) => {
        const statusCode = Number(res.statusCode || 0);
        if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          const redirect = new URL(res.headers.location, target).toString();
          res.resume();
          fetchHtml(redirect).then(resolve).catch(reject);
          return;
        }

        if (res.statusCode !== 200) {
          res.resume();
          const error = new Error(`Request failed with status ${statusCode}`);
          error.statusCode = statusCode;
          error.code = `HTTP_${statusCode}`;
          error.url = requestedUrl;
          complete({ statusCode, error });
          return;
        }

        let data = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => {
          data += chunk;
        });
        res.on("end", () => complete({ statusCode, html: data }));
      }
    );

    req.setTimeout(30000, () => {
      const error = new Error("Request timed out");
      error.code = "ETIMEDOUT";
      error.url = requestedUrl;
      req.destroy(error);
    });
    req.on("error", (error) => {
      if (!error.url) error.url = requestedUrl;
      complete({
        statusCode:
          Number.isFinite(Number(error.statusCode)) && Number(error.statusCode) >= 0
            ? Number(error.statusCode)
            : 0,
        error,
      });
    });
  });
}

function normalizeText(value) {
  if (!value) return "";
  return String(value).replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim();
}

function normalizeKey(value) {
  return normalizeText(value)
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "");
}

function isPremierLeagueLabel(value) {
  const key = normalizeKey(value);
  return key.includes("premierleague") && !key.includes("womens");
}

function toPosition(value) {
  if (typeof value === "number" && Number.isInteger(value) && value > 0 && value < 200) {
    return value;
  }
  if (typeof value === "string") {
    const cleaned = normalizeText(value).match(/\d+/);
    if (cleaned) {
      const parsed = Number(cleaned[0]);
      if (Number.isInteger(parsed) && parsed > 0 && parsed < 200) {
        return parsed;
      }
    }
  }
  return null;
}

function isLikelyTeamName(value) {
  const name = normalizeText(value);
  if (!name) return false;
  if (name.length < 2 || name.length > 80) return false;
  if (!/[a-z]/i.test(name)) return false;
  const key = normalizeKey(name);
  if (["pts", "played", "won", "drawn", "lost", "goaldifference"].includes(key)) return false;
  return true;
}

function extractPositionFromObject(node) {
  if (!node || typeof node !== "object") return null;

  for (const key of POSITION_KEYS) {
    const parsed = toPosition(node[key]);
    if (parsed) return parsed;
  }

  if (node.stats && typeof node.stats === "object") {
    for (const key of POSITION_KEYS) {
      const parsed = toPosition(node.stats[key]);
      if (parsed) return parsed;
    }
  }

  return null;
}

function extractTeamNameFromObject(node) {
  if (!node) return null;
  if (typeof node === "string") {
    return isLikelyTeamName(node) ? normalizeText(node) : null;
  }
  if (typeof node !== "object") return null;

  for (const key of TEAM_NAME_KEYS) {
    if (typeof node[key] === "string" && isLikelyTeamName(node[key])) {
      return normalizeText(node[key]);
    }
  }

  for (const key of TEAM_OBJECT_KEYS) {
    const nested = node[key];
    if (!nested) continue;
    const nestedName = extractTeamNameFromObject(nested);
    if (nestedName) return nestedName;
  }

  return null;
}

function dedupeAndSortRows(rows) {
  const byPosition = new Map();
  rows.forEach((row) => {
    if (!row || !row.position || !row.team) return;
    if (!byPosition.has(row.position)) {
      byPosition.set(row.position, row);
      return;
    }

    const existing = byPosition.get(row.position);
    if (normalizeText(row.team).length > normalizeText(existing.team).length) {
      byPosition.set(row.position, row);
    }
  });

  return Array.from(byPosition.values()).sort((a, b) => a.position - b.position);
}

function hasSequentialPositions(rows) {
  if (!rows.length) return false;
  for (let index = 0; index < rows.length; index += 1) {
    if (rows[index].position !== index + 1) return false;
  }
  return true;
}

function scoreCandidate(rows, premierLeagueContext) {
  if (!rows.length) return 0;
  let score = rows.length;
  if (premierLeagueContext) score += 100;
  if (rows.length === 20) score += 20;
  if (hasSequentialPositions(rows)) score += 40;
  if (rows[0] && rows[0].position === 1) score += 5;
  return score;
}

function chooseBestCandidate(candidates) {
  if (!candidates.length) return [];
  const sorted = [...candidates].sort((a, b) => {
    if (a.score !== b.score) return b.score - a.score;
    if (a.rows.length !== b.rows.length) return b.rows.length - a.rows.length;
    return 0;
  });
  return sorted[0].rows;
}

function extractRowsFromArray(entries) {
  if (!Array.isArray(entries) || entries.length < 10) return [];
  const rows = [];
  entries.forEach((entry) => {
    if (!entry || typeof entry !== "object") return;
    const position = extractPositionFromObject(entry);
    const team = extractTeamNameFromObject(entry);
    if (!position || !team) return;
    rows.push({ position, team });
  });
  return dedupeAndSortRows(rows);
}

function hasPremierLeagueContextSignal(node) {
  if (!node || typeof node !== "object") return false;

  const directKeys = [
    "name",
    "title",
    "label",
    "description",
    "slug",
    "league",
    "competition",
    "tournament",
  ];

  for (const key of directKeys) {
    const value = node[key];
    if (typeof value === "string" && isPremierLeagueLabel(value)) return true;
    if (value && typeof value === "object") {
      const nestedName = extractTeamNameFromObject(value);
      if (nestedName && isPremierLeagueLabel(nestedName)) return true;
      if (typeof value.name === "string" && isPremierLeagueLabel(value.name)) return true;
      if (typeof value.title === "string" && isPremierLeagueLabel(value.title)) return true;
      if (typeof value.label === "string" && isPremierLeagueLabel(value.label)) return true;
      if (typeof value.slug === "string" && isPremierLeagueLabel(value.slug)) return true;
    }
  }

  return false;
}

function collectCandidatesFromJson(node, inPremierLeagueContext, candidates, seen) {
  if (!node) return;

  if (Array.isArray(node)) {
    if (!seen.has(node)) {
      seen.add(node);
      const rows = extractRowsFromArray(node);
      if (rows.length >= 10) {
        candidates.push({
          rows,
          score: scoreCandidate(rows, inPremierLeagueContext),
        });
      }
    }
    node.forEach((entry) => {
      collectCandidatesFromJson(entry, inPremierLeagueContext, candidates, seen);
    });
    return;
  }

  if (typeof node !== "object") return;

  const nextContext = inPremierLeagueContext || hasPremierLeagueContextSignal(node);

  Object.entries(node).forEach(([key, value]) => {
    const keyContext = nextContext || isPremierLeagueLabel(key);
    collectCandidatesFromJson(value, keyContext, candidates, seen);
  });
}

function extractWindowStringLiteral(html, varName) {
  const marker = `window.${varName}`;
  const start = html.indexOf(marker);
  if (start === -1) return null;
  let idx = html.indexOf("=", start);
  if (idx === -1) return null;
  idx += 1;
  while (idx < html.length && /\s/.test(html[idx])) idx += 1;
  const quote = html[idx];
  if (quote !== "\"" && quote !== "'") return null;
  idx += 1;
  let raw = "";
  let escaped = false;
  for (; idx < html.length; idx += 1) {
    const ch = html[idx];
    if (escaped) {
      raw += ch;
      escaped = false;
      continue;
    }
    if (ch === "\\") {
      raw += ch;
      escaped = true;
      continue;
    }
    if (ch === quote) break;
    raw += ch;
  }
  if (idx >= html.length) return null;
  return raw;
}

function extractWindowJson(html, varName) {
  const raw = extractWindowStringLiteral(html, varName);
  if (!raw) return null;
  try {
    const jsonText = JSON.parse(`"${raw}"`);
    return JSON.parse(jsonText);
  } catch (err) {
    return null;
  }
}

function extractJsonScriptBlocks(html) {
  const blocks = [];
  const $ = cheerio.load(html);
  $("script").each((_, node) => {
    const content = normalizeText($(node).html() || "");
    if (!content) return;
    if (!content.startsWith("{") && !content.startsWith("[")) return;
    try {
      blocks.push(JSON.parse(content));
    } catch (err) {
      // ignore parse failures
    }
  });
  return blocks;
}

function parsePremierLeagueRowsFromJson(html) {
  const candidates = [];
  const seen = new WeakSet();

  const initialData = extractWindowJson(html, "__INITIAL_DATA__");
  if (initialData) {
    collectCandidatesFromJson(initialData, false, candidates, seen);
  }

  const nextData = extractWindowJson(html, "__NEXT_DATA__");
  if (nextData) {
    collectCandidatesFromJson(nextData, false, candidates, seen);
  }

  extractJsonScriptBlocks(html).forEach((block) => {
    collectCandidatesFromJson(block, false, candidates, seen);
  });

  return chooseBestCandidate(candidates);
}

function parseRowFromTable($row, $) {
  const rowText = normalizeText($row.text());
  if (!rowText) return null;

  const attrs = [
    $row.attr("data-position"),
    $row.attr("data-pos"),
    $row.attr("data-rank"),
    $row.attr("aria-rowindex"),
  ];
  const cellTexts = $row
    .find("th, td")
    .map((_, el) => normalizeText($(el).text()))
    .get();
  const allPositionCandidates = [...attrs, ...cellTexts];

  let position = null;
  for (const candidate of allPositionCandidates) {
    const parsed = toPosition(candidate);
    if (parsed) {
      position = parsed;
      break;
    }
  }
  if (!position) return null;

  const teamSelectors = [
    "[data-testid*='team']",
    "[class*='TeamName']",
    "[class*='teamName']",
    "[class*='team-name']",
    "a[href*='/football/teams/']",
    "a",
  ];
  const names = [];
  $row.find(teamSelectors.join(",")).each((_, el) => {
    const text = normalizeText($(el).text());
    if (isLikelyTeamName(text)) {
      names.push(text);
    }
  });

  cellTexts.forEach((text) => {
    if (!isLikelyTeamName(text)) return;
    if (toPosition(text)) return;
    names.push(text);
  });

  const dedupedNames = Array.from(new Set(names));
  if (!dedupedNames.length) return null;
  dedupedNames.sort((a, b) => b.length - a.length);
  return { position, team: dedupedNames[0] };
}

function parsePremierLeagueRowsFromDom(html) {
  const $ = cheerio.load(html);
  const candidates = [];

  $("table").each((_, tableNode) => {
    const $table = $(tableNode);
    const contextTexts = [
      normalizeText($table.find("caption").first().text()),
      normalizeText($table.prevAll("h1,h2,h3,h4").first().text()),
      normalizeText(
        $table.closest("section,article,div").find("h1,h2,h3,h4").first().text()
      ),
    ].filter(Boolean);
    const inPremierLeagueContext = contextTexts.some((text) => isPremierLeagueLabel(text));

    const rows = [];
    $table.find("tr").each((__, rowNode) => {
      const row = parseRowFromTable($(rowNode), $);
      if (row) rows.push(row);
    });

    const deduped = dedupeAndSortRows(rows);
    if (deduped.length >= 10) {
      candidates.push({
        rows: deduped,
        score: scoreCandidate(deduped, inPremierLeagueContext),
      });
    }
  });

  return chooseBestCandidate(candidates);
}

function extractPremierLeagueTeamsFromHtml(html) {
  const jsonRows = parsePremierLeagueRowsFromJson(html);
  const domRows = parsePremierLeagueRowsFromDom(html);
  const rows = chooseBestCandidate([
    { rows: jsonRows, score: scoreCandidate(jsonRows, false) },
    { rows: domRows, score: scoreCandidate(domRows, false) },
  ]);
  return rows.map((row) => row.team);
}

async function fetchPremierLeagueTeams(url = DEFAULT_BBC_TABLES_URL) {
  const html = await fetchHtml(url);
  return extractPremierLeagueTeamsFromHtml(html);
}

function writePremierLeagueTeams(outputPath, teams) {
  fs.writeFileSync(outputPath, JSON.stringify(teams, null, 2), "utf8");
}

async function main() {
  const args = process.argv.slice(2);
  const urlIdx = args.indexOf("--url");
  const outputIdx = args.indexOf("--output");
  const url = urlIdx !== -1 && args[urlIdx + 1] ? args[urlIdx + 1] : DEFAULT_BBC_TABLES_URL;
  const output =
    outputIdx !== -1 && args[outputIdx + 1]
      ? args[outputIdx + 1]
      : DEFAULT_BBC_PREMIER_LEAGUE_OUTPUT;

  const teams = await fetchPremierLeagueTeams(url);
  writePremierLeagueTeams(output, teams);
  console.log(`Wrote ${teams.length} Premier League teams to ${output}`);
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err.stack || err.message || String(err));
    process.exit(1);
  });
}

module.exports = {
  DEFAULT_BBC_TABLES_URL,
  DEFAULT_BBC_PREMIER_LEAGUE_OUTPUT,
  extractPremierLeagueTeamsFromHtml,
  fetchPremierLeagueTeams,
  setBbcPremierLeagueRequestObserver,
  writePremierLeagueTeams,
};
