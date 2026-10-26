import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { normalizedKey } from "../team-logos.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const webRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(webRoot, "..");
// Include the canonical API rules in standalone website deployments.
const sharedRoot = path.join(webRoot, "server-shared");
fs.mkdirSync(sharedRoot, { recursive: true });
for (const [source, destination] of [
  ["broadcast_priorities.js", "broadcast_priorities.cjs"],
  ["tv_provider_priorities.json", "tv_provider_priorities.json"],
]) {
  const sourcePath = path.join(repoRoot, "api", source);
  const destinationPath = path.join(sharedRoot, destination);
  if (fs.existsSync(sourcePath)) fs.copyFileSync(sourcePath, destinationPath);
  else if (!fs.existsSync(destinationPath)) throw new Error(`Missing bundled server dependency: ${destination}`);
}

const outputRoot = path.join(webRoot, "public", "generated-assets");
const outputTeamLogosRoot = path.join(outputRoot, "team-logos");
const outputTvLogosRoot = path.join(outputRoot, "tv-logos");
const outputManifestPath = path.join(outputRoot, "team-logo-manifest.json");
const outputAppIconPath = path.join(outputRoot, "app-icon.png");
const outputFaviconPath = path.join(outputRoot, "favicon-32.png");
const outputAppleTouchIconPath = path.join(outputRoot, "apple-touch-icon.png");
const outputFplLionPath = path.join(outputRoot, "fpl-lion.png");
const teamLogoManifestPath = path.join(
  repoRoot,
  "ios",
  "Top Scores",
  "Top Scores",
  "team_logo_assets.json"
);
const mediaAssetsRoot = path.join(repoRoot, "ios", "Top Scores", "Media.xcassets");
const teamIdentityCatalogPath = path.join(repoRoot, "ios", "Top Scores", "Top Scores", "team_colors.json");
const tvLogosRoot = path.join(repoRoot, "ios", "Top Scores", "Top Scores", "tv-logos");
const appIconSourcePath = path.join(
  repoRoot,
  "ios",
  "Top Scores",
  "Media.xcassets",
  "TopScoresAppIcon.appiconset",
  "icon-ios-1024x1024.png"
);
// The 40pt@3x icon uses the simplified ball artwork, which stays legible at favicon size.
const faviconSourcePath = path.join(path.dirname(appIconSourcePath), "icon-ios-40x40@3x.png");
const sourceInputs = [teamLogoManifestPath, teamIdentityCatalogPath, mediaAssetsRoot, tvLogosRoot, appIconSourcePath];

if (hasSourceAssets()) {
  const tempRoot = path.join(webRoot, "public", `.generated-assets-${process.pid}-${Date.now()}`);
  const tempTeamLogosRoot = path.join(tempRoot, "team-logos");
  const tempTvLogosRoot = path.join(tempRoot, "tv-logos");
  const tempManifestPath = path.join(tempRoot, "team-logo-manifest.json");
  const tempAppIconPath = path.join(tempRoot, "app-icon.png");
  const tempFaviconPath = path.join(tempRoot, "favicon-32.png");
  const tempAppleTouchIconPath = path.join(tempRoot, "apple-touch-icon.png");
  const tempFplLionPath = path.join(tempRoot, "fpl-lion.png");

  fs.rmSync(tempRoot, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
  fs.mkdirSync(tempTeamLogosRoot, { recursive: true });
  fs.mkdirSync(tempTvLogosRoot, { recursive: true });

  await copyAppIcons(tempAppIconPath, tempFaviconPath, tempAppleTouchIconPath);
  copyFplLion(tempFplLionPath);
  const teamEntries = await copyTeamLogos(tempTeamLogosRoot);
  await copyTvLogos(tempTvLogosRoot);

  fs.writeFileSync(tempManifestPath, JSON.stringify(teamEntries, null, 2));
  replaceOutputRoot(tempRoot);

  console.log(
    `Synced ${teamEntries.length} team logos, TV logos, and app icon into ${path.relative(repoRoot, outputRoot)}`
  );
} else if (hasBundledAssets()) {
  ensureBundledFplLion();
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

function ensureBundledFplLion() {
  if (fs.existsSync(outputFplLionPath)) {
    return;
  }

  fs.copyFileSync(outputAppIconPath, outputFplLionPath);
  console.warn(
    `Missing bundled FPL lion asset; copied ${path.basename(outputAppIconPath)} to ${path.basename(outputFplLionPath)}.`
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
    .resize(144, 144, { fit: "cover" })
    .sharpen({ sigma: 0.6 })
    .png({ compressionLevel: 9 })
    .toFile(appIconDestinationPath);

  await sharp(fs.readFileSync(faviconSourcePath))
    .resize(32, 32, { fit: "cover" })
    .sharpen({ sigma: 0.6 })
    .png({ compressionLevel: 9 })
    .toFile(faviconDestinationPath);

  await sharp(sourceBuffer)
    .resize(180, 180, { fit: "cover" })
    .png({ compressionLevel: 9, palette: true })
    .toFile(appleTouchDestinationPath);
}

async function copyTeamLogos(destinationRoot) {
  const { default: sharp } = await import("sharp");
  if (!fs.existsSync(teamLogoManifestPath)) {
    throw new Error(`Missing team logo manifest: ${teamLogoManifestPath}`);
  }

  const assetNames = JSON.parse(fs.readFileSync(teamLogoManifestPath, "utf8"));
  const catalog = JSON.parse(fs.readFileSync(teamIdentityCatalogPath, "utf8"));
  const manifest = [];

  for (const assetName of assetNames) {
    const imagesetPath = path.join(mediaAssetsRoot, `${assetName}.imageset`);
    const sourceFile = pickImagesetPng(imagesetPath);
    if (!sourceFile) {
      continue;
    }

    const filename = `${slugify(assetName)}.png`;
    const destination = path.join(destinationRoot, filename);
    await sharp(sourceFile).resize(96, 96, { fit: "inside", withoutEnlargement: true }).png({ compressionLevel: 9, palette: true }).toFile(destination);
    manifest.push({
      name: assetName,
      relativePath: path.posix.join("team-logos", filename),
      aliases: [],
    });
  }

  const exactNames = new Map(manifest.map((entry) => [entry.name.toLowerCase(), entry]));
  const normalizedNames = new Map(manifest.map((entry) => [normalizedKey(entry.name), entry]));
  const assignedNames = new Set();
  for (const identity of [...catalog.teams, ...catalog.identity_groups]) {
    const names = [identity.name, ...identity.aliases];
    const entry = names.map((name) => exactNames.get(name.toLowerCase())).find(Boolean) ||
      names.map((name) => normalizedNames.get(normalizedKey(name))).find(Boolean);
    if (!entry) continue;
    for (const name of names) {
      const key = normalizedKey(name);
      // Match iOS's first identity for ambiguous aliases, such as three-letter abbreviations.
      if (assignedNames.has(key)) continue;
      assignedNames.add(key);
      if (name !== entry.name) entry.aliases.push(name);
    }
  }

  return manifest;
}

async function copyTvLogos(destinationRoot) {
  const { default: sharp } = await import("sharp");
  if (!fs.existsSync(tvLogosRoot)) {
    throw new Error(`Missing TV logos directory: ${tvLogosRoot}`);
  }

  for (const entry of fs.readdirSync(tvLogosRoot)) {
    if (!entry.toLowerCase().endsWith(".png")) {
      continue;
    }

    await sharp(path.join(tvLogosRoot, entry))
      .resize(192, 72, { fit: "inside", withoutEnlargement: true })
      .png({ compressionLevel: 9, palette: true })
      .toFile(path.join(destinationRoot, entry));
  }
}

function copyFplLion(destinationPath) {
  const imagesetPath = path.join(mediaAssetsRoot, "FantasyPremierLeagueLion.imageset");
  const sourceFile = pickImagesetPng(imagesetPath);
  if (!sourceFile) {
    throw new Error(`Missing FPL lion source asset in ${imagesetPath}`);
  }
  fs.copyFileSync(sourceFile, destinationPath);
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
