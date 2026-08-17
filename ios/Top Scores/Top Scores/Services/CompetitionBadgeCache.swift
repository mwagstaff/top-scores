import Foundation
import SwiftUI
import UIKit

nonisolated final class CompetitionBadgeCache: @unchecked Sendable {
    static let shared = CompetitionBadgeCache()
    static let badgesUpdatedNotification = Notification.Name("CompetitionBadgeCacheDidUpdate")

    private let lock = NSLock()
    private var localURLsByID: [String: URL] = [:]
    private var competitionIDsByNormalizedName: [String: String] = [:]
    private var isWarming = false
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()
    private let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("competition-badges", isDirectory: true)

    private init() {}

    func image(for competitionID: String) -> UIImage? {
        let url = lock.withLock { localURLsByID[competitionID] }
        guard let url else { return nil }

        let key = url.path as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    func image(competitionID: String?, competitionName: String) -> UIImage? {
        let resolvedID: String? = lock.withLock { () -> String? in
            if let competitionID, localURLsByID[competitionID] != nil {
                return competitionID
            }
            return competitionIDsByNormalizedName[Self.normalizedName(competitionName)]
        }
        guard let resolvedID else { return nil }
        return image(for: resolvedID)
    }

    func warmIfNeeded(entries: [CompetitionCatalogEntry]) {
        let shouldWarm = lock.withLock {
            guard !isWarming else { return false }
            isWarming = true
            return true
        }
        guard shouldWarm else { return }

        let candidates = entries.compactMap { entry -> (String, URL, URL)? in
            lock.withLock {
                for name in entry.allNames {
                    competitionIDsByNormalizedName[Self.normalizedName(name)] = entry.stableID
                }
            }
            guard let rawURL = entry.logoURL,
                  let remoteURL = URL(string: rawURL),
                  !remoteURL.lastPathComponent.isEmpty else {
                return nil
            }
            let localURL = cacheDirectory.appendingPathComponent(remoteURL.lastPathComponent)
            lock.withLock {
                localURLsByID[entry.stableID] = localURL
            }
            return (entry.stableID, remoteURL, localURL)
        }

        Task.detached(priority: .utility) { [candidates] in
            defer {
                self.lock.withLock {
                    self.isWarming = false
                }
            }
            try? FileManager.default.createDirectory(
                at: self.cacheDirectory,
                withIntermediateDirectories: true
            )

            var downloadedAny = false
            for batchStart in stride(from: 0, to: candidates.count, by: 4) {
                let batchEnd = min(candidates.count, batchStart + 4)
                let batch = Array(candidates[batchStart..<batchEnd])
                let downloaded = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                    for (competitionID, remoteURL, localURL) in batch {
                        group.addTask {
                            await self.downloadIfNeeded(
                                competitionID: competitionID,
                                remoteURL: remoteURL,
                                destination: localURL
                            )
                        }
                    }
                    var any = false
                    for await didDownload in group {
                        any = any || didDownload
                    }
                    return any
                }
                downloadedAny = downloadedAny || downloaded
            }

            if downloadedAny || !candidates.isEmpty {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Self.badgesUpdatedNotification,
                        object: nil
                    )
                }
            }
        }
    }

    private static func normalizedName(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined()
    }

    private func downloadIfNeeded(
        competitionID: String,
        remoteURL: URL,
        destination: URL
    ) async -> Bool {
        if FileManager.default.fileExists(atPath: destination.path) {
            return false
        }
        guard let (data, response) = try? await URLSession.shared.data(from: remoteURL),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else {
            return false
        }
        do {
            try data.write(to: destination, options: .atomic)
            lock.withLock {
                localURLsByID[competitionID] = destination
            }
            return true
        } catch {
            return false
        }
    }
}
