"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const express = require("express");

const {
  StadiumArtworkCatalogError,
  createCatalogLoader,
  registerStadiumArtworkRoutes,
  validateCatalog,
} = require("./stadium_artwork");

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "stadium-artwork-"));
  const bytes = Buffer.from("published-webp-fixture");
  const hash = crypto.createHash("sha256").update(bytes).digest("hex");
  fs.mkdirSync(path.join(root, "assets"));
  fs.writeFileSync(path.join(root, "assets", `${hash}.webp`), bytes);
  const catalog = {
    schema_version: 1,
    catalog_version: "a".repeat(64),
    generated_at: "2026-08-27T00:00:00Z",
    teams: {
      "afc-bournemouth": {
        name: "AFC Bournemouth",
        aliases: ["Bournemouth"],
        source_team_ids: ["1044"],
        venue_ids: [],
      },
    },
    assets: [{
      id: "bournemouth-day-01",
      role: "team",
      light_context: "day",
      team_ids: ["afc-bournemouth"],
      stadium: "Vitality Stadium",
      sha256: hash,
      asset_path: `assets/${hash}.webp`,
      content_type: "image/webp",
      byte_size: bytes.length,
      width: 640,
      height: 360,
      credit: {
        author: "Top Scores",
        author_url: null,
        source: "Top Scores",
        source_page: null,
        license: "Top Scores artwork",
        license_url: null,
        attribution: "Top Scores artwork",
      },
    }],
  };
  fs.writeFileSync(path.join(root, "catalog.json"), `${JSON.stringify(catalog)}\n`);
  return { root, bytes, hash, catalog };
}

async function withServer(root, body, options = {}) {
  const app = express();
  registerStadiumArtworkRoutes(app, { rootDirectory: root, ...options });
  const server = http.createServer(app);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const address = server.address();
    return await body(`http://127.0.0.1:${address.port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

test("catalog route returns URLs, immutable assets, and conditional 304", async () => {
  const item = fixture();
  try {
    await withServer(item.root, async (origin) => {
      const catalogResponse = await fetch(`${origin}/api/v1/stadium-artwork/catalog`);
      assert.equal(catalogResponse.status, 200);
      assert.equal(catalogResponse.headers.get("etag"), `"${item.catalog.catalog_version}"`);
      const payload = await catalogResponse.json();
      assert.equal(
        payload.assets[0].asset_url,
        `/api/v1/stadium-artwork/assets/${item.hash}.webp`
      );

      const notModified = await fetch(`${origin}/api/v1/stadium-artwork/catalog`, {
        headers: { "If-None-Match": `"${item.catalog.catalog_version}"` },
      });
      assert.equal(notModified.status, 304);

      const assetResponse = await fetch(
        `${origin}/api/v1/stadium-artwork/assets/${item.hash}.webp`
      );
      assert.equal(assetResponse.status, 200);
      assert.equal(assetResponse.headers.get("cache-control"), "public, max-age=31536000, immutable");
      assert.deepEqual(Buffer.from(await assetResponse.arrayBuffer()), item.bytes);
    });
  } finally {
    fs.rmSync(item.root, { recursive: true, force: true });
  }
});

test("asset route rejects traversal-like and missing hashes", async () => {
  const item = fixture();
  try {
    await withServer(item.root, async (origin) => {
      assert.equal((await fetch(`${origin}/api/v1/stadium-artwork/assets/not-a-hash.webp`)).status, 400);
      assert.equal((await fetch(`${origin}/api/v1/stadium-artwork/assets/${"b".repeat(64)}.webp`)).status, 404);
    });
  } finally {
    fs.rmSync(item.root, { recursive: true, force: true });
  }
});

test("loader retains the last valid catalog after an invalid replacement", () => {
  const item = fixture();
  try {
    const loader = createCatalogLoader(item.root);
    const first = loader.load();
    fs.writeFileSync(path.join(item.root, "catalog.json"), "{ invalid json");
    const second = loader.load();
    assert.equal(second.value.catalog_version, first.value.catalog_version);
  } finally {
    fs.rmSync(item.root, { recursive: true, force: true });
  }
});

test("validation rejects unknown team assignments", () => {
  const item = fixture();
  try {
    item.catalog.assets[0].team_ids = ["unknown-team"];
    assert.throws(
      () => validateCatalog(item.catalog, item.root),
      StadiumArtworkCatalogError
    );
  } finally {
    fs.rmSync(item.root, { recursive: true, force: true });
  }
});

test("team directories keep existing hash URLs working without flat files", async () => {
  const item = fixture();
  try {
    const asset = item.catalog.assets[0];
    const oldPath = path.join(item.root, asset.asset_path);
    asset.asset_path = `assets/afc-bournemouth-2/${item.hash}.webp`;
    fs.mkdirSync(path.dirname(path.join(item.root, asset.asset_path)), { recursive: true });
    fs.renameSync(oldPath, path.join(item.root, asset.asset_path));
    fs.writeFileSync(path.join(item.root, "catalog.json"), JSON.stringify(item.catalog));
    await withServer(item.root, async (origin) => {
      const catalog = await (await fetch(`${origin}/api/v1/stadium-artwork/catalog`)).json();
      assert.equal(catalog.assets[0].asset_path, asset.asset_path);
      const response = await fetch(`${origin}${catalog.assets[0].asset_url}`);
      assert.equal(response.status, 200);
      assert.deepEqual(Buffer.from(await response.arrayBuffer()), item.bytes);
    });
  } finally {
    fs.rmSync(item.root, { recursive: true, force: true });
  }
});

test("nested catalogue paths reject traversal and filenames with the wrong hash", () => {
  const item = fixture();
  try {
    for (const folder of ["../escape", "team/../../escape", "team%2fescape", "/tmp"]) {
      item.catalog.assets[0].asset_path = `assets/${folder}/${item.hash}.webp`;
      assert.throws(() => validateCatalog(item.catalog, item.root, { verifyFiles: false }), /invalid asset_path/);
    }
    item.catalog.assets[0].asset_path = `assets/team-9/${"b".repeat(64)}.webp`;
    assert.throws(() => validateCatalog(item.catalog, item.root, { verifyFiles: false }), /invalid asset_path/);
  } finally {
    fs.rmSync(item.root, { recursive: true, force: true });
  }
});

test("optional focal points are passed through and invalid coordinates are rejected", () => {
  const item = fixture();
  try {
    item.catalog.assets[0].focal_point = { x: 0.3, y: 0.7 };
    fs.writeFileSync(path.join(item.root, "catalog.json"), JSON.stringify(item.catalog));
    assert.deepEqual(createCatalogLoader(item.root).load().value.assets[0].focal_point, { x: 0.3, y: 0.7 });
    for (const value of [-1, 1.1, NaN, "0.5", null, true]) {
      item.catalog.assets[0].focal_point.x = value;
      assert.throws(() => validateCatalog(item.catalog, item.root), /invalid focal_point/);
    }
  } finally {
    fs.rmSync(item.root, { recursive: true, force: true });
  }
});


test("admin deletion is authenticated, version-checked, idempotent and survives stale redeployment", async () => {
  const item = fixture();
  try {
    await withServer(item.root, async (origin) => {
      const route = `${origin}/api/v1/stadium-artwork/admin/assets/${item.catalog.assets[0].id}`;
      const headers = { Authorization: "Bearer test-admin-key", "If-Match": `"${item.hash}"` };
      assert.equal((await fetch(route, { method: "DELETE" })).status, 403);
      assert.equal((await fetch(route, { method: "DELETE", headers: { ...headers, Authorization: "Bearer wrong" } })).status, 403);
      assert.equal((await fetch(route, { method: "DELETE", headers: { ...headers, "If-Match": `"${"b".repeat(64)}"` } })).status, 409);
      assert.equal(fs.existsSync(`${item.root}.deletions.json`), false);
      const response = await fetch(route, { method: "DELETE", headers });
      assert.equal(response.status, 200);
      const updated = await response.json();
      assert.equal(updated.assets.length, 0);
      assert.notEqual(updated.catalog_version, item.catalog.catalog_version);
      assert.equal(fs.existsSync(path.join(item.root, item.catalog.assets[0].asset_path)), false);
      assert.equal((await fetch(route, { method: "DELETE", headers })).status, 200);
      assert.equal(JSON.parse(fs.readFileSync(`${item.root}.deletions.json`)).length, 1);
      // Simulate rsync restoring both the old catalogue and the removed image.
      fs.writeFileSync(path.join(item.root, item.catalog.assets[0].asset_path), item.bytes);
      fs.writeFileSync(path.join(item.root, "catalog.json"), JSON.stringify(item.catalog));
      assert.equal((await fetch(`${origin}/api/v1/stadium-artwork/assets/${item.hash}.webp`)).status, 404);
      const fresh = await fetch(`${origin}/api/v1/stadium-artwork/catalog`, {
        headers: { "If-None-Match": `"${item.catalog.catalog_version}"`, "If-Modified-Since": new Date(Date.now() + 60000).toUTCString() },
      });
      assert.equal(fresh.status, 200);
      assert.equal((await fresh.json()).assets.length, 0);
      assert.equal(createCatalogLoader(item.root).load().value.assets.length, 0);
      // An invalid replacement must not bypass the deletion record either.
      fs.writeFileSync(path.join(item.root, "catalog.json"), "bad json");
      assert.equal((await (await fetch(`${origin}/api/v1/stadium-artwork/catalog`)).json()).assets.length, 0);
    }, { adminToken: "test-admin-key" });
  } finally {
    fs.rmSync(item.root, { recursive: true, force: true });
    fs.rmSync(`${item.root}.deletions.json`, { force: true });
  }
});

test("admin is disabled without a configured key and a corrupt deletion record fails closed", async () => {
  const item = fixture();
  try {
    await withServer(item.root, async (origin) => {
      assert.equal((await fetch(`${origin}/api/v1/stadium-artwork/admin/assets/bournemouth-day-01`, { method: "DELETE" })).status, 503);
      await fetch(`${origin}/api/v1/stadium-artwork/catalog`);
      fs.writeFileSync(`${item.root}.deletions.json`, "invalid");
      assert.equal((await fetch(`${origin}/api/v1/stadium-artwork/catalog`)).status, 503);
      assert.equal((await fetch(`${origin}/api/v1/stadium-artwork/assets/${item.hash}.webp`)).status, 503);
    }, { adminToken: "" });
  } finally {
    fs.rmSync(item.root, { recursive: true, force: true });
    fs.rmSync(`${item.root}.deletions.json`, { force: true });
  }
});

test("deleting a photograph removes every assignment and replacement of the same source", async () => {
  const item = fixture();
  try {
    const asset = item.catalog.assets[0];
    asset.credit.source_page = "https://commons.wikimedia.org/wiki/File:Example.jpg";
    item.catalog.assets.push({ ...asset, id: "another-team-image" });
    fs.writeFileSync(path.join(item.root, "catalog.json"), JSON.stringify(item.catalog));
    await withServer(item.root, async (origin) => {
      const response = await fetch(`${origin}/api/v1/stadium-artwork/admin/assets/${asset.id}`, {
        method: "DELETE", headers: { Authorization: "Bearer test-admin-key", "If-Match": `"${item.hash}"` },
      });
      assert.equal(response.status, 200);
      assert.equal((await response.json()).assets.length, 0);
      const replacement = { ...asset, id: "reprocessed-photo", sha256: "c".repeat(64), asset_path: `assets/${"c".repeat(64)}.webp` };
      item.catalog.assets = [replacement];
      fs.writeFileSync(path.join(item.root, "catalog.json"), JSON.stringify(item.catalog));
      assert.equal(createCatalogLoader(item.root).load().value.assets.length, 0);
    }, { adminToken: "test-admin-key" });
  } finally {
    fs.rmSync(item.root, { recursive: true, force: true });
    fs.rmSync(`${item.root}.deletions.json`, { force: true });
  }
});


test("new removals apply to a cached catalogue while the deployment catalogue is absent", () => {
  const item = fixture();
  try {
    const loader = createCatalogLoader(item.root);
    assert.equal(loader.load().value.assets.length, 1);
    fs.unlinkSync(path.join(item.root, "catalog.json"));
    assert.equal(loader.load().value.assets.length, 1);
    fs.writeFileSync(`${item.root}.deletions.json`, JSON.stringify([{ id: item.catalog.assets[0].id, sha256: item.hash }]));
    assert.equal(loader.load().value.assets.length, 0);
  } finally {
    fs.rmSync(item.root, { recursive: true, force: true });
    fs.rmSync(`${item.root}.deletions.json`, { force: true });
  }
});
