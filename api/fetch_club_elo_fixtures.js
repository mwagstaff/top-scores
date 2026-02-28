#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require("fs");
const http = require("http");
const https = require("https");
const path = require("path");
const { URL } = require("url");

const DEFAULT_CLUB_ELO_FIXTURES_URL = "http://api.clubelo.com/Fixtures";
const DEFAULT_CLUB_ELO_FIXTURES_OUTPUT = path.join(__dirname, "club_elo_fixtures.json");
const DEFAULT_CLUB_ELO_FIXTURES_MIN_ROWS = 100;
const DEFAULT_CLUB_ELO_FIXTURES_MIN_BYTES = 8 * 1024;
const CLUB_ELO_FIXTURES_REQUIRED_COLUMNS = ["Date", "Country", "Home", "Away"];
const DATE_ONLY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

function fetchText(url, redirectDepth = 0) {
  return new Promise((resolve, reject) => {
    if (redirectDepth > 5) {
      reject(new Error("Too many redirects while fetching Club Elo fixtures CSV"));
      return;
    }

    const target = new URL(url);
    const lib = target.protocol === "https:" ? https : http;
    const req = lib.get(
      target,
      {
        headers: {
          "User-Agent": "Mozilla/5.0 (compatible; ClubEloFixturesParser/1.0)",
          Accept: "text/csv,*/*;q=0.8",
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
          reject(new Error(`Club Elo fixtures request failed with status ${statusCode}`));
          return;
        }

        let body = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => {
          body += chunk;
        });
        res.on("end", () => {
          resolve({
            headers: res.headers || {},
            body,
          });
        });
      }
    );

    req.setTimeout(30000, () => {
      req.destroy(new Error("Club Elo fixtures request timed out"));
    });
    req.on("error", reject);
  });
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

function normalizeHeader(value) {
  return String(value || "").replace(/^\uFEFF/, "").trim();
}

function parseProbability(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function parseProbabilityMarket(label) {
  const normalized = String(label || "").trim();
  if (!normalized) {
    return {
      market: "unknown",
      outcome: "",
    };
  }
  if (normalized.startsWith("GD")) {
    return {
      market: "goal_difference",
      outcome: normalized.slice(2),
    };
  }
  if (normalized.startsWith("R:")) {
    return {
      market: "scoreline",
      outcome: normalized.slice(2),
    };
  }
  return {
    market: "other",
    outcome: normalized,
  };
}

function validateCsvResponse(response, options = {}) {
  const minRows = Number.isFinite(Number(options.minRows))
    ? Math.max(1, Math.floor(Number(options.minRows)))
    : DEFAULT_CLUB_ELO_FIXTURES_MIN_ROWS;
  const minBytes = Number.isFinite(Number(options.minBytes))
    ? Math.max(1, Math.floor(Number(options.minBytes)))
    : DEFAULT_CLUB_ELO_FIXTURES_MIN_BYTES;
  const contentType = response && response.headers ? response.headers["content-type"] : "";
  if (!isCsvContentType(contentType)) {
    throw new Error(
      `Club Elo fixtures response is not CSV content-type (received: ${contentType || "none"})`
    );
  }

  const csvText = String(response && response.body ? response.body : "");
  const byteLength = Buffer.byteLength(csvText, "utf8");
  if (byteLength < minBytes) {
    throw new Error(
      `Club Elo fixtures CSV too small (${byteLength} bytes). Expected at least ${minBytes} bytes.`
    );
  }

  const lines = nonEmptyLines(csvText);
  if (lines.length < 2) {
    throw new Error("Club Elo fixtures CSV does not include header and data rows.");
  }

  const headers = parseCsvLine(lines[0]).map((header) => normalizeHeader(header));
  const missingColumns = CLUB_ELO_FIXTURES_REQUIRED_COLUMNS.filter(
    (column) => !headers.includes(column)
  );
  if (missingColumns.length > 0) {
    throw new Error(
      `Club Elo fixtures CSV missing required columns: ${missingColumns.join(", ")}`
    );
  }

  const rowCount = lines.length - 1;
  if (rowCount < minRows) {
    throw new Error(
      `Club Elo fixtures CSV has too few rows (${rowCount}). Expected at least ${minRows}.`
    );
  }

  return {
    headers,
    lines,
    rowCount,
    byteLength,
    contentType: String(contentType || ""),
  };
}

function parseFixturesRows(lines, headers) {
  const headerIndex = new Map();
  headers.forEach((header, index) => {
    headerIndex.set(header, index);
  });

  const fixtures = [];
  lines.slice(1).forEach((line, index) => {
    const fields = parseCsvLine(line);
    if (fields.length !== headers.length) {
      throw new Error(
        `Invalid Club Elo fixtures CSV row at line ${index + 2}: expected ${headers.length} columns, got ${fields.length}.`
      );
    }

    const date = String(fields[headerIndex.get("Date")] || "").trim();
    const country = String(fields[headerIndex.get("Country")] || "").trim();
    const homeTeam = String(fields[headerIndex.get("Home")] || "").trim();
    const awayTeam = String(fields[headerIndex.get("Away")] || "").trim();
    if (!DATE_ONLY_PATTERN.test(date) || !homeTeam || !awayTeam) {
      return;
    }

    const resultChances = [];
    for (let column = 0; column < headers.length; column += 1) {
      const label = headers[column];
      if (CLUB_ELO_FIXTURES_REQUIRED_COLUMNS.includes(label)) continue;
      const probability = parseProbability(fields[column]);
      if (probability === null) continue;
      const parsedLabel = parseProbabilityMarket(label);
      resultChances.push({
        label,
        market: parsedLabel.market,
        outcome: parsedLabel.outcome,
        probability,
      });
    }

    fixtures.push({
      date,
      country: country || null,
      home_team: homeTeam,
      away_team: awayTeam,
      result_chances: resultChances,
    });
  });
  return fixtures;
}

async function fetchClubEloFixtures(options = {}) {
  const url = String(options.url || DEFAULT_CLUB_ELO_FIXTURES_URL).trim();
  if (!url) {
    throw new Error("Club Elo fixtures URL is required.");
  }

  const response = await fetchText(url);
  const validated = validateCsvResponse(response, {
    minRows: options.minRows,
    minBytes: options.minBytes,
  });
  const fixtures = parseFixturesRows(validated.lines, validated.headers);
  const minRows = Number.isFinite(Number(options.minRows))
    ? Math.max(1, Math.floor(Number(options.minRows)))
    : DEFAULT_CLUB_ELO_FIXTURES_MIN_ROWS;
  if (fixtures.length < minRows) {
    throw new Error(
      `Club Elo fixtures parsed rows too small (${fixtures.length}). Expected at least ${minRows}.`
    );
  }

  return {
    url,
    fixtures,
    headers: validated.headers,
    rowCount: fixtures.length,
    byteLength: validated.byteLength,
    contentType: validated.contentType,
  };
}

function writeClubEloFixtures(outputPath, fixtures) {
  fs.writeFileSync(outputPath, JSON.stringify(fixtures, null, 2), "utf8");
}

function getArgValue(args, flag, fallback = null) {
  const index = args.indexOf(flag);
  if (index === -1 || index + 1 >= args.length) return fallback;
  return args[index + 1];
}

async function runCli() {
  const args = process.argv.slice(2);
  const url = getArgValue(args, "--url", DEFAULT_CLUB_ELO_FIXTURES_URL);
  const outputPath = path.resolve(getArgValue(args, "--out", DEFAULT_CLUB_ELO_FIXTURES_OUTPUT));
  const minRows = Number(getArgValue(args, "--min-rows", DEFAULT_CLUB_ELO_FIXTURES_MIN_ROWS));
  const minBytes = Number(getArgValue(args, "--min-bytes", DEFAULT_CLUB_ELO_FIXTURES_MIN_BYTES));

  const result = await fetchClubEloFixtures({
    url,
    minRows,
    minBytes,
  });
  writeClubEloFixtures(outputPath, result.fixtures);
  console.log(`Saved ${result.fixtures.length} Club Elo fixtures to ${outputPath}`);
}

if (require.main === module) {
  runCli().catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

module.exports = {
  DEFAULT_CLUB_ELO_FIXTURES_URL,
  DEFAULT_CLUB_ELO_FIXTURES_OUTPUT,
  DEFAULT_CLUB_ELO_FIXTURES_MIN_ROWS,
  DEFAULT_CLUB_ELO_FIXTURES_MIN_BYTES,
  CLUB_ELO_FIXTURES_REQUIRED_COLUMNS,
  fetchClubEloFixtures,
  writeClubEloFixtures,
  __private: {
    parseCsvLine,
    validateCsvResponse,
    parseFixturesRows,
    parseProbabilityMarket,
  },
};
