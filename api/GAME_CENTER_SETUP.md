# Game Center setup

Configuration audit: 10 September 2026. All 32 leaderboards were saved and verified in App Store Connect, including English (U.K.) localization, Classic type, Most Recent Score submission and High to Low sorting. All eight achievements were also created with English (U.K.) localization; all eight image uploads finished processing and their saved PNG filenames were verified. Every achievement is visible before earning (Hidden: No) and non-repeatable. App Store Connect lists them as **Prepare for Submission**; the resources have not been submitted to App Review. This file contains no credentials. Saved configuration does not imply App Review approval or production publication.

## App and private leagues

The app is `Top Scores`, bundle ID `topscores.dev.skynolimit`, signing team `SJ8X4DLAN9`. Browser verification confirmed that the Game Center checkbox is already on for App Store Connect iOS version 2.0. Apple Developer App ID record `287Z6XAXQW` already has Game Center and Associated Domains enabled. The iOS source already includes `com.apple.developer.game-center` for both Debug and Release.

Private mini-leagues need no Apple leaderboard, achievement, matchmaking configuration or friends-list permission. They use the existing verified Game Center identity and private Top Scores backend. Keep all private names, membership, invitations and tables out of public Game Center resources.

Invitation links use the already enabled **Associated Domains** capability on the Apple App ID; a signed build still needs a matching provisioning profile. The source entitlement is `applinks:top-scores.skynolimit.dev`; the deployed website must serve the matching AASA file. This is separate from Game Center. See [private league deployment](PRIVATE_PREDICTION_LEAGUES.md).

## Public achievements

The following identifiers are provisioned using the prefix `topscores.predictions.`. These are global achievements across competitions, not separate copies per league or season. Apple achievement points are presentation/reward metadata and do not change football scoring or these unlock thresholds. The configured values are 10, 10, 30, 30, 10, 30, 50 and 30 respectively (200 total).

| Identifier suffix | Display name | Unlock description |
|---|---|---|
| `firstWhistle` | First Whistle | Complete your first scored prediction. |
| `bullseye` | Bullseye | Make your first perfect prediction. |
| `sharpShooter` | Sharp Shooter | Make 10 perfect predictions. |
| `readingTheGame` | Reading the Game | Predict 25 results correctly. |
| `humanOneAiZero` | Human 1, AI 0 | Beat the AI on one match. |
| `tenStepsAhead` | Ten Steps Ahead | Build a 10-point advantage over the AI. |
| `cleanSweep` | Clean Sweep | Predict every result correctly in a completed weekly challenge. |
| `seasonedPro` | Seasoned Pro | Complete challenge predictions in two seasons of the same competition. |

Seasoned Pro requires seasons in the same competition. A perfect prediction earns three football points; a correct result earns one. Game Center unlocks are permanent even if an upstream correction subsequently changes the in-app record.

## Public leaderboards

Use **Classic**, **Integer**, **Most Recent Score**, and **High to Low** for every board. Most Recent Score is necessary because the backend may correct a total downward. Do not use recurring boards with the current submission contract: the API sends historical period totals without a recurring occurrence identifier.

Each competition and period needs its own Apple identifier. Weekly points have a range of 0–30 for at most ten shared challenge fixtures. Season points and perfect counts need a range large enough for the competition's full season; EPL has at most 1,140 points and 380 perfect scores. A broader nonnegative upper bound is acceptable and avoids rejecting legitimate totals in larger competitions.

The production database currently has these two published EPL challenges, both in BSD season `1058` (2026/27). Verified saved EPL resources:

| Backend mapping key | Apple leaderboard identifier | Display name |
|---|---|---|
| `weekly:epl-2026-09-11` | `topscores.predictions.epl.2026w0911.points` | Premier League · 11–17 Sep 2026 |
| `weekly:epl-2026-09-18` | `topscores.predictions.epl.2026w0918.points` | Premier League · 18–24 Sep 2026 |
| `season:1058` | `topscores.predictions.epl.1058.points` | Premier League · 2026/27 Points |
| `perfect:1058` | `topscores.predictions.epl.1058.perfect` | Premier League · 2026/27 Perfect Scores |

For the all-competition release, the following BSD competitions currently have upcoming AI-supported fixtures. Their event season IDs were checked against current competition metadata. Separate season/perfect resources for all of these competitions have been saved and verified with English (U.K.) localization. Their Apple IDs follow `topscores.predictions.c<competition>.s<season>.points` and `.perfect`; the full 32-board mapping is in [game-center-leaderboards.json](game-center-leaderboards.json). Do not map them to EPL resources.

| Competition | BSD competition ID | BSD season ID | Season mapping key |
|---|---:|---:|---|
| La Liga | 3 | 1307 | `competition:3:season:1307` |
| Serie A | 4 | 1375 | `competition:4:season:1375` |
| Bundesliga | 5 | 1091 | `competition:5:season:1091` |
| Ligue 1 | 6 | 1311 | `competition:6:season:1311` |
| Champions League | 7 | 1112 | `competition:7:season:1112` |
| Europa League | 8 | 1269 | `competition:8:season:1269` |
| Eredivisie | 10 | 1268 | `competition:10:season:1268` |
| Championship | 12 | 1111 | `competition:12:season:1111` |
| Scottish Premiership | 13 | 1355 | `competition:13:season:1355` |
| Carabao Cup | 40 | 1092 | `competition:40:season:1092` |
| Coppa Italia | 42 | 1155 | `competition:42:season:1155` |
| League One | 86 | 1655 | `competition:86:season:1655` |
| League Two | 87 | 1674 | `competition:87:season:1674` |
| National League | 91 | 1903 | `competition:91:season:1903` |

For perfect-score keys, replace `:season:` with `:perfect:`. Non-EPL weekly keys must include the full published challenge ID, for example `competition:7:weekly:competition:7:1112:epl-2026-09-11`. Use an actual published challenge from the API/database; the all-competition worker has not yet published these scopes in the production database. Weeks with an already started eligible fixture cannot be backfilled. Future weeks/seasons require new unique mappings rather than reusing a previous period's board.

## Nonsecret server configuration

Both nonsecret Game Center exports were staged in production static configuration on 10 September 2026 at 16:45 UTC. The running API process still has neither value because it was deliberately not restarted. Submission will activate on the next operator restart, subject to the Apple resources being available to the signed build. The user systemd unit `com.top-scores.api.service` runs `/home/mwagstaff/dev/top-scores/.start-with-bw-env-api.sh`, which sources `.static-config-top-scores.env.sh` and then `.bw-secrets.env.sh`. The update appended only the two Game Center exports, preserving every original byte, the file owner and mode `0600`. The secrets file was not changed. The observed service wrapper does not load `.env.local`.

The 32 leaderboard mappings and eight-achievement prefix are staged for the next operator restart. The following shell-safe reference includes the default bundle ID as context; the production update appended only `PREDICTION_GAME_GC_LEADERBOARDS` and `PREDICTION_GAME_GC_ACHIEVEMENT_PREFIX`:

```sh
export PREDICTION_GAME_BUNDLE_ID='topscores.dev.skynolimit'
export PREDICTION_GAME_GC_ACHIEVEMENT_PREFIX='topscores.predictions.'
export PREDICTION_GAME_GC_LEADERBOARDS='{"weekly:epl-2026-09-11":"topscores.predictions.epl.2026w0911.points","weekly:epl-2026-09-18":"topscores.predictions.epl.2026w0918.points","season:1058":"topscores.predictions.epl.1058.points","perfect:1058":"topscores.predictions.epl.1058.perfect","competition:3:season:1307":"topscores.predictions.c3.s1307.points","competition:3:perfect:1307":"topscores.predictions.c3.s1307.perfect","competition:4:season:1375":"topscores.predictions.c4.s1375.points","competition:4:perfect:1375":"topscores.predictions.c4.s1375.perfect","competition:5:season:1091":"topscores.predictions.c5.s1091.points","competition:5:perfect:1091":"topscores.predictions.c5.s1091.perfect","competition:6:season:1311":"topscores.predictions.c6.s1311.points","competition:6:perfect:1311":"topscores.predictions.c6.s1311.perfect","competition:7:season:1112":"topscores.predictions.c7.s1112.points","competition:7:perfect:1112":"topscores.predictions.c7.s1112.perfect","competition:8:season:1269":"topscores.predictions.c8.s1269.points","competition:8:perfect:1269":"topscores.predictions.c8.s1269.perfect","competition:10:season:1268":"topscores.predictions.c10.s1268.points","competition:10:perfect:1268":"topscores.predictions.c10.s1268.perfect","competition:12:season:1111":"topscores.predictions.c12.s1111.points","competition:12:perfect:1111":"topscores.predictions.c12.s1111.perfect","competition:13:season:1355":"topscores.predictions.c13.s1355.points","competition:13:perfect:1355":"topscores.predictions.c13.s1355.perfect","competition:40:season:1092":"topscores.predictions.c40.s1092.points","competition:40:perfect:1092":"topscores.predictions.c40.s1092.perfect","competition:42:season:1155":"topscores.predictions.c42.s1155.points","competition:42:perfect:1155":"topscores.predictions.c42.s1155.perfect","competition:86:season:1655":"topscores.predictions.c86.s1655.points","competition:86:perfect:1655":"topscores.predictions.c86.s1655.perfect","competition:87:season:1674":"topscores.predictions.c87.s1674.points","competition:87:perfect:1674":"topscores.predictions.c87.s1674.perfect","competition:91:season:1903":"topscores.predictions.c91.s1903.points","competition:91:perfect:1903":"topscores.predictions.c91.s1903.perfect"}'
```

This mapping contains 32 saved and localized resources: season points and season perfect scores for fifteen competitions, plus two known EPL weekly boards. Append only additional boards that have actually been provisioned and verified. Duplicate Apple IDs across mapping keys are rejected by the backend so one competition cannot overwrite another.

The currently running production code is still EPL-only. It safely ignores mapping keys beginning with `competition:` and submits only the four unprefixed EPL mappings. After the all-competition release is deployed, the new parser uses all 32 scopes. There is no need to strip the other mappings for staging.

The API must subsequently be restarted by the operator using the existing deployment process. No service was restarted or started. The pre-change backup is `/home/mwagstaff/dev/top-scores/.static-config-top-scores.env.sh.game-center-backup-20260910T164555074344Z`. Shell syntax and the 32 distinct mapping values were validated before the atomic file replacement. The running API PID remained `247622` with the configuration still unset. Complete any App Store Connect version attachment/review steps required to release the resources with the signed app build. In a recognized build, open Beat the AI to trigger automatic identity verification and authoritative score/achievement submission; ordinary fixtures browsing must not initialize Game Center.

Verify on a signed test build that the correct competition opens its Friends leaderboard and that a result correction can replace a previous score. Simulator tests validate client/backend contracts but do not establish App Store Connect publication, live authentication or universal-link delivery.
