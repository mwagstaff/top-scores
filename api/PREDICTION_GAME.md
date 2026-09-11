# Beat the AI

An optional iOS prediction game for any BSD fixture with a usable AI prediction,
backed by `/api/v1/prediction-game`. Goal Guesser remains a separate game.

## Runtime and configuration

The API registers the game and runs a settlement/recovery pass every minute.
`PREDICTION_GAME_ENABLED=false` disables both routes and the worker. MongoDB is
required; the game returns a friendly unavailable response if it cannot connect.
No additional BSD calls or credentials are needed: the existing poller supplies
`bsd_events` and `bsd_predictions`. Standard scores requests do not load game data.
Interactive fixture/editor requests read only the requested BSD events, saved game
snapshots and that player's entries, with an indexed batch query for each. They
work with an empty game cache and never wait for the historical settlement import.
Activation reads a bounded date window directly from BSD; its background refresh
is nonblocking even on the first request after an API restart. New guest statistics
do not scan archived challenges or write zero-score historical leaderboard rows.

Game Center identity verification defaults to the iOS app's exact bundle ID,
`topscores.dev.skynolimit`. Override it only for a separately registered app build.
Apple leaderboard and achievement publication additionally requires configuration:

```text
PREDICTION_GAME_BUNDLE_ID=topscores.dev.skynolimit
PREDICTION_GAME_GC_ACHIEVEMENT_PREFIX=<provisioned achievement prefix, e.g. beatsAI.>
PREDICTION_GAME_GC_LEADERBOARDS={"weekly:epl-2026-09-11":"<weekly leaderboard identifier>","season:<BSD season ID>":"<season identifier>","perfect:<BSD season ID>":"<perfect predictions identifier>"}
```

Enable Game Center for the app identifier and provision/release matching
leaderboards and achievements in App Store Connect. Achievement suffixes are
`firstWhistle`, `bullseye`, `sharpShooter`, `readingTheGame`, `humanOneAiZero`,
`tenStepsAhead`, `cleanSweep`, and `seasonedPro`. Missing leaderboard/achievement
configuration produces empty Game Center submission arrays; guest play continues.
Use distinct leaderboard identifiers for each weekly and season scope. These
settings do not create, configure, or publish App Store Connect resources.
If Apple shows a welcome banner followed by `gameUnrecognized`, the Apple account
has signed in but the app has not been recognised. Verify the App Store Connect
record uses `topscores.dev.skynolimit`, open the intended iOS version and enable
its Game Center checkbox. The signed build's provisioning profile must also
contain `com.apple.developer.game-center`. A new distribution profile may be
needed after adding the capability; the development profile alone is insufficient
for distribution builds. See [Apple's app-version setup instructions](https://developer.apple.com/help/app-store-connect/configure-game-center/manage-an-app-version-for-game-center)
and [the GameKit error reference](https://sosumi.ai/documentation/gamekit/gkerror/code/gameunrecognized).
The app distinguishes this registration failure from backend linking and score
publication failures; none of them discards locally retained game credentials.
Configure each as a **classic** leaderboard with **Most Recent Score** submission
and **High to Low** sorting. This allows authoritative totals to replace an older
score after a result correction. Weekly boards contain points on the fixed weekly
fixtures; season boards sum weekly challenge points for that BSD season; perfect
boards count 3-point predictions on challenge fixtures in that season. Free-choice
fixtures outside the shared challenge affect personal stats and achievements only.
GameKit's dashboard supplies Friends and Global comparisons; Top Scores' own
leaderboard endpoint supplies the first 100 ranked linked players plus the current
guest when eligible, with equal point totals sharing rank.
The iOS app automatically attempts Game Center authentication when Beat the AI
opens, once per presentation/server/account. Authentication runs separately from
fixture loading; declining or unavailable sign-in leaves guest play usable. Normal
app launch and scores browsing never initialize Game Center or prompt. Final game
dismissal cancels pending authentication; a GameKit sign-in sheet covering the game
does not count as navigation away. Existing verified Game Center history restores
automatically, preserving the guest credential. Account replacement waits until
draft editing and in-flight saves finish, and client draft scopes isolate players.

Game Center proof verifies the signed `teamPlayerID`, configured bundle ID,
big-endian timestamp and salt using RSA-SHA256. Only HTTPS key URLs on
`static.gc.apple.com/public-key/*.cer` are accepted, redirects are disabled,
certificate validity is checked, requests time out, and consumed proofs expire.
Only a hash of the verified identity is retained. A supplied `gamePlayerID` or
display name is never trusted as an authenticated identity.

Because Apple's ordinary verification proof does not sign `gamePlayerID`, this
server does not publish to an arbitrary player ID via Apple's server API. The
iOS client fetches authoritative totals and submits them through the currently
authenticated local GameKit player. Failed submissions can be retried by fetching
the totals again. With Most Recent Score configured, leaderboard corrections are
sent when the connected player next opens the game. Unlocked GameKit achievements
are monotonic and cannot be revoked after an upstream correction; the in-app
achievement progress and all Top Scores history/rankings are recomputed from the
corrected results. For game-independent server submission of Game Center totals,
first establish a trusted Apple mapping from the signed
team player identity to the scoped player identifier; never trust a client field.

## Rules and persistence

- 3 points for an exact score, 1 for the correct win/draw/loss result, 0 otherwise.
  A match win over the AI means more points, and equal points are a draw. Win
  percentage includes draws in its denominator. Comparisons use entered matches.
  Existing entries retain `scoringRulesVersion: 1`. New entries use version `2`,
  extending the same 3/1/0 rule to cups: the score is after extra time, excluding
  shootout kicks, and the actual winner includes penalties. A conditional
  `penaltyWinner: "home" | "away"` is used only if a shootout occurs. It is
  accepted for predicted draws and any second-leg score: a team can win the
  second leg but lose on penalties after an aggregate draw. Without an explicit
  choice, the predicted score supplies the outcome (a drawn score supplies draw). An exact score with the wrong shootout winner earns zero; a correct
  winner with a different score earns one. Ordinary draws ignore that conditional
  selection. No aggregate score from a previous leg is added to the prediction.
- Scores are integers from 0 to 20. The AI rounds each team's BSD expected goals
  to the nearest integer (`top-scores-xg-rounded-v2`), using BSD's
  `score.most_likely` only when either expected-goals value is missing or invalid.
  This projects expected goals rather than choosing the single most probable
  score: the latter can be 1–1 across many different goal expectations. It does
  not add a fixed goal bonus, randomly change picks or alter BSD's raw data.
  The source revision includes the local algorithm version and the upstream
  record; upgrading the algorithm requires first-time players to review the new
  score. Already accepted AI snapshots, including withdrawn picks, stay unchanged.
  Every newly frozen AI score also includes its conditional penalty winner,
  chosen by the greater BSD expected goals (or home/away result probabilities if
  expected goals are unavailable, with home as a deterministic tie breaker).
  This field is included in the reviewed revision. Existing frozen opponents are
  never rewritten. No client-supplied AI score is accepted.
- The first accepted save freezes the AI permanently for that player and match.
  An unreviewed source revision returns `409 ai_changed`; edits and withdrawal
  never reset a previously accepted snapshot.
- Each match locks separately. The server reads the latest durable BSD event,
  rejects live/finished/unknown statuses, and uses MongoDB `$$NOW` in the final
  conditional write to enforce kick-off even when a request is delayed.
- Official prestart postponement moves the deadline. Seeing a live, finished or
  abandoned event permanently sets its started flag. A provider regression cannot
  reopen it. Cancelled/void/abandoned matches contribute no points or denominator.
- Friday–Thursday weeks use London calendar dates. Publish up to 10 AI-backed fixtures per competition in
  kickoff order, with BSD event ID as the tie breaker, before the first eligible
  fixture begins. Published membership is immutable; a postponed match keeps its
  original week and cannot also enter a later week. Missed entries score zero.
- BSD season IDs are retained, with a calendar-derived label and a fallback ID
  only when upstream omits the season. `pg_fixtures` and `pg_entries` preserve
  historical facts across upstream retention and multiple seasons. Competition
  ID and name are retained on fixtures, entries, challenges, seasons and rankings.
  Existing rows with no competition ID are read as Premier League (`1`); no bulk
  destructive migration or reset is needed. EPL season, challenge, gameweek and
  leaderboard identifiers retain their original values. Other competitions have
  explicitly namespaced scopes, even if BSD season or round IDs overlap.
- Entry/result versions, durable pending-stat markers and player revisions make
  interrupted settlement retryable. Older rebuilds cannot replace newer cached
  stats. Materialized leaderboard rows support indexed top-100 queries.
- Mongo fixture leases renew during work, and lease ownership is checked before
  mutations; fixture/entry updates also use version predicates and bounded query
  execution. An inert first-save placeholder freezes no opponent and contributes
  to neither history nor stats if its deadline check fails.

## API contract

JSON keys are camelCase. Dates are ISO 8601 UTC strings. Fixture IDs are raw BSD
numeric strings; input also accepts a `bsd:` prefix. Except guest creation, all
routes require `Authorization: Bearer <credential>`. Random guest credentials
are returned once and stored as SHA-256 hashes server-side.

| Method and path | Purpose |
| --- | --- |
| `POST /players` | Create guest; return player and credential |
| `GET /state` | Player, lifetime stats, seasons, achievements, weekly challenge and nearby fixtures |
| `GET /fixtures?ids=123,456` | Batch game overlays for up to 200 fixtures |
| `GET /next-predictions?fixtureId=` | All editable AI-backed fixtures in the earliest eligible selected-competition gameweek, or the context fixture's gameweek |
| `PUT /predictions/:id` | Save `{homeScore,awayScore,penaltyWinner?,expectedAIRevision}`; first save requires reviewed revision |
| `DELETE /predictions/:id` | Withdraw before kick-off, preserving AI snapshot |
| `GET /stats?seasonId=` | Lifetime or one season's statistics |
| `GET /history?seasonId=&offset=0&limit=50` | Paginated personal entries and results |
| `GET /leaderboards?category=weekly\|season\|perfect&challengeId=&seasonId=` | Ranked challenge scores |
| `POST /game-center` | Verify proof and link guest identity; `restoreExisting:true` explicitly selects existing history |
| `GET /game-center/submissions` | Server-scored leaderboard/achievement payload for local GameKit submission |

`state`, `stats`, `history`, `next-predictions` and `leaderboards` accept an optional
`competitionId` query parameter (a canonical BSD numeric string). Omission selects
Premier League for existing clients. The exception is contextual `next-predictions`:
when only `fixtureId` is passed, its competition is inferred. An explicitly
conflicting competition is rejected. Batch `/fixtures` accepts mixed competitions;
PUT/DELETE derive the authoritative competition from the BSD event.

State/statistics include `competitions: [{id,name}]` from usable BSD predictions
and retained played history, plus the selected `competitionId`/`competitionName`.
Records, seasons, history, recent form and visible achievements are scoped to the
selected competition. The statistics cache rebuilds old data lazily into
`byCompetition`; original entries, credentials and AI snapshots survive untouched.
Game Center's existing achievement identifiers retain global progress. Seasoned
Pro requires two seasons within at least one competition, so playing concurrent
competitions does not unlock a two-season achievement.

All three leaderboard categories are competition-specific. An EPL prediction
never gains or loses leaderboard points because someone also plays the Champions
League. A challenge ID belonging to another competition returns
`400 wrong_competition`. The leaderboards response optionally includes
`gameCenterLeaderboardId` for opening that exact Friends leaderboard; an absent
mapping must not open an unrelated/global fallback board.

`PREDICTION_GAME_GC_LEADERBOARDS` supports explicit scopes such as
`{"season:203":"epl.203", "competition:7:season:203":"ucl.203"}`. The legacy
unprefixed keys are EPL-only. Explicit weekly keys include the full returned
challenge ID, for example `competition:7:weekly:competition:7:203:epl-2030-09-06`.
Each scope needs a distinct Apple leaderboard identifier. Reusing one identifier
for multiple scopes causes all ambiguous mappings to be omitted, preventing one
competition or week from overwriting another's result. These mappings do not
provision App Store Connect resources.

The settlement worker imports only fixtures with usable BSD predictions or
previously known game records. Interactive reads stay independent of the worker,
and mixed fixture reads load only the relevant competitions' prediction documents.
Cup settlement also reads scoped `bsd_incidents`: a completed PEN period supplies
the winner and the preceding ET/FT period supplies the on-field score, even if
BSD's top-level status or scores still describe the shootout. Incident-only result
corrections trigger a subsequent settlement pass.

Fixture DTOs include `ai.sourceRevision`, `ai.modelVersion`, `ai.frozenAt`, user
`prediction`, actual `result`, per-side awarded points and `locked`/`settled`/`void`
flags. `isSecondLeg` is true when BSD supplies `previous_leg_event_id`, and
retained if a later partial update omits that field. Errors are `{error,code}` with appropriate 400/401/404/409/429/503 status.
Scores and identity routes never accept client-computed statistics.

`next-predictions` returns `{serverTime,competitionId,competitionName,gameweekId,gameweekLabel,fixtures}`. Optional
`includeLocked=true` returns all matches in the selected gameweek, including live,
finished and unavailable-AI fixtures for read-only board rows. The default still
returns editable AI-backed matches. Without context the group is selected using
the earliest eligible fixture. A BSD
competition, season and `round_number` identify a gameweek, preserving the group when a fixture
is postponed. If round metadata is unavailable, the fallback uses the season and
London Friday–Thursday calendar week. The endpoint reads the complete upcoming
BSD schedule, without the scores screen's visible-date filter or the state
endpoint's 30-day window. Only matches still editable at server time and with a
usable AI prediction are returned, including already-saved predictions for review.
The client prioritizes unentered matches and excludes the current/visited IDs when
using Save and next, avoiding loops. A context never advances into another gameweek;
an exhausted context returns its gameweek metadata and an empty fixture array.

State and statistics responses also include `recentGameweeks`: the latest five
gameweeks with accepted player entries, including unfinished rounds. Each contains
`id`, `competitionId`, `competitionName`, `label`, `startsAt`, `youPoints`, `aiPoints`, `played`, `predicted`,
`totalMatches`, and `completed`. These aggregates read the player's full set of
entries independently of paginated history, then fetch only the relevant gameweeks.
Cancelled matches are excluded from match/participation denominators. Older server
responses without this field remain decodable by the app, using an empty list.

## Verification

`node --test api/prediction_game.test.js` exercises scoring, immutable snapshots,
late database writes, source changes, postponements, cancellations, correction and
restart recovery, stale-stat revision guards, fixture lease ownership, challenge
membership, guest credentials, Game Center cryptographic proofs and HTTP DTOs.
The HTTP tests invoke route handlers directly and never start the API server.

The v2 projection was checked against the ten BSD EPL Gameweek 4 predictions
stored on 9 September 2026. BSD's goal expectations averaged 2.87 per match, while
its modal scores averaged 1.90 (nine 1–1s and one 0–1). Rounding the same expected
goals produces 2.90 goals per match (seven 2–1s, one 1–1 and two 1–2s). For example,
Chelsea–Hull has expected goals 1.96–1.09, which projects to 2–1; Sunderland–Arsenal
has 0.88–1.54, which projects to 1–2. This is a check of goal calibration on one
upcoming gameweek, not evidence of improved result or exact-score accuracy.
