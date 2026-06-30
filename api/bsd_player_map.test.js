"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { __private } = require("./bsd_player_map");
const { pairSide, buildFixturePlayerMappings } = __private;

// Real Brazil data (Scotland v Brazil): numbers agree between sources, names
// diverge hard ("Vinícius Jr."/"Vinícius Júnior", "Alisson"/"Alisson Becker").
const BSD_BRAZIL = [
  { id: 322, jersey_number: 1, name: "Alisson" },
  { id: 49, jersey_number: 13, name: "Danilo" },
  { id: 595, jersey_number: 7, name: "Vinícius Jr." },
  { id: 663, jersey_number: 26, name: "Rayan" },
  { id: 4072, jersey_number: 3, name: "G. Magalhães" },
];

const TSDB_BRAZIL = [
  { strHome: "No", intSquadNumber: "1", strPlayer: "Alisson Becker", idPlayer: "34163551", strCutout: "http://x/alisson.png" },
  { strHome: "No", intSquadNumber: "13", strPlayer: "Danilo", idPlayer: "34146582", strCutout: "http://x/danilo.png" },
  { strHome: "No", intSquadNumber: "7", strPlayer: "Vinícius Júnior", idPlayer: "34161324", strCutout: "http://x/vini.png" },
  { strHome: "No", intSquadNumber: "26", strPlayer: "Rayan", idPlayer: "34235442", strCutout: "http://x/rayan.png" },
  { strHome: "No", intSquadNumber: "3", strPlayer: "Gabriel Magalhães", idPlayer: "34172252", strCutout: "http://x/gabriel.png" },
];

test("pairSide maps by jersey number even when names diverge (Vinícius, Alisson)", () => {
  const mappings = pairSide(BSD_BRAZIL, TSDB_BRAZIL);
  const byBsdId = new Map(mappings.map((m) => [m.id, m]));

  // Vinícius Jr. (name score 0 vs "Vinícius Júnior") still maps via #7.
  assert.equal(byBsdId.get("595").payload.tsdb_player_id, "34161324");
  assert.equal(byBsdId.get("595").payload.cutout_url, "http://x/vini.png");
  // Alisson (name score 0 vs "Alisson Becker") still maps via #1.
  assert.equal(byBsdId.get("322").payload.tsdb_player_id, "34163551");
  // Exact / initial+surname cases map too.
  assert.equal(byBsdId.get("49").payload.tsdb_player_id, "34146582");
  assert.equal(byBsdId.get("4072").payload.tsdb_player_id, "34172252");
  assert.equal(mappings.length, 5);
});

test("pairSide skips a BSD player with no same-number TSDB entry", () => {
  const bsd = [{ id: 999, jersey_number: 99, name: "Nobody" }];
  assert.deepEqual(pairSide(bsd, TSDB_BRAZIL), []);
});

test("pairSide rejects a shuffled number (contradiction guard)", () => {
  // BSD says Danilo wears #7, but TSDB #7 is Vinícius Júnior and TSDB #13 is
  // Danilo — the name points strongly to a different number, so reject.
  const bsd = [{ id: 49, jersey_number: 7, name: "Danilo" }];
  const mappings = pairSide(bsd, TSDB_BRAZIL);
  assert.deepEqual(mappings, []);
});

test("pairSide stores name-match confidence", () => {
  const mappings = pairSide(BSD_BRAZIL, TSDB_BRAZIL);
  const danilo = mappings.find((m) => m.id === "49");
  assert.equal(danilo.extra.confidence, 4); // exact name
  const vini = mappings.find((m) => m.id === "595");
  assert.equal(vini.extra.confidence, 0); // mapped by number despite 0 name score
});

test("buildFixturePlayerMappings splits home/away by strHome", () => {
  const bsdLineupPayload = {
    lineups: {
      home: { players: [{ id: 10, jersey_number: 1, name: "A. Gunn" }] },
      away: { players: BSD_BRAZIL },
    },
  };
  const entries = [
    { strHome: "Yes", intSquadNumber: "1", strPlayer: "Angus Gunn", idPlayer: "34145000", strCutout: "http://x/gunn.png" },
    ...TSDB_BRAZIL,
  ];
  const mappings = buildFixturePlayerMappings(bsdLineupPayload, entries);
  const gunn = mappings.find((m) => m.id === "10");
  assert.equal(gunn.payload.tsdb_player_id, "34145000"); // home matched to home
  assert.ok(mappings.find((m) => m.id === "595")); // away Vinícius mapped
});
