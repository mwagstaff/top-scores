# Home Screen Widget Implementation

## Overview
The Top Scores app now includes a fully functional, resizable home screen widget that displays match fixtures with live scores and automatic background updates.

## Features Implemented

### 1. **Resizable Widget Support**
- **Small Widget** (systemSmall): Compact view showing upcoming matches
- **Medium Widget** (systemMedium): Enhanced view with more matches
- **Large Widget** (systemLarge): Maximum matches with full details

All sizes dynamically adjust content to fit available space.

### 2. **Live Score Display**
- Shows real-time scores for matches in progress
- Displays match status (HT, FT, AET, PENS, live minute markers)
- Visual indicators for live matches (red highlight, pulsing effect)
- Team logos and TV channel icons

### 3. **User Preference Filtering**
- Respects competition filters (selected leagues)
- Respects TV channel filters (selected channels)
- Only shows matches matching user preferences
- Filters applied identically to main app

### 4. **Automatic Background Updates**

#### Timeline Refresh Strategy
- **Standard Interval**: 10 minutes when no live matches
- **Live Match Interval**: 5 minutes when matches are in progress or have reached kick-off without a live status
- Automatically switches between modes based on match status

#### Background App Refresh
The app uses iOS BackgroundTasks framework to update data even when closed:
- Registered task identifier: `dev.skynolimit.Top-Scores.refresh`
- Fetches latest match data from API
- Updates BBC Live scores for real-time match status
- Applies user preferences automatically
- Reloads widget timelines after successful fetch
- Schedules next refresh (1 minute if live matches, otherwise user preference)

#### Info.plist Configuration
Background modes enabled:
- `fetch` - Background fetch capability
- `processing` - Background processing for data updates

#### Shared Data Architecture
Uses App Group (`group.dev.skynolimit.topscores`) to share data between:
- Main app
- Widget extension
- Watch app

Data is synchronized via:
- `SharedMatchesBridge` - Saves matches and preferences to shared container
- `WidgetCenter.shared.reloadAllTimelines()` - Triggers widget refresh
- Automatic updates when app enters background

### 5. **Widget Data Model**

Enhanced `WidgetMatch` struct includes:
```swift
- date, time, homeTeam, awayTeam, league
- tvChannels: [String]
- homeScore: Int?
- awayScore: Int?
- scoreStatus: String?
- isInProgress: Bool (computed)
- isFinished: Bool (computed)
- displayScoreStatus: String? (formatted)
```

### 6. **Visual Design**

#### Match Row Components
- Team logos on both sides
- Team names (truncated with hyphen if needed)
- Center content switches based on match state:
  - **Pre-match**: TV channel icon + kick-off time
  - **Live/Finished**: Score display with status indicator
- Live matches show red status badge with background

#### Layout Optimization
- Dynamic layout calculation ensures maximum matches fit
- Headings for each date (Today, Tomorrow, or formatted date)
- Proper spacing and sizing for all widget families
- Graceful handling when no matches match filters

### 7. **Performance Optimizations**

- Logo caching (team and TV logos)
- Efficient layout builders (LargeLayoutBuilder, SmallLayoutBuilder)
- Minimal data transferred between app and widget
- Lossy JSON decoding to handle malformed data gracefully

## How It Works

### Data Flow
1. **Main App** fetches matches from API
2. **BackgroundRefreshManager** schedules background updates
3. **SharedMatchesBridge** saves filtered + unfiltered matches to App Group
4. **Widget** reads from the shared container and refreshes today’s started matches from the batch match-state API
5. **WidgetMatchPipeline** applies filters and groups the refreshed matches by date
6. **Widget Views** render matches with live scores
7. **Timeline Provider** schedules next refresh based on match status

### Background Update Trigger
- App entering background: Schedules BGAppRefreshTask
- Task executes: Fetches data, updates cache, syncs to widgets
- Widget timeline: Refreshes independently every 5-10 minutes, subject to WidgetKit’s system budget
- Combined strategy ensures widgets stay current even when app is closed

### User Experience
- Widget shows latest scores without opening app
- Live matches update every 2 minutes
- Matches respect user's selected leagues and channels
- Empty state when no matches match filters
- Smooth animations and visual feedback for live matches

## Testing

### Manual Testing
1. Add widget to home screen (all sizes)
2. Verify matches display correctly
3. Check filters work (leagues and channels)
4. Wait for live match to start
5. Verify score updates appear
6. Check refresh intervals (use system logs)

### Background Testing
1. Close app completely
2. Wait for background refresh (may take 15+ minutes)
3. Check widget updates with new data
4. Use Xcode Background Task debugging:
   ```bash
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"dev.skynolimit.Top-Scores.refresh"]
   ```

## Files Modified/Created

### Modified Files
1. `Top_ScoresWidgets.swift` - Enhanced with scores, live status, improved layouts
2. `Info.plist` - Added `processing` background mode
3. (No changes needed to SharedMatchesBridge - already includes score data)

### Created Files
1. `WidgetIntents.swift` - AppIntents for iOS 16+ widget interactions

## Apple Best Practices Followed

1. **Timeline Management**: Dynamic refresh intervals based on content
2. **Shared Containers**: App Group for data sharing
3. **Background Tasks**: Proper BGAppRefreshTask usage
4. **Widget Families**: Support for all standard sizes
5. **Placeholder Content**: Sample data for widget gallery
6. **Graceful Degradation**: Empty states and error handling
7. **Performance**: Caching, efficient layouts, minimal updates
8. **Privacy**: No data leaves device, respects user preferences

## Future Enhancements

Potential improvements:
- Interactive widgets (iOS 17+) for quick actions
- ConfigurableIntent for per-widget filter customization
- Lock screen widgets (iOS 16+)
- StandBy mode optimization
- Live Activities for match tracking (iOS 16.1+)
- Push notifications for score updates
