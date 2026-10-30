import test from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { readFileSync } from "node:fs";
import ts from "typescript";
import React, { act } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { create } from "react-test-renderer";
import { MemoryRouter } from "react-router-dom";

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

const { ChannelLogo, FixtureRow } = await import("../src/client/components/FixtureRow.tsx");

test("new broadcaster logos render without an upstream logo URL", () => {
  for (const name of ["Ligue1+", "Ligue 1+ (UK IR)", "S4C Online", "STV Player", "STV Scotland", "DeeTV"]) {
    const html = renderToStaticMarkup(React.createElement(ChannelLogo, {
      channel: { name, countryCode: "GB", logo: null },
    }));
    assert.ok(html.includes(`src="/logos/tv?name=${encodeURIComponent(name)}"`), name);
  }
});

test("Prime Video uses the bundled Amazon logo when the broadcast has no logo", () => {
  const html = renderToStaticMarkup(React.createElement(ChannelLogo, {
    channel: { name: "Prime Video (UK)", countryCode: "GB", country: "United Kingdom", logo: null },
  }));
  assert.match(html, /<img[^>]+src="\/logos\/tv\?name=Prime%20Video%20\(UK\)"/);
  assert.match(html, /Prime Video \(UK\)/);
});

test("fixture popovers reveal channels and ratings without replacing match links", async () => {
  const original = { document: globalThis.document, window: globalThis.window };
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.document = new EventTarget();
  globalThis.document.activeElement = null;
  globalThis.window = { innerHeight: 800 };
  const channels = ["TNT Sports 1", "TNT Sports Ultimate", "HBO Max"].map(name => ({ name, countryCode: "GB" }));
  const match = { id: "123", date: "2026-10-31", time: "12:30", homeTeam: "Chelsea", awayTeam: "Manchester United", league: "Premier League", tvChannels: channels, watchabilityIndex: { stars: 5, score: 90, tier: "must_watch" } };
  let renderer;
  try {
    await act(async () => {
      renderer = create(React.createElement(MemoryRouter, null, React.createElement(FixtureRow, { match, compactTV: true })), {
        createNodeMock: () => ({ getBoundingClientRect: () => ({ top: 400, bottom: 444 }) }),
      });
    });
    const target = kind => renderer.root.findByProps({ className: `fixture-tv-target fixture-tv-${kind}` });
    const tooltips = () => renderer.root.findAllByProps({ role: "tooltip" });
    assert.equal(tooltips().length, 0);
    await act(async () => target("channels").props.onPointerEnter({ pointerType: "touch" }));
    assert.equal(tooltips().length, 0);
    await act(async () => target("channels").props.onPointerEnter({ pointerType: "mouse" }));
    assert.deepEqual(tooltips()[0].findAllByType("li").map(node => node.findByType(ChannelLogo).props.channel.name), channels.map(channel => channel.name));
    const channelLink = target("channels").findByType("a");
    assert.equal(channelLink.props.href, "/matches/123?date=2026-10-31");
    assert.equal(channelLink.props["aria-describedby"], tooltips()[0].props.id);
    await act(async () => target("channels").props.onPointerLeave({ currentTarget: { contains: () => false } }));
    assert.equal(tooltips().length, 0);
    await act(async () => target("rating").props.onFocus());
    assert.ok(tooltips()[0].findAllByType("span").some(node => node.children.includes("Must watch")));
    assert.equal(target("rating").findByType("a").props.href, channelLink.props.href);
    await act(async () => {
      const event = new Event("keydown");
      event.key = "Escape";
      document.dispatchEvent(event);
    });
    assert.equal(tooltips().length, 0);
  } finally {
    if (renderer) await act(async () => renderer.unmount());
    Object.assign(globalThis, original);
  }
});
