import BackgroundTasks
import Foundation

enum BackgroundRefreshManager {
    static let taskIdentifier = "dev.skynolimit.Top-Scores.refresh"
    private static let liveRefreshIntervalMinutes = 1
    private static let preferencesSyncIntervalMinutes = 5

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }

    static func scheduleNextRefresh(intervalMinutes: Int, hasInProgressMatches: Bool = false) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        let resolvedRefreshIntervalMinutes = hasInProgressMatches
            ? min(max(1, intervalMinutes), liveRefreshIntervalMinutes)
            : max(1, intervalMinutes)
        let resolvedIntervalMinutes = min(
            resolvedRefreshIntervalMinutes,
            preferencesSyncIntervalMinutes
        )
        request.earliestBeginDate = Date().addingTimeInterval(TimeInterval(resolvedIntervalMinutes * 60))
        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("Failed to schedule background refresh: \(error)")
        }
    }

    static func handleAppRefresh(task: BGAppRefreshTask) {
        let snapshot = PreferencesStore.loadSnapshot()
        scheduleNextRefresh(intervalMinutes: snapshot.refreshIntervalMinutes)

        let operation = Task {
            guard let baseURL = URL(string: snapshot.apiBaseURL) else {
                task.setTaskCompleted(success: false)
                return
            }

            do {
                let client = APIClient(baseURL: baseURL)
                let syncTask = Task {
                    await PreferencesSyncService.shared.syncPreferences(snapshot)
                }
                if let cacheState = try? await client.fetchCacheState() {
                    let invalidation = MatchCache.applyServerCacheState(cacheState)
                    if invalidation.shouldClearMatchCaches {
                        MatchCache.clear()
                        SharedMatchesBridge.clear()
                    }
                }
                let response = try await client.fetchMatches(preferences: snapshot)
                let visibleFixtures = MatchesStore.applyPreferenceFilters(
                    to: response.matches,
                    snapshot: snapshot,
                    mode: .fixtures
                )
                let visibleResults = MatchesStore.applyPreferenceFilters(
                    to: response.matches,
                    snapshot: snapshot,
                    mode: .results
                )
                let mergedVisible = mergeMatches(visibleFixtures + visibleResults)
                let sorted = sortedMatches(mergedVisible)
                let unfilteredSorted = sortedMatches(response.matches)
                let fixtureCoverageEnd = Calendar.current.date(
                    byAdding: .day,
                    value: 89,
                    to: Calendar.current.startOfDay(for: Date())
                )

                MatchCache.save(
                    matches: unfilteredSorted,
                    lastUpdated: response.lastUpdated,
                    fixtureCoverageEnd: fixtureCoverageEnd,
                    snapshot: snapshot
                )
                SharedMatchesBridge.saveAndSync(
                    matches: sorted,
                    unfilteredMatches: unfilteredSorted,
                    lastUpdated: response.lastUpdated,
                    snapshot: snapshot
                )
                await syncTask.value
                await AppIconBadgeManager.update(preferences: snapshot, matches: sorted)
                scheduleNextRefresh(
                    intervalMinutes: snapshot.refreshIntervalMinutes,
                    hasInProgressMatches: sorted.contains(where: \.isInProgress)
                )
                task.setTaskCompleted(success: true)
            } catch {
                await PreferencesSyncService.shared.syncPreferences(snapshot)
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            operation.cancel()
        }
    }

    private static func sortedMatches(_ matches: [Match]) -> [Match] {
        matches.sorted {
            let leftDate = $0.dateTime ?? MatchDateParser.shared.parse(date: $0.date, time: "00:00") ?? .distantFuture
            let rightDate = $1.dateTime ?? MatchDateParser.shared.parse(date: $1.date, time: "00:00") ?? .distantFuture
            if leftDate != rightDate {
                return leftDate < rightDate
            }

            let leagueCompare = $0.league.localizedCaseInsensitiveCompare($1.league)
            if leagueCompare != .orderedSame {
                return leagueCompare == .orderedAscending
            }

            let homeCompare = $0.homeTeam.localizedCaseInsensitiveCompare($1.homeTeam)
            if homeCompare != .orderedSame {
                return homeCompare == .orderedAscending
            }

            return $0.awayTeam.localizedCaseInsensitiveCompare($1.awayTeam) == .orderedAscending
        }
    }

    private static func mergeMatches(_ matches: [Match]) -> [Match] {
        var merged: [Match] = []
        var seen = Set<String>()
        for match in matches {
            guard !seen.contains(match.id) else { continue }
            seen.insert(match.id)
            merged.append(match)
        }
        return merged
    }
}
