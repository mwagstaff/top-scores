"use strict";

const { getTvListings } = require("./thesportsdb_client");

// ---------------------------------------------------------------------------
// Country display-name → ISO 3166-1 alpha-2 code
//
// TheSportsDB returns strCountry as a free-text display name. We map the
// most common values to ISO codes so clients can render flag emojis and
// localised country names. Unmapped entries get countryCode: null and still
// appear in the "Where to watch" grid (flag omitted).
// ---------------------------------------------------------------------------

const COUNTRY_CODE_MAP = {
  "united kingdom": "GB",
  "england": "GB",
  "united states": "US",
  "usa": "US",
  "canada": "CA",
  "australia": "AU",
  "ireland": "IE",
  "germany": "DE",
  "france": "FR",
  "spain": "ES",
  "italy": "IT",
  "netherlands": "NL",
  "portugal": "PT",
  "brazil": "BR",
  "mexico": "MX",
  "argentina": "AR",
  "south africa": "ZA",
  "nigeria": "NG",
  "ghana": "GH",
  "kenya": "KE",
  "india": "IN",
  "japan": "JP",
  "south korea": "KR",
  "china": "CN",
  "turkey": "TR",
  "poland": "PL",
  "sweden": "SE",
  "norway": "NO",
  "denmark": "DK",
  "finland": "FI",
  "belgium": "BE",
  "switzerland": "CH",
  "austria": "AT",
  "russia": "RU",
  "ukraine": "UA",
  "czech republic": "CZ",
  "hungary": "HU",
  "romania": "RO",
  "greece": "GR",
  "worldwide": null,
  "international": null,
};

function resolveCountryCode(strCountry) {
  if (!strCountry) return null;
  return COUNTRY_CODE_MAP[strCountry.toLowerCase()] ?? null;
}

function resolveChannelCountryCode(strCountry, strChannel) {
  const explicitCode = resolveCountryCode(strCountry);
  if (explicitCode) return explicitCode;

  const channel = String(strChannel || "").toLowerCase();
  if (channel.includes("bbc")) return "GB";
  if (channel.includes("itv")) return "GB";

  return explicitCode;
}

// ---------------------------------------------------------------------------
// Parse the API response into a map keyed by idEvent.
//
// Returns Map<idEvent:string, TvChannel[]> where TvChannel is:
//   { name: string, country: string, countryCode: string|null, logo: string|null }
// ---------------------------------------------------------------------------

function parseTvListingsResponse(data) {
  const entries = Array.isArray(data && data.filter) ? data.filter : [];
  const byEvent = new Map();

  entries.forEach((entry) => {
    const idEvent = String(entry.idEvent || "").trim();
    if (!idEvent || !/^\d+$/.test(idEvent)) return;

    const name = String(entry.strChannel || "").trim();
    if (!name) return;

    const country = String(entry.strCountry || "").trim() || null;
    const countryCode = resolveChannelCountryCode(country, name);
    const logo = String(entry.strLogo || "").trim() || null;

    if (!byEvent.has(idEvent)) byEvent.set(idEvent, []);
    const channels = byEvent.get(idEvent);

    // De-duplicate within the same event by name+country.
    const key = `${name}|${country || ""}`;
    if (!channels.some((c) => `${c.name}|${c.country || ""}` === key)) {
      channels.push({ name, country, countryCode, logo });
    }
  });

  return byEvent;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

async function fetchTsdbTvListings(options = {}) {
  const data = await getTvListings({
    initiator: options.initiator || "scraper",
    trigger: options.trigger,
  });
  return parseTvListingsResponse(data);
}

// Converts the Map to the array shape needed for MongoDB upserts:
//   [{ idEvent, dateEvent, channels }]
function tvListingsMapToUpsertArray(byEvent, rawEntries) {
  // Build a dateEvent lookup from the raw API entries.
  const dateByEvent = {};
  if (Array.isArray(rawEntries)) {
    rawEntries.forEach((e) => {
      const id = String(e.idEvent || "").trim();
      if (id && e.dateEvent) dateByEvent[id] = String(e.dateEvent);
    });
  }

  return Array.from(byEvent.entries()).map(([idEvent, channels]) => ({
    idEvent,
    dateEvent: dateByEvent[idEvent] || null,
    channels,
  }));
}

// Fetches TV listings and returns both the in-memory map and the upsert array.
async function fetchTsdbTvListingsFull(options = {}) {
  const reqOpts = {
    initiator: options.initiator || "scraper",
    trigger: options.trigger,
  };
  const data = await getTvListings(reqOpts);
  const byEvent = parseTvListingsResponse(data);
  const rawEntries = Array.isArray(data && data.filter) ? data.filter : [];
  const upsertArray = tvListingsMapToUpsertArray(byEvent, rawEntries);
  return { byEvent, upsertArray };
}

module.exports = {
  fetchTsdbTvListings,
  fetchTsdbTvListingsFull,
  parseTvListingsResponse,
  resolveCountryCode,
  resolveChannelCountryCode,
  COUNTRY_CODE_MAP,
};
