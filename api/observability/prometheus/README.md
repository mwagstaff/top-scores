# BSD upstream alerts

`top-scores-bsd.yml` uses the existing BSD request counters from every
`job="top-scores"` scrape target. It alerts on HTTP 4xx (except 404), HTTP 5xx,
and status 0 (transport failures/timeouts). Optional resource lookups can
legitimately return 404, so these are excluded.

Any observed failure keeps its status-code alert active for ten minutes.
The one-minute pending period and existing email route normally deliver the
first notification within about three minutes of Prometheus observing it.
Ten minutes covers BSD's five-minute retry gaps. Alerts aggregate processes
and request sources by status code; inspect the counter's `source` label for
endpoint detail. Existing Alertmanager grouping combines the codes into one
notification group and repeats notifications every four hours.

The new-series branch catches the first failure when a status-code counter
does not yet have a zero baseline. A counter increase alone misses that case.
Historical, unchanged counters stop alerting after the lookback window.
Missing scrapes are covered by the existing `TargetDown` alert, not this rule.
An HTTP 200 with invalid content is outside this rule's scope.

## Validate and deploy

Run with Prometheus's `promtool` (also available in the production container):

```sh
promtool check rules top-scores-bsd.yml
promtool test rules top-scores-bsd.test.yml
```

On `sky`, install **only** `top-scores-bsd.yml` into
`/home/mwagstaff/monitoring/rules/`. Keep the test file outside that directory:
Prometheus loads every `*.yml` there as production rules.

```sh
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
docker kill --signal=HUP prometheus
docker exec alertmanager amtool config routes test \
  --config.file=/etc/alertmanager/alertmanager.yml \
  alertname=TopScoresBSDUpstreamErrors job=top-scores \
  service_name=top-scores severity=warning status_code=429
```

Verify `/api/v1/rules` on Prometheus reports `top-scores-bsd` with health `ok`
after its next evaluation. The route test should return `email`; it does not
send a synthetic notification. Existing silences and inhibition rules still
apply, including suppression when `TargetDown` fires for the same job.

To roll back, remove the installed rule file and reload Prometheus again.
No API or BSD worker restart is needed.

## Elo import alerts

Club Elo and National Elo imports use `api/elo_import_job.js`, independently of
Prometheus scraping. The complete import is attempted four times, with waits of
5, 10 and 20 seconds plus up to one second of jitter. This includes HTTP errors,
timeouts, invalid content and stale Club Elo publication dates. National Elo's
inner HTTP retry count is one in the scheduled job to avoid multiplying retries;
its standalone CLI retains its existing request retry settings. Overlapping
runs of the same import are skipped while the retry sequence is active.

Only an exhausted job posts `TopScoresEloImportFailed` to Alertmanager. The alert
includes its source, final error, attempt count and last dataset update. Successful
jobs post a resolved event, also clearing failures from before a scraper restart.
A resolved event without an existing firing alert does not produce a failure notification.
The disabled Club Elo fixtures feed and FootballDatabase are not covered.

On sky, the default destination is the active platform Alertmanager at
`http://127.0.0.1:19093`, which routes ordinary alerts to AIOps and Pushover.
The retired email Alertmanager on port `9093` is no longer a destination.
Override with the comma-separated `ELO_ALERTMANAGER_URLS` environment variable
on other hosts. Credentials and recipients remain managed by those services.
Each destination gets up to three delivery attempts (1- and 2-second backoff,
10-second request timeout); a delivery failure is logged without blocking the
other destination or re-running the import.

Existing Alertmanager routes control notification grouping, silencing, resolved
notifications and four-hour repeats. Failed-job alerts have a 24-hour expiry;
the normal 12-hour import renews an ongoing failure. If the scraper itself stops,
this alert will eventually expire; process/target monitoring must cover that case.
Deploy the new module with `server.js` and restart the scraper through the normal
deployment process. No new Prometheus rules or Alertmanager credentials are needed.

Validation:

```sh
node --test api/elo_import_job.test.js api/fetch_club_elo_rankings.test.js
```

The delivery tests mock Alertmanager, check the default destination for failure
and recovery, and preserve environment overrides and independent delivery retries.
On 22 October 2026, production checks confirmed port `9093` refused connections,
port `19093` was ready, and `amtool config routes test` selected `aiops,pushover`
for the existing Elo alert labels. No synthetic notifications were sent; this
checks receiver selection rather than end-to-end delivery or recovery ownership.
Deploy the module and restart the scraper through the normal deployment process
to apply the corrected default. A temporary configuration alternative is
`ELO_ALERTMANAGER_URLS=http://127.0.0.1:19093`, also requiring a scraper restart.
