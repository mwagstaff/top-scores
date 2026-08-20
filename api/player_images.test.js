"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  bsdPlayerImageUrl,
  collectMatchLineupTsdbPlayerIds,
  matchDetailsWithBsdPlayerImages,
  playerDetailsWithBsdImage,
} = require("./player_images");

const MAP_DOCS = [
  { _id: "6525", payload: { tsdb_player_id: "34167754" } },
  { _id: "595", payload: { tsdb_player_id: "34161324" } },
];

test("bsdPlayerImageUrl builds only numeric BSD player URLs", () => {
  assert.equal(
    bsdPlayerImageUrl("6525"),
    "https://sports.bzzoiro.com/img/player/6525/"
  );
  assert.equal(bsdPlayerImageUrl("null"), null);
  assert.equal(bsdPlayerImageUrl(""), null);
});

test("matchDetailsWithBsdPlayerImages rewrites mapped TSDB portraits in every lineup area", () => {
  const payload = {
    id: "8324",
    team_lineups: {
      home: {
        starting_lineup: [{ id_player: "34167754", name: "Cameron Burgess", cutout_url: "https://tsdb.test/old.png" }],
        substitutes: [],
        substitutions: [{
          minute: "60'",
          player_off: { id_player: "34167754", name: "Cameron Burgess" },
          player_on: { id_player: "99999999", name: "Unknown" },
        }],
      },
      away: {
        starting_lineup: [{ id_player: "34161324", name: "Vinícius Júnior" }],
        substitutes: [],
        substitutions: [],
      },
    },
  };

  assert.deepEqual(collectMatchLineupTsdbPlayerIds(payload).sort(), ["34161324", "34167754", "99999999"]);
  const result = matchDetailsWithBsdPlayerImages(payload, MAP_DOCS);

  assert.equal(result.team_lineups.home.starting_lineup[0].bsd_player_id, "6525");
  assert.equal(
    result.team_lineups.home.starting_lineup[0].cutout_url,
    "https://sports.bzzoiro.com/img/player/6525/"
  );
  assert.equal(
    result.team_lineups.home.substitutions[0].player_off.cutout_url,
    "https://sports.bzzoiro.com/img/player/6525/"
  );
  assert.equal(result.team_lineups.home.substitutions[0].player_on.cutout_url, null);
  assert.equal(payload.team_lineups.home.starting_lineup[0].cutout_url, "https://tsdb.test/old.png");
});

test("matchDetailsWithBsdPlayerImages uses an existing BSD id without a reverse map", () => {
  const payload = {
    team_lineups: {
      home: {
        starting_lineup: [{ id_player: null, bsd_player_id: "6525", name: "Cameron Burgess" }],
        substitutes: [],
        substitutions: [],
      },
    },
  };
  const result = matchDetailsWithBsdPlayerImages(payload);
  assert.equal(
    result.team_lineups.home.starting_lineup[0].cutout_url,
    "https://sports.bzzoiro.com/img/player/6525/"
  );
});

test("playerDetailsWithBsdImage removes every TSDB image candidate", () => {
  const result = playerDetailsWithBsdImage(
    {
      id: "34167754",
      name: "Cameron Burgess",
      cutout_url: "https://tsdb.test/cutout.png",
      thumb_url: "https://tsdb.test/thumb.png",
      render_url: "https://tsdb.test/render.png",
    },
    "34167754",
    MAP_DOCS
  );
  assert.equal(result.cutout_url, "https://sports.bzzoiro.com/img/player/6525/");
  assert.equal(result.thumb_url, null);
  assert.equal(result.render_url, null);
});

test("playerDetailsWithBsdImage uses an embedded BSD id without a reverse map", () => {
  const result = playerDetailsWithBsdImage({
    id: "34167754",
    bsd_player_id: 6525,
    cutout_url: "https://tsdb.test/cutout.png",
  });

  assert.equal(result.bsd_player_id, "6525");
  assert.equal(result.cutout_url, "https://sports.bzzoiro.com/img/player/6525/");
});
