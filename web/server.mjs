import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import express from "express";
import { registerArtwork } from "./artwork.mjs";
import { createTeamLogoResolver } from "./team-logos.mjs";
import { createPageRenderer } from "./page-document.mjs";
import broadcastConfig from "./server-shared/broadcast_priorities.cjs";
const { broadcastPriorities } = broadcastConfig;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const productionClientRoot = path.join(__dirname, "dist");
const apiBaseUrl = (process.env.TOP_SCORES_API_BASE_URL ||
  process.env.API_BASE_URL ||
  "http://127.0.0.1:3011/api/v1").replace(/\/+$/, "");
const port = Number(process.env.PORT || 3020);
const isProduction = process.env.NODE_ENV === "production";
const debugProxyThresholdMs = Number(process.env.TOP_SCORES_WEB_PROXY_SLOW_MS || 500);
const apiRetryAttempts = Math.max(1, Math.floor(numberSetting("TOP_SCORES_WEB_API_RETRY_ATTEMPTS", 6)));
const apiRetryBaseDelayMs = Math.max(0, numberSetting("TOP_SCORES_WEB_API_RETRY_BASE_MS", 500));
const apiRetryMaxDelayMs = Math.max(apiRetryBaseDelayMs, numberSetting("TOP_SCORES_WEB_API_RETRY_MAX_MS", 8000));
const generatedAssetsRoot = isProduction
  ? path.join(productionClientRoot, "generated-assets")
  : path.join(__dirname, "public", "generated-assets");
const tvLogosRoot = path.join(generatedAssetsRoot, "tv-logos");
const teamShortNamesConfigPath = path.join(__dirname, "..", "api", "team_short_names.json");
const appIconPath = path.join(generatedAssetsRoot, "app-icon.png");
const faviconPath = path.join(generatedAssetsRoot, "favicon-32.png");
const appleTouchIconPath = path.join(generatedAssetsRoot, "apple-touch-icon.png");

// Event-loop stall logger: detects synchronous blocks in this process that
// delay proxied API responses (diagnosing browser-visible multi-second loads
// that don't show up in the API's own timings).
const stallThresholdMs = Number(process.env.TOP_SCORES_WEB_STALL_THRESHOLD_MS || 200);
if (stallThresholdMs > 0) {
  const tickIntervalMs = 100;
  let lastTickMs = Date.now();
  setInterval(() => {
    const nowMs = Date.now();
    const delayMs = nowMs - lastTickMs - tickIntervalMs;
    lastTickMs = nowMs;
    if (delayMs >= stallThresholdMs) {
      // eslint-disable-next-line no-console
      console.warn(`[web][event-loop-stall] delay_ms=${delayMs} at=${new Date(nowMs).toISOString()}`);
    }
  }, tickIntervalMs).unref();
}

const tvLogoIndex = buildTvLogoIndex();
const teamShortNameEntries = loadTeamShortNameEntries();
const resolveTeamLogo = createTeamLogoResolver(generatedAssetsRoot, teamShortNameEntries);

let competitionWeightsCache = [];

async function loadCompetitionWeights() {
  try {
    const response = await fetchApiWithRetry(`${apiBaseUrl}/competitions/weights`, undefined, {
      label: "competition weights",
    });
    if (response.ok) {
      const data = await response.json();
      if (Array.isArray(data)) {
        competitionWeightsCache = data.filter(
          (entry) => typeof entry?.name === "string" && typeof entry?.weight === "number"
        );
        // eslint-disable-next-line no-console
        console.log(`[web] Loaded ${competitionWeightsCache.length} competition weights`);
      }
    } else {
      // eslint-disable-next-line no-console
      console.warn(`[web] Failed to load competition weights: ${response.status}`);
    }
  } catch (error) {
    // eslint-disable-next-line no-console
    console.warn(`[web] Failed to load competition weights: ${error instanceof Error ? error.message : String(error)}`);
  }
}

const app = express();
app.get("/fixtures", (req, res) => res.redirect(308, `/${req.originalUrl.includes("?") ? req.originalUrl.slice(req.originalUrl.indexOf("?")) : ""}`));

app.disable("x-powered-by");
registerArtwork(app, apiBaseUrl);

const canonicalOrigin = (process.env.TOP_SCORES_WEB_ORIGIN || "https://top-scores.skynolimit.dev").replace(/\/+$/, "");

app.get("/healthcheck", (_req, res) => {
  res.json({
    ok: true,
    apiBaseUrl,
    mode: isProduction ? "production" : "development",
  });
});

app.get("/competition-weights", (_req, res) => {
  res.json(competitionWeightsCache);
});

app.get("/brand/app-icon", (_req, res) => {
  if (!fs.existsSync(appIconPath)) {
    res.status(404).json({ error: "App icon not found" });
    return;
  }

  res.sendFile(appIconPath, { maxAge: "1d" });
});

app.get("/favicon.ico", (_req, res) => {
  if (!fs.existsSync(faviconPath)) {
    res.status(404).end();
    return;
  }

  res.sendFile(faviconPath, { maxAge: "1d" });
});

app.get("/apple-touch-icon.png", (_req, res) => {
  if (!fs.existsSync(appleTouchIconPath)) {
    res.status(404).end();
    return;
  }

  res.sendFile(appleTouchIconPath, { maxAge: "1d" });
});

app.get("/logos/team/:teamName", (req, res) => {
  const resolved = resolveTeamLogo(req.params.teamName || "");
  if (!resolved) {
    sendTeamPlaceholder(res, req.params.teamName || "");
    return;
  }

  res.sendFile(resolved);
});

app.get("/logos/team", (req, res) => {
  const requestedName = typeof req.query.name === "string" ? req.query.name : "";
  const alternateName = typeof req.query.alt === "string" ? req.query.alt : "";
  const resolved = resolveTeamLogo(requestedName, alternateName);
  if (!resolved) {
    sendTeamPlaceholder(res, requestedName);
    return;
  }

  res.sendFile(resolved);
});

app.get("/logos/tv/:channelName", (req, res) => {
  const channelName = decodeURIComponent(req.params.channelName || "");
  const resolved = resolveTvLogo(channelName);
  if (!resolved) {
    res.status(404).json({ error: "TV logo not found" });
    return;
  }

  res.sendFile(resolved);
});

app.get("/logos/tv", (req, res) => {
  const channelName = typeof req.query.name === "string" ? req.query.name : "";
  const resolved = resolveTvLogo(channelName);
  if (!resolved) {
    res.status(404).json({ error: "TV logo not found" });
    return;
  }

  res.sendFile(resolved);
});

app.use(
  "/api/v1",
  express.raw({
    inflate: true,
    limit: "2mb",
    type: "*/*",
  }),
  async (req, res) => {
    const requestId = Math.random().toString(36).slice(2, 10);
    const startedAtMs = Date.now();
    try {
      const suffix = req.originalUrl.replace(/^\/api\/v1\/?/, "");
      const target = new URL(
        suffix,
        apiBaseUrl.endsWith("/") ? apiBaseUrl : `${apiBaseUrl}/`
      );

      const upstream = await fetchApiWithRetry(target, {
        method: req.method,
        headers: buildProxyHeaders(req.headers),
        body: shouldSendBody(req.method) ? req.body : undefined,
      }, {
        attempts: shouldRetryProxyRequest(req.method) ? apiRetryAttempts : 1,
        label: `proxy ${req.method} ${req.originalUrl}`,
      });
      const upstreamHeadersReceivedAtMs = Date.now();

      res.status(upstream.status);
      upstream.headers.forEach((value, key) => {
        if (["content-encoding", "content-length", "connection"].includes(key.toLowerCase())) {
          return;
        }
        res.setHeader(key, value);
      });

      const buffer = Buffer.from(await upstream.arrayBuffer());
      const totalDurationMs = Date.now() - startedAtMs;
      const upstreamHeaderDurationMs = upstreamHeadersReceivedAtMs - startedAtMs;
      const bodyReadDurationMs = totalDurationMs - upstreamHeaderDurationMs;
      const logLine =
        `[web][proxy] id=${requestId} at=${new Date(startedAtMs).toISOString()} method=${req.method} path=${req.originalUrl} ` +
        `target=${target.toString()} status=${upstream.status} ` +
        `upstream_header_ms=${upstreamHeaderDurationMs} body_read_ms=${bodyReadDurationMs} total_ms=${totalDurationMs}`;
      if (totalDurationMs >= debugProxyThresholdMs) {
        // eslint-disable-next-line no-console
        console.warn(logLine);
      } else {
        // eslint-disable-next-line no-console
        console.log(logLine);
      }
      if (upstream.ok && req.method === "GET" && /^matches(?:[/?]|$)/.test(suffix) &&
          upstream.headers.get("content-type")?.includes("application/json")) {
        // Use the same hot-reloaded server config even while the upstream API is on an older release.
        res.removeHeader("ETag");
        res.setHeader("Cache-Control", "no-store");
        res.json(broadcastPriorities.apply(JSON.parse(buffer.toString("utf8"))));
      } else res.send(buffer);
    } catch (error) {
      // eslint-disable-next-line no-console
      console.error(
        `[web][proxy][error] method=${req.method} path=${req.originalUrl} base=${apiBaseUrl} message=${error instanceof Error ? error.message : String(error)}`
      );
      res.status(502).json({
        error: "Failed to reach the Top Scores API",
        details: error instanceof Error ? error.message : String(error),
      });
    }
  }
);

async function start() {
  await loadCompetitionWeights();
  setInterval(() => { void loadCompetitionWeights(); }, 24 * 60 * 60 * 1000);

  if (isProduction) {
    app.use("/assets", express.static(path.join(productionClientRoot, "assets"), { immutable: true, maxAge: "1y" }));
    // A ?v= query string marks a versioned URL whose content never changes, so it can be cached indefinitely.
    const versionedGeneratedAssets = express.static(generatedAssetsRoot, { immutable: true, maxAge: "1y" });
    app.use("/generated-assets", (req, res, next) => (req.query.v ? versionedGeneratedAssets(req, res, next) : next()));
    app.use(express.static(productionClientRoot, { index: false, maxAge: "1h" }));
    app.get("/generated-assets/*", (_req, res) => {
      res.status(404).end();
    });

    const { render } = await import("./dist-server/server-entry.js");
    const renderPage = createPageRenderer(apiBaseUrl, render, broadcastPriorities.apply);
    const manifest = JSON.parse(await fs.promises.readFile(path.join(productionClientRoot, ".vite/manifest.json"), "utf8"));
    const routeAssets = url => {
      const route = new URL(url, canonicalOrigin).pathname;
      const component = route.startsWith("/matches/") ? "MatchPage" : route.startsWith("/competitions/") ? "CompetitionPage" : route === "/tables" ? "TablesScreen" : null;
      const visited = new Set(), css = new Set(), scripts = new Set();
      const visit = key => {
        if (visited.has(key) || !manifest[key]) return;
        visited.add(key);
        const chunk = manifest[key];
        if (key !== "index.html") {
          if (chunk.file.endsWith(".js")) scripts.add(chunk.file);
          for (const file of chunk.css || []) css.add(file);
        }
        for (const dependency of chunk.imports || []) visit(dependency);
      };
      if (component) visit(`src/client/components/${component}.tsx`);
      if (component === "CompetitionPage" && new URL(url, canonicalOrigin).searchParams.get("section") === "table") visit("src/client/components/TablesScreen.tsx");
      return [...css].map(file => `<link rel="stylesheet" href="/${file}">`).join("") + [...scripts].map(file => `<link rel="modulepreload" href="/${file}">`).join("");
    };
    const template = await fs.promises.readFile(path.join(productionClientRoot, "index.html"), "utf8");
    app.get("*", async (req, res, next) => {
      try {
        const { html, status } = await renderPage(template.replace("</head>", `${routeAssets(req.originalUrl)}</head>`), req.originalUrl, canonicalOrigin);
        res.status(status).set("Cache-Control", "no-cache").type("html").send(html);
      } catch (error) { next(error); }
    });
  } else {
    const { createServer } = await import("vite");
    const vite = await createServer({
      root: __dirname,
      server: { middlewareMode: true },
      appType: "custom",
    });

    app.use(vite.middlewares);
    const renderDevelopmentPage = createPageRenderer(apiBaseUrl, async (url, seed) => {
      const { render } = await vite.ssrLoadModule("/src/server-entry.tsx");
      return render(url, seed);
    }, broadcastPriorities.apply);

    app.get("*", async (req, res, next) => {
      try {
        const templatePath = path.join(__dirname, "index.html");
        const template = await fs.promises.readFile(templatePath, "utf8");
        const transformed = await vite.transformIndexHtml(req.originalUrl, template);
        const { html, status } = await renderDevelopmentPage(transformed, req.originalUrl, canonicalOrigin);
        res.status(status).type("html").send(html);
      } catch (error) {
        vite.ssrFixStacktrace(error);
        next(error);
      }
    });
  }

  app.listen(port, () => {
    // eslint-disable-next-line no-console
    console.log(`Top Scores web server listening on http://localhost:${port}`);
  });
}

start();

async function fetchApiWithRetry(resource, init, options = {}) {
  const attempts = Math.max(1, Number(options.attempts || apiRetryAttempts));
  const label = options.label || "api request";
  let lastError = null;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetch(resource, init);
      if (!isRetryableApiStatus(response.status) || attempt === attempts) {
        return response;
      }

      await response.body?.cancel();
      const delayMs = retryDelayMs(attempt);
      logRetry(label, attempt, attempts, delayMs, `status ${response.status}`);
      await sleepMs(delayMs);
    } catch (error) {
      lastError = error;
      if (attempt === attempts || !isRetryableFetchError(error)) {
        throw error;
      }

      const delayMs = retryDelayMs(attempt);
      logRetry(label, attempt, attempts, delayMs, error instanceof Error ? error.message : String(error));
      await sleepMs(delayMs);
    }
  }

  throw lastError || new Error(`Failed ${label}`);
}

function isRetryableApiStatus(status) {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

function isRetryableFetchError(_error) {
  return true;
}

function retryDelayMs(attempt) {
  const exponentialDelay = apiRetryBaseDelayMs * (2 ** Math.max(0, attempt - 1));
  const jitter = Math.floor(Math.random() * Math.min(250, Math.max(1, apiRetryBaseDelayMs / 2)));
  return Math.min(apiRetryMaxDelayMs, exponentialDelay + jitter);
}

function sleepMs(delayMs) {
  return new Promise((resolve) => setTimeout(resolve, delayMs));
}

function logRetry(label, attempt, attempts, delayMs, reason) {
  // eslint-disable-next-line no-console
  console.warn(
    `[web][api-retry] ${label} attempt=${attempt}/${attempts} retry_in_ms=${delayMs} reason=${reason}`
  );
}

function buildProxyHeaders(sourceHeaders) {
  const headers = new Headers();
  const allowedHeaders = ["accept", "content-type", "if-none-match", "if-modified-since"];

  for (const [key, value] of Object.entries(sourceHeaders)) {
    if (!allowedHeaders.includes(key.toLowerCase())) {
      continue;
    }
    if (Array.isArray(value)) {
      headers.set(key, value.join(", "));
    } else if (typeof value === "string") {
      headers.set(key, value);
    }
  }

  return headers;
}

function shouldSendBody(method) {
  return !["GET", "HEAD"].includes(String(method || "GET").toUpperCase());
}

function shouldRetryProxyRequest(method) {
  return ["GET", "HEAD"].includes(String(method || "GET").toUpperCase());
}

function numberSetting(name, fallback) {
  const value = Number(process.env[name]);
  return Number.isFinite(value) ? value : fallback;
}

function buildTvLogoIndex() {
  if (!fs.existsSync(tvLogosRoot)) {
    return new Map();
  }

  return new Map(
    fs.readdirSync(tvLogosRoot)
      .filter((entry) => entry.toLowerCase().endsWith(".png"))
      .map((entry) => [
        entry.toLowerCase().replace(/\.png$/, ""),
        path.join(tvLogosRoot, entry),
      ])
  );
}

function loadTeamShortNameEntries() {
  try {
    if (!fs.existsSync(teamShortNamesConfigPath)) {
      return [];
    }

    const raw = fs.readFileSync(teamShortNamesConfigPath, "utf8");
    const parsed = JSON.parse(raw);
    const shortNames =
      parsed && typeof parsed === "object" && !Array.isArray(parsed) &&
      parsed.short_names && typeof parsed.short_names === "object" && !Array.isArray(parsed.short_names)
        ? parsed.short_names
        : {};

    return Object.entries(shortNames)
      .map(([name, shortName]) => ({
        name: String(name || "").trim(),
        shortName: String(shortName || "").trim(),
      }))
      .filter((entry) => entry.name && entry.shortName);
  } catch (_error) {
    return [];
  }
}

function resolveTvLogo(channelName) {
  const normalized = stripDiacritics(channelName).toLowerCase();
  if (normalized.includes("amazon") || normalized.includes("prime video") || normalized.includes("primevideo")) {
    return tvLogoIndex.get("amazon") || null;
  }
  if (normalized.includes("apple")) return tvLogoIndex.get("apple") || null;
  if (normalized.includes("bbc")) return tvLogoIndex.get("bbc") || null;
  if (normalized.includes("channel 4") || normalized.includes("channel4")) {
    return tvLogoIndex.get("channel 4") || null;
  }
  if (normalized.includes("dazn")) return tvLogoIndex.get("dazn") || null;
  if (normalized.includes("disney")) return tvLogoIndex.get("disney+") || null;
  if (normalized.includes("hbo")) return tvLogoIndex.get("hbo max") || null;
  if (normalized.includes("itv")) return tvLogoIndex.get("itv") || null;
  if (normalized.includes("laliga")) return tvLogoIndex.get("laliga tv") || null;
  if (normalized.includes("now tv") || normalized.includes("nowtv")) return tvLogoIndex.get("now") || null;
  if (normalized.includes("premier sports") || normalized.includes("premiersports")) {
    return tvLogoIndex.get("premier sports") || null;
  }
  if (normalized.includes("sky")) return tvLogoIndex.get("sky-expanded-dark") || tvLogoIndex.get("sky") || null;
  if (normalized.includes("tnt")) return tvLogoIndex.get("tnt-expanded-dark") || tvLogoIndex.get("tnt") || null;
  return null;
}

function stripDiacritics(value) {
  return value.normalize("NFKD").replace(/[\u0300-\u036f]/g, "");
}

function sendTeamPlaceholder(res, teamName) {
  const initials = String(teamName || "")
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((token) => stripDiacritics(token).charAt(0).toUpperCase())
    .join("") || "?";

  const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">
  <rect width="96" height="96" rx="20" fill="#163055"/>
  <rect x="2" y="2" width="92" height="92" rx="18" fill="none" stroke="#2a4f86"/>
  <text x="48" y="57" text-anchor="middle" font-family="system-ui, -apple-system, BlinkMacSystemFont, sans-serif" font-size="30" font-weight="700" fill="#78aaff">${escapeXml(initials)}</text>
</svg>`;

  res.setHeader("Content-Type", "image/svg+xml; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.status(200).send(svg);
}

function escapeXml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}
