import Foundation
import UIKit

final class LogoResolver {
    static let shared = LogoResolver()

    private let fallbackName = "_noTeamLogo"
    private var normalizedLookup: [String: URL] = [:]
    private var coreLookup: [String: [URL]] = [:]
    private var originalLookup: [String: URL] = [:]
    private var cache: [String: UIImage] = [:]

    private init() {
        loadLogos()
    }

    func image(for teamName: String) -> UIImage? {
        if let cached = cache[teamName] {
            return cached
        }

        let url = resolveURL(for: teamName) ?? resolveURL(for: fallbackName)
        guard let url else { return nil }
        let image = UIImage(contentsOfFile: url.path)
        if let image {
            cache[teamName] = image
        }
        return image
    }

    func hasDedicatedLogo(for teamName: String) -> Bool {
        guard let resolved = resolveURL(for: teamName) else { return false }
        return !isFallbackURL(resolved)
    }

    func missingTeamNames(in teamNames: [String]) -> [String] {
        var missing: [String] = []
        var seen = Set<String>()

        for rawTeamName in teamNames {
            let normalizedDisplayName = Self.normalizedDisplayName(rawTeamName)
            guard !normalizedDisplayName.isEmpty else { continue }
            let dedupeKey = normalizedDisplayName.lowercased()
            guard !seen.contains(dedupeKey) else { continue }
            seen.insert(dedupeKey)
            if !hasDedicatedLogo(for: normalizedDisplayName) {
                missing.append(normalizedDisplayName)
            }
        }

        return missing.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func loadLogos() {
        var urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: "team-logos") ?? []
        if urls.isEmpty {
            urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
        }
        for url in urls {
            let fileName = url.deletingPathExtension().lastPathComponent
            let normalized = Self.normalizedKey(fileName)
            normalizedLookup[normalized] = url
            let core = Self.normalizedCoreKey(fileName)
            if !core.isEmpty {
                coreLookup[core, default: []].append(url)
            }
            originalLookup[fileName.lowercased()] = url
        }
    }

    private func resolveURL(for teamName: String) -> URL? {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if let direct = originalLookup[lower] {
            return direct
        }

        for alias in Self.aliases(for: trimmed) {
            let aliasKey = Self.normalizedKey(alias)
            if let match = normalizedLookup[aliasKey] {
                return match
            }
        }

        let normalized = Self.normalizedKey(trimmed)
        if let match = normalizedLookup[normalized] {
            return match
        }

        let core = Self.normalizedCoreKey(trimmed)
        if let uniqueCoreMatch = uniqueCoreMatch(for: core) {
            return uniqueCoreMatch
        }

        return fuzzyMatch(normalizedTeam: normalized)
    }

    private func uniqueCoreMatch(for coreKey: String) -> URL? {
        guard !coreKey.isEmpty else { return nil }
        guard let candidates = coreLookup[coreKey], !candidates.isEmpty else { return nil }

        var seenPaths = Set<String>()
        let unique = candidates.filter { seenPaths.insert($0.path).inserted }
        guard unique.count == 1 else { return nil }
        return unique[0]
    }

    private func fuzzyMatch(normalizedTeam: String) -> URL? {
        guard !normalizedTeam.isEmpty else { return nil }

        var bestKey: String?
        var bestScore: Double = 0

        for key in normalizedLookup.keys {
            let score = Self.similarity(normalizedTeam, key)
            if score > bestScore {
                bestScore = score
                bestKey = key
            }
        }

        if let bestKey, bestScore >= 0.78 {
            return normalizedLookup[bestKey]
        }

        return nil
    }

    private func isFallbackURL(_ url: URL) -> Bool {
        let fileName = url.deletingPathExtension().lastPathComponent.lowercased()
        return fileName == fallbackName.lowercased()
    }

    private static func normalizedDisplayName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func normalizedKey(_ value: String) -> String {
        normalizedTokens(value).joined()
    }

    private static func normalizedCoreKey(_ value: String) -> String {
        normalizedTokens(value, stripClubAffixes: true).joined()
    }

    private static func normalizedTokens(_ value: String, stripClubAffixes: Bool = false) -> [String] {
        let lowered = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        return lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0) }
            .filter { token in
                if stopWords.contains(token) {
                    return false
                }
                if stripClubAffixes, clubAffixWords.contains(token) {
                    return false
                }
                return true
            }
    }

    private static func aliases(for name: String) -> [String] {
        let lowered = name.lowercased()
        if let alias = aliasMap[lowered] {
            return [alias, lowered]
        }
        return [lowered]
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let distance = levenshtein(lhs, rhs)
        let maxLength = max(lhs.count, rhs.count)
        guard maxLength > 0 else { return 1 }
        return 1 - (Double(distance) / Double(maxLength))
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)

        var previous = Array(0...rhsChars.count)
        var current = Array(repeating: 0, count: rhsChars.count + 1)

        for (i, lhsChar) in lhsChars.enumerated() {
            current[0] = i + 1
            for (j, rhsChar) in rhsChars.enumerated() {
                let cost = lhsChar == rhsChar ? 0 : 1
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + cost
                )
            }
            previous = current
        }

        return previous[rhsChars.count]
    }

    private static let stopWords: Set<String> = [
        "fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk",
        "club", "de", "the", "and", "atletico", "athletic", "sporting"
    ]

    private static let clubAffixWords: Set<String> = [
        "city", "town", "united", "rovers", "county", "albion", "wanderers",
        "hotspur", "saint", "st", "calcio"
    ]

    private static let aliasMap: [String: String] = [
        "manchester united": "man united",
        "manchester city": "man city",
        "tottenham hotspur": "tottenham",
        "wolverhampton wanderers": "wolves",
        "sheffield united": "sheff utd",
        "sheffield wednesday": "sheff wed",
        "nottingham forest": "nottm forest",
        "borussia dortmund": "dortmund",
        "borussia m'gladbach": "m'gladbach",
        "athletic club": "athletic",
        "real betis": "betis",
        "real sociedad": "real sociedad",
        "fc copenhagen": "copenhagen",
        "fc porto": "porto",
        "paok thessaloniki": "paok",
        "paok thessaloniki fc": "paok",
        "inter milan": "inter",
        "ac milan": "ac milan"
    ]
}
