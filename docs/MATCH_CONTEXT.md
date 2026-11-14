# Match context on web and iOS

Both clients use the additive `match_context` object on `/api/v1/matches/:id`.
The fixture list remains lightweight. BSD credentials stay on the server.

## Presentation

- Table position chips above Where to watch and its separator, then the AI match
  preview for upcoming matches, labelled **AI-generated**.
- Starting lineups and benches, labelled **AI predicted** or **Confirmed**. No
  player confidence percentages. Predicted teams use the **Predicted line-ups**
  heading. A partial teamsheet can show its known side.
- Head-to-head below lineups and benches: wins/draws/wins across all recorded
  meetings, followed by up to ten latest unique meetings. A missing score is
  displayed as a dash. Rows link only when their event has a usable stored match
  payload (matching ID, teams and kickoff date); only linked rows show a chevron.
- Fun facts at the bottom, retained after kickoff. Empty optional sections are
  omitted; zero recorded H2H meetings has an explicit empty state.

Preview text is normalized to plain text; its first paragraph is shown initially
with an expandable full preview. Both clients independently expire previews and
predictions at kickoff, even offline. Live, finished and postponed statuses also
hide pre-match content. Confirmed lineups remain visible.

## Storage and refresh

Raw provider responses are upserted into `bsd_lineups`, `bsd_h2h` and
`bsd_metadata`, keyed by event ID. `updated_at` is the internal fetch time;
provider timestamps remain inside `payload`. Standard Mongo `_id` indexes suffice
for the new collections; no migration or provider calls from clients are needed.

Lineup background polling warms the next 14 days, with at most 40 candidates per
30-second sweep, prioritizing live and nearest fixtures:

| Time to kickoff | Unconfirmed lineup cadence |
| --- | --- |
| 2–14 days | 6 hours |
| 2–48 hours | 2 hours |
| 75–120 minutes | 5 minutes |
| Final 75 minutes and late announcements | 1 minute |

Confirmed teams are checked every five minutes before kickoff for corrections.
Live unconfirmed lineups continue checking every minute; existing post-match
reconciliation remains in place. Upcoming fixtures with overdue kickoff times
remain eligible for three hours. Opening a future fixture also requests a
background lineup refresh, including fixtures beyond the 14-day warming window.

H2H refreshes daily; metadata refreshes every two hours before kickoff and daily
otherwise. A separate worker sweep warms ten upcoming fixtures per minute with
two concurrent events. Cold or stale match-detail reads request background
refresh without awaiting BSD. An unavailable response is cached normally;
failures preserve existing data and back off, while the shared BSD client also
enforces its token budget, Retry-After and exponential backoff. Independent
resource failures do not prevent the other context resources being saved.

Mongo lineup writes atomically prevent a prediction or unavailable response from
replacing confirmed data. Within the same status, an older provider timestamp
cannot replace newer data. A first confirmed response supersedes predictions
regardless of their timestamps.

Upcoming screens refresh our API every 30 seconds (15 seconds while context is
still missing). The website retains its 10-second live refresh and iOS its
existing live cadence. Screen updates use cached Mongo data, not synchronous
provider calls. No new alerts, background iOS execution or push notifications
are introduced.

## Validation and release

- Backend tests cover lifecycle gating, polling boundaries, unavailable/partial
  data, H2H ordering and orientation, independent failures, request coalescing,
  background hydration, and atomic lineup precedence.
- Web tests cover decoding, null values and exact kickoff expiry. Browser checks
  use the real React components with illustrative data at desktop/mobile widths.
- iOS tests cover kickoff expiry, cache replacement and missing-history values;
  rendering tests attach light, dark and accessibility-size images.
- Build web/SSR and the iOS simulator target before release. Deploy the API and
  BSD poller together, then web, then the iOS update. The new response field is
  additive and older clients ignore it. Confirm new collection writes and a
  real prediction-to-confirmation transition after deployment.
