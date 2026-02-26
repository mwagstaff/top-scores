# Match Simulator Test Harness

A standalone test harness for simulating live football matches to test the Top Scores app's real-time update functionality.

## Overview

The test harness allows you to create and control simulated football matches with:
- Configurable match speed (faster than real-time for testing)
- Automatic goal generation based on expected goals (xG)
- Manual event controls (goals, red cards)
- Real-time match progression (first half, HT, second half, FT, ET, penalties)
- Full match details including goal scorers, assists, and red cards

## Architecture

The test harness consists of three components:

1. **test_match_state.js** - Shared in-memory state module holding the active test match
2. **test_harness_server.js** - Standalone server (port 3001) with control panel UI
3. **Main API server integration** - Injects test match into `/matches` endpoint and provides `/matches/test_match_simulator_001` endpoint

## Getting Started

### Prerequisites

- Main API server running on port 3000
- Node.js installed

### Starting the Test Harness

1. Start your main API server:
   ```bash
   cd api
   npm start
   ```

2. In a separate terminal, start the test harness:
   ```bash
   cd api
   npm run test-harness
   ```

3. Open http://localhost:3001 in your browser to access the control panel

## Using the Control Panel

### Creating a Test Match

1. Fill in the match configuration:
   - **Home Team** / **Away Team**: Team names (free text)
   - **League**: Select from available competitions
   - **Competition Sub-heading**: Optional (e.g., "Round of 16")
   - **Starting Scores**: Default 0-0, but you can start with any score
   - **Expected Goals (xG)**: Controls automatic goal generation probability
   - **Match Speed**: How many real-time seconds per match minute (default: 10s)
   - **Stoppage Time**: First half (0-5 mins) and second half (0-10 mins)
   - **Extra Time**: Simulate 30 additional minutes if level at FT
   - **Penalties**: Simulate penalty shootout if level after ET

2. Click "Create & Configure Match"

### Controlling the Match

Once created, you can:

- **Start Match**: Begin the simulation (match progresses automatically)
- **Pause/Resume**: Pause and resume the simulation
- **Jump to HT**: Skip directly to half-time
- **Jump to FT**: Skip directly to full-time (or AET if in extra time)
- **Restart**: Reset the match to 0-0 and start over
- **Delete Match**: Remove the test match entirely

### Manual Events

While the match is running, you can manually trigger events:

- **Add Goal**: Score a goal for home or away team
  - Optionally specify goal scorer and assister names
  - Leave blank to auto-generate player names

- **Add Red Card**: Send off a player for home or away team
  - Optionally specify player name
  - Leave blank to auto-generate player name

### Automatic Events

The simulator automatically generates:

- **Goals**: Based on xG configuration with randomness
  - ~80% have an assister, ~20% don't
  - ~10% are penalties

- **Red Cards**: ~1/30 chance per minute (rare but realistic)

- **Player Names**: Realistic-sounding random names for goal scorers, assisters, and red card recipients

## How It Works

### Match Phases

1. **First Half**: Minutes 1-45
2. **First Half Stoppage**: 45+1 to 45+N (configurable)
3. **Half Time (HT)**: Brief pause
4. **Second Half**: Minutes 46-90
5. **Second Half Stoppage**: 90+1 to 90+N (configurable)
6. **Full Time (FT)**: Match ends
7. **Extra Time (ET)**: If enabled and scores level (30 additional minutes)
8. **After Extra Time (AET)**: If ET played and match finished
9. **Penalties (PENS)**: If enabled, ET played, and still level

### API Integration

The test match is injected into the main API server's responses:

- **`GET /api/v1/matches?start=YYYY-MM-DD&end=YYYY-MM-DD`**
  - Test match appears if its date falls within the requested range
  - Test match is marked with `"is_test_match": true`
  - Respects league and team filters

- **`GET /api/v1/matches/test_match_simulator_001`**
  - Returns full match details including:
    - Current score and status
    - Goal scorers with times
    - Assists with times
    - Red cards with times
    - Penalty shootout result (if applicable)

### iOS App Integration

The iOS app automatically:

- **DEBUG builds**: Show test matches normally
- **Release builds**: Filter out test matches (never shown)

This is controlled by the `#if DEBUG` build configuration in `MatchesStore.swift`.

## Match Speed Examples

- **10 seconds** (default): 90-minute match completes in ~15 minutes real-time
- **5 seconds**: 90-minute match completes in ~7.5 minutes real-time
- **1 second**: 90-minute match completes in ~1.5 minutes real-time
- **30 seconds**: 90-minute match completes in ~45 minutes real-time

## Testing Scenarios

### Test Goal Notifications
1. Create a match with high xG (e.g., 3 for each team)
2. Set match speed to 5-10 seconds
3. Start the match and observe goals appearing

### Test Match Status Updates
1. Create a match with default settings
2. Start the match
3. Watch status change: LIVE → 1' → 45' → HT → 46' → 90' → FT

### Test Extra Time & Penalties
1. Create a match starting at 1-1
2. Enable "Simulate Extra Time"
3. Enable "Simulate Penalties"
4. Set low xG (0.5 each) to keep it level
5. Jump to FT and watch ET/Pens unfold

### Test Manual Control
1. Create a match but don't start it
2. Use manual controls to add goals and red cards
3. Verify they appear correctly in the app

### Test Match Details
1. Create and start a match
2. Wait for some goals/events
3. In the iOS app, tap on the test match to view full details
4. Verify goal scorers, assists, and red cards are displayed correctly

## Troubleshooting

**Test match not appearing in app:**
- Verify main API server is running on port 3000
- Check that test match date is "today" or within your filter range
- Ensure you're running a DEBUG build of the iOS app

**Control panel not loading:**
- Verify test harness server is running on port 3001
- Check browser console for errors
- Ensure main API server is accessible

**Match not progressing:**
- Check if match is paused (click Resume)
- Verify match hasn't already ended (FT/AET status)
- Check test harness server console for errors

## Technical Details

### Shared State Module

The `test_match_state.js` module is imported by both:
- Main API server (server.js)
- Test harness server (test_harness_server.js)

This allows them to share the same in-memory match state without database/Redis dependencies.

### Match ID

All test matches use the fixed ID: `test_match_simulator_001`

This allows the iOS app to fetch match details via:
```
GET /api/v1/matches/test_match_simulator_001
```

### Goal Probability Calculation

Goals are generated per-minute based on xG:
```
probability_per_minute = (expected_goals / 90) * random_factor
random_factor = 0.7 to 1.3 (adds ±30% variance)
```

This means:
- xG of 2.0 = ~2.2% chance per minute
- Over 90 minutes, this converges toward 2 goals (with randomness)

## Files

- `test_match_state.js` - Shared state module
- `test_harness_server.js` - Standalone server
- `test_harness_ui.html` - Control panel UI
- `server.js` - Main API (modified to inject test match)
- `ios/Top Scores/Top Scores/Models/Match.swift` - Swift model (supports `is_test_match` field)
- `ios/Top Scores/Top Scores/State/MatchesStore.swift` - Filters test matches in Release builds

## Live Activity CLI Harness

You can also test Live Activity pushes directly from terminal without waiting for real match events.

### Prerequisites

1. API server running (default: `http://localhost:3011`).
2. iOS app has already uploaded:
   - `pushToStartToken` (for start)
   - `currentActivityPushToken` (for update/end, after start)
3. You know the app user device token (`X-Device-Token` value).

### Commands

```bash
cd api

# Inspect stored live activity token/state
./live_activity_test_harness.sh state <USER_DEVICE_TOKEN>

# Send a test START push
./live_activity_test_harness.sh start <USER_DEVICE_TOKEN> http://localhost:3011/api/v1 single_live

# Send a test START push against production API
./live_activity_test_harness.sh start <USER_DEVICE_TOKEN> prod single_live

# Force a brand new START push even if an activity already exists (debug only)
./live_activity_test_harness.sh start <USER_DEVICE_TOKEN> prod single_live true

# Keep test activity pinned for 10 minutes before auto-reconciler can end it
./live_activity_test_harness.sh start <USER_DEVICE_TOKEN> prod single_live false false 600

# Send a test UPDATE push
./live_activity_test_harness.sh update <USER_DEVICE_TOKEN> http://localhost:3011/api/v1 single_live

# Send a test END push
./live_activity_test_harness.sh end <USER_DEVICE_TOKEN>
```

Supported modes:
- `single_upcoming`
- `single_live`
- `multi_upcoming`
- `multi_live`

`multi_live` defaults to 10 fixtures for visual testing, including an ET/aggregate example (`110'`).

Supported API target aliases:
- `local` (default) -> `http://localhost:3011/api/v1`
- `prod` -> `https://api.skynolimit.dev/top-scores/api/v1`

`start` behavior:
- Default: upsert (updates existing Live Activity if activity token exists; starts new only when none exists)
- Optional `FORCE_START=true` to explicitly create a new activity for debugging
- Optional `TEST_HOLD_SECONDS` (default `300`, range `30-1800`) to suppress auto-end briefly while testing UI

### Raw API endpoints (if you prefer curl directly)

- `GET /api/v1/live-activity/test/state`
- `POST /api/v1/live-activity/test/start`
- `POST /api/v1/live-activity/test/update`
- `POST /api/v1/live-activity/test/end`

All accept `X-Device-Token` as the user device identity.
