# Top Scores audience and usage

The existing `top-scores-app-usage` Grafana UID now displays **Top Scores · Audience and Usage**. Import it with the existing `grafana/import-dashboards.sh` deployment workflow. No additional Grafana data source or paid plugin is required.

## Release

1. Deploy the API changes with the existing MongoDB configuration (`MONGODB_URI_TOP_SCORES`). The API creates its analytics collections and indexes automatically. No additional secret is required: a random HMAC key is created once in `app_analytics_config` and reused after restarts. Back up and restrict access to this collection with the rest of MongoDB; changing the key splits installation identities.
2. Import the updated Grafana dashboard. It keeps the existing dashboard URL. Check **Collection healthy = 1** and snapshot age below three minutes. A real zero audience is expected before the instrumented production app is used.
3. Release the instrumented iPhone/iPad app and extensions. Debug events never enter the headline audience. The dashboard starts collecting v2 audience history at rollout; legacy request counts cannot be backfilled into foreground audience history.
4. Confirm Prometheus retention covers the historical range required. Mongo retains identifier-free daily summaries beyond event expiry, but the dashboard's historical graphs use Prometheus history.

This change does not start or deploy the API automatically. The dashboard's version-specific filters refer to observed installations, not App Store download totals.

## Definitions

- Identity is the app's existing random `X-Device-Token` UUID. It is not an APNs token or a person/account identity. Reinstalls, restoration and multiple devices can change the relationship between installations and people.
- Audience includes only schema-v2, production, `ios_app`, foreground events with a valid installation ID. Screen activity can establish that an installation was active even if its app-open event was lost. Widgets, watch, website, old clients and unknown traffic are excluded.
- Today is the Europe/London calendar day, including DST. Seven and thirty days are trailing elapsed-time windows. The daily trend reports the previous completed London day. Unique counts are deduplicated across the whole window.
- App opens count foreground sessions: cold activation or return from background. Temporary inactive interruptions and multiple active windows do not create additional sessions.
- Feature reach is distinct installations with a screen-view event. Feature visits are event counts. Several features may be used by the same installation, so feature reach must not be summed to obtain total audience.
- Version, device class and OS-major breakdowns assign each installation its last observed value within the chosen window. They count installations, not events. Model-level hardware details, location, locale, search text, match IDs, account IDs and arbitrary properties are not stored in analytics.
- Live Activity starts measure successful **local foreground** starts, not push-to-start activities or notification impressions. API request state describes app lifecycle at dispatch, not proof of a deliberate user action; foreground polling remains foreground traffic.
- Audience and feature/profile panels use the explicit `today`/`7d`/`30d` selector. Event/request counters and latency use the Grafana time picker. Event rates reflect delivery time; durable audience summaries use observation time. Prometheus increases are estimates and can miss an event received before the first scrape.

## Collection and storage

`POST /api/v1/app-metrics` accepts allowlisted event/screen names. New events include `schemaVersion: 2`, a random `eventId`, `recordedAt`, `surface`, `state`, `buildType`, `appVersion`, `osVersion` and `deviceType`. Existing clients remain accepted but do not count toward v2 audience.

The app records events independently of startup data requests and persists up to 200 pending events. It retries network/429/5xx failures with backoff capped at five minutes, respecting numeric Retry-After within that bound. Events expire from the local queue after 48 hours; the oldest is dropped if the queue fills. Retries retain the event ID. Permanent 4xx validation failures are discarded. This bounded queue cannot guarantee capture of every offline session.

The API acknowledges events only after Mongo upsert succeeds. Its unique key combines keyed hashes of installation and event IDs, so retry/restart/concurrent delivery cannot double-count the event. Stored event records expire after 45 days. Daily identifier-free summaries in `app_analytics_daily` are updated for today and the prior three days to allow for delayed delivery across DST boundaries. TTL cleanup is asynchronous; query time boundaries apply independently of physical deletion.

The API refreshes its aggregate snapshot every minute using a time-indexed Mongo aggregation with a ten-second query limit. `/metrics` only reads the cached snapshot. Mongo outages return 503 to event deliveries; normal data routes remain independent. A snapshot older than three minutes is unhealthy, and audience panels suppress stale values rather than reporting zero. Metrics do not contain installation IDs or event IDs.

Requests are classified before feature-route registration. The phone sends surface, lifecycle state, app version/build and build type. Widgets identify as background; watch foreground state remains unknown. These extensions do not share the phone's installation identity for analytics. Direct requests to third-party services, such as FPL, receive no Top Scores identity headers.

## Verification

Run `node --test app_analytics.test.js server.runtime_metrics.test.js` from `api`. The Mongo integration case can also run with `APP_ANALYTICS_TEST_MONGO_URI` pointing at an isolated local Mongo instance (`mongodb://127.0.0.1:...`). It creates and drops its own randomly named test database. It never uses production credentials. The integration case checks unique counts, repeat feature visits, legacy/debug/background exclusion, deduplication after restart, metadata changes, TTL indexes and time-window expiry.

The focused iOS `AppAudienceTests` check foreground session boundaries and persistence of event IDs across queue reconstruction and retries. Build both the iOS and watch simulator schemes after changing client attribution. Validate dashboard JSON and PromQL before importing.
