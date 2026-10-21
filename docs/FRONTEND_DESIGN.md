# Top Scores website design contract

## Product direction

Serve UK football followers with equal priority for scores/fixtures and finding where to watch. Today is the starting point. UK domestic competitions and UK broadcasts are the default scope; all competitions and Premier League focus remain available. The website is dark only. Match and competition pages must be deep-linkable.

The direction is cinematic football utility: atmospheric stadium artwork around clear, compact football data. Avoid oversized heroes, dashboard tiles, heavy glass effects, decorative gradients and constant motion. The iPhone football experience is the colour reference; the separate iPhone FPL design context does not define the website palette.

## Colour and typography

| Role | Token/value |
| --- | --- |
| Page | `#04080c`, from app `FootballVisualStyle.pageBackground` |
| Raised surface | `#0a131d` |
| Navy depth | `#0e1b2a` to `#06111c` |
| Strong surface | `#142235` |
| Main text | `#f2f5fa` |
| Secondary text | `#91a3b8` |
| Selected/action | `#2aa8ff` |
| Live status | `#98dfad` on a restrained green tint |
| Qualification | Purple `#a785ff` |
| Warning | `#e1c491` |

Blue identifies navigation, selected dates, links and actions. Green communicates live/positive football state, never the page foundation. Preserve semantic red/yellow cards, relegation and substitution colours. Borders are translucent slate; depth comes from surfaces rather than shadows.

Use Avenir Next, Avenir, Segoe UI, sans-serif: no web-font download. Page titles are 30–48px, team names 14–16px, primary scores 17–20px, supporting data 11–13px. Use tabular numerals for scores, times and table columns. Wrap long team names rather than hiding both identities behind ellipses. Compact table rows may grow in height to preserve names.

## Layout and primitives

- `AppShell`: compact header, desktop competition rail, mobile bottom navigation and skip link. Main content has an explicit focus target.
- `MatchesScreen`: short atmospheric heading, previous/yesterday/today/tomorrow/next/date controls, all/live/TV filters, optional search, competition scope, then football.
- `FixtureRow`: two stacked club identities, fixed crest dimensions, aligned scores, a separate match-state column and readable UK channel text. One real link opens the match. Additional channels use a count; the match page lists all channels.
- `MatchPage`: team identity and score dominate; UK broadcasting is directly below the hero. Existing events, lineups, commentary and player detail functionality remain available.
- `CompetitionPage`: fixtures, results and standings for the named competition. Never silently substitute another competition's table.
- `StadiumBackdrop`: decorative imagery, independent of match data, with source credit. It must never contain essential text.

Use a 4px spacing rhythm with common gaps of 8, 12, 16, 24 and 32px. Main content is capped at 1504px. Website controls use a restrained 6px radius. Prefer separators over nested containers.

Above 1200px, provide a right-hand UK broadcast guide. Below 1200px, remove this secondary column. Below 900px, remove the competition rail. At 600px and below, use bottom navigation, compact date controls and a second row for TV listings. Keep full names and scores legible at 320px. Reserve space for asynchronously loaded secondary match information and standings.

## Football state and interactions

Display kickoff, live clock, HT, FT, AET and penalty status distinctly in text. Postponed, cancelled and abandoned fixtures must never appear live. Scores dominate; live colour is secondary. Use a small steady live dot, not a continually animated row. A changed score can animate once with opacity/translation.

Provide visible keyboard focus, pressed/current states, meaningful labels, disabled/loading states and genuine links. Main controls target 44px height; narrow mobile date controls retain at least 40px width (36px on 320px screens). Avoid hover-only information. Honour reduced motion, including programmatic table scrolling. Image slots have fixed dimensions. Artwork failure must leave an intentional navy surface.

Filters and date/section choices are URL state. Preserve scroll on browser back navigation and focus the main content on a new route. Retain scores during failed refreshes and expose a quiet retry message. Empty states distinguish no live matches, no broadcasts and no search results. Never fabricate data to fill space.

## Rendering, data and artwork

Keep React, Vite and Express. Production builds create a browser bundle and `dist-server`; both must be deployed. Render public content with the same React components on the server, then hydrate from the exact request-scoped seed. Lazy route code and CSS are preloaded only for the requested secondary route. Preferences are applied in the browser and never enter shared HTML/data caches.

Public server data is cached for 10 seconds with a bounded 64-entry cache and deduplicated requests. API timeouts leave a usable page. Browser day caches hold up to 12 date/scope combinations, backed by session storage where available. Fetch 200 rows per page and preserve opened pages on refresh. Include Premier League inclusion flags in cache keys. Reuse unchanged match objects so memoised rows avoid needless renders.

Poll today's scores every 10 seconds while visible. Pause background-tab work; other dates use the reader's refresh preference. Keep the last valid data after failures. Prefetch adjacent days only after useful content has loaded, and skip speculative work on data-saving/2G connections.

Use the app's stadium catalogue and team IDs/aliases. Prefer exact team IDs; use a deterministic generic image when no team mapping exists. Begin artwork loading after useful data, with low priority and a short opacity fade. Use fixed-size, cached WebP variants at 480/960/1440px; mobile sources are capped at 960px. No real-time CSS blur or browser image transforms. Server variants validate catalogue hashes, limit concurrent transforms and bound memory to 16MB. Immutable variants and hashed assets receive a one-year cache policy.

## Performance budget and validation

- Initial fixture JavaScript: at most 90KB gzip; initial CSS: at most 6KB gzip.
- No font or animation-library payload. Lazy-load match detail, standings and preferences.
- Aim for LCP below 2.5s, CLS below 0.05 and interaction latency below 200ms on representative devices. Cached date rendering should take under 50ms locally.
- Test cold navigation as well as client transitions. Artwork must not move content. Recheck request duplication and resource sizes when adding preloads.
- Maintain semantic headings, route-specific titles, descriptions, canonical URLs and Open Graph data. Include crawlable fixture links in HTML. Invalid matches/pages return meaningful HTTP statuses.

During the October 2026 redesign, the original production build delivered 325.99KB JavaScript / 100.05KB gzip and 47.24KB CSS / 9.48KB gzip initially. The redesigned fixture entry measured approximately 272.4KB JavaScript / 86.9KB gzip and 20.9KB CSS / 5.1KB gzip. Secondary routes have separate chunks.

A local production preview using the real remote API at a 390×844 viewport measured: fixtures TTFB 164ms, FCP 244ms, LCP 1584ms, CLS 0; direct match TTFB 214ms, FCP 272ms, LCP 1344ms, CLS 0. Cached next-day rendering took 10ms and the observed event duration was 40ms. These are unthrottled local lab observations with a temporary PerformanceObserver probe, not field Core Web Vitals or a formal INP assessment. The probe is not shipped.

Validate with `npm run check`, `npm test`, a production build, and browser inspection at mobile, tablet and desktop widths. Cover real fixtures/results, long names, TV discovery, empty states, match/competition deep links and preferences. Unit tests cover dates/DST, settled/live statuses, UK channels, cache/pagination/failure behaviour, SEO escaping and artwork selection/variant safety. No live games were available during the recorded morning checks; live status logic was tested with representative data.
