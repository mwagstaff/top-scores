"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { parseTvListingsResponse, resolveChannelCountryCode, resolveCountryCode, COUNTRY_CODE_MAP } = require("./fetch_tsdb_tv");

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

function entry(overrides = {}) {
  return {
    idEvent: "2391728",
    strChannel: "ITV1",
    strCountry: "United Kingdom",
    strLogo: "https://example.com/itv1.png",
    dateEvent: "2026-06-11",
    strTime: "19:00:00",
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// resolveCountryCode
// ---------------------------------------------------------------------------

test("resolveCountryCode: United Kingdom → GB", () => {
  assert.equal(resolveCountryCode("United Kingdom"), "GB");
});

test("resolveCountryCode: case-insensitive", () => {
  assert.equal(resolveCountryCode("UNITED KINGDOM"), "GB");
  assert.equal(resolveCountryCode("united kingdom"), "GB");
});

test("resolveCountryCode: USA → US", () => {
  assert.equal(resolveCountryCode("United States"), "US");
});

test("resolveCountryCode: Worldwide → null", () => {
  assert.equal(resolveCountryCode("Worldwide"), null);
});

test("resolveCountryCode: unknown country → null", () => {
  assert.equal(resolveCountryCode("Narnia"), null);
});

test("resolveCountryCode: null/empty → null", () => {
  assert.equal(resolveCountryCode(null), null);
  assert.equal(resolveCountryCode(""), null);
});

test("resolveChannelCountryCode: BBC and ITV channels default to GB", () => {
  assert.equal(resolveChannelCountryCode(null, "BBC iPlayer"), "GB");
  assert.equal(resolveChannelCountryCode("Other", "BBC Sport Website"), "GB");
  assert.equal(resolveChannelCountryCode(null, "ITVX"), "GB");
  assert.equal(resolveChannelCountryCode("Other", "ITV TBC"), "GB");
});

test("resolveChannelCountryCode: explicit mapped country wins", () => {
  assert.equal(resolveChannelCountryCode("United States", "BBC America"), "US");
});

// ---------------------------------------------------------------------------
// parseTvListingsResponse
// ---------------------------------------------------------------------------

test("parseTvListingsResponse: groups channels by idEvent", () => {
  const data = {
    filter: [
      entry({ idEvent: "2391728", strChannel: "ITV1" }),
      entry({ idEvent: "2391728", strChannel: "STV" }),
      entry({ idEvent: "2454916", strChannel: "BBC One Wales" }),
    ],
  };
  const map = parseTvListingsResponse(data);
  assert.equal(map.size, 2);
  assert.equal(map.get("2391728").length, 2);
  assert.equal(map.get("2454916").length, 1);
});

test("parseTvListingsResponse: channel shape includes name, country, countryCode, logo", () => {
  const data = { filter: [entry()] };
  const map = parseTvListingsResponse(data);
  const [ch] = map.get("2391728");
  assert.equal(ch.name, "ITV1");
  assert.equal(ch.country, "United Kingdom");
  assert.equal(ch.countryCode, "GB");
  assert.equal(ch.logo, "https://example.com/itv1.png");
});

test("parseTvListingsResponse: null logo becomes null", () => {
  const data = { filter: [entry({ strLogo: "" })] };
  const [ch] = parseTvListingsResponse(data).get("2391728");
  assert.equal(ch.logo, null);
});

test("parseTvListingsResponse: deduplicates identical name+country within same event", () => {
  const data = {
    filter: [
      entry({ strChannel: "ITV1", strCountry: "United Kingdom" }),
      entry({ strChannel: "ITV1", strCountry: "United Kingdom" }),
    ],
  };
  const channels = parseTvListingsResponse(data).get("2391728");
  assert.equal(channels.length, 1);
});

test("parseTvListingsResponse: same channel name in different countries → two entries", () => {
  const data = {
    filter: [
      entry({ strChannel: "SuperSport", strCountry: "South Africa" }),
      entry({ strChannel: "SuperSport", strCountry: "Nigeria" }),
    ],
  };
  const channels = parseTvListingsResponse(data).get("2391728");
  assert.equal(channels.length, 2);
});

test("parseTvListingsResponse: skips entries with non-numeric idEvent", () => {
  const data = { filter: [entry({ idEvent: "syn0abc123" })] };
  const map = parseTvListingsResponse(data);
  assert.equal(map.size, 0);
});

test("parseTvListingsResponse: skips entries with missing idEvent", () => {
  const data = { filter: [entry({ idEvent: "" })] };
  assert.equal(parseTvListingsResponse(data).size, 0);
});

test("parseTvListingsResponse: skips entries with empty channel name", () => {
  const data = { filter: [entry({ strChannel: "" })] };
  assert.equal(parseTvListingsResponse(data).size, 0);
});

test("parseTvListingsResponse: handles null/missing filter gracefully", () => {
  assert.equal(parseTvListingsResponse({}).size, 0);
  assert.equal(parseTvListingsResponse(null).size, 0);
  assert.equal(parseTvListingsResponse({ filter: null }).size, 0);
});

test("parseTvListingsResponse: maps multiple countries correctly", () => {
  const data = {
    filter: [
      entry({ idEvent: "1000", strChannel: "OneSoccer", strCountry: "Canada", strLogo: null }),
      entry({ idEvent: "1000", strChannel: "ESPN", strCountry: "United States", strLogo: "https://x.com/espn.png" }),
    ],
  };
  const channels = parseTvListingsResponse(data).get("1000");
  assert.equal(channels.length, 2);
  assert.equal(channels[0].countryCode, "CA");
  assert.equal(channels[1].countryCode, "US");
});

test("parseTvListingsResponse: worldwide country gets null countryCode", () => {
  const data = { filter: [entry({ strChannel: "World Feed", strCountry: "Worldwide" })] };
  const [ch] = parseTvListingsResponse(data).get("2391728");
  assert.equal(ch.country, "Worldwide");
  assert.equal(ch.countryCode, null);
});

test("parseTvListingsResponse: UK broadcaster channels with unmapped country get GB countryCode", () => {
  const data = {
    filter: [
      entry({ strChannel: "BBC TBC", strCountry: "Other" }),
      entry({ strChannel: "BBC iPlayer", strCountry: "" }),
      entry({ strChannel: "BBC Sport Website", strCountry: "Worldwide" }),
      entry({ strChannel: "ITV TBC", strCountry: "Other" }),
      entry({ strChannel: "ITVX", strCountry: "" }),
    ],
  };
  const channels = parseTvListingsResponse(data).get("2391728");
  assert.deepEqual(channels.map((ch) => ch.countryCode), ["GB", "GB", "GB", "GB", "GB"]);
});

test("COUNTRY_CODE_MAP has no empty-string values", () => {
  for (const [key, val] of Object.entries(COUNTRY_CODE_MAP)) {
    if (val !== null) {
      assert.match(val, /^[A-Z]{2}$/, `${key} should be a 2-letter ISO code or null`);
    }
  }
});
