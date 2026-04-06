const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const MODULE_PATH = "/Users/mwagstaff/dev/top-scores/api/team_identity.js";

function loadTeamIdentityModule({ colorsPath, aliasesPath }) {
  delete require.cache[require.resolve(MODULE_PATH)];
  process.env.TEAM_COLORS_CONFIG_PATH = colorsPath;
  process.env.TEAM_ALIASES_CONFIG_PATH = aliasesPath;
  return require(MODULE_PATH);
}

test("team_identity merges dedicated alias mappings into the shared canonical layer", () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "team-identity-"));
  const colorsPath = path.join(tempDir, "team_colors.json");
  const aliasesPath = path.join(tempDir, "team_aliases.json");
  const originalColorsPath = process.env.TEAM_COLORS_CONFIG_PATH;
  const originalAliasesPath = process.env.TEAM_ALIASES_CONFIG_PATH;

  fs.writeFileSync(
    colorsPath,
    JSON.stringify(
      {
        updatedAt: "2026-04-06T20:15:00.000Z",
        default: {
          primary: "#111111",
          secondary: "#ffffff",
          scheme: "default-dark",
        },
        teams: [],
        identity_groups: [
          {
            name: "Manchester City",
            aliases: ["MCI"],
          },
        ],
      },
      null,
      2
    )
  );
  fs.writeFileSync(
    aliasesPath,
    JSON.stringify(
      {
        updatedAt: "2026-04-06T20:16:00.000Z",
        aliases: {
          "QPR": "Queens Park Rangers",
          "West Brom": "West Bromwich Albion",
          "AZ": "AZ Alkmaar",
          "Man City": "Manchester City",
        },
      },
      null,
      2
    )
  );

  try {
    const teamIdentity = loadTeamIdentityModule({ colorsPath, aliasesPath });

    assert.equal(teamIdentity.canonicalTeamName("QPR"), "Queens Park Rangers");
    assert.equal(teamIdentity.canonicalTeamName("West Brom"), "West Bromwich Albion");
    assert.equal(teamIdentity.canonicalTeamName("AZ"), "AZ Alkmaar");
    assert.equal(teamIdentity.canonicalTeamName("Man City"), "Manchester City");
    assert.equal(teamIdentity.teamNamesEquivalent("QPR", "Queens Park Rangers"), true);
    assert.equal(teamIdentity.teamNamesEquivalent("West Brom", "West Bromwich Albion"), true);
    assert.equal(teamIdentity.buildFantasyShortNameMappings().QPR, "Queens Park Rangers");
    assert.equal(teamIdentity.buildFantasyShortNameMappings().MCI, "Manchester City");
  } finally {
    if (originalColorsPath === undefined) {
      delete process.env.TEAM_COLORS_CONFIG_PATH;
    } else {
      process.env.TEAM_COLORS_CONFIG_PATH = originalColorsPath;
    }
    if (originalAliasesPath === undefined) {
      delete process.env.TEAM_ALIASES_CONFIG_PATH;
    } else {
      process.env.TEAM_ALIASES_CONFIG_PATH = originalAliasesPath;
    }
    delete require.cache[require.resolve(MODULE_PATH)];
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
