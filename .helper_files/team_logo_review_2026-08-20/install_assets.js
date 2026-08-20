#!/usr/bin/env node

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const repositoryRoot = path.resolve(__dirname, "../..");
const mediaCatalog = path.join(repositoryRoot, "ios", "Top Scores", "Media.xcassets");
const manifestPath = path.join(__dirname, "manifest.json");
const catalogPaths = [
  path.join(repositoryRoot, "api", "team_logo_assets.json"),
  path.join(repositoryRoot, "ios", "Top Scores", "Top Scores", "team_logo_assets.json"),
];

const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const approvedRows = manifest.teams.filter(
  (row) => row.status !== "placeholder" && row.preview_path
);

for (const row of approvedRows) {
  const imagesetDirectory = path.join(mediaCatalog, `${row.reported_name}.imageset`);
  const sourcePath = path.join(__dirname, row.preview_path);
  const outputPath = path.join(imagesetDirectory, "logo.png");

  if (!fs.existsSync(sourcePath)) {
    throw new Error(`Missing approved preview for ${row.reported_name}: ${sourcePath}`);
  }

  fs.mkdirSync(imagesetDirectory, { recursive: true });
  let conversionSource = sourcePath;
  let temporaryDirectory = null;
  if (path.extname(sourcePath).toLowerCase() === ".svg") {
    const svg = fs.readFileSync(sourcePath, "utf8");
    const embeddedPNG = svg.match(/data:image\/png;base64,([^"']+)/);
    if (embeddedPNG) {
      temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "top-scores-logo-"));
      conversionSource = path.join(temporaryDirectory, "embedded.png");
      fs.writeFileSync(conversionSource, Buffer.from(embeddedPNG[1], "base64"));
    }
  }

  try {
    execFileSync("magick", [
      conversionSource,
      "-background", "none",
      "-thumbnail", "256x256>",
      "-strip",
      "-define", "png:compression-level=9",
      outputPath,
    ]);
  } finally {
    if (temporaryDirectory) {
      fs.rmSync(temporaryDirectory, { recursive: true, force: true });
    }
  }

  const contents = {
    images: [
      {
        filename: "logo.png",
        idiom: "universal",
        scale: "1x",
      },
      {
        idiom: "universal",
        scale: "2x",
      },
      {
        idiom: "universal",
        scale: "3x",
      },
    ],
    info: {
      author: "xcode",
      version: 1,
    },
  };
  fs.writeFileSync(
    path.join(imagesetDirectory, "Contents.json"),
    `${JSON.stringify(contents, null, 2)}\n`
  );
}

const catalogNames = new Set();
for (const catalogPath of catalogPaths) {
  const existing = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  existing.forEach((name) => catalogNames.add(name));
}
approvedRows.forEach((row) => catalogNames.add(row.reported_name));

const sortedCatalog = Array.from(catalogNames).sort((lhs, rhs) =>
  lhs.localeCompare(rhs, "en", { sensitivity: "base" })
);
const catalogJSON = `${JSON.stringify(sortedCatalog, null, 2)}\n`;
for (const catalogPath of catalogPaths) {
  fs.writeFileSync(catalogPath, catalogJSON);
}

console.log(JSON.stringify({
  installed_assets: approvedRows.length,
  catalog_entries: sortedCatalog.length,
  skipped_placeholders: manifest.teams.length - approvedRows.length,
}, null, 2));
