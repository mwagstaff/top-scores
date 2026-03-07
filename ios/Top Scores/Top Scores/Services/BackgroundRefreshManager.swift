import BackgroundTasks
import Foundation

enum BackgroundRefreshManager {
    static let taskIdentifier = "dev.skynolimit.Top-Scores.refresh"
    private static let liveRefreshIntervalMinutes = 1

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }

    static func scheduleNextRefresh(intervalMinutes: Int, hasInProgressMatches: Bool = false) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        let resolvedIntervalMinutes = hasInProgressMatches
            ? min(max(1, intervalMinutes), liveRefreshIntervalMinutes)
            : max(1, intervalMinutes)
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
                let response = try await client.fetchMatches(preferences: snapshot)
                let preferenceFiltered = applyPreferenceFilters(to: response.matches, snapshot: snapshot)
                let sorted = sortedMatches(preferenceFiltered)
                let unfilteredSorted = sortedMatches(response.matches)

                MatchCache.save(matches: unfilteredSorted, lastUpdated: response.lastUpdated, snapshot: snapshot)
                SharedMatchesBridge.saveAndSync(
                    matches: sorted,
                    unfilteredMatches: unfilteredSorted,
                    lastUpdated: response.lastUpdated,
                    snapshot: snapshot
                )
                scheduleNextRefresh(
                    intervalMinutes: snapshot.refreshIntervalMinutes,
                    hasInProgressMatches: sorted.contains(where: \.isInProgress)
                )
                task.setTaskCompleted(success: true)
            } catch {
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

    private static func applyPreferenceFilters(to matches: [Match], snapshot: PreferencesSnapshot) -> [Match] {
        let competitionFiltered = applyCompetitionFilters(
            to: matches,
            selectedLeagues: snapshot.selectedLeagues,
            isEnabled: snapshot.competitionFilterEnabled
        )
        guard snapshot.channelFilterEnabled else { return competitionFiltered }
        guard !snapshot.selectedChannels.isEmpty else { return competitionFiltered }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        return competitionFiltered.compactMap { match in
            if let date = match.dateOnly, calendar.startOfDay(for: date) < today {
                return match
            }

            let relevantChannels = ChannelSelection.filterChannels(
                match.tvChannels,
                selectedOptions: snapshot.selectedChannels
            )
            guard !relevantChannels.isEmpty else { return nil }
            return match.withTvChannels(relevantChannels)
        }
    }

    private static func applyCompetitionFilters(
        to matches: [Match],
        selectedLeagues: [String],
        isEnabled: Bool
    ) -> [Match] {
        guard isEnabled else { return matches }
        guard !selectedLeagues.isEmpty else { return matches }

        let selected = Set(selectedLeagues.map {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        })

        return matches.filter { match in
            selected.contains(
                match.league
                    .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            )
        }
    }
}
