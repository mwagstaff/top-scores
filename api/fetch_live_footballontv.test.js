"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  parseListingsHtml,
  fetchLiveFootballTvListings,
  __private,
} = require("./fetch_live_footballontv");

const SAMPLE_HTML = `
  <main>
    <div class="fixture-date">Sunday 30th August 2026</div>
    <div class="fixture">
      <div class="fixture__time">16:30</div>
      <div class="fixture__teams">Manchester United v Ipswich Town</div>
      <div class="fixture__competition">Premier League</div>
      <div class="fixture__channel">
        <span class="channel-pill">Sky Sports Main Event</span>
        <span class="channel-pill">Sky Sports Premier League</span>
        <span class="channel-pill">sky sports main event</span>
      </div>
    </div>
    <div class="fixture-date">Monday 31st August 2026</div>
    <div class="fixture">
      <div class="fixture__time">20:00</div>
      <div class="fixture__teams">Aston Villa v Arsenal</div>
      <div class="fixture__competition">Premier League &amp; Cup</div>
      <div class="fixture__channel"><span class="channel-pill">Sky Sports+</span></div>
    </div>
  </main>`;

test("parseListingsHtml extracts structural fixture fields and structured GB channels", () => {
  const listings = parseListingsHtml(SAMPLE_HTML);
  assert.equal(listings.length, 2);
  assert.deepEqual(listings[0], {
    date_local: "2026-08-30",
    time_local: "16:30",
    time_zone: "Europe/London",
    home_team: "Manchester United",
    away_team: "Ipswich Town",
    competition: "Premier League",
    channels: [
      { name: "Sky Sports Main Event", country: "United Kingdom", countryCode: "GB", logo: null },
      { name: "Sky Sports Premier League", country: "United Kingdom", countryCode: "GB", logo: null },
    ],
  });
  assert.equal(listings[1].date_local, "2026-08-31");
  assert.equal(listings[1].competition, "Premier League & Cup");
  assert.equal(listings[1].channels[0].name, "Sky Sports+");
});

test("parseListingsHtml drops malformed fixtures and fixtures without channels", () => {
  const listings = parseListingsHtml(`
    <div class="fixture-date">Sunday 30th August 2026</div>
    <div class="fixture"><div class="fixture__time">99:00</div></div>
    <div class="fixture">
      <div class="fixture__time">16:00</div>
      <div class="fixture__teams">Arsenal v Chelsea</div>
      <div class="fixture__competition">Premier League</div>
    </div>`);
  assert.deepEqual(listings, []);
});

test("fetchLiveFootballTvListings accepts an injected request and returns fetch metadata", async () => {
  const result = await fetchLiveFootballTvListings({
    url: "https://example.test/fixtures",
    attempts: 1,
    requestHtml: async () => ({ html: SAMPLE_HTML, bytes: 1234 }),
  });
  assert.equal(result.url, "https://example.test/fixtures");
  assert.equal(result.html_bytes, 1234);
  assert.equal(result.listings.length, 2);
  assert.ok(Number.isFinite(Date.parse(result.fetched_at)));
});

test("date, time, and team parsing reject invalid source values", () => {
  assert.equal(__private.parseListingDate("Sunday 31st February 2026"), null);
  assert.equal(__private.normalizeListingTime("24:00"), null);
  assert.equal(__private.splitTeams("Arsenal"), null);
});
