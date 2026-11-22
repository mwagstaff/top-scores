const test = require("node:test");
const assert = require("node:assert/strict");
const { createNextGoalIngestor, projectNextGoal, forecast } = require("./bsd_next_goal");
const read = require("../.helper_files/bsd_api/next_goal.json");
const call = require("../.helper_files/bsd_api/next_goal_calls.json");
const id = String(read.event.id);
const start = Date.parse(read.generated_at);
const event = { ...read.event, current_minute: read.minute };
const match = { score_status: String(read.minute), home_score: read.score.home, away_score: read.score.away,
  home_team: read.event.home_team, away_team: read.event.away_team };

test("repeated live reads advance coverage without a forecast write, including across restart", async () => {
  const docs = new Map(), writes = [];
  let now = start, rows = [read], error = null, requests = 0;
  const deps = { now: () => now, get: async () => [...docs.values()],
    save: async (collection, key, payload) => {
      docs.set(key, { _id: key, payload }); writes.push(key);
    }, client: { getNextGoal: async () => { requests++; if (error) throw error; return rows; } } };
  await createNextGoalIngestor(deps).reads();
  now += 200_000;
  rows = [read, { ...read, event: { id: 22, league_id: -1 } }];
  const ingestor = createNextGoalIngestor(deps);
  await ingestor.reads();
  const view = () => projectNextGoal([...docs.values()], [], event, match, now);
  assert.deepEqual(writes, [id, "coverage", "coverage"]);
  assert.equal(view().status, "available");
  now += 181_000;
  assert.equal(view().message, "Updating…");
  error = Object.assign(new Error("forbidden"), { statusCode: 403 });
  await ingestor.reads();
  await ingestor.reads();
  assert.equal(requests, 3);
  error = null; now += 3_600_001; rows = [];
  await ingestor.reads();
  assert.equal(requests, 4);
  assert.equal(view().message, "Updating…");
});

test("score mismatch, provider pause, and a strong call have distinct messages", () => {
  function view(overrides, current = match) {
    return projectNextGoal([{ _id: id, payload: { ...forecast(read), ...overrides } },
      { _id: "coverage", payload: { [id]: start } }], [], event, current, start);
  }
  assert.equal(view({ is_call: true, call_paused: false }).message, "Strong call");
  assert.equal(view({ call_paused: true }).message, "Paused after goal");
  assert.equal(view({}, { ...match, home_score: match.home_score + 1 }).message, "Updating after goal…");
  assert.equal(forecast({ ...read, probabilities: { home: 0.3, away: 0.2, no_goal: null } }).probabilities.home, 0.6);
  assert.equal(forecast({ ...read, probabilities: { home: 4, away: 0, no_goal: null } }), null);
});

test("warming up is limited to early allowlisted matches", () => {
  const view = (minute, league_id) => projectNextGoal([], [], { ...event, current_minute: minute, league_id }, match);
  assert.equal(view(8, "1").status, "warming_up");
  assert.equal(view(15, "1"), null);
  assert.equal(view(8, "-1"), null);
});

test("calls upsert by call ID, settle without probabilities and stop requesting refresh", async () => {
  const docs = [];
  const ingestor = createNextGoalIngestor({ get: async () => docs, client: { getNextGoalCalls: async () => [call] },
    save: async (collection, key, payload, extra) => {
      assert.equal(collection, "bsd_next_goal_calls");
      assert.equal(key, String(call.id));
      assert.equal(extra.event_id, String(call.event.id));
      docs.push({ _id: key, payload });
    } });
  await ingestor.calls({ eventId: call.event.id });
  await ingestor.calls({ eventId: call.event.id });
  assert.equal(docs.length, 1);
  const view = now => projectNextGoal([{ _id: "settled:" + id, payload: { at: start } }], docs, event,
    { ...match, score_status: "FT" }, now);
  assert.equal(view(start).calls[0].outcome, "hit");
  assert.match(view(start).calls[0].summary, /Correct/);
  assert.equal(view(start).probabilities, undefined);
  assert.equal(view(start).refresh_after_seconds, 60);
  assert.equal(view(start + 900_000).refresh_after_seconds, null);
  assert.equal(projectNextGoal([], [], event, { ...match, score_status: "FT" }), null);
});
