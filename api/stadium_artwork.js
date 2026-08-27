"use strict";

const fs = require("fs");
const path = require("path");

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
    if (asset.asset_path !== `assets/${sha256}.webp`) {
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

function createCatalogLoader(rootDirectory) {
  const catalogPath = path.join(rootDirectory, "catalog.json");
  let cachedSignature = null;
  let lastValid = null;

  function load() {
    const stat = fs.statSync(catalogPath, { throwIfNoEntry: false });
    if (!stat?.isFile()) return lastValid;
    const signature = `${stat.mtimeMs}:${stat.size}`;
    if (lastValid && cachedSignature === signature) return lastValid;

    try {
      const value = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
      validateCatalog(value, rootDirectory);
      const assets = value.assets.map((asset) => ({
        ...asset,
        asset_url: `/api/v1/stadium-artwork/assets/${asset.sha256}.webp`,
      }));
      lastValid = {
        value: { ...value, assets },
        etag: `"${value.catalog_version}"`,
        lastModified: stat.mtime,
      };
      cachedSignature = signature;
    } catch (error) {
      if (!lastValid) throw error;
      console.warn("[stadium-artwork] Ignoring invalid replacement catalog:", error.message || error);
    }
    return lastValid;
  }

  return { load, catalogPath };
}

function requestIsNotModified(req, catalog) {
  const ifNoneMatch = String(req.get("If-None-Match") || "").trim();
  if (ifNoneMatch && ifNoneMatch.split(",").map((value) => value.trim()).includes(catalog.etag)) {
    return true;
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
    const filePath = path.join(rootDirectory, "assets", `${hash}.webp`);
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
