# TV match reminders

The iOS Matches on TV notification section defaults to enabled, minimum watchability
70 (Highly Watchable or better), ten minutes before kick-off. It still requires the
existing global push preference and iOS notification permission. Users can choose
all televised matches, 55+, 70+, or 85+, and 5/10/15/30 minutes. Existing match-event
and actual kick-off alerts remain independently controlled. Streaming delay does
not apply to TV reminders.

## Server operation

Runs within the existing Top Scores API match monitor on Sky; no new service or
upstream polling loop. Every 30 seconds it reads the cached BSD fixtures and
current user preferences, applies the shared Scores team/competition/channel
filters, and groups eligible fixtures with identical kick-off times. Deleted,
postponed, started, cancelled, non-televised and below-threshold fixtures are
excluded. Missing ratings qualify only for the all-matches option.

A reminder is eligible from its chosen lead time until 90 seconds afterwards,
never at/after kick-off. This short catch-up window avoids a backlog of obsolete
reminders after outages. Changed schedules and preferences are evaluated afresh.
APNs expiry is the fixture kick-off, with a stable collapse ID. Notification taps
open one match or the original group/date, independent of the currently browsed
Scores date or subsequent filter changes.

Duplicate protection uses existing Redis notification claims, namespaced by TV
reminder, APNs target/environment and kick-off timestamp, retained for seven days.
Changing the rating, lead time or membership does not resend an already-claimed
group. A rescheduled kick-off is a new group. Redis unavailability suppresses
sending until a durable claim is possible. The existing APNs sender performs its
single retry; a claimed delivery is not replayed by the scheduler after an
ambiguous failure or process crash (prefer a missed reminder to duplicates).

Delivery results are recorded in existing per-device/per-match notification
history as `tv_match_reminder`, `dispatch_mode=tv_reminder`. Inspect existing API
logs (`/home/mwagstaff/dev/top-scores` on Sky), `[TVReminders]` evaluation errors,
APNs delivery results and notification history when diagnosing missing reminders.
Check global push permission, APNs token/environment, saved preferences, Scores
eligibility, channels, current rating, exact UTC kick-off and the 90-second due
window before remediation. No new automatic recovery or alert rule is added.

## Verification and rollout

Run `node --test api/tv_match_reminders.test.js` and the Scores filtering/calendar,
watchability and match-monitor regressions. Build the iOS app and run
`TVMatchReminderTests` for persistence, migration defaults and notification routing.
Check the preference controls in light/dark mode and larger Dynamic Type sizes.

Deploy the API through the existing deployment process and distribute the iOS
build. Older preference records use the same enabled/70/10 defaults; users with
global push disabled remain excluded. The new app is needed for TV-specific tap
navigation. Verify an actual push on an opted-in device, grouped and single taps,
and the opt-out. An APNs success means acceptance, not proof of device delivery.
Local tests do not establish production scheduling or delivery.
