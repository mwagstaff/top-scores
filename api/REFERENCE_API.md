# Reference API operations

The `/api/v1/reference` module serves the game-data API separately from existing
app responses. It is public by default and does not start any background work
in the API process. See [consumer quickstart](REFERENCE_API_QUICKSTART.md).

## Runtime setup

Install the API package dependencies, then restart the API and BSD poller through
your normal service management when ready to release. No extra service is needed.
The API and poller must point to the same Mongo database.

The BSD poller checks the configured `BSD_LEAGUE_ALLOWLIST` on startup and hourly.
Each successfully published competition becomes due after 24 hours. Failed
competitions are retried at the next hourly check. The first population can take
longer depending on the number of squads and BSD's rate limits. `/coverage` shows
progress as complete competitions become available. Data endpoints return `503`
before their first successful publication; reads never trigger ingestion.

For a one-off refresh, from the `api` directory, with local secrets in `.env.local`:

```sh
rtk proxy node --env-file=.env.local fetch_bsd_catalogue.js
```

Add `--force` to refresh already-fresh competitions. The same Mongo lease prevents
the CLI and poller from making simultaneous catalogue sweeps. No credentials are
printed. This command writes catalogue data; do not point a test run at production.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `BSD_API_KEY` | required in poller | Upstream token; never sent to clients |
| `MONGODB_URI_TOP_SCORES` | required | Shared API/poller Mongo database |
| `BSD_LEAGUE_ALLOWLIST` | existing Top Scores defaults | Competitions to collect and expose |
| `REFERENCE_API_KEYS` | empty/public | Comma-separated project bearer tokens; setting a nonempty list locks all reference data routes |
| `REFERENCE_RATE_LIMIT_PER_MINUTE` | 120 | Per-IP, per-process request units; exports cost 10, other requests cost 1 |
| `REFERENCE_TRUST_PROXY` | unset/false | Explicit trusted proxy addresses or subnets, e.g. `loopback` for a verified localhost reverse proxy |
| `REFERENCE_PUBLIC_BASE_URL` | `.` | OpenAPI server URL, relative to the schema URL by default; optional absolute deployed reference base |
| `TEAM_COLORS_CONFIG_PATH` | existing default | Top Scores' configured colour catalogue |

Use the relative OpenAPI server URL when the reverse proxy adds a path such as
`/top-scores`; documentation asset URLs and the schema resolve relative to their
external location. An explicit base URL must include the entire proxy prefix and
`/api/v1/reference`. Never infer the public base from untrusted forwarded headers.

Before public release, configure `REFERENCE_TRUST_PROXY` to match the real proxy
chain. Otherwise all users behind a reverse proxy share its IP budget. Do not use
unrestricted proxy trust. Keep the API origin inaccessible through paths that
bypass the trusted proxy. For multiple API replicas, apply a shared edge rate
limit as well; the built-in bounded limiter is deliberately per process.

To lock down later, set separate high-entropy keys in `REFERENCE_API_KEYS`, provide
them privately to your game backends and restart the API. Remove a key and restart
to revoke it. The reference module hashes keys for comparison and never logs them.
Documentation and OpenAPI remain public. Existing Top Scores app endpoints keep
their existing access behaviour.

## Storage and consistency

- `bsd_reference_competitions`: active manifest for each competition, published
  atomically after all team records have been written.
- `bsd_reference_teams`: immutable team-and-squad documents per snapshot. Keeping
  each team separate avoids putting an entire competition in a Mongo document.
- `bsd_reference_status`: last refresh attempt per competition, including failures.
- `bsd_reference_control`: renewable worker lease, preventing concurrent sweeps.
- Existing `bsd_leagues`, `bsd_teams`, `bsd_team_squads` and `bsd_players` retain
  upstream payloads. Full player profiles, never sparse squad entries, populate
  `bsd_players` in this ingestion path.

Every document includes `updated_at`. The lease uses `expires_at` for recovery.
Indexes on snapshot IDs and update times are created by the refresh worker.
Old inactive snapshot rows are removed after seven days. Active snapshots are
never removed by age, so a long BSD outage does not erase usable data.

Membership comes from BSD's league/season-filtered team list. A malformed or empty
membership response does not replace an existing competition. Truncated pages,
page-cap exhaustion, mismatched IDs, incomplete squads and failed player profiles
also leave that competition's last snapshot active. Other competitions continue.
Successful empty squads and tournament placeholders remain explicit coverage gaps.

Team and player requests are deduplicated across competitions within a refresh.
Only one background request is issued at a time, sharing the existing BSD client's
rate limiter/retry mechanism in the poller process. Live polling can use the
remaining concurrency. Bulk profile lookups avoid a request per player where BSD
supplies full profiles; national squad members missing from a club-filtered lookup
are fetched by player ID. Scouting ratings are not match ratings.

The API loads only active snapshots into a process-local catalogue. Reloads are
coalesced and occur at most once per minute after requests arrive. Warm reads use
the cached catalogue. A failed or incomplete reload preserves the previous view
and marks it stale. Exports represent one competition snapshot; global lists may
contain different competition publication times. There is no historical API.

## Verification and release

```sh
rtk npm run test:reference
rtk proxy node --test bsd_client.test.js bsd_poller.test.js player_squad_payload.test.js server.runtime_split.test.js
```

Tests use isolated router instances, fake upstream data and fake storage. They do
not start `server.js`, poll real feeds or write to Mongo. They validate all data
responses against the published JSON Schemas, game imports, failure retention,
pagination, rate limiting and optional auth. Validate proxy paths, trusted-client
IP handling, stored coverage and latency with the actual deployment before release.

Inspect `/coverage` for failed/uncollected competitions and data gaps. The poller
logs per-competition failures and reports the `game_catalogue` last-publication
timestamp in its existing metrics. Do not interpret a publication as a guarantee
that BSD contains all real-world players or non-null scouting ratings.

Public redistribution must be covered by the applicable BSD permission/terms:
https://sports.bzzoiro.com/docs/api-license/. The implementation does not grant
redistribution or media rights. Establish the public deployment arrangement before
publishing; authentication alone does not change upstream licensing requirements.
