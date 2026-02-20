# Redis User Preferences Sync

## Overview
User preferences are now automatically persisted to Redis based on device token. This allows preferences to be:
- Backed up automatically
- Restored across devices (if using same device token)
- Queried for analytics
- Synced in real-time as users make changes

## Architecture

### Database Structure
- **Database Name**: `top_scores`
- **Key Pattern**: `top_scores:user_preferences:{deviceToken}`
- **Storage Format**: JSON

### Data Model
```json
{
  "deviceToken": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
  "preferences": {
    "selectedLeagues": ["Premier League", "UEFA Champions League"],
    "selectedChannels": ["Sky Sports (all)", "TNT Sports (all)"],
    "competitionFilterEnabled": true,
    "channelFilterEnabled": true,
    "englishPremierLeagueTeamsOnly": false,
    "apiBaseURL": "http://example.com:3000/api/v1",
    "refreshIntervalMinutes": 10,
    "showAllMatches": false
  },
  "updatedAt": "2026-02-16T15:00:00.000Z"
}
```

## API Endpoints

### 1. Save User Preferences
**POST** `/api/v1/preferences`

Saves or updates user preferences in Redis.

**Request Body:**
```json
{
  "deviceToken": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
  "preferences": {
    "selectedLeagues": ["Premier League"],
    "selectedChannels": ["Sky Sports (all)"],
    "competitionFilterEnabled": true,
    "channelFilterEnabled": true,
    "englishPremierLeagueTeamsOnly": false,
    "apiBaseURL": "http://localhost:3000/api/v1",
    "refreshIntervalMinutes": 10,
    "showAllMatches": false
  }
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "deviceToken": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
    "preferences": { ... },
    "updatedAt": "2026-02-16T15:00:00.000Z"
  }
}
```

### 2. Get User Preferences
**GET** `/api/v1/preferences/{deviceToken}`

Retrieves preferences for a specific device.

**Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "deviceToken": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
    "preferences": { ... },
    "updatedAt": "2026-02-16T15:00:00.000Z"
  }
}
```

**Response (404 Not Found):**
```json
{
  "error": "Preferences not found for this device"
}
```

### 3. Delete User Preferences
**DELETE** `/api/v1/preferences/{deviceToken}`

Deletes preferences for a specific device.

**Response (200 OK):**
```json
{
  "success": true,
  "message": "Preferences deleted successfully"
}
```

### 4. Get All User Preferences (Admin)
**GET** `/api/v1/preferences`

Retrieves all stored preferences (useful for analytics/backup).

**Response (200 OK):**
```json
{
  "success": true,
  "count": 42,
  "data": [
    {
      "deviceToken": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
      "preferences": { ... },
      "updatedAt": "2026-02-16T15:00:00.000Z"
    },
    ...
  ]
}
```

## iOS Integration

### Automatic Sync
Preferences are automatically synced to Redis whenever the user makes changes. The `PreferencesStore.persist()` method triggers a background sync via `PreferencesSyncService`.

### Device Token
The device identifier is obtained from `UIDevice.current.identifierForVendor`, which:
- Remains consistent per app installation
- Changes if app is uninstalled and reinstalled
- Is unique per device and app combination
- Persists across app updates

### Debouncing
Syncs are debounced to a maximum of once per 2 seconds to avoid flooding the API when users make rapid changes.

### Error Handling
- Network errors are logged but don't interrupt the user experience
- Local preferences continue to work even if Redis sync fails
- Failed syncs are not retried (fire-and-forget approach)

## Redis Configuration

### Local Development (MacBook)
```bash
Host: 127.0.0.1
Port: 6379
Database: 0
Password: (none)
```

### Production (Oracle Server)
```bash
Host: <your-oracle-server-ip>
Port: 6379
Database: 0
Password: <set via REDIS_PASSWORD env var>
```

### Environment Variables
Set these in your environment or `.env` file:

```bash
# Redis connection
REDIS_HOST=127.0.0.1          # Default: 127.0.0.1
REDIS_PORT=6379               # Default: 6379
REDIS_DB=0                    # Default: 0
REDIS_PASSWORD=               # Default: none
```

## Files Created/Modified

### Backend (Node.js API)
1. **`api/redis_client.js`** (NEW)
   - Redis client initialization and connection management
   - CRUD operations for user preferences
   - Automatic reconnection handling

2. **`api/server.js`** (MODIFIED)
   - Added 4 new endpoints for preference management
   - Imports Redis client module

3. **`api/package.json`** (MODIFIED)
   - Added `redis` dependency (v4.x)

### iOS App
1. **`ios/Top Scores/Top Scores/Services/PreferencesSyncService.swift`** (NEW)
   - Actor-based service for async preference syncing
   - Device token retrieval
   - Debouncing logic
   - Fetch preferences from Redis (for restore feature)

2. **`ios/Top Scores/Top Scores/State/PreferencesStore.swift`** (MODIFIED)
   - Added automatic sync trigger in `persist()` method

## Testing

### Test Redis Connection
```bash
# Connect to Redis
redis-cli

# Test basic operations
127.0.0.1:6379> PING
PONG

# View all preference keys
127.0.0.1:6379> KEYS top_scores:user_preferences:*

# Get specific preference
127.0.0.1:6379> GET top_scores:user_preferences:XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX

# Delete all preferences (for testing)
127.0.0.1:6379> DEL top_scores:user_preferences:XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
```

### Test API Endpoints
```bash
# Save preferences
curl -X POST http://localhost:3000/api/v1/preferences \
  -H "Content-Type: application/json" \
  -d '{
    "deviceToken": "test-device-123",
    "preferences": {
      "selectedLeagues": ["Premier League"],
      "selectedChannels": ["Sky Sports (all)"],
      "competitionFilterEnabled": true,
      "channelFilterEnabled": true,
      "englishPremierLeagueTeamsOnly": false,
      "apiBaseURL": "http://localhost:3000/api/v1",
      "refreshIntervalMinutes": 10,
      "showAllMatches": false
    }
  }'

# Get preferences
curl http://localhost:3000/api/v1/preferences/test-device-123

# Get all preferences
curl http://localhost:3000/api/v1/preferences

# Delete preferences
curl -X DELETE http://localhost:3000/api/v1/preferences/test-device-123
```

## Monitoring

### Check Redis Memory Usage
```bash
redis-cli INFO memory
```

### View Connected Clients
```bash
redis-cli CLIENT LIST
```

### Monitor Real-time Commands
```bash
redis-cli MONITOR
```

### View Logs
```bash
# MacBook
tail -f /opt/homebrew/var/log/redis.log

# Production server logs
tail -f /var/log/redis/redis-server.log
```

## Data Persistence

Redis is configured with RDB snapshots:
- Snapshots taken every 15 minutes if 1+ changes
- Snapshots taken every 5 minutes if 10+ changes
- Snapshots taken every 60 seconds if 10000+ changes

Data location:
- **MacBook**: `/opt/homebrew/var/db/redis/dump.rdb`
- **Production**: `/var/lib/redis/dump.rdb`

## Security Considerations

1. **Device Token Privacy**: Device tokens are UUIDs and don't contain personally identifiable information
2. **API Access**: Consider adding authentication for admin endpoint (`GET /api/v1/preferences`)
3. **Rate Limiting**: Consider adding rate limits to prevent abuse
4. **HTTPS**: Use HTTPS in production to encrypt preferences in transit
5. **Redis Password**: Set `REDIS_PASSWORD` in production environment

## Future Enhancements

Potential improvements:
- User authentication (link device token to user account)
- Preference versioning/history
- Cross-device sync (if user has multiple devices)
- Analytics on popular leagues/channels
- Preference backup/restore feature in UI
- Expiration policy for inactive devices
