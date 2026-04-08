# Live Activity Troubleshooting

This document is a focused runbook for debugging server-driven Live Activity issues in Top Scores.

## Quick Summary

- `POST /api/v1/live-activity/reconcile` forces a reconcile for one device.
- `POST /api/v1/live-activity/reconcile-all` forces a reconcile for all known devices.
- `GET /api/v1/live-activity/test/state?userDeviceToken=...` is the main inspection endpoint.

If the server preview is correct but the activity on-device does not update, the next question is whether the server actually sent a push and whether APNS accepted it.

## Key Endpoints

### Inspect one device

```bash
curl "https://api.skynolimit.dev/top-scores/api/v1/live-activity/test/state?userDeviceToken=DEVICE_TOKEN"
```

Important fields:

- `serverPresentation`
- `serverPresentation.debug.contentState`
- `liveActivity`
- `liveActivityDispatchDebug.recentPushes`
- `liveActivityDispatchDebug.recentDecisions`

### Force one device

```bash
curl -X POST "https://api.skynolimit.dev/top-scores/api/v1/live-activity/reconcile?force=true" \
  -H "Content-Type: application/json" \
  -d '{"userDeviceToken":"DEVICE_TOKEN"}'
```

### Force all devices

```bash
curl -X POST "https://api.skynolimit.dev/top-scores/api/v1/live-activity/reconcile-all"
```

Useful flags:

- `force=true|false`
- `allowEnd=true|false`
- JSON body `{"trigger":"manual_reconcile_all"}` or another operator label

## What `ExpiredToken` Means

Example server log:

```text
[APNS] Failed Live Activity push (sandbox, event=update): ExpiredToken
```

This means APNS rejected the stored Live Activity push token for that activity instance. The server may still report the evaluation itself as successful, because the evaluation ran and attempted dispatch, but APNS rejected the actual push.

Common causes:

- development/sandbox activity token became stale after reinstalling or redeploying the app
- the device started a newer activity and the stored `currentActivityPushToken` is no longer current
- the activity ended or was replaced, but the server still has the older token
- test devices running debug builds rotated to a fresh sandbox token after app changes

In practice, this is much more common on debug/sandbox devices than on stable production devices.

## Important Caveat About `reconcile-all`

`reconcile-all` only forces evaluation and push attempts. It cannot recover an expired APNS activity token.

If the stored token is stale:

1. the server builds the correct payload
2. the server attempts the push
3. APNS rejects it with `ExpiredToken`
4. the activity does not update

The fix is not another server reconcile. The fix is to get the device to register a fresh activity token.

## Development / Sandbox Recovery

If a debug device shows `ExpiredToken`:

1. Foreground the app so it can sync fresh Live Activity state.
2. If that does not help, restart the Live Activity from the app flow.
3. If that still does not help, reinstall or redeploy the app so the device re-registers tokens.
4. Then call `reconcile` or `reconcile-all` again.

Expected behavior:

- after reinstall/redeploy, the device should upload a new `currentActivityPushToken`
- subsequent update pushes should stop failing with `ExpiredToken`

## Production Expectations

For production devices, `reconcile-all` should work as long as:

- the device has an active Live Activity
- the server has the current activity push token
- APNS accepts the push

If a production device does not update:

1. inspect `test/state`
2. confirm `serverPresentation.debug.contentState` is correct
3. inspect `liveActivityDispatchDebug.recentPushes`
4. look for:
   - `status: "success"` with the expected payload
   - or a concrete APNS failure such as `ExpiredToken`

## Reading `test/state`

### Case 1: server selection is wrong

Symptoms:

- `serverPresentation.matches` is wrong
- `serverPresentation.debug.filteredCanonicalMatches` is wrong

This is a feed/selection/dedupe issue on the server before dispatch.

### Case 2: server selection is right, push never sent

Symptoms:

- `serverPresentation.debug.contentState` is correct
- `liveActivityDispatchDebug.recentPushes` has no new update push

This is an evaluation/skip-path problem.

### Case 3: push sent, APNS rejected

Symptoms:

- `recentPushes` includes an `update`
- push has an error like `ExpiredToken`

This is a stale token problem, not a payload-selection problem.

### Case 4: push sent and accepted, UI still wrong

Symptoms:

- `recentPushes` shows `status: "success"`
- payload content is correct
- device UI still shows old content

This is likely client-side or widget-side state retention.

## Current Server Behavior To Remember

Live Activity fixture selection is not BBC-only.

The Live Activity path still reads operational fallback datasets:

- `merged_matches`
- `bbc_range_matches`
- `recent_matches`

Those datasets can still contain LiveFootballOnTV-derived fixture rows. BBC-backed canonical matches should win, but fallback rows may still appear in Redis and can still affect troubleshooting if dedupe regresses.

## Recommended Operator Workflow

For one broken device:

1. Call `test/state`
2. Verify `serverPresentation.debug.contentState`
3. Call `reconcile?force=true`
4. Reload `test/state`
5. Inspect `recentPushes`

For broad production recovery:

1. Deploy server fix
2. Call `reconcile-all`
3. Inspect logs for APNS failures
4. Spot-check affected devices with `test/state`

## Known Good Signal

When the server side is healthy, you should see all of the following:

- `serverPresentation.matches` contains the expected fixtures
- `serverPresentation.debug.contentState.matches` contains the expected fixtures
- `liveActivityDispatchDebug.recentPushes` shows a recent `update`
- that push has `status: "success"`
- APNS logs do not show `ExpiredToken`
