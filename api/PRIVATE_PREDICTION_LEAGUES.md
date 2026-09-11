# Private prediction leagues

Private mini-leagues reuse the canonical `pg_entries` predictions and the existing verified Game Center identity. No separate sign-in, Game Center friends permission or Apple leaderboard is created for a private league. Public Game Center boards remain independent.

## Rules and lifecycle

- Each league chooses one BSD competition. Its rounds contain **all** AI-supported fixtures in the official BSD season/round, rather than the public challenge's ten-match maximum. Competitions without official round information show a waiting state until usable rounds exist.
- A round opens 48 hours before its first scheduled kickoff. The first publication stores an immutable fixture set, scoring-rule version and shared AI snapshot. Publication never backfills a started round. A new league can use an already published round only while the entire round remains unstarted.
- Each member starts with the next full round after joining. Existing future predictions count; earlier-round points are never imported. Creating or joining across kickoff is rejected by a Mongo `$$NOW` guard and can be retried into the next round. An earlier-than-published kickoff is also excluded explicitly.
- A prediction can be changed until that match starts, using the existing server-guarded canonical save endpoint. Missing picks score zero. The normal 3/1/0 rules apply, including the existing extra-time/shootout outcome rule for cup competitions.
- A postponed fixture stays in its original snapshot even if BSD changes its round number. The unique fixture index prevents double scoring. Cancellations are excluded. An unfinished postponed fixture remains available in round history but cannot hold the default screen on an old round.
- Standings sort by points, then exact scores. Ties share positions. Former members retain only their already locked fixture history and are marked `left` or `removed`. The card's participant count includes those retained table rows, so its position denominator matches the table. The optional AI row has rank `0` and never takes a human podium position.
- Leaving ends future participation. A removed member cannot bypass removal with another invitation; an owner can permit them to join again with **reinstate**, which does not silently add them back. Rejoining starts a new eligibility period.
- An owner must transfer ownership to another active member or close the league. Transfer revokes outstanding invitations. Closing stops new participation, preserves locked-match history and result corrections, and makes settings read-only. Members, including the former owner, can then leave the closed league.
- League names are 2–40 characters. Limits are 20 active leagues per player, 100 active members per league, and 1,000 retained historical members per league to keep individual authorization documents bounded.

## Authentication and privacy

Every private endpoint requires a Bearer credential issued **after** successful Apple signature verification. The session stores a hashed Game Center subject and a 24-hour private expiry. A linked player record alone does not authorize an old guest credential. Every successful `POST /game-center` returns a new `credential`, `privateSessionExpiresAt` and `restoredExisting` flag; same-player rotation preserves the player's game.

The signed identity assignment uses an atomic subject comparison: simultaneous different Game Center assertions cannot overwrite an account linked by the other request. The existing timestamp, bundle, signing-key allowlist, signature and replay checks remain mandatory.

Canonical prediction writes for active private-league members require the same proof-bound session. Joining/creating and saving use a shared player lease, and authorization is rechecked inside the fixture lease immediately before the guarded write. No endpoint accepts a client point total, player identity or owner role as authority.

Membership, owner identity and invitation authorization live in **one versioned league document**. Compare-and-swap writes and expiring leases work with standalone MongoDB. A partially completed ownership transfer cannot grant stale owner privileges. Authorization is rechecked after slow reads before returning private data. Responses use `Cache-Control: private, no-store` and `Vary: Authorization`.

The `/fixtures` endpoint returns only the caller's canonical picks. `/predictions` returns an empty peer-prediction array until each individual fixture has actually started or reached its server deadline. This restriction includes owners and penalty-winner choices. Standings hide pre-lock participation counts as well. Voiding an unstarted fixture does not reveal picks early. Private identifiers, member names and tables never feed public Game Center submissions.

The iOS client additionally honors Game Center multiplayer restrictions, scopes private state to the currently authenticated Game Center account, and discards it on account changes.

## Invitations

Codes contain twelve cryptographically selected characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (60 bits). Only SHA-256 hashes are stored. Codes are reusable for seven days; their exact expiry and revocation are checked independently of Mongo's TTL cleanup. Creating a replacement atomically revokes earlier codes and prunes their lookup records.

Both invitation preview and redemption require verified identity and share persistent limits of 30 attempts per account and 100 per client IP in ten minutes. The limiter trusts forwarded addresses only from the local reverse proxy and uses the last validated address that proxy appended. Direct clients cannot spoof `X-Forwarded-For`. All private endpoints additionally enforce durable 120-read/40-write per-account minute limits.

The default URL is `https://top-scores.skynolimit.dev/invite/CODE`; `PREDICTION_GAME_INVITE_BASE_URL` can override that base for another deployment. APIs accept a code, that deployment's exact HTTPS invitation URL, or `topscores://invite/CODE`. No URL GET or link-preview request creates membership. The native join action calls the authenticated redemption API.

The website owns the generic invitation fallback and Apple association file. Deploy the web fallback/AASA and ship the iOS Associated Domains entitlement with the API release. Installation from the App Store does not promise deferred delivery of a link: the fallback includes a copyable code. No league name, member or standing is placed in public page metadata.

## API

All paths below are under `/api/v1/prediction-game`. JSON responses include ISO-8601 `serverTime`.

| Method | Path | Request / response |
|---|---|---|
| GET | `/my-leagues` | `{ leagues }` |
| POST | `/mini-leagues` | `{ name, competitionId, showAI? }` → `{ league }` |
| GET | `/mini-leagues/:id` | `{ league, rounds, members }` |
| PATCH | `/mini-leagues/:id` | Owner: `{ name?, showAI? }` → `{ league }` |
| GET | `/mini-leagues/:id/standings` | `scope=round\|season`, optional `roundId`/`seasonId` → `{ leagueId, scope, roundId, seasonId, rows }` |
| GET | `/mini-leagues/:id/fixtures` | Optional `roundId` → `{ fixtures, sharedAI: [{ fixtureId, ai }], scoringEligible, round }` |
| GET | `/mini-leagues/:id/predictions` | Optional `roundId` → `{ matches: [{ fixtureId, locked, predictions }] }` |
| POST | `/mini-leagues/:id/invitations` | Owner → `{ invitation: { id, code, url, expiresAt } }` (code returned once) |
| GET | `/mini-leagues/:id/invitations` | Owner → `{ invitations: [{ id, expiresAt, revokedAt, createdAt }] }` |
| DELETE | `/mini-leagues/:id/invitations/:invitationId` | Owner revocation → `{ ok: true }` |
| POST | `/mini-league-invitations/preview` | `{ code }` → `{ invitation: { leagueId, leagueName, competitionName, memberCount, expiresAt, alreadyMember, startsFrom } }` |
| POST | `/mini-league-invitations/redeem` | `{ code }` → `{ league }` |
| DELETE | `/mini-leagues/:id/membership` | Leave → `{ ok: true }` |
| DELETE | `/mini-leagues/:id/members/:memberId` | Owner removal → `{ ok: true }` |
| POST | `/mini-leagues/:id/members/:memberId/reinstate` | Owner permits fresh invitation join → `{ ok: true }` |
| POST | `/mini-leagues/:id/transfer` | Owner: `{ memberId }` → `{ ok: true }` |
| POST | `/mini-leagues/:id/close` | Owner closes → `{ ok: true }` |

Fixtures retain the existing `PredictionGameFixture` shape and personal frozen AI. `sharedAI` is a separate private benchmark, so its revision must not be submitted as the canonical first-save `expectedAIRevision`. `scoringEligible=false` explains that a remaining personal pick will not score in that league's current round.

Member IDs are opaque league-local UUIDs. Standings rows contain `memberId`, `displayName`, `rank`, `points`, `exactScores`, `correctResults`, `predicted`, `played`, `isYou`, `isAI`, and `status`. Private responses never include another person's canonical player ID.

Errors use the existing `{ code, error }` envelope. A stale Game Center proof receives `401 game_center_required`; outsiders and removed users receive `404 league_not_found`; owner-only operations return `403 owner_required`. Revoked and expired invitations share `404 invitation_unavailable`. Busy leases/concurrent changes return a retryable `409`. Unknown seasons/rounds cannot materialize arbitrary cache scopes.

## Storage, recovery and deployment

`ensureIndexes` in `mongo_client.js` is the additive migration. Existing player, prediction, personal AI and public leaderboard data remain unchanged. New storage:

- `pg_mini_leagues`: versioned authorization, memberships/eligibility intervals, invitation hashes and league settings. A short-lived `creating` draft enables database-clock activation; TTL removes interrupted drafts.
- `pg_mini_league_rounds`: immutable competition/season/round fixture and AI snapshots, unique fixture membership, derived completion metadata.
- `pg_mini_league_standings`: replacement totals by league and round/season, source revision, league version and durable `rebuildPending` intent.
- `pg_mini_league_invite_lookup`: hashed code lookup with expiry TTL.
- `pg_mini_league_attempts`: hashed account/IP rate counters with expiry TTL.

The existing settlement timer also refreshes private rounds and standings every minute. It revisits all retained seasons, so delayed result corrections are applied even without anyone opening the league. Standings calculate from authoritative results and canonical entries; they never add a result's points twice. Source reads and replacement writes occur inside the table lease, preventing an old calculation from overwriting a newer correction. Interrupted writes retain retry intent.

Interactive standings/fixture requests fetch entries only for the selected round or season. Round history reads exclude fixture snapshots; league cards reuse materialized season rows. Publication candidates are cached for fifteen seconds per competition, while the worker forces source refresh. Canonical saves always read current fixture status and enforce Mongo's clock at commit.

Run `node --test api/prediction_game.test.js api/private_prediction_leagues.test.js` for the backend contract, permissions, identity, invitation, deadline, privacy, scoring/correction and recovery tests. These tests invoke handlers directly and do not start the API server. Deployment, the existing index initializer and API restart remain operator actions.
