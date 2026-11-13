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
        compilerOptions: { target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX, module: ts.ModuleKind.ESNext },
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
  const toggle = () => renderer.root.findAllByType("label").find(node => node.children.includes("Show details"))?.findByType("input");
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
    assert.deepEqual(JSON.parse(stored.get("top-scores.match-view.v1")), { scope: "top", showDetails: true, showStats: true, highlightEnglishEuropean: true });

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
    assert.deepEqual(JSON.parse(stored.get("top-scores.match-view.v1")), { scope: "epl", showDetails: false, showStats: true, highlightEnglishEuropean: true });
  } finally {
    if (renderer) await act(async () => { renderer.unmount(); });
    globalThis.fetch = originalFetch;
  }
});


test("English clubs in European competitions are highlighted until the URL toggle turns it off", async t => {
  t.mock.timers.enable({ apis: ["Date"], now: new Date("2026-11-04T12:00:00Z") });
  stored.clear();
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async url => {
    const parsed = new URL(String(url), "https://example.test");
    if (parsed.pathname.endsWith("/teams/catalog")) {
      assert.equal(parsed.searchParams.get("competition_id"), "premier-league");
      return new Response(JSON.stringify({ teams: [{ name: "Arsenal", aliases: ["Arsenal FC"], source_team_ids: ["1"] }] }));
    }
    const fixture = (id, league, home, away) => ({ match_details_id: id, date: "2026-11-04", time: "20:00", league, score_status: "NS", home_team: home, away_team: away, tv_channels: [] });
    return new Response(JSON.stringify([
      fixture("ucl", "UEFA Champions League", "Bayern Munich", "Arsenal"),
      fixture("ucl-other", "UEFA Champions League", "Inter", "Barcelona"),
      fixture("epl", "Premier League", "Arsenal", "Chelsea"),
    ]));
  };
  let renderer, location;
  function Harness() {
    location = useLocation();
    return React.createElement(MatchesScreen);
  }
  const highlightToggle = () => renderer.root.findAllByType("label").find(node => node.children.includes("Highlight English clubs in Europe")).findByType("input");
  const highlighted = () => renderer.root.findAll(node => typeof node.props.className === "string" && node.props.className.includes("is-highlighted"), { deep: false })
    .map(node => node.props.className);
  try {
    await act(async () => {
      renderer = create(React.createElement(MemoryRouter, { initialEntries: ["/?date=2026-11-04"] }, React.createElement(Harness)));
    });
    await act(async () => {});
    assert.equal(highlightToggle().props.checked, true);
    assert.match(location.search, /highlight=1/);
    assert.equal(highlighted().length, 1);

    await act(async () => { highlightToggle().props.onChange({ target: { checked: false } }); });
    assert.equal(highlightToggle().props.checked, false);
    assert.match(location.search, /highlight=0/);
    assert.equal(highlighted().length, 0);
    assert.equal(JSON.parse(stored.get("top-scores.match-view.v1")).highlightEnglishEuropean, false);

    await act(async () => { highlightToggle().props.onChange({ target: { checked: true } }); });
    assert.equal(highlighted().length, 1);
  } finally {
    if (renderer) await act(async () => { renderer.unmount(); });
    globalThis.fetch = originalFetch;
  }
});

test("the English clubs highlight is offered only when it separates some rows from others", async t => {
  t.mock.timers.enable({ apis: ["Date"], now: new Date("2026-11-04T12:00:00Z") });
  const originalFetch = globalThis.fetch;
  const fixture = (date, league, home, away) => ({ match_details_id: `${date}-${home}`, date, time: "20:00", league, score_status: "NS", home_team: home, away_team: away, tv_channels: [] });
  // Each case has its own date because the day cache outlives a frozen clock.
  const cases = [
    ["2026-11-10", "all English league", [["Premier League", "Arsenal", "Chelsea"]], false],
    ["2026-11-11", "no English clubs", [["UEFA Champions League", "Inter", "Barcelona"]], false],
    ["2026-11-12", "only English clubs in Europe", [["UEFA Champions League", "Bayern Munich", "Arsenal"]], false],
    ["2026-11-13", "mixed", [["UEFA Champions League", "Bayern Munich", "Arsenal"], ["UEFA Champions League", "Inter", "Barcelona"]], true],
  ];
  let renderer;
  globalThis.fetch = async url => {
    const parsed = new URL(String(url), "https://example.test");
    if (parsed.pathname.endsWith("/teams/catalog")) return new Response(JSON.stringify({ teams: [{ name: "Arsenal", aliases: [], source_team_ids: ["1"] }, { name: "Chelsea", aliases: [], source_team_ids: ["2"] }] }));
    const date = parsed.searchParams.get("start");
    return new Response(JSON.stringify((cases.find(item => item[0] === date)?.[2] || []).map(row => fixture(date, ...row))));
  };
  try {
    for (const [date, name, , shown] of cases) {
      await act(async () => {
        renderer = create(React.createElement(MemoryRouter, { initialEntries: [`/?date=${date}&scope=all`] }, React.createElement(MatchesScreen)));
      });
      await act(async () => {});
      const label = renderer.root.findAllByType("label").find(node => node.children.includes("Highlight English clubs in Europe"));
      assert.equal(Boolean(label), shown, name);
      const rowsHighlighted = renderer.root.findAll(node => typeof node.props.className === "string" && node.props.className.includes("is-highlighted"), { deep: false });
      assert.equal(rowsHighlighted.length, shown ? 1 : 0, name);
      await act(async () => { renderer.unmount(); });
      renderer = null;
    }
  } finally {
    if (renderer) await act(async () => { renderer.unmount(); });
    globalThis.fetch = originalFetch;
  }
});


test("empty TV view counts all competition pages and clears the scope without changing the date", async t => {
  t.mock.timers.enable({ apis: ["Date"], now: new Date("2026-11-01T12:00:00Z") });
  const originalFetch = globalThis.fetch;
  const requests = [];
  const match = (id, status = "NS", channels = [{ name: "BBC One", country_code: "GB" }]) => ({
    match_details_id: id, date: "2026-11-03", time: "20:00", league: "League One",
    score_status: status, home_team: `Home ${id}`, away_team: `Away ${id}`, tv_channels: channels,
  });
  globalThis.fetch = async url => {
    const parsed = new URL(String(url), "https://example.test");
    requests.push(parsed);
    if (!parsed.pathname.endsWith("/matches")) return new Response("[]");
    const filtered = parsed.searchParams.has("view_option");
    const secondPage = parsed.searchParams.get("page") === "2";
    const items = filtered ? [] : secondPage ? [match("3"), match("finished", "FT"), match("no-tv", "NS", [])] : [match("1"), match("2")];
    return new Response(JSON.stringify(items), { headers: { "X-Has-More": String(!filtered && !secondPage) } });
  };
  let renderer, location;
  function Harness() {
    location = useLocation();
    return React.createElement(MatchesScreen, { tv: true });
  }
  try {
    await act(async () => {
      renderer = create(React.createElement(MemoryRouter, { initialEntries: ["/tv?date=2026-11-03&scope=top"] }, React.createElement(Harness)));
    });
    const button = renderer.root.findAllByType("button").find(node => node.children.includes("Show 3 matches across all competitions"));
    assert.ok(button);
    assert.equal(renderer.root.findAllByProps({ className: "empty-tv" }).length, 0);
    assert.ok(requests.some(url => url.searchParams.get("page") === "2" && !url.searchParams.has("view_option")));
    await act(async () => { button.props.onClick(); });
    assert.match(location.search, /scope=all/);
    assert.match(location.search, /date=2026-11-03/);
    assert.equal(renderer.root.findAllByProps({ className: "football-empty" }).length, 0);
  } finally {
    if (renderer) await act(async () => { renderer.unmount(); });
    globalThis.fetch = originalFetch;
  }
});


test("TV empty state confirms no remaining broadcasts across all competitions today", async t => {
  t.mock.timers.enable({ apis: ["Date"], now: new Date("2026-11-05T12:00:00Z") });
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async url => {
    const parsed = new URL(String(url), "https://example.test");
    const filtered = parsed.searchParams.has("view_option");
    const items = !filtered && parsed.searchParams.get("start") === "2026-11-05" ? [{
      match_details_id: "finished-tv", date: "2026-11-05", time: "10:00", league: "League One",
      score_status: "FT", home_team: "Home FC", away_team: "Away FC",
      tv_channels: [{ name: "BBC One", country_code: "GB" }],
    }, {
      match_details_id: "not-on-tv", date: "2026-11-05", time: "20:00", league: "League Two",
      score_status: "NS", home_team: "Other FC", away_team: "Visitors FC", tv_channels: [],
    }] : [];
    return new Response(JSON.stringify(items));
  };
  let renderer;
  try {
    await act(async () => {
      renderer = create(React.createElement(MemoryRouter, { initialEntries: ["/tv?scope=top"] }, React.createElement(MatchesScreen, { tv: true })));
    });
    assert.equal(renderer.root.findAllByProps({ className: "empty-tv" }).length, 1);
    assert.ok(renderer.root.findAllByType("h3").some(node => node.children.includes("No more matches on TV today")));
    assert.equal(renderer.root.findByProps({ className: "football-empty" }).findAllByType("button").length, 0);
  } finally {
    if (renderer) await act(async () => { renderer.unmount(); });
    globalThis.fetch = originalFetch;
  }
});


test("empty fixtures jump to the next filtered matchdate and mark the carousel with dots", async t => {
  t.mock.timers.enable({ apis: ["Date"], now: new Date("2026-11-10T12:00:00Z") });
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async url => {
    const parsed = new URL(String(url), "https://example.test");
    if (!parsed.pathname.endsWith("/matches")) return new Response("[]");
    requests.push(parsed.searchParams);
    const start = parsed.searchParams.get("start"), end = parsed.searchParams.get("end");
    const date = "2026-11-13";
    return new Response(JSON.stringify(start <= date && end >= date ? [{
      match_details_id: "next-friday", date, time: "20:00", league: "Premier League",
      score_status: "NS", home_team: "Home FC", away_team: "Away FC", tv_channels: [],
    }] : []));
  };
  let renderer, location;
  function Harness() { location = useLocation(); return React.createElement(MatchesScreen); }
  try {
    await act(async () => {
      renderer = create(React.createElement(MemoryRouter, { initialEntries: ["/?date=2026-11-10&scope=top"] }, React.createElement(Harness)));
    });
    const jump = renderer.root.findAllByType("button").find(node => node.children.join("") === "Jump to next matchdate (this Friday)");
    assert.ok(jump);
    const dots = renderer.root.findAll(node => node.type === "span" && node.props.className?.startsWith("date-count"));
    assert.equal(dots.length, 1);
    assert.deepEqual(dots[0].children, []);
    assert.equal(dots[0].props["aria-hidden"], "true");
    assert.match(dots[0].parent.props["aria-label"], /1 match/);
    assert.ok(requests.filter(query => query.get("start") !== query.get("end")).every(query => query.get("view_option") === "preset:top-teams"));
    await act(async () => { jump.props.onClick(); });
    assert.match(location.search, /date=2026-11-13/);
    assert.match(location.search, /scope=top/);
  } finally {
    if (renderer) await act(async () => { renderer.unmount(); });
    globalThis.fetch = originalFetch;
  }
});

test("next matchdate lookup paginates past nonmatching broadcasts and honours cancellation", async () => {
  const { nextMatchDate, nextMatchDateLabel } = await import("../src/client/competitionDates.ts");
  const originalFetch = globalThis.fetch;
  const pages = [];
  globalThis.fetch = async url => {
    const page = new URL(String(url), "https://example.test").searchParams.get("page");
    pages.push(page);
    return new Response(JSON.stringify([{
      match_details_id: `page-${page}`, date: page === "1" ? "2026-11-11" : "2026-12-03", time: "20:00",
      league: "Premier League", score_status: "NS", home_team: "Home", away_team: "Away",
      tv_channels: page === "1" ? [] : [{ name: "BBC One", country_code: "GB" }],
    }]), { headers: { "X-Has-More": String(page === "1") } });
  };
  try {
    assert.equal(await nextMatchDate([], "2026-11-10", "9999-12-31", false, { tv: true }), "2026-12-03");
    assert.deepEqual(pages, ["1", "2"]);
    assert.equal(await nextMatchDate([], "2026-11-10", "9999-12-31", false, {}, () => false), undefined);
    assert.equal(pages.length, 2);
    assert.equal(nextMatchDateLabel("2026-11-11", "2026-11-10"), "tomorrow");
  } finally { globalThis.fetch = originalFetch; }
});


test("arrow keys navigate dates, preserve filters, and respect controls and date limits", async t => {
  t.mock.timers.enable({ apis: ["Date"], now: new Date("2026-11-10T12:00:00Z") });
  const listeners = new Set();
  t.mock.method(window, "addEventListener", (type, listener) => { if (type === "keydown") listeners.add(listener); });
  t.mock.method(window, "removeEventListener", (type, listener) => { if (type === "keydown") listeners.delete(listener); });
  class Element {
    constructor(control = false, editable = false) { this.control = control; this.isContentEditable = editable; }
    closest() { return this.control ? this : null; }
  }
  const originalElement = globalThis.HTMLElement;
  globalThis.HTMLElement = Element;
  t.mock.method(globalThis, "fetch", async () => new Response(JSON.stringify([])));
  let renderer, location, navigate;
  function Harness() {
    location = useLocation();
    navigate = useNavigate();
    return React.createElement(Routes, null,
      React.createElement(Route, { path: "/", element: React.createElement(MatchesScreen) }),
      React.createElement(Route, { path: "/tv", element: React.createElement(MatchesScreen, { tv: true }) }),
      React.createElement(Route, { path: "/results", element: React.createElement(MatchesScreen, { mode: "results" }) }));
  }
  async function key(key, options = {}) {
    const event = { key, target: new Element(), preventDefault() { this.defaultPrevented = true; }, ...options };
    await act(async () => { for (const listener of [...listeners]) listener(event); });
    return event.defaultPrevented === true;
  }
  const date = () => new URLSearchParams(location.search).get("date");
  try {
    await act(async () => { renderer = create(React.createElement(MemoryRouter, { initialEntries: ["/?date=2026-11-15&scope=top&highlight=1"] }, React.createElement(Harness))); });
    assert.equal(listeners.size, 1);
    assert.equal(await key("ArrowLeft"), true);
    assert.equal(date(), "2026-11-14");
    await key("ArrowRight");
    await key("ArrowRight");
    assert.equal(date(), "2026-11-16");
    assert.equal(new URLSearchParams(location.search).get("scope"), "top");
    assert.equal(new URLSearchParams(location.search).get("highlight"), "1");
    for (const options of [{ target: new Element(true) }, { target: new Element(false, true) }, { altKey: true }, { ctrlKey: true }, { metaKey: true }, { shiftKey: true }, { isComposing: true }, { defaultPrevented: true }]) {
      await key("ArrowLeft", options);
      assert.equal(date(), "2026-11-16");
    }
    await key("ArrowDown");
    assert.equal(date(), "2026-11-16");
    await act(async () => { navigate("/?date=2026-12-31"); });
    await key("ArrowRight");
    assert.equal(date(), "2027-01-01");
    await act(async () => { navigate("/tv?date=2026-11-10"); });
    assert.equal(await key("ArrowLeft"), false);
    assert.equal(date(), "2026-11-10");
    await key("ArrowRight");
    assert.equal(date(), "2026-11-11");
    await act(async () => { navigate("/results?date=2026-11-09"); });
    assert.equal(await key("ArrowRight"), false);
    assert.equal(date(), "2026-11-09");
    await key("ArrowLeft");
    assert.equal(date(), "2026-11-08");
  } finally {
    if (renderer) await act(async () => { renderer.unmount(); });
    globalThis.HTMLElement = originalElement;
  }
  assert.equal(listeners.size, 0);
});
