# Login-free FPL preferences sync

The website's **FPL → Connect to app** generates a ten-minute QR code. Scan
it using the phone camera, open Top Scores, check the matching six-digit code
and tap **Connect this browser**. The website detects approval and imports the
app setup automatically, with no further browser confirmation. The app is the
source for the team ID. The website offers replace or merge (rivals/leagues)
before scanning, plus **Import once only** if ongoing sync is unwanted.

A phone confirmation is intentional: opening an unsolicited link must not
silently grant another browser ongoing access. This connects viewing preferences,
not an authenticated FPL account or permission to make transfers.

## Website-first pairing

`POST browser-pair` creates a pending request with two independent secrets:
- A scanner secret in the QR link's fragment, which can only inspect or approve
  the request. Approval also requires the app's existing sync credential.
- A browser-owner secret in a separate HttpOnly, Secure, SameSite=Strict cookie,
  which is required to claim the approved connection. The QR never contains it.

The phone inspects `browser-pair/inspect` then explicitly approves with
`browser-pair/approve`. The originating browser polls `browser-pair/status`
every two seconds while visible; this transaction attaches a distinct browser
credential and sets its HttpOnly cookie. Repeated scans/claims cannot create
extra devices, and lost responses can be recovered. Device revocation invalidates
the request, so polling cannot revive a revoked credential. Cancellation and
regeneration invalidate the old QR. Session storage lets a waiting browser resume
after refresh without copying its owner credential into JavaScript.

The link is `https://top-scores.skynolimit.dev/fpl/connect#pair=…`. Universal Links
are scoped to `/fpl/connect` by the app entitlement and
`/.well-known/apple-app-site-association` (app ID
`SJ8X4DLAN9.topscores.dev.skynolimit`). If Safari opens instead, the fallback page
provides **Open Top Scores**, using the existing `topscores` scheme. Both handlers
validate the origin/path/secret and reject unexpected parameters. GET requests
and link previews never approve or claim a connection.

The iOS scene delegate captures browsing activities and URL contexts, including
cold-start connection options. A memory-only inbox retains the request until
the SwiftUI scene is active, then selects FPL and presents the pairing sheet.
SwiftUI URL delivery feeds the same inbox. Diagnostic breadcrumbs record the
delivery path and validation result, never the URL or pairing secret.

This requires a newly signed app build with Associated Domains enabled in its
provisioning profile. A website deploy alone does not activate the link handler
in an already installed app. Camera-to-app Universal Link behaviour must also be
verified on a signed device after the app update; simulator URL tests are separate.

## Data and lifecycle

- Synced: manager entry ID, ordered rival entry IDs, ordered tracked league IDs
  and league display-name hints. Automatically discovered manager leagues still
  come from public FPL data. The app's separate order for automatically discovered
  leagues is not part of the tracked-league list.
- No FPL session, password, APNs token, existing device token, lineup or score is
  stored in the sync database.
- Each device has an independent 256-bit credential. Web uses an HttpOnly,
  Secure, SameSite=Strict host-only cookie; iOS uses a device-only Keychain item.
  Device credentials and pairing secrets are stored as SHA-256 hashes. The six-digit matching code is a display-only check, never a credential.
- Pairing secrets travel in the URL fragment and POST body, never a query string.
  Preview does not approve a link. Completion is transactional. New QR codes
  invalidate previous requests for that browser; revoking the approving device
  invalidates its pending approvals. Pairing attempts are rate limited.
- Maximum 20 devices per connection, 100 rivals and 100 tracked leagues. Imports
  over the limit fail visibly rather than truncating data.
- Connections expire after 180 days of device inactivity; browser cookies last
  180 days. Clearing browser data requires pairing again. Orphaned spaces and
  expired links/credentials are cleaned up hourly and on startup.

## Sync and conflicts

Clients retain local settings and the last sync baseline across restarts. Web
syncs after edits (600 ms debounce), every 15 seconds while visible and on
foreground/reconnection. The app syncs every 15 seconds while FPL is selected
and active. Offline edits remain local and retry. Neither surface promises
background sync while closed.

The server performs three-way merges against the supplied baseline: independent
additions/removals combine, changes to different settings combine, and conflicting
team changes or competing reorders return HTTP 409 with the current snapshot.
Clients preserve local choices until the user picks local or synced settings.
Edits made during a request remain pending for the next sync. Disconnecting
revokes the credential while preserving local preferences. Import-once revocation
of an old browser connection is part of the same transaction as redemption.

## Hosting

`web/fpl-sync.mjs` runs inside the existing website service; no sports API or
new process is needed. `better-sqlite3` is pinned to 12.9.0, which provides a prebuilt binary for production Node 20.
Local Node 26 builds it from source (npm emits an engine-range warning); the
focused sync tests verify that local build. Prefer Node 22 or 24 for development.

Default store: `$HOME/.local/share/top-scores-web/fpl-sync.sqlite`, outside the
deployment tree. Set `FPL_SYNC_DB` to override. Directory permissions are 0700
and database permissions 0600. SQLite WAL and transactions protect concurrent
updates and redemption. Browser requests allow the explicit public origins
`https://top-scores.com` and `https://top-scores.skynolimit.dev`, plus the configured
`TOP_SCORES_WEB_ORIGIN` for local deployments. QR links continue to use that
configured origin, which must be supported by the app's Universal Links.
TLS is terminated by the existing proxy.

Preserve this directory across deployment. For live backups use SQLite's backup
API (or stop the website before copying the database); do not copy only the main
database file while WAL writes are active. Loss of this store requires users to
pair again, but local FPL preferences remain intact. Existing operational backup
coverage for this new directory should be checked before promising recovery.

API prefix: `/api/fpl-sync`. Routes: `POST session`, authenticated `GET/PUT state`,
authenticated `POST pair`, `POST preview`, `POST redeem`, authenticated
`POST disconnect`. Native clients send `X-FPL-Client: ios` and a bearer token;
browser responses never expose device credentials to JavaScript. The original app-issued
pair/preview/redeem routes remain available for compatibility, but current UI uses
the website-first browser-pair routes described above. Responses are
no-store; no credentials or pairing request bodies are logged.

## Verification and release

Run `npm test`, `npm run check`, `npm run build` in `web`; run
`FantasyPreferenceSyncTests` with the Top Scores Xcode scheme. Browser checks
cover importing, both sync directions, existing settings, revocation and narrow
layouts. Website deployment does not distribute the iOS changes: ship an app
update separately. Do not install on physical devices without explicit consent.
