import sharp from "sharp";
import { gzip } from "node:zlib";
import { promisify } from "node:util";
const compress = promisify(gzip);

// Fixed upstream, fixed widths, bounded cache: no arbitrary image proxy or resize surface.
export function registerArtwork(app, apiBaseUrl) {
  let catalog,
    expires = 0,
    catalogRequest;
  const images = new Map();
  const pending = new Map();
  let cacheBytes = 0;
  async function getCatalog() {
    if (catalog && expires > Date.now()) return catalog;
    if (catalogRequest) return catalogRequest;
    catalogRequest = (async () => {
      const response = await fetch(`${apiBaseUrl}/stadium-artwork/catalog`, {
        signal: AbortSignal.timeout(8000),
      });
      if (!response.ok) throw new Error("Artwork unavailable");
      const data = await response.json();
      if (
        data.schema_version !== 1 ||
        !Array.isArray(data.assets) ||
        !data.teams
      )
        throw new Error("Invalid catalogue");
      catalog = {
        teams: data.teams,
        assets: data.assets.map(
          ({ id, sha256, role, team_ids, stadium, focal_point, credit }) => ({
            id,
            sha256,
            role,
            team_ids,
            stadium,
            focal_point,
            credit,
          }),
        ),
      };
      expires = Date.now() + 300_000;
      return catalog;
    })().finally(() => {
      catalogRequest = undefined;
    });
    return catalogRequest;
  }
  app.get("/artwork/catalog", async (req, res) => {
    try {
      const body = JSON.stringify(await getCatalog());
      res
        .set("Cache-Control", "public, max-age=300")
        .vary("Accept-Encoding")
        .type("json");
      if (req.acceptsEncodings("gzip"))
        res.set("Content-Encoding", "gzip").send(await compress(body));
      else res.send(body);
    } catch {
      res.status(503).json({ error: "Stadium artwork unavailable" });
    }
  });
  app.get("/artwork/:hash/:width.webp", async (req, res) => {
    const { hash, width } = req.params;
    if (!/^[a-f0-9]{64}$/.test(hash) || !["480", "960", "1440"].includes(width))
      return res.sendStatus(404);
    try {
      const catalog = await getCatalog();
      if (!catalog.assets.some((asset) => asset.sha256 === hash))
        return res.sendStatus(404);
      const key = `${hash}:${width}`;
      let buffer = images.get(key);
      if (!buffer) {
        let work = pending.get(key);
        if (!work) {
          if (pending.size >= 4) return res.sendStatus(503);
          work = (async () => {
            const upstream = await fetch(
              `${apiBaseUrl}/stadium-artwork/assets/${hash}.webp`,
              { signal: AbortSignal.timeout(10000) },
            );
            if (!upstream.ok) throw new Error("Image unavailable");
            if (Number(upstream.headers.get("content-length")) > 10_000_000)
              throw new Error("Image too large");
            const original = Buffer.from(await upstream.arrayBuffer());
            if (original.length > 10_000_000)
              throw new Error("Image too large");
            const result = await sharp(original, {
              limitInputPixels: 40_000_000,
            })
              .resize({ width: Number(width), withoutEnlargement: true })
              .webp({ quality: 76 })
              .toBuffer();
            while (cacheBytes + result.length > 16_000_000 && images.size) {
              const first = images.keys().next().value;
              cacheBytes -= images.get(first).length;
              images.delete(first);
            }
            images.set(key, result);
            cacheBytes += result.length;
            return result;
          })().finally(() => pending.delete(key));
          pending.set(key, work);
        }
        buffer = await work;
      }
      res
        .set("Cache-Control", "public, max-age=31536000, immutable")
        .type("webp")
        .send(buffer);
    } catch {
      res.sendStatus(503);
    }
  });
}
