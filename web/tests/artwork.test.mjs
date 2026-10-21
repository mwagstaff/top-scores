import test from "node:test";
import assert from "node:assert/strict";
import express from "express";
import sharp from "sharp";
import { registerArtwork } from "../artwork.mjs";
test("artwork variants are bounded, cached and limited to catalogue images", async () => {
  const originalFetch = globalThis.fetch;
  const hash = "a".repeat(64);
  const image = await sharp({
    create: { width: 1000, height: 600, channels: 3, background: "#264432" },
  })
    .webp()
    .toBuffer();
  let imageRequests = 0;
  globalThis.fetch = async (url, options) => {
    if (!String(url).startsWith("https://upstream.test"))
      return originalFetch(url, options);
    if (String(url).endsWith("/catalog"))
      return new Response(
        JSON.stringify({
          schema_version: 1,
          teams: {},
          assets: [
            { id: "test", sha256: hash, role: "generic_match", team_ids: [] },
          ],
        }),
      );
    imageRequests++;
    return new Response(image);
  };
  const app = express();
  registerArtwork(app, "https://upstream.test");
  const server = app.listen(0, "127.0.0.1");
  await new Promise((resolve) => server.once("listening", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const response = await originalFetch(`${base}/artwork/${hash}/480.webp`);
    assert.equal(response.status, 200);
    assert.match(response.headers.get("cache-control"), /immutable/);
    assert.equal(
      (await sharp(Buffer.from(await response.arrayBuffer())).metadata()).width,
      480,
    );
    await originalFetch(`${base}/artwork/${hash}/480.webp`);
    assert.equal(imageRequests, 1);
    assert.equal(
      (await originalFetch(`${base}/artwork/${hash}/99999.webp`)).status,
      404,
    );
    assert.equal(
      (await originalFetch(`${base}/artwork/${"b".repeat(64)}/480.webp`))
        .status,
      404,
    );
    assert.equal(imageRequests, 1);
  } finally {
    globalThis.fetch = originalFetch;
    await new Promise((resolve) => server.close(resolve));
  }
});
