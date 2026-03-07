import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const webRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(webRoot, "..");
const outputRoot = path.join(webRoot, "public", "generated-assets");
const outputTeamLogosRoot = path.join(outputRoot, "team-logos");
const outputTvLogosRoot = path.join(outputRoot, "tv-logos");
const outputManifestPath = path.join(outputRoot, "team-logo-manifest.json");
const outputAppIconPath = path.join(outputRoot, "app-icon.png");
const outputFaviconPath = path.join(outputRoot, "favicon-32.png");
const outputAppleTouchIconPath = path.join(outputRoot, "apple-touch-icon.png");
const teamLogoManifestPath = path.join(
  repoRoot,
  "ios",
  "Top Scores",
  "Top Scores",
  "team_logo_assets.json"
);
const mediaAssetsRoot = path.join(repoRoot, "ios", "Top Scores", "Media.xcassets");
const tvLogosRoot = path.join(repoRoot, "ios", "Top Scores", "Top Scores", "tv-logos");
const appIconSourcePath = path.join(
  repoRoot,
  "ios",
  "Top Scores",
  "Top Scores Share Extension",
  "top-scores-logo.png"
);
const sourceInputs = [teamLogoManifestPath, mediaAssetsRoot, tvLogosRoot, appIconSourcePath];

if (hasSourceAssets()) {
  const tempRoot = path.join(webRoot, "public", `.generated-assets-${process.pid}-${Date.now()}`);
  const tempTeamLogosRoot = path.join(tempRoot, "team-logos");
  const tempTvLogosRoot = path.join(tempRoot, "tv-logos");
  const tempManifestPath = path.join(tempRoot, "team-logo-manifest.json");
  const tempAppIconPath = path.join(tempRoot, "app-icon.png");
  const tempFaviconPath = path.join(tempRoot, "favicon-32.png");
  const tempAppleTouchIconPath = path.join(tempRoot, "apple-touch-icon.png");

  fs.rmSync(tempRoot, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
  fs.mkdirSync(tempTeamLogosRoot, { recursive: true });
  fs.mkdirSync(tempTvLogosRoot, { recursive: true });

  await copyAppIcons(tempAppIconPath, tempFaviconPath, tempAppleTouchIconPath);
  const teamEntries = copyTeamLogos(tempTeamLogosRoot);
  copyTvLogos(tempTvLogosRoot);

  fs.writeFileSync(tempManifestPath, JSON.stringify(teamEntries, null, 2));
  replaceOutputRoot(tempRoot);

  console.log(
    `Synced ${teamEntries.length} team logos, TV logos, and app icon into ${path.relative(repoRoot, outputRoot)}`
  );
} else if (hasBundledAssets()) {
  console.log(
    `iOS asset sources not present; using bundled web assets from ${path.relative(repoRoot, outputRoot)}`
  );
} else {
  throw new Error(
    [
      "No asset source was available.",
      `Expected either iOS sources under ${path.relative(repoRoot, path.join(repoRoot, "ios"))}`,
      `or bundled assets under ${path.relative(repoRoot, outputRoot)}.`,
    ].join(" ")
  );
}

function hasSourceAssets() {
  return sourceInputs.every((entryPath) => fs.existsSync(entryPath));
}

function hasBundledAssets() {
  if (!fs.existsSync(outputManifestPath) || !fs.existsSync(outputAppIconPath)) {
    return false;
  }

  if (!fs.existsSync(outputTeamLogosRoot) || !fs.existsSync(outputTvLogosRoot)) {
    return false;
  }

  const manifest = JSON.parse(fs.readFileSync(outputManifestPath, "utf8"));
  return (
    Array.isArray(manifest) &&
    manifest.length > 0 &&
    fs.existsSync(outputFaviconPath) &&
    fs.existsSync(outputAppleTouchIconPath) &&
    fs.readdirSync(outputTeamLogosRoot).some((entry) => entry.toLowerCase().endsWith(".png")) &&
    fs.readdirSync(outputTvLogosRoot).some((entry) => entry.toLowerCase().endsWith(".png"))
  );
}

async function copyAppIcons(appIconDestinationPath, faviconDestinationPath, appleTouchDestinationPath) {
  if (!fs.existsSync(appIconSourcePath)) {
    throw new Error(`Missing app icon source: ${appIconSourcePath}`);
  }

  const sharpModule = await import("sharp");
  const sharp = sharpModule.default;
  const sourceBuffer = fs.readFileSync(appIconSourcePath);

  await sharp(sourceBuffer)
    .resize(96, 96, { fit: "cover" })
    .png({ compressionLevel: 9, palette: true })
    .toFile(appIconDestinationPath);

  await sharp(sourceBuffer)
    .resize(32, 32, { fit: "cover" })
    .png({ compressionLevel: 9, palette: true })
    .toFile(faviconDestinationPath);

  await sharp(sourceBuffer)
    .resize(180, 180, { fit: "cover" })
    .png({ compressionLevel: 9, palette: true })
    .toFile(appleTouchDestinationPath);
}

function copyTeamLogos(destinationRoot) {
  if (!fs.existsSync(teamLogoManifestPath)) {
    throw new Error(`Missing team logo manifest: ${teamLogoManifestPath}`);
  }

  const assetNames = JSON.parse(fs.readFileSync(teamLogoManifestPath, "utf8"));
  const manifest = [];

  for (const assetName of assetNames) {
    const imagesetPath = path.join(mediaAssetsRoot, `${assetName}.imageset`);
    const sourceFile = pickImagesetPng(imagesetPath);
    if (!sourceFile) {
      continue;
    }

    const filename = `${slugify(assetName)}.png`;
    const destination = path.join(destinationRoot, filename);
    fs.copyFileSync(sourceFile, destination);
    manifest.push({
      name: assetName,
      relativePath: path.posix.join("team-logos", filename),
    });
  }

  return manifest;
}

function copyTvLogos(destinationRoot) {
  if (!fs.existsSync(tvLogosRoot)) {
    throw new Error(`Missing TV logos directory: ${tvLogosRoot}`);
  }

  for (const entry of fs.readdirSync(tvLogosRoot)) {
    if (!entry.toLowerCase().endsWith(".png")) {
      continue;
    }

    fs.copyFileSync(
      path.join(tvLogosRoot, entry),
      path.join(destinationRoot, entry)
    );
  }
}

function pickImagesetPng(imagesetPath) {
  if (!fs.existsSync(imagesetPath)) {
    return null;
  }

  const candidates = fs
    .readdirSync(imagesetPath)
    .filter((entry) => entry.toLowerCase().endsWith(".png"))
    .sort((left, right) => left.localeCompare(right, undefined, { sensitivity: "base" }));

  if (candidates.length === 0) {
    return null;
  }

  return path.join(imagesetPath, candidates[0]);
}

function slugify(value) {
  return String(value)
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function replaceOutputRoot(tempRoot) {
  const backupRoot = `${outputRoot}.previous`;
  fs.rmSync(backupRoot, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });

  if (fs.existsSync(outputRoot)) {
    try {
      fs.renameSync(outputRoot, backupRoot);
    } catch (error) {
      if (!(error && typeof error === "object" && "code" in error && error.code === "ENOENT")) {
        throw error;
      }
    }
  }

  fs.renameSync(tempRoot, outputRoot);
  fs.rmSync(backupRoot, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
}
