#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require("fs");
const http = require("http");
const https = require("https");
const path = require("path");
const { URL } = require("url");

const LEAGUE_TABLE_SOURCES = [
  {
    id: "premier-league",
    name: "Premier League",
    url: "https://www.bbc.co.uk/sport/football/premier-league/table",
  },
  {
    id: "championship",
    name: "Championship",
    url: "https://www.bbc.co.uk/sport/football/championship/table",
  },
  {
    id: "champions-league",
    name: "UEFA Champions League",
    url: "https://www.bbc.co.uk/sport/football/champions-league/table",
  },
  {
    id: "scottish-premiership",
    name: "Scottish Premiership",
    url: "https://www.bbc.co.uk/sport/football/scottish-premiership/table",
  },
  {
    id: "la-liga",
    name: "La Liga",
    url: "https://www.bbc.co.uk/sport/football/spanish-la-liga/table",
  },
  {
    id: "europa-league",
    name: "UEFA Europa League",
    url: "https://www.bbc.co.uk/sport/football/europa-league/table",
  },
  {
    id: "europa-conference-league",
    name: "UEFA Conference League",
    url: "https://www.bbc.co.uk/sport/football/europa-conference-league/table",
  },
];

const DEFAULT_BBC_LEAGUE_TABLES_OUTPUT = path.join(__dirname, "bbc_league_tables.json");
let bbcLeagueTablesRequestObserver = null;

function setBbcLeagueTablesRequestObserver(observer) {
  bbcLeagueTablesRequestObserver = typeof observer === "function" ? observer : null;
}

function notifyBbcLeagueTablesRequestObserver(event) {
  if (typeof bbcLeagueTablesRequestObserver !== "function" || !event || typeof event !== "object") {
    return;
  }
  try {
    bbcLeagueTablesRequestObserver(event);
  } catch (_error) {
    // Metrics hooks must never break scraping.
  }
}

function fetchHtml(url, options = {}) {
  return new Promise((resolve, reject) => {
    const requestedUrl = String(url || "").trim();
    const initiator = String(options.initiator || "").trim() || "scraper";
    const reason = String(options.reason || "").trim() || "bbc_league_tables_fetch";
    const trigger = String(options.trigger || "").trim() || null;
    const startedAtMs = Date.now();
    const target = new URL(requestedUrl);
    const lib = target.protocol === "https:" ? https : http;
    let settled = false;

    const complete = ({ statusCode, error, html }) => {
      if (settled) return;
      settled = true;
      notifyBbcLeagueTablesRequestObserver({
        source: "bbc_league_tables",
        initiator,
        reason,
        trigger,
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
          "User-Agent": "Mozilla/5.0 (compatible; BBCTablesParser/1.0)",
        },
      },
      (res) => {
        const statusCode = Number(res.statusCode || 0);
        if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          const redirect = new URL(res.headers.location, target).toString();
          res.resume();
          fetchHtml(redirect, options).then(resolve).catch(reject);
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

function toInteger(value, { min = Number.MIN_SAFE_INTEGER, max = Number.MAX_SAFE_INTEGER } = {}) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return null;
  const rounded = Math.trunc(parsed);
  if (rounded < min || rounded > max) return null;
  return rounded;
}

function toPositiveInteger(value) {
  return toInteger(value, { min: 1 });
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

function extractFootballTableData(initialData) {
  if (!initialData || typeof initialData !== "object" || !initialData.data) return null;
  const footballTableKey = Object.keys(initialData.data).find((key) =>
    key.startsWith("football-table?")
  );
  if (!footballTableKey) return null;
  const record = initialData.data[footballTableKey];
  return record && record.data ? record.data : null;
}

function normalizeFormGuide(formGuide) {
  if (!Array.isArray(formGuide)) return [];
  return formGuide
    .map((entry) => {
      if (typeof entry === "string") return normalizeText(entry).toUpperCase();
      if (!entry || typeof entry !== "object") return "";
      const value = normalizeText(entry.value || entry.result || entry.code).toUpperCase();
      return value;
    })
    .map((value) => value.slice(0, 1))
    .filter((value) => value === "W" || value === "D" || value === "L")
    .slice(-5);
}

function normalizeParticipant(participant) {
  if (!participant || typeof participant !== "object") return null;
  const position = toPositiveInteger(participant.rank);
  const team = normalizeText(participant.name || participant.shortName);
  if (!position || !team) return null;
  const played = toInteger(participant.matchesPlayed, { min: 0 });
  const won = toInteger(participant.wins, { min: 0 });
  const drawn = toInteger(participant.draws, { min: 0 });
  const lost = toInteger(participant.losses, { min: 0 });
  const goalsFor = toInteger(participant.goalsScoredFor, { min: 0 });
  const goalsAgainst = toInteger(participant.goalsScoredAgainst, { min: 0 });
  const goalDifference = toInteger(participant.goalDifference);
  const points = toInteger(participant.points, { min: 0 });

  return {
    position,
    team,
    played: played ?? 0,
    won: won ?? 0,
    drawn: drawn ?? 0,
    lost: lost ?? 0,
    goals_for: goalsFor ?? 0,
    goals_against: goalsAgainst ?? 0,
    goal_difference: goalDifference ?? 0,
    points: points ?? 0,
    form: normalizeFormGuide(participant.formGuide),
    rank_status: normalizeText(participant.rankStatus) || null,
  };
}

function scoreRoundCandidate(round) {
  const participants = Array.isArray(round && round.participants) ? round.participants : [];
  if (participants.length === 0) return 0;
  let score = participants.length * 100;
  const positioned = participants.filter((participant) => toPositiveInteger(participant.rank));
  if (positioned.length === participants.length) score += 20;
  const uniqueRanks = new Set(positioned.map((participant) => participant.rank));
  if (uniqueRanks.size === participants.length) score += 20;
  return score;
}

function chooseBestRound(tournaments) {
  let best = null;
  for (const tournament of tournaments) {
    const stages = Array.isArray(tournament && tournament.stages) ? tournament.stages : [];
    for (const stage of stages) {
      const rounds = Array.isArray(stage && stage.rounds) ? stage.rounds : [];
      for (const round of rounds) {
        const participants = Array.isArray(round && round.participants) ? round.participants : [];
        if (participants.length === 0) continue;
        const candidate = {
          tournament,
          stage,
          round,
          score: scoreRoundCandidate(round),
        };
        if (!best || candidate.score > best.score) {
          best = candidate;
        }
      }
    }
  }
  return best;
}

function extractLeagueTableFromHtml(html, source) {
  const initialData = extractWindowJson(html, "__INITIAL_DATA__");
  if (!initialData) {
    throw new Error("Could not find __INITIAL_DATA__ payload");
  }

  const footballTableData = extractFootballTableData(initialData);
  if (!footballTableData) {
    throw new Error("Could not find football table payload");
  }

  const tournaments = Array.isArray(footballTableData.tournaments)
    ? footballTableData.tournaments
    : [];
  const best = chooseBestRound(tournaments);
  if (!best) {
    throw new Error("Could not find round participants in football table payload");
  }

  const rows = best.round.participants
    .map(normalizeParticipant)
    .filter(Boolean)
    .sort((left, right) => left.position - right.position);

  if (!rows.length) {
    throw new Error("Could not parse participant rows from football table payload");
  }

  return {
    league_id: source.id,
    league_name: source.name,
    stage_name: normalizeText(best.stage && best.stage.name) || null,
    source_url: source.url,
    updated_at: normalizeText(best.tournament && best.tournament.lastUpdated) || null,
    rows,
  };
}

async function fetchLeagueTable(source, options = {}) {
  const html = await fetchHtml(source.url, {
    ...options,
    reason: options.reason || `bbc_league_table_fetch:${source.id}`,
  });
  return extractLeagueTableFromHtml(html, source);
}

async function fetchLeagueTables(sources = LEAGUE_TABLE_SOURCES, options = {}) {
  const settled = await Promise.allSettled(
    sources.map((source) => fetchLeagueTable(source, options))
  );
  const tables = [];
  const errors = [];

  settled.forEach((result, index) => {
    if (result.status === "fulfilled") {
      tables.push(result.value);
      return;
    }
    errors.push({
      league_id: sources[index].id,
      league_name: sources[index].name,
      source_url: sources[index].url,
      message: result.reason && result.reason.message ? result.reason.message : String(result.reason),
    });
  });

  return {
    tables,
    errors,
  };
}

function writeLeagueTables(outputPath, tables) {
  fs.writeFileSync(outputPath, JSON.stringify(tables, null, 2), "utf8");
}

async function main() {
  const args = process.argv.slice(2);
  const outputIdx = args.indexOf("--output");
  const output =
    outputIdx !== -1 && args[outputIdx + 1]
      ? args[outputIdx + 1]
      : DEFAULT_BBC_LEAGUE_TABLES_OUTPUT;

  const { tables, errors } = await fetchLeagueTables();
  if (errors.length) {
    errors.forEach((error) => {
      console.warn(`[league_tables] ${error.league_id}: ${error.message}`);
    });
  }
  if (!tables.length) {
    throw new Error("Failed to fetch all league tables");
  }

  writeLeagueTables(output, tables);
  console.log(`Wrote ${tables.length} league tables to ${output}`);
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err.stack || err.message || String(err));
    process.exit(1);
  });
}

module.exports = {
  LEAGUE_TABLE_SOURCES,
  DEFAULT_BBC_LEAGUE_TABLES_OUTPUT,
  extractLeagueTableFromHtml,
  fetchLeagueTable,
  fetchLeagueTables,
  setBbcLeagueTablesRequestObserver,
  writeLeagueTables,
};
