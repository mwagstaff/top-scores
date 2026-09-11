import CryptoKit
import Foundation
import UIKit

actor StadiumPhotoCache {
    static let shared = StadiumPhotoCache()

    private struct PhotoIndex: Codable {
        var matchURLs: [String: String] = [:]
        var venueURLs: [String: String] = [:]
        var teamURLs: [String: String] = [:]

        private enum CodingKeys: String, CodingKey {
            case matchURLs
            case venueURLs
            case teamURLs
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            matchURLs = try container.decodeIfPresent([String: String].self, forKey: .matchURLs) ?? [:]
            venueURLs = try container.decodeIfPresent([String: String].self, forKey: .venueURLs) ?? [:]
            teamURLs = try container.decodeIfPresent([String: String].self, forKey: .teamURLs) ?? [:]
        }
    }

    private static let maximumDownloadBytes = 16 * 1_024 * 1_024
    private static let diskCapacity = 180 * 1_024 * 1_024

    private let cacheDirectory: URL
    private let indexURL: URL
    private let session: URLSession
    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 16
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var index = PhotoIndex()
    private var hasLoadedIndex = false

    init(
        cacheDirectory: URL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("stadium-photos", isDirectory: true),
        session: URLSession? = nil
    ) {
        self.cacheDirectory = cacheDirectory
        indexURL = cacheDirectory.appendingPathComponent("index.json")
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20
            configuration.httpMaximumConnectionsPerHost = 3
            self.session = URLSession(configuration: configuration)
        }
    }

    func knownPhotoURL(matchID: String?, venueID: String?) -> URL? {
        loadIndexIfNeeded()
        if let matchID = normalizedIdentifier(matchID),
           let value = index.matchURLs[matchID],
           let url = validRemoteURL(value) {
            return url
        }
        if let venueID = normalizedIdentifier(venueID),
           let value = index.venueURLs[venueID],
           let url = validRemoteURL(value) {
            return url
        }
        return nil
    }

    func knownTeamPhotoURL(teamID: String?, teamName: String) -> URL? {
        loadIndexIfNeeded()
        for key in teamKeys(teamID: teamID, teamName: teamName) {
            if let value = index.teamURLs[key], let url = validRemoteURL(value) {
                return url
            }
        }
        return nil
    }

    func recordPhotoURL(
        _ url: URL,
        matchID: String?,
        venueID: String?,
        teamID: String? = nil,
        teamName: String? = nil
    ) {
        guard validRemoteURL(url.absoluteString) != nil else { return }
        loadIndexIfNeeded()

        var changed = false
        if let matchID = normalizedIdentifier(matchID),
           index.matchURLs[matchID] != url.absoluteString {
            index.matchURLs[matchID] = url.absoluteString
            changed = true
        }
        if let venueID = normalizedIdentifier(venueID),
           index.venueURLs[venueID] != url.absoluteString {
            index.venueURLs[venueID] = url.absoluteString
            changed = true
        }
        if let teamName {
            for key in teamKeys(teamID: teamID, teamName: teamName)
                where index.teamURLs[key] != url.absoluteString {
                index.teamURLs[key] = url.absoluteString
                changed = true
            }
        }
        guard changed else { return }
        persistIndex()
    }

    func image(for url: URL) async -> UIImage? {
        guard validRemoteURL(url.absoluteString) != nil else { return nil }
        let key = url.absoluteString
        if let cached = images.object(forKey: key as NSString) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<UIImage?, Never> { [cacheDirectory, session] in
            await Self.loadImage(
                from: url,
                cacheDirectory: cacheDirectory,
                session: session
            )
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let pixelWidth = image.cgImage?.width ?? Int(image.size.width * image.scale)
            let pixelHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)
            images.setObject(
                image,
                forKey: key as NSString,
                cost: max(pixelWidth * pixelHeight * 4, 1)
            )
        }
        return image
    }

    private func loadIndexIfNeeded() {
        guard !hasLoadedIndex else { return }
        hasLoadedIndex = true
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode(PhotoIndex.self, from: data) else {
            return
        }
        index = decoded
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: indexURL, options: .atomic)
        } catch {
            diagnosticLog("[StadiumPhoto] Failed to persist photo index: %@", String(describing: error))
        }
    }

    private func normalizedIdentifier(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private func teamKeys(teamID: String?, teamName: String) -> [String] {
        var keys: [String] = []
        if let teamID = normalizedIdentifier(teamID) {
            keys.append("id:\(teamID.lowercased())")
        }
        let nameKey = TeamIdentityStore.normalizedKey(teamName)
        if !nameKey.isEmpty {
            keys.append("name:\(nameKey)")
        }
        return keys
    }

    private func validRemoteURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }

    private nonisolated static func loadImage(
        from remoteURL: URL,
        cacheDirectory: URL,
        session: URLSession
    ) async -> UIImage? {
        let fileURL = cacheDirectory
            .appendingPathComponent(cacheKey(for: remoteURL))
            .appendingPathExtension("image")

        if let data = try? Data(contentsOf: fileURL),
           let image = renderableImage(from: data) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: fileURL.path
            )
            return image
        }

        do {
            let (data, response) = try await session.data(from: remoteURL)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.mimeType?.lowercased().hasPrefix("image/") != false,
                  !data.isEmpty,
                  data.count <= maximumDownloadBytes,
                  let image = renderableImage(from: data) else {
                return nil
            }

            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            pruneDiskCache(at: cacheDirectory)
            return image
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            diagnosticLog("[StadiumPhoto] Image download failed: %@", String(describing: error))
            return nil
        }
    }

    private nonisolated static func cacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func renderableImage(from data: Data) -> UIImage? {
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            if elapsed >= 100 {
                diagnosticLog(
                    "[StadiumPhoto] image_decode elapsed_ms=%.1f bytes=%d main_thread=%@",
                    elapsed, data.count, String(Thread.isMainThread)
                )
            }
        }
        guard let image = UIImage(data: data) else { return nil }
        let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
        // UIImage(data:) defers decompression until drawing unless prepared here.
        return width > 1 && height > 1 ? image.preparingForDisplay() : nil
    }

    private nonisolated static func pruneDiskCache(at cacheDirectory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let images = files.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard url.pathExtension == "image",
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                  ) else { return nil }
            return (
                url,
                values.fileSize ?? 0,
                values.contentModificationDate ?? .distantPast
            )
        }
        var totalSize = images.reduce(0) { $0 + $1.size }
        guard totalSize > diskCapacity else { return }

        for file in images.sorted(by: { $0.date < $1.date }) {
            guard totalSize > diskCapacity else { break }
            do {
                try FileManager.default.removeItem(at: file.url)
                totalSize -= file.size
            } catch {
                continue
            }
        }
    }
}

nonisolated enum StadiumPhotoPrewarmPlanner {
    static let dayRadius = 1
    static let maximumMatches = 40

    static func dateRange(
        around date: Date,
        calendar: Calendar = .current
    ) -> ClosedRange<String>? {
        guard let start = calendar.date(byAdding: .day, value: -dayRadius, to: date),
              let end = calendar.date(byAdding: .day, value: dayRadius, to: date) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: start)...formatter.string(from: end)
    }

    static func candidates(from matches: [Match], around date: Date) -> [Match] {
        let startOfToday = Calendar.current.startOfDay(for: date)
        var seen = Set<String>()
        return matches
            .filter { $0.matchDetailsID != nil }
            .sorted { lhs, rhs in
                let lhsDistance = dayDistance(from: startOfToday, to: lhs.dateOnly)
                let rhsDistance = dayDistance(from: startOfToday, to: rhs.dateOnly)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                let lhsWeight = lhs.competitionWeight ?? 0
                let rhsWeight = rhs.competitionWeight ?? 0
                if lhsWeight != rhsWeight { return lhsWeight > rhsWeight }
                return lhs.id < rhs.id
            }
            .filter { match in
                guard let id = match.matchDetailsID else { return false }
                return seen.insert(id).inserted
            }
            .prefix(maximumMatches)
            .map { $0 }
    }

    private static func dayDistance(from startOfToday: Date, to matchDate: Date?) -> Int {
        guard let matchDate else { return .max }
        return abs(Calendar.current.dateComponents([.day], from: startOfToday, to: matchDate).day ?? .max)
    }
}

nonisolated enum TeamStadiumPhotoResolver {
    private static let maximumDetailsLookups = 3

    static func resolve(
        teamID: String?,
        teamName: String,
        from matches: [Match],
        apiBaseURL: String
    ) async -> URL? {
        let cache = StadiumPhotoCache.shared
        if let known = await cache.knownTeamPhotoURL(teamID: teamID, teamName: teamName) {
            return known
        }

        let homeMatches = homeMatchCandidates(teamName: teamName, from: matches)

        for match in homeMatches {
            if let value = match.venueDetails?.imageURL,
               let directURL = URL(string: value) {
                await cache.recordPhotoURL(
                    directURL,
                    matchID: match.matchDetailsID,
                    venueID: match.venueDetails?.id ?? match.venueID,
                    teamID: teamID ?? match.homeTeamId,
                    teamName: teamName
                )
                return directURL
            }
            if let known = await cache.knownPhotoURL(
                matchID: match.matchDetailsID,
                venueID: match.venueID
            ) {
                await cache.recordPhotoURL(
                    known,
                    matchID: match.matchDetailsID,
                    venueID: match.venueID,
                    teamID: teamID ?? match.homeTeamId,
                    teamName: teamName
                )
                return known
            }
        }

        guard let baseURL = URL(string: apiBaseURL) else { return nil }
        for match in homeMatches.prefix(maximumDetailsLookups) {
            guard !Task.isCancelled, let detailsID = match.matchDetailsID else { return nil }
            do {
                let details = try await APIClient(baseURL: baseURL).fetchMatchDetails(matchId: detailsID)
                try Task.checkCancellation()
                guard let value = details.venueDetails?.imageURL,
                      let imageURL = URL(string: value) else {
                    continue
                }
                await cache.recordPhotoURL(
                    imageURL,
                    matchID: detailsID,
                    venueID: details.venueDetails?.id ?? match.venueID,
                    teamID: teamID ?? match.homeTeamId,
                    teamName: teamName
                )
                return imageURL
            } catch is CancellationError {
                return nil
            } catch let error as URLError where error.code == .cancelled {
                return nil
            } catch {
                diagnosticLog(
                    "[StadiumPhoto] Team venue lookup failed id=%@ error=%@",
                    detailsID,
                    String(describing: error)
                )
            }
        }
        return nil
    }

    static func homeMatchCandidates(teamName: String, from matches: [Match]) -> [Match] {
        var seenMatchIDs = Set<String>()
        return matches.filter {
            TeamIdentityStore.shared.matches($0.homeTeam, teamName)
        }.filter { match in
            guard let detailsID = match.matchDetailsID else { return false }
            return seenMatchIDs.insert(detailsID).inserted
        }
    }
}

actor StadiumPhotoPrewarmer {
    static let shared = StadiumPhotoPrewarmer()

    private static let refreshInterval: TimeInterval = 6 * 60 * 60
    private static let maximumConcurrentDetailsRequests = 3
    private var activeKeys = Set<String>()

    func prewarm(
        apiBaseURL: String,
        preferences: PreferencesSnapshot,
        now: Date = Date()
    ) async {
        guard let baseURL = URL(string: apiBaseURL),
              let dateRange = StadiumPhotoPrewarmPlanner.dateRange(around: now) else {
            return
        }

        let runKey = "\(apiBaseURL)|\(dateRange.lowerBound)|\(dateRange.upperBound)"
        guard activeKeys.insert(runKey).inserted else { return }
        defer { activeKeys.remove(runKey) }

        let defaultsKey = "stadium.photo.prewarm.\(Self.hash(runKey))"
        if let lastRun = UserDefaults.standard.object(forKey: defaultsKey) as? Date,
           now.timeIntervalSince(lastRun) < Self.refreshInterval {
            return
        }

        do {
            let client = APIClient(baseURL: baseURL)
            let response = try await client.fetchFixtureBrowseMatches(
                from: dateRange.lowerBound,
                through: dateRange.upperBound,
                preferences: preferences,
                hydrateStates: false
            )
            try Task.checkCancellation()

            let candidates = StadiumPhotoPrewarmPlanner.candidates(
                from: response.matches,
                around: now
            )
            await prewarm(candidates: candidates, baseURL: baseURL)
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(now, forKey: defaultsKey)
        } catch is CancellationError {
            return
        } catch {
            diagnosticLog("[StadiumPhoto] Prewarm failed: %@", String(describing: error))
        }
    }

    private func prewarm(candidates: [Match], baseURL: URL) async {
        guard !candidates.isEmpty else { return }
        let concurrency = min(Self.maximumConcurrentDetailsRequests, candidates.count)

        await withTaskGroup(of: Void.self) { group in
            var iterator = candidates.makeIterator()
            for _ in 0..<concurrency {
                guard let match = iterator.next() else { break }
                group.addTask {
                    await Self.prewarm(match: match, baseURL: baseURL)
                }
            }

            while await group.next() != nil {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let match = iterator.next() {
                    group.addTask {
                        await Self.prewarm(match: match, baseURL: baseURL)
                    }
                }
            }
        }
    }

    private nonisolated static func prewarm(match: Match, baseURL: URL) async {
        let cache = StadiumPhotoCache.shared
        if let value = match.venueDetails?.imageURL,
           let directURL = URL(string: value) {
            await cache.recordPhotoURL(
                directURL,
                matchID: match.matchDetailsID,
                venueID: match.venueDetails?.id ?? match.venueID,
                teamID: match.homeTeamId,
                teamName: match.homeTeam
            )
            _ = await cache.image(for: directURL)
            return
        }
        if let knownURL = await cache.knownPhotoURL(
            matchID: match.matchDetailsID,
            venueID: match.venueID
        ) {
            _ = await cache.image(for: knownURL)
            return
        }

        guard let detailsID = match.matchDetailsID else { return }
        do {
            let details = try await APIClient(baseURL: baseURL).fetchMatchDetails(matchId: detailsID)
            try Task.checkCancellation()
            guard let value = details.venueDetails?.imageURL,
                  let imageURL = URL(string: value) else {
                return
            }
            await cache.recordPhotoURL(
                imageURL,
                matchID: detailsID,
                venueID: details.venueDetails?.id ?? match.venueID,
                teamID: match.homeTeamId,
                teamName: match.homeTeam
            )
            _ = await cache.image(for: imageURL)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            diagnosticLog(
                "[StadiumPhoto] Match prewarm failed id=%@ error=%@",
                detailsID,
                String(describing: error)
            )
        }
    }

    private nonisolated static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

actor TeamLinkStadiumPhotoPrewarmer {
    static let shared = TeamLinkStadiumPhotoPrewarmer()

    private static let lookupGate = TeamLinkStadiumPhotoLookupGate(limit: 3)
    private var inFlight: [String: Task<Void, Never>] = [:]

    func prewarm(
        context: TeamDetailsContext,
        candidateMatches: [Match],
        apiBaseURL: String
    ) async {
        let key = Self.key(context: context, apiBaseURL: apiBaseURL)
        if let task = inFlight[key] {
            await task.value
            return
        }
        let task = Task.detached(priority: .utility) {
            await Self.performPrewarm(
                context: context,
                candidateMatches: candidateMatches,
                apiBaseURL: apiBaseURL
            )
        }
        inFlight[key] = task
        await task.value
        inFlight[key] = nil
    }

    private nonisolated static func performPrewarm(
        context: TeamDetailsContext,
        candidateMatches: [Match],
        apiBaseURL: String
    ) async {
        let cache = StadiumPhotoCache.shared
        if let knownURL = await cache.knownTeamPhotoURL(
            teamID: context.teamID,
            teamName: context.teamName
        ) {
            _ = await cache.image(for: knownURL)
            return
        }

        await lookupGate.acquire()
        let imageURL = await resolveUncachedPhotoURL(
            context: context,
            candidateMatches: candidateMatches,
            apiBaseURL: apiBaseURL
        )
        await lookupGate.release()

        guard let imageURL else { return }
        _ = await cache.image(for: imageURL)
    }

    private nonisolated static func resolveUncachedPhotoURL(
        context: TeamDetailsContext,
        candidateMatches: [Match],
        apiBaseURL: String
    ) async -> URL? {
        var matches = candidateMatches
        if TeamStadiumPhotoResolver.homeMatchCandidates(
            teamName: context.teamName,
            from: matches
        ).isEmpty,
           let baseURL = URL(string: apiBaseURL) {
            let client = APIClient(baseURL: baseURL)
            do {
                let fixtures = try await client.fetchTeamFixtures(teamName: context.teamName)
                matches.append(contentsOf: fixtures.matches)

                if TeamStadiumPhotoResolver.homeMatchCandidates(
                    teamName: context.teamName,
                    from: matches
                ).isEmpty {
                    let results = try await client.fetchTeamResults(teamName: context.teamName)
                    matches.append(contentsOf: results.matches)
                }
            } catch is CancellationError {
                return nil
            } catch let error as URLError where error.code == .cancelled {
                return nil
            } catch {
                diagnosticLog(
                    "[StadiumPhoto] Team-link prewarm failed team=%@ error=%@",
                    context.teamName,
                    String(describing: error)
                )
            }
        }

        return await TeamStadiumPhotoResolver.resolve(
            teamID: context.teamID,
            teamName: context.teamName,
            from: matches,
            apiBaseURL: apiBaseURL
        )
    }

    private nonisolated static func key(
        context: TeamDetailsContext,
        apiBaseURL: String
    ) -> String {
        let normalizedTeamID = context.teamID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let teamKey = normalizedTeamID.isEmpty
            ? "name:\(TeamIdentityStore.normalizedKey(context.teamName))"
            : "id:\(normalizedTeamID)"
        return "\(apiBaseURL)|\(teamKey)"
    }
}

private actor TeamLinkStadiumPhotoLookupGate {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = max(1, limit)
    }

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
