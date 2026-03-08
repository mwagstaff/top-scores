# Cache Invalidation Runbook

This document covers the server-driven correction flow for clearing bad cached match data from the API, iOS app cache, widgets, watch sync payloads, and BBC live overlay state.

## Purpose

Use this when:

- bad match data has already been served and cached by clients
- app data remains stale after the API has been corrected
- you need a server-triggered refresh path for future incidents

## How It Works

- The server maintains monotonic cache generations for:
  - `matches`
  - `match_details`
  - `bbc_live`
- The current generations are exposed at `GET /api/v1/cache-state`.
- The iOS app compares the latest server generations with its locally stored generations before refresh.
- If a generation increases, the app clears affected local/shared caches and fetches fresh data.

## Full Correction

Invalidate all match-related caches with:

```bash
curl -X POST https://api.skynolimit.dev/top-scores/api/v1/admin/cache-state/invalidate \
  -H 'Content-Type: application/json' \
  -d '{"domains":["matches","match_details","bbc_live"],"reason":"clear bad cached match data"}'
```

Expected response shape:

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

## Scoped Correction

Invalidate only one domain when the issue is isolated:

```bash
curl -X POST https://api.skynolimit.dev/top-scores/api/v1/admin/cache-state/invalidate \
  -H 'Content-Type: application/json' \
  -d '{"domains":["bbc_live"],"reason":"clear stale bbc live overlay"}'
```

Supported domains:

- `matches`
- `match_details`
- `bbc_live`

## Inspect Current Generations

```bash
curl https://api.skynolimit.dev/top-scores/api/v1/cache-state
```

## Operational Notes

- A generation bump does not mutate historic payloads already stored on devices; it tells updated clients to discard them and refetch.
- This correction flow only works on app builds that include generation-aware cache invalidation logic.
- Older app builds will continue using their previous cache behavior until manually refreshed, relaunched, or updated.
