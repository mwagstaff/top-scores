# Live Activity team crests

Live Activity crest selection uses BSD `home_team_id` / `away_team_id` from
the canonical match. `bsd_team_logo_assets.json` binds each supported BSD ID to
an existing bundled crest. The server still sends `homeLogoKey` / `awayLogoKey`
because the widget loads `<asset_name> Live Activity` from its asset catalog.
Display names do not participate when a team ID is present. No network request
or database query is needed while building a Live Activity payload.

An unknown ID returns no crest key. Do not fall back to a similar team name:
Reading City and Reading FC, for example, are separate clubs. ID-less legacy
snapshots and synthetic harness fixtures retain the compatibility name lookup.
The harness also accepts BSD `home_team_id` / `away_team_id` (or camel-case
`homeTeamId` / `awayTeamId`). Explicit harness logo overrides remain available.

## Investigation, 6 September 2026

Manchester United is BSD team **17**. Its bundled crest is **Man United**.
The old resolver ignored the BSD ID, tried the full name and selected short
aliases such as “Man U”, and omitted the logo key when none matched the asset
name. The widget consequently displayed its first-letter fallback.

The audit inspected 1,980 stored BSD team records and verified 948 ID mappings
against the bundled Live Activity assets. Mappings were seeded from BSD full
names, curated aliases and reviewed BSD short names, then stored explicitly by
ID. Broad/fuzzy aliases from the team-colour catalog were not imported.

Additional missing keys included FC Nordsjælland, SC Paderborn 07,
1. FSV Mainz 05, VfL Bochum 1848 and the alternate BSD Bayern München record.
National teams also affected included Turks and Caicos Islands, Solomon
Islands, East Timor, Congo Republic and North Korea.

The previous name lookup also selected the wrong crest for:

| BSD team | Previous crest | Correct crest |
| --- | --- | --- |
| Wolverhampton (11) | AFC Wolverhampton City | Wolves |
| Cambridge United (1413) | Cambridge City | Cambridge Utd |
| Dundee United (227) | Dundee | Dundee Utd |

The ID path stops cross-club substitutions for other unmapped teams, including
Arsenal Tivat, Oxford City, Reading City, Coventry United, Swindon Supermarine,
Ipswich Wanderers, Newcastle Town, Redcar Athletic, Dinamo City, UD Melilla,
and Red Star FC. FC Andorra no longer receives the national team's flag.
These teams retain the generic fallback until their own crests are mapped.
The catalog is coverage of available, verified crests, not a claim that every
BSD team (including placeholder records) has bundled artwork.

## Adding coverage

1. Verify the BSD ID and identity using the stored `bsd_teams` payload or BSD's
   `/api/v2/teams/:id` endpoint. Check country and full name when names collide.
2. Verify that the chosen asset depicts that club. Add a record under `teams`
   keyed by the BSD ID, with the upstream `name` and exact `asset_name`.
   Keep IDs in numeric order and update `verified_at`.
3. If artwork is new, add it to the existing team manifests and regenerate the
   Live Activity assets with the iOS asset-generation script.
4. Run `rtk proxy node --test api/live_activity_team_logos.test.js
   api/server.live_activity_test_harness.test.js` and
   `rtk proxy bash 'ios/Top Scores/scripts/verify-live-activity-assets.sh'`.

Deploy the JSON catalog and its resolver alongside `match_monitor.js` and
`server.js`. Manchester United's fix uses its already bundled asset and needs
no widget code change. Newly added artwork still requires an app release.
