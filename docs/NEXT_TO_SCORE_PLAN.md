# Next to Score — implementation plan (API, web, iOS)

Status: **plan only, nothing built yet** (2026-11-22).

## What BSD gives us (verified live against our key)

| Endpoint | Notes |
|---|---|
| `GET /api/v2/next-goal/?limit=200` | Every live match with a read, one call. Reads move once a minute, upstream cache 15s. Our token returns **200** (no `403 unlimited_required`). |
| `GET /api/v2/next-goal/{event_id}/` | Same object + `available:true`, or `{available:false, reason:"not_live"\|"too_early"}`. Finished matches return `not_live`, so there is **no post-match read**. |
| `GET /api/v2/next-goal/calls/?event_id=&date_from=&outcome=` | Graded "calls": `minute`, `side`, `team`, `probability`, `score_at_call`, `outcome` (`open/hit/miss/nogoal/unclear`), `resolved_minute`, `called_at`, `resolved_at`. |

Read shape: `event{id,status,…}`, `minute`, `score{home,away}`, `probabilities{home,away,no_goal}` (sum 1, `no_goal` may be null), `leader` (`home`/`away`/`none`; `none` = no goal is most likely), `confidence`, `is_call`, `call_threshold` (**0.7 in practice**, docs example says 0.6), `call_paused` (goal just went in, read held), `minutes_since_goal`, `evidence{momentum_5m,momentum_15m,shots_home_10m,shots_away_10m,red_cards_home,red_cards_away}`, `track_record{accuracy,base_rate,brier_skill_score,matches_evaluated}`, `generated_at`.

Observed at plan time: only 10 matches had a read, so BSD covers some live matches and not others. Matches appear from about minute 10.

## Design summary

Follow the **momentum/match-stats pattern exactly**:

- The poller writes `bsd_*` collections.
- `projectBsdMatchDetails` adds a projected `next_goal` block, with `refresh_after_seconds` driving client polling.
- Both clients normalise it and render a self-contained card.

UI reads never call upstream. The UI shows nothing when there is no read, so uncovered leagues and TSDB-sourced matches lose nothing.

```
bsd_poller ──30s while live──▶ GET /next-goal/?limit=200 ──▶ bsd_next_goal (per event, write only on change)
           ──60s while live──▶ GET /next-goal/calls/?date_from=today ──▶ bsd_next_goal_calls (per call id)
           ──on settle───────▶ GET /next-goal/calls/?event_id=X (final outcomes)
GET /api/v1/matches/:id ──▶ projectBsdMatchDetails ──▶ match.next_goal = projectNextGoal(read, calls, event)
web MatchCard / iOS MatchDetailView ──▶ NextGoalCard (live) / call outcome line (post-match)
```

## Phase 1 — API ingestion

1. **`api/bsd_client.js`**
   - Add `getNextGoal(options)`, which uses `_requestAllPages("next-goal/")` with limit 200.
   - Add `getNextGoalCalls({ eventId, dateFrom }, options)`.
   - Both reuse the existing token bucket, retry and 429 backoff, and add `module.exports` entries.
2. **New `api/bsd_next_goal.js`**, modelled on `bsd_momentum.js`'s `createMomentumIngestor`, with injectable `client`/`save`/`now` for tests:
   - `ingestNextGoalReads()`: run one bulk fetch, then filter results to `BSD_LEAGUE_ALLOWLIST` by `event.league_id`.
     - For each read, upsert `bsd_next_goal` (`_id` = event id, extra `event_id`).
     - **Skip the write when nothing material changed.** Compare a fingerprint of `minute, score, probabilities, is_call, call_paused, evidence` and ignore `generated_at`. `generated_at` changes on every poll, and per the Jul 2026 perf review an always-changing field causes a no-op write storm.
   - `ingestNextGoalCalls({ eventId?, dateFrom? })`: upsert `bsd_next_goal_calls` with `_id` = call id and an indexed top-level `event_id`. Calls are few (about 1.7k total across all of BSD), so a TTL index isn't needed. If we add one later, it must sit on a **Date** field, not a numeric one (the `match_write_logs` lesson).
   - On `403 unlimited_required`, log once, then suppress for 1h, so a plan downgrade can't spam logs or burn the rate budget.
3. **`api/bsd_poller.js`**
   - Add `pollNextGoal` (30s, `BSD_NEXT_GOAL_POLL_MS`) and `pollNextGoalCalls` (60s). Both return early when `liveEventIds` is empty and use `inFlight` guards like `pollMomentum`.
   - In the settle hook (≈ line 369, next to `ingestMomentum` on settle), call `ingestNextGoalCalls({ eventId })` once to capture final outcomes (`nogoal` resolves at full time).
   - Cost: 1 bulk request every 30s plus 1 calls request every 60s while anything is live. This is independent of match count, unlike per-match polling.
4. **Indexes:** add `bsd_next_goal_calls.event_id` wherever the other `bsd_*` indexes are ensured.

## Phase 2 — API projection

1. Add `projectNextGoal(readDoc, callDocs, event, now)` to `bsd_next_goal.js` and return **`null` (card hidden)** unless one of these holds:
   - **Live and read present** → `status: "available"`.
   - **Live, no read, minute < 15, league allowlisted** → `status: "warming_up"` ("Next-goal chances start around 10′"). After minute 15 with no read we assume no coverage and return `null`.
   - **Read is stale or out of date** → `status: "updating"`. That means `generated_at` older than 3 min, **or** the read's `score` ≠ the event's current score. The second case happens because incidents (10s) land before the next read (≤60s). Clients show the last bars dimmed with "Updating after goal…".
   - **Finished/not live and calls exist** → `status: "settled"` with calls only and no probabilities.

   Projected shape (snake_case like momentum):
   ```json
   {
     "status": "available",
     "minute": 66,
     "score": { "home": 0, "away": 0 },
     "probabilities": { "home": 0.348, "no_goal": 0.404, "away": 0.248 },
     "leader": "none",
     "is_call": false,
     "call_paused": false,
     "minutes_since_goal": null,
     "evidence": { "shots_home_10m": 2, "shots_away_10m": 1, "momentum_15m": -14.9 },
     "calls": [{ "minute": 10, "side": "away", "probability": 0.737, "outcome": "miss", "resolved_minute": 34 }],
     "updated_at": "…",
     "refresh_after_seconds": 30
   }
   ```
   `refresh_after_seconds` is 30 while live, 60 for 15 min after full time (so the last call's outcome lands), then `null`.
2. **`api/bsd_adapter.js` `projectBsdMatchDetails`** has two edits:
   - Add `bsd_next_goal` (`_id`) and `bsd_next_goal_calls` (`event_id`) reads to the existing `Promise.all`, both with `.catch(() => null)` like `statsDoc`.
   - Set `match.next_goal = projectNextGoal(...)` next to `match.momentum`.

   Details are projected per request from Mongo, so there's no server cache TTL to tune.
3. **Tests (`api/bsd_next_goal.test.js`)** cover:
   - The allowlist filter and the no-op-write fingerprint.
   - Each status branch, including score mismatch → `updating`, uncovered → `null`, and finished-with-calls → `settled`.
   - `no_goal: null` (two-way model).
   - 403 suppression.

   Use fixtures saved to `.helper_files/bsd_api/next_goal.json` and `next_goal_calls.json`.

## Phase 3 — Web

1. **New `web/src/client/nextGoal.ts`**: `normalizeNextGoal(raw)` plus types, mirroring `momentum.ts`/`matchStats.ts`. It rejects malformed probabilities and renormalises `no_goal: null` to a two-way split.
2. **`types.ts`** gets `nextGoal?: NextGoal | null` on match details.
3. **`api.ts`**
   - Set `nextGoal: normalizeNextGoal(raw.next_goal)` (≈ line 484).
   - Add `!details.nextGoal?.refresh_after_seconds` to the "details are final" check (≈ line 854).
4. **`components/MatchCard.tsx`**
   - Add `details?.nextGoal?.refresh_after_seconds` to the refresh-interval list and deps (≈ lines 139/156).
   - Render `<NextGoalCard>` between `MatchPreview` and `MatchAnalysisCard` when `details?.nextGoal` is set.
5. **New `components/NextGoalCard.tsx`:**
   - Heading "Next goal".
   - One horizontal 3-segment bar: home team colour | neutral "No goal" | away team colour. Colours come from `momentumColors(catalog.lineupColors…)` so the card matches the momentum chart.
   - Percentages under each segment, with the leader in bold.
   - Chips:
     - "Strong call" when `is_call`
     - "Paused after goal" when `call_paused`
     - "Updating…" when `status === "updating"`
   - Muted evidence line: "Shots, last 10′: 2–1".
   - `settled` renders just the call line, e.g. "10′ · Called Real Madrid to score next (74%) · Missed — Granada scored 34′".
   - Accessibility: `role="img"` with a full-sentence `aria-label`. Width transitions sit behind `prefers-reduced-motion: no-preference`.
6. **CSS** goes in `styles.css` beside the `.momentum-*` rules, reusing the analysis-card surface tokens.
7. **Test:** add `web/tests/next-goal.test.ts` (normaliser + label formatting), alongside `momentum.test.ts`.

## Phase 4 — iOS

1. **Model:** new `Models/NextGoal.swift` (the project uses synchronized folders, so no pbxproj edit is needed). In `Match.swift`:
   - Add `let nextGoal: NextGoal?` to match details, with `case nextGoal = "next_goal"`.
   - Decode with `try? container.decodeIfPresent` like momentum (≈ line 809), so a bad block never breaks details decoding.
2. **`Views/MatchDetailView.swift`**
   - Add `@State private var nextGoal: NextGoal?`, reset it with momentum (≈ line 572), and assign it from cache and fresh details (≈ lines 611, 727).
   - Include `details.nextGoal?.refreshAfterSeconds` in the "stop refreshing" check (≈ line 744) and in `refreshIntervalNanos` for the finished case (≈ line 816). The live path already refreshes every 10s.
   - Render `NextGoalCard` just above `MatchAnalysisCard` (≈ line 279) when `nextGoal != nil`.
3. **New `Views/NextGoalCard.swift`:**
   - The same layout as the web card.
   - Colours from `MatchAnalysisPalette`.
   - Segment widths animate with `.animation(.smooth, value:)`, disabled under `accessibilityReduceMotion`.
   - `accessibilityElement(children: .ignore)` with a single sentence label.
   - Monospaced digits for percentages.
4. **Tests:** add `Top ScoresTests/NextGoalTests.swift` for decoding (including `no_goal: null` and an unknown status), the status-to-chip mapping, and the accessibility label.
5. **Build:** run `xcodebuild` build + test for the app scheme.

## Phase 5 — Verify and roll out

- Local: point at sky Mongo data during a live window. Confirm `GET /api/v1/matches/:id` returns `next_goal` for a covered live match and omits it for an uncovered one.
- Write-rate check: after an hour of live play, `bsd_next_goal` `updated_at` writes should be about 1/min per covered match, not 2/min.
- Deploy API → web → iOS (TestFlight). Older app builds ignore the unknown key.
- Monitoring: optionally add a `bsd_next_goal` freshness signal to existing BSD diagnostics (`bsd_diagnostics.js`). If it becomes an alert, follow `server-tooling/monitoring/ALERTING.md` first.

## Open decisions

1. **Placement:** a standalone card above Match analysis (recommended: it's the most glanceable live item) vs a third tab in the Momentum | Stats picker.
2. **Post-match:** show the graded call outcome line (recommended, cheap) vs hide the feature entirely once the match ends (which would drop the calls collection and polling).
3. **Track record footnote** ("71% accuracy over 4,479 matches"): BSD doesn't define `accuracy`/`base_rate`, so recommend **omitting** it until clarified via their MCP.
4. **Copy tone:** keep wording as "chance"/"likely", with no odds or betting language, to stay clear of App Store gambling-adjacent review.

## Out of scope / possible follow-ups

- Next-goal chances on Live Activities and widgets.
- A push notification when a strong call is made for a followed team.
- Showing a leader badge in the scores list.
