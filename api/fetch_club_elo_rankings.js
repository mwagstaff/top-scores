#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require("fs");
const cheerio = require("cheerio");
const http = require("http");
const https = require("https");
const path = require("path");
const { URL } = require("url");

const DEFAULT_CLUB_ELO_BASE_URL = "https://clubelo.com";
const DEFAULT_CLUB_ELO_TIMEZONE = "Europe/London";
const DEFAULT_CLUB_ELO_OUTPUT = path.join(__dirname, "club_elo_teams.json");
const DEFAULT_CLUB_ELO_MIN_ROWS = 600;
const DEFAULT_CLUB_ELO_MIN_BYTES = 10 * 1024;
const CLUB_ELO_HEADER_ROW = "Rank,Club,Country,Level,Elo,From,To";

function safeDateFormatter(timeZone, options) {
  try {
    return new Intl.DateTimeFormat("en-GB", { ...options, timeZone });
  } catch (_error) {
    return new Intl.DateTimeFormat("en-GB", options);
  }
}

function clubEloDateInTimeZone(date = new Date(), timeZone = DEFAULT_CLUB_ELO_TIMEZONE) {
  const formatter = safeDateFormatter(timeZone, {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  const parts = formatter.formatToParts(date);
  const get = (type) => {
    const part = parts.find((candidate) => candidate.type === type);
    return part ? part.value : "";
  };
  const year = get("year");
  const month = get("month");
  const day = get("day");
  if (!year || !month || !day) {
    return new Date().toISOString().split("T")[0];
  }
  return `${year}-${month}-${day}`;
}

function buildClubEloUrl(baseUrl) {
  const normalizedBase = String(baseUrl || DEFAULT_CLUB_ELO_BASE_URL).replace(/\/+$/, "");
  // Migrate existing deployments that still override the retired CSV host.
  if (/^https?:\/\/api\.clubelo\.com$/i.test(normalizedBase)) return `${DEFAULT_CLUB_ELO_BASE_URL}/Ranking`;
  return `${normalizedBase}/Ranking`;
}

function fetchText(url, redirectDepth = 0) {
  return new Promise((resolve, reject) => {
    if (redirectDepth > 5) {
      reject(new Error("Too many redirects while fetching Club Elo rankings"));
      return;
    }

    const target = new URL(url);
    const lib = target.protocol === "https:" ? https : http;
    const req = lib.get(
      target,
      {
        headers: {
          "User-Agent": "Mozilla/5.0 (compatible; ClubEloParser/1.0)",
          Accept: "text/html,*/*;q=0.8",
        },
      },
      (res) => {
        const statusCode = Number(res.statusCode || 0);
        if (statusCode >= 300 && statusCode < 400 && res.headers.location) {
          const redirectUrl = new URL(res.headers.location, target).toString();
          res.resume();
          fetchText(redirectUrl, redirectDepth + 1).then(resolve).catch(reject);
          return;
        }
        if (statusCode !== 200) {
          res.resume();
          reject(new Error(`Club Elo request failed with status ${statusCode}`));
          return;
        }

        let data = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => {
          data += chunk;
        });
        res.on("end", () => {
          resolve({
            headers: res.headers || {},
            body: data,
          });
        });
      }
    );

    req.setTimeout(30000, () => {
      req.destroy(new Error("Club Elo request timed out"));
    });
    req.on("error", reject);
  });
}

function isCsvContentType(value) {
  const normalized = String(value || "").toLowerCase();
  if (!normalized) return false;
  if (normalized.includes("text/csv")) return true;
  if (normalized.includes("application/csv")) return true;
  if (normalized.includes("application/vnd.ms-excel")) return true;
  return normalized.includes("csv");
}

function nonEmptyLines(text) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function parseCsvLine(line) {
  const output = [];
  let current = "";
  let inQuotes = false;
  for (let index = 0; index < line.length; index += 1) {
    const ch = line[index];
    if (ch === "\"") {
      if (inQuotes && line[index + 1] === "\"") {
        current += "\"";
        index += 1;
        continue;
      }
      inQuotes = !inQuotes;
      continue;
    }
    if (ch === "," && !inQuotes) {
      output.push(current.trim());
      current = "";
      continue;
    }
    current += ch;
  }
  output.push(current.trim());
  return output;
}

function validateCsvResponse(response, options = {}) {
  const minRows = Number.isFinite(Number(options.minRows))
    ? Math.max(1, Math.floor(Number(options.minRows)))
    : DEFAULT_CLUB_ELO_MIN_ROWS;
  const minBytes = Number.isFinite(Number(options.minBytes))
    ? Math.max(1, Math.floor(Number(options.minBytes)))
    : DEFAULT_CLUB_ELO_MIN_BYTES;
  const contentType = response && response.headers ? response.headers["content-type"] : "";
  if (!isCsvContentType(contentType)) {
    throw new Error(`Club Elo response is not CSV content-type (received: ${contentType || "none"})`);
  }

  const csvText = String(response && response.body ? response.body : "");
  const byteLength = Buffer.byteLength(csvText, "utf8");
  if (byteLength < minBytes) {
    throw new Error(
      `Club Elo CSV too small (${byteLength} bytes). Expected at least ${minBytes} bytes.`
    );
  }

  const lines = nonEmptyLines(csvText);
  if (lines.length < 2) {
    throw new Error("Club Elo CSV does not include header and data rows.");
  }

  const header = String(lines[0] || "").replace(/^\uFEFF/, "").trim();
  if (header !== CLUB_ELO_HEADER_ROW) {
    throw new Error(`Unexpected Club Elo CSV header: "${header}"`);
  }

  const rowCount = lines.length - 1;
  if (rowCount < minRows) {
    throw new Error(`Club Elo CSV has too few rows (${rowCount}). Expected at least ${minRows}.`);
  }

  return {
    rowCount,
    byteLength,
    contentType: String(contentType || ""),
    csvText,
    lines,
  };
}

function toNumber(value, fallback = null) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function normalizeDateOnly(value) {
  const trimmed = String(value || "").trim();
  return /^\d{4}-\d{2}-\d{2}$/.test(trimmed) ? trimmed : null;
}

function parseClubEloRows(lines) {
  const rows = [];
  lines.slice(1).forEach((line, index) => {
    const fields = parseCsvLine(line);
    if (fields.length !== 7) {
      throw new Error(
        `Invalid Club Elo CSV row at line ${index + 2}: expected 7 columns, got ${fields.length}.`
      );
    }
    const [, clubRaw, countryRaw, levelRaw, eloRaw, fromRaw, toRaw] = fields;
    const club = String(clubRaw || "").trim();
    if (!club) return;
    rows.push({
      Club: club,
      Country: String(countryRaw || "").trim() || null,
      Level: toNumber(levelRaw),
      Elo: toNumber(eloRaw),
      From: normalizeDateOnly(fromRaw),
      To: normalizeDateOnly(toRaw),
    });
  });
  return rows;
}

function rankByElo(rows) {
  const sorted = rows
    .filter((row) => row && typeof row === "object")
    .slice()
    .sort((left, right) => {
      const leftElo = Number.isFinite(left.Elo) ? left.Elo : Number.NEGATIVE_INFINITY;
      const rightElo = Number.isFinite(right.Elo) ? right.Elo : Number.NEGATIVE_INFINITY;
      if (rightElo !== leftElo) return rightElo - leftElo;
      const leftClub = String(left.Club || "");
      const rightClub = String(right.Club || "");
      return leftClub.localeCompare(rightClub);
    });

  return sorted.map((row, index) => ({
    Name: row.Club,
    Rank: index + 1,
    Club: row.Club,
    Country: row.Country,
    Level: row.Level,
    Elo: row.Elo,
    From: row.From,
    To: row.To,
  }));
}

// Read published HTML only; never execute the upstream page's scripts.
function parseRankingPage(response, options = {}) {
  const body = String(response.body || "");
  const contentType = String(response.headers["content-type"] || "");
  const byteLength = Buffer.byteLength(body);
  if (!contentType.includes("text/html")) throw new Error("Club Elo response is not HTML");
  if (byteLength < (options.minBytes ?? DEFAULT_CLUB_ELO_MIN_BYTES)) {
    throw new Error("Club Elo rankings page is too small");
  }
  const $ = cheerio.load(body);
  const date = $(".accordion-major-item a").map((_i, el) => $(el).text().trim())
    .get().find((value) => /^\d{4}-\d{2}-\d{2}$/.test(value));
  const age = Date.now() - Date.parse(date);
  if (!date || !Number.isFinite(age) || age > 7 * 86400000 || age < -86400000) {
    throw new Error("Club Elo rankings page has a missing or stale publication date");
  }
  const rows = new Map();
  $(".accordion-item").each((_i, section) => {
    const country = $(section).find(".accordion-header a").first().attr("href");
    if (!country || !/^\/?[A-Z]{3}$/.test(country)) return;
    let level = null;
    $(section).find(".accordion-content tr").each((_j, tr) => {
      if ($(tr).closest(".accordion-item")[0] !== section) return;
      const cells = $(tr).children("td");
      const levelMatch = cells.first().find("i").text().match(/Level (\d+)/);
      if (levelMatch) level = Number(levelMatch[1]);
      const club = cells.first().find(".Ast").text().trim();
      const rating = cells.eq(1).text().trim();
      // Provisional ratings (e.g. 1554p) are not established Elo scores.
      if (!club || !/^\d+(?:\.\d+)?$/.test(rating)) return;
      const code = country.replace("/", "");
      const key = `${code}:${club}`;
      // Same-name lower-division entries cannot be distinguished by our name-based catalog.
      // Keep the strongest entry, consistent with ranking-order matching.
      if (rows.has(key) && rows.get(key).Elo >= Number(rating)) return;
      rows.set(key, {
        Club: club === "Internazionale" ? "Inter" : club,
        Country: code,
        Level: level,
        Elo: Number(rating),
        From: date,
        To: null,
      });
    });
  });
  // The chart carries more precise scores for the top 100. Its data is JSON,
  // unlike the separate JavaScript table literal, which we intentionally ignore.
  for (const match of body.matchAll(/(?:const|let|var)\s+vegaJson\s*=\s*(\{[\s\S]*?\});/g)) {
    const chart = JSON.parse(match[1]);
    for (const dataset of Object.values(chart.datasets || {})) {
      if (!Array.isArray(dataset)) continue;
      for (const item of dataset) {
        const row = rows.get(`${item.FedURL}:${item.Name}`);
        if (row && Number.isFinite(item.Elo)) row.Elo = item.Elo;
      }
    }
  }
  if (rows.size < (options.minRows ?? DEFAULT_CLUB_ELO_MIN_ROWS)) {
    throw new Error(`Club Elo rankings page has too few teams (${rows.size})`);
  }
  return { rows: [...rows.values()], date, byteLength, contentType };
}

async function fetchClubEloRankings(options = {}) {
  const url = buildClubEloUrl(options.baseUrl || DEFAULT_CLUB_ELO_BASE_URL);
  const response = await fetchText(url);
  const validated = parseRankingPage(response, options);
  if (options.date && options.date !== validated.date) {
    throw new Error("Club Elo website only supplies its latest published rankings");
  }
  const teams = rankByElo(validated.rows);

  return {
    date: validated.date,
    url,
    teams,
    rowCount: teams.length,
    byteLength: validated.byteLength,
    contentType: validated.contentType,
  };
}

function writeClubEloRankings(outputPath, teams) {
  fs.writeFileSync(outputPath, JSON.stringify(teams, null, 2), "utf8");
}

function getArgValue(args, flag, fallback = null) {
  const index = args.indexOf(flag);
  if (index === -1 || index + 1 >= args.length) return fallback;
  return args[index + 1];
}

async function runCli() {
  const args = process.argv.slice(2);
  const baseUrl = getArgValue(args, "--base-url", DEFAULT_CLUB_ELO_BASE_URL);
  const outputPath = path.resolve(getArgValue(args, "--out", DEFAULT_CLUB_ELO_OUTPUT));
  const timeZone = getArgValue(args, "--timezone", DEFAULT_CLUB_ELO_TIMEZONE);
  const date = getArgValue(args, "--date", null);
  const minRows = Number(getArgValue(args, "--min-rows", DEFAULT_CLUB_ELO_MIN_ROWS));
  const minBytes = Number(getArgValue(args, "--min-bytes", DEFAULT_CLUB_ELO_MIN_BYTES));

  const result = await fetchClubEloRankings({
    baseUrl,
    date,
    timeZone,
    minRows,
    minBytes,
  });
  writeClubEloRankings(outputPath, result.teams);
  console.log(
    `Saved ${result.teams.length} Club Elo teams for ${result.date} to ${outputPath}`
  );
}

if (require.main === module) {
  runCli().catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

module.exports = {
  DEFAULT_CLUB_ELO_BASE_URL,
  DEFAULT_CLUB_ELO_TIMEZONE,
  DEFAULT_CLUB_ELO_OUTPUT,
  DEFAULT_CLUB_ELO_MIN_ROWS,
  DEFAULT_CLUB_ELO_MIN_BYTES,
  CLUB_ELO_HEADER_ROW,
  clubEloDateInTimeZone,
  fetchClubEloRankings,
  writeClubEloRankings,
  __private: {
    parseRankingPage,
    parseCsvLine,
    validateCsvResponse,
    parseClubEloRows,
    rankByElo,
    buildClubEloUrl,
  },
};
