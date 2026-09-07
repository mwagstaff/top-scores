import Combine
import Foundation

private struct StadiumArtworkCachePayload: Codable, Sendable {
    let apiBaseURL: String
    let fetchedAt: Date
    let etag: String?
    let catalog: StadiumArtworkCatalog
}

@MainActor
final class StadiumArtworkStore: ObservableObject {
    private static let refreshInterval: TimeInterval = 15 * 60

    @Published private(set) var catalog: StadiumArtworkCatalog?
    @Published private(set) var lastRefreshErrorDescription: String?

    private let cacheURL: URL
    private let session: URLSession?
    private var apiBaseURL: String?
    private var fetchedAt: Date?
    private var etag: String?
    private var refreshTask: Task<StadiumArtworkFetchResult, Error>?
    private var refreshGeneration = UUID()
    private var nextAttemptAt: Date?

    init(
        cacheURL: URL = StadiumArtworkStore.defaultCacheURL(),
        session: URLSession? = nil
    ) {
        self.cacheURL = cacheURL
        self.session = session
        if let cached = Self.loadCache(from: cacheURL) {
            catalog = cached.catalog
            apiBaseURL = cached.apiBaseURL
            fetchedAt = cached.fetchedAt
            etag = cached.etag
        }
    }

    func ensureFresh(apiBaseURL: String, force: Bool = false, now: Date = Date()) async {
        let normalizedBaseURL = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: normalizedBaseURL) else {
            lastRefreshErrorDescription = "Invalid API base URL."
            return
        }

        if self.apiBaseURL != nil, self.apiBaseURL != normalizedBaseURL {
            refreshTask?.cancel()
            refreshTask = nil
            refreshGeneration = UUID()
            nextAttemptAt = nil
            catalog = nil
            fetchedAt = nil
            etag = nil
        }
        self.apiBaseURL = normalizedBaseURL

        if !force, let nextAttemptAt, now < nextAttemptAt { return }

        if !force,
           let fetchedAt,
           now.timeIntervalSince(fetchedAt) < Self.refreshInterval {
            return
        }
        if let refreshTask {
            do {
                _ = try await refreshTask.value
            } catch is CancellationError {
                return
            } catch {
                lastRefreshErrorDescription = error.localizedDescription
            }
            return
        }

        let currentETag = etag
        let session = session
        lastRefreshErrorDescription = nil
        let task = Task {
            try await APIClient(baseURL: baseURL, session: session).fetchStadiumArtworkCatalog(
                ifNoneMatch: currentETag
            )
        }
        refreshTask = task
        let generation = UUID()
        refreshGeneration = generation
        // Failed refreshes should not be retried on every navigation event.
        nextAttemptAt = now.addingTimeInterval(60)
        defer {
            if refreshGeneration == generation { refreshTask = nil }
        }

        do {
            let result = try await task.value
            guard refreshGeneration == generation else { return }
            let refreshDate = now
            if result.isNotModified, catalog != nil {
                fetchedAt = refreshDate
                etag = result.etag ?? etag
                persistCache()
                return
            }
            guard let nextCatalog = result.catalog,
                  nextCatalog.schemaVersion == 1,
                  !nextCatalog.catalogVersion.isEmpty else {
                lastRefreshErrorDescription = "The server returned an unsupported stadium artwork catalogue."
                return
            }
            await StadiumArtworkImageCache.shared.prune(keeping: Set(nextCatalog.assets.map(\.sha256)))
            guard refreshGeneration == generation else { return }
            catalog = nextCatalog
            fetchedAt = refreshDate
            etag = result.etag
            persistCache()
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == generation else { return }
            lastRefreshErrorDescription = error.localizedDescription
            diagnosticLog("[StadiumArtwork] Catalog refresh failed: \(error)")
        }
    }

    #if DEBUG
    func deleteArtwork(_ asset: StadiumArtworkAsset, apiBaseURL: String, adminToken: String) async throws {
        guard let baseURL = URL(string: apiBaseURL) else { throw URLError(.badURL) }
        let nextCatalog = try await APIClient(baseURL: baseURL, session: session)
            .deleteStadiumArtwork(asset: asset, adminToken: adminToken)
        guard self.apiBaseURL == apiBaseURL else { return }
        refreshTask?.cancel()
        refreshTask = nil
        let generation = UUID()
        refreshGeneration = generation
        await StadiumArtworkImageCache.shared.prune(keeping: Set(nextCatalog.assets.map(\.sha256)))
        guard refreshGeneration == generation else { return }
        catalog = nextCatalog
        fetchedAt = Date()
        etag = "\"\(nextCatalog.catalogVersion)\""
        nextAttemptAt = nil
        lastRefreshErrorDescription = nil
        persistCache()
    }
    #endif

    func backdropAsset(selectionKey: String) -> StadiumArtworkAsset? {
        guard let assets = catalog?.genericBackdropAssets, !assets.isEmpty else { return nil }
        return assets[stableIndex(selectionKey, count: assets.count)]
    }

    func matchAsset(for match: Match, selectionSeed: UInt32? = nil) -> StadiumArtworkAsset? {
        guard let catalog else { return nil }
        return MatchStadiumArtworkResolver.shared.remoteAsset(
            for: match,
            catalog: catalog,
            selectionSeed: selectionSeed
        )
    }

    func teamHeroAsset(teamID: String?, teamName: String) -> StadiumArtworkAsset? {
        guard let catalog else { return nil }
        return MatchStadiumArtworkResolver.shared.remoteTeamHeroAsset(
            teamID: teamID,
            teamName: teamName,
            catalog: catalog
        )
    }

    func matchAssets(for match: Match) -> [StadiumArtworkAsset] {
        guard let catalog else { return [] }
        return MatchStadiumArtworkResolver.shared.remoteAssets(for: match, catalog: catalog)
    }

    func teamHeroAssets(teamID: String?, teamName: String) -> [StadiumArtworkAsset] {
        guard let catalog else { return [] }
        return MatchStadiumArtworkResolver.shared.remoteTeamHeroAssets(
            teamID: teamID, teamName: teamName, catalog: catalog
        )
    }

    func refreshWhileVisible(apiBaseURL: String) async {
        do {
            while !Task.isCancelled {
                await ensureFresh(apiBaseURL: apiBaseURL)
                try await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        } catch is CancellationError {
            return
        } catch {
            diagnosticLog("[StadiumArtwork] Refresh timer failed: \(error)")
        }
    }

    private func stableIndex(_ value: String, count: Int) -> Int {
        let hash = value.utf8.reduce(UInt32(2_166_136_261)) { partial, byte in
            (partial ^ UInt32(byte)) &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }

    private func persistCache() {
        guard let apiBaseURL, let fetchedAt, let catalog else { return }
        let payload = StadiumArtworkCachePayload(
            apiBaseURL: apiBaseURL,
            fetchedAt: fetchedAt,
            etag: etag,
            catalog: catalog
        )
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(payload).write(to: cacheURL, options: .atomic)
        } catch {
            diagnosticLog("[StadiumArtwork] Failed to persist catalog: \(error)")
        }
    }

    private static func loadCache(from url: URL) -> StadiumArtworkCachePayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StadiumArtworkCachePayload.self, from: data)
    }

    private nonisolated static func defaultCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stadium-artwork", isDirectory: true)
            .appendingPathComponent("catalog-cache.json")
    }
}
