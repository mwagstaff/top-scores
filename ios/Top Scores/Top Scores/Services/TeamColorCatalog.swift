import Combine
import Foundation
import SwiftUI

struct TeamLineupNumberColors {
    let background: Color
    let foreground: Color
    let outline: Color?
}

struct TeamAccentColors {
    let primary: Color
    let secondary: Color
}

private struct TeamColorsCachePayload: Codable, Sendable {
    let fetchedAt: Date
    let catalog: TeamColorsCatalogResponse

    private enum CodingKeys: String, CodingKey {
        case fetchedAt
        case catalog
    }

    nonisolated init(fetchedAt: Date, catalog: TeamColorsCatalogResponse) {
        self.fetchedAt = fetchedAt
        self.catalog = catalog
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        catalog = try container.decode(TeamColorsCatalogResponse.self, forKey: .catalog)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(catalog, forKey: .catalog)
    }
}

@MainActor
final class TeamColorCatalog: ObservableObject {
    static let shared = TeamColorCatalog()

    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let cacheFileName = "team-colors-cache.json"

    @Published private(set) var refreshVersion = 0

    private let fallbackEntry = TeamColorEntry(
        name: "Default",
        aliases: [],
        primary: "#111111",
        secondary: "#FFFFFF",
        scheme: "default-dark",
        isFallback: true
    )

    private var cachedFetchedAt: Date?
    private var currentCatalog: TeamColorsCatalogResponse?
    private var exactByKey: [String: TeamColorEntry] = [:]
    private var refreshTask: Task<TeamColorsCatalogResponse, Error>?

    private init() {
        loadCache()
    }

    func ensureFresh(apiBaseURL: String) async {
        guard shouldRefresh(now: Date()) else { return }

        if let inFlight = refreshTask {
            _ = try? await inFlight.value
            return
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            log("Invalid team colors base URL: \(apiBaseURL)")
            return
        }

        let task = Task<TeamColorsCatalogResponse, Error> {
            let client = APIClient(baseURL: baseURL)
            return try await client.fetchTeamColors()
        }
        refreshTask = task

        defer { refreshTask = nil }

        do {
            let payload = try await task.value
            apply(catalog: payload, fetchedAt: Date(), notify: true)
            persistCache()
            log("Team colors cache refreshed with \(payload.teams.count) mappings.")
        } catch {
            log("Team colors refresh failed: \(String(describing: error))")
        }
    }

    func lineupColors(for teamName: String, opponentTeamName: String?, isAway: Bool) -> TeamLineupNumberColors {
        let entry = resolve(teamName) ?? fallbackEntry
        let opponent = opponentTeamName.flatMap(resolve)
        let invert = isAway && shouldInvert(entry, against: opponent)
        let backgroundHex = invert ? entry.secondary : entry.primary
        let preferredForegroundHex = invert ? entry.primary : entry.secondary
        let foregroundHex = accessibleForegroundHex(
            backgroundHex: backgroundHex,
            preferredForegroundHex: preferredForegroundHex
        )

        return TeamLineupNumberColors(
            background: Color(hex: backgroundHex) ?? Color.black.opacity(0.92),
            foreground: Color(hex: foregroundHex) ?? Color.white,
            outline: foregroundHex.caseInsensitiveCompare(preferredForegroundHex) == .orderedSame
                ? outlineColor(backgroundHex: backgroundHex, foregroundHex: foregroundHex)
                : nil
        )
    }

    func accentColors(for teamName: String) -> TeamAccentColors {
        guard let entry = resolve(teamName) else {
            return TeamAccentColors(primary: Color.accentColor, secondary: .white)
        }
        return TeamAccentColors(
            primary: Color(hex: entry.primary) ?? Color.accentColor,
            secondary: Color(hex: entry.secondary) ?? .white
        )
    }

    private func shouldRefresh(now: Date) -> Bool {
        guard let fetchedAt = cachedFetchedAt else {
            return true
        }
        return now.timeIntervalSince(fetchedAt) >= Self.cacheTTL || exactByKey.isEmpty
    }

    private func apply(catalog: TeamColorsCatalogResponse, fetchedAt: Date, notify: Bool) {
        currentCatalog = catalog
        cachedFetchedAt = fetchedAt

        var lookup: [String: TeamColorEntry] = [:]
        for team in catalog.teams {
            let entry = TeamColorEntry(
                name: team.name,
                aliases: team.aliases,
                primary: team.primary,
                secondary: team.secondary,
                scheme: team.scheme,
                isFallback: false
            )
            for candidate in [entry.name] + entry.aliases {
                let key = TeamIdentityStore.normalizedKey(candidate)
                guard !key.isEmpty else { continue }
                if lookup[key] == nil {
                    lookup[key] = entry
                }
            }
        }

        exactByKey = lookup
        TeamIdentityStore.shared.update(from: catalog)

        if notify {
            refreshVersion &+= 1
        }
    }

    private func resolve(_ teamName: String) -> TeamColorEntry? {
        let key = TeamIdentityStore.normalizedKey(teamName)
        guard !key.isEmpty else { return nil }
        if let direct = exactByKey[key] {
            return direct
        }
        let canonical = TeamIdentityStore.shared.canonicalName(for: teamName)
        let canonicalKey = TeamIdentityStore.normalizedKey(canonical)
        guard !canonicalKey.isEmpty else { return nil }
        return exactByKey[canonicalKey]
    }

    private func shouldInvert(_ entry: TeamColorEntry, against opponent: TeamColorEntry?) -> Bool {
        guard let opponent else { return false }

        if entry.isFallback || opponent.isFallback {
            return false
        }

        if let scheme = entry.scheme, let opponentScheme = opponent.scheme,
           scheme.caseInsensitiveCompare(opponentScheme) == .orderedSame {
            return true
        }

        if areColorsSimilar(entry.primary, opponent.primary) {
            return true
        }

        return entry.primary.caseInsensitiveCompare(opponent.primary) == .orderedSame &&
            entry.secondary.caseInsensitiveCompare(opponent.secondary) == .orderedSame
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(TeamColorsCachePayload.self, from: data) else {
            log("Failed to decode team colors cache; ignoring stored data.")
            return
        }

        apply(catalog: payload.catalog, fetchedAt: payload.fetchedAt, notify: false)
    }

    private func persistCache() {
        guard let fetchedAt = cachedFetchedAt, let currentCatalog else { return }

        let payload = TeamColorsCachePayload(fetchedAt: fetchedAt, catalog: currentCatalog)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: cacheURL, options: [.atomic])
    }

    private var cacheURL: URL {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("TopScores", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(Self.cacheFileName)
    }

    private func log(_ message: @autoclosure () -> String) {
        diagnosticLog("[TeamColorCatalog] \(message())")
    }

    private func accessibleForegroundHex(backgroundHex: String, preferredForegroundHex: String) -> String {
        guard contrastRatio(backgroundHex, preferredForegroundHex) < 4.5 else {
            return preferredForegroundHex
        }

        let whiteContrast = contrastRatio(backgroundHex, "#FFFFFF")
        let blackContrast = contrastRatio(backgroundHex, "#000000")
        return whiteContrast >= blackContrast ? "#FFFFFF" : "#000000"
    }

    private func outlineColor(backgroundHex: String, foregroundHex: String) -> Color? {
        guard contrastRatio(backgroundHex, foregroundHex) < 4 else {
            return nil
        }

        let whiteScore = min(
            contrastRatio(backgroundHex, "#FFFFFF"),
            contrastRatio(foregroundHex, "#FFFFFF")
        )
        let blackScore = min(
            contrastRatio(backgroundHex, "#000000"),
            contrastRatio(foregroundHex, "#000000")
        )

        return Color(hex: whiteScore >= blackScore ? "#FFFFFF" : "#000000")
    }

    private func contrastRatio(_ left: String, _ right: String) -> Double {
        guard let leftRGB = parseHexColor(left), let rightRGB = parseHexColor(right) else {
            return Double.infinity
        }

        let leftLuminance = relativeLuminance(leftRGB)
        let rightLuminance = relativeLuminance(rightRGB)
        let lighter = max(leftLuminance, rightLuminance)
        let darker = min(leftLuminance, rightLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func parseHexColor(_ value: String) -> (red: Double, green: Double, blue: Double)? {
        guard let normalized = normalizeHex(value) else {
            return nil
        }

        let raw = String(normalized.dropFirst())
        guard let hex = UInt64(raw, radix: 16) else {
            return nil
        }

        return (
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    private func areColorsSimilar(_ left: String, _ right: String) -> Bool {
        guard let leftRGB = parseHexColor(left), let rightRGB = parseHexColor(right) else {
            return false
        }

        let redDelta = leftRGB.red - rightRGB.red
        let greenDelta = leftRGB.green - rightRGB.green
        let blueDelta = leftRGB.blue - rightRGB.blue
        let distance = sqrt((redDelta * redDelta) + (greenDelta * greenDelta) + (blueDelta * blueDelta))
        return distance <= 0.28
    }

    private func normalizeHex(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.range(of: "^#[0-9A-F]{6}$", options: .regularExpression) != nil else {
            return nil
        }
        return normalized
    }

    private func relativeLuminance(_ rgb: (red: Double, green: Double, blue: Double)) -> Double {
        func convert(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }

        let red = convert(rgb.red)
        let green = convert(rgb.green)
        let blue = convert(rgb.blue)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

private struct TeamColorEntry: Sendable {
    let name: String
    let aliases: [String]
    let primary: String
    let secondary: String
    let scheme: String?
    let isFallback: Bool
}

final class TeamIdentityStore: @unchecked Sendable {
    nonisolated static let shared = TeamIdentityStore()

    private let lock = NSLock()
    private nonisolated(unsafe) var canonicalNameByKey: [String: String] = [:]
    private nonisolated(unsafe) var namesByCanonicalKey: [String: [String]] = [:]
    private nonisolated(unsafe) var exactToCanonicalKey: [String: String] = [:]

    private init() {}

    nonisolated func update(from catalog: TeamColorsCatalogResponse) {
        var nextCanonicalNameByKey: [String: String] = [:]
        var nextNamesByCanonicalKey: [String: [String]] = [:]
        var nextExactToCanonicalKey: [String: String] = [:]

        for entry in catalog.teams.map({ ($0.name, $0.aliases) }) +
            catalog.identityGroups.map({ ($0.name, $0.aliases) }) {
            let canonicalKey = Self.normalizedKey(entry.0)
            guard !canonicalKey.isEmpty else { continue }

            if nextCanonicalNameByKey[canonicalKey] == nil {
                nextCanonicalNameByKey[canonicalKey] = entry.0
            }

            var names = nextNamesByCanonicalKey[canonicalKey] ?? []
            for candidate in [entry.0] + entry.1 {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if !names.contains(trimmed) {
                    names.append(trimmed)
                }
                let key = Self.normalizedKey(trimmed)
                if !key.isEmpty, nextExactToCanonicalKey[key] == nil {
                    nextExactToCanonicalKey[key] = canonicalKey
                }
            }
            nextNamesByCanonicalKey[canonicalKey] = names
        }

        lock.lock()
        canonicalNameByKey = nextCanonicalNameByKey
        namesByCanonicalKey = nextNamesByCanonicalKey
        exactToCanonicalKey = nextExactToCanonicalKey
        lock.unlock()
    }

    nonisolated func canonicalName(for rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let key = Self.normalizedKey(trimmed)
        lock.lock()
        let canonicalKey = exactToCanonicalKey[key]
        let canonicalName = canonicalKey.flatMap { canonicalNameByKey[$0] }
        lock.unlock()
        return canonicalName ?? trimmed
    }

    nonisolated func names(for rawValue: String) -> [String] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let key = Self.normalizedKey(trimmed)

        lock.lock()
        let canonicalKey = exactToCanonicalKey[key]
        let canonicalName = canonicalKey.flatMap { canonicalNameByKey[$0] }
        let knownNames = canonicalKey.flatMap { namesByCanonicalKey[$0] } ?? []
        lock.unlock()

        return Array(Set(([canonicalName, trimmed] + knownNames).compactMap { $0 }))
    }

    nonisolated func normalizedKeys(for rawValue: String) -> Set<String> {
        Set(names(for: rawValue).map(Self.normalizedKey).filter { !$0.isEmpty })
    }

    nonisolated func matches(_ lhs: String, _ rhs: String) -> Bool {
        let leftKeys = normalizedKeys(for: lhs)
        let rightKeys = normalizedKeys(for: rhs)
        return !leftKeys.isDisjoint(with: rightKeys)
    }

    nonisolated static func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0) }
            .joined()
    }
}

private extension Color {
    init?(hex: String) {
        let raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard raw.count == 6, let value = UInt64(raw, radix: 16) else {
            return nil
        }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
