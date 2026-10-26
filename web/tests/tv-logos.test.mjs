import test from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { readFileSync } from "node:fs";
import ts from "typescript";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";

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

const { ChannelLogo } = await import("../src/client/components/FixtureRow.tsx");

test("Prime Video uses the bundled Amazon logo when the broadcast has no logo", () => {
  const html = renderToStaticMarkup(React.createElement(ChannelLogo, {
    channel: { name: "Prime Video (UK)", countryCode: "GB", country: "United Kingdom", logo: null },
  }));
  assert.match(html, /<img[^>]+src="\/logos\/tv\?name=Prime%20Video%20\(UK\)"/);
  assert.match(html, /Prime Video \(UK\)/);
});
