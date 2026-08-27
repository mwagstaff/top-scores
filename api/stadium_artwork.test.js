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

async function withServer(root, body) {
  const app = express();
  registerStadiumArtworkRoutes(app, { rootDirectory: root });
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
