# TV Listings Migration Plan: live-footballontv.com → TheSportsDB TV API

Status: **PLAN ONLY — no implementation yet.**

Goal: Remove the `live-footballontv.com` scraper entirely and replace TV
channel data with the TheSportsDB TV filter API.  Also replace the current
flat `tv_channels: [String]` payload with a structured, country-aware shape
that powers locale-filtered display in both the web client and the iOS app.

---

## Context

The `live_football_on_tv` source (scraping `live-footballontv.com`) has always
been a hybrid: it supplied both fixture data **and** TV channels.  After the
BBC→TSDB migration (Phases 1–7) it stopped being the fixture source — TSDB
schedule fixtures survive the merge (`has_tsdb_source` filter).  Today its
only remaining job is grafting TV channel strings onto TSDB fixtures via a
fuzzy team-name identity match in `mergeTsdbAndLiveMatches`.

The TheSportsDB TV API (`GET /api/v2/json/filter/tv/sport/soccer`) provides
channel data keyed directly by `idEvent`, eliminating the fuzzy join.  An
example response is in `log.txt`.

This work sits logically after Phase 7 and before Phase 8 of
`THESPORTSDB_MIGRATION_PLAN.md`, so it is numbered **Phase 9** here.  Phase 8
(BBC file deletion) can proceed independently or be batched with this work.

---

## TheSportsDB TV API record shape (from `log.txt`)

```json
{
  "id": "1175810",
  "idEvent": "2454916",
  "strSport": "Soccer",
  "strEvent": "Wales vs Ghana",
  "idChannel": "6389",
  "strCountry": "United Kingdom",
  "strChannel": "S4C",
  "strLogo": "https://r2.thesportsdb.com/images/media/channel/logo/...",
  "strSeason": "2026",
  "strTime": "18:45:00",
  "dateEvent": "2026-06-02",
  "strTimeStamp": "2026-06-02 18:45:00"
}
```

One row per (event × channel).  Multiple rows share `idEvent` when a match is
broadcast on several channels or in several territories.

---

## New payload shape: `tv_channels`

Replace the flat `[String]` with a structured array:

```jsonc
"tv_channels": [
  {
    "name": "BBC One Wales",       // strChannel
    "country": "United Kingdom",   // strCountry (display name)
    "countryCode": "GB",           // ISO 3166-1 alpha-2 — see mapping note below
    "logo": "https://..."          // strLogo (may be null/empty)
  }
]
```

**Country code mapping:** `strCountry` is a free-text display name from TSDB.
A static lookup table in `api/fetch_tsdb_tv.js` maps the ~20–30 most common
country display names to ISO codes.  Unmapped entries get `countryCode: null`
and still appear in the "all regions" grid with flag omitted.  The lookup is
easy to extend without code changes (just add an entry).

**Backward compatibility:** During the iOS rollout window (coordinated with the
`idEvent` clean break), emit both the new structured array and a
`tv_channel_names: [String]` (flat names only) alongside it.  Drop the flat
field once the old app build is no longer live.

---

## Display behaviour (agreed)

### Fixture list card (compact)
- Resolve the user's region from device/browser locale (web: `navigator.language`
  / `Intl.DisplayNames`; iOS: `Locale.current.region`).
- Show the TV badge/logo **only** for channels where `countryCode` matches the
  user's region.  No match → no TV icon.

### Match details page (tap-through) — new "Where to watch" section
- Always rendered when `tv_channels.length > 0`, regardless of locale.
- Displayed by default (not collapsed) at the bottom of the details screen.
- Grouped by country; user's own locale country sorted first, others
  alphabetically by `country` display name.
- Each row/cell: **flag emoji (from `countryCode`) · country name · channel
  logo (from `logo`) · channel name**.
- Present on both the web expanded details (`ExpandedMatchDetails`) and the
  iOS match details screen.

---

## Phases

### Phase 9a — Validation gate

Before deleting the scraper, confirm the TV API covers our 10 allowlisted
leagues with usable `idEvent`s that match the schedule cache.

Steps:
1. Call `GET /filter/tv/sport/soccer` with the production key and sample a
   week's worth of results.
2. Cross-reference returned `idEvent` values against `tsdb_schedule_matches.json`
   to confirm overlap for EPL, UCL, and at least 3 other allowlisted leagues.
3. If coverage is adequate → proceed.  If gaps exist, keep the scraper running
   in parallel while coverage improves (set a flag `TV_SCRAPER_FALLBACK=true`).

Estimated cost: 1 API call per poll, negligible against the 90/min budget.

---

### Phase 9b — API client method

**File:** `api/thesportsdb_client.js`

Add one method after the existing schedule methods:

```js
function getTvListings(options = {}) {
  return _request("/filter/tv/sport/soccer", {
    source: "tsdb_tv",
    reason: "tv_listings_fetch",
    ...options,
  });
}
```

Export it alongside the others.  No other changes to the client.

---

### Phase 9c — TV fetch module

**New file:** `api/fetch_tsdb_tv.js`

Responsibilities:
- Call `getTvListings()`.
- Group rows by `idEvent` into `Map<String, TvChannel[]>`.
- Normalise each row to `{ name, country, countryCode, logo }` (dedup within
  the same `idEvent`).
- Expose `fetchTsdbTvListings(options)` returning the Map, and
  `fetchTsdbTvListingsArray(options)` returning a plain array for persistence.

Country display-name → ISO code lookup lives here as a module-level constant.
Seed it with the countries present in `log.txt` plus the UK territories.

**New file:** `api/fetch_tsdb_tv.test.js`

Unit tests using `log.txt` as the fixture (same pattern as
`fetch_tsdb_matches.test.js`).  Cover: grouping by `idEvent`, deduplication,
`countryCode` mapping, null logo handling.

---

### Phase 9d — Server-side poller

**File:** `api/server.js`

**Config constants** (follow the `EPL_INTERVAL_HOURS`/`EPL_INTERVAL_MS`
precedent at line 158–161):

```js
const TSDB_TV_OUTPUT_PATH =
  process.env.TSDB_TV_OUTPUT_PATH || path.join(__dirname, "tsdb_tv_listings.json");
const TSDB_TV_INTERVAL_HOURS = Number(process.env.TSDB_TV_INTERVAL_HOURS || 2);
const TSDB_TV_INTERVAL_MS = Number(
  process.env.TSDB_TV_UPDATE_INTERVAL_MS ||
  TSDB_TV_INTERVAL_HOURS * 60 * 60 * 1000
);
```

`TSDB_TV_UPDATE_INTERVAL_MS` overrides directly (useful for testing with a
shorter interval without changing the hours constant).

**Source/component constants:**

```js
const SOURCE_TSDB_TV = "tsdb_tv_listings";
const COMPONENT_SOURCE_TSDB_TV = "source_tsdb_tv";
```

**In-memory state:**

```js
let cachedTvListingsByEvent = new Map(); // idEvent → TvChannel[]
let tsdbTvLastUpdated = null;
```

**`updateTsdbTvListings()` function** — modelled on `updateTsdbScheduleMatches`:
- Calls `fetchTsdbTvListings()`.
- Stores result in `cachedTvListingsByEvent`.
- Writes snapshot JSON to `TSDB_TV_OUTPUT_PATH`.
- Persists to `OP_DATASET_TV_LISTINGS` operational dataset.
- Calls `rebuildMergedMatchesCache("tsdb_tv")` when data changes.
- Records `COMPONENT_SOURCE_TSDB_TV` start/success/failure metrics.
- Calls `setSourceCacheSize(SOURCE_TSDB_TV, ...)` for the admin dashboard.

**Scheduler registration** — same `setInterval` + boot call pattern as other
TSDB pollers.

**Cold-start / warm boot** — load `OP_DATASET_TV_LISTINGS` from Redis/disk in
the existing data-load block, same as schedule/livescore.

---

### Phase 9e — Join: attach TV channels to fixtures

**File:** `api/server.js` and/or `api/fetch_tsdb_matches.js`

In `rebuildMergedMatchesCache` / the schedule normalisation, after TSDB
schedule matches are produced, join TV channels by exact `idEvent`:

```js
// Inside the loop that builds preferredMatchesForMerge
const tvChannels = cachedTvListingsByEvent.get(match.id) || [];
// Also emit tv_channel_names for backward compat during iOS rollout
return {
  ...match,
  tv_channels: tvChannels,
  tv_channel_names: tvChannels.map(c => c.name),
};
```

Update `mergeTvChannels` to deduplicate on `name + country` pair, not just
string equality.

Update `uniqueChannels` to operate on objects (keyed by `name+country`) while
keeping `mergeTvChannels` returning the same structured shape.

---

### Phase 9f — Remove `live_football_on_tv` source

**File:** `api/server.js`

Remove:
- `require("./fetch_live_footballontv")` import and the 3 symbols destructured
  from it (`fetchMatches`, `writeMatches`, `DEFAULT_URL`).
- `SOURCE_URL`, `OUTPUT_PATH`, `INTERVAL_MINUTES`, `INTERVAL_MS` constants
  (the footballontv-specific ones at lines 119–122).
- `SOURCE_LIVE_FOOTBALL`, `COMPONENT_SOURCE_LIVE_FOOTBALL` constants.
- `cachedMatches` state variable and all reads/writes.
- `updating` flag used by `updateMatches`.
- `updateMatches()` function (~70 lines, line 18286).
- `filterStaleBbcMatches()` function (~60 lines, line 18356) — only called
  from `updateMatches`.
- `shouldRefreshCanonicalMatchDetailsFromBbcLive()` — only used in the
  now-removed flow.
- The `setInterval`/boot call for `updateMatches`.
- The `liveMatchesForMerge` / `cachedMatches` contribution to
  `rebuildMergedMatchesCache` (line 11485) — leave only TSDB schedule +
  test matches.
- The `markAsBbcSource` option path in `mergeTsdbAndLiveMatches` (it becomes
  dead code once `liveMatchesForMerge` is always empty).
- Cold-start load of the `OP_DATASET_LIVE_MATCHES` operational dataset.
- Grafana / runtime dashboard references to `live_football` / `source_live_football`.

**File:** `api/fetch_live_footballontv.js` — **delete**.

**File:** `api/package.json` — remove `cheerio` dependency (used only by
the footballontv scraper; verify no other module imports it first).

**Test files to delete:**
- `api/fetch_live_footballontv.test.js` (if it exists)
- Any `matches.json` / footballontv JSON fixture files

---

### Phase 9g — Web client

**File:** `web/src/client/components/MatchCard.tsx`

1. Update `Match` type: `tvChannels: { name: string; country: string; countryCode: string | null; logo: string | null }[]`.  Add a type guard that tolerates a legacy `string` element during rollout.

2. **Locale resolver** (small utility, same file or a `locale.ts` sibling):
   ```ts
   function userCountryCode(): string | null {
     // navigator.language → e.g. "en-GB" → "GB"
     const tag = navigator.language || "";
     const parts = tag.split("-");
     return parts.length >= 2 ? parts[parts.length - 1].toUpperCase() : null;
   }
   ```

3. **Fixture card badge** (lines 159/173): filter `tvChannels` to entries where
   `countryCode === userCountryCode()`.  Show badge if any match; use first
   match's `logo` (fall back to existing `/logos/tv/{name}` asset if `logo`
   is null).

4. **`ExpandedMatchDetails`** (line 327): render a "Where to watch" section
   at the bottom, always visible when `tvChannels.length > 0`.  Group by
   country, user's country first.  Each row: flag + country name + channel
   logo + channel name.  For channels without a `logo`, fall back to
   `/logos/tv/{name}`.

---

### Phase 9h — iOS client

**File:** `ios/Top Scores/Top Scores/Models/Match.swift`

1. Add a `TvChannel` struct (Codable):
   ```swift
   struct TvChannel: Codable, Equatable {
       let name: String
       let country: String
       let countryCode: String?
       let logo: String?
   }
   ```

2. Update `tvChannels` property to `[TvChannel]`.  Decoder uses
   `decodeIfPresent` and handles both the new structured form and the legacy
   `[String]` (attempt structured decode; on failure decode as strings and
   wrap each in `TvChannel(name: s, country: "", countryCode: nil, logo: nil)`).

3. Update `withTvChannels`, `Equatable` conformance, and any serialisation
   (`CodingKeys.tvChannels` remains `"tv_channels"`).

4. **Fixture list badge:** filter `tvChannels` by
   `Locale.current.region?.identifier` (e.g. `"GB"`).  Show badge if any
   match.

5. **Match details screen:** add a "Where to watch" section at the bottom.
   Group by country (user's country first).  Each row: SF Symbol / emoji flag
   from `countryCode`, `country` name, channel `logo` image (async), channel
   `name`.

6. **Widget / Live Activity** (`Top_ScoresWidgets.swift`): no structural
   change needed — widgets read from the same `Match` model; the TV badge
   logic already checks `tvChannels`, will now check `countryCode` match.

**Coordinate** this release with the existing `idEvent` / `has_tsdb_source`
iOS clean-break release noted in `THESPORTSDB_MIGRATION_PLAN.md`.

---

### Phase 9i — Cleanup and docs

- Remove footballontv references from `ARCHITECTURE_OVERVIEW.md`.
- Remove the `live_football` source from the Grafana dashboard JSON
  (`observability/grafana/dashboards/`).
- Remove `SOURCE_URL` / `OUTPUT_PATH` / `UPDATE_INTERVAL_MINUTES` from any
  `.env.example` or deployment scripts.
- Update this document's status line to `DONE` when complete.
- Add a "Phase 9 — TV listings" entry to `THESPORTSDB_MIGRATION_PLAN.md`
  referencing this file.

---

## Open risk: API coverage validation (Phase 9a is a hard gate)

The TV API endpoint is confirmed working (see `log.txt`).  However, `log.txt`
shows mostly international fixtures.  **Do not delete the scraper (Phase 9f)
until Phase 9a confirms sufficient `idEvent` overlap with the allowlisted
club leagues** (EPL, UCL, Championship, etc.).

If overlap is partial, a transitional strategy is:
- Keep scraper running in parallel.
- TV join prefers the TSDB TV API result for any `idEvent` found there.
- Falls back to the fuzzy-name scraper result for any match not found in the
  TV API.
- Remove scraper once overlap is 100% for the allowlisted leagues across a
  full matchday.

---

## Recommended implementation order

```
9a  Validate API coverage with prod key           ← hard gate
9b  Add getTvListings() to client                 ← 15 min, low risk
9c  fetch_tsdb_tv.js + tests                      ← ~2h, self-contained
9d  Server poller                                 ← ~2h, follows existing pattern
9e  Join TV to fixtures in rebuildMergedMatches   ← ~1h
--- deploy API changes, verify TV data flows ---
9g  Web "Where to watch" section                  ← ~3h
9h  iOS structured decode + details screen        ← coordinate with idEvent release
9f  Delete live_football_on_tv source             ← only after confirming TV API covers all leagues
9i  Cleanup + docs
```

Rationale for this order:
- **9b–9e before 9f:** The TV API poller runs alongside the scraper until
  the join is confirmed working end-to-end.  The scraper's `tv_channels` is
  simply overwritten by the richer structured data when the `idEvent` matches.
- **9g/9h before 9f:** Deploy and validate the display changes before removing
  the fallback source.
- **9f last:** Scraper removal is the irreversible step; do it only when the
  TV API join is confirmed and clients are deployed.
