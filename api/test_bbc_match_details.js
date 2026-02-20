#!/usr/bin/env node
/* eslint-disable no-console */
const { URL } = require("url");
const { parseMatchDetailsFromHtml } = require("./fetch_bbc_scores");

const DEFAULT_HEADERS = {
  "User-Agent": "Mozilla/5.0 (compatible; BBCSportMatchDetailsTester/1.0)",
};

function normalizeInputUrl(value) {
  const raw = String(value || "").trim();
  if (!raw) return null;
  try {
    return new URL(raw).toString();
  } catch (err) {
    return null;
  }
}

function usage() {
  console.error("Usage: node test_bbc_match_details.js <bbc-match-details-url>");
  console.error("Example: node test_bbc_match_details.js https://www.bbc.co.uk/sport/football/live/c98g4jxd8jpt");
}

async function fetchHtml(url) {
  const response = await fetch(url, { headers: DEFAULT_HEADERS, redirect: "follow" });
  if (!response.ok) {
    throw new Error(`Request failed with status ${response.status}`);
  }
  return response.text();
}

function emptyDetails() {
  return {
    home_goal_scorers: [],
    away_goal_scorers: [],
    home_red_cards: [],
    away_red_cards: [],
    home_assists: [],
    away_assists: [],
  };
}

async function main() {
  const inputUrl = process.argv[2];
  const detailsUrl = normalizeInputUrl(inputUrl);
  if (!detailsUrl) {
    usage();
    process.exit(1);
  }

  const html = await fetchHtml(detailsUrl);
  const parsed = parseMatchDetailsFromHtml(html) || emptyDetails();
  const output = {
    details_url: detailsUrl,
    ...parsed,
  };
  console.log(JSON.stringify(output, null, 2));
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err.stack || err.message || String(err));
    process.exit(1);
  });
}
