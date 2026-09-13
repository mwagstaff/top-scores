const catalog = require("./bsd_team_logo_assets.json");

// BSD IDs are the runtime identity. Asset names are only the widget's existing
// bundle resource keys; neither a display-name change nor an alias can change
// the crest selected for a match with an ID.
const assetByID = new Map(
  Object.entries(catalog.teams).map(([id, team]) => [id, team.asset_name])
);
const canonicalNameByID = new Map(
  Object.entries(catalog.teams).map(([id, team]) => {
    const providerName = String(team.name || "").trim();
    const explicitName = String(team.canonical_name || "").trim();
    return [id, explicitName || providerName];
  })
);

function bsdTeamLogoAsset(teamID) {
  return assetByID.get(String(teamID ?? "").trim()) || null;
}

// Resolve the catalogue record by BSD ID only. Any preferred display label is
// stored on that same ID; the global name-alias table is never consulted.
function bsdTeamCanonicalName(teamID) {
  return canonicalNameByID.get(String(teamID ?? "").trim()) || null;
}

// Compatibility for old snapshots and synthetic harness matches without IDs.
// Only exact catalogue names qualify, and ambiguous names stay unresolved.
const legacyAssetByName = new Map();
function legacyNameKey(name) {
  return String(name || "").normalize("NFC").trim().toLowerCase();
}
for (const team of Object.values(catalog.teams)) {
  const key = legacyNameKey(team.name);
  if (legacyAssetByName.has(key) && legacyAssetByName.get(key) !== team.asset_name) {
    legacyAssetByName.set(key, null);
  } else if (!legacyAssetByName.has(key)) {
    legacyAssetByName.set(key, team.asset_name);
  }
}

function legacyBsdTeamLogoAsset(teamName) {
  return legacyAssetByName.get(legacyNameKey(teamName)) || null;
}

module.exports = { bsdTeamLogoAsset, bsdTeamCanonicalName, legacyBsdTeamLogoAsset };
