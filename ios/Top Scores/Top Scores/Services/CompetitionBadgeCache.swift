import Foundation
import SwiftUI
import UIKit

enum BundledCompetitionLogo {
    private static let assetNamesByCompetitionID: [String: String] = [
        "1": "FantasyPremierLeagueLion",
        "3": "CompetitionLogo3",
        "4": "CompetitionLogo4",
        "5": "CompetitionLogo5",
        "6": "CompetitionLogo6",
        "7": "CompetitionLogo7",
        "8": "CompetitionLogo8",
        "10": "CompetitionLogo10",
        "12": "CompetitionLogo12",
        "13": "CompetitionLogo13",
        "27": "CompetitionLogo27",
        "31": "CompetitionLogoInternationalFriendly",
        "39": "CompetitionLogo39",
        "40": "CompetitionLogo40",
        "41": "CompetitionLogo41",
        "42": "CompetitionLogo42",
        "43": "CompetitionLogo43",
        "44": "CompetitionLogo44",
        "58": "CompetitionLogo27",
        "59": "CompetitionLogo27",
        "62": "CompetitionLogo27",
        "63": "CompetitionLogo27",
        "64": "CompetitionLogo64",
        "83": "CompetitionLogo83",
        "86": "CompetitionLogo86",
        "87": "CompetitionLogo87",
        "90": "CompetitionLogo90",
        "91": "CompetitionLogo91",
        "bundesliga": "CompetitionLogo5",
        "championship": "CompetitionLogo12",
        "copa-del-rey": "CompetitionLogo41",
        "english-league-cup": "CompetitionLogo40",
        "fa-cup": "CompetitionLogo39",
        "fifa-world-cup-2026": "CompetitionLogo27",
        "german-super-cup": "CompetitionLogoGermanSuperCup",
        "international-friendly": "CompetitionLogoInternationalFriendly",
        "la-liga": "CompetitionLogo3",
        "league-one": "CompetitionLogo86",
        "league-two": "CompetitionLogo87",
        "national-league": "CompetitionLogo91",
        "ligue-1": "CompetitionLogo6",
        "premier-league": "FantasyPremierLeagueLion",
        "scottish-championship": "CompetitionLogo13",
        "scottish-league-one": "CompetitionLogo13",
        "scottish-league-two": "CompetitionLogo13",
        "scottish-premiership": "CompetitionLogo13",
        "serie-a": "CompetitionLogo4",
        "uefa-champions-league": "CompetitionLogo7",
        "uefa-conference-league": "CompetitionLogo83",
        "uefa-europa-league": "CompetitionLogo8",
        "uefa-nations-league": "CompetitionLogo64",
        "uefa-super-cup": "CompetitionLogo90"
    ]

    private static let assetNamesByCompetitionName: [String: String] = [
        "bundesliga": "CompetitionLogo5",
        "champions league": "CompetitionLogo7",
        "championship": "CompetitionLogo12",
        "copa del rey": "CompetitionLogo41",
        "coppa italia": "CompetitionLogo42",
        "coupe de france": "CompetitionLogo44",
        "dfb pokal": "CompetitionLogo43",
        "dfl supercup": "CompetitionLogoGermanSuperCup",
        "dutch eredivisie": "CompetitionLogo10",
        "efl cup": "CompetitionLogo40",
        "efl league one": "CompetitionLogo86",
        "efl league two": "CompetitionLogo87",
        "english league cup": "CompetitionLogo40",
        "english premier league": "FantasyPremierLeagueLion",
        "english national league": "CompetitionLogo91",
        "enterprise national league": "CompetitionLogo91",
        "fa cup": "CompetitionLogo39",
        "fifa world cup": "CompetitionLogo27",
        "fifa world cup 2026": "CompetitionLogo27",
        "german super cup": "CompetitionLogoGermanSuperCup",
        "international friendlies": "CompetitionLogoInternationalFriendly",
        "international friendly": "CompetitionLogoInternationalFriendly",
        "international friendly games": "CompetitionLogoInternationalFriendly",
        "la liga": "CompetitionLogo3",
        "league one": "CompetitionLogo86",
        "league two": "CompetitionLogo87",
        "national league": "CompetitionLogo91",
        "ligue 1": "CompetitionLogo6",
        "premier league": "FantasyPremierLeagueLion",
        "scottish championship": "CompetitionLogo13",
        "scottish league one": "CompetitionLogo13",
        "scottish league two": "CompetitionLogo13",
        "scottish premiership": "CompetitionLogo13",
        "serie a": "CompetitionLogo4",
        "spanish la liga": "CompetitionLogo3",
        "uefa champions league": "CompetitionLogo7",
        "uefa conference league": "CompetitionLogo83",
        "uefa europa conference league": "CompetitionLogo83",
        "uefa europa league": "CompetitionLogo8",
        "uefa nations league": "CompetitionLogo64",
        "uefa super cup": "CompetitionLogo90",
        "world cup qualifying concacaf": "CompetitionLogo27",
        "world cup qualifying conmebol": "CompetitionLogo27",
        "world cup qualifying ofc": "CompetitionLogo27",
        "world cup qualifying uefa": "CompetitionLogo27"
    ]

    static func assetName(competitionID: String?, competitionName: String) -> String? {
        competitionID.flatMap { assetNamesByCompetitionID[$0] }
            ?? assetNamesByCompetitionName[normalizedName(competitionName)]
    }

    private static func normalizedName(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}

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
