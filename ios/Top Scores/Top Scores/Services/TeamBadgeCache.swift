import Foundation
import SwiftUI
import UIKit

/// Downloads and caches TSDB badge images for all teams across all tracked
/// competitions. Active only when the server reports `team_logo_source == "tsdb"`.
///
/// Images are written to the shared app-group container so widgets and the
/// watch can also read them. The download is entirely asynchronous and
/// non-blocking: existing cached images continue to serve while new ones
/// arrive.
final class TeamBadgeCache {
    static let shared = TeamBadgeCache()
    static let badgesUpdatedNotification = Notification.Name("TeamBadgeCacheDidUpdate")

    // MARK: - Types

    private struct BadgeEntry: Codable {
        let name: String
        // swiftlint:disable:next identifier_name
        let badge_url: String
        // swiftlint:disable:next identifier_name
        let color_primary: String?
        // swiftlint:disable:next identifier_name
        let color_secondary: String?
    }

    private struct BadgesPayload: Codable {
        let team_logo_source: String?
        let updated_at: String?
        let teams: [String: BadgeEntry]
    }

    private struct ConfigPayload: Codable {
        let team_logo_source: String?
    }

    // MARK: - State

    /// badge_url → local file URL (computed once from the badge URL basename).
    private var cachedURLs: [String: URL] = [:]
    /// teamId → primary brand colour hex (TSDB strColour1), e.g. "#0000FF".
    private var primaryColorByTeamId: [String: String] = [:]
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()
    private var eTag: String?
    private var isRefreshing = false
    private let lock = NSLock()

    // Shared container used by app, widgets and watch.
    private let cacheDirectory: URL? = {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroupConfig.identifier)?
            .appendingPathComponent("team-badges", isDirectory: true)
    }()

    private init() {
        loadManifestFromDisk()
        loadColorsFromDisk()
    }

    // MARK: - Public API

    /// Primary brand colour (TSDB strColour1) for a team as a SwiftUI Color, or nil.
    func accentColor(forTeamId teamId: String) -> Color? {
        lock.lock()
        let hex = primaryColorByTeamId[teamId]
        lock.unlock()
        guard let hex, let uiColor = UIColor(teamBadgeHex: hex) else { return nil }
        return Color(uiColor: uiColor)
    }

    /// Returns a locally-cached UIImage for the given team ID, or nil if not yet downloaded.
    func image(forTeamId teamId: String) -> UIImage? {
        guard let url = localURL(forTeamId: teamId) else { return nil }

        let cacheKey = url.path as NSString
        if let image = imageCache.object(forKey: cacheKey) {
            return image
        }

        guard FileManager.default.fileExists(atPath: url.path),
              let image = UIImage(contentsOfFile: url.path)
        else {
            return nil
        }

        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    /// Call once at app startup (and optionally on background refresh). Fire-and-forget.
    func warmIfNeeded(apiBaseURL: String) {
        guard let base = URL(string: apiBaseURL) else {
            print("[TeamBadgeCache] warmIfNeeded: invalid apiBaseURL=\(apiBaseURL)")
            return
        }
        lock.lock()
        guard !isRefreshing else { lock.unlock(); print("[TeamBadgeCache] warmIfNeeded: already refreshing"); return }
        isRefreshing = true
        lock.unlock()
        print("[TeamBadgeCache] warmIfNeeded: starting refresh apiBaseURL=\(base)")

        Task.detached(priority: .utility) {
            defer {
                self.lock.lock()
                self.isRefreshing = false
                self.lock.unlock()
            }
            await self.refresh(apiBaseURL: base)
        }
    }

    // MARK: - Private

    private func refresh(apiBaseURL: URL) async {
        // 1. Check feature flag.
        let configURL = apiBaseURL.appendingPathComponent("teams/config")
        guard let config = try? await fetchJSON(ConfigPayload.self, from: configURL) else {
            print("[TeamBadgeCache] refresh: failed to fetch config url=\(configURL)")
            return
        }
        guard config.team_logo_source == "tsdb" else {
            print("[TeamBadgeCache] refresh: team_logo_source=\(config.team_logo_source ?? "nil") - skipping")
            return
        }

        // 2. Fetch badge manifest (304-aware).
        let badgesURL = apiBaseURL.appendingPathComponent("teams/badges")
        var request = URLRequest(url: badgesURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = eTag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            print("[TeamBadgeCache] refresh: failed to fetch badges url=\(badgesURL)")
            return
        }

        if http.statusCode == 304 { print("[TeamBadgeCache] refresh: badges 304 not modified"); return }
        guard http.statusCode == 200 else {
            print("[TeamBadgeCache] refresh: badges status=\(http.statusCode)")
            return
        }

        if let newETag = http.value(forHTTPHeaderField: "ETag") { eTag = newETag }

        guard let payload = try? JSONDecoder().decode(BadgesPayload.self, from: data) else {
            print("[TeamBadgeCache] refresh: failed to decode badges payload bytes=\(data.count)")
            return
        }
        print("[TeamBadgeCache] refresh: fetched manifest teams=\(payload.teams.count)")

        // 2b. Capture brand colours (TSDB strColour1) keyed by team id.
        var colors: [String: String] = [:]
        for (teamId, entry) in payload.teams {
            if let hex = entry.color_primary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !hex.isEmpty {
                colors[teamId] = hex
            }
        }
        lock.lock()
        primaryColorByTeamId = colors
        lock.unlock()
        saveColors()

        // 3. Ensure local cache directory exists.
        if let dir = cacheDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 4. Download each badge, skipping ones we already have at that URL.
        await withTaskGroup(of: Void.self) { group in
            for (teamId, entry) in payload.teams {
                guard !entry.badge_url.isEmpty else { continue }
                let badgeUrlString = entry.badge_url
                group.addTask {
                    await self.downloadIfNeeded(teamId: teamId, badgeUrlString: badgeUrlString)
                }
            }
        }

        // 5. Persist teamId → filename manifest so next launch is instant.
        saveManifest()
        print("[TeamBadgeCache] refresh: complete cachedURLs=\(self.cachedURLs.count)")
        NotificationCenter.default.post(name: TeamBadgeCache.badgesUpdatedNotification, object: nil)
    }

    private func saveManifest() {
        guard let dir = cacheDirectory else { return }
        lock.lock()
        let snapshot = cachedURLs.mapValues { $0.lastPathComponent }
        lock.unlock()
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func saveColors() {
        guard let dir = cacheDirectory else { return }
        lock.lock()
        let snapshot = primaryColorByTeamId
        lock.unlock()
        let colorsURL = dir.appendingPathComponent("colors.json")
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: colorsURL, options: .atomic)
    }

    private func loadColorsFromDisk() {
        guard let dir = cacheDirectory else { return }
        let colorsURL = dir.appendingPathComponent("colors.json")
        guard let data = try? Data(contentsOf: colorsURL),
              let colors = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        lock.lock()
        primaryColorByTeamId = colors
        lock.unlock()
        print("[TeamBadgeCache] init: loaded \(colors.count) team colours")
    }

    private func downloadIfNeeded(teamId: String, badgeUrlString: String) async {
        guard let dest = localPath(forBadgeURL: badgeUrlString) else { return }

        // Register the mapping so image(forTeamId:) can find it immediately.
        lock.lock()
        cachedURLs[teamId] = dest
        lock.unlock()

        // Content-addressed filenames: if the file already exists, the badge hasn't changed.
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }

        guard let badgeURL = URL(string: badgeUrlString) else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: badgeURL),
              !data.isEmpty else { return }

        try? data.write(to: dest, options: .atomic)
    }

    /// Local file URL derived from the badge URL basename (content-addressed by TSDB).
    private func localPath(forBadgeURL badgeUrlString: String) -> URL? {
        guard let dir = cacheDirectory,
              let url = URL(string: badgeUrlString) else { return nil }
        let filename = url.lastPathComponent
        guard !filename.isEmpty else { return nil }
        return dir.appendingPathComponent(filename)
    }

    private func localURL(forTeamId teamId: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return cachedURLs[teamId]
    }

    private func fetchJSON<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - On-disk restoration

    /// Synchronously loads the teamId→localURL manifest from disk.
    /// Called from init() so image(forTeamId:) works immediately on first access,
    /// before any network call completes.
    private func loadManifestFromDisk() {
        guard let dir = cacheDirectory else { return }
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        lock.lock()
        var loaded = 0
        for (teamId, filename) in manifest {
            let fileURL = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                cachedURLs[teamId] = fileURL
                loaded += 1
            }
        }
        lock.unlock()
        print("[TeamBadgeCache] init: loaded \(loaded)/\(manifest.count) from manifest")
    }

    /// Triggers a network refresh to pick up any new or changed badges.
    /// Call once at startup (and on background refresh). The manifest is already
    /// loaded from disk in init(), so this is purely a network warm-up.
    func restoreFromDisk(apiBaseURL: String) {
        print("[TeamBadgeCache] restoreFromDisk: triggering network refresh cachedURLs=\(cachedURLs.count)")
        warmIfNeeded(apiBaseURL: apiBaseURL)
    }
}

private extension UIColor {
    /// Parses a `#RRGGBB` (or `RRGGBB`) hex string into a UIColor.
    convenience init?(teamBadgeHex hex: String) {
        let raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard raw.count == 6, let value = UInt64(raw, radix: 16) else {
            return nil
        }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
