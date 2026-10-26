import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { build } from "esbuild";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";

test("compact match details show goals, assists, and red cards in minute order", async () => {
  const compiled = await build({
    entryPoints: ["src/client/components/CompactMatchEvents.tsx"],
    bundle: true,
    platform: "node",
    format: "cjs",
    packages: "external",
    write: false,
  });
  const module = { exports: {} };
  new Function("require", "module", "exports", compiled.outputFiles[0].text)(
    createRequire(import.meta.url), module, module.exports,
  );
  const details = {
    homeGoalScorers: [{ player: "A. Striker", goalTimes: ["23'"], ownGoalTimes: [] }],
    awayGoalScorers: [],
    homeAssists: [{ player: "B. Winger", assistTimes: ["23'"] }],
    awayAssists: [],
    homeRedCards: [{ player: "C. Defender", redCardTimes: ["67'"] }],
    awayRedCards: [{ player: "D. Midfielder", redCardTimes: ["90+1'"] }],
  };
  const html = renderToStaticMarkup(React.createElement(module.exports.CompactMatchEvents, {
    details,
    homeTeam: "Home FC",
    awayTeam: "Away FC",
  }));
  assert.ok(html.indexOf("23&#x27;") < html.indexOf("67&#x27;"));
  assert.match(html, /Striker.*\(Winger\)/);
  assert.match(html, /67[^>]*.*Defender, red card/);
  assert.match(html, /90\+1[^>]*.*Midfielder, red card/);
  assert.equal((html.match(/class="compact-red-card"/g) || []).length, 2);
});
