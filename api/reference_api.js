"use strict";

const express = require("express");
const { createHash, timingSafeEqual } = require("crypto");
const fs = require("fs");
const path = require("path");
const { createReferenceService, apiError } = require("./reference_service");
const { operations, openApi, markdownReference } = require("./reference_contract");

function createReferenceApp({ service = createReferenceService(), keys = String(process.env.REFERENCE_API_KEYS || "").split(",").map((key) => key.trim()).filter(Boolean),
  rateLimit = Math.max(10, Number(process.env.REFERENCE_RATE_LIMIT_PER_MINUTE) || 120), now = Date.now,
  publicBaseUrl = process.env.REFERENCE_PUBLIC_BASE_URL || ".", trustProxy = process.env.REFERENCE_TRUST_PROXY || false } = {}) {
  const app = express();
  app.disable("x-powered-by");
  // Configure specific proxy addresses/subnets, never blindly trust X-Forwarded-For.
  app.set("trust proxy", trustProxy);
  const hashes = keys.map((key) => createHash("sha256").update(key).digest());
  const rateBuckets = new Map();
  let windowStart = now();
  app.use((req, res, next) => {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Authorization, If-None-Match");
    res.set("Access-Control-Expose-Headers", "ETag, Retry-After, X-Reference-Stale");
    res.set("X-Content-Type-Options", "nosniff");
    res.set("Cache-Control", "no-store");
    if (req.method === "OPTIONS") return res.sendStatus(204);
    if (!["GET", "HEAD"].includes(req.method)) return next(apiError(405, "method_not_allowed", "Reference API is read-only."));
    const time = now();
    if (time - windowStart >= 60_000) { rateBuckets.clear(); windowStart = time; }
    const key = req.ip || req.socket.remoteAddress || "unknown";
    const cost = /\/export\/?$/.test(req.path) ? 10 : 1;
    const used = rateBuckets.get(key) || 0;
    if (used + cost > rateLimit || (!rateBuckets.has(key) && rateBuckets.size >= 10_000)) {
      res.set("Retry-After", String(Math.max(1, Math.ceil((windowStart + 60_000 - time) / 1000))));
      return next(apiError(429, "rate_limited", "Too many reference requests. Observe Retry-After."));
    }
    rateBuckets.set(key, used + cost);
    next();
  });

  // Documentation stays readable even when data access is locked down later.
  app.get("/openapi.json", (_req, res) => res.json(openApi(publicBaseUrl, hashes.length > 0)));
  app.get("/docs", (req, res, next) => req.path.endsWith("/") ? next() : res.redirect(308, "docs/"));
  app.get("/docs/", (_req, res) => res.type("html").send(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Top Scores Reference API</title><link rel="stylesheet" href="assets/swagger-ui.css"></head>
<body><div id="swagger-ui"></div><script src="assets/swagger-ui-bundle.js"></script><script src="init.js"></script></body></html>`));
  app.get("/docs/init.js", (_req, res) => res.type("js").send('SwaggerUIBundle({url:"../openapi.json",dom_id:"#swagger-ui",deepLinking:true,validatorUrl:null,persistAuthorization:false});'));
  app.use("/docs/assets", express.static(require("swagger-ui-dist").getAbsoluteFSPath(), { index: false, maxAge: "1d" }));
  const quickstart = fs.readFileSync(path.join(__dirname, "REFERENCE_API_QUICKSTART.md"), "utf8");
  app.get("/docs/quickstart.md", (_req, res) => res.type("text/markdown").send(quickstart));
  app.get("/docs/reference.md", (_req, res) => res.type("text/markdown").send(markdownReference(publicBaseUrl)));
  app.get("/llms.txt", (_req, res) => res.type("text/plain").send(`# Top Scores Reference API

> Read-only competitions, teams, colours, current squads and BSD player profiles for games. Daily refresh. Ratings are 0–200 scouting ability, never percentages.

Links below are relative to this file. Start with the quickstart. Do not invent IDs or replace missing ratings with zero.

## Documentation
- [Quickstart and import workflow](docs/quickstart.md)
- [Endpoint and field reference](docs/reference.md)
- [OpenAPI contract](openapi.json)
- [Interactive API explorer](docs/)
`));

  app.use((req, res, next) => {
    if (!hashes.length) return next();
    const token = String(req.get("authorization") || "").match(/^Bearer (\S+)$/i)?.[1] || "";
    const hash = createHash("sha256").update(token).digest();
    if (!hashes.some((expected) => timingSafeEqual(hash, expected))) {
      res.set("WWW-Authenticate", 'Bearer realm="Top Scores Reference API"');
      return next(apiError(401, "unauthorized", "A valid project API key is required."));
    }
    next();
  });

  const normal = (value) => String(value || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
  function validate(req, operation) {
    const allowed = new Map(operation.parameters.filter((value) => value.in === "query").map((value) => [value.name, value]));
    for (const [key, value] of Object.entries(req.query)) {
      const definition = allowed.get(key);
      if (!definition || typeof value !== "string") throw apiError(400, "invalid_parameter", `Unsupported or repeated parameter: ${key}.`);
      const schema = definition.schema;
      if ((schema.pattern && !new RegExp(schema.pattern).test(value)) || (schema.maxLength && value.length > schema.maxLength) ||
          (schema.type === "integer" && (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value)) || Number(value) < schema.minimum || Number(value) > (schema.maximum ?? Number.MAX_SAFE_INTEGER)))) {
        throw apiError(400, "invalid_parameter", `Invalid ${key}. See openapi.json.`);
      }
    }
    if (req.params.id && !/^\d+$/.test(req.params.id)) throw apiError(400, "invalid_id", "IDs must be numeric BSD identifiers.");
  }

  for (const operation of operations) {
    app.get(operation.path.replace("{id}", ":id"), async (req, res, next) => {
      try {
        validate(req, operation);
        const catalogue = await service.catalogue();
        if (req.query.catalogue_version && req.query.catalogue_version !== catalogue.version) {
          throw apiError(409, "catalogue_changed", "Catalogue changed during pagination. Restart from offset 0.");
        }
        if (!catalogue.competitions.size && operation.operationId !== "getCoverage") {
          throw apiError(503, "not_collected", "No reference snapshots are available yet. See /coverage.");
        }
        let competition = null;
        let data;
        if (operation.path.startsWith("/competitions/{id}")) competition = service.competition(catalogue, req.params.id, req.query.season_id);
        const getTeam = (id) => {
          const result = catalogue.teams.get(id);
          if (!result) throw apiError(404, "not_found", "Team is not present in the published covered squads. See /coverage for collection gaps.");
          return result;
        };
        switch (operation.operationId) {
          case "listCompetitions": data = [...catalogue.competitions.values()].map((value) => value.competition); break;
          case "getCompetition": data = competition.competition; break;
          case "listCompetitionTeams": data = competition.records.map((value) => value.team); break;
          case "exportCompetition": data = { competition: competition.competition, teams: competition.records, coverage: service.coverage(catalogue).find((value) => value.competition_id === req.params.id) }; break;
          case "listTeams": data = [...catalogue.teams.values()].map((value) => value.team); break;
          case "getTeam": data = getTeam(req.params.id).team; break;
          case "getTeamSquad": data = getTeam(req.params.id).squad; break;
          case "listPlayers": data = req.query.team_id ? getTeam(req.query.team_id).squad.players.map((entry) => entry.player) : [...catalogue.players.values()]; break;
          case "getPlayer":
            data = catalogue.players.get(req.params.id);
            if (!data) throw apiError(404, "not_found", "Player is not present in the published covered squads. See /coverage for collection gaps.");
            break;
          case "getCoverage": data = service.coverage(catalogue); break;
        }
        let pagination = null;
        if (operation.list) {
          if (req.query.search) {
            const search = normal(req.query.search.trim());
            data = data.filter((entry) => [entry.name, entry.short_name, ...(entry.aliases || [])].some((name) => normal(name).includes(search)));
          }
          data.sort((a, b) => a.id.localeCompare(b.id));
          const limit = Number(req.query.limit || 200);
          const offset = Number(req.query.offset || 0);
          const total = data.length;
          data = data.slice(offset, offset + limit);
          pagination = { total, limit, offset, next_offset: offset + data.length < total ? offset + data.length : null };
        }
        const meta = service.metadata(catalogue, competition);
        const body = JSON.stringify({ data, meta, pagination });
        res.set("ETag", `"${createHash("sha256").update(body).digest("hex")}"`);
        res.set("Cache-Control", "private, max-age=0, must-revalidate");
        res.set("X-Reference-Stale", String(meta.stale));
        // Express's freshness handling honours If-None-Match after auth and rate limiting.
        res.type("json").send(body);
      } catch (error) { next(error); }
    });
  }
  app.use((_req, _res, next) => next(apiError(404, "not_found", "Unknown reference endpoint. See openapi.json.")));
  app.use((error, _req, res, _next) => {
    const status = error.status || 503;
    if (status === 503) res.set("Retry-After", "60");
    if (status === 405) res.set("Allow", "GET, HEAD, OPTIONS");
    if (!error.status) console.warn(`[reference] request failed: ${error.message}`);
    res.status(status).json({ error: { code: error.code || "data_unavailable", message: error.status ? error.message : "Reference data is temporarily unavailable." } });
  });
  return app;
}

function registerReferenceRoutes(app) { app.use("/api/v1/reference", createReferenceApp()); }
module.exports = { createReferenceApp, registerReferenceRoutes };
