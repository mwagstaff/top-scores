"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const { historyRows } = require("./bsd_player_performance");

function service(bsd, mongo) {
  const module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(require.resolve("./bsd_player_performance"), "utf8"), {
    module, Date, console,
    require: name => name === "./bsd_client" ? bsd : name === "./mongo_client" ? mongo : require(name),
  });
  return module.exports;
}

test("opening an uncached completed lineup fetches once and stores match stats", async () => {
  let calls = 0;
  const saved = [];
  const api = service({ getEventPlayerStats: async id => {
    calls++;
    await new Promise(resolve => setTimeout(resolve, 5));
    return { event_id: id, player_stats: [{ player_id: 803, rating: 7.2, minutes_played: 90 }] };
  } }, {
    getBsdRecords: async collection => collection === "bsd_events" ? [{ status: "finished" }] : [],
    upsertBsdRecord: async (...args) => saved.push(args),
  });
  const [a, b] = await Promise.all([api.getMatchPerformance("209598"), api.getMatchPerformance("209598")]);
  assert.equal(calls, 1);
  assert.equal(saved[0][0], "bsd_player_stats");
  assert.equal(a.players[0].stats.rating, 7.2);
  assert.equal(b.players[0].player_id, "803");
});

test("cached stats are returned without upstream work and upcoming matches do not fetch", async () => {
  const api = service({ getEventPlayerStats() { throw new Error("must not fetch"); } }, {
    getBsdRecords: async (collection, query) => collection === "bsd_events"
      ? [{ status: query._id === "upcoming" ? "notstarted" : "finished" }]
      : [{ updated_at: new Date().toISOString(), payload: { player_stats: [] } }],
  });
  assert.equal((await api.getMatchPerformance("finished")).players.length, 0);
  assert.equal((await api.getMatchPerformance("upcoming")).players.length, 0);
});

test("history joins event IDs, keeps unrated appearances, excludes unused subs and sorts by kickoff", () => {
  const stats = [
    { event_id: 1, team_id: 20, minutes_played: 90, rating: null },
    { event_id: 2, team_id: 20, minutes_played: 90, rating: 8.1 },
    { event_id: 3, team_id: 20, minutes_played: 0, rating: null },
    { event_id: 4, team_id: 20, minutes_played: 20, rating: 6.2 },
  ];
  const events = [1, 2, 3].map(id => ({ id, status: "finished", event_date: `2026-10-0${id}T12:00:00Z`,
    home_team_id: id === 2 ? 13 : 20, away_team_id: id === 2 ? 20 : 13, home_team: "Home", away_team: "Away", home_score: 1, away_score: 2 }));
  const rows = historyRows(stats, events);
  assert.deepEqual(rows.map(row => row.event_id), ["2", "1"]);
  assert.equal(rows[0].is_home, false);
  assert.equal(rows[0].stats.rating, 8.1);
  assert.equal(rows[1].stats.rating, null);
  assert.equal(rows[0].home_score, 1);
});

test("history uses cached fixtures and stores the result for subsequent profile opens", async () => {
  const saved = [];
  const api = service({
    getPlayerStats: async () => [{ event_id: 1, player_id: 803, team_id: 20, minutes_played: 90, rating: 7 }],
    getEvent: async () => { throw new Error("should use cached event"); },
  }, {
    getBsdRecords: async collection => collection === "bsd_events" ? [{ payload: {
      id: 1, status: "finished", event_date: "2026-10-17T12:00:00Z", home_team_id: 20,
      home_team: "Everton", away_team: "Chelsea", home_score: 1, away_score: 2,
    } }] : [],
    upsertBsdRecord: async (...args) => saved.push(args),
  });
  const payload = await api.getPlayerPerformance("803");
  assert.equal(payload.matches[0].home_team, "Everton");
  assert.equal(payload.matches[0].match.match_details_id, "1");
  assert.equal(saved[0][0], "bsd_player_history");
});

test("cached history only links matches currently available in the details store", async () => {
  let available = true;
  const api = service({ getPlayerStats() { throw new Error("history is cached"); } }, {
    getBsdRecords: async collection => collection === "bsd_player_history"
      ? [{ updated_at: new Date().toISOString(), payload: { matches: [{ event_id: "1" }, { event_id: "2" }] } }]
      : collection === "bsd_events" && available ? [{ payload: {
        id: 1, status: "finished", event_date: "2026-10-17T12:00:00Z",
        home_team: "Everton", away_team: "Chelsea", home_score: 0, away_score: 2,
      } }] : [],
  });
  const first = await api.getPlayerPerformance("803");
  assert.equal(first.matches[0].match.match_details_id, "1");
  assert.equal(first.matches[0].match.home_score, 0);
  assert.equal(first.matches[1].match, null);
  available = false;
  const second = await api.getPlayerPerformance("803");
  assert.equal(second.matches[0].match, null);
});
