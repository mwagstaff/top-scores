"use strict";

const { schemas: models, ref, object, idSchema } = require("./reference_model");

const integer = { type: "integer", minimum: 0 };
const nullableTime = { type: ["string", "null"], format: "date-time" };
const nullableString = { type: ["string", "null"] };
const ids = { type: "array", items: idSchema };
const schemas = {
  ...models,
  Meta: object({
    catalogue_version: { type: "string", description: "Send this as catalogue_version on subsequent list pages; 409 means restart pagination." },
    snapshot_id: { ...nullableString, description: "Immutable competition snapshot identifier; null for cross-competition responses." },
    updated_at: { ...nullableTime, description: "Publication time; for cross-competition responses, the oldest active publication time." },
    stale: { type: "boolean", description: "True when older than 48 hours or the serving cache cannot reload from MongoDB." },
  }),
  Pagination: object({ total: integer, limit: { type: "integer", minimum: 1, maximum: 200 }, offset: integer, next_offset: { type: ["integer", "null"], minimum: 0 } }),
  Coverage: object({
    competition_id: idSchema, status: { enum: ["available", "not_collected"] }, snapshot_id: nullableString,
    updated_at: nullableTime, stale: { type: "boolean" }, last_attempt_at: nullableTime,
    last_attempt_status: { enum: ["succeeded", "failed", null] }, team_count: integer, player_count: integer,
    empty_squad_team_ids: ids, placeholder_team_ids: ids, missing_colour_team_ids: ids, missing_rating_player_ids: ids,
  }),
  Export: object({
    competition: ref("Competition"), teams: { type: "array", items: object({ team: ref("Team"), squad: ref("Squad") }) },
    coverage: ref("Coverage"),
  }),
  Error: object({ error: object({ code: { type: "string" }, message: { type: "string" } }) }),
};

const query = (name, schema, description) => ({ name, in: "query", required: false, schema, description });
const pagination = [
  query("limit", { type: "integer", minimum: 1, maximum: 200, default: 200 }, "Page size, maximum 200."),
  query("offset", integer, "Zero-based offset, default 0. Results sort by string ID."),
  query("catalogue_version", { type: "string", maxLength: 64 }, "Use the value from your first page to detect a refresh during pagination. A mismatch returns 409."),
];
const search = query("search", { type: "string", maxLength: 100 }, "Case- and accent-insensitive name substring search; teams also match configured aliases.");
const season = query("season_id", idSchema, "Optional current season ID from competition details. Historical seasons are rejected; squads are always current.");
const pathId = (name) => ({ name, in: "path", required: true, schema: idSchema, description: "BSD ID returned by this API." });

const operations = [
  { path: "/competitions", operationId: "listCompetitions", summary: "List published covered competitions", model: "Competition", list: true, parameters: [...pagination] },
  { path: "/competitions/{id}", operationId: "getCompetition", summary: "Get a competition and current season", model: "Competition", parameters: [pathId("id")] },
  { path: "/competitions/{id}/teams", operationId: "listCompetitionTeams", summary: "List teams in the published current season", model: "Team", list: true, parameters: [pathId("id"), season, ...pagination] },
  { path: "/competitions/{id}/export", operationId: "exportCompetition", summary: "Import a consistent competition, teams, current squads and full player profiles", model: "Export", parameters: [pathId("id"), season] },
  { path: "/teams", operationId: "listTeams", summary: "Search teams across covered competitions", model: "Team", list: true, parameters: [search, ...pagination] },
  { path: "/teams/{id}", operationId: "getTeam", summary: "Get team identity and colours", model: "Team", parameters: [pathId("id")] },
  { path: "/teams/{id}/squad", operationId: "getTeamSquad", summary: "Get the current squad with full player profiles and squad shirt numbers", model: "Squad", parameters: [pathId("id")] },
  { path: "/players", operationId: "listPlayers", summary: "Search players or filter by current squad membership", model: "Player", list: true, parameters: [search, query("team_id", idSchema, "Current squad membership, including national squads. Profile jersey_number is the club number; use /teams/{id}/squad for squad numbers."), ...pagination] },
  { path: "/players/{id}", operationId: "getPlayer", summary: "Get a full player profile including BSD scouting rating (0–200)", model: "Player", parameters: [pathId("id")] },
  { path: "/coverage", operationId: "getCoverage", summary: "Inspect every configured competition, refresh status and missing data", model: "Coverage", array: true, parameters: [] },
];

for (const operation of operations) {
  operation.responseModel = `${operation.operationId}Response`;
  schemas[operation.responseModel] = object({
    data: operation.list || operation.array ? { type: "array", items: ref(operation.model) } : ref(operation.model),
    meta: ref("Meta"), pagination: operation.list ? ref("Pagination") : { type: "null" },
  });
}

function openApi(baseUrl, authenticated = false) {
  return {
    openapi: "3.1.0", info: {
      title: "Top Scores Reference API", version: "1.0.0",
      description: "Read-only football reference data for games. Current squads, BSD profile ratings (0–200) and Top Scores team colours. Data refreshes daily; reads never fetch BSD. Use /coverage to inspect gaps and /competitions/{id}/export for consistent imports. Public by default. See docs/quickstart.md for workflows and data semantics.",
    },
    servers: [{ url: baseUrl }], security: authenticated ? [{ projectKey: [] }] : [],
    components: { schemas, securitySchemes: { projectKey: { type: "http", scheme: "bearer", description: "Only required when the operator enables project API keys. Never send the upstream BSD key." } } },
    paths: Object.fromEntries(operations.map((operation) => [operation.path, { get: {
      operationId: operation.operationId, summary: operation.summary, parameters: operation.parameters,
      responses: {
        "200": { description: "Stored data. Null fields represent unavailable values.", content: { "application/json": { schema: ref(operation.responseModel) } } },
        "304": { description: "Unchanged response for If-None-Match; no response body." },
        ...Object.fromEntries([400, 401, 404, 409, 429, 503].map((status) => [status, {
          description: ({ 400: "Invalid or unsupported parameter.", 401: "Authentication required or invalid key.", 404: "Unknown or uncovered resource.", 409: "Catalogue changed; restart pagination.", 429: "Rate limited. Observe Retry-After.", 503: "Not collected or temporarily unavailable. Observe Retry-After." })[status],
          headers: [429, 503].includes(status) ? { "Retry-After": { schema: { type: "integer" }, description: "Seconds before retrying." } } : {},
          content: { "application/json": { schema: ref("Error") } },
        }])),
      },
    } }])),
  };
}

function markdownReference(baseUrl) {
  const lines = ["# Top Scores Reference API", "", `Base URL: ${baseUrl}`, "", "See [Quickstart](quickstart.md) for imports, authentication, freshness and missing data.", "", "## Endpoints", ""];
  for (const operation of operations) {
    lines.push(`### GET ${operation.path}`, "", operation.summary, "", `Operation: ${operation.operationId}. Response schema: ${operation.responseModel}.`, "");
    for (const parameter of operation.parameters) lines.push(`- ${parameter.name} (${parameter.in}, ${parameter.schema.type}): ${parameter.description}`);
    lines.push("");
  }
  lines.push("## Schemas", "", "All listed object fields are returned. Null means unavailable unless a field says otherwise. IDs are BSD numeric IDs encoded as strings.", "");
  for (const [name, schema] of Object.entries(schemas)) {
    lines.push(`### ${name}`, "");
    for (const [key, value] of Object.entries(schema.properties)) {
      lines.push(`- ${key}: ${value.description || ""} Schema: ${JSON.stringify(value)}`);
    }
    lines.push("");
  }
  return lines.join("\n");
}

module.exports = { schemas, operations, openApi, markdownReference };
