"use strict";

const { loadTeamIdentityConfig, teamIdentityNames, normalizeTeamIdentityKey } = require("./team_identity");

const DAY_MS = 24 * 60 * 60 * 1000;
const string = (description) => ({ type: ["string", "null"], description });
const number = (description) => ({ type: ["number", "null"], description });
const idSchema = { type: "string", pattern: "^[0-9]+$", description: "BSD identifier, represented as a string. Never join by display name." };
const nullableId = { ...idSchema, type: ["string", "null"] };
const date = (description) => ({ ...string(description), format: "date" });
const timestamp = { type: "string", format: "date-time", description: "UTC time this record was fetched from BSD, not the time BSD changed it." };
const ref = (name) => ({ $ref: `#/components/schemas/${name}` });
const object = (properties) => ({ type: "object", properties, required: Object.keys(properties), additionalProperties: false });

const playerProperties = {
  id: idSchema,
  name: { type: "string", minLength: 1, description: "Player's full display name." },
  short_name: string("Abbreviated display name."),
  position: string("BSD general position code, usually G, D, M or F. Unknown/new codes are preserved."),
  specific_position: string("BSD specific position label or code."),
  jersey_number: number("Shirt number at the current club. Use the squad entry's jersey_number for that squad."),
  date_of_birth: date("Date of birth; no derived age that can become stale."),
  height_cm: number("Height in centimetres."),
  weight_kg: number("Weight in kilograms."),
  preferred_foot: string("BSD preferred foot, preserved as supplied (for example R, L, right, left or both)."),
  nationality: string("Nationality as supplied by BSD."),
  current_team_id: { ...nullableId, description: "Current club ID; may be outside the covered competitions." },
  national_team_id: { ...nullableId, description: "National team ID; may be outside the covered competitions." },
  current_team: { anyOf: [ref("TeamReference"), { type: "null" }], description: "Current club reference when BSD supplies it." },
  national_team: { anyOf: [ref("TeamReference"), { type: "null" }], description: "National team reference when BSD supplies it." },
  market_value_eur: number("Estimated market value in EUR; null is not zero."),
  contract_until: date("Contract expiry date."),
  availability: string("BSD status: usually available, injured, doubtful or suspended. Available means not listed as missing, not confirmed fit."),
  injury_type: string("Reason for absence when supplied."),
  injury_expected_return: date("Expected return date when supplied."),
  attributes: {
    anyOf: [object({
      ...Object.fromEntries(["attacking", "technical", "tactical", "defending", "creativity"].map((key) =>
        [key, { type: ["number", "null"], description: "Raw BSD scouting attribute. Live values can exceed the documented 0–20 scale; no rescaling or clamping is applied." }])),
      position: string("Position used by the scouting model."),
    }), { type: "null" }],
    description: "BSD scouting attributes; null when unavailable.",
  },
  strengths: { type: "array", items: { type: "string" }, description: "Scouting strength labels; empty when unpublished." },
  weaknesses: { type: "array", items: { type: "string" }, description: "Scouting weakness labels; empty when unpublished." },
  rating: { type: ["integer", "null"], minimum: 0, maximum: 200, description: "BSD overall FM scouting ability, 0–200, higher is better. Not a match rating or percentage. Null means unavailable; never substitute zero." },
  potential: string("BSD scouting potential label."),
  injury_risk: string("BSD scouting injury-risk label."),
  wage_eur_annual: number("Estimated annual gross wage in EUR."),
  image_url: { type: "string", format: "uri", description: "BSD player portrait; may return a missing-image placeholder." },
  updated_at: timestamp,
};

const schemas = {
  TeamReference: object({ id: idSchema, name: { type: "string" }, short_name: string("Abbreviated name.") }),
  Player: object(playerProperties),
  Colours: object({
    primary: { type: ["string", "null"], pattern: "^#[0-9A-F]{6}$" },
    secondary: { type: ["string", "null"], pattern: "^#[0-9A-F]{6}$" },
    source: { enum: ["top_scores", "bsd", "unavailable"] },
    is_fallback: { type: "boolean", description: "True when colours are unknown. Apply game display defaults locally." },
  }),
  Season: object({ id: idSchema, name: string("Season name."), year: number("Season start year as provided by BSD.") }),
  Competition: object({
    id: idSchema, name: { type: "string" }, country: string("Competition country or International."),
    is_women: { type: ["boolean", "null"] }, is_active: { type: ["boolean", "null"] },
    current_season: ref("Season"), updated_at: timestamp,
  }),
  Team: object({
    id: idSchema, name: { type: "string" }, short_name: string("Abbreviated name."),
    aliases: { type: "array", items: { type: "string" } }, country: string("Team country."),
    venue_id: nullableId, colours: ref("Colours"),
    is_placeholder: { type: "boolean", description: "Unresolved competition slot such as W101; not a real team." },
    image_url: { type: ["string", "null"], format: "uri" }, updated_at: timestamp,
  }),
  SquadEntry: object({ player_id: idSchema, jersey_number: number("Shirt number in this squad; independent of the player's club number."), player: ref("Player") }),
  Squad: object({
    team_id: idSchema, status: { enum: ["available", "empty", "placeholder"] },
    count: { type: "integer", minimum: 0 }, players: { type: "array", items: ref("SquadEntry") }, updated_at: timestamp,
  }),
};

function text(value) { return typeof value === "string" && value.trim() ? value.trim() : null; }
function numeric(value) {
  if (value == null || value === "") return null;
  const result = Number(value);
  return Number.isFinite(result) ? result : null;
}
function id(value) {
  const result = String(value ?? "");
  return /^\d+$/.test(result) ? result : null;
}
function identity(value, expectedId) {
  if (!value || !id(value.id) || !text(value.name) || (expectedId != null && id(value.id) !== String(expectedId))) {
    throw new Error("BSD returned an invalid or mismatched identity");
  }
}
function normalizePlayer(value, updatedAt) {
  identity(value);
  const result = {};
  for (const [key, definition] of Object.entries(playerProperties)) {
    if (key === "id") result[key] = id(value.id);
    else if (key.endsWith("_id")) result[key] = id(value[key] ?? value[key.replace(/_id$/, "")]?.id);
    else if (definition.type?.includes("number") || definition.type?.includes("integer")) result[key] = numeric(value[key]);
    else if (definition.type === "array") result[key] = Array.isArray(value[key]) ? value[key].filter((entry) => typeof entry === "string") : [];
    else result[key] = text(value[key]);
  }
  for (const key of ["current_team", "national_team"]) {
    const team = value[key];
    result[key] = team && id(team.id) && text(team.name)
      ? { id: id(team.id), name: team.name.trim(), short_name: text(team.short_name) } : null;
  }
  result.attributes = value.attributes && typeof value.attributes === "object"
    ? Object.fromEntries(["attacking", "technical", "tactical", "defending", "creativity", "position"].map((key) =>
      [key, key === "position" ? text(value.attributes[key]) : numeric(value.attributes[key])])) : null;
  if (result.rating != null && (!Number.isInteger(result.rating) || result.rating < 0 || result.rating > 200)) {
    throw new Error(`BSD player ${result.id} has an invalid profile rating`);
  }
  result.image_url = `https://sports.bzzoiro.com/img/player/${result.id}/`;
  result.updated_at = updatedAt;
  return result;
}

function createColourResolver(config = loadTeamIdentityConfig()) {
  const index = new Map();
  for (const team of config.teams || []) {
    for (const name of [team.name, ...(team.aliases || [])]) index.set(normalizeTeamIdentityKey(name), team);
  }
  const hex = (value) => /^#?[0-9a-f]{6}$/i.test(String(value || "")) ? `#${String(value).replace(/^#/, "").toUpperCase()}` : null;
  return (team) => {
    const configured = teamIdentityNames(team.name).map((name) => index.get(normalizeTeamIdentityKey(name))).find(Boolean);
    const primary = hex(configured?.primary);
    if (primary) return { primary, secondary: hex(configured.secondary), source: "top_scores", is_fallback: false };
    const bsdColours = team.colours || team.colors || {};
    const bsdPrimary = hex(bsdColours.primary);
    if (bsdPrimary) return { primary: bsdPrimary, secondary: hex(bsdColours.secondary), source: "bsd", is_fallback: false };
    return { primary: null, secondary: null, source: "unavailable", is_fallback: true };
  };
}

function normalizeTeam(value, updatedAt, resolveColours) {
  identity(value);
  const placeholder = /^(?:W|L)\d+$|^(?:TBD|TBC)$/i.test(value.name.trim());
  return {
    id: id(value.id), name: value.name.trim(), short_name: text(value.short_name),
    aliases: teamIdentityNames(value.name).filter((name) => name !== value.name), country: text(value.country),
    venue_id: id(value.venue_id), colours: resolveColours(value), is_placeholder: placeholder,
    image_url: placeholder ? null : `https://sports.bzzoiro.com/img/team/${id(value.id)}/`, updated_at: updatedAt,
  };
}

function normalizeCompetition(value, updatedAt) {
  identity(value);
  const season = value.current_season;
  if (!season || !id(season.id)) throw new Error(`BSD competition ${value.id} has no current season`);
  return {
    id: id(value.id), name: value.name.trim(), country: text(value.country),
    is_women: typeof value.is_women === "boolean" ? value.is_women : null,
    is_active: typeof value.is_active === "boolean" ? value.is_active : null,
    current_season: { id: id(season.id), name: text(season.name), year: numeric(season.year) }, updated_at: updatedAt,
  };
}

module.exports = { DAY_MS, schemas, ref, object, timestamp, idSchema, normalizePlayer, normalizeTeam, normalizeCompetition, createColourResolver, identity, id, numeric };
