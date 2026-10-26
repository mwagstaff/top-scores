import test from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { readFileSync } from "node:fs";
import ts from "typescript";
import React, { act } from "react";
import { create } from "react-test-renderer";
import { MemoryRouter, Route, Routes, useLocation, useNavigate } from "react-router-dom";

registerHooks({
  resolve(specifier, context, next) {
    try { return next(specifier, context); }
    catch (error) {
      if (error.code !== "ERR_MODULE_NOT_FOUND" || !specifier.startsWith(".") || /\.[a-z]+$/i.test(specifier)) throw error;
      try { return next(`${specifier}.ts`, context); }
      catch { return next(`${specifier}.tsx`, context); }
    }
  },
  load(url, context, next) {
    if (!url.endsWith(".tsx")) return next(url, context);
    return {
      format: "module",
      shortCircuit: true,
      source: ts.transpileModule(readFileSync(new URL(url), "utf8"), {
        compilerOptions: { jsx: ts.JsxEmit.ReactJSX, module: ts.ModuleKind.ESNext },
      }).outputText,
    };
  },
});

globalThis.IS_REACT_ACT_ENVIRONMENT = true;
globalThis.document = {
  visibilityState: "visible",
  documentElement: { dataset: {} },
  querySelector: () => ({ setAttribute() {}, content: "", rel: "", href: "" }),
  addEventListener() {}, removeEventListener() {},
};
globalThis.window = {
  location: { origin: "https://example.test" },
  setTimeout, clearTimeout, setInterval, clearInterval,
  addEventListener() {}, removeEventListener() {},
};
globalThis.sessionStorage = { getItem: () => null, setItem() {} };
const stored = new Map();
globalThis.localStorage = {
  getItem: key => stored.get(key) ?? null,
  setItem: (key, value) => stored.set(key, value),
};
const { MatchesScreen } = await import("../src/client/components/MatchesScreen.tsx");

test("match view choices survive dates, routes, and a new visit while URLs can override them", async t => {
  t.mock.timers.enable({ apis: ["Date"], now: new Date("2026-10-25T12:00:00Z") });
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async url => {
    const date = new URL(String(url), "https://example.test").searchParams.get("start") || "2026-10-25";
    return new Response(JSON.stringify([{
      match_details_id: `match-${date}`,
      date, time: "20:00", league: "Premier League", score_status: "NS",
      home_team: "Home FC", away_team: "Away FC",
      tv_channels: [{ name: "BBC One", country_code: "GB" }],
    }]));
  };
  let navigate, location, renderer;
  function Harness() {
    navigate = useNavigate();
    location = useLocation();
    return React.createElement(Routes, null,
      React.createElement(Route, { path: "/", element: React.createElement(MatchesScreen) }),
      React.createElement(Route, { path: "/tables", element: React.createElement("div", null, "Tables") }));
  }
  const toggle = () => renderer.root.findAllByType("input").find(node => node.props.type === "checkbox");
  const scopeButton = name => renderer.root.findAllByType("button").find(node => node.props["aria-pressed"] !== undefined && node.findAllByType("span").some(span => span.children.includes(name)));
  try {
    await act(async () => {
      renderer = create(React.createElement(MemoryRouter, { initialEntries: ["/?date=2026-10-25"] }, React.createElement(Harness)));
    });
    assert.equal(toggle()?.props.checked, false);
    assert.match(location.search, /details=0/);

    await act(async () => { toggle().props.onChange({ target: { checked: true } }); });
    assert.equal(toggle()?.props.checked, true);
    assert.match(location.search, /details=1/);
    await act(async () => { scopeButton("Top teams").props.onClick(); });
    assert.equal(scopeButton("Top teams").props["aria-pressed"], true);
    assert.match(location.search, /scope=top/);
    assert.deepEqual(JSON.parse(stored.get("top-scores.match-view.v1")), { scope: "top", showDetails: true, showStats: true });

    await act(async () => { navigate("/?date=2026-10-26&scope=top&details=1"); });
    assert.equal(toggle(), undefined);
    assert.doesNotMatch(location.search, /details=/);

    await act(async () => { navigate("/?date=2026-10-24"); });
    assert.equal(toggle()?.props.checked, true);
    assert.equal(scopeButton("Top teams").props["aria-pressed"], true);
    assert.match(location.search, /details=1/);
    assert.match(location.search, /scope=top/);

    await act(async () => { navigate("/tables"); });
    assert.equal(toggle(), undefined);
    await act(async () => { navigate("/"); });
    assert.equal(toggle()?.props.checked, true);
    assert.equal(scopeButton("Top teams").props["aria-pressed"], true);

    await act(async () => { renderer.unmount(); });
    renderer = null;
    await act(async () => { renderer = create(React.createElement(MemoryRouter, { initialEntries: ["/"] }, React.createElement(Harness))); });
    assert.equal(toggle()?.props.checked, true);
    assert.equal(scopeButton("Top teams").props["aria-pressed"], true);

    await act(async () => { navigate("/?date=2026-10-25&scope=epl&details=0"); });
    assert.equal(toggle()?.props.checked, false);
    assert.equal(scopeButton("Premier League teams").props["aria-pressed"], true);
    assert.deepEqual(JSON.parse(stored.get("top-scores.match-view.v1")), { scope: "epl", showDetails: false, showStats: true });
  } finally {
    if (renderer) await act(async () => { renderer.unmount(); });
    globalThis.fetch = originalFetch;
  }
});
