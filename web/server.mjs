import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import express from "express";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const productionClientRoot = path.join(__dirname, "dist");
const apiBaseUrl = (process.env.TOP_SCORES_API_BASE_URL ||
  process.env.API_BASE_URL ||
  "https://api.skynolimit.dev/top-scores/api/v1").replace(/\/+$/, "");
const port = Number(process.env.PORT || 3020);
const isProduction = process.env.NODE_ENV === "production";
const generatedAssetsRoot = isProduction
  ? path.join(productionClientRoot, "generated-assets")
  : path.join(__dirname, "public", "generated-assets");
const teamLogoManifestPath = path.join(generatedAssetsRoot, "team-logo-manifest.json");
const tvLogosRoot = path.join(generatedAssetsRoot, "tv-logos");
const teamShortNamesConfigPath = path.join(__dirname, "..", "api", "team_short_names.json");
const appIconPath = path.join(generatedAssetsRoot, "app-icon.png");
const faviconPath = path.join(generatedAssetsRoot, "favicon-32.png");
const appleTouchIconPath = path.join(generatedAssetsRoot, "apple-touch-icon.png");

const teamLogoIndex = buildTeamLogoIndex();
const tvLogoIndex = buildTvLogoIndex();
const teamShortNameEntries = loadTeamShortNameEntries();
const teamLogoAliases = new Map(
  Object.entries({
    "manchester united": "man united",
    "man utd": "man united",
    "manchester utd": "man united",
    "man u": "man united",
    "manchester city": "man city",
    "tottenham hotspur": "tottenham",
    "wolverhampton wanderers": "wolves",
    "sheffield united": "sheff utd",
    "sheffield wednesday": "sheff wed",
    "nottingham forest": "nottm forest",
    "borussia dortmund": "dortmund",
    "borussia m'gladbach": "m'gladbach",
    "athletic club": "athletic",
    "real betis": "betis",
    "fc copenhagen": "copenhagen",
    "fc porto": "porto",
    "paok thessaloniki": "paok",
    "paok thessaloniki fc": "paok",
    "inter milan": "inter",
    "ac milan": "ac milan",
    "bodo/glimt": "bodo-glimt",
    "bodoglimt": "bodo-glimt",
    "rakow": "rakow czestochowa",
    "sigma olomouc": "olomouc",
    "bosnia-herzegovina": "bosnia",
    "bosnia and herzegovina": "bosnia",
  })
);

const app = express();
app.disable("x-powered-by");

app.get("/healthcheck", (_req, res) => {
  res.json({
    ok: true,
    apiBaseUrl,
    mode: isProduction ? "production" : "development",
  });
});

app.get("/brand/app-icon", (_req, res) => {
  if (!fs.existsSync(appIconPath)) {
    res.status(404).json({ error: "App icon not found" });
    return;
  }

  res.sendFile(appIconPath);
});

app.get("/favicon.ico", (_req, res) => {
  if (!fs.existsSync(faviconPath)) {
    res.status(404).end();
    return;
  }

  res.sendFile(faviconPath);
});

app.get("/apple-touch-icon.png", (_req, res) => {
  if (!fs.existsSync(appleTouchIconPath)) {
    res.status(404).end();
    return;
  }

  res.sendFile(appleTouchIconPath);
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
  const resolved = resolveTeamLogo(requestedName);
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
    try {
      const suffix = req.originalUrl.replace(/^\/api\/v1\/?/, "");
      const target = new URL(
        suffix,
        apiBaseUrl.endsWith("/") ? apiBaseUrl : `${apiBaseUrl}/`
      );

      const upstream = await fetch(target, {
        method: req.method,
        headers: buildProxyHeaders(req.headers),
        body: shouldSendBody(req.method) ? req.body : undefined,
      });

      res.status(upstream.status);
      upstream.headers.forEach((value, key) => {
        if (["content-encoding", "content-length", "connection"].includes(key.toLowerCase())) {
          return;
        }
        res.setHeader(key, value);
      });

      const buffer = Buffer.from(await upstream.arrayBuffer());
      res.send(buffer);
    } catch (error) {
      res.status(502).json({
        error: "Failed to reach the Top Scores API",
        details: error instanceof Error ? error.message : String(error),
      });
    }
  }
);

async function start() {
  if (isProduction) {
    app.use("/assets", express.static(path.join(productionClientRoot, "assets")));
    app.use(express.static(productionClientRoot));

    app.get("*", (_req, res) => {
      res.sendFile(path.join(productionClientRoot, "index.html"));
    });
  } else {
    const { createServer } = await import("vite");
    const vite = await createServer({
      root: __dirname,
      server: { middlewareMode: true },
      appType: "spa",
    });

    app.use(vite.middlewares);

    app.get("*", async (req, res, next) => {
      try {
        const templatePath = path.join(__dirname, "index.html");
        const template = await fs.promises.readFile(templatePath, "utf8");
        const transformed = await vite.transformIndexHtml(req.originalUrl, template);
        res.status(200).setHeader("Content-Type", "text/html").end(transformed);
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

function buildTeamLogoIndex() {
  if (!fs.existsSync(teamLogoManifestPath)) {
    return [];
  }

  const entries = JSON.parse(fs.readFileSync(teamLogoManifestPath, "utf8"));
  return entries
    .filter((entry) => typeof entry?.name === "string" && typeof entry?.relativePath === "string")
    .map((entry) => ({
      name: entry.name,
      normalized: normalizedKey(entry.name),
      core: normalizedCoreKey(entry.name),
      path: path.join(generatedAssetsRoot, entry.relativePath),
    }))
    .filter((entry) => fs.existsSync(entry.path));
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

function resolveTeamLogo(teamName) {
  const trimmed = decodeURIComponent(teamName || "").trim();
  if (!trimmed) {
    return null;
  }

  for (const candidate of logoCandidates(trimmed)) {
    const direct = teamLogoIndex.find(
      (entry) => entry.name.toLowerCase() === candidate.toLowerCase()
    );
    if (direct) {
      return direct.path;
    }

    const normalized = normalizedKey(candidate);
    const normalizedMatch = teamLogoIndex.find((entry) => entry.normalized === normalized);
    if (normalizedMatch) {
      return normalizedMatch.path;
    }

    const core = normalizedCoreKey(candidate);
    const coreMatches = teamLogoIndex.filter((entry) => entry.core === core);
    if (coreMatches.length === 1) {
      return coreMatches[0].path;
    }
  }

  const normalizedQuery = normalizedKey(trimmed);
  let bestMatch = null;
  let bestScore = 0;
  for (const entry of teamLogoIndex) {
    const score = similarity(normalizedQuery, entry.normalized);
    if (score > bestScore) {
      bestScore = score;
      bestMatch = entry;
    }
  }

  if (bestMatch && bestScore >= 0.82) {
    return bestMatch.path;
  }

  return null;
}

function resolveTvLogo(channelName) {
  const normalized = stripDiacritics(channelName).toLowerCase();
  if (normalized.includes("amazon")) return tvLogoIndex.get("amazon") || null;
  if (normalized.includes("apple")) return tvLogoIndex.get("apple") || null;
  if (normalized.includes("bbc")) return tvLogoIndex.get("bbc") || null;
  if (normalized.includes("channel 4") || normalized.includes("channel4")) {
    return tvLogoIndex.get("channel 4") || null;
  }
  if (normalized.includes("itv")) return tvLogoIndex.get("itv") || null;
  if (normalized.includes("sky")) return tvLogoIndex.get("sky") || null;
  if (normalized.includes("tnt")) return tvLogoIndex.get("tnt") || null;
  return null;
}

function normalizedCoreKey(value) {
  return normalizedTokens(value).join("");
}

function normalizedKey(value) {
  const tokens = normalizedTokens(value);
  if (tokens.length > 0) {
    return tokens.join("");
  }

  return stripDiacritics(String(value || ""))
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "");
}

function normalizedTokens(value) {
  const stopWords = new Set(["fc", "cf", "sc", "afc", "ac", "sv", "fk", "club", "the", "and"]);
  return stripDiacritics(String(value || ""))
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[.'’_-]/g, " ")
    .split(/[^a-z0-9]+/g)
    .map((token) => token.trim())
    .filter((token) => token && !stopWords.has(token));
}

function stripDiacritics(value) {
  return value.normalize("NFKD").replace(/[\u0300-\u036f]/g, "");
}

function logoCandidates(teamName) {
  const output = [];
  const seen = new Set();

  function add(candidate) {
    const trimmed = String(candidate || "").trim();
    if (!trimmed) return;
    const key = trimmed.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    output.push(trimmed);
  }

  const trimmed = String(teamName || "").trim();
  const lowered = trimmed.toLowerCase();
  add(trimmed);

  const alias = teamLogoAliases.get(lowered);
  if (alias) {
    add(alias);
  }

  for (const entry of teamShortNameEntries) {
    if (entry.name.toLowerCase() === lowered) {
      add(entry.shortName);
    }
    if (entry.shortName.toLowerCase() === lowered) {
      add(entry.name);
    }
  }

  return output;
}

function similarity(left, right) {
  const maxLength = Math.max(left.length, right.length);
  if (maxLength === 0) {
    return 1;
  }

  return 1 - levenshtein(left, right) / maxLength;
}

function levenshtein(left, right) {
  const leftChars = Array.from(left);
  const rightChars = Array.from(right);
  let previous = Array.from({ length: rightChars.length + 1 }, (_, index) => index);

  for (let row = 0; row < leftChars.length; row += 1) {
    const current = [row + 1];
    for (let column = 0; column < rightChars.length; column += 1) {
      const cost = leftChars[row] === rightChars[column] ? 0 : 1;
      current[column + 1] = Math.min(
        previous[column + 1] + 1,
        current[column] + 1,
        previous[column] + cost
      );
    }
    previous = current;
  }

  return previous[rightChars.length];
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
  res.setHeader("Cache-Control", "public, max-age=3600");
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
