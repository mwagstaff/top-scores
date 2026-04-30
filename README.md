# Top Scores

Top Scores is a multi-surface football scores project with a Node/Express API, an iOS app, widgets/watch integrations, and a web frontend.

## Repository Structure

- [`api`](api)
  - Main backend and data ingestion pipeline.
  - `server.js` is the primary API entry point.
  - `fetch_*.js` scripts pull data from BBC Sport, Football on TV, Club Elo, Football Database, and National Elo sources.
  - `redis_client.js` handles Redis-backed operational state and persistence.
  - Admin/test harness HTML files and API-side tests also live here.
- [`ios`](ios)
  - Native Apple client code.
  - [`Top Scores`](ios/Top%20Scores) contains the app, widgets, watch app, share extension, and tests.
  - The app layer includes API access, local caching, shared app-group sync, widgets, watch sync, and background refresh handling.
- [`web`](web)
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

## Match Date Windows

- Server BBC scores/fixtures scraping
  - The scheduled BBC Scores & Fixtures range poller is configured in [`api/server.js`](api/server.js) with `BBC_RANGE_PAST_DAYS` and `BBC_RANGE_FUTURE_DAYS`.
  - Defaults come from [`api/fetch_bbc_scores.js`](api/fetch_bbc_scores.js): 30 days look-back and 90 days look-forward, using the `Europe/London` match timezone.
  - Operators can override the scheduled range with `BBC_RANGE_PAST_DAYS` and `BBC_RANGE_FUTURE_DAYS`. Values are floored and clamped to non-negative integers; there is no separate hard maximum in the scheduled poller code.
  - The poller enumerates every date from `today - pastDays` through `today + futureDays`, fetches each BBC dated scores/fixtures page, then persists the deduplicated result as the BBC range dataset.
- Server admin backfill
  - The admin BBC range backfill endpoint in [`api/server.js`](api/server.js) accepts explicit `start_date` and `end_date` values and enforces a maximum span of 366 days per request.
- Public matches API
  - `GET /api/v1/matches` requires `start=YYYY-MM-DD` and `end=YYYY-MM-DD`, but the route only validates date format and `start <= end`; it does not impose its own maximum date span. Results are limited by the server-side cached/scraped datasets available at the time of the request.
- iOS app client
  - The main API client in [`APIClient.swift`](ios/Top%20Scores/Top%20Scores/Services/APIClient.swift) uses broad match windows when it builds match requests: results from one year before today, and fixtures through `9999-12-31`.
  - The interactive fixtures screen in [`MatchesStore.swift`](ios/Top%20Scores/Top%20Scores/State/MatchesStore.swift) requests fixtures from today through `9999-12-31`. Fixture display is limited by the server-side scraped/cache data available for the selected filters, not by a local app end-date horizon.
  - Results history in [`MatchesStore.swift`](ios/Top%20Scores/Top%20Scores/State/MatchesStore.swift) requests results from one year before today through today and automatically loads additional result pages in the background until the server has no more data in that window.
  - Competition/category filtering is requested from the server with the user's preferences. The app keeps only date-mode filtering locally so competition names, weights, normalization, and category membership can be controlled server-side.
- Web client
  - The web match query builder in [`web/src/client/api.ts`](web/src/client/api.ts) requests fixtures from today through `9999-12-31`.
  - For results, it requests one year before today through today and automatically loads additional result pages in the background until the server has no more data in that window.
  - Competition/category filtering is sent to the server with the user's preferences; the web client still supports the explicit in-page custom competition picker as an additional display-only refinement.

## Important Documents

- Cache invalidation / full correction runbook:
  - [CACHE_INVALIDATION_RUNBOOK.md](CACHE_INVALIDATION_RUNBOOK.md)
- Push notification notes:
  - [PUSH_NOTIFICATIONS_README.md](PUSH_NOTIFICATIONS_README.md)
- Live Activity troubleshooting runbook:
  - [LIVE_ACTIVITY_TROUBLESHOOTING.md](LIVE_ACTIVITY_TROUBLESHOOTING.md)
- Redis preference sync notes:
  - [REDIS_PREFERENCES_SYNC.md](REDIS_PREFERENCES_SYNC.md)
- Widget implementation notes:
  - [WIDGET_IMPLEMENTATION.md](WIDGET_IMPLEMENTATION.md)
- API backfill notes:
  - [BACKFILL_README.md](api/BACKFILL_README.md)
- API test harness notes:
  - [TEST_HARNESS_README.md](api/TEST_HARNESS_README.md)
