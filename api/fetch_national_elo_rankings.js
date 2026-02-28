#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require("fs");
const http = require("http");
const https = require("https");
const path = require("path");
const { URL } = require("url");

const DEFAULT_NATIONAL_ELO_BASE_URL = "https://www.eloratings.net";
const DEFAULT_NATIONAL_ELO_PAGE = "World";
const DEFAULT_NATIONAL_ELO_OUTPUT = path.join(__dirname, "national_elo_teams.json");
const DEFAULT_NATIONAL_ELO_MIN_ROWS = 180;
const DEFAULT_NATIONAL_ELO_MIN_BYTES = 4 * 1024;
const DEFAULT_NATIONAL_ELO_TIMEOUT_MS = 30000;
const DEFAULT_NATIONAL_ELO_RETRY_ATTEMPTS = 5;
const DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_BASE_MS = 400;
const DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_MAX_MS = 5000;
const DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_FACTOR = 2;
const DEFAULT_NATIONAL_ELO_RETRY_JITTER_MS = 200;
const DEFAULT_NATIONAL_ELO_PREFER_IPV4 = true;
const DEFAULT_NATIONAL_ELO_USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36";

const RETRYABLE_NETWORK_ERROR_CODES = new Set([
  "ETIMEDOUT",
  "ECONNRESET",
  "ECONNREFUSED",
  "EHOSTUNREACH",
  "ENETUNREACH",
  "EAI_AGAIN",
  "ENOTFOUND",
  "ESOCKETTIMEDOUT",
]);
const RETRYABLE_HTTP_STATUS_CODES = new Set([408, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524]);

function normalizeBaseUrl(baseUrl) {
  return String(baseUrl || DEFAULT_NATIONAL_ELO_BASE_URL).replace(/\/+$/, "");
}

function normalizePageName(value) {
  const normalized = String(value || DEFAULT_NATIONAL_ELO_PAGE)
    .replace(/[^A-Za-z0-9_-]/g, "")
    .trim();
  return normalized || DEFAULT_NATIONAL_ELO_PAGE;
}

function buildTsvUrl(baseUrl, name) {
  return `${normalizeBaseUrl(baseUrl)}/${String(name || "").replace(/\/+/g, "")}.tsv`;
}

function cleanText(value) {
  return String(value || "")
    .replace(/\u00a0/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function splitLines(data) {
  return String(data || "").split(/\r?\n/);
}

function parseInteger(value) {
  const normalized = cleanText(value)
    .replace(/\u2212/g, "-")
    .replace(/,/g, "");
  if (!normalized) return null;
  const parsed = Number.parseInt(normalized, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function parseDateHeader(value) {
  const parsedMs = Date.parse(String(value || "").trim());
  if (!Number.isFinite(parsedMs) || parsedMs <= 0) return null;
  return new Date(parsedMs).toISOString();
}

function parseDateOnlyFromIso(value) {
  const iso = String(value || "").trim();
  if (!iso) return null;
  const parsedMs = Date.parse(iso);
  if (!Number.isFinite(parsedMs) || parsedMs <= 0) return null;
  return new Date(parsedMs).toISOString().slice(0, 10);
}

function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, Math.max(0, Math.floor(Number(ms) || 0)));
  });
}

function isRetryableError(error) {
  if (!error || typeof error !== "object") return false;

  const statusCode = Number(error.statusCode || error.status || 0);
  if (RETRYABLE_HTTP_STATUS_CODES.has(statusCode)) return true;

  const code = String(error.code || "").toUpperCase();
  if (RETRYABLE_NETWORK_ERROR_CODES.has(code)) return true;

  if (Array.isArray(error.errors) && error.errors.some((item) => isRetryableError(item))) {
    return true;
  }
  if (error.cause && isRetryableError(error.cause)) {
    return true;
  }

  return false;
}

function computeRetryDelayMs(retryNumber, options) {
  const base = Number(options && options.backoffBaseMs);
  const factor = Number(options && options.backoffFactor);
  const max = Number(options && options.backoffMaxMs);
  const jitter = Number(options && options.jitterMs);
  const exponentialDelay = base * Math.pow(factor, Math.max(0, retryNumber - 1));
  const capped = Math.min(max, Math.floor(exponentialDelay));
  const jitterDelay = jitter > 0 ? Math.floor(Math.random() * (jitter + 1)) : 0;
  return capped + jitterDelay;
}

function normalizeRetryOptions(options = {}) {
  const attempts = Number(options.retryAttempts || DEFAULT_NATIONAL_ELO_RETRY_ATTEMPTS);
  const backoffBaseMs = Number(
    options.retryBackoffBaseMs || DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_BASE_MS
  );
  const backoffMaxMs = Number(
    options.retryBackoffMaxMs || DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_MAX_MS
  );
  const backoffFactor = Number(
    options.retryBackoffFactor || DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_FACTOR
  );
  const jitterMs = Number(options.retryJitterMs || DEFAULT_NATIONAL_ELO_RETRY_JITTER_MS);

  const safeAttempts = Number.isFinite(attempts) ? Math.max(1, Math.floor(attempts)) : DEFAULT_NATIONAL_ELO_RETRY_ATTEMPTS;
  const safeBase = Number.isFinite(backoffBaseMs) ? Math.max(1, Math.floor(backoffBaseMs)) : DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_BASE_MS;
  const safeMax = Number.isFinite(backoffMaxMs)
    ? Math.max(safeBase, Math.floor(backoffMaxMs))
    : DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_MAX_MS;
  const safeFactor = Number.isFinite(backoffFactor) ? Math.max(1, backoffFactor) : DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_FACTOR;
  const safeJitter = Number.isFinite(jitterMs) ? Math.max(0, Math.floor(jitterMs)) : DEFAULT_NATIONAL_ELO_RETRY_JITTER_MS;

  return {
    attempts: safeAttempts,
    backoffBaseMs: safeBase,
    backoffMaxMs: safeMax,
    backoffFactor: safeFactor,
    jitterMs: safeJitter,
  };
}

function normalizeRequestOptions(options = {}) {
  const timeoutMs = Number.isFinite(Number(options.timeoutMs))
    ? Math.max(1000, Math.floor(Number(options.timeoutMs)))
    : DEFAULT_NATIONAL_ELO_TIMEOUT_MS;
  const preferIpv4 =
    options.preferIpv4 === undefined || options.preferIpv4 === null
      ? DEFAULT_NATIONAL_ELO_PREFER_IPV4
      : Boolean(options.preferIpv4);
  const userAgent = cleanText(options.userAgent) || DEFAULT_NATIONAL_ELO_USER_AGENT;
  return {
    timeoutMs,
    preferIpv4,
    userAgent,
  };
}

function formatErrorForMessage(error, depth = 0) {
  if (error === undefined || error === null) return "unknown error";
  if (typeof error === "string") return error;
  if (typeof error !== "object") return String(error);

  const name = cleanText(error.name) || "Error";
  const message = cleanText(error.message) || name;
  const details = [];
  const code = cleanText(error.code);
  const statusCode = Number(error.statusCode || error.status || 0);
  if (code) details.push(`code=${code}`);
  if (Number.isFinite(statusCode) && statusCode > 0) details.push(`status=${statusCode}`);
  if (error.address) details.push(`address=${error.address}`);
  if (Number.isFinite(Number(error.port))) details.push(`port=${Number(error.port)}`);

  let result = message;
  if (details.length > 0) {
    result = `${result} (${details.join(",")})`;
  }

  if (depth < 1 && Array.isArray(error.errors) && error.errors.length > 0) {
    const children = error.errors
      .map((item) => formatErrorForMessage(item, depth + 1))
      .filter(Boolean);
    if (children.length > 0) {
      result = `${result}; suberrors=[${children.join(" | ")}]`;
    }
  }

  if (depth < 1 && error.cause) {
    const causeText = formatErrorForMessage(error.cause, depth + 1);
    if (causeText) {
      result = `${result}; cause=${causeText}`;
    }
  }

  if (name && !result.toLowerCase().startsWith(name.toLowerCase())) {
    result = `${name}: ${result}`;
  }
  return result;
}

function fetchText(url, options = {}, redirectDepth = 0) {
  return new Promise((resolve, reject) => {
    if (redirectDepth > 5) {
      reject(new Error("Too many redirects while fetching National Elo TSV"));
      return;
    }

    const requestOptions = normalizeRequestOptions(options);
    const target = new URL(url);
    const lib = target.protocol === "https:" ? https : http;
    const req = lib.get(
      target,
      {
        headers: {
          "User-Agent": requestOptions.userAgent,
          Accept: "text/plain,text/tab-separated-values,*/*;q=0.8",
          "Accept-Language": "en-GB,en-US;q=0.9,en;q=0.8",
          Referer: "https://www.eloratings.net/",
        },
        family: requestOptions.preferIpv4 ? 4 : undefined,
      },
      (res) => {
        const statusCode = Number(res.statusCode || 0);
        if (statusCode >= 300 && statusCode < 400 && res.headers.location) {
          const redirectUrl = new URL(res.headers.location, target).toString();
          res.resume();
          fetchText(redirectUrl, requestOptions, redirectDepth + 1).then(resolve).catch(reject);
          return;
        }
        if (statusCode !== 200) {
          res.resume();
          const error = new Error(`National Elo request failed with status ${statusCode}`);
          error.statusCode = statusCode;
          error.code = `HTTP_${statusCode}`;
          reject(error);
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

    req.setTimeout(requestOptions.timeoutMs, () => {
      const timeoutError = new Error("National Elo request timed out");
      timeoutError.code = "ETIMEDOUT";
      req.destroy(timeoutError);
    });
    req.on("error", reject);
  });
}

async function fetchTextWithRetry(url, requestOptions, retryOptions, retryState = null) {
  for (let attempt = 1; attempt <= retryOptions.attempts; attempt += 1) {
    try {
      return await fetchText(url, requestOptions);
    } catch (error) {
      const hasMore = attempt < retryOptions.attempts;
      const retryable = isRetryableError(error);
      const errorSummary = formatErrorForMessage(error);
      if (retryState && typeof retryState === "object") {
        if (!Array.isArray(retryState.attemptErrors)) retryState.attemptErrors = [];
        retryState.attemptErrors.push({
          url,
          attempt,
          retryable,
          error: errorSummary,
        });
      }
      if (!hasMore || !retryable) {
        const wrapped = new Error(
          `National Elo request failed after ${attempt} attempts (${url}): ${errorSummary}`
        );
        wrapped.code = error && error.code ? error.code : undefined;
        wrapped.statusCode = error && error.statusCode ? error.statusCode : undefined;
        wrapped.cause = error;
        wrapped.url = url;
        wrapped.attempts = attempt;
        wrapped.retryable = retryable;
        wrapped.attemptErrors = Array.isArray(retryState && retryState.attemptErrors)
          ? retryState.attemptErrors.filter((entry) => entry && entry.url === url)
          : [];
        throw wrapped;
      }

      if (retryState && typeof retryState === "object") {
        retryState.retriesPerformed = Number(retryState.retriesPerformed || 0) + 1;
        if (!Array.isArray(retryState.urlsRetried)) retryState.urlsRetried = [];
        if (!retryState.urlsRetried.includes(url)) {
          retryState.urlsRetried.push(url);
        }
      }

      const delayMs = computeRetryDelayMs(attempt, retryOptions);
      await sleep(delayMs);
    }
  }

  throw new Error(`National Elo request exhausted retry attempts (${url})`);
}

function validateTsvResponse(name, response, minBytes = null) {
  const contentType = String(
    response && response.headers ? response.headers["content-type"] || "" : ""
  ).toLowerCase();
  const body = String(response && response.body ? response.body : "");
  const byteLength = Buffer.byteLength(body, "utf8");
  const looksLikeText = !contentType || /text|plain|tab-separated-values|octet-stream/.test(contentType);
  if (!looksLikeText) {
    throw new Error(`${name} response is not plain text content-type (received: ${contentType || "none"})`);
  }
  if (!body.trim()) {
    throw new Error(`${name} response body is empty`);
  }
  if (Number.isFinite(minBytes) && minBytes > 0 && byteLength < minBytes) {
    throw new Error(`${name} TSV too small (${byteLength} bytes). Expected at least ${minBytes} bytes.`);
  }
  return {
    contentType,
    byteLength,
    body,
  };
}

function parseSuccessorMap(tsvText) {
  const map = new Map();
  splitLines(tsvText).forEach((line) => {
    const fields = line.split("\t").map((item) => cleanText(item));
    if (fields.length < 2) return;
    const from = fields[0];
    const to = fields[1];
    if (!from || !to) return;
    map.set(from, to);
  });
  return map;
}

function parseTeamDictionary(tsvText) {
  const map = new Map();
  splitLines(tsvText).forEach((line) => {
    const fields = line.split("\t").map((item) => cleanText(item));
    if (fields.length < 2) return;
    const code = fields.shift();
    if (!code) return;
    const labels = fields.filter(Boolean);
    if (labels.length === 0) return;
    map.set(code, labels);
  });
  return map;
}

function resolveSuccessorCode(code, successorMap) {
  let current = cleanText(code);
  if (!current) return "";
  const visited = new Set();
  for (let depth = 0; depth < 12; depth += 1) {
    if (visited.has(current)) break;
    visited.add(current);
    if (!successorMap.has(current)) break;
    const next = cleanText(successorMap.get(current));
    if (!next || next === current) break;
    current = next;
  }
  return current;
}

function parseRankingRows(tsvText, teamDictionary, successorMap) {
  const rows = [];
  splitLines(tsvText).forEach((line) => {
    const fields = line.split("\t");
    if (fields.length < 4) return;
    const globalRank = parseInteger(fields[1]);
    const teamCode = cleanText(fields[2]);
    const rating = parseInteger(fields[3]);
    if (!Number.isFinite(globalRank) || globalRank <= 0) return;
    if (!teamCode) return;
    if (!Number.isFinite(rating)) return;

    const resolvedCode = resolveSuccessorCode(teamCode, successorMap);
    const labels =
      teamDictionary.get(resolvedCode) || teamDictionary.get(teamCode) || [resolvedCode || teamCode];
    const teamName = cleanText(labels[0]) || resolvedCode || teamCode;
    if (!teamName) return;

    const aliases = labels
      .map((label) => cleanText(label))
      .filter(Boolean)
      .filter((label, index, arr) => arr.indexOf(label) === index)
      .filter((label) => label !== teamName);

    rows.push({
      Name: teamName,
      Team: teamName,
      Country: teamName,
      Rank: Math.floor(globalRank),
      Elo: rating,
      Points: rating,
      TeamCode: resolvedCode || teamCode,
      Aliases: aliases,
      OneYearRankChange: parseInteger(fields[14]),
      OneYearRatingChange: parseInteger(fields[15]),
    });
  });
  return rows;
}

function deduplicateByTeamCode(rows) {
  const byCode = new Map();
  (Array.isArray(rows) ? rows : []).forEach((row) => {
    const code = cleanText(row && row.TeamCode ? row.TeamCode : "");
    const fallbackCode = cleanText(row && row.Name ? row.Name : "");
    const key = code || fallbackCode;
    if (!key) return;
    if (!byCode.has(key)) {
      byCode.set(key, row);
    }
  });
  return Array.from(byCode.values()).sort((left, right) => {
    const leftRank = Number.isFinite(left && left.Rank) ? left.Rank : Number.MAX_SAFE_INTEGER;
    const rightRank = Number.isFinite(right && right.Rank) ? right.Rank : Number.MAX_SAFE_INTEGER;
    if (leftRank !== rightRank) return leftRank - rightRank;
    return String(left && left.Team ? left.Team : "").localeCompare(String(right && right.Team ? right.Team : ""));
  });
}

function buildFallbackTeamDictionaryFromTeams(teams) {
  const map = new Map();
  (Array.isArray(teams) ? teams : []).forEach((team) => {
    const code = cleanText(team && team.TeamCode ? team.TeamCode : "");
    const primary = cleanText(team && (team.Team || team.Name || team.Country));
    if (!code || !primary) return;
    const aliases = Array.isArray(team && team.Aliases)
      ? team.Aliases.map((alias) => cleanText(alias)).filter(Boolean)
      : [];
    const labels = Array.from(new Set([primary, ...aliases]));
    if (labels.length === 0) return;
    map.set(code, labels);
  });
  return map;
}

async function fetchOptionalTextWithRetry(name, url, timeoutMs, retryOptions, retryState, warnings) {
  const requestOptions = {
    timeoutMs,
    preferIpv4: retryState && retryState.preferIpv4,
    userAgent: retryState && retryState.userAgent,
  };
  try {
    return await fetchTextWithRetry(url, requestOptions, retryOptions, retryState);
  } catch (error) {
    if (Array.isArray(warnings)) {
      warnings.push(
        `${name} unavailable (${url}): ${formatErrorForMessage(error)}`
      );
    }
    return null;
  }
}

async function fetchNationalEloRankings(options = {}) {
  const baseUrl = options.baseUrl || DEFAULT_NATIONAL_ELO_BASE_URL;
  const page = normalizePageName(options.page || DEFAULT_NATIONAL_ELO_PAGE);
  const timeoutMs = Number.isFinite(Number(options.timeoutMs))
    ? Math.max(1000, Math.floor(Number(options.timeoutMs)))
    : DEFAULT_NATIONAL_ELO_TIMEOUT_MS;
  const minRows = Number.isFinite(Number(options.minRows))
    ? Math.max(1, Math.floor(Number(options.minRows)))
    : DEFAULT_NATIONAL_ELO_MIN_ROWS;
  const minBytes = Number.isFinite(Number(options.minBytes))
    ? Math.max(1, Math.floor(Number(options.minBytes)))
    : DEFAULT_NATIONAL_ELO_MIN_BYTES;
  const retryOptions = normalizeRetryOptions(options);
  const retryState = {
    retriesPerformed: 0,
    urlsRetried: [],
    attemptErrors: [],
  };
  const warnings = [];
  const requestOptions = normalizeRequestOptions({
    timeoutMs,
    preferIpv4: options.preferIpv4,
    userAgent: options.userAgent,
  });
  retryState.preferIpv4 = requestOptions.preferIpv4;
  retryState.userAgent = requestOptions.userAgent;

  const rankingUrl = buildTsvUrl(baseUrl, page);
  const successorUrl = buildTsvUrl(baseUrl, "teams");
  const teamDictionaryUrl = buildTsvUrl(baseUrl, "en.teams");
  const fallbackTeamDictionary = buildFallbackTeamDictionaryFromTeams(options.fallbackTeams);

  const rankingResponse = await fetchTextWithRetry(
    rankingUrl,
    requestOptions,
    retryOptions,
    retryState
  );
  const [successorResponse, teamDictionaryResponse] = await Promise.all([
    fetchOptionalTextWithRetry(
      "National Elo successor map",
      successorUrl,
      requestOptions.timeoutMs,
      retryOptions,
      retryState,
      warnings
    ),
    fetchOptionalTextWithRetry(
      "National Elo team dictionary",
      teamDictionaryUrl,
      requestOptions.timeoutMs,
      retryOptions,
      retryState,
      warnings
    ),
  ]);

  const rankingValidated = validateTsvResponse("National Elo rankings", rankingResponse, minBytes);
  const successorValidated = successorResponse
    ? validateTsvResponse("National Elo successor map", successorResponse)
    : null;
  const dictionaryValidated = teamDictionaryResponse
    ? validateTsvResponse("National Elo team dictionary", teamDictionaryResponse)
    : null;

  const successorMap = successorValidated ? parseSuccessorMap(successorValidated.body) : new Map();
  const teamDictionary = dictionaryValidated
    ? parseTeamDictionary(dictionaryValidated.body)
    : new Map(fallbackTeamDictionary.entries());

  if (!dictionaryValidated && teamDictionary.size === 0) {
    throw new Error(
      "National Elo team dictionary unavailable and no fallback dictionary is available."
    );
  }

  const parsedRows = parseRankingRows(rankingValidated.body, teamDictionary, successorMap);
  const teams = deduplicateByTeamCode(parsedRows);

  if (teams.length < minRows) {
    throw new Error(
      `National Elo parsed rows too small (${teams.length}). Expected at least ${minRows}.`
    );
  }

  const rankingLastModifiedIso = parseDateHeader(
    rankingResponse &&
      rankingResponse.headers &&
      (rankingResponse.headers["last-modified"] || rankingResponse.headers["Last-Modified"])
  );
  const rankingDate = parseDateOnlyFromIso(rankingLastModifiedIso);

  const contentTypes = new Set([rankingValidated.contentType]);
  if (successorValidated && successorValidated.contentType) contentTypes.add(successorValidated.contentType);
  if (dictionaryValidated && dictionaryValidated.contentType) contentTypes.add(dictionaryValidated.contentType);
  const totalBytes = rankingValidated.byteLength +
    (successorValidated ? successorValidated.byteLength : 0) +
    (dictionaryValidated ? dictionaryValidated.byteLength : 0);

  return {
    url: rankingUrl,
    page,
    rowCount: teams.length,
    teams,
    byteLength: totalBytes,
    contentType: Array.from(contentTypes.values()).filter(Boolean).join(","),
    lastModified: rankingLastModifiedIso,
    dateModified: rankingDate,
    source_files: {
      rankings: rankingUrl,
      successors: successorUrl,
      team_dictionary: teamDictionaryUrl,
    },
    partial_fetch: {
      successors_loaded: Boolean(successorValidated),
      team_dictionary_loaded: Boolean(dictionaryValidated),
      fallback_team_dictionary_used: !dictionaryValidated && fallbackTeamDictionary.size > 0,
    },
    warnings,
    retry: {
      attempts: retryOptions.attempts,
      backoff_base_ms: retryOptions.backoffBaseMs,
      backoff_max_ms: retryOptions.backoffMaxMs,
      backoff_factor: retryOptions.backoffFactor,
      jitter_ms: retryOptions.jitterMs,
      retries_performed: retryState.retriesPerformed,
      urls_retried: retryState.urlsRetried.slice(),
      attempt_errors: Array.isArray(retryState.attemptErrors)
        ? retryState.attemptErrors.slice()
        : [],
    },
    request: {
      prefer_ipv4: requestOptions.preferIpv4,
      user_agent: requestOptions.userAgent,
      timeout_ms: requestOptions.timeoutMs,
    },
    min_rows: minRows,
    min_bytes: minBytes,
  };
}

function writeNationalEloRankings(outputPath, teams) {
  fs.writeFileSync(outputPath, JSON.stringify(teams, null, 2), "utf8");
}

function getArgValue(args, flag, fallback = null) {
  const index = args.indexOf(flag);
  if (index === -1 || index + 1 >= args.length) return fallback;
  return args[index + 1];
}

async function runCli() {
  const args = process.argv.slice(2);
  const baseUrl = getArgValue(args, "--base-url", DEFAULT_NATIONAL_ELO_BASE_URL);
  const outputPath = path.resolve(getArgValue(args, "--out", DEFAULT_NATIONAL_ELO_OUTPUT));
  const page = getArgValue(args, "--page", DEFAULT_NATIONAL_ELO_PAGE);
  const minRows = Number(getArgValue(args, "--min-rows", DEFAULT_NATIONAL_ELO_MIN_ROWS));
  const minBytes = Number(getArgValue(args, "--min-bytes", DEFAULT_NATIONAL_ELO_MIN_BYTES));
  const retryAttempts = Number(
    getArgValue(args, "--retry-attempts", DEFAULT_NATIONAL_ELO_RETRY_ATTEMPTS)
  );
  const retryBackoffBaseMs = Number(
    getArgValue(args, "--retry-backoff-base-ms", DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_BASE_MS)
  );
  const retryBackoffMaxMs = Number(
    getArgValue(args, "--retry-backoff-max-ms", DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_MAX_MS)
  );
  const retryBackoffFactor = Number(
    getArgValue(args, "--retry-backoff-factor", DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_FACTOR)
  );
  const retryJitterMs = Number(
    getArgValue(args, "--retry-jitter-ms", DEFAULT_NATIONAL_ELO_RETRY_JITTER_MS)
  );
  const preferIpv4Arg = getArgValue(args, "--prefer-ipv4", String(DEFAULT_NATIONAL_ELO_PREFER_IPV4));
  const preferIpv4 = ["1", "true", "yes", "y", "on"].includes(
    String(preferIpv4Arg || "").trim().toLowerCase()
  );
  const userAgent = getArgValue(args, "--user-agent", DEFAULT_NATIONAL_ELO_USER_AGENT);

  const result = await fetchNationalEloRankings({
    baseUrl,
    page,
    minRows,
    minBytes,
    retryAttempts,
    retryBackoffBaseMs,
    retryBackoffMaxMs,
    retryBackoffFactor,
    retryJitterMs,
    preferIpv4,
    userAgent,
  });
  writeNationalEloRankings(outputPath, result.teams);
  console.log(
    `Saved ${result.teams.length} National Elo teams to ${outputPath} ` +
    `(date=${result.dateModified || "unknown"}, retries=${result.retry.retries_performed})`
  );
}

if (require.main === module) {
  runCli().catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

module.exports = {
  DEFAULT_NATIONAL_ELO_BASE_URL,
  DEFAULT_NATIONAL_ELO_PAGE,
  DEFAULT_NATIONAL_ELO_OUTPUT,
  DEFAULT_NATIONAL_ELO_MIN_ROWS,
  DEFAULT_NATIONAL_ELO_MIN_BYTES,
  DEFAULT_NATIONAL_ELO_TIMEOUT_MS,
  DEFAULT_NATIONAL_ELO_RETRY_ATTEMPTS,
  DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_BASE_MS,
  DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_MAX_MS,
  DEFAULT_NATIONAL_ELO_RETRY_BACKOFF_FACTOR,
  DEFAULT_NATIONAL_ELO_RETRY_JITTER_MS,
  DEFAULT_NATIONAL_ELO_PREFER_IPV4,
  DEFAULT_NATIONAL_ELO_USER_AGENT,
  fetchNationalEloRankings,
  writeNationalEloRankings,
  __private: {
    normalizeBaseUrl,
    normalizePageName,
    buildTsvUrl,
    parseSuccessorMap,
    parseTeamDictionary,
    resolveSuccessorCode,
    parseRankingRows,
    deduplicateByTeamCode,
    buildFallbackTeamDictionaryFromTeams,
    fetchOptionalTextWithRetry,
    normalizeRetryOptions,
    normalizeRequestOptions,
    formatErrorForMessage,
    isRetryableError,
    computeRetryDelayMs,
  },
};
