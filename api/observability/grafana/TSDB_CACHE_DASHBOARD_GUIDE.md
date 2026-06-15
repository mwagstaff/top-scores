# TheSportsDB Cache Dashboard Guide

This dashboard tracks Mongo-backed cache coverage for TheSportsDB supplemental data.
It is not a live match-health dashboard. It answers:

- Can the API read Mongo cache observability data?
- How many expected SportsDB records are cached?
- Which collections still have missing records?
- How quickly is the cache filling?
- Which cached records are due to be refreshed?

The dashboard definition lives in `api/observability/grafana/dashboards/tsdb-cache-dashboard.json`.
The Prometheus metrics are emitted from `appendTsdbCachePrometheusMetrics` in `api/server.js`.
The Mongo snapshot is built by `getTsdbCacheObservabilitySnapshot` in `api/mongo_client.js`.

## Collections

The dashboard tracks four Mongo collections:

| Collection | What it stores | Expected records are derived from |
| --- | --- | --- |
| `players` | Cached SportsDB player payloads | Player IDs found in cached `match_lineups` payloads |
| `teams` | Cached SportsDB team payloads | Home/away team IDs found in numeric SportsDB `matches` records |
| `match_lineups` | Cached `/lookup/event_lineup/{eventId}` payloads | Numeric SportsDB match IDs in `matches` |
| `match_timelines` | Cached `/lookup/event_timeline/{eventId}` payloads | Numeric SportsDB match IDs in `matches` |

`expected` is therefore dynamic. It is not a fixed target configured in Grafana.
As more SportsDB matches or lineups are discovered, expected counts can increase.

## Top Row

### Mongo Cache Metrics

Query:

```promql
top_scores_tsdb_cache_mongo_available{job="top-scores"}
```

`Available` means that a scraped Top Scores process was able to build a Mongo cache observability snapshot.
`Unavailable` means that process could not read Mongo for this metric snapshot, or has not successfully refreshed it.

If you see three values in this panel, Grafana is showing three Prometheus series for the same query. In this deployment that usually means multiple Top Scores Node processes are being scraped under `job="top-scores"`: API, scraper, and monitor/runtime processes. The panel is not three different checks; it is one check per scraped instance.

### Snapshot Age

Query:

```promql
time() - top_scores_tsdb_cache_snapshot_refreshed_timestamp_seconds{job="top-scores"}
```

This is the age of each scraped process's latest cache-observability snapshot.

Interpretation:

- Green: the process refreshed the snapshot recently.
- Orange/red: that process has stale observability data.
- Very large values, for example years: that process is exporting the initial `0` timestamp or has never refreshed the snapshot successfully.

If you see three values, the same multi-instance explanation applies: one age per scraped process.

### Outstanding Records

Query:

```promql
sum(top_scores_tsdb_cache_missing_records{job="top-scores"})
```

Total missing expected records across all tracked collections and scraped series.
Because this uses `sum(...)`, duplicate scraped instances can inflate the number if more than one process exports the same Mongo-derived snapshot.

Best use: trend direction, not an exact operational count, unless the query is constrained to the canonical instance.

### Overall Completion

Query:

```promql
sum(top_scores_tsdb_cache_expected_records{job="top-scores"} - top_scores_tsdb_cache_missing_records{job="top-scores"})
/
clamp_min(sum(top_scores_tsdb_cache_expected_records{job="top-scores"}), 1)
```

This is:

```text
(expected - missing) / expected
```

It can go down if expected records increase faster than cached records are created.

### Due For Refresh

Query:

```promql
sum(top_scores_tsdb_cache_due_records{job="top-scores"})
```

Counts cached non-final records whose `next_refresh_at_ms` is in the past.

This is different from missing records:

- Missing: expected record does not exist in the cache collection.
- Due: record exists, but is non-final and scheduled for refresh.

### ETA At 30m Rate

Query:

```promql
sum(top_scores_tsdb_cache_missing_records{job="top-scores"})
/
clamp_min(sum(increase(top_scores_tsdb_cache_records{job="top-scores"}[30m])) / 1800, 0.001)
```

This estimates:

```text
missing records / recent cached-records-per-second
```

It is useful only as a rough directional estimate. It can be misleading when:

- expected records are still increasing;
- multiple instances are exporting duplicate series;
- cache inserts are bursty;
- a collection is waiting on rate-limited or scheduled refresh work;
- the last 30 minutes had little activity, causing the denominator to be very small.

## Main Time-Series Panels

### Cached vs Expected Records

Queries:

```promql
top_scores_tsdb_cache_records{job="top-scores"}
top_scores_tsdb_cache_expected_records{job="top-scores"}
```

This compares current cache size with the dynamic expected set for each collection.

Important details:

- `match_lineups expected` and `match_timelines expected` usually track the same number, because both are expected for each numeric SportsDB match ID.
- `players expected` depends on IDs extracted from cached lineup payloads. It can rise as more lineups are cached.
- `teams expected` depends on team IDs in cached SportsDB match records. It can rise as more match records with team IDs are discovered.
- `cached` can rise while `completion` stays flat or drops if `expected` rises at the same time.

#### Why progress looks slow

Progress is slow because this cache fill is intentionally incremental, not a one-shot bulk migration.

The supplemental cache refresher is configured in `api/server.js`:

```text
TSDB_SUPPLEMENTAL_CACHE_INTERVAL_MS default: 30 seconds
TSDB_SUPPLEMENTAL_CACHE_BATCH_SIZE default: 25 matches
TSDB_SUPPLEMENTAL_CACHE_CONCURRENCY default: 2
```

Each candidate match can require multiple external lookups:

- event timeline;
- event lineup;
- team cache warmups;
- player cache warmups.

The code also treats finished/final records differently from non-final records, respects `next_refresh_at_ms`, and warms player/team data with low concurrency. That protects TheSportsDB and keeps the app responsive, but it means thousands of expected lineups/timelines will take time.

In your screenshots, expected lineups/timelines are around `7.95K`, while cached lineups are around `1.5K-1.6K`. With a 25-match batch every 30 seconds, plus concurrency and freshness checks, this dashboard should be read as a gradual backfill curve rather than an immediate catch-up job.

### Outstanding Records By Collection

Query:

```promql
top_scores_tsdb_cache_missing_records{job="top-scores"}
```

This shows which collections dominate the missing total.

Typical interpretation:

- Large `match_lineups missing` or `match_timelines missing`: many known SportsDB matches still do not have supplemental payloads cached.
- `players missing`: player cache is behind the lineups that discovered those player IDs.
- `teams missing`: team cache is behind the match records that discovered team IDs.

### Completion Ratio

Query:

```promql
top_scores_tsdb_cache_completion_ratio{job="top-scores"}
```

Per collection:

```text
(expected_count - missing_count) / expected_count
```

#### Why `teams` can go down

`teams` completion can go down even when the absolute number of cached teams rises.

Reason: expected teams are dynamic. They are built from home/away team IDs found in numeric SportsDB match records. If the system discovers many new team IDs before the team-cache warmer has fetched those team payloads, the denominator increases immediately and the ratio falls.

Example:

```text
Before:
cached teams = 350
expected teams = 550
completion = 63.6%

After discovering more team IDs:
cached teams = 397
expected teams = 985
completion = 40.3%
```

The cache improved in absolute terms, but coverage fell because the known universe expanded faster.

Also check whether the panel is showing duplicate series from multiple scraped instances. The tooltip can show repeated `teams` or `players` entries when multiple processes export the same metric labels except `instance`.

### Due Refresh Backlog

Query:

```promql
top_scores_tsdb_cache_due_records{job="top-scores"}
```

This is the count of cached records that exist but are due for refresh.

Use it to distinguish:

- low cache coverage: missing records are high;
- stale cache maintenance: due records are high.

## Per-Collection Stat Rows

The bottom rows repeat the same three-panel pattern for each collection.

### `<Collection> Cached`

Shows:

```promql
top_scores_tsdb_cache_records{collection="<collection>"}
top_scores_tsdb_cache_missing_records{collection="<collection>"}
```

Interpretation:

- `Cached`: documents currently in the Mongo collection.
- `Missing`: expected IDs not present in that collection.

### `<Collection> Last Update`

Shows:

```promql
top_scores_tsdb_cache_last_updated_timestamp_seconds{collection="<collection>"} * 1000
```

This is the newest `updated_at_ms` found in that collection.

Interpretation:

- Recent timestamp: cache is actively being written.
- Old timestamp: no recent writes for that collection.
- Empty/zero-looking value: no records or no valid update timestamp.

### `<Collection> ETA`

Shows:

```promql
missing_records / recent cached-record insert rate over 30 minutes
```

Same caveats as the top-row ETA:

- best for rough trend only;
- can swing heavily when recent insert rate is low;
- can be distorted by duplicate scraped instances;
- does not account for future increases in expected records.

## Why There Are 3 Values In Some Stat Panels

The dashboard queries mostly use:

```promql
{job="top-scores"}
```

They do not consistently filter by `instance`, nor do they always aggregate with `max by (...)` or `sum by (...)`.

If Prometheus scrapes multiple Top Scores processes, Grafana receives one time series per process. A stat panel with `textMode: value_and_name` displays all of those returned series side by side.

So:

- 3x `Mongo Cache Metrics` = three scraped instances exporting `top_scores_tsdb_cache_mongo_available`.
- 3x `Snapshot Age` = three scraped instances exporting `top_scores_tsdb_cache_snapshot_refreshed_timestamp_seconds`.
- Repeated legend entries in time-series panels = multiple scraped instances exporting the same collection metric.

The likely instances are the Top Scores API, scraper, and monitor/runtime processes. The node runtime dashboards already distinguish those by ports such as `3013` and `3014`; this cache dashboard currently does not.

## Recommended Reading Workflow

1. Start with `Mongo Cache Metrics`.
   If any instance is unavailable, identify which Prometheus `instance` is red.

2. Check `Snapshot Age`.
   If one value is stale or extremely old, that process is not refreshing observability. Do not trust its series.

3. Check `Cached vs Expected Records`.
   Look for expected counts rising. If expected is rising, completion ratios may fall temporarily.

4. Check `Outstanding Records By Collection`.
   Identify whether the backlog is lineups/timelines, players, or teams.

5. Check `Due Refresh Backlog`.
   If due is high but missing is stable, the issue is refresh maintenance rather than initial cache fill.

6. Use per-collection `Last Update`.
   This tells you whether the collection is still receiving writes.

7. Treat ETA as advisory.
   It is only based on the last 30 minutes of cached-record growth.

## Recommended Dashboard Improvements

The current dashboard is useful, but the duplicate series make interpretation harder.

Recommended follow-up changes:

- Add an `instance` template variable so the user can choose API, scraper, or monitor.
- For global cache state, pick the canonical writer or use `max by (collection)` to avoid duplicate Mongo-derived snapshots.
- Rename `Mongo Cache Metrics` to `Mongo Cache Available By Instance`.
- Rename `Snapshot Age` to `Snapshot Age By Instance`.
- Add an `Expected Records` stat by collection so ratio drops are easier to explain.
- Add `increase(top_scores_tsdb_cache_expected_records[30m])` beside cached growth to show when the target is expanding.

