import Foundation
import Combine

@MainActor
final class PreferencesViewModel: ObservableObject {
    typealias CompetitionLoader = (URL) async throws -> CompetitionCatalogResponse
    typealias ChannelLoader = (URL) async throws -> [String]

    private struct CatalogCache: Codable {
        var catalogsByBaseURL: [String: CompetitionCatalogResponse] = [:]
    }

    private static let catalogCacheKey = "preferences.competitionCatalogCache.v1"
    private let competitionLoader: CompetitionLoader
    private let channelLoader: ChannelLoader

    @Published private(set) var availableLeagues: [String] = []
    @Published private(set) var competitionCatalog: [CompetitionCatalogEntry] = []
    @Published private(set) var availableChannels: [String] = []
    @Published var isLoadingLeagues = false
    @Published var isLoadingChannels = false
    @Published var errorMessage: String?

    init(
        competitionLoader: @escaping CompetitionLoader = {
            try await APIClient(baseURL: $0).fetchCompetitionCatalog()
        },
        channelLoader: @escaping ChannelLoader = {
            try await APIClient(baseURL: $0).fetchChannels()
        }
    ) {
        self.competitionLoader = competitionLoader
        self.channelLoader = channelLoader
    }

    func reload(
        baseURL: String,
        loadCompetitions: Bool = true,
        loadChannels: Bool = true
    ) async {
        guard let url = URL(string: baseURL) else {
            errorMessage = "Invalid API base URL."
            return
        }

        errorMessage = nil
        if loadCompetitions {
            await loadCompetitionCatalog(baseURL: url)
        }
        if loadChannels {
            await loadChannelCatalog(baseURL: url)
        }
    }

    private func loadCompetitionCatalog(baseURL: URL) async {
        let cacheID = baseURL.absoluteString
        if competitionCatalog.isEmpty, let cachedCatalog = Self.cachedCatalog(for: cacheID) {
            apply(cachedCatalog)
        }

        isLoadingLeagues = competitionCatalog.isEmpty
        defer { isLoadingLeagues = false }

        do {
            let loadedCatalog = try await competitionLoader(baseURL)
            try Task.checkCancellation()
            apply(loadedCatalog)
            Self.cache(loadedCatalog, for: cacheID)
        } catch is CancellationError {
            return
        } catch {
            if competitionCatalog.isEmpty {
                errorMessage = "Unable to load competitions from the API."
            }
        }
    }

    private func loadChannelCatalog(baseURL: URL) async {
        isLoadingChannels = availableChannels.isEmpty
        defer { isLoadingChannels = false }

        do {
            let loadedChannels = try await channelLoader(baseURL)
            try Task.checkCancellation()
            availableChannels = loadedChannels.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        } catch is CancellationError {
            return
        } catch {
            if availableChannels.isEmpty {
                errorMessage = "Unable to load channels from the API."
            }
        }
    }

    private func apply(_ catalog: CompetitionCatalogResponse) {
        competitionCatalog = catalog.competitions
        availableLeagues = catalog.competitions.map(\.name).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static func cachedCatalog(for baseURL: String) -> CompetitionCatalogResponse? {
        guard
            let data = UserDefaults.standard.data(forKey: catalogCacheKey),
            let cache = try? JSONDecoder().decode(CatalogCache.self, from: data)
        else {
            return nil
        }
        return cache.catalogsByBaseURL[baseURL]
    }

    private static func cache(_ catalog: CompetitionCatalogResponse, for baseURL: String) {
        let defaults = UserDefaults.standard
        var cache = defaults.data(forKey: catalogCacheKey)
            .flatMap { try? JSONDecoder().decode(CatalogCache.self, from: $0) }
            ?? CatalogCache()
        cache.catalogsByBaseURL[baseURL] = catalog
        guard let encoded = try? JSONEncoder().encode(cache) else { return }
        defaults.set(encoded, forKey: catalogCacheKey)
    }
}
