# Top Scores

Top Scores is a multi-surface football scores project with a Node/Express API, an iOS app, widgets/watch integrations, and a web frontend.

## Repository Structure

- [`api`](/Users/mwagstaff/dev/top-scores/api)
  - Main backend and data ingestion pipeline.
  - `server.js` is the primary API entry point.
  - `fetch_*.js` scripts pull data from BBC Sport, Football on TV, Club Elo, Football Database, and National Elo sources.
  - `redis_client.js` handles Redis-backed operational state and persistence.
  - Admin/test harness HTML files and API-side tests also live here.
- [`ios`](/Users/mwagstaff/dev/top-scores/ios)
  - Native Apple client code.
  - [`Top Scores`](/Users/mwagstaff/dev/top-scores/ios/Top%20Scores) contains the app, widgets, watch app, share extension, and tests.
  - The app layer includes API access, local caching, shared app-group sync, widgets, watch sync, and background refresh handling.
- [`web`](/Users/mwagstaff/dev/top-scores/web)
  - Web frontend and static assets.
  - Includes source under [`src`](/Users/mwagstaff/dev/top-scores/web/src), public assets, scripts, and built output.

## Key Components

- Match aggregation
  - The backend merges multiple upstream feeds into a unified match dataset for fixtures, live matches, results, and details.
- Match details enrichment
  - BBC match detail pages are parsed for scores, statuses, scorers, assists, red cards, and lineups.
- Operational state
  - Redis-backed datasets store merged matches, match details, tables, rankings, and other cached operational data.
- iOS caching and sync
  - The iOS app keeps a local cache, shared app-group payloads for widgets/watch, and background refresh logic.
- Rankings and tables
  - Separate ingestion paths supply Premier League teams, league tables, and club/national ranking datasets.
- Admin and test tooling
  - The API includes admin pages, backfill tooling, and a test harness for simulated match flows.

## Important Documents

- Cache invalidation / full correction runbook:
  - [CACHE_INVALIDATION_RUNBOOK.md](/Users/mwagstaff/dev/top-scores/CACHE_INVALIDATION_RUNBOOK.md)
- Push notification notes:
  - [PUSH_NOTIFICATIONS_README.md](/Users/mwagstaff/dev/top-scores/PUSH_NOTIFICATIONS_README.md)
- Live Activity troubleshooting runbook:
  - [LIVE_ACTIVITY_TROUBLESHOOTING.md](/Users/mwagstaff/dev/top-scores/LIVE_ACTIVITY_TROUBLESHOOTING.md)
- Redis preference sync notes:
  - [REDIS_PREFERENCES_SYNC.md](/Users/mwagstaff/dev/top-scores/REDIS_PREFERENCES_SYNC.md)
- Widget implementation notes:
  - [WIDGET_IMPLEMENTATION.md](/Users/mwagstaff/dev/top-scores/WIDGET_IMPLEMENTATION.md)
- API backfill notes:
  - [BACKFILL_README.md](/Users/mwagstaff/dev/top-scores/api/BACKFILL_README.md)
- API test harness notes:
  - [TEST_HARNESS_README.md](/Users/mwagstaff/dev/top-scores/api/TEST_HARNESS_README.md)
