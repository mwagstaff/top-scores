# Match momentum

Both match-detail clients show a momentum card above Key events / Commentary when BSD has usable data. It uses the provider's relative pressure, not possession or win probability. Home is above zero and away below. Team labels and event descriptions supplement colour; dark or clashing colours have readable alternatives.

## Data flow

`bsd_client.getEventStats` reads `/api/v2/events/{id}/stats/`. This single-match endpoint rejects `limit`/`offset` (HTTP 400); unlike list APIs it is not paginated. The existing client handles authentication, shared concurrency/rate limits and retry/backoff.

The BSD poller upserts the full response into `bsd_event_stats`, keyed by event ID, with the standard internal `updated_at` timestamp. Live matches refresh every 60 seconds with two workers. Post-match settlement at 0, 2 and 15 minutes refreshes momentum without holding up final-score publication.

On startup and every minute, a batch of at most 20 finished matches from the preceding 14 days is selected from the configured competition allowlist. Already checked matches, including empty coverage, are retried after 24 hours. Failed IDs cool down for 15 minutes without blocking other backfill candidates. Existing older graphs remain stored; there is no historical scan outside the 14-day window and no deletion of retained graphs.

`projectBsdMatchDetails` reads only the stored momentum series/timestamp alongside its existing reads. No client request waits for BSD. Fixture-list responses do not acquire graph payloads. Old clients ignore the optional `momentum` field; new clients accept its absence during rollout.

## Timeline and annotations

Sampled regulation and extra-time responses use fractional buckets `45.5`, `90.5`, `105.5` and `120.5` for period added time. Incident added-time markers use those positions while preserving labels such as `90+5′`. The x-axis extends for extra time; shootout events are excluded. Half-time is after the first added-time bucket.

Areas use linear interpolation, split at zero crossings, missing minutes and period boundaries. A common symmetric scale has a floor of ±100 and expands for larger provider values. No numerical percentage is displayed. Missing coverage hides the card rather than fabricating a flat line.

Goals (including own/penalty goals), red/second-yellow cards, missed penalties and confirmed disallowed goals have team-specific markers. Own goals use the credited team as BSD specifies. Rescinded events are excluded. VAR uses the provider's decision/confirmation pair; unconfirmed reviews are not shown as outcomes. A disallowed goal with the same player/time/side removes a duplicate goal marker; unrelated reviews are not heuristically matched. Rebuilt snapshots replace prior annotations so corrected/removed events disappear.

Overlapping markers receive separate lanes with 44-point/pixel targets. Tap/click and keyboard activation expose the full minute, team, event and player. SwiftUI supports light/dark appearance and larger text; the website retains its dark theme.

## Refresh and rollout

Live details use existing refresh loops. Finished matches keep refreshing while momentum is pending within the backfill window or within five hours of kickoff; once checked and settled, they stop graph-driven polling. Reopening details fetches the stored result again. Transport errors retain the last successful client response. Normal successful empty coverage is authoritative.

Deploy the API and BSD poller before the website/iOS release. The poller's startup/minute job performs the bounded backfill automatically. Implementation alone does not run the production backfill. Verify stored `bsd_event_stats` records and timestamps, a live response, a result from the last 14 days, an extra-time match and an uncovered match after deployment.

Focused checks: `node --test api/bsd_momentum.test.js api/bsd_poller.test.js api/bsd_adapter.test.js api/bsd_client.test.js`, web momentum tests/typecheck/build, and iOS `MatchMomentumTests`, `MatchMomentumRenderingTests`, `MatchDetailsCacheTests`. Rendering tests attach light/dark/large-text charts to the Xcode test result.
