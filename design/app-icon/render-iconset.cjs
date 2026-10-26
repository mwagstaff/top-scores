// Renders every image in TopScoresAppIcon.appiconset from ball.svg / ball-small.svg.
// Icons at 40pt and below use the simplified small variant so they stay legible.
// Usage: node design/app-icon/render-iconset.cjs
const fs = require("node:fs");
const path = require("node:path");
const sharp = require("../../web/node_modules/sharp");

const repoRoot = path.join(__dirname, "..", "..");
const iconset = path.join(repoRoot, "ios", "Top Scores", "Media.xcassets", "TopScoresAppIcon.appiconset");
const large = fs.readFileSync(path.join(__dirname, "ball.svg"));
const small = fs.readFileSync(path.join(__dirname, "ball-small.svg"));
const SMALL_MAX_POINTS = 40;

(async () => {
  const { images } = JSON.parse(fs.readFileSync(path.join(iconset, "Contents.json"), "utf8"));
  for (const image of images) {
    if (!image.filename) continue;
    const points = parseFloat(image.size);
    const scale = image.scale ? parseFloat(image.scale) : 1;
    const px = Math.round(points * scale);
    const source = points <= SMALL_MAX_POINTS ? small : large;
    await sharp(source, { density: Math.max(72, (72 * px) / 1024 * 4) })
      .resize(px, px)
      .removeAlpha()
      .png({ compressionLevel: 9 })
      .toFile(path.join(iconset, image.filename));
    console.log(`${image.filename} ${px}px ${source === small ? "small" : "large"}`);
  }
})();
