"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const sharp = require("sharp");
const { normalizeTeamLogo, r2Configuration, OUTPUT_SIZES, TeamLogoStorageError } = require("./goal_guesser_images");

test("R2 configuration uses Goal Guessers variables and defaults the bucket", () => {
  const config = r2Configuration({
    CLOUDFLARE_R2_S3_API_GOAL_GUESSERS: "https://example.r2.cloudflarestorage.com/",
    CLOUDFLARE_R2_ACCESS_KEY_GOAL_GUESSERS: "access",
    CLOUDFLARE_R2_SECRET_ACCESS_KEY_GOAL_GUESSERS: "secret",
  });
  assert.equal(config.endpoint, "https://example.r2.cloudflarestorage.com");
  assert.equal(config.bucket, "goal-guessers");
  assert.equal(config.configured, true);
});

test("team logos are normalized to metadata-free square PNG variants", async () => {
  const input = await sharp({ create: { width: 900, height: 600, channels: 4, background: "#1e5b3a" } })
    .jpeg()
    .withMetadata({ exif: { IFD0: { Artist: "private" } } })
    .toBuffer();
  const result = await normalizeTeamLogo(input);
  assert.deepEqual(Object.keys(result.variants).sort(), Object.keys(OUTPUT_SIZES).sort());
  for (const [name, size] of Object.entries(OUTPUT_SIZES)) {
    const metadata = await sharp(result.variants[name].data).metadata();
    assert.equal(metadata.format, "png");
    assert.equal(metadata.width, size);
    assert.equal(metadata.height, size);
    assert.equal(metadata.exif, undefined);
  }
});

test("team logo normalization rejects unsupported and tiny inputs", async () => {
  await assert.rejects(() => normalizeTeamLogo(Buffer.from("not an image")), (error) => error instanceof TeamLogoStorageError && error.status === 415);
  const tiny = await sharp({ create: { width: 8, height: 8, channels: 3, background: "red" } }).png().toBuffer();
  await assert.rejects(() => normalizeTeamLogo(tiny), (error) => error instanceof TeamLogoStorageError && error.status === 400);
});
