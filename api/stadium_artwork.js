"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const CATALOG_SCHEMA_VERSION = 1;
const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const ASSET_ID_PATTERN = /^[a-z0-9][a-z0-9-]{1,79}$/;
const VALID_ROLES = new Set(["generic_backdrop", "generic_match", "team"]);
const VALID_LIGHT_CONTEXTS = new Set(["any", "day", "night"]);

class StadiumArtworkCatalogError extends Error {
  constructor(message) {
    super(message);
    this.name = "StadiumArtworkCatalogError";
  }
}

function validateCatalog(value, rootDirectory, options = {}) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new StadiumArtworkCatalogError("catalog must be an object");
  }
  if (value.schema_version !== CATALOG_SCHEMA_VERSION) {
    throw new StadiumArtworkCatalogError("unsupported catalog schema_version");
  }
  if (!SHA256_PATTERN.test(String(value.catalog_version || ""))) {
    throw new StadiumArtworkCatalogError("catalog_version must be a SHA-256 value");
  }
  if (!value.teams || typeof value.teams !== "object" || Array.isArray(value.teams)) {
    throw new StadiumArtworkCatalogError("catalog teams must be an object");
  }
  if (!Array.isArray(value.assets)) {
    throw new StadiumArtworkCatalogError("catalog assets must be an array");
  }

  const teamIDs = new Set(Object.keys(value.teams));
  const assetIDs = new Set();
  value.assets.forEach((asset) => {
    const assetID = String(asset && asset.id || "");
    const sha256 = String(asset && asset.sha256 || "");
    if (!ASSET_ID_PATTERN.test(assetID)) {
      throw new StadiumArtworkCatalogError(`invalid asset id: ${assetID || "<empty>"}`);
    }
    if (assetIDs.has(assetID)) {
      throw new StadiumArtworkCatalogError(`duplicate asset id: ${assetID}`);
    }
    assetIDs.add(assetID);
    if (!VALID_ROLES.has(asset.role)) {
      throw new StadiumArtworkCatalogError(`invalid role for asset ${assetID}`);
    }
    if (!VALID_LIGHT_CONTEXTS.has(asset.light_context)) {
      throw new StadiumArtworkCatalogError(`invalid light_context for asset ${assetID}`);
    }
    if (!SHA256_PATTERN.test(sha256)) {
      throw new StadiumArtworkCatalogError(`invalid sha256 for asset ${assetID}`);
    }
    if (asset.focal_point != null && ["x", "y"].some((axis) => {
      const coordinate = asset.focal_point[axis];
      return typeof coordinate !== "number" || !Number.isFinite(coordinate) || coordinate < 0 || coordinate > 1;
    })) {
      throw new StadiumArtworkCatalogError(`invalid focal_point for asset ${assetID}`);
    }
    if (!new RegExp(`^assets/(?:[a-z0-9][a-z0-9-]*/)?${sha256}\\.webp$`).test(asset.asset_path)) {
      throw new StadiumArtworkCatalogError(`invalid asset_path for asset ${assetID}`);
    }
    if (!Array.isArray(asset.team_ids)) {
      throw new StadiumArtworkCatalogError(`team_ids must be an array for asset ${assetID}`);
    }
    asset.team_ids.forEach((teamID) => {
      if (!teamIDs.has(String(teamID))) {
        throw new StadiumArtworkCatalogError(`unknown team ${teamID} for asset ${assetID}`);
      }
    });
    if (!asset.credit || typeof asset.credit !== "object") {
      throw new StadiumArtworkCatalogError(`missing credit for asset ${assetID}`);
    }
    ["author", "source", "license", "attribution"].forEach((field) => {
      if (!String(asset.credit[field] || "").trim()) {
        throw new StadiumArtworkCatalogError(`missing ${field} for asset ${assetID}`);
      }
    });
    if (options.verifyFiles !== false) {
      const filePath = path.join(rootDirectory, asset.asset_path);
      if (!fs.statSync(filePath, { throwIfNoEntry: false })?.isFile()) {
        throw new StadiumArtworkCatalogError(`missing image for asset ${assetID}`);
      }
    }
  });
  return value;
}

// Kept beside the deployment root so replacing an artwork bundle cannot undo removals.
function deletionPath(rootDirectory) { return `${rootDirectory}.deletions.json`; }

function readDeletions(rootDirectory) {
  const file = deletionPath(rootDirectory);
  if (!fs.existsSync(file)) return [];
  const value = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!Array.isArray(value) || value.some((entry) =>
    !ASSET_ID_PATTERN.test(entry.id) || !SHA256_PATTERN.test(entry.sha256))) {
    throw new StadiumArtworkCatalogError("Invalid artwork deletion record");
  }
  return value;
}

function isDeleted(asset, deletions) {
  return deletions.some((entry) => entry.id === asset.id || entry.sha256 === asset.sha256
    || (entry.source_page && entry.source_page === asset.credit?.source_page));
}

function createCatalogLoader(rootDirectory) {
  const catalogPath = path.join(rootDirectory, "catalog.json");
  let cachedSignature = null;
  let lastValid = null;

  function load() {
    // Read outside the replacement-catalog fallback: a corrupt deletion record must fail closed.
    const deletions = readDeletions(rootDirectory);
    const stat = fs.statSync(catalogPath, { throwIfNoEntry: false });
    const signature = `${stat?.mtimeMs ?? "missing"}:${stat?.size ?? 0}:${JSON.stringify(deletions)}`;
    if (lastValid && cachedSignature === signature) return lastValid;
    let value;
    try {
      value = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
      validateCatalog(value, rootDirectory, { verifyFiles: false });
      value = { ...value, assets: value.assets.filter((asset) => !isDeleted(asset, deletions)) };
      validateCatalog(value, rootDirectory);
    } catch (error) {
      if (!lastValid) throw error;
      console.warn("[stadium-artwork] Ignoring invalid replacement catalog:", error.message || error);
      value = { ...lastValid.value, assets: lastValid.value.assets.filter((asset) => !isDeleted(asset, deletions)) };
    }
    if (deletions.length) {
      value.catalog_version = crypto.createHash("sha256")
        .update(JSON.stringify({ teams: value.teams, assets: value.assets.map(({ asset_url, ...asset }) => asset), deletions }))
        .digest("hex");
    }
    const assets = value.assets.map((asset) => ({
      ...asset, asset_url: `/api/v1/stadium-artwork/assets/${asset.sha256}.webp`,
    }));
    const deletionStat = fs.statSync(deletionPath(rootDirectory), { throwIfNoEntry: false });
    lastValid = {
      value: { ...value, assets },
      assetPaths: new Map(assets.map((asset) => [asset.sha256, asset.asset_path])),
      etag: `"${value.catalog_version}"`,
      lastModified: new Date(Math.max(stat?.mtimeMs || 0, deletionStat?.mtimeMs || 0)),
    };
    cachedSignature = signature;
    return lastValid;
  }
  return { load, catalogPath };
}

function requestIsNotModified(req, catalog) {
  const ifNoneMatch = String(req.get("If-None-Match") || "").trim();
  if (ifNoneMatch) {
    return ifNoneMatch.split(",").map((value) => value.trim()).includes(catalog.etag);
  }
  const ifModifiedSince = Date.parse(String(req.get("If-Modified-Since") || ""));
  return Number.isFinite(ifModifiedSince)
    && Math.floor(catalog.lastModified.getTime() / 1000) <= Math.floor(ifModifiedSince / 1000);
}

function registerStadiumArtworkRoutes(app, options = {}) {
  const apiPrefix = options.apiPrefix || "/api/v1";
  const rootDirectory = path.resolve(
    options.rootDirectory || process.env.STADIUM_ARTWORK_ROOT || path.join(__dirname, "stadium-artwork")
  );
  const loader = options.loader || createCatalogLoader(rootDirectory);

  const adminToken = options.adminToken ?? process.env.STADIUM_ARTWORK_ADMIN_TOKEN ?? "";
  app.delete(`${apiPrefix}/stadium-artwork/admin/assets/:id`, (req, res) => {
    res.set("Cache-Control", "no-store");
    if (!adminToken) return res.status(503).json({ error: "Artwork administration is not configured." });
    const supplied = String(req.get("Authorization") || "");
    const digest = (token) => crypto.createHash("sha256").update(token).digest();
    if (!crypto.timingSafeEqual(digest(supplied), digest(`Bearer ${adminToken}`))) {
      return res.status(403).json({ error: "Invalid artwork admin key." });
    }
    const id = String(req.params.id || "");
    const hash = String(req.get("If-Match") || "").replace(/^"|"$/g, "");
    if (!ASSET_ID_PATTERN.test(id) || !SHA256_PATTERN.test(hash)) {
      return res.status(400).json({ error: "An image ID and its current SHA-256 are required." });
    }
    const lock = `${deletionPath(rootDirectory)}.lock`;
    let locked = false;
    try {
      fs.mkdirSync(lock);
      locked = true;
      const deletions = readDeletions(rootDirectory);
      const catalog = loader.load();
      const asset = catalog?.value.assets.find((item) => item.id === id);
      if (!asset && !deletions.some((item) => item.id === id && item.sha256 === hash)) {
        return res.status(404).json({ error: "Stadium artwork was not found. Refresh the catalogue." });
      }
      if (asset && asset.sha256 !== hash) {
        return res.status(409).json({ error: "This image has changed. Refresh before deleting it." });
      }
      if (asset) {
        deletions.push({ id, sha256: hash, source_page: asset.credit.source_page || null,
          deleted_at: new Date().toISOString() });
        const temporary = `${deletionPath(rootDirectory)}.${crypto.randomUUID()}.tmp`;
        fs.writeFileSync(temporary, JSON.stringify(deletions, null, 2) + "\n", { mode: 0o600 });
        fs.renameSync(temporary, deletionPath(rootDirectory));
        // Save the record before touching files. A failed unlink remains inaccessible.
        for (const removed of catalog.value.assets.filter((item) => isDeleted(item, deletions))) {
          try { fs.rmSync(path.join(rootDirectory, removed.asset_path), { force: true }); }
          catch (error) { console.warn("[stadium-artwork] Removed image cleanup failed:", error.message); }
        }
      }
      const updated = loader.load();
      res.set("ETag", updated.etag);
      return res.json(updated.value);
    } catch (error) {
      console.warn("[stadium-artwork] Delete failed:", error.message);
      return res.status(error.code === "EEXIST" ? 409 : 503)
        .json({ error: "Could not complete image deletion. Refresh and try again." });
    } finally {
      if (locked) {
        try { fs.rmdirSync(lock); }
        catch (error) { console.warn("[stadium-artwork] Could not release deletion lock:", error.message); }
      }
    }
  });

  app.get(`${apiPrefix}/stadium-artwork/catalog`, (req, res) => {
    let catalog;
    try {
      catalog = loader.load();
    } catch (error) {
      console.warn("[stadium-artwork] Catalog unavailable:", error.message || error);
      res.status(503).json({ error: "Stadium artwork catalog is unavailable." });
      return;
    }
    if (!catalog) {
      res.status(503).json({ error: "Stadium artwork catalog is unavailable." });
      return;
    }
    res.set("Cache-Control", "public, max-age=900, must-revalidate");
    res.set("ETag", catalog.etag);
    res.set("Last-Modified", catalog.lastModified.toUTCString());
    if (requestIsNotModified(req, catalog)) {
      res.status(304).end();
      return;
    }
    res.status(200).json(catalog.value);
  });

  app.get(`${apiPrefix}/stadium-artwork/assets/:hash.webp`, (req, res) => {
    const hash = String(req.params.hash || "").toLowerCase();
    if (!SHA256_PATTERN.test(hash)) {
      res.status(400).json({ error: "Invalid stadium artwork identifier." });
      return;
    }
    // Only active catalogue entries may be served, even if a stale deployment restores a file.
    let relativePath;
    try {
      relativePath = loader.load()?.assetPaths.get(hash);
    } catch (error) {
      return res.status(503).json({ error: "Stadium artwork is unavailable." });
    }
    if (!relativePath) return res.status(404).json({ error: "Stadium artwork was not found." });
    const filePath = path.join(rootDirectory, relativePath);
    if (!fs.statSync(filePath, { throwIfNoEntry: false })?.isFile()) {
      res.status(404).json({ error: "Stadium artwork was not found." });
      return;
    }
    res.set("Cache-Control", "public, max-age=31536000, immutable");
    res.set("Content-Type", "image/webp");
    res.set("ETag", `"${hash}"`);
    res.sendFile(filePath);
  });

  return { rootDirectory, loader };
}

module.exports = {
  CATALOG_SCHEMA_VERSION,
  StadiumArtworkCatalogError,
  validateCatalog,
  createCatalogLoader,
  registerStadiumArtworkRoutes,
};
