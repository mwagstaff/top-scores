import test from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { createRequire } from "node:module";
import React, { act } from "react";
import { create } from "react-test-renderer";
import { MemoryRouter, Route, Routes } from "react-router-dom";



test("the full match page renders one analysis panel after loading and refreshing", async t => {
  const errors = [];
  t.mock.method(console, "error", (...args) => errors.push(args.map(String).join(" ")));
  const compiled = await build({
    entryPoints: ["src/client/components/MatchPage.tsx"], bundle: true,
    platform: "node", format: "cjs", packages: "external", write: false,
    loader: { ".css": "empty" },
    plugins: [{ name: "omit-background-and-metadata", setup(builder) {
      builder.onLoad({ filter: /\/teamColors\.ts$/ }, () => ({ contents: `export const normalizedTeamKey = name => name.toLowerCase(); export const teamIdentityNames = name => [name]; export const useTeamColorCatalog = () => ({lineupColors: () => ({background:"#ff0000",foreground:"#ffffff"})});`, loader: "js" }));
      builder.onLoad({ filter: /\/(StadiumBackdrop|PageMeta)\.tsx$/ }, args => {
        const name = args.path.split("/").pop().replace(".tsx", "");
        return { contents: `export function ${name}() { return null; }`, loader: "js" };
      });
    } }],
  });
  const original = { fetch: globalThis.fetch, document: globalThis.document, window: globalThis.window };
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  let refresh;
  globalThis.document = { visibilityState: "visible", getElementById: () => null, addEventListener() {}, removeEventListener() {} };
  globalThis.window = { setTimeout: callback => { refresh = callback; return 1; }, clearTimeout() {}, addEventListener() {}, removeEventListener() {} };
  const module = { exports: {} };
  new Function("require", "module", "exports", compiled.outputFiles[0].text)(createRequire(import.meta.url), module, module.exports);
  const MatchPage = module.exports.default;
  const raw = { match_details_id: "212706", date: "2026-11-14", time: "19:45", league: "UEFA Nations League",
    home_team: "Portugal", away_team: "Denmark", home_score: 1, away_score: 4, score_status: "FT", tv_channels: [],
    momentum: { status: "available", segments: [{ id: "home", side: "home", points: [{minute: 1, value: 0}, {minute: 2, value: 10}] }], annotations: [], ticks: [], end_minute: 90, scale: 100 },
    match_stats: { status: "available", periods: [{ id: "all", label: "All", rows: [{id: "ball_possession", label: "Possession", group: "Key stats", headline: true, home: 52, away: 48, home_display: "52%", away_display: "48%"}] }] },
  };
  globalThis.fetch = async url => new Response(JSON.stringify(String(url).includes("/matches/212706?") ? raw : []));
  let renderer;
  try {
    await act(async () => {
      renderer = create(React.createElement(MemoryRouter, { initialEntries: ["/matches/212706?date=2026-11-14"] },
        React.createElement(Routes, null, React.createElement(Route, { path: "/matches/:id", element: React.createElement(MatchPage) }))));
    });
    const panels = () => renderer.root.findAllByProps({ "aria-label": "Match analysis" });
    const button = text => renderer.root.findAllByType("button").find(node => node.children.includes(text));
    assert.equal(panels().length, 1);
    assert.equal(renderer.root.findAllByProps({ "aria-label": "Match momentum" }).length, 1);
    for (let cycle = 0; cycle < 3; cycle++) {
      await act(async () => button("Commentary").props.onClick());
      assert.equal(panels().length, 1, "Commentary must retain exactly one analysis panel");
      await act(async () => button("Key events").props.onClick());
      assert.equal(panels().length, 1, "Returning to key events must not duplicate analysis");
    }
    assert.equal(errors.filter(message => message.includes("same key")).length, 0, "Sibling components must have unique keys");
    await act(async () => button("Match stats").props.onClick());
    assert.equal(panels().length, 1);
    assert.equal(renderer.root.findAllByProps({ className: "match-stat-row" }).length, 1);
    await act(async () => refresh());
    assert.equal(panels().length, 1);
    assert.equal(button("Match stats").props["aria-pressed"], true);
    await act(async () => button("Momentum").props.onClick());
    assert.equal(renderer.root.findAllByProps({ "aria-label": "Match momentum" }).length, 1);
  } finally {
    if (renderer) await act(async () => renderer.unmount());
    Object.assign(globalThis, original);
  }
});
