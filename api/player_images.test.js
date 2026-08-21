"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  bsdPlayerImageUrl,
  matchDetailsWithBsdPlayerImages,
  playerDetailsWithBsdImage,
} = require("./player_images");

test("bsdPlayerImageUrl builds only numeric BSD player URLs", () => {
  assert.equal(bsdPlayerImageUrl("6525"), "https://sports.bzzoiro.com/img/player/6525/");
  assert.equal(bsdPlayerImageUrl("null"), null);
  assert.equal(bsdPlayerImageUrl(""), null);
});

test("matchDetailsWithBsdPlayerImages uses direct BSD ids throughout lineups", () => {
  const payload = {
    team_lineups: {
      home: {
        starting_lineup: [{ id_player: "6525", name: "Cameron Burgess" }],
        substitutes: [],
        substitutions: [{
          minute: "60'",
          player_off: { id_player: "6525", name: "Cameron Burgess" },
          player_on: { bsd_player_id: "595", name: "Vinícius Júnior" },
        }],
      },
    },
  };

  const result = matchDetailsWithBsdPlayerImages(payload);
  assert.equal(result.team_lineups.home.starting_lineup[0].bsd_player_id, "6525");
  assert.equal(result.team_lineups.home.starting_lineup[0].cutout_url, "https://sports.bzzoiro.com/img/player/6525/");
  assert.equal(result.team_lineups.home.substitutions[0].player_off.cutout_url, "https://sports.bzzoiro.com/img/player/6525/");
  assert.equal(result.team_lineups.home.substitutions[0].player_on.cutout_url, "https://sports.bzzoiro.com/img/player/595/");
});

test("playerDetailsWithBsdImage uses the direct BSD id and clears alternate images", () => {
  const result = playerDetailsWithBsdImage(
    {
      id: "6525",
      name: "Cameron Burgess",
      thumb_url: "https://example.test/thumb.png",
      render_url: "https://example.test/render.png",
    },
    "6525"
  );

  assert.equal(result.bsd_player_id, "6525");
  assert.equal(result.cutout_url, "https://sports.bzzoiro.com/img/player/6525/");
  assert.equal(result.thumb_url, null);
  assert.equal(result.render_url, null);
});
