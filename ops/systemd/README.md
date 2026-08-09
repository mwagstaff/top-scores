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
