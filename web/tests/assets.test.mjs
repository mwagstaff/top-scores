import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import { createTeamLogoResolver, normalizedKey } from "../team-logos.mjs";

const root = new URL("../public/generated-assets/", import.meta.url);
const manifest = JSON.parse(fs.readFileSync(new URL("team-logo-manifest.json", root)));
const resolve = createTeamLogoResolver(fileURLToPath(root));

test("every bundled crest and identity alias resolves to a decodable image", async () => {
  for (const entry of manifest) {
    const expected = fileURLToPath(new URL(entry.relativePath, root));
    assert.equal(resolve(entry.name), expected, entry.name);
    const { info } = await sharp(expected).raw().toBuffer({ resolveWithObject: true });
    assert.ok(info.width > 0 && info.height > 0, entry.name);
    for (const alias of entry.aliases) assert.ok(resolve(alias), alias);
  }
});

test("all iOS identities with a bundled crest resolve without a sibling API checkout", () => {
  const catalog = JSON.parse(fs.readFileSync(new URL("../../ios/Top Scores/Top Scores/team_colors.json", import.meta.url)));
  const keys = new Set(manifest.map((entry) => normalizedKey(entry.name)));
  for (const entry of [...catalog.teams, ...catalog.identity_groups]) {
    const names = [entry.name, ...entry.aliases];
    if (!names.some((name) => keys.has(normalizedKey(name)))) continue;
    for (const name of names) assert.ok(resolve(name), `${entry.name}: ${name}`);
  }
});

test("full club names, international aliases and numeric tokens select the correct crest", () => {
  for (const [name, filename] of [
    ["Bolton Wanderers", "bolton.png"],
    ["Charlton Athletic", "charlton.png"],
    ["Lincoln City", "lincoln.png"],
    ["Cardiff City", "cardiff.png"],
    ["1. FSV Mainz 05", "1-fsvmainz-5.png"],
    ["Czechia", "czech-republic.png"],
    ["Türkiye", "turkey.png"],
    ["GNK Dinamo Zagreb", "dinamo.png"],
    ["Sporting Lisbon", "sporting-cp.png"],
  ]) assert.equal(path.basename(resolve(name)), filename, name);
  assert.equal(resolve("Unknown FC", "Bolton"), resolve("Bolton"));
  assert.equal(resolve("TBC"), null);
  assert.equal(resolve(""), null);
});
test("bundled website crests include the iOS identities missing from the old snapshot", () => {
  for (const name of ["RC Lens", "Club Brugge", "Viking FK"]) {
    const entry = manifest.find(item => item.name === name);
    assert.ok(entry, name);
    const png = fs.readFileSync(new URL(entry.relativePath, root));
    assert.equal(png.subarray(1, 4).toString(), "PNG");
    assert.ok(png.readUInt32BE(16) <= 96 && png.readUInt32BE(20) <= 96, name);
  }
});
