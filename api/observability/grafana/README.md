# Top Scores Grafana

The public Grafana on Sky (`127.0.0.1:3001`, public `/grafana/`) uses
`top-scores-prometheus` to read Mini's active Prometheus through Mini Grafana's
authenticated datasource proxy. The former Docker URL `http://prometheus:9090`
is retired. Prometheus itself remains private on loopback port 19090.

The existing Viewer credential is stored on Sky as
`~/.local/share/server-tooling-monitoring/secrets/KIDSPLORERS_GRAFANA_READER`.
Despite its historical name, it reads the shared monitoring datasource.
The local Grafana administrator password is in the adjacent `GRAFANA_PASSWORD`
file. Do not print either credential.

## Repair and verification

Copy this directory to `~/dev/top-scores/observability/grafana/` on Sky. Run:

```sh
python3 observability/grafana/reconnect.py --apply
```

This preflights the active application scrapes, backs up all dashboards in the
`top-scores-dashboards` folder and the datasource configuration under the private
monitoring `backups/` directory, reconnects the datasource, and migrates obsolete
job/instance selectors while preserving live layouts and folder membership.
Backups contain Grafana's redacted datasource configuration, not secret values;
existing secure credentials remain in Grafana and the private secrets files.
No applications, Prometheus instances, or alert rules are restarted or modified.

Run without `--apply` for a read-only datasource health check and execution of
every visible Prometheus panel target through Grafana's `/api/ds/query` over six
hours, using the saved variable defaults. The report distinguishes query errors
from empty results. Dashboard-specific transformations and alternate variable
selections still need browser verification.

Current application job names are `app-top-scores`, `app-top-scores-bsd`,
`app-top-scores-monitor`, `app-top-scores-scraper`, and `app-top-scores-audit`.
The gateway gives them the same instance address, so runtime dashboards select
the exact job rather than the old application port. Combined application queries
use `job=~"app-top-scores(|-.*)"`.

`import-dashboards.sh` now preserves the existing datasource URL and secure
headers unless `PROM_DS_URL` is explicitly supplied. For the active estate, leave
`PROM_CONFIG_HOST` unset: scrape configuration belongs to server-tooling's
monitoring platform, not the importer's legacy Docker setup.

## Verification on 6 November 2026

All 18 dashboards in the Top Scores folder passed: 302 visible panel queries,
zero query errors. All 20 BSD targets returned data, as did all runtime, Redis,
match audit, and match hydration targets. The datasource health check passed.

Empty results remain in old BBC source, Live Football On TV, and TheSportsDB
dashboards. BSD is now the canonical sports provider; these old panels do not
prove a failure of BSD ingestion. Other empty results include some audience and
Live Activity event metrics, FPL failure/duration metrics, and FootballDatabase
data age. Query success does not prove those metrics are being collected or that
every application is healthy. Do not replace missing metrics with fabricated
zeroes or remove historical dashboards as part of a connection repair.

## BSD bad URL evidence

The **Top Bad URLs by Query String and Status** table uses an independently
ranked set of up to 100 failed URL/status combinations per process, so high
success volume cannot displace rare failures. It includes HTTP 4xx/5xx and
transport failures (status 0), with URL query strings, source, count, and the
last failure timestamp in UTC. Use the panel menu → Inspect → Data → Download
CSV to share evidence with BSD. No authentication headers are exported.

Counts are gauges over the process rolling window (six hours by default),
evaluated at the dashboard end time; they are not counts over the time-picker
range. Restarting the process clears its in-memory evidence. Historical samples
remain queryable in Prometheus by selecting an earlier end time, subject to
retention. An empty table means no retained failed URLs, not proof that no
failures occurred. The new metrics cannot reconstruct URLs omitted by the old
top-100 all-status table. The table includes 404s; the upstream alert excludes
them. Alert rules and recovery permissions were unchanged.

For incident INC-d35279a1-20261106T0739Z, the first available 502 counter sample
was at 07:38:30 UTC on 6 November 2026: one `bsd_social` request from the API
process, with a 44 ms recorded duration. The counter remained at one through
07:50. The alert fired at 07:39:33 and resolved at 07:48:33; its ten-minute
lookback explains the duration, rather than continuous upstream failure. The
URL query parameters and upstream response body/request ID were not retained.
