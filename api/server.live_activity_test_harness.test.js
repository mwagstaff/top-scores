const test = require("node:test");
const assert = require("node:assert/strict");

const {
  __private: {
    buildLiveActivityTestContentState,
    buildLiveActivityTestPresets,
    resolveLiveActivityTestPreset,
  },
} = require("./server");

const FIXED_NOW = new Date("2026-03-22T12:00:00.000Z");

test("buildLiveActivityTestPresets exposes the dense footer regression preset", () => {
  const presets = buildLiveActivityTestPresets(FIXED_NOW);
  const densePreset = presets.find((preset) => preset.id === "single_live_trailing_footer");

  assert.ok(densePreset);
  assert.equal(densePreset.payload.mode, "single_live");
  assert.equal(densePreset.payload.delayMinutes, 8);
  assert.equal(densePreset.payload.fantasyCurrentScore, 63);
  assert.equal(densePreset.payload.matches.length, 5);
});

test("resolveLiveActivityTestPreset normalizes dash-separated identifiers", () => {
  const preset = resolveLiveActivityTestPreset("multi-live-dense", FIXED_NOW);

  assert.ok(preset);
  assert.equal(preset.id, "multi_live_dense");
  assert.equal(preset.payload.mode, "multi_live");
});

test("buildLiveActivityTestContentState uses preset defaults and explicit overrides", () => {
  const contentState = buildLiveActivityTestContentState(
    {
      presetId: "single_live_trailing_footer",
      delayMinutes: 3,
      fantasyCurrentScore: 21,
    },
    FIXED_NOW
  );

  assert.equal(contentState.mode, "single_live");
  assert.equal(contentState.delayMinutes, 3);
  assert.equal(contentState.fantasyCurrentScore, 21);
  assert.equal(contentState.matches.length, 5);
  assert.equal(contentState.matches[0].homeTeam, "Atalanta");
  assert.equal(contentState.matches[0].awayTeam, "Dortmund");
  assert.equal(contentState.matches[0].homeLogoKey, "Atalanta");
  assert.equal(contentState.matches[0].awayLogoKey, "Borussia Dortmund");
  assert.equal(contentState.matches[2].homeTeam, "Norwich");
  assert.equal(contentState.matches[2].awayTeam, "Sheff Wed");
  assert.equal(contentState.matches[2].homeLogoKey, "Norwich City");
  assert.equal(contentState.matches[2].awayLogoKey, "Sheff Wed");
});

test("buildLiveActivityTestContentState returns an empty ended payload", () => {
  const contentState = buildLiveActivityTestContentState(
    {
      presetId: "ended",
    },
    FIXED_NOW
  );

  assert.equal(contentState.mode, "ended");
  assert.equal(contentState.delayMinutes, 0);
  assert.equal(contentState.fantasyCurrentScore, undefined);
  assert.deepEqual(contentState.matches, []);
});
