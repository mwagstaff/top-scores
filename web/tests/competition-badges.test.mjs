import test from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { readFileSync } from "node:fs";
import ts from "typescript";
import React, { act } from "react";
import { create } from "react-test-renderer";
import { MemoryRouter, useNavigate } from "react-router-dom";

// Run the actual component, including its effects, without a browser server.
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
  getElementById: () => null,
  addEventListener() {},
  removeEventListener() {},
};
globalThis.window = { setInterval, clearInterval, scrollTo() {}, scrollY: 0 };
globalThis.sessionStorage = { getItem: () => null, setItem() {} };
const { AppShell } = await import("../src/client/components/AppShell.tsx");
const { ukDate } = await import("../src/client/football.ts");

test("competition badges follow date navigation, include every page, and ignore stale responses", async t => {
  t.mock.timers.enable({ apis: ["Date"], now: new Date("2026-10-23T12:00:00Z") });
  const originalFetch = globalThis.fetch;
  const requests = [];
  let resolveSelected, resolveStale;
  const selectedResponse = new Promise(resolve => { resolveSelected = resolve; });
  const staleResponse = new Promise(resolve => { resolveStale = resolve; });
  const matches = (date, count, offset = 0, league = "Premier League", hasMore = false) =>
    new Response(JSON.stringify(Array.from({ length: count }, (_, i) => ({
      match_details_id: `${date}-${offset + i}`,
      date, time: "14:00", league, home_team: `Home ${i}`, away_team: `Away ${i}`, tv_channels: [],
    }))), { headers: { "X-Has-More": String(hasMore) } });
  globalThis.fetch = async url => {
    if (String(url).includes("/competitions/catalog"))
      return new Response(JSON.stringify({ competitions: [
        { id: "1", name: "Premier League", aliases: ["EPL"], weight: 1 },
      ] }));
    const params = new URL(String(url), "https://example.test").searchParams;
    const date = params.get("start");
    requests.push({ date, page: params.get("page") });
    if (date === "2026-10-25")
      return params.get("page") === "1" ? selectedResponse : matches(date, 2, 3, "EPL");
    if (date === "2026-10-26") return staleResponse;
    return matches(date, date === ukDate() ? 1 : date === "2026-10-27" ? 2 : 0);
  };
  let navigate, renderer;
  function Harness() {
    navigate = useNavigate();
    return React.createElement(AppShell);
  }
  const badges = () => renderer.root.findAllByProps({ className: "competition-count" });
  const count = () => badges()[0]?.children.join("");
  try {
    await act(async () => {
      renderer = create(React.createElement(MemoryRouter, null, React.createElement(Harness)));
    });
    assert.equal(count(), "1");
    assert.equal(badges()[0].props["aria-label"], "1 match today");

    await act(async () => { navigate("/?date=2026-10-25"); });
    assert.equal(badges().length, 0, "the previous date's count must not remain visible");
    await act(async () => { resolveSelected(matches("2026-10-25", 3, 0, "Premier League", true)); });
    assert.equal(count(), "5");
    assert.equal(badges()[0].props["aria-label"], "5 matches on Sunday 25 October");
    assert.equal(badges()[0].props.title, "5 matches on Sunday 25 October");
    assert.deepEqual(requests.filter(item => item.date === "2026-10-25").map(item => item.page), ["1", "2"]);

    await act(async () => { navigate("/?date=2026-10-26"); });
    assert.equal(badges().length, 0);
    await act(async () => { navigate("/?date=2026-10-27"); });
    assert.equal(count(), "2");
    await act(async () => { resolveStale(matches("2026-10-26", 9)); });
    assert.equal(count(), "2", "a late response must not overwrite the selected date");

    await act(async () => { navigate("/?date=2026-10-28"); });
    assert.equal(badges().length, 0, "competitions with no matches have no badge");
    await act(async () => { navigate("/?date=invalid"); });
    assert.equal(count(), "1", "invalid dates fall back to today");
    await act(async () => { navigate("/"); });
    assert.equal(count(), "1");
  } finally {
    if (renderer) await act(async () => { renderer.unmount(); });
    globalThis.fetch = originalFetch;
  }
});
