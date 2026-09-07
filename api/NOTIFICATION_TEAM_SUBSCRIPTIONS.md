# BSD IDs for notification subscriptions

Club and rivalry selections use server-owned `notificationTeamSubscriptions` on
user records. Installed apps can continue sending their existing `team:<slug>`
view-option IDs. Preference saves resolve those selectors to BSD team IDs; the
notification path only compares those stored IDs with `home_team_id` and
`away_team_id`. Different, absent or invalid fixture IDs never fall back to names.
Unmigrated or unresolved club selections fail closed. The Premier League category
uses the current catalogue's BSD membership IDs, rather than name similarity.
Competition-wide selections retain their existing behavior.

Example:

```json
{
  "notificationTeamSubscriptions": {
    "version": 1,
    "provider": "bsd",
    "bindings": { "newcastle-united": "4" },
    "unresolved": {}
  }
}
```

Bindings survive catalogue renames and old-client preference saves. Changing a
selection resolves the new selector; removing it removes its binding. Canonical
catalogue selectors are preferred to search aliases. Missing or multiple BSD IDs
are recorded in `unresolved`, rather than guessed. Runtime eligibility does not
resolve names. The server can also accept `team:bsd:<id>` selectors.

## Migration

Run `scripts/migrate_notification_team_subscriptions.js` with the same MongoDB
and Redis environment as the running API. Do not assume a shell's `.env.local`
points to the production database. The script uses the existing API catalogue,
with `limit=200` and offset pagination; it does not start the API or send pushes.

- Default: preview only.
- `--apply`: write bindings to MongoDB `user_devices` and Redis preference records.
- `--backup=<path>`: private JSONL backup of prior binding fields (exclusive create).
- `--api-url=<url>`: existing API base URL; defaults to localhost port 3011.

Only the binding fields and their internal update timestamp are changed. Redis
uses compare-and-swap with KEEPTTL; MongoDB conditionally updates the preference
snapshot it read. Concurrent edits are retried. Tokens, preferences, revisions,
Live Activities and other user state are preserved. A second preview verifies
idempotence. Backup entries contain prior binding fields and a preference hash;
they contain no APNs credentials.

## Production migration, 5 September 2026

Applied to 84 MongoDB and 58 Redis records. A repeat preview found all 142
unchanged. AE874635 has 20 resolved club IDs in both stores, including Newcastle
United = BSD 4. The legacy Inter selector is ambiguous in the existing catalogue
and remains unresolved (including its use within Milan rivalry selections).
Do not infer a BSD ID from the contaminated Inter catalogue entry.

Server backup and full reports: `/tmp/top-scores-team-id-migration/` on sky.

The runtime changes are in the local working tree. Deploy
`notification_team_subscriptions.js`, `server.js` and `redis_client.js` to both API
and monitor runtimes, plus `match_monitor.js` and the corrected `team_colors.json`.
Both running processes must reload the code before ID-only enforcement is active.
No service was started or restarted as part of the migration.
