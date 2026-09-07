# Top Scores Reference API

Read-only football reference data for game imports: covered competitions, teams,
team colours, current squads and full player profiles including BSD scouting ratings.

## Find the API

Append `/api/v1/reference` to the Top Scores service URL (including any deployment
path prefix). For example, production behind the existing `/top-scores` proxy uses
`https://api.skynolimit.dev/top-scores/api/v1/reference` once this version is deployed.

Documentation and discovery are available relative to that base:

- `openapi.json`: machine-readable contract, including all response fields.
- `docs/`: interactive Swagger UI; assets are served locally.
- `docs/reference.md`: generated endpoint and schema reference.
- `llms.txt`: concise documentation index.

The API is public initially. If authentication is enabled later, send a project
key as `Authorization: Bearer YOUR_PROJECT_KEY`. Never send a BSD upstream key.
Keep project keys in your game's backend. Documentation remains public.

## Import a competition into a game

1. Read `GET /coverage`. Every configured competition appears here, including
   those still awaiting their first successful refresh.
2. Read `GET /competitions`. Select the returned BSD `id` and `current_season.id`.
   Only competitions with a published snapshot appear in this list.
3. Read `GET /competitions/{id}/export`. This single response contains the
   competition and `teams`, each holding `team` and `squad`. Every squad entry has
   `player_id`, its own `jersey_number`, and the full `player` profile.
4. Inspect `data.coverage` and `meta.stale`. Decide whether your game accepts
   unknown colours, missing ratings, empty squads or placeholder teams.
5. Store the import in a staging area, keyed by `meta.snapshot_id`. Replace your
   game's active competition data only after your entire import succeeds.
6. Check again daily. Send the previous `ETag` in `If-None-Match`; a `304` response
   means the representation is unchanged. There is no response body on `304`.

Example (replace BASE with the deployed reference base URL):

```sh
curl "$BASE/competitions?limit=200&offset=0"
curl "$BASE/competitions/1/export"
curl "$BASE/teams/19/squad"
curl "$BASE/players/363"
```

The numeric IDs above are examples, not a guaranteed membership or coverage list.
Discover IDs from the API. Do not join entities by name or substitute Top Scores'
older name-based team catalogue identifiers. Unsupported IDs return `404`.

## Browse and paginate

`GET /teams?search=Leeds` searches names and configured aliases.
`GET /players?search=Rodon` searches player names.
`GET /players?team_id=19` filters by current squad membership, including national
squads, rather than just a player's club ID.

All successful data responses have `data`, `meta` and `pagination`.
List endpoints use `limit` (default/max 200) and `offset` (default 0), sorted by ID
as strings. Follow `pagination.next_offset` until it is `null`. After the first
page, also send `catalogue_version` from `meta.catalogue_version`. A `409` means
the dataset changed: discard accumulated pages and restart at offset 0.

Competition exports are unpaginated, coherent snapshots. Other endpoints return
the latest stored views and can include competitions refreshed at different times.
A team or player shared by multiple competitions uses its most recently fetched
record in global endpoints. Use the export when cross-record consistency matters.

## Data semantics

- `player.rating` is BSD's overall FM scouting ability on a **0–200** scale.
  Higher is better. It is not a percentage or match-performance rating.
  Preserve the number; `null` means unknown, not zero. Rating zero remains zero.
- Scouting attributes are preserved exactly as supplied by BSD. Live values can
  exceed BSD's documented 0–20 scale; do not assume a common scale or rescale them
  without checking the source. Missing values remain `null`.
- `player.jersey_number` belongs to the current club. A national squad can use a
  different number: use the squad entry's `jersey_number` for that squad.
- Squads are always current, not historical or tournament registration lists.
  A competition's season defines team participation only. Optional `season_id`
  must match the published current season; other seasons return `400`.
- Club and national-team IDs in a player profile can refer to uncovered teams.
  Such team details will return `404`; references are not expanded recursively.
- `colours` use uppercase `#RRGGBB`. Top Scores configured colours take precedence
  over BSD colours. `source: unavailable` and `is_fallback: true` mean no verified
  colours exist; choose a display fallback within the game.
- `is_placeholder: true` identifies unresolved tournament slots such as W101.
  These have `squad.status: placeholder`, no players and no team image URL.
- A successful empty upstream squad has `status: empty`. This reports what BSD
  supplied; it does not guarantee the real-world team has no players.
- `availability: available` means BSD has not listed the player as missing. It
  is not confirmation of fitness. Preserve unfamiliar status/position codes.
- Money is in EUR; wages are annual gross estimates. Height is centimetres and
  weight is kilograms. Dates use ISO dates; timestamps are UTC ISO timestamps.
- `updated_at` on records is our fetch time, not BSD's original change time.
  `meta.updated_at` is the competition publication time, or the oldest active
  competition publication for cross-competition responses.
- Image URLs identify teams and players. An image may be unavailable or return
  a placeholder, and media rights are separate from the data API.

## Freshness, failures and limits

The background worker refreshes each competition at most once per 24 hours after
a successful publication, checking hourly for due or failed competitions. Reads
never call BSD. An interrupted or failed refresh retains the last complete
competition snapshot. Coverage reports the most recent attempt separately.

The serving process reloads stored snapshots at most once per minute. On a reload
failure it continues serving its previous catalogue. `meta.stale` becomes true
when the relevant publication is older than 48 hours, or when the serving process
cannot reload MongoDB. Daily refresh is a target, not a guarantee of BSD accuracy.

`data.coverage` in exports lists missing ratings/colours, empty squads and unresolved
slots. `/coverage` also distinguishes `not_collected` from `available`.
Published membership may still be limited by BSD's own coverage.

Errors use `{"error":{"code":"...","message":"..."}}`:

- `400`: malformed/repeated/unknown parameter, or unsupported season.
- `401`: authentication is enabled and the project key is missing/invalid.
- `404`: unknown endpoint, uncovered competition, or entity absent from published squads.
- `409`: catalogue changed during pagination; restart your list import.
- `429`: request limit exceeded; observe `Retry-After` seconds.
- `503`: initial collection pending or storage unavailable; observe `Retry-After`.

The default per-IP, per-process budget is 120 units per minute. Each export costs
10 units; other requests cost one. Limits also apply to documentation. Conditional
requests still consume units. Multiple API replicas should share an edge rate
limit. No cookies or browser credentials are needed for public reads.

## Sources

- BSD sports data and rating definitions: https://sports.bzzoiro.com/openapi.json
- Team and player API: https://sports.bzzoiro.com/docs/football/teams-players/
- Data usage terms: https://sports.bzzoiro.com/docs/api-license/

This API does not grant downstream redistribution or media rights. Check the
applicable BSD terms and permissions for your intended deployment.
