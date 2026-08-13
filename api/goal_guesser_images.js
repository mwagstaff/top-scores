"use strict";

const crypto = require("crypto");
const sharp = require("sharp");
const { S3Client, PutObjectCommand, GetObjectCommand, DeleteObjectsCommand } = require("@aws-sdk/client-s3");

const MAX_UPLOAD_BYTES = 5 * 1024 * 1024;
const MAX_INPUT_PIXELS = 40_000_000;
const OUTPUT_SIZES = { thumbnail: 128, full: 512 };
const ACCEPTED_FORMATS = new Set(["jpeg", "png", "webp"]);

class TeamLogoStorageError extends Error {
  constructor(message, status = 500) {
    super(message);
    this.name = "TeamLogoStorageError";
    this.status = status;
  }
}

function r2Configuration(environment = process.env) {
  const endpoint = String(environment.CLOUDFLARE_R2_S3_API_GOAL_GUESSERS || "").trim().replace(/\/+$/, "");
  const accessKeyId = String(environment.CLOUDFLARE_R2_ACCESS_KEY_GOAL_GUESSERS || "").trim();
  const secretAccessKey = String(environment.CLOUDFLARE_R2_SECRET_ACCESS_KEY_GOAL_GUESSERS || "").trim();
  const bucket = String(environment.CLOUDFLARE_R2_BUCKET_GOAL_GUESSERS || "goal-guessers").trim();
  return { endpoint, accessKeyId, secretAccessKey, bucket, configured: Boolean(endpoint && accessKeyId && secretAccessKey && bucket) };
}

async function normalizeTeamLogo(input) {
  if (!Buffer.isBuffer(input) || input.length === 0) throw new TeamLogoStorageError("Choose an image to upload", 400);
  if (input.length > MAX_UPLOAD_BYTES) throw new TeamLogoStorageError("The cropped image must be smaller than 5 MB", 413);

  let metadata;
  try {
    metadata = await sharp(input, { failOn: "error", limitInputPixels: MAX_INPUT_PIXELS, animated: false }).metadata();
  } catch (_error) {
    throw new TeamLogoStorageError("That image could not be read", 415);
  }
  if (!ACCEPTED_FORMATS.has(metadata.format) || !metadata.width || !metadata.height) {
    throw new TeamLogoStorageError("Use a PNG, JPEG, or WebP image", 415);
  }
  if (Number(metadata.pages || 1) > 1) throw new TeamLogoStorageError("Animated images are not supported", 415);
  if (metadata.width * metadata.height > MAX_INPUT_PIXELS) throw new TeamLogoStorageError("That image is too large to process", 413);
  if (metadata.width < 32 || metadata.height < 32) throw new TeamLogoStorageError("Choose an image at least 32 pixels wide and tall", 400);

  const base = sharp(input, { failOn: "error", limitInputPixels: MAX_INPUT_PIXELS, animated: false })
    .rotate()
    .toColorspace("srgb");
  const entries = await Promise.all(Object.entries(OUTPUT_SIZES).map(async ([name, size]) => {
    const data = await base.clone()
      .resize(size, size, { fit: "cover", position: "centre", withoutEnlargement: false })
      .png({ compressionLevel: 9, adaptiveFiltering: true })
      .toBuffer();
    return [name, { data, width: size, height: size, byte_size: data.length, content_type: "image/png" }];
  }));
  return {
    variants: Object.fromEntries(entries),
    sha256: crypto.createHash("sha256").update(input).digest("hex"),
    source: { format: metadata.format, width: metadata.width, height: metadata.height, byte_size: input.length },
  };
}

function createTeamLogoStorage({ environment = process.env, client = null } = {}) {
  const config = r2Configuration(environment);
  const s3 = client || (config.configured ? new S3Client({
    region: "auto",
    endpoint: config.endpoint,
    credentials: { accessKeyId: config.accessKeyId, secretAccessKey: config.secretAccessKey },
  }) : null);

  function requireConfiguration() {
    if (!config.configured || !s3) throw new TeamLogoStorageError("Team logo storage is not configured", 503);
  }

  async function store(assetId, normalized) {
    requireConfiguration();
    const stored = {};
    try {
      for (const [name, variant] of Object.entries(normalized.variants)) {
        const key = `team-logos/${assetId}/${name}.png`;
        await s3.send(new PutObjectCommand({
          Bucket: config.bucket,
          Key: key,
          Body: variant.data,
          ContentType: variant.content_type,
          CacheControl: "private, max-age=300",
          Metadata: { asset_id: assetId, variant: name },
        }));
        stored[name] = { key, width: variant.width, height: variant.height, byte_size: variant.byte_size, content_type: variant.content_type };
      }
      return stored;
    } catch (error) {
      if (Object.keys(stored).length) await remove(stored).catch(() => {});
      throw new TeamLogoStorageError(`Team logo storage failed: ${error.message || "R2 rejected the image"}`, 503);
    }
  }

  async function read(asset, variantName = "thumbnail") {
    requireConfiguration();
    const variant = asset?.variants?.[variantName] || asset?.variants?.full;
    if (!variant?.key) throw new TeamLogoStorageError("Team logo was not found", 404);
    try {
      const response = await s3.send(new GetObjectCommand({ Bucket: config.bucket, Key: variant.key }));
      return { body: response.Body, contentType: response.ContentType || variant.content_type || "image/png", contentLength: response.ContentLength || variant.byte_size, etag: response.ETag };
    } catch (error) {
      const status = error?.$metadata?.httpStatusCode === 404 || error?.name === "NoSuchKey" ? 404 : 503;
      throw new TeamLogoStorageError(status === 404 ? "Team logo was not found" : "Team logo storage is unavailable", status);
    }
  }

  async function remove(variants) {
    requireConfiguration();
    const keys = Object.values(variants || {}).map((variant) => variant?.key).filter(Boolean);
    if (!keys.length) return;
    await s3.send(new DeleteObjectsCommand({ Bucket: config.bucket, Delete: { Objects: keys.map((Key) => ({ Key })), Quiet: true } }));
  }

  return { configured: config.configured, bucket: config.bucket, store, read, remove };
}

module.exports = {
  MAX_UPLOAD_BYTES,
  MAX_INPUT_PIXELS,
  OUTPUT_SIZES,
  TeamLogoStorageError,
  r2Configuration,
  normalizeTeamLogo,
  createTeamLogoStorage,
};
