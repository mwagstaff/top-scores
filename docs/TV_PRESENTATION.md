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

The website TV Guide sidebar sorts live/upcoming televised matches by descending API watchability score, then kickoff time. Unrated matches sort last. It shows three recommendations and counts other televised matches for the selected date; incomplete pagination is marked with a plus sign.
