import test from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { createRequire } from "node:module";
import React, { act } from "react";
import { create } from "react-test-renderer";
import { MemoryRouter, Route, Routes } from "react-router-dom";

test("match details retain fixture ratings and resolve ratings on direct visits", async () => {
  const compiled = await build({
    entryPoints: ["src/client/components/MatchPage.tsx"], bundle: true,
    platform: "node", format: "cjs", packages: "external", write: false,
    loader: { ".css": "empty" },
    plugins: [{ name: "omit-unrelated-panels", setup(builder) {
      builder.onLoad({ filter: /\/(MatchCard|StadiumBackdrop|PageMeta)\.tsx$/ }, args => {
        const name = args.path.split("/").pop().replace(".tsx", "");
        return { contents: `export function ${name}() { return null; }`, loader: "js" };
      });
    } }],
  });
  const original = { fetch: globalThis.fetch, document: globalThis.document, window: globalThis.window };
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.document = { visibilityState: "visible", getElementById: () => null, addEventListener() {}, removeEventListener() {} };
  globalThis.window = { setTimeout: () => 1, clearTimeout() {}, addEventListener() {}, removeEventListener() {} };
  const module = { exports: {} };
  new Function("require", "module", "exports", compiled.outputFiles[0].text)(createRequire(import.meta.url), module, module.exports);
  const MatchPage = module.exports.default;
  const rating = { score: 88, stars: 5, tier: "must_watch" };
  let renderer;
  try {
    for (const fromRow of [true, false]) {
      const id = fromRow ? "from-row" : "direct";
      const date = fromRow ? "2026-11-10" : "2026-11-11";
      const raw = { match_details_id: id, date, time: "20:00", league: "Premier League", home_team: "Home", away_team: "Away", score_status: "NS", tv_channels: [{ name: "BBC One", country_code: "GB" }] };
      const listPages = [];
      globalThis.fetch = async url => {
        const parsed = new URL(String(url), "http://localhost");
        if (parsed.pathname.endsWith(`/matches/${id}`)) return new Response(JSON.stringify(raw));
        const page = parsed.searchParams.get("page");
        listPages.push(page);
        return new Response(JSON.stringify([{ ...raw, match_details_id: page === "1" ? "another-match" : id, watchability_index: rating }]), { headers: { "X-Has-More": page === "1" ? "true" : "false" } });
      };
      const state = fromRow ? { match: { id, date, time: "20:00", league: "Premier League", homeTeam: "Home", awayTeam: "Away", tvChannels: [], watchabilityIndex: rating } } : undefined;
      await act(async () => {
        renderer = create(React.createElement(MemoryRouter, { initialEntries: [{ pathname: `/matches/${id}`, state }] },
          React.createElement(Routes, null, React.createElement(Route, { path: "/matches/:id", element: React.createElement(MatchPage) }))));
      });
      const ratings = renderer.root.findAll(node => node.props.className?.includes("watchability-rating-label"));
      assert.equal(ratings.length, 1);
      assert.match(ratings[0].props["aria-label"], /must watch, 88 out of 100, 5 out of 5 stars/);
      assert.deepEqual(listPages, fromRow ? [] : ["1", "2"]);
      await act(async () => renderer.unmount());
      renderer = null;
    }
  } finally {
    if (renderer) await act(async () => renderer.unmount());
    Object.assign(globalThis, original);
  }
});
