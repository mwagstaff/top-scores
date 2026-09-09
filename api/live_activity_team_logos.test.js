const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { __testHooks } = require("./match_monitor");
const { bsdEventToCanonicalMatch } = require("./bsd_adapter");
const catalog = require("./bsd_team_logo_assets.json");

function matchState(overrides = {}) {
  return __testHooks.buildLiveActivityContentState("single_finished", [{
    match_details_id: "crest-regression",
    date: "2026-09-06",
    time: "14:00",
    league: "Premier League",
    home_team: "Everton",
    home_team_id: "20",
    away_team: "Manchester United",
    away_team_id: "17",
    away_short_name: "Man U",
    home_score: 2,
    away_score: 2,
    score_status: "FT",
    ...overrides,
  }], 2, Date.parse("2026-09-06T16:00:00Z")).matches[0];
}

test("Live Activity resolves Manchester United by BSD ID and keeps its display name", () => {
  const state = matchState();
  assert.equal(state.homeLogoKey, "Everton");
  assert.equal(state.awayTeam, "Man U");
  assert.equal(state.awayLogoKey, "Man United");
});

test("BSD event IDs survive canonical projection into the Live Activity payload", () => {
  const match = bsdEventToCanonicalMatch({
    id: 8325,
    league_id: 1,
    home_team_id: 17,
    away_team_id: 12,
    home_team: "Manchester United",
    away_team: "Manchester City",
    home_score: 2,
    away_score: 2,
    status: "finished",
    period: "FT",
    event_date: "2026-09-06T14:00:00Z",
  });
  const state = __testHooks.buildLiveActivityContentState(
    "single_finished", [match], 2, Date.parse("2026-09-06T16:00:00Z")
  ).matches[0];
  assert.equal(state.homeLogoKey, "Man United");
  assert.equal(state.awayLogoKey, "Man City");
});

test("BSD IDs take precedence over conflicting names on both sides", () => {
  const state = matchState({
    home_team_id: 17,
    home_team: "Manchester City",
    home_short_name: "Man City",
    away_team_id: "12",
    away_team: "Manchester United",
  });
  assert.equal(state.homeLogoKey, "Man United");
  assert.equal(state.awayLogoKey, "Man City");
});

test("unmapped BSD IDs never borrow another club's crest from a similar name", () => {
  for (const [id, name] of [
    ["8554", "Reading"], // Reading City, not Reading FC.
    ["4268", "Swindon"], // Swindon Supermarine, not Swindon Town.
    ["669", "Arsenal"], // Arsenal Tivat, not Arsenal FC.
    ["4032", "Oxford"], // Oxford City, not Oxford United.
    ["1460", "Andorra"], // FC Andorra, not the national team.
    ["1686", "Red Star"], // Red Star FC, not Red Star Belgrade.
    ["99999999", "Manchester United"],
  ]) {
    assert.equal(matchState({ away_team_id: id, away_team: name }).awayLogoKey, undefined, id);
  }
});

test("ID-less legacy matches can still resolve Manchester United's existing crest", () => {
  assert.equal(matchState({ away_team_id: null }).awayLogoKey, "Man United");
});

test("South Liverpool FC resolves its dedicated crest rather than Liverpool's", () => {
  assert.equal(
    matchState({ away_team_id: null, away_team: "South Liverpool FC" }).awayLogoKey,
    "South Liverpool FC"
  );
});

test("every mapped BSD ID resolves independently of names to a bundled Live Activity crest", () => {
  const manifest = new Set(require("./team_logo_assets.json"));
  const widgetManifest = new Set(require("../ios/Top Scores/Top Scores Widgets/live_activity_team_logo_assets.json"));
  for (const [id, entry] of Object.entries(catalog.teams)) {
    assert.match(id, /^[1-9]\d*$/);
    assert.ok(entry.name);
    assert.ok(manifest.has(entry.asset_name), `${id}: ${entry.asset_name}`);
    const variant = `${entry.asset_name} Live Activity`;
    assert.ok(widgetManifest.has(variant), variant);
    const directory = path.join(__dirname, "../ios/Top Scores/Media.xcassets/LiveActivityGenerated", `${variant}.imageset`);
    const contents = JSON.parse(fs.readFileSync(path.join(directory, "Contents.json"), "utf8"));
    const image = contents.images.find((image) => image.filename);
    assert.ok(image, variant);
    assert.ok(fs.existsSync(path.join(directory, image.filename)), variant);
    assert.equal(matchState({ away_team_id: id, away_team: "Renamed club", away_short_name: "NEW" }).awayLogoKey, entry.asset_name, id);
  }
});

test("Cambridge United uses its own crest instead of Cambridge City's", () => {
  assert.equal(matchState({ away_team_id: "1413", away_team: "Cambridge United", away_short_name: "Cambridge" }).awayLogoKey, "Cambridge Utd");
});

test("other affected clubs resolve to the correct crest by BSD ID", () => {
  for (const [id, name, asset] of [
    ["11", "Wolverhampton", "Wolves"],
    ["227", "Dundee United", "Dundee Utd"],
    ["93", "1. FSV Mainz 05", "Mainz"],
    ["1293", "SC Paderborn 07", "SC Paderborn 7"],
    ["1834", "VfL Bochum 1848", "VfL Bochum"],
    ["1332", "FC Nordsjælland", "FC Nordsjaelland"],
  ]) {
    assert.equal(matchState({ away_team_id: id, away_team: name }).awayLogoKey, asset, name);
  }
});
