import test from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { createRequire } from "node:module";
import React, { act } from "react";
import { create } from "react-test-renderer";

const compiled = await build({ entryPoints: ["src/client/components/MatchAnalysisCard.tsx"], bundle: true,
  platform: "node", format: "cjs", packages: "external", write: false,
  plugins: [{ name: "team-colors", setup(builder) {
    builder.onLoad({ filter: /\/teamColors\.ts$/ }, () => ({ contents: `export const useTeamColorCatalog = () => ({lineupColors: () => ({background:'#e6003a',foreground:'#ffffff'})});`, loader: "js" }));
  } }],
});
const module = { exports: {} };
new Function("require", "module", "exports", compiled.outputFiles[0].text)(createRequire(import.meta.url), module, module.exports);
const { MatchAnalysisCard } = module.exports;
const row = (id, home, group = "Key stats") => ({id, label:id, group, headline:group === "Key stats", home, away:0,
  home_display:String(home), away_display:"0", home_estimated:false, away_estimated:false});
const stats = {status:"available", periods:[
  {id:"all",label:"All",rows:[row("ball_possession",54),row("xg",1.2),row("shots_on_target",3),row("fouls",7,"Discipline")]},
  {id:"first_half",label:"1st half",rows:[row("ball_possession",38),row("fouls",4,"Discipline")]},
], updated_at:null,refresh_after_seconds:60};
const momentum = { status:"available",segments:[{id:"1",side:"home",points:[{minute:1,value:0},{minute:2,value:10}]}],annotations:[],ticks:[],end_minute:90.5,scale:100 };
const props = {momentum,stats,homeTeam:"Home",awayTeam:"Away",isLive:false};
globalThis.IS_REACT_ACT_ENVIRONMENT = true;

test("switching, half filters and expansion use supplied data and preserve selection during refresh", async () => {
  let renderer;
  try {
    await act(async () => { renderer = create(React.createElement(MatchAnalysisCard, props)); });
    const button = text => renderer.root.findAllByType("button").find(b => b.children.join("").startsWith(text));
    const rows = () => renderer.root.findAllByProps({className:"match-stat-row"}).map(r => r.props["aria-label"]);
    assert.equal(rows().length,3);
    assert.ok(button("Momentum").props["aria-pressed"]);
    await act(async () => button("View match stats").props.onClick());
    assert.ok(button("Match stats").props["aria-pressed"]);
    assert.equal(rows().length,3);
    await act(async () => button("Show all stats").props.onClick());
    assert.equal(rows().length,4);
    await act(async () => button("1st half").props.onClick());
    assert.match(rows()[0],/Home 38/);
    assert.match(rows()[1],/Home 4/);
    await act(async () => renderer.update(React.createElement(MatchAnalysisCard,{...props,stats:{...stats}})));
    assert.ok(button("1st half").props["aria-pressed"]);
    await act(async () => button("Show key stats").props.onClick());
    assert.equal(rows().length,1);
    await act(async () => button("Momentum").props.onClick());
    assert.match(rows()[0],/Home 54/);
  } finally { if(renderer) await act(async()=>renderer.unmount()); }
});

test("stats-only coverage renders without a chart and legacy payloads retain Momentum", async () => {
  let renderer;
  try {
    await act(async()=>{renderer=create(React.createElement(MatchAnalysisCard,{...props,momentum:null}));});
    assert.equal(renderer.root.findAllByType("svg").length,0);
    assert.equal(renderer.root.findAllByProps({className:"match-stat-row"}).length,3);
    await act(async()=>renderer.update(React.createElement(MatchAnalysisCard,{...props,stats:null})));
    assert.equal(renderer.root.findAllByType("svg").length,1);
    assert.equal(renderer.root.findAllByProps({className:"match-stat-row"}).length,0);
  } finally { if(renderer) await act(async()=>renderer.unmount()); }
});

test("a lone supplied half is labelled and secondary-only coverage needs no misleading expansion", async () => {
  let renderer;
  try {
    const thinStats = {...stats, periods:[{id:"first_half",label:"1st half",rows:[row("fouls",4,"Discipline")]}]};
    await act(async()=>{renderer=create(React.createElement(MatchAnalysisCard,{...props,momentum:null,stats:thinStats}));});
    assert.equal(renderer.root.findAllByProps({className:"match-stat-row"}).length,1);
    assert.ok(renderer.root.findAllByType("p").some(p=>p.children.join("") === "1st half"));
    assert.equal(renderer.root.findAllByType("button").length,0);
  } finally { if(renderer) await act(async()=>renderer.unmount()); }
});
