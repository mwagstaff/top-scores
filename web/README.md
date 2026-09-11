# Top Scores Web

React + Express web client for the existing Top Scores API.

## Run

```bash
cd /Users/mwagstaff/dev/top-scores/web
npm install
npm run dev
```

The web server defaults to `http://localhost:3011/api/v1`.

If you want a different backend:

```bash
TOP_SCORES_API_BASE_URL=https://api.skynolimit.dev/top-scores/api/v1 npm run dev
```

## Screens

- `Fixtures`
- `Results`
- `Preferences`

Preferences are stored in local browser storage under `top-scores.web.preferences.v1`.

## Private league invitation links

The web server serves `/invite/:code` as a small standalone invitation page. It
does not fetch league data or redeem an invitation. Opening a link in a messaging
preview cannot join a league. The page offers the native app link, a copyable code
and the verified Top Scores App Store listing. After installing the app, enter
the code in **Beat the AI → My Leagues → Join League**; installation does not
automatically recover an earlier link.

`/.well-known/apple-app-site-association` is served as JSON without a redirect.
The default app identifier is `SJ8X4DLAN9.topscores.dev.skynolimit`; override
`TOP_SCORES_ASSOCIATED_APP_ID` only for a different signed App ID prefix/bundle.
The iOS Associated Domains entitlement contains
`applinks:top-scores.skynolimit.dev`, matching the API's default
`PREDICTION_GAME_INVITE_BASE_URL=https://top-scores.skynolimit.dev/invite`.
Changing the invitation domain requires updating both the entitlement and the
iOS link allowlist, and serving AASA from the new domain's root.

Release verification requires deploying this web change, enabling Associated
Domains for the app identifier/provisioning profile, and a newly signed app build.
Check that the public AASA path returns JSON, not the SPA or a redirect, then test
both a cold launch and an already-open app from Messages. Apple caches association
files, so propagation is not immediate. No Apple private leaderboard setup or
friends-list permission is needed. See
[Apple's universal link guidance](https://sosumi.ai/documentation/xcode/supporting-universal-links-in-your-app).

Run the isolated invitation page tests with
`node --test league-invitations.test.mjs`; this does not start a server.
