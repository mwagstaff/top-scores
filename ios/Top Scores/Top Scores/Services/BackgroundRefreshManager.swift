import BackgroundTasks
import Foundation

enum BackgroundRefreshManager {
    static let taskIdentifier = "dev.skynolimit.Top-Scores.refresh"
    private static let minimumRefreshIntervalMinutes = 15

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }

    static func scheduleNextRefresh(intervalMinutes: Int) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        let hasLinkedFantasyTeam = !(UserDefaults.standard.string(forKey: "fantasy.managerEntryID") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let resolvedIntervalMinutes = hasLinkedFantasyTeam
            ? minimumRefreshIntervalMinutes
            : max(minimumRefreshIntervalMinutes, intervalMinutes)
        request.earliestBeginDate = Date().addingTimeInterval(TimeInterval(resolvedIntervalMinutes * 60))
        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            try BGTaskScheduler.shared.submit(request)
        } catch {
            diagnosticLog("Failed to schedule background refresh: \(error)")
        }
    }

    static func handleAppRefresh(task: BGAppRefreshTask) {
        let operation = Task {
            let snapshot = PreferencesStore.loadSnapshot()
            scheduleNextRefresh(intervalMinutes: snapshot.refreshIntervalMinutes)
            async let fantasyRefresh: Void = refreshFantasySnapshotIfNeeded()

            guard let baseURL = URL(string: snapshot.apiBaseURL) else {
                await fantasyRefresh
                task.setTaskCompleted(success: false)
                return
            }

            do {
                let client = APIClient(baseURL: baseURL)
                if let cacheState = try? await client.fetchCacheState() {
                    let invalidation = MatchCache.applyServerCacheState(cacheState)
                    if invalidation.shouldClearMatchCaches {
                        MatchCache.clear()
                        SharedMatchesBridge.clear()
                    }
                }
                let response = try await client.fetchMatches(preferences: snapshot)
                let releaseMatches: [Match]
                #if DEBUG
                releaseMatches = response.matches
                #else
                releaseMatches = response.matches.filter { $0.isTestMatch != true }
                #endif
                let visibleFixtures = MatchesStore.applyPreferenceFilters(
                    to: releaseMatches,
                    snapshot: snapshot,
                    mode: .fixtures
                )
                let visibleResults = MatchesStore.applyPreferenceFilters(
                    to: releaseMatches,
                    snapshot: snapshot,
                    mode: .results
                )
                let mergedVisible = mergeMatches(visibleFixtures + visibleResults)
                let sorted = sortedMatches(mergedVisible)
                let unfilteredSorted = sortedMatches(releaseMatches)
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
                await fantasyRefresh
                await PreferencesSyncService.shared.syncPreferences(snapshot)
                await AppIconBadgeManager.update(preferences: snapshot, matches: sorted)
                scheduleNextRefresh(intervalMinutes: snapshot.refreshIntervalMinutes)
                task.setTaskCompleted(success: true)
            } catch {
                await fantasyRefresh
                await PreferencesSyncService.shared.syncPreferences(snapshot)
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            operation.cancel()
        }
    }

    private static func refreshFantasySnapshotIfNeeded() async {
        let rawEntryID = UserDefaults.standard.string(forKey: "fantasy.managerEntryID") ?? ""
        guard let entryID = Int(rawEntryID.trimmingCharacters(in: .whitespacesAndNewlines)),
              entryID > 0 else {
            return
        }

        do {
            let client = FantasyPublicAPIClient()
            let bootstrap = try await client.fetchBootstrapStatic()
            guard let gameweek = bootstrap.events.first(where: {
                $0.isCurrent == true && $0.dataChecked != true
            }) else {
                return
            }

            async let picksTask = client.fetchPicks(entryID: entryID, eventID: gameweek.id)
            async let liveTask = client.fetchEventLive(eventID: gameweek.id)
            async let fixturesTask = client.fetchAllFixtures()
            let (picks, live, seasonFixtures) = try await (picksTask, liveTask, fixturesTask)
            let eventFixtures = seasonFixtures.filter { $0.event == gameweek.id }
            let squad = FantasySquadBuilder.build(
                gameweek: gameweek,
                picksResponse: picks,
                liveResponse: live,
                fixtures: eventFixtures,
                seasonFixtures: seasonFixtures,
                bootstrap: bootstrap
            )
            FantasySyncStore.persist(managerEntryID: String(entryID), squad: squad)
            let historyRecord = FantasyMatchHistoryRecord(
                managerEntryID: entryID,
                gameweek: gameweek,
                picksResponse: picks,
                liveResponse: live,
                fixtures: eventFixtures,
                bootstrap: bootstrap
            )
            await FantasyMatchHistoryStore.shared.save(historyRecord)
        } catch is CancellationError {
            return
        } catch {
            diagnosticLog("Fantasy background refresh failed: \(error.localizedDescription)")
        }
    }

    private static func sortedMatches(_ matches: [Match]) -> [Match] {
        matches.sorted {
            let leftDate = $0.dateTime ?? MatchDateParser.parse(date: $0.date, time: "00:00") ?? .distantFuture
            let rightDate = $1.dateTime ?? MatchDateParser.parse(date: $1.date, time: "00:00") ?? .distantFuture
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
