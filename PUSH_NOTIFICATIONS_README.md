# Push Notifications Implementation

This document describes the push notification system for Top Scores, which sends real-time match event notifications to users based on their preferences.

## Overview

The push notification system monitors live football matches and sends notifications for the following events:

- **Kick-off**: When a match starts (e.g., "Kick off: Watford vs Liverpool")
- **Half-time**: At half-time with current score (e.g., "HT: Watford 1 - 0 Liverpool")
- **Full-time**: At the end of the match (e.g., "FT: Watford 2 - 5 Liverpool" or "AET: Watford 0 - 0 Liverpool (Liverpool win 4-2 on penalties)")
- **Goals**: When a goal is scored (e.g., "Goal: Watford 2 - 4 Liverpool (F. Wirtz, assist: C. Gakpo)")
- **Red cards**: When a player receives a red card (e.g., "Red card: Watford (T. Deeney)")

## Architecture

### Components

1. **iOS App** ([NotificationManager.swift](ios/Top Scores/Top Scores/Services/NotificationManager.swift))
   - Handles APNS registration
   - Manages notification permissions
   - Stores APNS device token
   - Detects development vs production builds

2. **Preferences System**
   - [PreferencesStore.swift](ios/Top Scores/Top Scores/State/PreferencesStore.swift) - Stores user preferences including notification settings
   - [PreferencesView.swift](ios/Top Scores/Top Scores/Views/PreferencesView.swift) - UI for notification preferences
   - [PreferencesSyncService.swift](ios/Top Scores/Top Scores/Services/PreferencesSyncService.swift) - Syncs preferences to Redis

3. **Backend Services** (Node.js)
   - [apns_client.js](api/apns_client.js) - APNS communication layer
   - [match_monitor.js](api/match_monitor.js) - Match monitoring and event detection
   - [redis_client.js](api/redis_client.js) - User preferences storage
   - [server.js](api/server.js) - API endpoints and service initialization

### Data Flow

```
1. User enables notifications in iOS app
   ↓
2. iOS requests APNS permission
   ↓
3. iOS receives APNS device token
   ↓
4. iOS syncs preferences + APNS token + isDevelopmentBuild to Redis via API
   ↓
5. Match Monitor polls for live matches every 10 seconds
   ↓
6. When match event detected, Monitor checks Redis for interested users
   ↓
7. Notifications scheduled with user's configured delay (0-5 minutes)
   ↓
8. APNS sends notification to device (sandbox or production based on build)
```

## User Preferences

Users can configure the following notification settings in the Preferences screen:

### Notification Toggle
- **Enable push notifications**: Master switch for all notifications
- When enabled, the app requests notification permission from iOS

### Notification Delay
- **Delay options**: 0, 1, 2, 3, 4, or 5 minutes
- **Purpose**: Prevents spoilers when streaming a match with a delay
- **Implementation**: Server-side timer delays the APNS push by the configured amount

### Match Filtering
Notifications respect the user's existing preference filters:
- **Selected Leagues**: Only matches in selected competitions
- **Selected Channels**: Only matches on selected TV channels
- **EPL Teams Filter**: Only matches involving Premier League teams (if enabled)

## APNS Configuration

### Certificate Details
- **Key File**: `api/certs/APNS_AuthKey_SkyNoLimit_SandboxAndProd.p8`
- **Key ID**: `UQ2DV6UTF4`
- **Team ID**: `SJ8X4DLAN9`
- **Key Name**: `pushNotifications`
- **Supported Environments**: Both Sandbox (development) and Production

### Environment Detection
- **Development Builds**: Use APNS Sandbox
  - Detected via `#if DEBUG` or presence of `embedded.mobileprovision`
- **Production Builds**: Use APNS Production
  - App Store and TestFlight builds

## Backend Implementation

### Match Monitoring Process

The match monitor ([match_monitor.js](api/match_monitor.js)) performs the following:

1. **Daily Match Check** (every 60 seconds)
   - Fetches today's matches: `GET /api/v1/matches?start={today}&end={today}`
   - Identifies matches that are in progress or starting soon

2. **Match Polling** (every 10 seconds per match)
   - Polls match details: `GET /api/v1/matches/{match_details_id}`
   - Compares current state with previous state
   - Detects events: kick-off, goals, half-time, full-time, red cards

3. **User Notification Filtering**
   - Retrieves all user preferences from Redis
   - Filters users based on:
     - Notifications enabled
     - APNS token present
     - Match league in user's selected leagues
     - Match channels in user's selected channels (if applicable)
     - EPL teams filter (if enabled)

4. **Notification Scheduling**
   - Creates unique notification ID to prevent duplicates
   - Checks deduplication set (5-minute window)
   - Schedules notification with user's delay (0-5 minutes)
   - Sends via appropriate APNS environment (sandbox/production)

5. **Cleanup** (every 5 minutes)
   - Removes stale matches (no updates in 30 minutes)
   - Reports monitoring status to logs

### Duplicate Prevention

The system prevents duplicate notifications using:

1. **Notification ID Format**: `{deviceToken}:{matchId}:{eventType}:{homeScore}:{awayScore}`
2. **Deduplication Set**: In-memory Set tracking sent notifications
3. **Dedup Window**: 5 minutes - prevents re-sending if match data fluctuates
4. **Automatic Cleanup**: IDs removed from set after 5 minutes

### API Endpoints

#### Preferences Management
- `POST /api/v1/preferences` - Save user preferences
  - Body: `{ deviceToken, apnsToken, isDevelopmentBuild, preferences: {...} }`
- `GET /api/v1/preferences/{deviceToken}` - Get user preferences
- `DELETE /api/v1/preferences/{deviceToken}` - Delete user preferences
- `GET /api/v1/preferences` - Get all preferences (admin)

#### Notification Testing
- `POST /api/v1/notifications/test` - Send test notification
  - Body: `{ deviceToken, title, body, isDevelopmentBuild }`

#### Monitoring Status
- `GET /api/v1/monitor/status` - Get monitoring status
  - Returns: `{ isMonitoring, monitoredMatchCount, scheduledNotificationCount, dedupSetSize }`

## Installation

### Backend Setup

1. Install the APNS package:
```bash
cd api
npm install
```

This will install `@parse/node-apn` which is already added to `package.json`.

2. Ensure the APNS key file is present:
```bash
ls -la api/certs/APNS_AuthKey_SkyNoLimit_SandboxAndProd.p8
```

3. Start the server (user will do this):
```bash
npm start
```

The match monitor will automatically start 2 seconds after the server initializes.

### iOS Setup

The iOS app changes are already implemented. You need to:

1. Build and run the app in Xcode
2. Grant notification permission when prompted
3. Configure your notification preferences in Settings
4. The app will automatically register for APNS and sync preferences to Redis

## Testing

### 1. Test APNS Token Registration

1. Run the iOS app
2. Enable notifications in Preferences
3. Check the Xcode console for:
   ```
   [APNS] Successfully registered for remote notifications
   [APNS] Device token: abc123def456...
   [NotificationManager] APNS token updated and saved
   [PreferencesSync] Successfully synced preferences to Redis
   ```

### 2. Test Notification Delivery

Use the test endpoint to send a test notification:

```bash
curl -X POST http://localhost:3000/api/v1/notifications/test \
  -H "Content-Type: application/json" \
  -d '{
    "deviceToken": "YOUR_APNS_TOKEN_HERE",
    "title": "Test Goal",
    "body": "Watford 1 - 0 Liverpool (Deeney)",
    "isDevelopmentBuild": true
  }'
```

### 3. Test Match Monitoring

1. Create a test match using the test harness UI at `http://localhost:3000/admin/harness`
2. Enable notifications in the iOS app
3. Set your preferences to include the test match's league
4. Start the test match
5. Observe notifications arriving for:
   - Kick-off
   - Goals
   - Half-time
   - Full-time
   - Red cards (if any)

### 4. Test Notification Delay

1. Set notification delay to 2 minutes in Preferences
2. Create and start a test match
3. When a goal is scored, note the time
4. The notification should arrive 2 minutes later

### 5. Check Monitoring Status

```bash
curl http://localhost:3000/api/v1/monitor/status
```

Expected response:
```json
{
  "success": true,
  "isMonitoring": true,
  "monitoredMatchCount": 2,
  "scheduledNotificationCount": 0,
  "dedupSetSize": 5
}
```

## Troubleshooting

### No notifications received

1. **Check APNS token registration**:
   - View Xcode console logs for APNS registration
   - Verify token is saved in Redis: `GET /api/v1/preferences`

2. **Check notification permissions**:
   - iOS Settings → Top Scores → Notifications → Allow Notifications

3. **Check preferences**:
   - Ensure notifications are enabled in app Preferences
   - Verify league/channel filters match the test match

4. **Check server logs**:
   - Look for `[MatchMonitor]` logs showing match polling
   - Check for notification sending logs

5. **Verify APNS environment**:
   - Development builds must use sandbox APNS
   - Check `isDevelopmentBuild` flag in Redis preferences

### Duplicate notifications

The system should prevent duplicates, but if you receive duplicates:
- Check server logs for deduplication messages
- Verify notification IDs are unique
- Ensure dedup window (5 minutes) hasn't expired

### Match not being monitored

1. Check if match is "relevant":
   - Must be in progress, starting soon, or recently finished
   - Check match score_status field

2. Verify API responses:
   ```bash
   curl http://localhost:3000/api/v1/matches?start=2026-02-16&end=2026-02-16
   ```

3. Check monitoring status:
   ```bash
   curl http://localhost:3000/api/v1/monitor/status
   ```

## Production Deployment

### Before going to production:

1. **Update APNS Topic**: In [apns_client.js](api/apns_client.js), change:
   ```javascript
   const APNS_TOPIC = "com.mikewagstaff.TopScores"; // Your actual bundle ID
   ```

2. **Configure Environment Variables** (optional):
   ```bash
   export REDIS_HOST=your-redis-host
   export REDIS_PORT=6379
   export REDIS_PASSWORD=your-redis-password
   export PORT=3000
   ```

3. **Test with TestFlight**:
   - Build a production/distribution build
   - Upload to TestFlight
   - Verify `isDevelopmentBuild` is `false`
   - Test notifications arrive via production APNS

4. **Monitor Server Resources**:
   - CPU usage (polling can be intensive with many matches)
   - Memory usage (dedup set and scheduled notifications)
   - Redis connections

5. **Scale Considerations**:
   - Current polling interval: 10 seconds per match
   - With 10 concurrent matches: ~1 request/second
   - Consider rate limiting if scaling to 100+ concurrent matches

## Files Modified/Created

### iOS App
- ✅ [Top_ScoresApp.swift](ios/Top Scores/Top Scores/Top_ScoresApp.swift) - Added AppDelegate for APNS
- ✅ [NotificationManager.swift](ios/Top Scores/Top Scores/Services/NotificationManager.swift) - NEW: APNS management
- ✅ [PreferencesStore.swift](ios/Top Scores/Top Scores/State/PreferencesStore.swift) - Added notification preferences
- ✅ [PreferencesView.swift](ios/Top Scores/Top Scores/Views/PreferencesView.swift) - Added notification UI
- ✅ [PreferencesSyncService.swift](ios/Top Scores/Top Scores/Services/PreferencesSyncService.swift) - Added APNS token sync

### Backend
- ✅ [package.json](api/package.json) - Added @parse/node-apn dependency
- ✅ [apns_client.js](api/apns_client.js) - NEW: APNS communication module
- ✅ [match_monitor.js](api/match_monitor.js) - NEW: Match monitoring service
- ✅ [redis_client.js](api/redis_client.js) - Updated schema for APNS tokens
- ✅ [server.js](api/server.js) - Added monitoring initialization and endpoints

## Next Steps

1. **Install dependencies**: Run `npm install` in the `api` directory
2. **Build the iOS app**: Let Xcode build and run the app
3. **Test basic functionality**: Enable notifications and send a test notification
4. **Create a test match**: Use the test harness to simulate a match
5. **Verify notifications**: Ensure all event types are working correctly
6. **Test notification delays**: Verify delays work as configured
7. **Monitor resource usage**: Check CPU/memory during active matches

## Support

For issues or questions:
- Check server logs for `[MatchMonitor]`, `[APNS]`, and `[PreferencesSync]` messages
- Use the `/api/v1/monitor/status` endpoint to check system health
- Review Redis data using the `/api/v1/preferences` endpoint
