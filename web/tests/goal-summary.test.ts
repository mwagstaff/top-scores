import test from "node:test";
import assert from "node:assert/strict";
import { goalSummary } from "../src/client/goalSummary.ts";
import type { MatchDetails } from "../src/client/types.ts";

test("scoreboard goals match exact added-time assists, reverse own goals and omit disallowed goals", () => {
  const scorer = (player: string, goalTimes: string[] = [], ownGoalTimes: string[] = [], disallowedGoalTimes: string[] = []) => ({ player, goalTimes, ownGoalTimes, disallowedGoalTimes });
  const details = {
    homeGoalScorers: [scorer("A. Davies", ["35", "45+2"], [], ["60"]), scorer("Home Defender", [], ["70"])],
    awayGoalScorers: [scorer("E. Eze", ["25"]), scorer("Away Defender", [], ["50"])],
    homeAssists: [{ player: "H. Kane", assistTimes: ["35"] }, { player: "M. Olise", assistTimes: ["45+1"] }],
    awayAssists: [{ player: "M. Ødegaard", assistTimes: ["25"] }],
  } as MatchDetails;
  assert.deepEqual(goalSummary(details, "home").map(g => [g.minute, g.scorer, g.assister]), [
    ["35'", "Davies", "Kane"], ["45+2'", "Davies", undefined], ["50'", "Defender (OG)", undefined],
  ]);
  assert.deepEqual(goalSummary(details, "away").map(g => [g.minute, g.scorer, g.assister]), [
    ["25'", "Eze", "Ødegaard"], ["70'", "Defender (OG)", undefined],
  ]);
  assert.deepEqual(goalSummary(undefined, "home"), []);
});
