#!/usr/bin/env node
/* eslint-disable no-console */
"use strict";

const http = require("http");
const https = require("https");
const { URL } = require("url");
const cheerio = require("cheerio");

const DEFAULT_URL = "https://www.live-footballontv.com/";
const DEFAULT_TIMEOUT_MS = 30_000;
const DEFAULT_MAX_BYTES = 10 * 1024 * 1024;
const DEFAULT_ATTEMPTS = 3;
const LONDON_TIME_ZONE = "Europe/London";

const MONTHS = new Map([
  ["january", 1], ["february", 2], ["march", 3], ["april", 4],
  ["may", 5], ["june", 6], ["july", 7], ["august", 8],
  ["september", 9], ["october", 10], ["november", 11], ["december", 12],
]);

function pad2(value) {
  return String(value).padStart(2, "0");
}

function parseListingDate(value) {
  const match = String(value || "").trim().match(
    /^(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]+)\s+(\d{4})$/i
  );
  if (!match) return null;
  const day = Number(match[1]);
  const month = MONTHS.get(match[2].toLowerCase());
  const year = Number(match[3]);
  if (!month || day < 1 || day > 31) return null;
  const checked = new Date(Date.UTC(year, month - 1, day));
  if (
    checked.getUTCFullYear() !== year ||
    checked.getUTCMonth() !== month - 1 ||
    checked.getUTCDate() !== day
  ) {
    return null;
  }
  return `${year}-${pad2(month)}-${pad2(day)}`;
}

function normalizeListingTime(value) {
  const match = String(value || "").trim().match(/^(\d{1,2}):(\d{2})$/);
  if (!match) return null;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return `${pad2(hour)}:${pad2(minute)}`;
}

function splitTeams(value) {
  const text = String(value || "").replace(/\s+/g, " ").trim();
  const parts = text.split(/\s+v(?:s)?\s+/i);
  if (parts.length !== 2) return null;
  const homeTeam = parts[0].trim();
  const awayTeam = parts[1].trim();
  return homeTeam && awayTeam ? { homeTeam, awayTeam } : null;
}

function parseListingsHtml(html) {
  const $ = cheerio.load(String(html || ""));
  const listings = [];
  let currentDate = null;

  $(".fixture-date, .fixture").each((_, element) => {
    const node = $(element);
    if (node.hasClass("fixture-date")) {
      currentDate = parseListingDate(node.text());
      return;
    }
    if (!currentDate || !node.hasClass("fixture")) return;

    const time = normalizeListingTime(node.find(".fixture__time").first().text());
    const teams = splitTeams(node.find(".fixture__teams").first().text());
    const competition = node.find(".fixture__competition").first().text().replace(/\s+/g, " ").trim();
    const channels = [];
    const seenChannels = new Set();
    node.find(".channel-pill").each((__, channelElement) => {
      const name = $(channelElement).text().replace(/\s+/g, " ").trim();
      const key = name.toLowerCase();
      if (!name || seenChannels.has(key)) return;
      seenChannels.add(key);
      channels.push({
        name,
        country: "United Kingdom",
        countryCode: "GB",
        logo: null,
      });
    });

    if (!time || !teams || !competition || channels.length === 0) return;
    listings.push({
      date_local: currentDate,
      time_local: time,
      time_zone: LONDON_TIME_ZONE,
      home_team: teams.homeTeam,
      away_team: teams.awayTeam,
      competition,
      channels,
    });
  });

  return listings;
}

function retryAfterMs(headers) {
  const value = headers && headers["retry-after"];
  if (!value) return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds) && seconds >= 0) return Math.min(30_000, seconds * 1000);
  const timestamp = Date.parse(String(value));
  return Number.isFinite(timestamp) ? Math.max(0, Math.min(30_000, timestamp - Date.now())) : null;
}

function requestHtml(url, options = {}, redirectCount = 0) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const transport = target.protocol === "https:" ? https : http;
    const timeoutMs = Number(options.timeoutMs) || DEFAULT_TIMEOUT_MS;
    const maxBytes = Number(options.maxBytes) || DEFAULT_MAX_BYTES;
    const userAgent = String(
      options.userAgent ||
      process.env.LIVE_FOOTBALL_TV_USER_AGENT ||
      "Top Scores TV Listings/1.0"
    ).trim();
    const req = transport.get(target, {
      headers: {
        Accept: "text/html,application/xhtml+xml",
        "Accept-Encoding": "identity",
        "User-Agent": userAgent,
      },
    }, (res) => {
      const statusCode = Number(res.statusCode || 0);
      if (statusCode >= 300 && statusCode < 400 && res.headers.location) {
        res.resume();
        if (redirectCount >= 5) {
          reject(new Error("Too many redirects while fetching TV listings"));
          return;
        }
        const redirect = new URL(res.headers.location, target).toString();
        requestHtml(redirect, options, redirectCount + 1).then(resolve, reject);
        return;
      }
      if (statusCode !== 200) {
        res.resume();
        const error = new Error(`TV listings request failed with status ${statusCode}`);
        error.statusCode = statusCode;
        error.retryAfterMs = retryAfterMs(res.headers);
        error.retryable = statusCode === 429 || statusCode >= 500;
        reject(error);
        return;
      }

      const contentType = String(res.headers["content-type"] || "").toLowerCase();
      if (contentType && !contentType.includes("text/html")) {
        res.resume();
        reject(new Error(`Unexpected TV listings content type: ${contentType}`));
        return;
      }

      let bytes = 0;
      const chunks = [];
      res.on("data", (chunk) => {
        bytes += chunk.length;
        if (bytes > maxBytes) {
          req.destroy(new Error(`TV listings response exceeded ${maxBytes} bytes`));
          return;
        }
        chunks.push(chunk);
      });
      res.on("end", () => resolve({ html: Buffer.concat(chunks).toString("utf8"), bytes }));
    });
    req.setTimeout(timeoutMs, () => req.destroy(new Error("TV listings request timed out")));
    req.on("error", reject);
  });
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function fetchLiveFootballTvListings(options = {}) {
  const url = String(options.url || process.env.LIVE_FOOTBALL_TV_URL || DEFAULT_URL).trim();
  const attempts = Math.max(1, Math.floor(Number(options.attempts) || DEFAULT_ATTEMPTS));
  let lastError = null;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await (options.requestHtml || requestHtml)(url, options);
      const listings = parseListingsHtml(response.html);
      return {
        url,
        fetched_at: new Date().toISOString(),
        html_bytes: response.bytes,
        listings,
      };
    } catch (error) {
      lastError = error;
      if (attempt >= attempts || error.retryable === false) break;
      const backoffMs = error.retryAfterMs ?? Math.min(5_000, 500 * (2 ** (attempt - 1)));
      await wait(backoffMs);
    }
  }
  throw lastError || new Error("Failed to fetch TV listings");
}

module.exports = {
  DEFAULT_URL,
  LONDON_TIME_ZONE,
  fetchLiveFootballTvListings,
  parseListingsHtml,
  __private: {
    normalizeListingTime,
    parseListingDate,
    requestHtml,
    retryAfterMs,
    splitTeams,
  },
};
