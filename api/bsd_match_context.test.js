"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { createMatchContextService, projectMatchContext, normalizeH2H, lineupInterval, validateLineups } = require("./bsd_match_context");
const now = Date.parse("2026-11-14T14:00:00Z");
const event = { id: 42, status: "notstarted", event_date: "2026-11-14T15:00:00Z" };
const metadata = { payload: { funfacts: [{ sentence: "A fact." }, { sentence: " A fact. " }], ai_preview: { text: "Preview", generated_at: null } } };

test("kickoff expires cached predictions and preview while retaining facts and confirmed teams", () => {
  const docs = { metadata, lineups: { payload: { lineup_status: "predicted", updated_at: "2026-11-14T12:00:00Z" } } };
  const upcoming = projectMatchContext(event, docs, now);
  assert.equal(upcoming.lineup_status, "predicted");
  assert.equal(upcoming.match_preview.text, "Preview");
  for (const [match, time] of [[event, now + 3600_000], [{ ...event, status: "inprogress" }, now], [{ ...event, status: "postponed" }, now]]) {
    const result = projectMatchContext(match, docs, time);
    assert.equal(result.lineup_status, "unavailable");
    assert.equal(result.match_preview, null);
    assert.deepEqual(result.fun_facts, ["A fact."]);
  }
  docs.lineups.payload.lineup_status = "confirmed";
  assert.equal(projectMatchContext({ ...event, status: "finished" }, docs, now).lineup_status, "confirmed");
});

test("lineup scheduling accelerates at 75 minutes and keeps checking late confirmed corrections", () => {
  const last = { payload: { lineup_status: "predicted" } };
  const at = minutes => ({ ...event, event_date: new Date(now + minutes * 60_000).toISOString() });
  assert.equal(lineupInterval(at(74), last, now), 60_000);
  assert.equal(lineupInterval(at(90), last, now), 300_000);
  assert.equal(lineupInterval(at(180), last, now), 7200_000);
  assert.equal(lineupInterval(at(3 * 1440), last, now), 21600_000);
  assert.equal(lineupInterval(at(15 * 1440), last, now), Infinity);
  assert.equal(lineupInterval(at(30), { payload: { lineup_status: "confirmed" } }, now), 300_000);
});

test("head-to-head keeps orientation, null scores, stable IDs and newest ten unique meetings", () => {
  const rows = Array.from({ length: 12 }, (_, index) => ({ event_id: index + 1, date: `2026-10-${String(index + 1).padStart(2, "0")}T15:00:00Z`,
    home: "Away in today's fixture", away: "Home in today's fixture", home_team_id: 8, away_team_id: 7, home_score: null, away_score: null, score: "0-0" }));
  const result = normalizeH2H({ total_matches: 20, home_wins: 9, away_wins: 7, draws: 4, recent_matches: [...rows, rows[11]] });
  assert.equal(result.home_wins, 9);
  assert.equal(result.recent_matches.length, 10);
  assert.equal(result.recent_matches[0].event_id, "12");
  assert.equal(result.recent_matches[0].home_team_id, "8");
  assert.equal(result.recent_matches[0].home_score, null);
  assert.equal(normalizeH2H({}), null);
});

test("valid unavailable and partial lineups are normal; malformed payloads cannot erase cached teams", () => {
  assert.doesNotThrow(() => validateLineups({ event_id: 42, lineup_status: "unavailable", lineups: null }, "42"));
  assert.doesNotThrow(() => validateLineups({ event_id: 42, lineup_status: "predicted", lineups: { home: { players: [], substitutes: [] }, away: null } }, "42"));
  assert.throws(() => validateLineups({ event_id: 42, lineup_status: "confirmed", lineups: null }, "42"));
  assert.throws(() => validateLineups({ event_id: 43, lineup_status: "unavailable", lineups: null }, "42"));
});

test("cold details return without waiting for BSD; concurrent background refreshes are coalesced", async () => {
  let release, calls = 0;
  const blocked = new Promise(resolve => { release = resolve; });
  const saved = [];
  const service = createMatchContextService({ now: () => now, read: async () => [],
    save: async (...args) => saved.push(args), client: {
      getLineups: async () => ({ event_id: 42, lineup_status: "unavailable", lineups: null }),
      getHeadToHead: async () => { calls++; await blocked; return { total_matches: 0, recent_matches: [] }; },
      getEventMetadata: async () => ({ event_id: 42, funfacts: [], ai_preview: null }),
    } });
  const first = await service.load(event, { refreshInBackground: true });
  await service.load(event, { refreshInBackground: true });
  assert.equal(first.context.head_to_head, null);
  assert.equal(first.context.refresh_after_seconds, 15);
  assert.equal(calls, 1);
  release();
  await service.refresh(event);
  assert.deepEqual(saved.map(args => args[0]), ["bsd_lineups", "bsd_h2h", "bsd_metadata"]);
});

test("historical links require a usable match detail payload, not just a catalogue ID", async () => {
  const service = createMatchContextService({ now: () => now, read: async name => {
    if (name === "bsd_events") return [
      { _id: "3", payload: { id: 3, home_team: "A", away_team: "B", event_date: "2026-01-01T12:00:00Z" } },
      { _id: "4" },
      { _id: "5", payload: { id: 5, home_team: "A", away_team: "B", event_date: "invalid" } },
      { _id: "6", payload: { id: 99, home_team: "A", away_team: "B", event_date: "2026-01-01T12:00:00Z" } },
    ];
    if (name === "bsd_h2h") return [{ payload: { total_matches: 5, recent_matches: [3, 4, 5, 6, 7].map(event_id => ({ event_id, date: "2026-01-01T12:00:00Z", home: "A", away: "B", home_score: 1, away_score: 0 })) } }];
    return [];
  } });
  assert.deepEqual((await service.load(event)).context.head_to_head.recent_matches.map(row => row.match_id), ["3", null, null, null, null]);
});

test("failed optional enrichment retains stored content and backs off", async () => {
  let calls = 0;
  const service = createMatchContextService({ now: () => now, client: { getHeadToHead: async () => { calls++; throw new Error("429"); } } });
  await assert.rejects(service.refresh(event), /429/);
  await service.refresh(event);
  assert.equal(calls, 1);
});

test("opened distant fixtures hydrate lineups and independent context survives a failed resource", async () => {
  const saved = [];
  const service = createMatchContextService({ now: () => now, save: async (name) => saved.push(name), client: {
    getLineups: async () => ({ event_id: 42, lineup_status: "unavailable", lineups: null }),
    getHeadToHead: async () => { throw new Error("H2H unavailable"); },
    getEventMetadata: async () => ({ event_id: 42, funfacts: [], ai_preview: null }),
  } });
  const distant = { ...event, event_date: "2027-01-01T15:00:00Z" };
  assert.equal(service.due("lineups", distant, null), true);
  await assert.rejects(service.refresh(distant, {}, { includeLineups: true }), /H2H unavailable/);
  assert.deepEqual(saved, ["bsd_lineups", "bsd_metadata"]);
});
