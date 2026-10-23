const test = require("node:test");
const assert = require("node:assert/strict");
const { __testHooks } = require("./match_monitor");

const nowMs = Date.parse("2026-10-22T13:43:00Z");
const fixture = {
  match_details_id: "jablonec-brighton",
  date: "2026-10-22",
  time: "17:45",
  league: "UEFA Conference League",
  home_team: "FK Jablonec",
  away_team: "Brighton & Hove Albion",
};

for (const mode of ["single_upcoming", "multi_upcoming", "single_live", "multi_live", "single_finished", "multi_finished"]) {
  test(`${mode} selects TNT ahead of HBO Max for string and structured broadcasts`, () => {
    for (const tv_channels of [
      ["HBO Max", "TNT Sports 2"],
      ["TNT Sports 2", "HBO Max"],
      [{ name: "HBO Max", countryCode: "GB" }, { name: "TNT Sports 2", countryCode: "GB" }],
    ]) {
      const content = __testHooks.buildLiveActivityContentState(mode, [{ ...fixture, tv_channels }], 2, nowMs);
      assert.deepEqual(content.matches[0].tvChannels, ["TNT Sports"]);
      assert.equal(content.matches[0].tvLogoKey, "tnt");
    }
  });
}

test("Live Activity channel filtering preserves shared ordering and respects selected channels", () => {
  const match = { ...fixture, tv_channels: ["HBO Max", "TNT Sports 2", "BBC One"] };
  for (const [selectedChannels, expectedChannels, expectedLogo] of [
    [["HBO Max", "TNT Sports"], ["TNT Sports", "HBO Max"], "tnt"],
    [["HBO Max"], ["HBO Max"], "hbomax"],
  ]) {
    const matches = __testHooks.filterCanonicalLiveActivityMatchesForUser([match], {
      preferences: { channelFilterEnabled: true, selectedChannels },
    }, nowMs);
    assert.deepEqual(matches[0].tv_channels, expectedChannels);
    const content = __testHooks.buildLiveActivityContentState("multi_upcoming", matches, 2, nowMs);
    assert.equal(content.matches[0].tvLogoKey, expectedLogo);
  }
  assert.deepEqual(match.tv_channels, ["HBO Max", "TNT Sports 2", "BBC One"]);
});

test("Live Activity keeps HBO Max when it is the only broadcaster", () => {
  const content = __testHooks.buildLiveActivityContentState("multi_upcoming", [
    { ...fixture, tv_channels: ["HBO Max"] },
  ], 2, nowMs);
  assert.deepEqual(content.matches[0].tvChannels, ["HBO Max"]);
  assert.equal(content.matches[0].tvLogoKey, "hbomax");
});
