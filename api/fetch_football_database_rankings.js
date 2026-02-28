#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require("fs");
const http = require("http");
const https = require("https");
const path = require("path");
const { URL } = require("url");
const cheerio = require("cheerio");

const DEFAULT_FOOTBALL_DATABASE_BASE_URL = "https://footballdatabase.com/ranking/world";
const DEFAULT_FOOTBALL_DATABASE_OUTPUT = path.join(__dirname, "football_database_teams.json");
const DEFAULT_FOOTBALL_DATABASE_CONCURRENCY = 20;
const DEFAULT_FOOTBALL_DATABASE_MIN_ROWS = 2000;
const DEFAULT_FOOTBALL_DATABASE_TIMEOUT_MS = 30000;
const DEFAULT_FOOTBALL_DATABASE_MAX_AUTO_PROBE_PAGES = 120;
const DEFAULT_FOOTBALL_DATABASE_RETRY_ATTEMPTS = 4;
const DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS = 500;
const DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_MAX_MS = 8000;
const DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_FACTOR = 2;
const DEFAULT_FOOTBALL_DATABASE_RETRY_JITTER_MS = 250;

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
  return String(baseUrl || DEFAULT_FOOTBALL_DATABASE_BASE_URL).replace(/\/+$/, "");
}

function buildFootballDatabaseUrl(baseUrl, pageNumber) {
  const normalizedBase = normalizeBaseUrl(baseUrl);
  const page = Number.isFinite(Number(pageNumber)) ? Math.max(1, Math.floor(Number(pageNumber))) : 1;
  return `${normalizedBase}/${page}`;
}

function fetchText(url, timeoutMs = DEFAULT_FOOTBALL_DATABASE_TIMEOUT_MS, redirectDepth = 0) {
  return new Promise((resolve, reject) => {
    if (redirectDepth > 5) {
      reject(new Error("Too many redirects while fetching FootballDatabase ranking page"));
      return;
    }

    const target = new URL(url);
    const lib = target.protocol === "https:" ? https : http;
    const req = lib.get(
      target,
      {
        headers: {
          "User-Agent": "Mozilla/5.0 (compatible; FootballDatabaseParser/1.0)",
          Accept: "text/html,application/xhtml+xml,*/*;q=0.8",
        },
      },
      (res) => {
        const statusCode = Number(res.statusCode || 0);
        if (statusCode >= 300 && statusCode < 400 && res.headers.location) {
          const redirectUrl = new URL(res.headers.location, target).toString();
          res.resume();
          fetchText(redirectUrl, timeoutMs, redirectDepth + 1).then(resolve).catch(reject);
          return;
        }
        if (statusCode !== 200) {
          res.resume();
          const httpError = new Error(`FootballDatabase request failed with status ${statusCode}`);
          httpError.statusCode = statusCode;
          httpError.code = `HTTP_${statusCode}`;
          reject(httpError);
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

    req.setTimeout(timeoutMs, () => {
      const timeoutError = new Error("FootballDatabase request timed out");
      timeoutError.code = "ETIMEDOUT";
      req.destroy(timeoutError);
    });
    req.on("error", reject);
  });
}

function cleanText(value) {
  return String(value || "")
    .replace(/\u00a0/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function parseInteger(value) {
  const normalized = cleanText(value).replace(/,/g, "");
  const parsed = Number.parseInt(normalized, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function parseOptionalPositiveInteger(value) {
  if (value === undefined || value === null) return null;
  if (typeof value === "string" && value.trim() === "") return null;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) return null;
  return Math.floor(parsed);
}

function parseOptionalNonNegativeInteger(value) {
  if (value === undefined || value === null) return null;
  if (typeof value === "string" && value.trim() === "") return null;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0) return null;
  return Math.floor(parsed);
}

function parseOptionalPositiveNumber(value) {
  if (value === undefined || value === null) return null;
  if (typeof value === "string" && value.trim() === "") return null;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) return null;
  return parsed;
}

function parseOptionalBoolean(value) {
  if (value === undefined || value === null) return null;
  if (typeof value === "boolean") return value;
  const normalized = String(value).trim().toLowerCase();
  if (!normalized) return null;
  if (["1", "true", "yes", "y", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "n", "off"].includes(normalized)) return false;
  return null;
}

function normalizeAdaptiveConcurrencyOptions(options = {}, fallbackConcurrency = 1) {
  const baseConcurrency = Number.isFinite(Number(fallbackConcurrency))
    ? Math.max(1, Math.floor(Number(fallbackConcurrency)))
    : 1;
  const enabledValue =
    options && Object.prototype.hasOwnProperty.call(options, "adaptiveConcurrencyEnabled")
      ? options.adaptiveConcurrencyEnabled
      : options.enabled;
  const enabledParsed = parseOptionalBoolean(enabledValue);
  const enabled = enabledParsed === null ? true : enabledParsed;
  const minConcurrencyValue =
    options && Object.prototype.hasOwnProperty.call(options, "adaptiveMinConcurrency")
      ? options.adaptiveMinConcurrency
      : options.minConcurrency;
  const defaultMinConcurrency = Math.min(4, baseConcurrency);
  const requestedMinConcurrency =
    parseOptionalPositiveInteger(minConcurrencyValue) || defaultMinConcurrency;
  const minConcurrency = Math.max(1, Math.min(baseConcurrency, requestedMinConcurrency));
  return {
    enabled,
    minConcurrency,
    initialConcurrency: baseConcurrency,
  };
}

function normalizeRetryOptions(options = {}) {
  const attemptsValue =
    options.retryAttempts !== undefined ? options.retryAttempts : options.attempts;
  const backoffBaseMsValue =
    options.retryBackoffBaseMs !== undefined
      ? options.retryBackoffBaseMs
      : options.backoffBaseMs;
  const backoffMaxMsValue =
    options.retryBackoffMaxMs !== undefined ? options.retryBackoffMaxMs : options.backoffMaxMs;
  const backoffFactorValue =
    options.retryBackoffFactor !== undefined
      ? options.retryBackoffFactor
      : options.backoffFactor;
  const jitterMsValue =
    options.retryJitterMs !== undefined ? options.retryJitterMs : options.jitterMs;

  const attempts =
    parseOptionalPositiveInteger(attemptsValue) || DEFAULT_FOOTBALL_DATABASE_RETRY_ATTEMPTS;
  const backoffBaseMs =
    parseOptionalPositiveInteger(backoffBaseMsValue) ||
    DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS;
  const backoffMaxMs = Math.max(
    backoffBaseMs,
    parseOptionalPositiveInteger(backoffMaxMsValue) ||
      DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_MAX_MS
  );
  const backoffFactor =
    parseOptionalPositiveNumber(backoffFactorValue) ||
    DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_FACTOR;
  const parsedJitterMs = parseOptionalNonNegativeInteger(jitterMsValue);
  const jitterMs =
    parsedJitterMs === null ? DEFAULT_FOOTBALL_DATABASE_RETRY_JITTER_MS : parsedJitterMs;
  return {
    attempts,
    backoffBaseMs,
    backoffMaxMs,
    backoffFactor,
    jitterMs,
  };
}

function isRetryableError(error, depth = 0) {
  if (!error || depth > 4) return false;

  const statusCode = Number(error.statusCode || error.status || 0);
  if (RETRYABLE_HTTP_STATUS_CODES.has(statusCode)) return true;

  const code = String(error.code || "").toUpperCase();
  if (RETRYABLE_NETWORK_ERROR_CODES.has(code)) return true;

  if (error.name === "AggregateError" && Array.isArray(error.errors)) {
    return error.errors.some((child) => isRetryableError(child, depth + 1));
  }

  if (error.cause && typeof error.cause === "object") {
    return isRetryableError(error.cause, depth + 1);
  }

  return false;
}

function computeRetryDelayMs(retryNumber, retryOptions) {
  const exponentialDelay =
    retryOptions.backoffBaseMs *
    Math.pow(retryOptions.backoffFactor, Math.max(0, retryNumber - 1));
  const cappedDelay = Math.min(retryOptions.backoffMaxMs, Math.floor(exponentialDelay));
  const jitterDelay =
    retryOptions.jitterMs > 0 ? Math.floor(Math.random() * (retryOptions.jitterMs + 1)) : 0;
  return cappedDelay + jitterDelay;
}

function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, Math.max(0, Math.floor(Number(ms) || 0)));
  });
}

function parseDateOnlyFromDisplayText(value) {
  const text = cleanText(value);
  if (!text) return null;
  const parsedMs = Date.parse(text);
  if (!Number.isFinite(parsedMs) || parsedMs <= 0) return null;
  return new Date(parsedMs).toISOString().slice(0, 10);
}

function parseTotalPages($) {
  let maxPage = 1;
  const considerPage = (value) => {
    const pageNumber = Number.parseInt(String(value || ""), 10);
    if (Number.isFinite(pageNumber) && pageNumber > maxPage) {
      maxPage = pageNumber;
    }
  };

  $("ul.pagination a[href], a[href], option[value]").each((_index, element) => {
    const href = String($(element).attr("href") || $(element).attr("value") || "");
    const match = href.match(/\/ranking\/world\/(\d+)(?:[/?#]|$)/i);
    if (match) considerPage(match[1]);
  });

  // Fallback for markup variants where page links are embedded in scripts or text blocks.
  const wholeHtml = $.root().html() || "";
  const regex = /\/ranking\/world\/(\d+)(?:[/?#"'\\\s]|$)/gi;
  let regexMatch = regex.exec(wholeHtml);
  while (regexMatch) {
    considerPage(regexMatch[1]);
    regexMatch = regex.exec(wholeHtml);
  }

  return maxPage;
}

function firstRowRank(pageResult) {
  if (!pageResult || !Array.isArray(pageResult.rows) || pageResult.rows.length === 0) return null;
  const rank = Number(pageResult.rows[0] && pageResult.rows[0].Rank);
  return Number.isFinite(rank) ? rank : null;
}

function mergePageResults(basePages, additionalPages) {
  const byPage = new Map();
  (Array.isArray(basePages) ? basePages : []).forEach((page) => {
    if (!page || !Number.isFinite(Number(page.pageNumber))) return;
    byPage.set(Number(page.pageNumber), page);
  });
  (Array.isArray(additionalPages) ? additionalPages : []).forEach((page) => {
    if (!page || !Number.isFinite(Number(page.pageNumber))) return;
    byPage.set(Number(page.pageNumber), page);
  });
  return Array.from(byPage.values()).sort(
    (left, right) => Number(left.pageNumber) - Number(right.pageNumber)
  );
}

async function probeAdditionalPages(options = {}) {
  const baseUrl = options.baseUrl || DEFAULT_FOOTBALL_DATABASE_BASE_URL;
  const timeoutMs = Number.isFinite(Number(options.timeoutMs))
    ? Math.max(1000, Math.floor(Number(options.timeoutMs)))
    : DEFAULT_FOOTBALL_DATABASE_TIMEOUT_MS;
  const startPage = Number.isFinite(Number(options.startPage))
    ? Math.max(1, Math.floor(Number(options.startPage)))
    : 1;
  const firstPage = options.firstPage || null;
  const concurrency = Number.isFinite(Number(options.concurrency))
    ? Math.max(1, Math.floor(Number(options.concurrency)))
    : DEFAULT_FOOTBALL_DATABASE_CONCURRENCY;
  const maxAutoProbePages =
    parseOptionalPositiveInteger(options.maxAutoProbePages) ||
    DEFAULT_FOOTBALL_DATABASE_MAX_AUTO_PROBE_PAGES;
  const retryOptions = normalizeRetryOptions(options.retryOptions || {});
  const retryState = options.retryState || null;
  const adaptiveOptions = normalizeAdaptiveConcurrencyOptions(
    options.adaptiveOptions || {},
    concurrency
  );
  const adaptiveState = options.adaptiveState || null;

  if (!firstPage || !Array.isArray(firstPage.rows) || firstPage.rows.length === 0) {
    return {
      totalPages: startPage,
      pages: [],
      stoppedBy: "missing_first_page",
    };
  }

  const acceptedPages = [];
  let lastAcceptedPage = startPage;
  let previousFirstRank = firstRowRank(firstPage);
  let stoppedBy = "reached_probe_limit";

  const candidatePages = [];
  for (
    let page = startPage + 1;
    page <= startPage + maxAutoProbePages;
    page += 1
  ) {
    candidatePages.push(page);
  }

  for (let index = 0; index < candidatePages.length; index += concurrency) {
    const batchPages = candidatePages.slice(index, index + concurrency);
    let batchResults = [];
    try {
      batchResults = await fetchPagesInBatches(
        baseUrl,
        timeoutMs,
        batchPages,
        concurrency,
        retryOptions,
        retryState,
        adaptiveOptions,
        adaptiveState
      );
    } catch (_error) {
      stoppedBy = "fetch_error";
      break;
    }

    let shouldStop = false;
    for (let resultIndex = 0; resultIndex < batchResults.length; resultIndex += 1) {
      const candidatePageNumber = batchPages[resultIndex];
      const pageResult = batchResults[resultIndex];
      if (!Array.isArray(pageResult.rows) || pageResult.rows.length === 0) {
        stoppedBy = "empty_rows";
        shouldStop = true;
        break;
      }

      const currentFirstRank = firstRowRank(pageResult);
      if (!Number.isFinite(currentFirstRank)) {
        stoppedBy = "missing_rank";
        shouldStop = true;
        break;
      }

      if (Number.isFinite(previousFirstRank) && currentFirstRank <= previousFirstRank) {
        // The source likely repeated page 1 (or stopped exposing deeper pages).
        stoppedBy = "non_increasing_rank";
        shouldStop = true;
        break;
      }

      acceptedPages.push(pageResult);
      lastAcceptedPage = candidatePageNumber;
      previousFirstRank = currentFirstRank;
    }

    if (shouldStop) break;
  }

  return {
    totalPages: lastAcceptedPage,
    pages: acceptedPages,
    stoppedBy,
  };
}

function buildRemainingPages(startPage, totalPages, alreadyFetchedPages) {
  const fetchedSet = new Set(
    (Array.isArray(alreadyFetchedPages) ? alreadyFetchedPages : [])
      .map((value) => Number(value))
      .filter((value) => Number.isFinite(value))
  );
  const remaining = [];
  for (let page = startPage; page <= totalPages; page += 1) {
    if (fetchedSet.has(page)) continue;
    remaining.push(page);
  }
  return remaining;
}

function fetchPagesInBatches(
  baseUrl,
  timeoutMs,
  pageNumbers,
  concurrency,
  retryOptions = {},
  retryState = null,
  adaptiveOptions = {},
  adaptiveState = null
) {
  const pages = Array.isArray(pageNumbers) ? pageNumbers.slice() : [];
  const normalizedConcurrency = Number.isFinite(Number(concurrency))
    ? Math.max(1, Math.floor(Number(concurrency)))
    : DEFAULT_FOOTBALL_DATABASE_CONCURRENCY;
  const normalizedRetryOptions = normalizeRetryOptions(retryOptions);
  const normalizedAdaptiveOptions = normalizeAdaptiveConcurrencyOptions(
    adaptiveOptions,
    normalizedConcurrency
  );
  return (async () => {
    const outputByPage = new Map();
    const queue = pages.slice();
    let currentConcurrency = normalizedConcurrency;

    if (adaptiveState && typeof adaptiveState === "object") {
      if (!Number.isFinite(adaptiveState.initial_concurrency)) {
        adaptiveState.initial_concurrency = normalizedConcurrency;
      }
      adaptiveState.final_concurrency = currentConcurrency;
      adaptiveState.min_concurrency = normalizedAdaptiveOptions.minConcurrency;
      adaptiveState.enabled = Boolean(normalizedAdaptiveOptions.enabled);
      adaptiveState.reductions = Number.isFinite(adaptiveState.reductions)
        ? adaptiveState.reductions
        : 0;
      adaptiveState.total_batches = Number.isFinite(adaptiveState.total_batches)
        ? adaptiveState.total_batches
        : 0;
      adaptiveState.failed_batches = Number.isFinite(adaptiveState.failed_batches)
        ? adaptiveState.failed_batches
        : 0;
    }

    while (queue.length > 0) {
      const pageBatch = queue.splice(0, currentConcurrency);
      const settled = await Promise.allSettled(
        pageBatch.map((pageNumber) =>
          fetchPage(baseUrl, pageNumber, timeoutMs, normalizedRetryOptions, retryState)
        )
      );

      if (adaptiveState && typeof adaptiveState === "object") {
        adaptiveState.total_batches += 1;
      }

      const failed = [];
      settled.forEach((result, resultIndex) => {
        const pageNumber = pageBatch[resultIndex];
        if (result && result.status === "fulfilled") {
          outputByPage.set(pageNumber, result.value);
          return;
        }
        failed.push({
          pageNumber,
          error: result && result.status === "rejected" ? result.reason : null,
        });
      });

      if (failed.length === 0) continue;

      if (adaptiveState && typeof adaptiveState === "object") {
        adaptiveState.failed_batches += 1;
      }

      const nonRetryableFailure = failed.find(
        (entry) => !isRetryableError(entry && entry.error ? entry.error : null)
      );
      const failure = nonRetryableFailure || failed[0];
      const failureError = failure && failure.error ? failure.error : new Error("Unknown fetch failure");

      const canReduceConcurrency =
        normalizedAdaptiveOptions.enabled &&
        currentConcurrency > normalizedAdaptiveOptions.minConcurrency;
      if (canReduceConcurrency) {
        const reducedConcurrency = Math.max(
          normalizedAdaptiveOptions.minConcurrency,
          Math.floor(currentConcurrency / 2)
        );
        if (reducedConcurrency < currentConcurrency) {
          currentConcurrency = reducedConcurrency;
          if (adaptiveState && typeof adaptiveState === "object") {
            adaptiveState.reductions += 1;
            adaptiveState.final_concurrency = currentConcurrency;
          }
        }
        queue.unshift(...failed.map((entry) => entry.pageNumber));
        continue;
      }

      const wrapped = new Error(
        `FootballDatabase batch failed at concurrency ${currentConcurrency} ` +
          `(min=${normalizedAdaptiveOptions.minConcurrency}) on page ${failure.pageNumber}: ` +
          `${failureError && failureError.message ? failureError.message : failureError}`
      );
      wrapped.code = failureError && failureError.code ? failureError.code : undefined;
      wrapped.statusCode =
        failureError && failureError.statusCode ? failureError.statusCode : undefined;
      wrapped.cause = failureError;
      throw wrapped;
    }

    if (adaptiveState && typeof adaptiveState === "object") {
      adaptiveState.final_concurrency = currentConcurrency;
    }

    const output = [];
    pages.forEach((pageNumber) => {
      if (outputByPage.has(pageNumber)) {
        output.push(outputByPage.get(pageNumber));
      }
    });
    if (output.length !== pages.length) {
      throw new Error(
        `FootballDatabase batch fetch mismatch: expected ${pages.length} pages, received ${output.length}`
      );
    }
    return output;
  })();
}

function sortPagesByPageNumber(pages) {
  return (Array.isArray(pages) ? pages : [])
    .slice()
    .sort((left, right) => Number(left.pageNumber) - Number(right.pageNumber));
}

function totalPageBytes(pages) {
  return (Array.isArray(pages) ? pages : []).reduce(
    (sum, page) => sum + Number(page && page.byteLength ? page.byteLength : 0),
    0
  );
}

function collectPageContentTypes(pages) {
  const contentTypes = new Set();
  (Array.isArray(pages) ? pages : []).forEach((page) => {
    if (page && page.contentType) contentTypes.add(page.contentType);
  });
  return Array.from(contentTypes.values()).join(",");
}

function collectPageDates(pages) {
  return (Array.isArray(pages) ? pages : [])
    .map((page) => (page && page.dateModified ? page.dateModified : null))
    .filter(Boolean);
}

function collectPageUrls(pages) {
  return (Array.isArray(pages) ? pages : [])
    .map((page) => (page && page.url ? page.url : null))
    .filter(Boolean);
}

function flattenPageRows(pages) {
  const rows = [];
  (Array.isArray(pages) ? pages : []).forEach((page) => {
    if (Array.isArray(page && page.rows)) {
      rows.push(...page.rows);
    }
  });
  return rows;
}

function buildPaginationDebug(firstPage, totalPages, fetchedPages, probeStopReason = null) {
  return {
    first_page_detected_total_pages: Number(firstPage && firstPage.totalPages) || 1,
    resolved_total_pages: totalPages,
    fetched_pages: fetchedPages,
    probe_stop_reason: probeStopReason,
  };
}

function parseOneYearChange(cell) {
  if (!cell || cell.length === 0) return null;
  const textNodes = cell
    .contents()
    .filter((_index, node) => node && node.type === "text")
    .toArray()
    .map((node) => cleanText(node.data))
    .filter(Boolean);
  const rawText = textNodes.join(" ");
  const absoluteChange = parseInteger(rawText);
  if (!Number.isFinite(absoluteChange)) {
    if (cell.find(".ranking-yrchg-left, .ranking-yrchg-right").length > 0) return 0;
    return null;
  }
  if (cell.find(".ranking-yrchg-down").length > 0) {
    return -Math.abs(absoluteChange);
  }
  if (cell.find(".ranking-yrchg-up").length > 0) {
    return Math.abs(absoluteChange);
  }
  if (cell.find(".ranking-yrchg-left, .ranking-yrchg-right").length > 0) {
    return 0;
  }
  return absoluteChange;
}

function parseRows($) {
  const rows = [];
  $("table.table.table-hover tbody tr").each((_index, element) => {
    const row = $(element);
    const columns = row.find("td");
    if (!columns || columns.length < 4) return;

    const rank = parseInteger($(columns[0]).text());
    if (!Number.isFinite(rank) || rank <= 0) return;

    const clubCell = $(columns[1]);
    const clubName =
      cleanText(clubCell.find("div[itemprop='itemListElement']").first().text()) ||
      cleanText(clubCell.find(".limittext").first().text()) ||
      cleanText(clubCell.find("a").first().text());
    if (!clubName) return;

    const countryName = cleanText(clubCell.find("a.sm_logo-name").first().text()) || null;
    const points = parseInteger($(columns[2]).text());
    const changeCell = $(columns[3]);
    const oneYearChange = parseOneYearChange(changeCell);
    const previousPoints = parseInteger(changeCell.find("div").first().text());

    rows.push({
      Name: clubName,
      Rank: rank,
      Club: clubName,
      Country: countryName,
      Points: Number.isFinite(points) ? points : null,
      OneYearChange: Number.isFinite(oneYearChange) ? oneYearChange : null,
      PreviousPoints: Number.isFinite(previousPoints) ? previousPoints : null,
    });
  });
  return rows;
}

function parsePageHtml(htmlText) {
  const html = String(htmlText || "");
  const $ = cheerio.load(html);
  const rows = parseRows($);
  const totalPages = parseTotalPages($);
  const dateModifiedText = cleanText($("span[itemprop='dateModified']").first().text());
  const dateModified = parseDateOnlyFromDisplayText(dateModifiedText);
  return {
    rows,
    totalPages,
    dateModifiedText: dateModifiedText || null,
    dateModified,
  };
}

function validateHtmlResponse(response) {
  const contentType = String(
    response && response.headers ? response.headers["content-type"] || "" : ""
  ).toLowerCase();
  const body = String(response && response.body ? response.body : "");
  const looksLikeHtml = /^\s*</.test(body);
  if (contentType && !contentType.includes("text/html") && !contentType.includes("xhtml") && !looksLikeHtml) {
    throw new Error(
      `FootballDatabase response is not HTML content-type (received: ${contentType || "none"})`
    );
  }
  if (!body) {
    throw new Error("FootballDatabase response body is empty");
  }
  return {
    body,
    byteLength: Buffer.byteLength(body, "utf8"),
    contentType,
  };
}

async function fetchPageOnce(baseUrl, pageNumber, timeoutMs) {
  const url = buildFootballDatabaseUrl(baseUrl, pageNumber);
  const response = await fetchText(url, timeoutMs);
  const validated = validateHtmlResponse(response);
  const parsed = parsePageHtml(validated.body);
  return {
    pageNumber,
    url,
    byteLength: validated.byteLength,
    contentType: validated.contentType,
    ...parsed,
  };
}

async function fetchPage(baseUrl, pageNumber, timeoutMs, retryOptions = {}, retryState = null) {
  const normalizedRetryOptions = normalizeRetryOptions(retryOptions);
  for (let attempt = 1; attempt <= normalizedRetryOptions.attempts; attempt += 1) {
    try {
      return await fetchPageOnce(baseUrl, pageNumber, timeoutMs);
    } catch (error) {
      const hasMoreAttempts = attempt < normalizedRetryOptions.attempts;
      const retryable = isRetryableError(error);
      if (!hasMoreAttempts || !retryable) {
        if (attempt > 1) {
          const wrapped = new Error(
            `FootballDatabase page ${pageNumber} failed after ${attempt} attempts: ` +
              `${error && error.message ? error.message : error}`
          );
          wrapped.code = error && error.code ? error.code : undefined;
          wrapped.statusCode = error && error.statusCode ? error.statusCode : undefined;
          wrapped.cause = error;
          throw wrapped;
        }
        throw error;
      }

      if (retryState && retryState.retriedPages instanceof Set) {
        retryState.retriesPerformed = Number(retryState.retriesPerformed || 0) + 1;
        retryState.retriedPages.add(pageNumber);
      }

      const delayMs = computeRetryDelayMs(attempt, normalizedRetryOptions);
      await sleep(delayMs);
    }
  }

  throw new Error(`FootballDatabase page ${pageNumber} exhausted retry attempts`);
}

function deduplicateByRank(rows) {
  const byRank = new Map();
  (Array.isArray(rows) ? rows : []).forEach((row) => {
    const rank = Number(row && row.Rank);
    if (!Number.isFinite(rank) || rank <= 0) return;
    if (!byRank.has(rank)) {
      byRank.set(rank, row);
    }
  });
  return Array.from(byRank.values()).sort((left, right) => {
    if (left.Rank !== right.Rank) return left.Rank - right.Rank;
    return String(left.Club || "").localeCompare(String(right.Club || ""));
  });
}

async function fetchFootballDatabaseRankings(options = {}) {
  const baseUrl = options.baseUrl || DEFAULT_FOOTBALL_DATABASE_BASE_URL;
  const timeoutMs = Number.isFinite(Number(options.timeoutMs))
    ? Math.max(1000, Math.floor(Number(options.timeoutMs)))
    : DEFAULT_FOOTBALL_DATABASE_TIMEOUT_MS;
  const concurrency = Number.isFinite(Number(options.concurrency))
    ? Math.max(1, Math.floor(Number(options.concurrency)))
    : DEFAULT_FOOTBALL_DATABASE_CONCURRENCY;
  const minRows = Number.isFinite(Number(options.minRows))
    ? Math.max(1, Math.floor(Number(options.minRows)))
    : DEFAULT_FOOTBALL_DATABASE_MIN_ROWS;
  const startPage = Number.isFinite(Number(options.startPage))
    ? Math.max(1, Math.floor(Number(options.startPage)))
    : 1;
  const maxPages = parseOptionalPositiveInteger(options.maxPages);
  const maxAutoProbePages =
    parseOptionalPositiveInteger(options.maxAutoProbePages) ||
    DEFAULT_FOOTBALL_DATABASE_MAX_AUTO_PROBE_PAGES;
  const retryOptions = normalizeRetryOptions(options);
  const adaptiveOptions = normalizeAdaptiveConcurrencyOptions(options, concurrency);
  const retryState = {
    retriesPerformed: 0,
    retriedPages: new Set(),
  };
  const adaptiveState = {
    enabled: adaptiveOptions.enabled,
    initial_concurrency: concurrency,
    final_concurrency: concurrency,
    min_concurrency: adaptiveOptions.minConcurrency,
    reductions: 0,
    total_batches: 0,
    failed_batches: 0,
  };

  const firstPage = await fetchPage(baseUrl, startPage, timeoutMs, retryOptions, retryState);
  if (!Array.isArray(firstPage.rows) || firstPage.rows.length === 0) {
    throw new Error(`FootballDatabase page ${startPage} returned no ranking rows`);
  }

  let totalPages = Number.isFinite(firstPage.totalPages) ? firstPage.totalPages : startPage;
  let pageResults = [firstPage];
  let probeStopReason = null;

  if (!maxPages && totalPages <= startPage) {
    const probeResult = await probeAdditionalPages({
      baseUrl,
      timeoutMs,
      startPage,
      firstPage,
      concurrency,
      maxAutoProbePages,
      retryOptions,
      retryState,
      adaptiveOptions,
      adaptiveState,
    });
    totalPages = Math.max(totalPages, Number(probeResult.totalPages) || startPage);
    pageResults = mergePageResults(pageResults, probeResult.pages);
    probeStopReason = probeResult.stoppedBy || null;
  }

  if (maxPages) {
    totalPages = Math.min(totalPages, maxPages);
  }
  totalPages = Math.max(startPage, totalPages);

  const remainingPages = buildRemainingPages(
    startPage,
    totalPages,
    pageResults.map((page) => page.pageNumber)
  );
  if (remainingPages.length > 0) {
    const fetchedRemainingPages = await fetchPagesInBatches(
      baseUrl,
      timeoutMs,
      remainingPages,
      concurrency,
      retryOptions,
      retryState,
      adaptiveOptions,
      adaptiveState
    );
    pageResults = mergePageResults(pageResults, fetchedRemainingPages);
  }

  const sortedPageResults = sortPagesByPageNumber(pageResults);
  const allRows = flattenPageRows(sortedPageResults);
  const totalBytes = totalPageBytes(sortedPageResults);
  const parsedDateCandidates = collectPageDates(sortedPageResults);
  const pageUrls = collectPageUrls(sortedPageResults);
  const paginationDebug = buildPaginationDebug(
    firstPage,
    totalPages,
    sortedPageResults.length,
    probeStopReason
  );

  const teams = deduplicateByRank(allRows);
  if (teams.length < minRows) {
    throw new Error(
      `FootballDatabase parsed rows too small (${teams.length}). Expected at least ${minRows}. ` +
      `Pagination debug: ${JSON.stringify(paginationDebug)}`
    );
  }

  const dateModified = parsedDateCandidates.sort().slice(-1)[0] || null;
  return {
    url: buildFootballDatabaseUrl(baseUrl, startPage),
    pageUrls,
    startPage,
    totalPages,
    fetchedPages: sortedPageResults.length,
    teams,
    rowCount: teams.length,
    byteLength: totalBytes,
    contentType: collectPageContentTypes(sortedPageResults),
    dateModified,
    concurrency,
    pagination: paginationDebug,
    maxAutoProbePages,
    retry: {
      attempts: retryOptions.attempts,
      backoff_base_ms: retryOptions.backoffBaseMs,
      backoff_max_ms: retryOptions.backoffMaxMs,
      backoff_factor: retryOptions.backoffFactor,
      jitter_ms: retryOptions.jitterMs,
      retries_performed: retryState.retriesPerformed,
      pages_retried: retryState.retriedPages.size,
    },
    adaptive_concurrency: {
      enabled: adaptiveState.enabled,
      initial_concurrency: adaptiveState.initial_concurrency,
      final_concurrency: adaptiveState.final_concurrency,
      min_concurrency: adaptiveState.min_concurrency,
      reductions: adaptiveState.reductions,
      total_batches: adaptiveState.total_batches,
      failed_batches: adaptiveState.failed_batches,
    },
  };
}

function writeFootballDatabaseRankings(outputPath, teams) {
  fs.writeFileSync(outputPath, JSON.stringify(teams, null, 2), "utf8");
}

function getArgValue(args, flag, fallback = null) {
  const index = args.indexOf(flag);
  if (index === -1 || index + 1 >= args.length) return fallback;
  return args[index + 1];
}

async function runCli() {
  const args = process.argv.slice(2);
  const baseUrl = getArgValue(args, "--base-url", DEFAULT_FOOTBALL_DATABASE_BASE_URL);
  const outputPath = path.resolve(
    getArgValue(args, "--out", DEFAULT_FOOTBALL_DATABASE_OUTPUT)
  );
  const concurrency = Number(
    getArgValue(args, "--concurrency", DEFAULT_FOOTBALL_DATABASE_CONCURRENCY)
  );
  const minRows = Number(getArgValue(args, "--min-rows", DEFAULT_FOOTBALL_DATABASE_MIN_ROWS));
  const maxPagesArg = getArgValue(args, "--max-pages", null);
  const maxPages = maxPagesArg === null ? null : Number(maxPagesArg);
  const retryAttempts = Number(
    getArgValue(args, "--retry-attempts", DEFAULT_FOOTBALL_DATABASE_RETRY_ATTEMPTS)
  );
  const retryBackoffBaseMs = Number(
    getArgValue(args, "--retry-backoff-base-ms", DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS)
  );
  const retryBackoffMaxMs = Number(
    getArgValue(args, "--retry-backoff-max-ms", DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_MAX_MS)
  );
  const retryBackoffFactor = Number(
    getArgValue(args, "--retry-backoff-factor", DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_FACTOR)
  );
  const retryJitterMs = Number(
    getArgValue(args, "--retry-jitter-ms", DEFAULT_FOOTBALL_DATABASE_RETRY_JITTER_MS)
  );
  const adaptiveConcurrencyEnabled = getArgValue(args, "--adaptive-concurrency", "true");
  const adaptiveMinConcurrency = Number(getArgValue(args, "--adaptive-min-concurrency", 4));

  const result = await fetchFootballDatabaseRankings({
    baseUrl,
    concurrency,
    minRows,
    maxPages,
    retryAttempts,
    retryBackoffBaseMs,
    retryBackoffMaxMs,
    retryBackoffFactor,
    retryJitterMs,
    adaptiveConcurrencyEnabled,
    adaptiveMinConcurrency,
  });
  writeFootballDatabaseRankings(outputPath, result.teams);
  console.log(
    `Saved ${result.teams.length} FootballDatabase teams across ${result.fetchedPages}/${result.totalPages} pages to ${outputPath} ` +
    `(retries=${result.retry ? result.retry.retries_performed : 0}, ` +
    `pages_retried=${result.retry ? result.retry.pages_retried : 0}, ` +
    `adaptive_reductions=${result.adaptive_concurrency ? result.adaptive_concurrency.reductions : 0}, ` +
    `final_concurrency=${result.adaptive_concurrency ? result.adaptive_concurrency.final_concurrency : "n/a"})`
  );
}

if (require.main === module) {
  runCli().catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });
}

module.exports = {
  DEFAULT_FOOTBALL_DATABASE_BASE_URL,
  DEFAULT_FOOTBALL_DATABASE_OUTPUT,
  DEFAULT_FOOTBALL_DATABASE_CONCURRENCY,
  DEFAULT_FOOTBALL_DATABASE_MIN_ROWS,
  DEFAULT_FOOTBALL_DATABASE_TIMEOUT_MS,
  DEFAULT_FOOTBALL_DATABASE_RETRY_ATTEMPTS,
  DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_BASE_MS,
  DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_MAX_MS,
  DEFAULT_FOOTBALL_DATABASE_RETRY_BACKOFF_FACTOR,
  DEFAULT_FOOTBALL_DATABASE_RETRY_JITTER_MS,
  fetchFootballDatabaseRankings,
  writeFootballDatabaseRankings,
  __private: {
    DEFAULT_FOOTBALL_DATABASE_MAX_AUTO_PROBE_PAGES,
    buildFootballDatabaseUrl,
    parsePageHtml,
    parseRows,
    parseTotalPages,
    parseOneYearChange,
    deduplicateByRank,
    validateHtmlResponse,
    probeAdditionalPages,
    buildRemainingPages,
    mergePageResults,
    normalizeRetryOptions,
    normalizeAdaptiveConcurrencyOptions,
    isRetryableError,
    computeRetryDelayMs,
  },
};
