import Foundation
import Combine

@MainActor
final class FantasyViewModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var data: FantasySquadDisplayData?
    @Published private(set) var rivalSquads: [FantasyRivalSquad] = []
    @Published private(set) var lastUpdated: Date?
    @Published var errorMessage: String?

    private let fantasyPublicClient = FantasyPublicAPIClient()

    func reset() {
        isLoading = false
        isRefreshing = false
        data = nil
        rivalSquads = []
        lastUpdated = nil
        errorMessage = nil
    }

    func refresh(managerEntryID: String, apiBaseURL: String, rivalManagers: [FantasyRivalManager]) async {
        let trimmedManagerID = managerEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entryID = Int(trimmedManagerID), entryID > 0 else {
            errorMessage = "Stored manager ID is invalid. Please relink your Fantasy account."
            return
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            errorMessage = "Invalid API base URL in preferences."
            return
        }

        let hadExistingData = data != nil
        if hadExistingData {
            isRefreshing = true
        } else {
            isLoading = true
        }

        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            let serverClient = APIClient(baseURL: baseURL)
            let currentGameweek = try await serverClient.fetchFantasyCurrentGameweek()

            async let bootstrapLookupTask = serverClient.fetchFantasyBootstrapLookup()
            async let picksTask = fantasyPublicClient.fetchPicks(
                entryID: entryID,
                eventID: currentGameweek.id
            )
            async let liveTask = fantasyPublicClient.fetchEventLive(eventID: currentGameweek.id)
            async let fixturesTask = fantasyPublicClient.fetchEventFixtures(eventID: currentGameweek.id)

            let (bootstrapLookup, picksResponse, liveResponse, fixtures) = try await (
                bootstrapLookupTask,
                picksTask,
                liveTask,
                fixturesTask
            )

            data = FantasySquadBuilder.build(
                gameweek: currentGameweek,
                picksResponse: picksResponse,
                liveResponse: liveResponse,
                fixtures: fixtures,
                bootstrap: bootstrapLookup
            )

            let normalizedRivals = deduplicatedRivals(
                rivalManagers: rivalManagers,
                excludingEntryID: entryID
            )

            var refreshedRivals: [FantasyRivalSquad] = []
            for rival in normalizedRivals {
                do {
                    let rivalPicks = try await fantasyPublicClient.fetchPicks(
                        entryID: rival.entryID,
                        eventID: currentGameweek.id
                    )
                    let rivalSquad = FantasySquadBuilder.build(
                        gameweek: currentGameweek,
                        picksResponse: rivalPicks,
                        liveResponse: liveResponse,
                        fixtures: fixtures,
                        bootstrap: bootstrapLookup
                    )
                    refreshedRivals.append(
                        FantasyRivalSquad(
                            entryID: rival.entryID,
                            teamName: rival.teamName,
                            managerName: rival.managerDisplayName,
                            squad: rivalSquad
                        )
                    )
                } catch {
                    continue
                }
            }

            rivalSquads = refreshedRivals.sorted { lhs, rhs in
                let left = lhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
                let right = rhs.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
                if left.caseInsensitiveCompare(right) != .orderedSame {
                    return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                }
                return lhs.entryID < rhs.entryID
            }
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func validateRivalEntryID(_ rawEntryID: String) async throws -> FantasyEntryProfile {
        let trimmed = rawEntryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RivalValidationError.empty
        }
        guard trimmed.allSatisfy(\.isNumber) else {
            throw RivalValidationError.nonNumeric
        }
        guard let entryID = Int(trimmed), entryID > 0 else {
            throw RivalValidationError.invalidNumber
        }
        return try await fantasyPublicClient.fetchEntryProfile(entryID: entryID)
    }

    private func deduplicatedRivals(
        rivalManagers: [FantasyRivalManager],
        excludingEntryID: Int
    ) -> [FantasyRivalManager] {
        var seen = Set<Int>()
        var result: [FantasyRivalManager] = []

        for rival in rivalManagers {
            guard rival.entryID > 0 else { continue }
            guard rival.entryID != excludingEntryID else { continue }
            guard !seen.contains(rival.entryID) else { continue }
            seen.insert(rival.entryID)
            result.append(rival)
        }

        return result
    }
}

private enum RivalValidationError: LocalizedError {
    case empty
    case nonNumeric
    case invalidNumber

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a manager ID to continue."
        case .nonNumeric:
            return "Manager ID must contain numbers only."
        case .invalidNumber:
            return "Manager ID is invalid."
        }
    }
}
