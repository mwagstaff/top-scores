const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createBroadcastPriorities, broadcastPriorities } = require("./broadcast_priorities");

test("provider order is shared for legacy strings and structured iOS/web channels", () => {
  const expected = ["BBC iPlayer", "ITV 4", "Channel 4", "Channel 5", "Sky Sports Football", "TNT Sports 1", "NOW TV UK", "HBO Max", "Premier Sports 1", "DAZN"];
  assert.deepEqual(broadcastPriorities.order([...expected].reverse()), expected);
  const channels = [...expected].reverse().map(name => ({ name, countryCode: "GB", logo: null }));
  assert.deepEqual(broadcastPriorities.order(channels).map(channel => channel.name), expected);
  assert.equal(channels[0].name, "DAZN", "does not mutate cached arrays");
  assert.deepEqual(broadcastPriorities.order(["TNT Sports 4", "TNT Sports 1"]), ["TNT Sports 4", "TNT Sports 1"], "same-provider order stays stable");
});

test("config edits reorder cached match payloads without restarting or changing clients", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "tv-priorities-"));
  const filename = path.join(directory, "config.json");
  const config = { providers: [{ id: "bbc", priority: 10, aliases: ["bbc"] }, { id: "hbo", priority: 20, aliases: ["hbo"] }], other_priority: 1000 };
  fs.writeFileSync(filename, JSON.stringify(config));
  const store = createBroadcastPriorities(filename);
  const cached = { matches: [{ home_team: "Home", tv_channels: ["HBO Max", "BBC One"], watchability_index: { score: 79, stars: 4, tier: "highly_watchable" } }] };
  try {
    assert.equal(store.apply(cached).matches[0].tv_channels[0], "BBC One");
    const before = store.updatedAt;
    config.providers[1].priority = 1;
    fs.writeFileSync(filename, JSON.stringify(config));
    for (let attempt = 0; attempt < 30 && store.apply(cached).matches[0].tv_channels[0] !== "HBO Max"; attempt++) {
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.equal(store.apply(cached).matches[0].tv_channels[0], "HBO Max");
    assert.notEqual(store.updatedAt, before);
    assert.deepEqual(store.apply(cached).matches[0].watchability_index, cached.matches[0].watchability_index);
  } finally { store.close(); fs.rmSync(directory, { recursive: true, force: true }); }
});

test("public API presentation applies ordering after cached payloads and preserves short names", () => {
  const { __private: { applyPublicMatchPresentation } } = require("./server");
  const result = applyPublicMatchPresentation({ home_team: "AZ Alkmaar", home_short_name: "AZ", tv_channels: ["HBO Max", "TNT Sports 7"] }, new Map());
  assert.equal(result.home_short_name, "AZ");
  assert.deepEqual(result.tv_channels, ["TNT Sports 7", "HBO Max"]);
});
