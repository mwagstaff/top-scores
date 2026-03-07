#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require("fs");
const http = require("http");
const https = require("https");
const path = require("path");
const { URL } = require("url");
const cheerio = require("cheerio");

const DEFAULT_BBC_URL = "https://www.bbc.co.uk/sport/football/scores-fixtures";
const DEFAULT_BBC_OUTPUT = path.join(__dirname, "bbc_live_matches.json");
const DEFAULT_BBC_MATCH_TIMEZONE = "Europe/London";
const DEFAULT_BBC_RANGE_PAST_DAYS = 30;
const DEFAULT_BBC_RANGE_FUTURE_DAYS = 90;
const DEFAULT_BBC_RANGE_CONCURRENCY = 20;
const BBC_BASE_URL = "https://www.bbc.co.uk";

const BBC_FIXTURE_SELECTOR = "[data-event-id]";
const BBC_PARTICIPANT_SELECTOR = "[data-participant-id]";
const BBC_TEAM_NAME_WRAPPER_SELECTOR = "[class*='TeamNameWrapper']";
const BBC_SCORE_CONTAINER_SELECTOR = "[data-testid='score']";
const BBC_HOME_SCORE_SELECTOR = "[class*='HomeScore']";
const BBC_AWAY_SCORE_SELECTOR = "[class*='AwayScore']";
const BBC_STATUS_SELECTOR = "[class*='MatchProgress'] [class*='StyledPeriod']";
const BBC_AGGREGATE_SCORE_SELECTOR = "[data-testid='agg-score'], [class*='AggregateScore']";
const BBC_KICKOFF_TIME_SELECTOR = "time, [class*='StyledTime']";
const BBC_PENALTIES_SELECTOR = "[class*='PenaltiesText']";
const BBC_DETAILS_LINK_SELECTOR = "a[href*='/sport/football/']";
const BBC_KEY_EVENTS_HOME_SELECTOR = "[class$='-KeyEventsHome'], [class*='KeyEventsHome']";
const BBC_KEY_EVENTS_AWAY_SELECTOR = "[class$='-KeyEventsAway'], [class*='KeyEventsAway']";
const BBC_GROUPED_HOME_EVENT_SELECTOR = "[class$='GroupedHomeEvent'], [class*='GroupedHomeEvent']";
const BBC_GROUPED_AWAY_EVENT_SELECTOR = "[class$='GroupedAwayEvent'], [class*='GroupedAwayEvent']";
const BBC_HIDDEN_TEXT_SELECTOR = ".visually-hidden, [class*='VisuallyHidden']";
const BBC_SECONDARY_HEADING_SELECTOR = "h3[class$='SecondaryHeading'], h3[class*='SecondaryHeading-']";
const BBC_COMPETITION_FORMATTER_SELECTOR = "[class*='CompetitionFormatter']";

const BBC_DETAILS_CONCURRENCY = 4;
const BBC_DETAIL_TTL_LIVE_MS = 5 * 1000; // Reduced from 30s to 5s for fresher live match data
const BBC_DETAIL_TTL_COMPLETE_MS = 12 * 60 * 60 * 1000;
const BBC_DETAIL_FAIL_TTL_MS = 2 * 60 * 1000;
const BBC_DETAILS_CACHE_MAX_ENTRIES = 2000;
const BBC_COMPLETED_STATUSES = new Set(["FT", "AET", "Pens", "PENS", "PEN", "PEN."]);
const bbcDetailsCache = new Map();

const TEAM_SELECTORS = [
  "[data-team-name]",
  "[data-testid*='team-name']",
  "[data-testid*='teamName']",
  "[class*='team-name']",
  "[class*='teamName']",
  ".sp-c-fixture__team-name",
];

const SCORE_SELECTORS = [
  "[data-testid='score']",
  "[data-testid*='score']",
  "[class*='HomeScore']",
  "[class*='AwayScore']",
  "[class*='score']",
  ".sp-c-fixture__number",
  "[class*='number']",
];

const STATUS_SELECTORS = [
  "[class*='MatchProgress'] [class*='StyledPeriod']",
  "[data-testid*='status']",
  "[class*='status']",
  "[class*='time']",
  "[class*='minute']",
  ".sp-c-fixture__status",
  ".sp-c-fixture__time",
];

const FIXTURE_SELECTORS = [
  "[data-event-id]",
  "[data-testid*='fixture']",
  "[data-testid*='match']",
  "[class*='fixture']",
  "[class*='match']",
  "article",
];

const STATUS_ALIASES = new Map([
  ["after extra time", "AET"],
  ["half time", "HT"],
  ["half-time", "HT"],
  ["full time", "FT"],
  ["full-time", "FT"],
  ["extra time", "ET"],
  ["penalty shootout", "Pens"],
]);

function fetchHtml(url) {
  return new Promise((resolve, reject) => {
    // Add cache-busting query parameter with current timestamp
    const target = new URL(url);
    target.searchParams.set('_t', Date.now().toString());

    const lib = target.protocol === "https:" ? https : http;
    const req = lib.get(
      target,
      {
        headers: {
          "User-Agent": "Mozilla/5.0 (compatible; BBCSportParser/1.0)",
          // Additional cache-busting headers
          "Cache-Control": "no-cache, no-store, must-revalidate",
          "Pragma": "no-cache",
          "Expires": "0",
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

function normalizeText(text) {
  if (!text) return "";
  return String(text).replace(/\s+/g, " ").replace(/\u00a0/g, " ").trim();
}

function pickBestCandidate(candidates) {
  const cleaned = [];
  candidates.forEach((candidate) => {
    const value = normalizeText(candidate);
    if (!value) return;
    if (!cleaned.includes(value)) cleaned.push(value);
  });
  if (!cleaned.length) return null;
  cleaned.sort((a, b) => b.length - a.length);
  return cleaned[0];
}

function uniquePush(list, value) {
  if (!value) return;
  if (!list.includes(value)) list.push(value);
}

function toAbsoluteUrl(href, baseUrl = BBC_BASE_URL) {
  if (!href) return null;
  try {
    return new URL(href, baseUrl).toString();
  } catch (err) {
    return null;
  }
}

function stripHiddenText($node, $) {
  if (!$node || !$node.length) return "";
  const $clone = $node.clone();
  $clone.find(BBC_HIDDEN_TEXT_SELECTOR).remove();
  return normalizeText($clone.text());
}

function extractMinuteTokens(text) {
  if (!text) return [];
  const normalized = normalizeText(text)
    .replace(/(\d{1,3})\s*'\s*\+\s*(\d{1,2})/g, "$1+$2'")
    .replace(/(\d{1,3})\s*minutes?\s*plus\s*(\d{1,2})/gi, "$1+$2 minutes");
  const minutes = [];
  const seen = new Set();

  // Match patterns like "32' pen" or "45+2' pen" or just "32'"
  const apostropheRegex = /(\d{1,3}(?:\+\d{1,2})?)\s*'(?:\s+(pen|penalty))?/gi;
  let apostropheMatch = apostropheRegex.exec(normalized);
  while (apostropheMatch) {
    const minute = apostropheMatch[1];
    const isPenalty = apostropheMatch[2];
    const key = minute;
    if (!seen.has(key)) {
      seen.add(key);
      // Include "pen" suffix if it's a penalty goal
      minutes.push(isPenalty ? `${minute}' pen` : `${minute}'`);
    }
    apostropheMatch = apostropheRegex.exec(normalized);
  }

  if (minutes.length) return minutes;

  // Fallback: match "32 minutes" or "penalty 32 minutes" patterns
  const minuteWordRegex = /(penalty\s+)?(\d{1,3}(?:\+\d{1,2})?)\s*minutes?/gi;
  let minuteWordMatch = minuteWordRegex.exec(normalized);
  while (minuteWordMatch) {
    const isPenalty = minuteWordMatch[1];
    const minute = String(minuteWordMatch[2] || "").replace(/\s+/g, "");
    const key = minute;
    if (!seen.has(key)) {
      seen.add(key);
      minutes.push(isPenalty ? `${minute}' pen` : `${minute}'`);
    }
    minuteWordMatch = minuteWordRegex.exec(normalized);
  }

  return minutes;
}

function normalizePlayerName(name) {
  if (!name) return "";
  return normalizeText(name).replace(/[,:;]+$/, "");
}

function splitGroupedEventText(text) {
  if (!text) return [];
  const output = [];
  let current = "";
  let depth = 0;
  for (const ch of text) {
    if (ch === "(") depth += 1;
    if (ch === ")") depth = Math.max(0, depth - 1);
    if (ch === "," && depth === 0) {
      const item = normalizeText(current);
      if (item) output.push(item);
      current = "";
      continue;
    }
    current += ch;
  }
  const tail = normalizeText(current);
  if (tail) output.push(tail);
  return output;
}

function normalizeDetailsUrl(url, baseUrl = BBC_BASE_URL) {
  const absolute = toAbsoluteUrl(url, baseUrl);
  if (!absolute) return null;
  if (!absolute.includes("/sport/football/")) return null;
  if (absolute.includes("/sport/football/scores-fixtures")) return null;
  if (absolute.includes("/sport/football/tables")) return null;
  return absolute;
}

function scoreDetailsUrl(url) {
  if (!url) return 0;
  if (url.includes("/sport/football/live/")) return 3;
  if (url.includes("/sport/football/")) return 2;
  return 1;
}

function pickDetailsUrlFromObject(node) {
  if (!node || typeof node !== "object") return null;

  const candidates = [];
  function addCandidate(value) {
    if (typeof value !== "string") return;
    const normalized = normalizeDetailsUrl(value);
    if (!normalized) return;
    if (!candidates.includes(normalized)) candidates.push(normalized);
  }

  const directKeys = [
    "url",
    "href",
    "uri",
    "path",
    "link",
    "liveUrl",
    "matchUrl",
    "eventUrl",
    "eventUri",
    "eventPath",
    "canonicalUrl",
  ];
  directKeys.forEach((key) => addCandidate(node[key]));

  Object.values(node).forEach((value) => {
    if (!value) return;
    if (typeof value === "string") {
      addCandidate(value);
      return;
    }
    if (Array.isArray(value)) {
      value.slice(0, 6).forEach((item) => {
        if (!item || typeof item !== "object") return;
        directKeys.forEach((key) => addCandidate(item[key]));
        Object.values(item).forEach((nestedValue) => {
          if (typeof nestedValue === "string") addCandidate(nestedValue);
        });
      });
      return;
    }
    if (typeof value === "object") {
      directKeys.forEach((key) => addCandidate(value[key]));
      Object.values(value).forEach((nestedValue) => {
        if (typeof nestedValue === "string") addCandidate(nestedValue);
      });
    }
  });

  if (!candidates.length) return null;
  candidates.sort((a, b) => scoreDetailsUrl(b) - scoreDetailsUrl(a));
  return candidates[0];
}

function extractTeamsFromAttributes($node) {
  const attrs = [
    ["data-home-team", "data-away-team"],
    ["data-home", "data-away"],
    ["data-hometeam", "data-awayteam"],
    ["data-home-team-name", "data-away-team-name"],
  ];
  for (const [homeKey, awayKey] of attrs) {
    const home = normalizeText($node.attr(homeKey));
    const away = normalizeText($node.attr(awayKey));
    if (home && away) return [home, away];
  }
  return [];
}

function extractTeams($node, $) {
  const names = [];
  const fromAttrs = extractTeamsFromAttributes($node);
  fromAttrs.forEach((name) => uniquePush(names, name));

  const selector = TEAM_SELECTORS.join(",");
  $node.find(selector).each((_, el) => {
    const $el = $(el);
    let name = normalizeText($el.text());
    if (!name) {
      const attrName = $el.attr("data-team-name") || $el.attr("aria-label");
      name = normalizeText(attrName);
    }
    if (name) uniquePush(names, name);
  });

  if (names.length >= 2) return names.slice(0, 2);

  const aria = normalizeText($node.attr("aria-label"));
  if (aria) {
    const match = aria.match(/(.+?)\s+v(?:s)?\.?\s+(.+)/i);
    if (match) {
      uniquePush(names, normalizeText(match[1]));
      uniquePush(names, normalizeText(match[2]));
    }
  }

  return names.slice(0, 2);
}

function extractTeamNameFromParticipant($participant, $) {
  const wrapper = $participant.find(BBC_TEAM_NAME_WRAPPER_SELECTOR).first();
  const scope = wrapper.length ? wrapper : $participant;
  const spanCandidates = [];
  scope.find("span").each((_, el) => {
    uniquePush(spanCandidates, normalizeText($(el).text()));
  });
  const bestSpan = pickBestCandidate(spanCandidates);
  if (bestSpan) return bestSpan;
  return pickBestCandidate([
    normalizeText(scope.attr("aria-label")),
    normalizeText(scope.text()),
  ]);
}

function extractTeamsFromBbcNode($node, $) {
  const participants = $node.find(BBC_PARTICIPANT_SELECTOR);
  if (participants.length >= 2) {
    const home = extractTeamNameFromParticipant($(participants[0]), $);
    const away = extractTeamNameFromParticipant($(participants[1]), $);
    if (home && away) return [home, away];
  }
  return [];
}

function parseScorePair(text) {
  if (!text) return null;
  const cleaned = normalizeText(text).replace(/[–—]/g, "-");
  const direct = cleaned.match(/^(\d+)\s*-\s*(\d+)$/);
  if (direct) return [direct[1], direct[2]];
  return null;
}

function parseAggregateScoreText(text) {
  const cleaned = normalizeText(text).replace(/[–—]/g, "-");
  if (!cleaned) return null;

  const aggTextMatch = cleaned.match(/\(?(?:agg(?:regate)?\.?\s*:?)\s*(\d+)\s*-\s*(\d+)\)?/i);
  if (aggTextMatch) return [aggTextMatch[1], aggTextMatch[2]];

  const hiddenTextMatch = cleaned.match(/aggregate\s+score[^0-9]*(\d+)\s*,[^0-9]*(\d+)/i);
  if (hiddenTextMatch) return [hiddenTextMatch[1], hiddenTextMatch[2]];

  return null;
}

function extractScoresFromAttributes($node) {
  const attrs = [
    ["data-home-score", "data-away-score"],
    ["data-homescore", "data-awayscore"],
    ["data-homeScore", "data-awayScore"],
  ];
  for (const [homeKey, awayKey] of attrs) {
    const home = normalizeText($node.attr(homeKey));
    const away = normalizeText($node.attr(awayKey));
    if (home && away) return [home, away];
  }
  return null;
}

function extractScoresFromBbcNode($node, $) {
  const scoreContainer = $node.find(BBC_SCORE_CONTAINER_SELECTOR).first();
  if (!scoreContainer.length) return null;
  const homeScore = normalizeText(scoreContainer.find(BBC_HOME_SCORE_SELECTOR).first().text());
  const awayScore = normalizeText(scoreContainer.find(BBC_AWAY_SCORE_SELECTOR).first().text());
  if (isScoreValue(homeScore) && isScoreValue(awayScore)) {
    return [homeScore, awayScore];
  }
  return null;
}

function extractScores($node, $) {
  const fromAttrs = extractScoresFromAttributes($node);
  if (fromAttrs) return fromAttrs;

  let pair = null;
  const numbers = [];
  const selector = SCORE_SELECTORS.join(",");
  $node.find(selector).each((_, el) => {
    const text = normalizeText($(el).text());
    if (!text) return;
    if (!pair) {
      const direct = parseScorePair(text);
      if (direct) pair = direct;
    }
    const matches = text.match(/\b\d+\b/g);
    if (matches) {
      matches.forEach((num) => numbers.push(num));
    }
  });

  if (pair) return pair;
  if (numbers.length >= 2) return [numbers[0], numbers[1]];

  const text = normalizeText($node.text());
  const combined = text.match(/\b(\d+)\s*[-–—]\s*(\d+)\b/);
  if (combined) return [combined[1], combined[2]];

  return null;
}

function extractAggregateFromBbcNode($node, $) {
  const aggText = normalizeText($node.find(BBC_AGGREGATE_SCORE_SELECTOR).first().text());
  const direct = parseAggregateScoreText(aggText);
  if (direct) return direct;

  let hidden = null;
  $node.find(BBC_HIDDEN_TEXT_SELECTOR).each((_, el) => {
    if (hidden) return;
    hidden = parseAggregateScoreText(normalizeText($(el).text()));
  });
  if (hidden) return hidden;

  return parseAggregateScoreText(normalizeText($node.text()));
}

function extractAggregateFromDocument($) {
  const aggText = normalizeText($(BBC_AGGREGATE_SCORE_SELECTOR).first().text());
  const direct = parseAggregateScoreText(aggText);
  if (direct) return direct;

  let hidden = null;
  $(BBC_HIDDEN_TEXT_SELECTOR).each((_, el) => {
    if (hidden) return;
    hidden = parseAggregateScoreText(normalizeText($(el).text()));
  });
  return hidden;
}

function normalizeStatusToken(token) {
  if (!token) return null;
  const upper = token.toUpperCase();
  if (upper === "PENS" || upper === "PEN" || upper === "PEN.") return "Pens";
  if (["HT", "FT", "AET", "ET"].includes(upper)) return upper;
  return token;
}

function extractStatusFromText(text) {
  const cleaned = normalizeText(text);
  if (!cleaned) return null;
  const lower = cleaned.toLowerCase();

  // Special case: if text contains "win" and "penalties", it's a result description, not a status
  // Look for "AET" in the actual text instead
  if (lower.includes("win") && lower.includes("penalties")) {
    return null;
  }

  for (const [phrase, code] of STATUS_ALIASES.entries()) {
    if (lower.includes(phrase)) return code;
  }

  const statusMatch = cleaned.match(/\b(HT|FT|AET|ET|Pens?)\b/i);
  if (statusMatch) return normalizeStatusToken(statusMatch[1]);

  const minuteNormalized = cleaned.replace(/(\d{1,3})'\+(\d{1,2})/g, "$1+$2");
  if (/^\d{1,3}(?:\+\d{1,2})?'?$/.test(minuteNormalized)) {
    return minuteNormalized.replace(/'$/, "");
  }
  const minuteApostropheMatch = minuteNormalized.match(/\b(\d{1,3}(?:\+\d{1,2})?)'/);
  if (minuteApostropheMatch) return minuteApostropheMatch[1];
  const minuteWordsMatch = minuteNormalized.match(
    /\b(\d{1,3})(?:\s*minutes?)(?:\s*plus\s*(\d{1,2}))?\b/i
  );
  if (minuteWordsMatch) {
    const base = String(minuteWordsMatch[1] || "").trim();
    const added = String(minuteWordsMatch[2] || "").trim();
    return added ? `${base}+${added}` : base;
  }

  return null;
}

function isKickoffTime(value) {
  return /^\d{1,2}:\d{2}$/.test(value || "");
}

function extractStatus($node, $) {
  const selector = STATUS_SELECTORS.join(",");
  let status = null;
  $node.find(selector).each((_, el) => {
    if (status) return;
    const text = normalizeText($(el).text());
    const candidate = extractStatusFromText(text);
    if (candidate && !isKickoffTime(candidate)) status = candidate;
  });

  if (status) return status;

  const aria = normalizeText($node.attr("aria-label"));
  if (aria) {
    const candidate = extractStatusFromText(aria);
    if (candidate && !isKickoffTime(candidate)) return candidate;
  }

  const text = normalizeText($node.text());
  const candidate = extractStatusFromText(text);
  if (candidate && !isKickoffTime(candidate)) return candidate;

  return null;
}

function extractStatusFromBbcNode($node, $) {
  const statusEl = $node.find(BBC_STATUS_SELECTOR).first();
  const statusText = statusEl.length ? normalizeText(statusEl.text()) : "";
  const candidate = extractStatusFromText(statusText);
  if (candidate && !isKickoffTime(candidate)) {
    return candidate;
  }
  return null;
}

function extractKickoffTimeFromBbcNode($node, $) {
  const candidates = [];
  $node.find(BBC_KICKOFF_TIME_SELECTOR).each((_, el) => {
    const $el = $(el);
    uniquePush(candidates, normalizeText($el.attr("datetime")));
    uniquePush(candidates, normalizeText($el.text()));
  });

  for (const candidate of candidates) {
    const kickoff = normalizeKickoffTimeToken(candidate);
    if (kickoff) return kickoff;
  }
  return null;
}

function isMatchStarted(status) {
  return Boolean(status) && !isKickoffTime(status);
}

function isCompletedStatus(status) {
  return BBC_COMPLETED_STATUSES.has(status);
}

function detailsCacheTtlMs(status) {
  return isCompletedStatus(status) ? BBC_DETAIL_TTL_COMPLETE_MS : BBC_DETAIL_TTL_LIVE_MS;
}

function extractDetailsUrl($node, $, baseUrl = BBC_BASE_URL) {
  let liveUrl = null;
  let fallbackUrl = null;

  $node.find(BBC_DETAILS_LINK_SELECTOR).each((_, el) => {
    const href = normalizeText($(el).attr("href"));
    if (!href) return;
    const absolute = toAbsoluteUrl(href, baseUrl);
    if (!absolute || !absolute.includes("/sport/football/")) return;
    if (absolute.includes("/sport/football/scores-fixtures")) return;

    if (!liveUrl && /\/sport\/football\/live\//.test(absolute)) {
      liveUrl = absolute;
      return;
    }
    if (!fallbackUrl) fallbackUrl = absolute;
  });

  return liveUrl || fallbackUrl;
}

function normalizeDetailsUrlKey(url) {
  const value = normalizeText(url);
  if (!value) return null;
  try {
    const parsed = new URL(value, BBC_BASE_URL);
    parsed.hash = "";
    parsed.search = "";
    parsed.protocol = (parsed.protocol || "https:").toLowerCase();
    parsed.hostname = parsed.hostname.toLowerCase();
    parsed.pathname = parsed.pathname.replace(/\/+$/, "");
    return parsed.toString().toLowerCase();
  } catch (err) {
    return value.toLowerCase();
  }
}

function parseGoalScorers($container, $) {
  const byPlayer = new Map();
  if (!$container || !$container.length) return [];

  $container.find("li").each((_, li) => {
    const $li = $(li);
    const roleName = normalizePlayerName($li.find("[role='text']").first().text());
    const visibleText = stripHiddenText($li, $);
    const hiddenText = normalizeText($li.find(BBC_HIDDEN_TEXT_SELECTOR).first().text());
    const fallbackNameMatch = visibleText.match(/^([^()]+?)\s*(?:\(|$)/);
    const player = roleName || normalizePlayerName(fallbackNameMatch && fallbackNameMatch[1]);
    if (!player) {
      return;
    }

    const goalTimes = extractMinuteTokens(visibleText);
    if (!goalTimes.length) {
      return;
    }

    const hiddenLower = hiddenText.toLowerCase();
    const visibleLower = visibleText.toLowerCase();
    const hasRedCardIcon = $li.find("[data-testid='red-card-img']").length > 0;
    const isOwnGoal = hiddenLower.includes("own goal") || /\bog\b/.test(visibleLower);
    // Check if it's a goal event - includes penalty goals
    const isGoalEvent = isOwnGoal || hiddenLower.includes("goal") || hiddenLower.includes("penalty") || !hiddenLower;
    if (!isGoalEvent || hiddenLower.includes("red card") || hasRedCardIcon) {
      return;
    }

    const current = byPlayer.get(player) || { player, goal_times: [], own_goal_times: [] };
    goalTimes.forEach((time) => {
      if (isOwnGoal) {
        if (!current.own_goal_times.includes(time)) current.own_goal_times.push(time);
        return;
      }
      if (!current.goal_times.includes(time)) current.goal_times.push(time);
    });
    byPlayer.set(player, current);
  });

  return Array.from(byPlayer.values()).map((entry) => {
    const parsed = { player: entry.player };
    if (entry.goal_times.length) parsed.goal_times = entry.goal_times;
    if (entry.own_goal_times.length) parsed.own_goal_times = entry.own_goal_times;
    return parsed;
  });
}

function parseRedCards($container, $) {
  const byPlayer = new Map();
  if (!$container || !$container.length) return [];

  $container.find("li").each((_, li) => {
    const $li = $(li);
    const roleName = normalizePlayerName($li.find("[role='text']").first().text());
    const visibleText = stripHiddenText($li, $);
    const hiddenText = normalizeText($li.find(BBC_HIDDEN_TEXT_SELECTOR).first().text());
    const fallbackNameMatch = visibleText.match(/^([^()]+?)\s*(?:\(|$)/);
    const player = roleName || normalizePlayerName(fallbackNameMatch && fallbackNameMatch[1]);
    if (!player) return;

    const hiddenLower = hiddenText.toLowerCase();
    const isRedCardEvent = hiddenLower.includes("red card")
      || $li.find("[data-testid='red-card-img']").length > 0;
    if (!isRedCardEvent) return;

    const cardTimes = extractMinuteTokens(visibleText);
    if (!cardTimes.length) return;

    const current = byPlayer.get(player) || { player, red_card_times: [] };
    cardTimes.forEach((time) => {
      if (!current.red_card_times.includes(time)) current.red_card_times.push(time);
    });
    byPlayer.set(player, current);
  });

  return Array.from(byPlayer.values());
}

function parseAssistEvents($container, $) {
  if (!$container || !$container.length) return [];
  const text = stripHiddenText($container, $);
  if (!text) return [];
  const lower = text.toLowerCase();
  if (lower === "none" || lower === "n/a" || lower === "-") return [];

  const entries = splitGroupedEventText(text);
  const assists = [];
  entries.forEach((entry) => {
    const match = entry.match(/^(.+?)\s*\(([^)]+)\)$/);
    if (match) {
      const player = normalizePlayerName(match[1]);
      if (!player) return;
      assists.push({
        player,
        assist_times: extractMinuteTokens(match[2]),
      });
      return;
    }

    const player = normalizePlayerName(entry);
    if (!player) return;
    assists.push({
      player,
      assist_times: extractMinuteTokens(entry),
    });
  });

  return assists;
}

function extractMetaContent($, attribute, value) {
  return normalizeText($(`meta[${attribute}="${value}"]`).first().attr("content"));
}

function parseBbcHumanDate(dateText) {
  const normalized = normalizeText(dateText);
  if (!normalized) return null;

  const match = normalized.match(/^(?:[A-Za-z]{3,9}\s+)?(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{4})$/);
  if (!match) return null;

  const monthToken = String(match[2] || "").slice(0, 3).toLowerCase();
  const monthByToken = {
    jan: "01",
    feb: "02",
    mar: "03",
    apr: "04",
    may: "05",
    jun: "06",
    jul: "07",
    aug: "08",
    sep: "09",
    oct: "10",
    nov: "11",
    dec: "12",
  };
  const month = monthByToken[monthToken];
  if (!month) return null;

  return `${match[3]}-${String(match[1]).padStart(2, "0")}-${month}`;
}

function extractMatchIdentityFromText(text) {
  const normalized = normalizeText(text);
  if (!normalized) return null;

  const match = normalized.match(/^(.+?)\s+vs\s+(.+?)(?::|\s+in\s+the\b|$)/i);
  if (!match) return null;

  const homeTeam = normalizeText(match[1]);
  const awayTeam = normalizeText(match[2]);
  if (!homeTeam || !awayTeam) return null;

  return {
    home_team: homeTeam,
    away_team: awayTeam,
  };
}

function extractLeagueFromText(text) {
  const normalized = normalizeText(text);
  if (!normalized) return null;

  const fromTitle = normalized.match(/:\s*(.+?)\s+stats(?:\s*&\s*head-to-head)?(?:\s+-\s+BBC Sport)?$/i);
  if (fromTitle) {
    return normalizeText(fromTitle[1]);
  }

  const fromDescription = normalized.match(/\bin\s+the\s+(.+?)(?:[.!?]|$)/i);
  if (fromDescription) {
    return normalizeText(fromDescription[1]);
  }

  return null;
}

function splitCompetitionAndSubcategory(text) {
  const normalized = normalizeText(text);
  if (!normalized) return { league: null, league_subcategory: null };

  const parts = normalized
    .split(/\s*[-–—]\s*/)
    .map((part) => normalizeText(part))
    .filter(Boolean);

  if (parts.length >= 2) {
    return {
      league: parts[0],
      league_subcategory: parts.slice(1).join(" - "),
    };
  }

  return {
    league: normalized.replace(/\s*[-–—]\s*$/, "").trim() || null,
    league_subcategory: null,
  };
}

function extractCompetitionMetadata($, html) {
  const formatterParts = $(BBC_COMPETITION_FORMATTER_SELECTOR)
    .map((_, el) => normalizeText($(el).text()))
    .get()
    .filter(Boolean);

  if (formatterParts.length > 0) {
    return splitCompetitionAndSubcategory(formatterParts.join(" "));
  }

  const tournamentDescriptionMatch = html.match(/"tournamentDescriptionLabel":"([^"]+)"/i);
  if (tournamentDescriptionMatch) {
    return splitCompetitionAndSubcategory(tournamentDescriptionMatch[1]);
  }

  return {
    league:
      extractLeagueFromText($("title").first().text())
      || extractLeagueFromText(extractMetaContent($, "name", "description"))
      || extractLeagueFromText(extractMetaContent($, "property", "og:description")),
    league_subcategory: null,
  };
}

function extractDetailsPageMetadata($, html) {
  const metadata = {};
  const competition = extractCompetitionMetadata($, html);
  if (competition.league) {
    metadata.league = competition.league;
  }
  if (competition.league_subcategory) {
    metadata.league_subcategory = competition.league_subcategory;
  }

  const coverageStartMatch = html.match(/"coverageStartTime":"([^"]+)"/i);
  if (coverageStartMatch) {
    const parsedCoverageStart = parseDateTimeCandidate(
      coverageStartMatch[1],
      null,
      DEFAULT_BBC_MATCH_TIMEZONE
    );
    if (parsedCoverageStart) {
      metadata.date = parsedCoverageStart.date;
      metadata.time = parsedCoverageStart.time;
    }
  }

  if (!metadata.date || !metadata.time) {
    const dateMatch = html.match(/"date":"([^"]+)"/i);
    const accessibleTimeMatch = html.match(/"accessibleTime":"([^"]+)"/i);
    const fallbackDate = dateMatch ? parseBbcHumanDate(dateMatch[1]) : null;
    const fallbackTime = accessibleTimeMatch
      ? normalizeKickoffTimeToken(accessibleTimeMatch[1])
      : null;
    if (fallbackDate) metadata.date = metadata.date || fallbackDate;
    if (fallbackTime) metadata.time = metadata.time || fallbackTime;
  }

  const titleIdentity = extractMatchIdentityFromText($("title").first().text());
  const descriptionIdentity = extractMatchIdentityFromText(extractMetaContent($, "name", "description"));
  const identity = titleIdentity || descriptionIdentity;
  if (identity) {
    metadata.home_team = identity.home_team;
    metadata.away_team = identity.away_team;
  }

  return metadata;
}

function parseMatchDetailsFromHtml(html, homeTeam = null, awayTeam = null) {
  if (!html) return null;
  const $ = cheerio.load(html);
  const $root = $.root();
  const $homeGoals = $(BBC_KEY_EVENTS_HOME_SELECTOR).first();
  const $awayGoals = $(BBC_KEY_EVENTS_AWAY_SELECTOR).first();
  const $homeAssists = $(BBC_GROUPED_HOME_EVENT_SELECTOR).first();
  const $awayAssists = $(BBC_GROUPED_AWAY_EVENT_SELECTOR).first();
  const pageMetadata = extractDetailsPageMetadata($, html);
  const teamsFromHeader = extractTeamsFromBbcNode($root, $);
  const scoresFromHeader = extractScoresFromBbcNode($root, $);
  const resolvedHomeTeam = normalizeText(homeTeam) || teamsFromHeader[0] || pageMetadata.home_team || null;
  const resolvedAwayTeam = normalizeText(awayTeam) || teamsFromHeader[1] || pageMetadata.away_team || null;

  // Parse match status/time from the page
  const $status = $(BBC_STATUS_SELECTOR).first();
  let matchTime = null;
  if ($status.length) {
    const statusText = normalizeText($status.text());
    if (statusText) {
      const parsedStatus = extractStatusFromText(statusText);
      if (parsedStatus) {
        matchTime = parsedStatus;
      } else if (isKickoffTime(statusText)) {
        matchTime = statusText;
      }
    }
  }

  const aggregate = extractAggregateFromDocument($);

  if (
    !$homeGoals.length &&
    !$awayGoals.length &&
    !$homeAssists.length &&
    !$awayAssists.length &&
    !matchTime &&
    !aggregate &&
    !pageMetadata.league &&
    !pageMetadata.date &&
    !pageMetadata.time &&
    !resolvedHomeTeam &&
    !resolvedAwayTeam &&
    !scoresFromHeader
  ) {
    return null;
  }

  const result = {
    home_goal_scorers: parseGoalScorers($homeGoals, $),
    away_goal_scorers: parseGoalScorers($awayGoals, $),
    home_red_cards: parseRedCards($homeGoals, $),
    away_red_cards: parseRedCards($awayGoals, $),
    home_assists: parseAssistEvents($homeAssists, $),
    away_assists: parseAssistEvents($awayAssists, $),
  };

  if (pageMetadata.date) {
    result.date = pageMetadata.date;
  }
  if (pageMetadata.time) {
    result.time = pageMetadata.time;
  }
  if (pageMetadata.league) {
    result.league = pageMetadata.league;
  }
  if (pageMetadata.league_subcategory) {
    result.league_subcategory = pageMetadata.league_subcategory;
  }
  if (resolvedHomeTeam) {
    result.home_team = resolvedHomeTeam;
  }
  if (resolvedAwayTeam) {
    result.away_team = resolvedAwayTeam;
  }
  if (scoresFromHeader && isScoreValue(scoresFromHeader[0]) && isScoreValue(scoresFromHeader[1])) {
    result.home_score = toScoreValue(scoresFromHeader[0]);
    result.away_score = toScoreValue(scoresFromHeader[1]);
  }

  // Include match time/status if parsed
  if (matchTime) {
    result.match_time = matchTime;
    result.score_status = matchTime;
  }

  if (aggregate) {
    result.aggregate_home_score = aggregate[0];
    result.aggregate_away_score = aggregate[1];
  }

  // Only parse penalty result if we have team names to validate against
  if (resolvedHomeTeam && resolvedAwayTeam) {
    const penaltyResult = parsePenaltyShootoutResult($, html, resolvedHomeTeam, resolvedAwayTeam);
    if (penaltyResult) {
      result.penalty_result = penaltyResult;
    }
  }


  return result;
}

function parsePenaltyShootoutResult($, html, homeTeam, awayTeam) {
  const $penaltiesContainer = $(BBC_PENALTIES_SELECTOR).first();
  if (!$penaltiesContainer.length) return null;

  const ariaText = normalizeText($penaltiesContainer.parent().find(BBC_HIDDEN_TEXT_SELECTOR).first().text());
  const visibleText = normalizeText($penaltiesContainer.text());
  const text = ariaText || visibleText;

  if (!text) return null;

  const cleanText = text.trim();
  if (!cleanText) return null;

  // CRITICAL FIX: Validate that the penalty result text contains one of the team names
  // to prevent picking up penalty results from other matches on the same page
  const lowerText = cleanText.toLowerCase();
  const homeTeamLower = homeTeam.toLowerCase();
  const awayTeamLower = awayTeam.toLowerCase();

  if (!lowerText.includes(homeTeamLower) && !lowerText.includes(awayTeamLower)) {
    return null;
  }

  return cleanText;
}

async function fetchDetailsWithCache(detailsUrl, matchStatus, homeTeam = null, awayTeam = null) {
  if (!detailsUrl || !isMatchStarted(matchStatus)) return null;

  const now = Date.now();
  const isCompleted = isCompletedStatus(matchStatus);

  // Only use cache for completed matches - always fetch fresh data for in-progress matches
  if (isCompleted) {
    const cached = bbcDetailsCache.get(detailsUrl);
    if (cached && cached.expiresAt > now) return cached.data;
  }

  try {
    const html = await fetchHtml(detailsUrl);
    const parsed = parseMatchDetailsFromHtml(html, homeTeam, awayTeam);

    // Only cache completed matches to ensure fresh data for live matches
    if (isCompleted) {
      bbcDetailsCache.set(detailsUrl, {
        data: parsed,
        expiresAt: now + BBC_DETAIL_TTL_COMPLETE_MS,
      });
    }

    return parsed;
  } catch (err) {
    // On error, cache the failure briefly to avoid hammering BBC
    bbcDetailsCache.set(detailsUrl, {
      data: null,
      expiresAt: now + BBC_DETAIL_FAIL_TTL_MS,
    });
    return null;
  }
}

async function mapWithConcurrency(items, concurrency, worker) {
  if (!Array.isArray(items) || items.length === 0) return;
  const limit = Math.max(1, Number(concurrency) || 1);
  let cursor = 0;

  async function runWorker() {
    while (cursor < items.length) {
      const idx = cursor;
      cursor += 1;
      // eslint-disable-next-line no-await-in-loop
      await worker(items[idx], idx);
    }
  }

  const workers = [];
  const workerCount = Math.min(limit, items.length);
  for (let i = 0; i < workerCount; i += 1) {
    workers.push(runWorker());
  }
  await Promise.all(workers);
}

function pruneDetailsCache(now = Date.now()) {
  for (const [key, value] of bbcDetailsCache.entries()) {
    if (!value || !Number.isFinite(value.expiresAt) || value.expiresAt <= now) {
      bbcDetailsCache.delete(key);
    }
  }

  while (bbcDetailsCache.size > BBC_DETAILS_CACHE_MAX_ENTRIES) {
    const oldestKey = bbcDetailsCache.keys().next().value;
    if (!oldestKey) break;
    bbcDetailsCache.delete(oldestKey);
  }
}

async function enrichMatchesWithDetails(matches) {
  if (!Array.isArray(matches) || matches.length === 0) return matches;
  const enriched = matches.map((match) => ({ ...match }));
  const candidates = [];

  enriched.forEach((match, index) => {
    if (!match || !match.details_url || !isMatchStarted(match.match_time)) return;
    candidates.push({
      index,
      detailsUrl: match.details_url,
      matchStatus: match.match_time,
      homeTeam: match.home_team,
      awayTeam: match.away_team
    });
  });

  await mapWithConcurrency(candidates, BBC_DETAILS_CONCURRENCY, async (candidate) => {
    const details = await fetchDetailsWithCache(
      candidate.detailsUrl,
      candidate.matchStatus,
      candidate.homeTeam,
      candidate.awayTeam
    );
    if (!details) return;
    enriched[candidate.index] = {
      ...enriched[candidate.index],
      ...details,
    };
  });

  return enriched;
}

function findFixtureNodes($) {
  const nodes = [];
  const seen = new Set();

  const bbcNodes = $(BBC_FIXTURE_SELECTOR);
  if (bbcNodes.length) {
    bbcNodes.each((_, el) => {
      const $el = $(el);
      const card = $el.closest("article").first();
      const node = card.length ? card.get(0) : el;
      if (seen.has(node)) return;
      seen.add(node);
      nodes.push(node);
    });
    return nodes;
  }

  const selector = FIXTURE_SELECTORS.join(",");
  $(selector).each((_, el) => {
    if (seen.has(el)) return;
    const $el = $(el);
    if ($el.find(TEAM_SELECTORS.join(",")).length < 2 && extractTeamsFromAttributes($el).length < 2) {
      return;
    }
    seen.add(el);
    nodes.push(el);
  });
  return nodes;
}

function parseMatchesFromDom($) {
  const results = [];
  const nodes = findFixtureNodes($);
  nodes.forEach((node) => {
    const $node = $(node);
    const bbcTeams = extractTeamsFromBbcNode($node, $);
    const teams = bbcTeams.length ? bbcTeams : extractTeams($node, $);
    if (teams.length < 2) return;
    const aggregate = extractAggregateFromBbcNode($node, $);
    const bbcScores = extractScoresFromBbcNode($node, $);
    const scores = bbcScores || (aggregate ? null : extractScores($node, $));
    if (!scores || scores.length < 2) return;
    const kickoffTime = extractKickoffTimeFromBbcNode($node, $);
    let status = extractStatusFromBbcNode($node, $) || extractStatus($node, $);
    if ((!status || isKickoffTime(status)) && kickoffTime) {
      status = kickoffTime;
    }
    if (aggregate && !bbcScores && kickoffTime) {
      status = kickoffTime;
    }
    if (!status) return;
    const detailsUrl = extractDetailsUrl($node, $, BBC_BASE_URL);

    const parsedMatch = {
      home_team: teams[0],
      home_score: scores[0],
      away_team: teams[1],
      away_score: scores[1],
      match_time: status,
    };
    if (detailsUrl) parsedMatch.details_url = detailsUrl;
    if (aggregate) {
      parsedMatch.aggregate_home_score = aggregate[0];
      parsedMatch.aggregate_away_score = aggregate[1];
    }
    results.push(parsedMatch);
  });
  return results;
}

function collectAggregateTextCandidates(value, output, depth = 0) {
  if (value === null || value === undefined || depth > 4) return;
  if (typeof value === "string" || typeof value === "number") {
    const normalized = normalizeText(String(value));
    if (normalized) output.push(normalized);
    return;
  }
  if (Array.isArray(value)) {
    value.slice(0, 24).forEach((item) => collectAggregateTextCandidates(item, output, depth + 1));
    return;
  }
  if (typeof value !== "object") return;

  Object.entries(value).forEach(([key, nested]) => {
    if (/(agg|aggregate|status|comment|label|text|value|description)/i.test(key)) {
      collectAggregateTextCandidates(nested, output, depth + 1);
    }
  });
}

function extractAggregateFromObject(node) {
  if (!node || typeof node !== "object") return null;
  const candidates = [];
  [
    node.aggregate,
    node.aggregateScore,
    node.aggregate_score,
    node.agg,
    node.aggScore,
    node.matchProgress,
    node.statusComment,
    node.periodLabel,
    node.status,
    node.statusText,
    node.description,
  ].forEach((value) => collectAggregateTextCandidates(value, candidates));

  for (const candidate of candidates) {
    const parsed = parseAggregateScoreText(candidate);
    if (parsed) return parsed;
  }

  return null;
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

function extractSubcategory($competitionSection) {
  if (!$competitionSection || !$competitionSection.length) return null;
  const $subcategoryHeading = $competitionSection.find(BBC_SECONDARY_HEADING_SELECTOR).first();
  if (!$subcategoryHeading.length) return null;
  const text = normalizeText($subcategoryHeading.text());
  return text || null;
}

function findEventGroups(node) {
  const groups = [];
  function visit(value) {
    if (!value) return;
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }
    if (typeof value !== "object") return;
    if (Array.isArray(value.eventGroups)) {
      groups.push(...value.eventGroups);
    }
    Object.values(value).forEach(visit);
  }
  visit(node);
  return groups;
}

function pickEventScore(team) {
  if (!team || typeof team !== "object") return null;
  const candidates = [
    team.score,
    team.scoreUnconfirmed,
    team.runningScores && team.runningScores.fulltime,
    team.runningScores && team.runningScores.halftime,
  ];
  for (const candidate of candidates) {
    if (isScoreValue(candidate)) return candidate;
  }
  return null;
}

function isPostEventLifecycleStatus(value) {
  const normalized = normalizeText(value)
    .toLowerCase()
    .replace(/[\s_-]+/g, "");
  if (!normalized) return false;
  return (
    normalized === "postevent" ||
    normalized === "postmatch" ||
    normalized === "fulltime" ||
    normalized === "finished" ||
    normalized === "completed" ||
    normalized === "final"
  );
}

function terminalStatusRank(status) {
  const token = String(status || "").toUpperCase();
  if (token === "AET") return 400;
  if (token === "PENS" || token === "PEN" || token === "PEN.") return 300;
  if (token === "FT") return 200;
  return 0;
}

function pickEventStatus(event) {
  const candidates = [
    event.periodLabel && event.periodLabel.value,
    event.periodLabel && event.periodLabel.accessible,
    event.statusComment && event.statusComment.value,
    event.statusComment && event.statusComment.accessible,
    event.status,
  ];

  const lifecycleHints = [
    event.status,
    event.eventStatus,
    event.state,
    event.phase,
  ];
  const hasPostEventLifecycle = lifecycleHints.some((value) => isPostEventLifecycleStatus(value));

  const parsedCandidates = [];
  for (const candidate of candidates) {
    if (!candidate) continue;
    const status = extractStatusFromText(candidate);
    if (!status) continue;
    parsedCandidates.push(status);
  }

  // BBC event payloads can transiently keep a stale live minute in periodLabel
  // after the lifecycle has switched to post-event. Prefer terminal tokens in that phase.
  if (hasPostEventLifecycle) {
    const bestTerminal = parsedCandidates
      .filter((status) => terminalStatusRank(status) > 0)
      .sort((lhs, rhs) => terminalStatusRank(rhs) - terminalStatusRank(lhs))[0];
    if (bestTerminal) return bestTerminal;
  }

  let bestStatus = null;
  let bestRank = Number.NEGATIVE_INFINITY;
  for (const status of parsedCandidates) {
    const minuteMatch = String(status).match(/^(\d{1,3})(?:\+(\d{1,2}))?$/);
    let rank = 0;
    if (minuteMatch) {
      const base = Number(minuteMatch[1]);
      const added = Number(minuteMatch[2] || 0);
      rank = 1000 + base + added;
    } else {
      const token = String(status).toUpperCase();
      if (token === "LIVE") rank = 900;
      else if (token === "ET") rank = 800;
      else if (token === "HT") rank = 700;
      else if (token === "PENS" || token === "PEN" || token === "PEN.") rank = 650;
      else if (token === "AET") rank = 600;
      else if (token === "FT") rank = 500;
    }

    if (rank > bestRank) {
      bestRank = rank;
      bestStatus = status;
    }
  }

  return bestStatus;
}

function extractMatchFromEvent(event) {
  if (!event || typeof event !== "object") return null;
  const homeName = normalizeText(
    event.home && (event.home.fullName || (event.home.name && event.home.name.fullName) || event.home.shortName)
  );
  const awayName = normalizeText(
    event.away && (event.away.fullName || (event.away.name && event.away.name.fullName) || event.away.shortName)
  );
  if (!homeName || !awayName) return null;

  const homeScore = pickEventScore(event.home);
  const awayScore = pickEventScore(event.away);
  if (!isScoreValue(homeScore) || !isScoreValue(awayScore)) return null;

  const status = pickEventStatus(event);
  if (!status || isKickoffTime(status)) return null;

  const match = {
    home_team: homeName,
    home_score: String(homeScore),
    away_team: awayName,
    away_score: String(awayScore),
    match_time: status,
  };
  const aggregate = extractAggregateFromObject(event);
  if (aggregate) {
    match.aggregate_home_score = aggregate[0];
    match.aggregate_away_score = aggregate[1];
  }
  const detailsUrl = pickDetailsUrlFromObject(event);
  if (detailsUrl) match.details_url = detailsUrl;
  return match;
}

function parseMatchesFromInitialData(initialData) {
  const matches = [];
  const groups = findEventGroups(initialData);
  groups.forEach((group) => {
    (group.secondaryGroups || []).forEach((secondary) => {
      (secondary.events || []).forEach((event) => {
        const match = extractMatchFromEvent(event);
        if (match) matches.push(match);
      });
    });
  });
  return matches;
}

function parseMatchesFromJson(html) {
  const matches = [];
  const initialData = extractWindowJson(html, "__INITIAL_DATA__");
  if (initialData) {
    matches.push(...parseMatchesFromInitialData(initialData));
    matches.push(...collectMatchesFromObject(initialData));
  }

  const scriptMatches = html.match(/<script[^>]*>([\s\S]*?)<\/script>/gi) || [];
  scriptMatches.forEach((block) => {
    if (!block.includes("__NEXT_DATA__") && !block.includes("__INITIAL_STATE__")) return;
    const jsonMatch = block.match(/>([\s\S]*?)<\/script>/i);
    if (!jsonMatch) return;
    const raw = jsonMatch[1].trim();
    if (!raw.startsWith("{") && !raw.startsWith("[")) return;
    try {
      const data = JSON.parse(raw);
      const found = collectMatchesFromObject(data);
      matches.push(...found);
    } catch (err) {
      // ignore
    }
  });
  return matches;
}

function collectMatchesFromObject(obj) {
  const results = [];
  const seen = new Set();

  function visit(node) {
    if (!node) return;
    if (Array.isArray(node)) {
      node.forEach(visit);
      return;
    }
    if (typeof node !== "object") return;

    const match = extractMatchFromObject(node);
    if (match) {
      const key = `${match.home_team}|${match.away_team}|${match.match_time}|${match.home_score}-${match.away_score}`;
      if (!seen.has(key)) {
        seen.add(key);
        results.push(match);
      }
    }

    Object.values(node).forEach(visit);
  }

  visit(obj);
  return results;
}

function extractMatchFromObject(node) {
  const home = pickString(node, ["homeTeam", "home_team", "home", "homeName", "home_team_name"]);
  const away = pickString(node, ["awayTeam", "away_team", "away", "awayName", "away_team_name"]);
  if (!home || !away) return null;

  const score = pickScore(node);
  if (!score) return null;

  const status = pickStatus(node);
  if (!status || isKickoffTime(status)) return null;

  const match = {
    home_team: home,
    home_score: score[0],
    away_team: away,
    away_score: score[1],
    match_time: status,
  };
  const aggregate = extractAggregateFromObject(node);
  if (aggregate) {
    match.aggregate_home_score = aggregate[0];
    match.aggregate_away_score = aggregate[1];
  }
  const detailsUrl = pickDetailsUrlFromObject(node);
  if (detailsUrl) match.details_url = detailsUrl;
  return match;
}

function pickString(node, keys) {
  for (const key of keys) {
    if (typeof node[key] === "string") return normalizeText(node[key]);
    if (node[key] && typeof node[key].name === "string") return normalizeText(node[key].name);
    if (node[key] && typeof node[key].displayName === "string") return normalizeText(node[key].displayName);
  }
  return null;
}

function pickScore(node) {
  const directPairs = [
    ["homeScore", "awayScore"],
    ["home_score", "away_score"],
    ["homeTeamScore", "awayTeamScore"],
    ["home", "away"],
  ];

  for (const [homeKey, awayKey] of directPairs) {
    if (isScoreValue(node[homeKey]) && isScoreValue(node[awayKey])) {
      return [String(node[homeKey]), String(node[awayKey])];
    }
    if (node[homeKey] && node[awayKey]) {
      if (isScoreValue(node[homeKey].score) && isScoreValue(node[awayKey].score)) {
        return [String(node[homeKey].score), String(node[awayKey].score)];
      }
      if (isScoreValue(node[homeKey].goals) && isScoreValue(node[awayKey].goals)) {
        return [String(node[homeKey].goals), String(node[awayKey].goals)];
      }
    }
  }

  if (node.score && typeof node.score === "string") {
    const pair = parseScorePair(node.score);
    if (pair) return pair;
  }

  return null;
}

function isScoreValue(value) {
  return typeof value === "number" || (typeof value === "string" && /^\d+$/.test(value));
}

function pickStatus(node) {
  const keys = ["status", "state", "matchStatus", "displayStatus", "eventProgress", "progress", "time", "statusText"];
  for (const key of keys) {
    if (typeof node[key] === "string") {
      const candidate = extractStatusFromText(node[key]);
      if (candidate) return candidate;
    }
  }
  return null;
}

function dedupeMatches(matches) {
  const map = new Map();
  matches.forEach((match) => {
    const key = `${match.home_team}|${match.away_team}|${match.match_time}|${match.home_score}-${match.away_score}`;
    const existing = map.get(key);
    map.set(key, existing ? { ...existing, ...match } : match);
  });
  return Array.from(map.values());
}

const GENERIC_COMPETITION_LABELS = new Set([
  "football",
  "scores & fixtures",
  "scores and fixtures",
  "fixtures",
  "results",
  "all competitions",
]);

function safeArray(value) {
  return Array.isArray(value) ? value : [];
}

function readStringValue(value, depth = 0) {
  if (value === null || value === undefined) return null;
  if (typeof value === "string" || typeof value === "number") {
    return normalizeText(String(value));
  }
  if (typeof value !== "object" || depth > 3) return null;
  const keys = ["fullName", "name", "displayName", "title", "label", "shortName", "value", "text"];
  for (const key of keys) {
    const nested = readStringValue(value[key], depth + 1);
    if (nested) return nested;
  }
  return null;
}

function toTitleCaseWords(value) {
  return String(value || "")
    .replace(/[_-]+/g, " ")
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .map((token) => token.charAt(0).toUpperCase() + token.slice(1))
    .join(" ");
}

function collectCompetitionHints(value, output, depth = 0) {
  if (!value || depth > 4) return;
  if (typeof value === "string" || typeof value === "number") {
    const text = normalizeText(String(value)).toLowerCase();
    if (text) output.push(text);
    return;
  }
  if (Array.isArray(value)) {
    value.slice(0, 24).forEach((item) => collectCompetitionHints(item, output, depth + 1));
    return;
  }
  if (typeof value !== "object") return;

  Object.entries(value).forEach(([key, nested]) => {
    if (
      /(competition|tournament|group|stage|country|region|slug|path|href|url|name|title|label|id|urn|event)/i.test(
        key
      )
    ) {
      collectCompetitionHints(nested, output, depth + 1);
    }
  });
}

function inferPremierLeagueName(node, fallback = null) {
  const hints = [];
  collectCompetitionHints(node, hints);
  if (fallback) hints.push(normalizeText(String(fallback)).toLowerCase());

  for (const hint of hints) {
    if (!hint) continue;
    if (/\bukrain(?:e|ian)\b/.test(hint)) {
      return "Ukraine Premier League";
    }

    const slugMatch = hint.match(/(?:^|\/)([a-z0-9-]+)-premier-league(?:\/|$)/);
    if (!slugMatch) continue;
    const prefix = String(slugMatch[1] || "").trim();
    if (!prefix || ["premier", "english", "england"].includes(prefix)) continue;
    const titled = toTitleCaseWords(prefix);
    if (!titled) continue;
    return `${titled} Premier League`;
  }

  return null;
}

function pickCompetitionName(node, fallback = null) {
  if (!node || typeof node !== "object") {
    return fallback || null;
  }

  const candidates = [
    readStringValue(node.competition),
    readStringValue(node.competitionName),
    readStringValue(node.tournament),
    readStringValue(node.tournamentName),
    readStringValue(node.eventGroupName),
    readStringValue(node.groupName),
    readStringValue(node.stageName),
    readStringValue(node.displayLabel),
    readStringValue(node.displayName),
    readStringValue(node.title),
    readStringValue(node.name),
    fallback,
  ].filter(Boolean);

  for (const candidate of candidates) {
    const normalized = candidate.toLowerCase();
    if (!GENERIC_COMPETITION_LABELS.has(normalized)) {
      if (normalized === "premier league") {
        const inferred = inferPremierLeagueName(node, fallback);
        if (inferred) return inferred;
      }
      return candidate;
    }
  }

  const fallbackCandidate = candidates[0] || null;
  if (String(fallbackCandidate || "").toLowerCase() === "premier league") {
    return inferPremierLeagueName(node, fallback) || fallbackCandidate;
  }
  return fallbackCandidate;
}

function pickSubcategoryName(node) {
  if (!node || typeof node !== "object") {
    return null;
  }

  const candidates = [
    readStringValue(node.subcategory),
    readStringValue(node.subCategory),
    readStringValue(node.stageName),
    readStringValue(node.stage),
    readStringValue(node.roundName),
    readStringValue(node.round),
    readStringValue(node.phaseName),
    readStringValue(node.phase),
    readStringValue(node.secondaryGroupName),
    readStringValue(node.secondaryHeading),
    readStringValue(node.heading),
  ].filter(Boolean);

  return candidates[0] || null;
}

function normalizeKickoffTimeToken(value) {
  const text = normalizeText(value);
  if (!text) return null;
  const match = text.match(/\b(\d{1,2}):(\d{2})\b/);
  if (!match) return null;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (!Number.isFinite(hour) || !Number.isFinite(minute)) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}

function safeDateFormatter(timeZone, options) {
  try {
    return new Intl.DateTimeFormat("en-GB", { ...options, timeZone });
  } catch (err) {
    return new Intl.DateTimeFormat("en-GB", options);
  }
}

function formatDateInTimeZone(date, timeZone) {
  const formatter = safeDateFormatter(timeZone, {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  const parts = formatter.formatToParts(date);
  const partMap = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${partMap.year}-${partMap.month}-${partMap.day}`;
}

function formatTimeInTimeZone(date, timeZone) {
  const formatter = safeDateFormatter(timeZone, {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  const parts = formatter.formatToParts(date);
  const partMap = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${partMap.hour}:${partMap.minute}`;
}

function collectDateTimeCandidates(value, output, depth = 0) {
  if (value === null || value === undefined || depth > 3) return;
  if (typeof value === "string" || typeof value === "number") {
    const normalized = normalizeText(String(value));
    if (normalized) output.push(normalized);
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item) => collectDateTimeCandidates(item, output, depth + 1));
    return;
  }
  if (typeof value !== "object") return;

  const keys = [
    "value",
    "iso",
    "startTime",
    "startDateTime",
    "dateTime",
    "date",
    "time",
    "kickoff",
    "kickOff",
    "scheduled",
  ];
  keys.forEach((key) => collectDateTimeCandidates(value[key], output, depth + 1));
}

function parseDateTimeCandidate(candidate, fallbackDate, timeZone) {
  if (!candidate) return null;
  const text = normalizeText(candidate);
  if (!text) return null;

  const fullDate = text.match(/^(\d{4}-\d{2}-\d{2})$/);
  if (fullDate) {
    return { date: fullDate[1], time: "00:00" };
  }

  const dateAndTime = text.match(/^(\d{4}-\d{2}-\d{2})[T\s](\d{2}:\d{2})/);
  if (dateAndTime) {
    return { date: dateAndTime[1], time: dateAndTime[2] };
  }

  const kickoffTime = normalizeKickoffTimeToken(text);
  if (kickoffTime && fallbackDate) {
    return { date: fallbackDate, time: kickoffTime };
  }

  const parsed = new Date(text);
  if (!Number.isNaN(parsed.getTime())) {
    return {
      date: formatDateInTimeZone(parsed, timeZone),
      time: formatTimeInTimeZone(parsed, timeZone),
    };
  }

  return null;
}

function extractEventTeamName(team) {
  if (!team || typeof team !== "object") return null;
  return normalizeText(
    readStringValue(team.fullName)
      || readStringValue(team.name && team.name.fullName)
      || readStringValue(team.name)
      || readStringValue(team.shortName)
      || readStringValue(team.displayName)
  );
}

function pickEventStatusTextCandidates(event) {
  return [
    event.statusComment && event.statusComment.value,
    event.periodLabel && event.periodLabel.value,
    event.statusComment && event.statusComment.accessible,
    event.periodLabel && event.periodLabel.accessible,
    event.statusText,
    event.status,
    event.time,
  ].filter(Boolean);
}

function extractKickoffDateTimeFromEvent(event, fallbackDate, timeZone) {
  const candidates = [];
  [
    event.startTime,
    event.startDateTime,
    event.start_date_time,
    event.eventDateTime,
    event.scheduledStartTime,
    event.kickoffTime,
    event.kickOffTime,
    event.kickoff,
    event.time,
    event.date,
  ].forEach((value) => collectDateTimeCandidates(value, candidates));

  pickEventStatusTextCandidates(event).forEach((value) => {
    const kickoff = normalizeKickoffTimeToken(value);
    if (kickoff && fallbackDate) {
      candidates.push(`${fallbackDate} ${kickoff}`);
    }
  });

  for (const candidate of candidates) {
    const parsed = parseDateTimeCandidate(candidate, fallbackDate, timeZone);
    if (parsed) return parsed;
  }

  if (fallbackDate) {
    return { date: fallbackDate, time: "00:00" };
  }

  return null;
}

function collectBroadcastChannels(node, output, depth = 0) {
  if (!node || depth > 4) return;
  if (typeof node === "string") {
    const value = normalizeText(node);
    if (value) uniquePush(output, value);
    return;
  }
  if (Array.isArray(node)) {
    node.forEach((item) => collectBroadcastChannels(item, output, depth + 1));
    return;
  }
  if (typeof node !== "object") return;

  const keys = ["name", "shortName", "displayName", "channelName", "service", "title"];
  keys.forEach((key) => {
    if (typeof node[key] === "string") {
      const value = normalizeText(node[key]);
      if (value) uniquePush(output, value);
    }
  });

  const branchKeys = [
    "broadcasters",
    "broadcasts",
    "media",
    "mediaCoverage",
    "channels",
    "tv",
    "services",
    "coverage",
  ];
  branchKeys.forEach((key) => collectBroadcastChannels(node[key], output, depth + 1));
}

function extractScheduledMatchFromEvent(event, options = {}) {
  if (!event || typeof event !== "object") return null;

  const homeName = normalizeText(
    extractEventTeamName(event.home)
      || readStringValue(event.homeTeam)
      || readStringValue(event.home_team)
      || readStringValue(event.home)
  );
  const awayName = normalizeText(
    extractEventTeamName(event.away)
      || readStringValue(event.awayTeam)
      || readStringValue(event.away_team)
      || readStringValue(event.away)
  );
  if (!homeName || !awayName) return null;

  const kickoff = extractKickoffDateTimeFromEvent(
    event,
    options.fallbackDate || null,
    options.timeZone || DEFAULT_BBC_MATCH_TIMEZONE
  );
  if (!kickoff || !kickoff.date || !kickoff.time) return null;

  const match = {
    date: kickoff.date,
    time: kickoff.time,
    league: pickCompetitionName(event, options.competition || "") || "",
    home_team: homeName,
    away_team: awayName,
    tv_channels: [],
  };

  const subcategory = pickSubcategoryName(event) || options.subcategory || null;
  if (subcategory) {
    match.league_subcategory = subcategory;
  }

  const channels = [];
  collectBroadcastChannels(event, channels);
  if (channels.length > 0) {
    match.tv_channels = channels;
  }

  // Check if match has started before including scores
  const status = pickEventStatus(event);
  const hasStarted = status && !isKickoffTime(status);

  const score = pickScore(event);
  // Only include scores if the match has actually started
  if (hasStarted && score && isScoreValue(score[0]) && isScoreValue(score[1])) {
    match.home_score = toScoreValue(score[0]);
    match.away_score = toScoreValue(score[1]);
  }

  if (hasStarted) {
    match.score_status = status;
  }

  const aggregate = extractAggregateFromObject(event);
  if (aggregate) {
    match.aggregate_home_score = aggregate[0];
    match.aggregate_away_score = aggregate[1];
  }

  const detailsUrl = pickDetailsUrlFromObject(event);
  if (detailsUrl) {
    match.details_url = detailsUrl;
  }

  return match;
}

function mergeScheduledMatch(existing, incoming) {
  const merged = { ...existing };

  if (incoming.league) merged.league = incoming.league;
  if (incoming.league_subcategory) merged.league_subcategory = incoming.league_subcategory;
  if (incoming.time && incoming.time !== "00:00") merged.time = incoming.time;
  if (incoming.time && !merged.time) merged.time = incoming.time;
  if (incoming.home_score !== undefined && incoming.home_score !== null) {
    merged.home_score = incoming.home_score;
  }
  if (incoming.away_score !== undefined && incoming.away_score !== null) {
    merged.away_score = incoming.away_score;
  }
  if (incoming.score_status) merged.score_status = incoming.score_status;
  if (incoming.details_url) merged.details_url = incoming.details_url;
  if (incoming.aggregate_home_score !== undefined && incoming.aggregate_home_score !== null) {
    merged.aggregate_home_score = incoming.aggregate_home_score;
  }
  if (incoming.aggregate_away_score !== undefined && incoming.aggregate_away_score !== null) {
    merged.aggregate_away_score = incoming.aggregate_away_score;
  }

  const existingChannels = safeArray(existing.tv_channels);
  const incomingChannels = safeArray(incoming.tv_channels);
  const combinedChannels = [...existingChannels];
  incomingChannels.forEach((channel) => uniquePush(combinedChannels, channel));
  merged.tv_channels = combinedChannels;

  return merged;
}

function dedupeScheduledMatches(matches) {
  const map = new Map();
  matches.forEach((match) => {
    if (!match || !match.date || !match.home_team || !match.away_team) return;
    const key = [
      match.date,
      match.time || "00:00",
      normalizeText(match.league || "").toLowerCase(),
      normalizeText(match.home_team || "").toLowerCase(),
      normalizeText(match.away_team || "").toLowerCase(),
    ].join("|");
    const existing = map.get(key);
    map.set(key, existing ? mergeScheduledMatch(existing, match) : match);
  });
  return Array.from(map.values());
}

function parseScheduledMatchesFromInitialData(initialData, options = {}) {
  const matches = [];
  const groups = findEventGroups(initialData);
  groups.forEach((group) => {
    const groupCompetition = pickCompetitionName(group, options.competition || null);
    const groupSubcategory = pickSubcategoryName(group);

    safeArray(group.secondaryGroups).forEach((secondary) => {
      const competition = pickCompetitionName(secondary, groupCompetition);
      const subcategory = pickSubcategoryName(secondary) || groupSubcategory;
      safeArray(secondary.events).forEach((event) => {
        const match = extractScheduledMatchFromEvent(event, {
          ...options,
          competition,
          subcategory,
        });
        if (match) matches.push(match);
      });
    });

    safeArray(group.events).forEach((event) => {
      const match = extractScheduledMatchFromEvent(event, {
        ...options,
        competition: groupCompetition,
        subcategory: groupSubcategory,
      });
      if (match) matches.push(match);
    });
  });
  return matches;
}

function collectScheduledMatchesFromObject(node, options = {}) {
  const matches = [];
  function visit(value, competition, subcategory, depth) {
    if (!value || depth > 8) return;
    if (Array.isArray(value)) {
      value.forEach((item) => visit(item, competition, subcategory, depth + 1));
      return;
    }
    if (typeof value !== "object") return;

    const nextCompetition = pickCompetitionName(value, competition || null);
    const nextSubcategory = pickSubcategoryName(value) || subcategory;
    const match = extractScheduledMatchFromEvent(value, {
      ...options,
      competition: nextCompetition,
      subcategory: nextSubcategory,
    });
    if (match) matches.push(match);

    Object.values(value).forEach((nested) => visit(nested, nextCompetition, nextSubcategory, depth + 1));
  }

  visit(node, options.competition || null, options.subcategory || null, 0);
  return matches;
}

function parseScheduledMatchesFromJson(html, options = {}) {
  const matches = [];

  const initialData = extractWindowJson(html, "__INITIAL_DATA__");
  if (initialData) {
    matches.push(...parseScheduledMatchesFromInitialData(initialData, options));
    matches.push(...collectScheduledMatchesFromObject(initialData, options));
  }

  const scriptMatches = html.match(/<script[^>]*>([\s\S]*?)<\/script>/gi) || [];
  scriptMatches.forEach((block) => {
    if (!block.includes("__NEXT_DATA__") && !block.includes("__INITIAL_STATE__")) return;
    const jsonMatch = block.match(/>([\s\S]*?)<\/script>/i);
    if (!jsonMatch) return;
    const raw = jsonMatch[1].trim();
    if (!raw.startsWith("{") && !raw.startsWith("[")) return;
    try {
      const data = JSON.parse(raw);
      matches.push(...parseScheduledMatchesFromInitialData(data, options));
      matches.push(...collectScheduledMatchesFromObject(data, options));
    } catch (err) {
      // ignore
    }
  });

  return dedupeScheduledMatches(matches);
}

function aggregateTeamsKey(homeTeam, awayTeam, time = "") {
  const normalizedTime = normalizeKickoffTimeToken(time) || "";
  return [
    normalizeText(homeTeam).toLowerCase(),
    normalizeText(awayTeam).toLowerCase(),
    normalizedTime,
  ].join("|");
}

function parseScheduledAggregateEntriesFromDom($) {
  const entries = [];
  const nodes = findFixtureNodes($);
  nodes.forEach((node) => {
    const $node = $(node);
    const aggregate = extractAggregateFromBbcNode($node, $);
    if (!aggregate) return;

    const bbcTeams = extractTeamsFromBbcNode($node, $);
    const teams = bbcTeams.length ? bbcTeams : extractTeams($node, $);
    if (teams.length < 2) return;

    const entry = {
      home_team: teams[0],
      away_team: teams[1],
      aggregate_home_score: aggregate[0],
      aggregate_away_score: aggregate[1],
    };

    const kickoffTime = extractKickoffTimeFromBbcNode($node, $);
    if (kickoffTime) entry.time = kickoffTime;

    const detailsUrl = extractDetailsUrl($node, $, BBC_BASE_URL);
    if (detailsUrl) entry.details_url = detailsUrl;

    entries.push(entry);
  });
  return entries;
}

function applyAggregateScoresToScheduledMatches(matches, aggregateEntries) {
  if (!Array.isArray(matches) || matches.length === 0) return matches;
  if (!Array.isArray(aggregateEntries) || aggregateEntries.length === 0) return matches;

  const output = matches.map((match) => ({ ...match }));
  const byDetailsUrl = new Map();
  const byTeamTime = new Map();
  const byTeamsOnly = new Map();

  output.forEach((match, index) => {
    const detailsUrl = normalizeDetailsUrlKey(match && match.details_url);
    if (detailsUrl) byDetailsUrl.set(detailsUrl, index);

    const teamTimeKey = aggregateTeamsKey(match.home_team, match.away_team, match.time || "");
    if (!byTeamTime.has(teamTimeKey)) byTeamTime.set(teamTimeKey, []);
    byTeamTime.get(teamTimeKey).push(index);

    const teamsOnlyKey = aggregateTeamsKey(match.home_team, match.away_team, "");
    if (!byTeamsOnly.has(teamsOnlyKey)) byTeamsOnly.set(teamsOnlyKey, []);
    byTeamsOnly.get(teamsOnlyKey).push(index);
  });

  aggregateEntries.forEach((aggregateEntry) => {
    let targetIndex;
    const detailsUrl = normalizeDetailsUrlKey(aggregateEntry && aggregateEntry.details_url);
    if (detailsUrl && byDetailsUrl.has(detailsUrl)) {
      targetIndex = byDetailsUrl.get(detailsUrl);
    }

    if (targetIndex === undefined) {
      const byTimeKey = aggregateTeamsKey(
        aggregateEntry.home_team,
        aggregateEntry.away_team,
        aggregateEntry.time || ""
      );
      const byTimeMatches = byTeamTime.get(byTimeKey) || [];
      if (byTimeMatches.length === 1) {
        targetIndex = byTimeMatches[0];
      }
    }

    if (targetIndex === undefined) {
      const teamsOnlyKey = aggregateTeamsKey(aggregateEntry.home_team, aggregateEntry.away_team, "");
      const teamsOnlyMatches = byTeamsOnly.get(teamsOnlyKey) || [];
      if (teamsOnlyMatches.length === 1) {
        targetIndex = teamsOnlyMatches[0];
      }
    }

    if (targetIndex === undefined) return;

    if (isScoreValue(aggregateEntry.aggregate_home_score) && isScoreValue(aggregateEntry.aggregate_away_score)) {
      output[targetIndex].aggregate_home_score = aggregateEntry.aggregate_home_score;
      output[targetIndex].aggregate_away_score = aggregateEntry.aggregate_away_score;
    }
  });

  return output;
}

function normalizeDateOnly(value) {
  const text = normalizeText(value);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text || "")) {
    throw new Error(`Invalid date: ${value}`);
  }
  return text;
}

function parseDateOnlyUtc(dateString) {
  return new Date(`${dateString}T00:00:00.000Z`);
}

function formatDateOnlyUtc(date) {
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  const day = String(date.getUTCDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function enumerateDateStrings(startDate, endDate) {
  const start = parseDateOnlyUtc(normalizeDateOnly(startDate));
  const end = parseDateOnlyUtc(normalizeDateOnly(endDate));
  if (start > end) return [];

  const dates = [];
  const cursor = new Date(start.getTime());
  while (cursor <= end) {
    dates.push(formatDateOnlyUtc(cursor));
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }
  return dates;
}

function resolveScoresFixturesDateUrl(baseUrl, dateString) {
  const target = new URL(baseUrl || DEFAULT_BBC_URL, BBC_BASE_URL);
  target.hash = "";
  target.search = "";
  const cleanPath = target.pathname.replace(/\/+$/, "");
  const withoutDate = cleanPath.replace(/\/\d{4}-\d{2}-\d{2}$/i, "");
  target.pathname = `${withoutDate}/${normalizeDateOnly(dateString)}`;
  return target.toString();
}

function resolveRangeDateWindow(options = {}) {
  const timeZone = options.timeZone || DEFAULT_BBC_MATCH_TIMEZONE;
  const now = new Date();

  const pastDays = Number.isFinite(options.pastDays)
    ? Math.max(0, Math.floor(options.pastDays))
    : DEFAULT_BBC_RANGE_PAST_DAYS;
  const futureDays = Number.isFinite(options.futureDays)
    ? Math.max(0, Math.floor(options.futureDays))
    : DEFAULT_BBC_RANGE_FUTURE_DAYS;

  if (options.startDate && options.endDate) {
    return {
      startDate: normalizeDateOnly(options.startDate),
      endDate: normalizeDateOnly(options.endDate),
      pastDays,
      futureDays,
    };
  }

  const start = new Date(now.getTime());
  start.setDate(start.getDate() - pastDays);
  const end = new Date(now.getTime());
  end.setDate(end.getDate() + futureDays);
  return {
    startDate: formatDateInTimeZone(start, timeZone),
    endDate: formatDateInTimeZone(end, timeZone),
    pastDays,
    futureDays,
  };
}

async function fetchBbcScoresFixturesByDate(dateString, options = {}) {
  const fallbackDate = normalizeDateOnly(dateString);
  const timeZone = options.timeZone || DEFAULT_BBC_MATCH_TIMEZONE;
  const url = resolveScoresFixturesDateUrl(options.baseUrl || DEFAULT_BBC_URL, fallbackDate);
  const html = await fetchHtml(url);
  const matches = parseScheduledMatchesFromJson(html, {
    fallbackDate,
    timeZone,
  });
  const $ = cheerio.load(html);
  const aggregateEntries = parseScheduledAggregateEntriesFromDom($);
  const matchesWithAggregate = applyAggregateScoresToScheduledMatches(matches, aggregateEntries);

  return matchesWithAggregate.map((match) => ({
    ...match,
    home_score:
      match.home_score !== undefined && match.home_score !== null
        ? toScoreValue(match.home_score)
        : match.home_score,
    away_score:
      match.away_score !== undefined && match.away_score !== null
        ? toScoreValue(match.away_score)
        : match.away_score,
    aggregate_home_score:
      match.aggregate_home_score !== undefined && match.aggregate_home_score !== null
        ? toScoreValue(match.aggregate_home_score)
        : match.aggregate_home_score,
    aggregate_away_score:
      match.aggregate_away_score !== undefined && match.aggregate_away_score !== null
        ? toScoreValue(match.aggregate_away_score)
        : match.aggregate_away_score,
  }));
}

async function fetchBbcScoresFixturesByDateRange(options = {}) {
  const {
    startDate,
    endDate,
  } = resolveRangeDateWindow(options);
  const dates = enumerateDateStrings(startDate, endDate);
  const allMatches = [];
  const concurrency = Number.isFinite(options.concurrency)
    ? Math.max(1, Math.floor(options.concurrency))
    : DEFAULT_BBC_RANGE_CONCURRENCY;

  await mapWithConcurrency(dates, concurrency, async (dateString) => {
    const dailyMatches = await fetchBbcScoresFixturesByDate(dateString, options);
    allMatches.push(...dailyMatches);
  });

  return dedupeScheduledMatches(allMatches);
}

function toScoreValue(value) {
  const num = Number(value);
  return Number.isFinite(num) ? num : value;
}

async function fetchBbcFixtures(url = DEFAULT_BBC_URL) {
  pruneDetailsCache(Date.now());
  const html = await fetchHtml(url);
  const $ = cheerio.load(html);
  const fromDom = parseMatchesFromDom($);
  const fromJson = parseMatchesFromJson(html);
  const deduped = dedupeMatches([...fromJson, ...fromDom]).map((match) => ({
    ...match,
    home_score: toScoreValue(match.home_score),
    away_score: toScoreValue(match.away_score),
    aggregate_home_score:
      match.aggregate_home_score !== undefined && match.aggregate_home_score !== null
        ? toScoreValue(match.aggregate_home_score)
        : match.aggregate_home_score,
    aggregate_away_score:
      match.aggregate_away_score !== undefined && match.aggregate_away_score !== null
        ? toScoreValue(match.aggregate_away_score)
        : match.aggregate_away_score,
  }));
  return enrichMatchesWithDetails(deduped);
}

function selectMatchCandidateByDetailsUrl(candidates, normalizedTarget) {
  if (!Array.isArray(candidates) || !normalizedTarget) return null;
  return (
    candidates.find((candidate) => {
      const validated = normalizeDetailsUrl(candidate && candidate.details_url);
      return normalizeDetailsUrlKey(validated) === normalizedTarget;
    }) || null
  );
}

async function fetchBbcMatchByDetailsUrl(detailsUrl) {
  const validatedTarget = normalizeDetailsUrl(detailsUrl);
  const normalizedTarget = normalizeDetailsUrlKey(validatedTarget);
  if (!normalizedTarget) return null;

  const html = await fetchHtml(validatedTarget);
  const $ = cheerio.load(html);
  const fromDom = parseMatchesFromDom($);
  const fromJson = parseMatchesFromJson(html);
  const candidates = dedupeMatches([...fromJson, ...fromDom]).map((match) => ({
    ...match,
    home_score: toScoreValue(match.home_score),
    away_score: toScoreValue(match.away_score),
    aggregate_home_score:
      match.aggregate_home_score !== undefined && match.aggregate_home_score !== null
        ? toScoreValue(match.aggregate_home_score)
        : match.aggregate_home_score,
    aggregate_away_score:
      match.aggregate_away_score !== undefined && match.aggregate_away_score !== null
        ? toScoreValue(match.aggregate_away_score)
        : match.aggregate_away_score,
  }));

  let match = selectMatchCandidateByDetailsUrl(candidates, normalizedTarget);

  // Parse details from the dedicated match page even when summary candidate extraction fails.
  // This avoids incorrectly falling back to an unrelated fixture from shared JSON blobs.
  const detailsFromPage = parseMatchDetailsFromHtml(
    html,
    match ? match.home_team : null,
    match ? match.away_team : null
  );

  if (!match) {
    if (!detailsFromPage) return null;
    const fallbackMatch = {
      details_url: validatedTarget,
      ...detailsFromPage,
    };
    if (!fallbackMatch.score_status && fallbackMatch.match_time) {
      fallbackMatch.score_status = fallbackMatch.match_time;
    }
    if (!fallbackMatch.match_time && fallbackMatch.score_status) {
      fallbackMatch.match_time = fallbackMatch.score_status;
    }
    return fallbackMatch;
  }

  if (detailsFromPage) {
    match = {
      ...match,
      ...detailsFromPage,
    };
  }
  if (!match.details_url) {
    match.details_url = validatedTarget;
  }
  if (!match.score_status && match.match_time) {
    match.score_status = match.match_time;
  }
  if (!match.match_time && match.score_status) {
    match.match_time = match.score_status;
  }

  return match;
}

function writeBbcFixtures(outputPath, matches) {
  fs.writeFileSync(outputPath, JSON.stringify(matches, null, 2), "utf8");
}

async function main() {
  const args = process.argv.slice(2);
  const urlIdx = args.indexOf("--url");
  const outputIdx = args.indexOf("--output");
  const url = urlIdx !== -1 && args[urlIdx + 1] ? args[urlIdx + 1] : DEFAULT_BBC_URL;
  const output = outputIdx !== -1 && args[outputIdx + 1] ? args[outputIdx + 1] : DEFAULT_BBC_OUTPUT;

  const matches = await fetchBbcFixtures(url);
  writeBbcFixtures(output, matches);
  console.log(`Wrote ${matches.length} live matches to ${output}`);
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err.stack || err.message || String(err));
    process.exit(1);
  });
}

module.exports = {
  DEFAULT_BBC_URL,
  DEFAULT_BBC_OUTPUT,
  DEFAULT_BBC_MATCH_TIMEZONE,
  DEFAULT_BBC_RANGE_PAST_DAYS,
  DEFAULT_BBC_RANGE_FUTURE_DAYS,
  DEFAULT_BBC_RANGE_CONCURRENCY,
  fetchBbcFixtures,
  fetchBbcScoresFixturesByDate,
  fetchBbcScoresFixturesByDateRange,
  fetchBbcMatchByDetailsUrl,
  parseMatchDetailsFromHtml,
  resolveScoresFixturesDateUrl,
  writeBbcFixtures,
  __private: {
    extractStatusFromText,
    normalizeDetailsUrl,
    normalizeDetailsUrlKey,
    parseMatchesFromDom,
    pickCompetitionName,
    selectMatchCandidateByDetailsUrl,
    pickEventStatus,
  },
};
