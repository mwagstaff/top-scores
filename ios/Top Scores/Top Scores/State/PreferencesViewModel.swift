import Foundation
import Combine

@MainActor
final class PreferencesViewModel: ObservableObject {
    @Published private(set) var availableLeagues: [String] = []
    @Published private(set) var availableChannels: [String] = []
    @Published var isLoadingLeagues = false
    @Published var isLoadingChannels = false
    @Published var errorMessage: String?

    func reload(baseURL: String) async {
        guard let url = URL(string: baseURL) else {
            errorMessage = "Invalid API base URL."
            return
        }

        errorMessage = nil
        isLoadingLeagues = true
        isLoadingChannels = true

        do {
            async let leagues = APIClient(baseURL: url).fetchCompetitions()
            async let channels = APIClient(baseURL: url).fetchChannels()
            let (loadedLeagues, loadedChannels) = try await (leagues, channels)
            availableLeagues = loadedLeagues.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            availableChannels = loadedChannels.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } catch {
            errorMessage = "Unable to load competitions or channels from the API."
        }

        isLoadingLeagues = false
        isLoadingChannels = false
    }
}
