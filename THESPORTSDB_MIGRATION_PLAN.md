# Migration Plan: Replace BBC Sport scraper with TheSportsDB v2 API

Status: **PLAN ONLY — no implementation, no deploy.**
Goal: Remove **all** calls to the BBC Sport website and replace the data they provide
with TheSportsDB v2 API (`https://www.thesportsdb.com/api/v2/json`, auth header `X-API-KEY`).

## Decisions (agreed)

1. **Live-score freshness:** Accept SportsDB's ~2-minute livescore refresh (vs BBC ~30s).
2. **Push notifications:** Validate `event_timeline` depth/latency with a **production key first**, then decide the notification model. (Today push relies on BBC prose live-text, which has no SportsDB equivalent.)
3. **League coverage:** Core leagues first — the 7 leagues that already have tables, plus top European leagues. Expand later.
4. **Match identity:** Clean break to SportsDB numeric `idEvent` as the canonical key. Flush/rebuild Redis operational state and coordinate a matching iOS app release.

## BBC surface being removed

| Function | BBC endpoint | Cadence | Feeds | SportsDB replacement |
|---|---|---|---|---|
| `fetchBbcFixtures` | `/sport/football/scores-fixtures` | 30s | live score/status overlay | `GET /livescore/soccer` (1 call, all live soccer) |
| `fetchBbcScoresFixturesByDateRange` | scores-fixtures per date (−300/+90d) | 1h | broad fixtures/results | `GET /schedule/league/{idLeague}/{season}` per allowlisted league |
| `fetchBbcMatchByDetailsUrl` / `parseMatchDetailsFromHtml` | `/sport/football/live/{id}` | 10s/live match | scorers, cards, lineups, aggregate, penalties | `GET /lookup/event/{id}` + `/lookup/event_timeline/{id}` + `/lookup/event_lineup/{id}` |
| `fetchBbcLiveTextEntriesByDetailsUrl` | `…/live/{id}#LiveText` | per live match | push notifications | `event_timeline` (pending validation) |
| `fetchLeagueTables` | 7 hardcoded `/table` pages | 2min | `league_tables` | `lookup/table/{idLeague}/{season}` (path to confirm w/ prod key) |
| `fetchPremierLeagueTeams` | `/sport/football/tables` | 24h | `premier_league_teams` | `GET /list/teams/{idLeague}` |

Files to delete at the end: `fetch_bbc_scores.js`, `fetch_bbc_league_tables.js`,
`fetch_bbc_premier_league_table.js`, `test_bbc_match_details.js`, `test_subcategory.js`,
the `*bbc*` test files, `bbc_*.json` fixtures, and
`observability/grafana/dashboards/bbc-sport-dashboard.json`.

## Rate-limit design (hard cap 100 req/min)

Single shared **token-bucket limiter** in the new client, used by every SportsDB call, with a
priority queue:

1. **Live scores** — `/livescore/soccer`, ~1 call / 30–60s loop. Trivial cost; one call covers all live matches.
2. **Active-match detail** — `event`/`event_timeline`/`event_lineup` only for matches currently live or recently finished; bounded concurrency, refreshed on a slow cadence (e.g. 30–60s).
3. **Standings** — per league; slow cadence (every few minutes), staggered across the allowlist.
4. **Season schedules** — per league hourly/daily; cheap and staggered.

Also: retry-on-null (SportsDB returns transient `null` during data updates — retry after ~2s),
and a request-observer hook mirroring the existing BBC metrics so admin/status dashboards keep working.

## League allowlist (initial — "core first")

Seed from the existing 7 table leagues + top European leagues. IDs to be confirmed via
`/search/league/{name}` or `/all/leagues`:
EPL (`4328`), Championship, UEFA Champions League, Scottish Premiership, La Liga, UEFA Europa
League, UEFA Conference League, plus Bundesliga, Serie A, Ligue 1. Stored as config so the set
can grow without code changes.

## Phased work

- **Phase 0 — Validation gate.** Partially complete (see "Phase 0 results" below). Timeline +
  lineup confirmed sufficient for major leagues, so the push-notification model is decided:
  **derive notifications from `event_timeline`.** Remaining Phase 0 items: standings path/season
  format, aggregate (two-leg) and penalty-shootout coverage — confirm with a production key.
- **Phase 1 — Client layer.** ✅ DONE. `thesportsdb_client.js`: `X-API-KEY`, token-bucket
  limiter (90/min), retry-on-null, request-observer parity. 15 tests passing.
- **Phase 2 — Live scores.** ✅ DONE. `updateTsdbLivescores` calls `/livescore/soccer`
  (one call, all live soccer).
- **Phase 3 — Fixtures/results.** ✅ DONE. `updateTsdbScheduleMatches` iterates the 10-league
  allowlist via `fetchTsdbAllLeagueSchedules`.
- **Phase 4 — Match details.** ✅ DONE. `fetchTsdbMatchDetails(idEvent)` replaces
  `fetchBbcMatchByDetailsUrl(url)` at all call sites. `details_url` guard removed from the
  poll-target collector. Aggregate computed from schedule cache.
- **Phase 5 — Standings + EPL teams.** ✅ DONE (EPL teams). `updateTsdbPremierLeagueTeams`
  calls `/list/teams/{idLeague}`. Standings remain parked.
- **Phase 6 — Push notifications.** ✅ DONE. `fetchBbcLiveTextEntriesByDetailsUrl` removed from
  `match_monitor.js`. VAR confirmation falls back to consecutive-polls logic.
- **Phase 7 — Identity clean break.** ✅ DONE. `has_bbc_source` → `has_tsdb_source` globally;
  `idEvent` adopted as canonical match key; Redis dataset keys updated to `tsdb_live_matches` /
  `tsdb_schedule_matches`; all SOURCE/COMPONENT constants renamed. iOS-side update to coordinate
  separately on deploy.
- **Phase 8 — Removal.** TODO. Delete `fetch_bbc_scores.js`, `fetch_bbc_premier_league_table.js`,
  `test_bbc_match_details.js`, `test_subcategory.js`, `bbc_*.json` fixtures, and
  `observability/grafana/dashboards/bbc-sport-dashboard.json`.
  Update `ARCHITECTURE_OVERVIEW.md`.

## Phase 0 results (validated against real events)

Validated with example events `2267452` (West Ham vs Leeds, EPL) and `2452577`
(Bayern vs Real Madrid, UCL 2nd leg):

- ✅ **`event_timeline`** — rich for major leagues. Per entry: `intTime` (minute), `strTimeline`
  (`Goal`/`Card`/`subst`), `strTimelineDetail` (`Normal Goal`/`Yellow Card`/`Red Card`/
  `Substitution N`), `strPlayer`, `strAssist`, `strTeam`, `strHome`. Fully covers BBC's
  scorers + yellow/red cards + subs model. Earlier "No data found" was a sparse lower-tier
  league (Brazilian Serie B) — **coverage is league-dependent, which fits "core leagues first".**
- ✅ **`event_lineup`** — full both-team squads (22 entries): `strPosition`/`strPositionShort`,
  `strFormation`, `strHome`, `strSubstitute`, `intSquadNumber`, `strPlayer`, `idTeam`. Covers
  BBC's lineup model.
- ✅ **Team short names** — not on the event payload, but `/lookup/team/{idTeam}` carries
  `strTeamShort`; cache per team (one-off), so no functionality loss.
- ⚠️→🔧 **Aggregate (two-legged ties)** — `lookup/event` exposes only the single-leg score, no
  aggregate field. **Decision: preserve aggregate by computing it** — fetch the paired first-leg
  event and sum. Implementation: identify two-legged ties (cup rounds), resolve the first-leg
  `idEvent` (via league schedule / same teams reversed), cache the computed aggregate. Costs one
  extra event fetch per tie, cacheable.
- ✅ **Penalty-shootout progress** — derivable from `event_timeline`. Validated on `2470477`
  (PSG vs Arsenal): each kick appears at `intTime` 120 as `Goal | Penalty` (scored) or
  `Goal | Missed Penalty`, per player + team + home/away; `lookup/event` `strStatus` is `PEN`.
  Reconstruct the shootout score by counting scored penalties per side (distinguish from in-play
  penalties via the minute-120 cluster + `PEN` status).

**Push-notification decision (resolved):** derive from `event_timeline` — it carries goals,
yellow/red cards, and subs with minute + player for the leagues we're targeting.

## Open items to confirm with a production key

- Standings/table endpoint — **parked for now.** `GET /api/v2/json/lookup/table/{idLeague}/{season}`
  returns HTTP 200 + `{"Message":"Invalid ID passed"}`; no-season variant returns 200 + empty body.
  Revisit later (likely a path/season-format or production-key issue).
- Aggregate (two-legged): **preserve** — compute from the first-leg event (see Phase 0 results).
- iOS payload contract changes required by the `idEvent` clean break (separate iOS work stream).
