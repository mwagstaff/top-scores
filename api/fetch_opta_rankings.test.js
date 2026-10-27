"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { parseOptaRankings, fetchOptaRankings, OPTA_SOURCE } = require("./fetch_opta_rankings");
const { buildOptaIndex, findOptaMatch } = require("./opta_matching");
const { __private: server } = require("./server");
const now = Date.parse("2026-10-26T12:00:00Z");
const row = { rank: 1, contestantId: "4dsgumo7d4zupm2ugsvm4zm4d", contestantName: "Arsenal", contestantClubName: "Arsenal FC", currentRating: 100, country: "England", leagueId: "2kwbbcootiqqgmrzs6o5inle5" };
function script(rows = [row], other = []) {
  return 'const abc="Oct 23, 2026",xyz={lastUpdated:abc},women=JSON.parse(`' + JSON.stringify(other) + '`),men=JSON.parse(`' + JSON.stringify(rows) + '`)';
}
const parse = (text) => parseOptaRankings(text, { minRows: 1, now });

test("selects men by competition ID even when women occur first; retains original rating and date", () => {
  const women = [{ ...row, contestantId: "women", leagueId: "women-league" }];
  const result = parse(script([row], women));
  assert.equal(result.date, "2026-10-23");
  assert.equal(result.teams.length, 1);
  assert.equal(result.teams[0].OptaId, row.contestantId);
  assert.equal(result.teams[0].OptaRating, 100);
  assert.equal(result.teams[0].Elo, 2015);
  assert.equal(result.teams[0].Source, OPTA_SOURCE);
  assert.equal(result.teams[0].Country, "ENG");
});

test("rejects malformed, stale, duplicate, ambiguous and truncated datasets", () => {
  assert.throws(() => parse("<html>Blocked</html>"), /date missing/);
  assert.throws(() => parse(script().replace("Oct 23", "Oct 01")), /stale/);
  assert.throws(() => parse(script().replace("Oct 23", "Oct 30")), /stale/);
  assert.throws(() => parse(script([row, row])), /duplicate/);
  assert.throws(() => parse(script([row], [row])), /ambiguous/);
  assert.throws(() => parse(script([{ ...row, currentRating: null }])), /Invalid Opta rating/);
  assert.throws(() => parse(script([{ ...row, currentRating: 101 }])), /Invalid Opta rating/);
  assert.throws(() => parseOptaRankings(script(), { now }), /too small/);
  assert.throws(() => parse(script([{ ...row, leagueId: "women-only" }])), /men's rankings missing/);
});

test("fetch rejects HTTP failures and parses a successful response without executing script", async () => {
  await assert.rejects(fetchOptaRankings({ fetchImpl: async () => new Response("blocked", { status: 403 }) }), /HTTP 403/);
  const result = await fetchOptaRankings({ minRows: 1, now, fetchImpl: async () => new Response(script() + ';throw Error("must not execute")') });
  assert.equal(result.teams.length, 1);
  assert.ok(result.byteLength > 0);
});

test("strict matching handles explicit IDs, ambiguous names and reserve teams safely", () => {
  const teams = parse(script()).teams;
  const inter = { ...teams[0], Club: "Internazionale", OptaId: "3vo5mpj7catp66nrwwqiuhuup", OptaAliases: ["Inter"] };
  const andorra = { ...teams[0], Club: "Inter Club d'Escaldes", OptaId: "andorra", OptaAliases: [] };
  const index = buildOptaIndex([...teams, inter, andorra,
    { ...teams[0], OptaId: "other-arsenal", Country: "Argentina" },
    { ...inter, Club: "Internazionale II", OptaId: "reserves" }]);
  assert.equal(findOptaMatch("Arsenal", index).team.OptaId, row.contestantId);
  assert.equal(findOptaMatch("Inter Milan", index).team.OptaId, inter.OptaId);
  assert.equal(findOptaMatch("Inter Club d'Escaldes", index).team.OptaId, "andorra");
  assert.equal(findOptaMatch("Inter", index).accepted, false);
  assert.equal(findOptaMatch("FK Arsenal Tivat", index).accepted, false);
  assert.equal(findOptaMatch("Internazionale II", index).team.OptaId, "reserves");
});

test("API integration preserves attribution, raw score and distinct clubs through normalization and deduplication", async () => {
  const teams = parse(script()).teams;
  teams.push({ ...teams[0], Club: "Internazionale", Name: "Internazionale", OptaId: "3vo5mpj7catp66nrwwqiuhuup", OptaRating: 95, Elo: 1910, OptaAliases: [] });
  teams.push({ ...teams[0], Club: "Inter Club d'Escaldes", Name: "Inter Club d'Escaldes", OptaId: "andorra", OptaRating: 60, Elo: 1175, OptaAliases: [] });
  const matches = [{ home_team: "Arsenal", away_team: "England" }, { home_team: "Inter Milan", away_team: "Inter Club d'Escaldes" }];
  const result = await server.buildRankedTeamsForSource(matches, teams, [], [{ Team: "England", Elo: 2100, Rank: 3 }], "clubelo");
  const payload = server.toTeamsApiTeamPayload(result);
  const arsenal = payload.find(t => t.Name === "Arsenal");
  assert.deepEqual(arsenal.Datasource, [OPTA_SOURCE]);
  assert.equal(arsenal.OptaRating, 100);
  assert.equal(arsenal.RatingUpdatedAt, "2026-10-23");
  assert.equal(arsenal.Points, 2015);
  assert.equal(payload.filter(t => t.OptaId).length, 3);
  assert.deepEqual(payload.find(t => t.Name === "England").Datasource, ["National Elo"]);
});

test("top-team filters use compatible scores and preserve home-association country checks", () => {
  const arsenal = parse(script()).teams[0];
  const tamworth = { ...arsenal, Name: "Tamworth", Club: "Tamworth", OptaId: "tamworth", Rank: 3000, Elo: 1175, OptaRating: 60, OptaAliases: [] };
  const context = server.buildFixtureViewFilterContext({
    clubEloTeams: [arsenal, tamworth], premierLeagueTeams: [],
    teamCatalogSnapshot: { teams: [], byID: new Map() },
  });
  assert.equal(context.isTopTeamsMajorClub("Arsenal"), true);
  assert.equal(context.isTopTeamsMajorClub("Tamworth"), false);
  assert.equal(context.isTopTeamsHomeAssociationClub("Tamworth"), true);
  assert.equal(context.isTopTeamsMajorClub("FK Arsenal Tivat"), false);
});
