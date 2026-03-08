# Top Scores

## Cache Invalidation / Full Correction

The API and iOS app now support server-driven cache invalidation using cache generations.

This is intended for incidents where bad data has been cached by the app, widgets, watch sync, or shared app-group storage and you need clients to drop local state and fetch fresh data without user intervention.

### How it works

- The server tracks monotonic generations for:
  - `matches`
  - `match_details`
  - `bbc_live`
- The current generations are exposed at `GET /api/v1/cache-state`.
- The app fetches cache state before refresh and clears affected local caches when a generation increases.
- The same generations are also returned as response headers on API routes.

### Trigger a full correction

To invalidate all match-related caches, call:

```bash
curl -X POST https://api.skynolimit.dev/top-scores/api/v1/admin/cache-state/invalidate \
  -H 'Content-Type: application/json' \
  -d '{"domains":["matches","match_details","bbc_live"],"reason":"clear bad cached match data"}'
```

Expected response:

```json
{
  "success": true,
  "invalidated_domains": ["matches", "match_details", "bbc_live"],
  "cache_state": {
    "updated_at": "2026-03-08T12:34:56.000Z",
    "domains": {
      "matches": { "generation": 2 },
      "match_details": { "generation": 2 },
      "bbc_live": { "generation": 2 }
    }
  }
}
```

### Trigger a scoped correction

If the issue is isolated, invalidate only the affected domain:

```bash
curl -X POST https://api.skynolimit.dev/top-scores/api/v1/admin/cache-state/invalidate \
  -H 'Content-Type: application/json' \
  -d '{"domains":["bbc_live"],"reason":"clear stale bbc live overlay"}'
```

Supported domains:

- `matches`
- `match_details`
- `bbc_live`

### Inspect current cache generations

```bash
curl https://api.skynolimit.dev/top-scores/api/v1/cache-state
```

### Important limitation

Server-triggered correction only works for app builds that include the generation-aware cache invalidation client logic. Older app builds will continue using their existing local cache behavior until they are updated or manually refreshed.
