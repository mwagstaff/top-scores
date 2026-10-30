import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import vm from "node:vm";

const server = readFileSync(new URL("../server.mjs", import.meta.url), "utf8");
const resolver = server.slice(server.indexOf("function resolveTvLogo("), server.indexOf("function sendTeamPlaceholder("));
const brands = ["ligue 1+", "s4c", "stv", "deetv"];
const resolve = vm.runInNewContext(`${resolver}; resolveTvLogo`, {
  tvLogoIndex: new Map(brands.map(brand => [brand, `${brand}.png`])),
});

test("additional broadcaster aliases resolve to real bundled PNGs", () => {
  const aliases = {
    "ligue 1+": ["Ligue1+", "Ligue 1+ (UK IR)", "Ligue 1 Plus"],
    s4c: ["S4C", "S4C Online"],
    stv: ["STV", "STV Player", "STV Scotland"],
    deetv: ["DeeTV"],
  };
  for (const [brand, names] of Object.entries(aliases)) {
    const asset = new URL(`../public/generated-assets/tv-logos/${brand}.png`, import.meta.url);
    assert.ok(existsSync(asset));
    assert.equal(readFileSync(asset).subarray(1, 4).toString(), "PNG");
    for (const name of names) assert.equal(resolve(name), `${brand}.png`);
  }
  assert.equal(resolve("TBC"), null);
});
