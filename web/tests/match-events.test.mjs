import test from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { createRequire } from "node:module";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";

test("own goals credit the opposing team while keeping the scorer's portrait", async () => {
  const compiled = await build({
    entryPoints: ["src/client/components/MatchCard.tsx"],
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
  const { buildTimelineEntries, MatchCard } = module.exports;
  const details = {
    id: "214111",
    homeTeam: "Portsmouth",
    awayTeam: "Millwall",
    homeGoalScorers: [],
    awayGoalScorers: [
      { player: "J. Metcalfe", goalTimes: ["6'"], ownGoalTimes: [], disallowedGoalTimes: [] },
      { player: "L. Dykes", goalTimes: [], ownGoalTimes: ["16'"], disallowedGoalTimes: [] },
    ],
    homeAssists: [],
    awayAssists: [],
    homeYellowCards: [],
    awayYellowCards: [],
    homeRedCards: [],
    awayRedCards: [],
    homeVarEvents: [],
    awayVarEvents: [],
    teamLineups: {
      away: {
        startingLineup: [{ number: 9, name: "L. Dykes", idPlayer: "dykes" }],
        substitutes: [],
        substitutions: [],
      },
    },
  };

  const entries = buildTimelineEntries(details);
  assert.deepEqual(entries.map(({ minute, side, playerSide }) => [minute, side, playerSide]), [
    ["6'", "away", undefined],
    ["16'", "home", "away"],
  ]);
  assert.equal(entries[1].lineupPlayer?.idPlayer, "dykes");
  assert.equal(entries[1].text, "L. Dykes (OG)");

  const match = {
    id: "214111",
    date: "2026-10-24",
    time: "15:00",
    homeTeam: "Portsmouth",
    awayTeam: "Millwall",
    league: "Championship",
    tvChannels: [],
    homeScore: 1,
    awayScore: 1,
    scoreStatus: "FT",
    matchDetailsId: "214111",
    matchDetails: details,
  };
  const html = renderToStaticMarkup(
    React.createElement(MemoryRouter, null, React.createElement(MatchCard, { match, detailOnly: true })),
  );
  const timeline = html.slice(html.indexOf('class="timeline-list"'));
  assert.ok(timeline.indexOf("L. Dykes (OG)") < timeline.indexOf("J. Metcalfe"));
  assert.match(timeline, /timeline-team[^>]*>.*?Portsmouth.*?L\. Dykes \(OG\)/);
});
