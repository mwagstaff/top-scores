# Top Scores memory guardrails

These user-service drop-ins cap Node's managed heap and give systemd an early
pressure threshold plus a hard per-process ceiling. They complement the code
changes that remove the large recurring allocations; they are not a substitute
for those changes.

Install after a production canary has established the new steady-state RSS:

```sh
mkdir -p ~/.config/systemd/user/com.top-scores.{api,scraper,monitor,bsd}.service.d
cp ops/systemd/com.top-scores.api.service.d/20-memory.conf ~/.config/systemd/user/com.top-scores.api.service.d/
cp ops/systemd/com.top-scores.scraper.service.d/20-memory.conf ~/.config/systemd/user/com.top-scores.scraper.service.d/
cp ops/systemd/com.top-scores.monitor.service.d/20-memory.conf ~/.config/systemd/user/com.top-scores.monitor.service.d/
cp ops/systemd/com.top-scores.bsd.service.d/20-memory.conf ~/.config/systemd/user/com.top-scores.bsd.service.d/
systemctl --user daemon-reload
```

Restart one service at a time and observe `/metrics`, `systemctl --user status`,
and `journalctl --user-unit ...`. The checked-in limits deliberately leave RSS
headroom above the V8 heap. If the post-fix p99 RSS is above `MemoryHigh`, set
`MemoryHigh` to roughly 1.25x p99 and `MemoryMax` to roughly 1.5x p99 before
installing. `MONGODB_MAX_POOL_SIZE` can override the role defaults (API 10;
scraper, monitor and BSD 5).

The cleanup command is dry-run by default:

```sh
cd api
npm run cleanup:legacy-history
npm run cleanup:legacy-history -- --execute --batch-size=5000 --max-batches=10
```

Remove a guardrail by deleting its copied `20-memory.conf`, running
`systemctl --user daemon-reload`, and restarting that service.


## BSD memory-spike diagnostics

The API, monitor, scraper and BSD executable entry points timestamp console
messages with UTC ISO timestamps (milliseconds, `Z`) and PID, including multiline
messages. Existing log files and stdout/stderr routing are unchanged. Runtime
warnings or native crash output written directly to stderr bypass this wrapper;
retain journal/service-manager timestamps for those. Changes take effect after
deployment and the normal service restart; old lines cannot be retroactively dated.

The BSD poller additionally emits `[bsd-diagnostics]` JSON records:

- `start` / `end`: refresh and projection names, operation IDs, parent IDs,
  triggering reason where applicable, elapsed milliseconds, process memory before
  and after, deltas, and fulfilled/rejected status. A fulfilled operation can still
  contain handled per-item failures; consult its timestamped error logs.
- `sample` every 10 seconds: RSS, heap used/total, external and ArrayBuffer bytes,
  active operations and their ages, live/incident/lineup/standings activity,
  request/token queues, cache/timer counts, event-loop maximum delay and aggregate
  GC count/duration since the previous sample.
- `mongo_read` / `bsd_pagination` operations appear in active samples and emit
  completion records when they fail, return at least 1,000 records, take at least
  two seconds, or coincide with at least 32 MiB heap growth. Read records include
  collection, filter/projection presence and limit; pagination records include
  endpoint, league/team identity and total returned records.
- `request`: failed, >=2 second, or >=1 MiB BSD responses, with endpoint,
  allowlisted pagination/filter parameters, attempt, status, UTF-8 body bytes,
  list count and operation ID. Bodies, headers and arbitrary query values are
  excluded. These byte counts describe received JSON text, not parsed heap size.

For another incident, extract the same UTC window from both BSD log files and
compare it with Prometheus host/process memory and tunnel events. Follow operation
IDs to find overlapping refreshes and unusually large database reads or responses.
Memory deltas are process-wide, not allocations attributable solely to one job.
Ten-second samples can miss short peaks, and a blocked event loop delays sampling;
start/end records and event-loop delay provide complementary evidence. No heap
snapshots, forced GC or extra production database scans are performed.

The 30 September 2026 investigation measured heap used growing approximately
98 -> 1,065 -> 105 MiB around 17:47 UTC, alongside severe host pressure. That is
consistent with transient allocation/GC pressure, but does not establish which
operation caused it or prove that the poller alone caused the shared outage.
Current-match projection, paginated ingests and catalogue refreshes are candidate
allocation paths, not confirmed causes.

Next steps after deploying these diagnostics:

1. Retain and rotate both stdout and stderr logs across restarts; keep enough
   history to compare multiple daily/6-hour/hourly refresh cycles.
2. Correlate host available memory, swap-in/out, memory PSI, disk latency and
   per-service RSS with job timing. Full swap alone does not show active thrashing.
3. Validate the existing memory drop-ins above against observed peaks before
   enabling them. The incident investigation reported no active BSD memory limits.
   Limits reduce the blast radius; they do not explain or fix the allocation.
4. If a job is implicated but its allocating code remains unclear, reproduce it
   with representative data and a sampling allocation profile on an isolated
   process. Avoid automatic heap snapshots on a memory-starved shared host:
   [Node documents that snapshots block execution and can double heap usage](https://nodejs.org/en/learn/diagnostics/memory/using-heap-snapshot).

These changes do not install drop-ins or restart production services.
