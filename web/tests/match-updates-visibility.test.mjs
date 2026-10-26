import test from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { createRequire } from "node:module";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";

test("match updates appear only after kickoff", async () => {
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
  const { MatchCard } = module.exports;
  const details = {
    id: "123",
    homeGoalScorers: [{ player: "A. Player", goalTimes: ["6'"], ownGoalTimes: [], disallowedGoalTimes: [] }],
    awayGoalScorers: [],
    homeAssists: [],
    awayAssists: [],
    homeYellowCards: [],
    awayYellowCards: [],
    homeRedCards: [],
    awayRedCards: [],
    homeVarEvents: [],
    awayVarEvents: [],
  };
  const match = {
    id: "123",
    date: "2026-10-25",
    time: "14:00",
    homeTeam: "Liverpool",
    awayTeam: "Brighton & Hove Albion",
    league: "Premier League",
    tvChannels: [],
    homeScore: null,
    awayScore: null,
    scoreStatus: "NS",
    matchDetailsId: "123",
    matchDetails: details,
  };
  const render = (scoreStatus) => renderToStaticMarkup(
    React.createElement(MemoryRouter, null,
      React.createElement(MatchCard, { match: { ...match, scoreStatus }, detailOnly: true })),
  );

  const upcoming = render("NS");
  assert.doesNotMatch(upcoming, /Match updates|Key events|Commentary|Match Events|A\. Player/);
  assert.match(render("LIVE"), /Match updates/);
  assert.match(render("LIVE"), /Match Events/);
  assert.match(render("FT"), /Match updates/);
});
