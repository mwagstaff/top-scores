import test from "node:test";
import assert from "node:assert/strict";
import { createPageRenderer } from "../page-document.mjs";
const template =
  '<html><head><title>Top Scores</title><meta name="description" content="old"></head><body><div id="root"></div></body></html>';
const fixture = {
  match_details_id: "42",
  date: "2026-10-21",
  time: "20:00",
  home_team: "A & B <script>alert(1)</script>",
  away_team: "Visitors",
  league: "Premier League",
  tv_channels: [{ name: "BBC One", countryCode: "GB" }],
};
test("public HTML includes crawlable matches, escaped metadata and safe client seed", async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return new Response(JSON.stringify([fixture]), {
      headers: { "X-Has-More": "false" },
    });
  };
  try {
    const render = createPageRenderer("https://example.test/api");
    const result = await render(
      template,
      "/fixtures?date=2026-10-21",
      "https://football.test",
    );
    assert.equal(result.status, 200);
    assert.match(result.html, /href="\/matches\/42\?date=2026-10-21"/);
    assert.match(result.html, /A &amp; B &lt;script&gt;/);
    assert.doesNotMatch(result.html, /<script>alert/);
    assert.match(result.html, /\\u003cscript>/);
    assert.match(
      result.html,
      /rel="canonical" href="https:\/\/football.test\/\?date=2026-10-21"/,
    );
    await render(
      template,
      "/fixtures?date=2026-10-21",
      "https://football.test",
    );
    assert.equal(calls, 1);
  } finally {
    globalThis.fetch = original;
  }
});
test("match permalinks return server titles and real not-found responses", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async (url) =>
    url.includes("missing")
      ? new Response("{}", { status: 404 })
      : new Response(JSON.stringify({ ...fixture, id: "42" }));
  try {
    const render = createPageRenderer("https://example.test/api");
    const found = await render(
      template,
      "/matches/42",
      "https://football.test",
    );
    assert.match(found.html, /og:title/);
    assert.match(found.html, /Where to watch in the UK/);
    const missing = await render(
      template,
      "/matches/missing",
      "https://football.test",
    );
    assert.equal(missing.status, 404);
    assert.match(missing.html, /noindex/);
  } finally {
    globalThis.fetch = original;
  }
});
test("retired preferences URL returns a not-found response", async () => {
  const result = await createPageRenderer("https://example.test/api")(
    template,
    "/preferences",
    "https://football.test",
  );
  assert.equal(result.status, 404);
  assert.match(result.html, /Page not found/);
  assert.match(result.html, /noindex/);
  assert.match(result.html, /href="https:\/\/skynolimit\.dev\/">Developed by Sky No Limit<\/a>/);
});
test("upstream failure still returns a usable page without fabricated fixtures", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => {
    throw new Error("offline");
  };
  try {
    const result = await createPageRenderer("https://example.test/api")(
      template,
      "/fixtures",
      "https://football.test",
    );
    assert.match(result.html, /temporarily unavailable/);
    assert.doesNotMatch(result.html, /class="server-fixture"/);
  } finally {
    globalThis.fetch = original;
  }
});

test("server rendering receives request-scoped data matching the hydration seed", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify([fixture]));
  try {
    const seeds = [];
    const render = createPageRenderer(
      "https://example.test/api",
      (url, seed) => {
        seeds.push(seed);
        assert.equal(seed.rendered, true);
        assert.equal(seed.matches[0].home_team, fixture.home_team);
        return '<main class="football-app">Rendered fixtures</main>';
      },
    );
    const a = await render(
      template,
      "/fixtures?date=2026-10-21",
      "https://football.test",
    );
    await render(
      template,
      "/fixtures?date=2026-10-22",
      "https://football.test",
    );
    assert.match(a.html, /football-app/);
    assert.doesNotMatch(a.html, /server-page/);
    assert.notEqual(seeds[0], seeds[1]);
    assert.equal(seeds[0].date, "2026-10-21");
    assert.equal(seeds[1].date, "2026-10-22");
  } finally {
    globalThis.fetch = original;
  }
});


test("shared presentation order applies to cached SSR data and its hydration seed", async () => {
  const { default: shared } = await import("../server-shared/broadcast_priorities.cjs");
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return new Response(JSON.stringify([{ ...fixture, tv_channels: [{name:"HBO Max",countryCode:"GB"},{name:"TNT Sports 2",countryCode:"GB"}] }]));
  };
  try {
    const seeds = [];
    const render = createPageRenderer("https://example.test/api", (_url, seed) => {
      seeds.push(seed);
      return "<main>Matches</main>";
    }, shared.broadcastPriorities.apply);
    for (let i = 0; i < 2; i++) {
      const result = await render(template, "/fixtures?date=2026-10-21", "https://football.test");
      assert.equal(seeds[i].matches[0].tv_channels[0].name,"TNT Sports 2");
      const encoded = JSON.parse(result.html.match(/id="football-seed" type="application\/json">(.*?)<\/script>/s)[1]);
      assert.equal(encoded.matches[0].tv_channels[0].name,"TNT Sports 2");
    }
    assert.equal(calls,1);
  } finally { globalThis.fetch = original; }
});
