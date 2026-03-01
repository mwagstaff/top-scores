import Foundation
import Combine

@MainActor
final class FantasyViewModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var data: FantasySquadDisplayData?
    @Published private(set) var lastUpdated: Date?
    @Published var errorMessage: String?

    private let fantasyPublicClient = FantasyPublicAPIClient()

    func reset() {
        isLoading = false
        isRefreshing = false
        data = nil
        lastUpdated = nil
        errorMessage = nil
    }

    func refresh(managerEntryID: String, apiBaseURL: String) async {
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
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
