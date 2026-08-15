import Foundation
import Combine

@MainActor
final class PreferencesViewModel: ObservableObject {
    @Published private(set) var availableLeagues: [String] = []
    @Published private(set) var competitionCatalog: [CompetitionCatalogEntry] = []
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
            async let catalog = APIClient(baseURL: url).fetchCompetitionCatalog()
            async let channels = APIClient(baseURL: url).fetchChannels()
            let (loadedCatalog, loadedChannels) = try await (catalog, channels)
            competitionCatalog = loadedCatalog.competitions
            availableLeagues = loadedCatalog.competitions.map(\.name).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            availableChannels = loadedChannels.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } catch {
            availableLeagues = []
            competitionCatalog = []
            availableChannels = []
            errorMessage = "Unable to load competitions or channels from the API."
        }

        isLoadingLeagues = false
        isLoadingChannels = false
    }
}
