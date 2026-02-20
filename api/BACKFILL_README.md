# Match Details Backfill Feature

## Overview

This feature implements lazy backfilling of historical match details (goal scorers, assists, red cards) for completed matches that were initially cached without detailed event data.

## The Problem

Historical matches fetched via `fetchBbcScoresFixturesByDateRange` are stored with basic match data (teams, scores, dates) but without detailed events like:
- Goal scorers (with times)
- Assists (with times)
- Red cards (with times)

This creates a data-flow gap where completed matches lack the rich detail available on their BBC Sport match pages.

## The Solution

### 1. Lazy Backfill (Per-Match)

When a client requests a specific match via `GET /api/v1/matches/:matchId`, the server now:

1. Checks if the cached match has empty event arrays
2. If empty AND a `details_url` exists:
   - Fetches the match details page HTML
   - Parses it using `parseMatchDetailsFromHtml()`
   - Enriches the cache with scorers, assists, and red cards
   - Returns the enriched data
3. Subsequent requests use the enriched cache

**Example:**
```bash
# First request triggers lazy backfill
curl http://localhost:3000/api/v1/matches/c0ke3xj52ddt

# Response includes enriched data:
{
  "id": "c0ke3xj52ddt",
  "home_team": "West Bromwich Albion",
  "away_team": "Middlesbrough",
  "home_score": 2,
  "away_score": 3,
  "home_goal_scorers": [
    { "player": "J. Maja", "goal_times": ["45+2'", "90+1'"] }
  ],
  "away_goal_scorers": [
    { "player": "B. Mbeumo", "goal_times": ["65'"] },
    { "player": "P. Dorgu", "goal_times": ["76'"] },
    { "player": "E. Fernández", "goal_times": ["82'"] }
  ],
  "home_assists": [...],
  "away_assists": [...]
}
```

### 2. Batch Backfill (Multiple Matches)

For bulk enrichment of historical matches, use the batch endpoint:

```bash
# Enrich up to 50 matches (default batch size)
curl -X POST http://localhost:3000/api/v1/matches/backfill

# Custom batch size (1-500)
curl -X POST http://localhost:3000/api/v1/matches/backfill?batch_size=100
```

**Response:**
```json
{
  "enriched_count": 47,
  "enriched_ids": ["c0ke3xj52ddt", "c043pne0q3kt", ...],
  "failed_count": 3,
  "failed_ids": ["c0ke3xj52ddc"],
  "skipped_count": 120,
  "total_candidates": 170,
  "batch_size": 50,
  "timestamp": "2026-02-14T22:30:45.123Z"
}
```

**Behavior:**
- Processes up to `batch_size` matches in parallel (respecting `MATCH_DETAILS_POLL_CONCURRENCY`)
- Only enriches matches with empty event arrays that have a `details_url`
- Returns summary of enriched, failed, and skipped matches
- Can be called multiple times to progressively enrich the full dataset

### 3. Status Monitoring

The `/api/v1/status` endpoint now includes:

```json
{
  "match_details_count": 523,
  "match_details_needs_enrichment_count": 170,
  "match_details_backfill_batch_size": 50,
  ...
}
```

## Configuration

### Environment Variables

```bash
# Maximum matches to process per batch backfill request (default: 50)
MATCH_DETAILS_BACKFILL_BATCH_SIZE=50

# Concurrency for fetching details pages (default: 20)
MATCH_DETAILS_POLL_CONCURRENCY=20
```

### Query Parameters

**Batch Backfill:**
- `batch_size`: Override default batch size (1-500)

## Implementation Details

### Core Functions

1. **`matchDetailsNeedsEnrichment(payload)`**
   - Returns `true` if match has no goal scorers, assists, or red cards
   - Used to identify candidates for backfill

2. **`GET /api/v1/matches/:matchId` (modified)**
   - Now `async` to support lazy backfill
   - Checks if enrichment needed before responding
   - Falls back gracefully on fetch errors

3. **`POST /api/v1/matches/backfill`**
   - Scans `matchDetailsById` for candidates
   - Processes in parallel batches
   - Returns detailed statistics

### Concurrency & Rate Limiting

- Batch backfill respects `MATCH_DETAILS_POLL_CONCURRENCY` (default: 20 concurrent requests)
- Each request uses the existing BBC scraper with built-in caching
- Completed match details are cached for 12 hours (existing TTL)

### Error Handling

- Failed fetches are logged but don't block the request
- Lazy backfill returns original (un-enriched) data on error
- Batch backfill tracks failed IDs for retry

## Testing

### Manual Testing

1. Find a match needing enrichment:
   ```bash
   node test_backfill.js
   ```

2. Test lazy backfill:
   ```bash
   # Start server (in separate terminal)
   npm start

   # Run test
   node test_lazy_backfill.js
   ```

3. Test batch backfill:
   ```bash
   curl -X POST http://localhost:3000/api/v1/matches/backfill?batch_size=10
   ```

### Expected Results

**Lazy backfill:** Match details should include scorers and assists after first request

**Batch backfill:** Should return summary with `enriched_count > 0`

## Migration Strategy

### Recommended Approach

1. **Deploy with lazy backfill enabled** (automatic, no action needed)
   - Matches enriched on-demand as clients request them
   - Zero downtime, gradual enrichment

2. **Optional: Bulk backfill during low traffic**
   ```bash
   # Process all matches in batches of 100
   while true; do
     response=$(curl -s -X POST http://localhost:3000/api/v1/matches/backfill?batch_size=100)
     enriched=$(echo $response | jq -r '.enriched_count')
     skipped=$(echo $response | jq -r '.skipped_count')
     echo "Enriched: $enriched, Remaining: $skipped"
     [ "$skipped" -eq 0 ] && break
     sleep 2
   done
   ```

3. **Monitor progress** via `/api/v1/status`:
   ```bash
   curl -s http://localhost:3000/api/v1/status | jq '{
     total: .match_details_count,
     needs_enrichment: .match_details_needs_enrichment_count
   }'
   ```

## Performance Considerations

### Memory
- In-memory cache (`matchDetailsById`) grows as matches are enriched
- Typical match details: ~2KB per match
- 1000 enriched matches ≈ 2MB additional memory

### Network
- Each backfill fetches full HTML page (~50-200KB)
- Batch of 50: ~5-10MB transfer
- Respects BBC's servers via concurrency limits

### Latency
- Lazy backfill adds 200-800ms to first request for a match
- Subsequent requests served from cache (instant)
- Batch backfill: ~30-60 seconds per 50 matches

## Troubleshooting

### "No enrichment happening"

1. Check match has `details_url`:
   ```bash
   curl http://localhost:3000/api/v1/matches/:matchId | jq '.details_url'
   ```

2. Check if already enriched:
   ```bash
   curl http://localhost:3000/api/v1/matches/:matchId | jq '.home_goal_scorers | length'
   ```

3. Check server logs for fetch errors

### "Batch backfill returns 0 enriched"

1. Verify candidates exist:
   ```bash
   curl http://localhost:3000/api/v1/status | jq '.match_details_needs_enrichment_count'
   ```

2. Check server logs for parsing errors
3. Verify BBC Sport pages are accessible

## Future Enhancements

Potential improvements for v2:

- [ ] Persistent storage of enriched details (write to JSON files)
- [ ] Scheduled background backfill job
- [ ] Backfill progress indicator for clients
- [ ] Per-competition backfill filtering
- [ ] Retry logic for failed fetches with exponential backoff

## Related Files

- [`server.js:1771-1820`](server.js) - Lazy backfill implementation
- [`server.js:1940-1998`](server.js) - Batch backfill endpoint
- [`fetch_bbc_scores.js:652-672`](fetch_bbc_scores.js) - HTML parser for match details
- [`test_backfill.js`](test_backfill.js) - Find matches needing enrichment
- [`test_lazy_backfill.js`](test_lazy_backfill.js) - Integration test
