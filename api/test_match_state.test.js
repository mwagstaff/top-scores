const test = require("node:test");
const assert = require("node:assert/strict");

const { TestMatchState } = require("./test_match_state");

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

test("simulateVarDisallowedGoal reverts the score and records synthetic LiveText", async () => {
  const state = new TestMatchState();
  const match = state.createMatch({
    homeTeam: "Leeds United",
    awayTeam: "Norwich City",
    league: "FA Cup",
    homeScore: 0,
    awayScore: 0,
  });

  match.score_status = "19'";
  match.matchMinute = 19;

  try {
    const result = state.simulateVarDisallowedGoal(match.id, true, {
      playerName: "Lukas Nmecha",
      assisterName: "Wilfried Gnonto",
      revertDelayMs: 20,
    });

    assert.ok(result);
    assert.equal(match.home_score, 1);
    assert.equal(match.away_score, 0);

    await wait(1100);

    const updated = state.getMatch(match.id);
    assert.ok(updated);
    assert.equal(updated.home_score, 0);
    assert.equal(updated.away_score, 0);
    assert.deepStrictEqual(updated.home_goal_scorers, [
      {
        player: "Lukas Nmecha",
        goal_times: [],
        own_goal_times: [],
        disallowed_goal_times: ["19'"],
      },
    ]);
    assert.deepStrictEqual(updated.home_assists, [
      {
        player: "Wilfried Gnonto",
        assist_times: ["19'"],
      },
    ]);
    assert.equal(updated.live_text_entries.length, 2);
    assert.match(
      updated.live_text_entries[0].text,
      /^GOAL OVERTURNED BY VAR: Lukas Nmecha \(Leeds United\) scores but the goal is ruled out after a VAR review\.$/
    );
    assert.match(updated.live_text_entries[1].text, /^VAR Decision: No Goal Leeds United 0-0 Norwich City\.$/);
  } finally {
    state.deleteMatch(match.id);
  }
});
