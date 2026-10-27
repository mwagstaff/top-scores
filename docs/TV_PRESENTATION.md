# TV provider priority and watchability

## Shared provider order

`api/tv_provider_priorities.json` is the source of truth. Lower `priority` values come first; aliases identify a provider family, and `other_priority` covers unmatched providers. Default order:

BBC → ITV → Channel 4 → Channel 5 → Sky → TNT → NOW TV → HBO → Premier Sports → others.

The API reads this file once and watches it for updates every second. Edit it atomically (write a replacement, then rename it into place). Valid changes apply without restarting the API or releasing an app update. Invalid changes retain the last valid rules. `TV_PROVIDER_PRIORITIES_PATH` can point to an externally managed JSON file with the same schema.

Ordering happens at the public response boundary, after match caches, for fixture lists, match details and batch states. Ties preserve the upstream channel order. Channel names, countries and logos are unchanged. The match-list Last-Modified time includes config updates, so conditional requests see the revised order.

The existing iOS app preserves API channel order when filtering by country and takes the first local channel for its compact logo (`localeFilteredChannels` and `compactPrimaryBroadcastChannel` in MatchRow.swift). The website now does the same. Neither client maintains a second provider-weight table. Match rows show the first UK logo with an accessible expand/collapse button when alternatives exist; the sliding list reveals all UK channels. Match detail pages retain all channels. Unsupported logos retain their channel text.

Deploy the API changes and the website together. The website is deployed as a standalone folder: `prepare-assets` copies the canonical API module and default config into `web/server-shared` (using `.cjs` for CommonJS). These bundled files must be included in deployment; when the API checkout is absent, the build retains them. The website must never import a sibling `../api` path at runtime. The website server also applies this same module and config to SSR data and proxied match responses, so an older upstream API cannot restore the wrong primary provider. Keep the API and website processes pointed at the same config file (or deploy the same config to both hosts). Subsequent config-only changes need no app or website release; normal refresh/cache intervals still apply.

## Watchability

`api/watchability.js` already calculates the shared score, tier and stars and includes `watchability_index` in match responses. iOS and the website render those returned values; neither recalculates scores or star thresholds. The website's On the box panel uses the same tier labels and colours as iOS. Missing watchability data is omitted, never invented.

## Crests

Pass both the full team name and the API-provided short name to the website logo resolver, matching iOS alternate-name lookup. This resolves AZ Alkmaar → AZ and SK Sturm Graz → Sturm without truncating visible names. The resolver retains explicit full-name aliases for callers lacking short names. Unknown crests use non-cacheable initials.

Validation: provider ordering, hot config reload, cache immutability, nested response integration, existing watchability calibration, and web decoding/order preservation are covered by automated tests. Browser checks cover live pills, primary-logo rows, ratings and alternate-name crests.

The website TV Guide sidebar sorts live/upcoming televised matches by descending API watchability score, then kickoff time. Unrated matches sort last. It shows three recommendations and counts other live/upcoming televised matches for the selected date; incomplete pagination is marked with a plus sign. When none remain, it searches the next 14 days for UK broadcasts, shows matches from the first available date, and links the full guide to that date.


## UK audience calibration (model v4)

The shared API retains the competition weights (Premier League 100, FA Cup 65,
EFL Cup 60, Serie A 45) and adds a single 15-point **Premier League cup appeal**
component to FA Cup/EFL Cup fixtures with at least one current Premier League
participant. Membership comes from the existing Premier League team context;
there are no hardcoded club names, and two qualifying clubs do not double the bonus.
This recognises UK interest in cup ties even when team-strength imbalance lowers
the competitive-balance component. Other competitions retain their existing
calibration, including marquee rivalries and European finals.

The 27 October 2026 API snapshot now scores Fleetwood–Arsenal 62 (previously 47),
ahead of Torino–Como 50, Bradford–Peterborough 50 and Sassuolo–Lazio 49. Snapshot
regressions cover this order alongside the established Premier League and European
calibrations. Missing ratings remain absent rather than becoming zero: balance
uses a neutral baseline and team quality uses available ratings, or a neutral
baseline if neither is available.

The same score feeds web/iOS presentation and existing TV calendar/reminder
thresholds. The thresholds remain 55/70/85; a score of 62 is a Good watch and does
not cross the default 70-point TV reminder threshold.

### Minimum rating and consistent stars

The iOS TV listings picker persists its own minimum rating locally, independently
of reminder and calendar settings. It defaults to Good watch (three stars) for users without a saved choice;
a selected star threshold includes that rating and above. All matches includes
unrated matches. It remains
visible when filtering leaves no matches.

Model v5 aligns labels and stars: 0–29 = 1 / For the diehards; 30–54 = 2 /
Moderate; 55–69 = 3 / Good watch; 70–84 = 4 / Highly watchable; 85–100 = 5 /
Must watch. iOS also derives these from score for older cached payloads.

Premier League and Champions League fixtures receive a bounded elite-matchup
bonus when both strength ratings exceed 1850. The bonus ramps linearly to its
maximum at 1950 for the weaker club: 7 points for the Premier League and 6 for
the Champions League. Missing ratings and weaker opposition receive no bonus.
The breakdown shows this contribution alongside the existing factors.

The minimum-rating control uses an interactive Liquid Glass capsule without a
full-width material strip. Its anchored chooser shows six options in a two-row
grid, with stars, labels and a selected checkmark. Accessibility Dynamic Type
switches to a scrollable single-column sheet. Selection closes the chooser and
continues to use the same persisted rating and filtering logic.

When the minimum rating hides every listing, the empty state offers a link to
the highest available lower rating and states the exact number of matches it
will reveal. If only unrated listings exist, it offers All matches. Dates without
any UK TV listings instead say there are no matches on UK TV for that date.
