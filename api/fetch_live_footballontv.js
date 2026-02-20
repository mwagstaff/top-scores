#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require("fs");
const http = require("http");
const https = require("https");
const path = require("path");
const { URL } = require("url");
const cheerio = require("cheerio");

const DEFAULT_URL = "https://www.live-footballontv.com/";
const DEFAULT_OUTPUT = path.join(__dirname, "matches.json");

const DATE_RE = /^(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+\d{1,2}(st|nd|rd|th)?\s+[A-Za-z]+\s+\d{4}$/;
const TIME_RE = /^\d{1,2}:\d{2}$/;
const MATCH_RE = /\s+v\s+|\s+vs\s+/i;

const MONTHS = {
  January: 1,
  February: 2,
  March: 3,
  April: 4,
  May: 5,
  June: 6,
  July: 7,
  August: 8,
  September: 9,
  October: 10,
  November: 11,
  December: 12,
  Jan: 1,
  Feb: 2,
  Mar: 3,
  Apr: 4,
  Jun: 6,
  Jul: 7,
  Aug: 8,
  Sep: 9,
  Sept: 9,
  Oct: 10,
  Nov: 11,
  Dec: 12,
};

function pad2(value) {
  return String(value).padStart(2, "0");
}

function fetchHtml(url) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const lib = target.protocol === "https:" ? https : http;
    const req = lib.get(
      target,
      {
        headers: {
          "User-Agent": "Mozilla/5.0 (compatible; LiveFootballOnTVParser/1.0)",
        },
      },
      (res) => {
        if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          const redirect = new URL(res.headers.location, target).toString();
          res.resume();
          fetchHtml(redirect).then(resolve).catch(reject);
          return;
        }

        if (res.statusCode !== 200) {
          res.resume();
          reject(new Error(`Request failed with status ${res.statusCode}`));
          return;
        }

        let data = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => {
          data += chunk;
        });
        res.on("end", () => resolve(data));
      }
    );

    req.setTimeout(30000, () => {
      req.destroy(new Error("Request timed out"));
    });
    req.on("error", reject);
  });
}

function iterTextTokens($) {
  const tokens = [];
  const nodes = $("body").find("*").addBack().contents();
  nodes.each((_, node) => {
    if (node.type !== "text") return;
    const parentName = node.parent && node.parent.name;
    if (parentName && ["script", "style", "noscript"].includes(parentName)) {
      return;
    }
    const text = String(node.data || "").replace(/\s+/g, " ").trim();
    if (text) tokens.push(text);
  });
  return tokens;
}

function parseDate(text) {
  const parts = text.split(/\s+/);
  if (parts.length < 4) {
    throw new Error(`Unrecognized date format: ${text}`);
  }
  const day = parts[1].replace(/(st|nd|rd|th)$/i, "");
  const monthName = parts[2];
  const year = parts[3];
  const month = MONTHS[monthName];
  if (!month) {
    throw new Error(`Unrecognized date format: ${text}`);
  }
  return `${year}-${pad2(month)}-${pad2(day)}`;
}

function normalizeTime(text) {
  const [hour, minute] = text.split(":");
  return `${pad2(parseInt(hour, 10))}:${minute}`;
}

function splitMatch(text) {
  const parts = text.split(/\s+v\s+|\s+vs\s+/i);
  if (parts.length < 2) {
    return [text.trim(), ""];
  }
  const home = parts[0].trim();
  let away = parts[1].trim();
  away = away.replace(/\s*\([^)]*\)\s*$/, "").trim();
  return [home, away];
}

function splitChannelLines(lines) {
  const channels = [];
  lines.forEach((line) => {
    let chunks;
    if (line.includes("|")) {
      chunks = line.split("|").map((c) => c.trim()).filter(Boolean);
    } else if (line.includes("•")) {
      chunks = line.split("•").map((c) => c.trim()).filter(Boolean);
    } else if (line.includes("/") && !line.includes("http")) {
      chunks = line.split("/").map((c) => c.trim()).filter(Boolean);
    } else if (line.includes(",")) {
      chunks = line.split(",").map((c) => c.trim()).filter(Boolean);
    } else {
      chunks = [line.trim()];
    }
    channels.push(...chunks);
  });

  const seen = new Set();
  const deduped = [];
  channels.forEach((channel) => {
    if (!seen.has(channel)) {
      seen.add(channel);
      deduped.push(channel);
    }
  });
  return deduped;
}

function parseMatches(tokens) {
  const matches = [];
  let startIdx = -1;
  for (let i = 0; i < tokens.length; i += 1) {
    if (DATE_RE.test(tokens[i])) {
      startIdx = i;
      break;
    }
  }
  if (startIdx === -1) return matches;

  let currentDate = null;
  let i = startIdx;
  while (i < tokens.length) {
    const token = tokens[i];
    if (DATE_RE.test(token)) {
      try {
        currentDate = parseDate(token);
      } catch (err) {
        currentDate = null;
      }
      i += 1;
      continue;
    }

    if (currentDate && TIME_RE.test(token)) {
      const matchTime = normalizeTime(token);
      i += 1;
      if (i >= tokens.length) break;
      const matchLine = tokens[i];
      if (!MATCH_RE.test(matchLine)) {
        i += 1;
        continue;
      }
      const [home, away] = splitMatch(matchLine);
      i += 1;
      if (i >= tokens.length) break;
      const leagueLine = tokens[i];
      if (DATE_RE.test(leagueLine) || TIME_RE.test(leagueLine)) {
        i += 1;
        continue;
      }
      const league = leagueLine;
      i += 1;

      const channelLines = [];
      while (i < tokens.length) {
        const peek = tokens[i];
        if (DATE_RE.test(peek) || TIME_RE.test(peek)) break;
        if (MATCH_RE.test(peek)) break;
        channelLines.push(peek);
        i += 1;
      }

      const channels = splitChannelLines(channelLines);

      matches.push({
        date: currentDate,
        time: matchTime,
        home_team: home,
        away_team: away,
        league,
        tv_channels: channels,
      });
      continue;
    }

    i += 1;
  }

  return matches;
}

function getArgValue(args, flag, defaultValue) {
  const idx = args.indexOf(flag);
  if (idx === -1) return defaultValue;
  if (idx + 1 >= args.length) return defaultValue;
  return args[idx + 1];
}

async function fetchMatches(url = DEFAULT_URL) {
  const html = await fetchHtml(url);
  const $ = cheerio.load(html);
  const tokens = iterTextTokens($);
  return parseMatches(tokens);
}

function writeMatches(outputPath, matches) {
  fs.writeFileSync(outputPath, JSON.stringify(matches, null, 2), "utf8");
}

async function main() {
  const args = process.argv.slice(2);
  const url = getArgValue(args, "--url", DEFAULT_URL);
  const output = getArgValue(args, "--output", DEFAULT_OUTPUT);

  const matches = await fetchMatches(url);

  writeMatches(output, matches);
  console.log(`Wrote ${matches.length} matches to ${output}`);
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err.stack || err.message || String(err));
    process.exit(1);
  });
}

module.exports = {
  DEFAULT_URL,
  DEFAULT_OUTPUT,
  fetchMatches,
  writeMatches,
};
