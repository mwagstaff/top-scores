import Foundation

enum CompetitionWeightConfig {
    private nonisolated static let refreshInterval: TimeInterval = 6 * 60 * 60
    private nonisolated static let bootstrapWeightsByName: [String: Double] = [
        "premier league": 100,
        "uefa champions league": 90,
        "fifa world cup 2026": 85,
        "uefa europa league": 80,
        "uefa conference league": 70,
        "uefa nations league": 69,
        "uefa super cup": 68,
        "fa cup": 65,
        "english league cup": 60,
        "copa del rey": 58,
        "la liga": 50,
        "bundesliga": 48,
        "serie a": 48,
        "championship": 40,
        "scottish premiership": 30,
        "scottish championship": 25,
        "scottish league one": 20,
        "scottish league two": 15,
        "league one": 14,
        "league two": 12,
        "international friendly": 10,
    ]
    private nonisolated static let stagePatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"\s*[-:–]\s*Round\s+\w+$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+\w+\s+Round$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Round\s+\w+$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Round\s+\d+$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Round\s+of\s+\d+$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Last\s+\d+$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Group\s+Stage$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Group\s+[A-Z]$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Quarter[- ]Finals?$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Semi[- ]Finals?$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Finals?$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Third[- ]Place\s+Play-?Off$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Play-?Offs?$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Qualifying$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Qualification$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Preliminary\s+Round$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+First\s+Leg$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Second\s+Leg$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+1st\s+Leg$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+2nd\s+Leg$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"\s+Leg\s+\d+$"#, options: [.caseInsensitive]),
    ]
    private nonisolated static let trailingStageSeparatorPattern = try! NSRegularExpression(
        pattern: #"[-:–]\s*$"#,
        options: [.caseInsensitive]
    )
    private nonisolated static let aliases: [String: String] = [
        "efl cup": "english league cup",
        "carabao cup": "english league cup",
        "fifa world cup": "fifa world cup 2026",
        "uefa europa conference league": "uefa conference league",
        "spanish la liga": "la liga",
        "italian serie a": "serie a",
        "german bundesliga": "bundesliga",
    ]
    private nonisolated static let displayAliases: [String: String] = [
        "english league cup": "English League Cup",
        "uefa conference league": "UEFA Conference League",
    ]
    private nonisolated static let cacheLock = NSLock()
    private nonisolated(unsafe) static var normalizedNameCache: [String: String] = [:]
    private nonisolated(unsafe) static var canonicalNameCache: [String: String] = [:]
    private nonisolated(unsafe) static var displayBaseNameCache: [String: String] = [:]
    private nonisolated(unsafe) static var weightsByNameCache: [String: Double]?
    private nonisolated(unsafe) static var allowedCompetitionNamesCache: Set<String>?
    private nonisolated(unsafe) static var updatedAtCache: String?
    private nonisolated(unsafe) static var fetchedAtCache: Date?

    nonisolated static func weight(for competitionName: String) -> Double? {
        let canonical = canonicalFilterName(competitionName)
        guard !canonical.isEmpty else { return nil }
        return cachedWeightsByName()[canonical]
    }

    nonisolated static func normalizeCompetitionName(_ competitionName: String) -> String {
        cacheLock.lock()
        if let cached = normalizedNameCache[competitionName] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let normalized = competitionName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        cacheLock.lock()
        normalizedNameCache[competitionName] = normalized
        cacheLock.unlock()
        return normalized
    }

    nonisolated static func canonicalFilterName(_ competitionName: String) -> String {
        cacheLock.lock()
        if let cached = canonicalNameCache[competitionName] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let normalized = normalizeCompetitionName(competitionName)
        guard !normalized.isEmpty else { return "" }
        let stripped = stripStageDescriptors(from: normalized)
        let canonical = stripped.isEmpty ? normalized : stripped
        let resolved = aliases[canonical] ?? canonical
        cacheLock.lock()
        canonicalNameCache[competitionName] = resolved
        cacheLock.unlock()
        return resolved
    }

    nonisolated static func isAllowedCompetitionForPublicDisplay(_ competitionName: String) -> Bool {
        let canonical = canonicalFilterName(competitionName)
        guard !canonical.isEmpty else { return true }
        let allowed = activeCompetitionNameSet()
        guard !allowed.isEmpty else { return true }
        return allowed.contains(canonical)
    }

    nonisolated static func availableCompetitionNames() -> [String] {
        activeWeightsByName()
            .keys
            .map(displayCompetitionName)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    nonisolated static func displayBaseCompetitionName(_ competitionName: String) -> String {
        cacheLock.lock()
        if let cached = displayBaseNameCache[competitionName] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let trimmed = competitionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let canonical = canonicalFilterName(trimmed)
        if let aliased = displayAliases[canonical] {
            cacheLock.lock()
            displayBaseNameCache[competitionName] = aliased
            cacheLock.unlock()
            return aliased
        }
        let stripped = stripStageDescriptorsPreservingCase(from: trimmed)
        let resolved = stripped.isEmpty ? trimmed : stripped
        cacheLock.lock()
        displayBaseNameCache[competitionName] = resolved
        cacheLock.unlock()
        return resolved
    }

    static func refreshIfNeeded(apiBaseURL: String, force: Bool = false) async -> Bool {
        guard force || shouldRefresh() else { return false }
        guard let url = URL(string: apiBaseURL) else { return false }

        do {
            let catalog = try await APIClient(baseURL: url).fetchCompetitionCatalog()
            return applyCatalog(catalog)
        } catch {
            NSLog("Competition catalog refresh failed: %@", String(describing: error))
            return false
        }
    }

    @discardableResult
    static func applyCatalog(_ catalog: CompetitionCatalogResponse, fetchedAt: Date = Date()) -> Bool {
        let normalizedWeights = normalizedWeights(from: catalog.competitions)
        guard !normalizedWeights.isEmpty else { return false }

        let currentWeights = cachedWeightsByName()
        let currentUpdatedAt = cachedUpdatedAt()
        let nextUpdatedAt = catalog.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines)
        persist(weightsByName: normalizedWeights, updatedAt: nextUpdatedAt, fetchedAt: fetchedAt)
        return currentWeights != normalizedWeights || currentUpdatedAt != nextUpdatedAt
    }

    private nonisolated static func shouldRefresh(now: Date = Date()) -> Bool {
        guard let fetchedAt = cachedFetchedAt() else { return true }
        return now.timeIntervalSince(fetchedAt) >= refreshInterval
    }

    private nonisolated static func normalizedWeights(
        from competitions: [CompetitionCatalogEntry]
    ) -> [String: Double] {
        competitions.reduce(into: [String: Double]()) { result, competition in
            let canonical = canonicalFilterName(competition.name)
            guard !canonical.isEmpty else { return }
            result[canonical] = competition.weight
        }
    }

    private nonisolated static func cachedWeightsByName() -> [String: Double] {
        cacheLock.lock()
        if let cached = weightsByNameCache {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let defaultsSequence = [
            UserDefaults.standard,
            UserDefaults(suiteName: AppGroupConfig.identifier),
        ]

        for defaults in defaultsSequence {
            guard let defaults,
                  let data = defaults.data(forKey: AppGroupConfig.competitionCatalogWeightsDataKey),
                  let decoded = try? JSONDecoder().decode([String: Double].self, from: data),
                  !decoded.isEmpty else {
                continue
            }
            cacheLock.lock()
            weightsByNameCache = decoded
            allowedCompetitionNamesCache = Set(decoded.keys)
            cacheLock.unlock()
            return decoded
        }

        return [:]
    }

    private nonisolated static func activeWeightsByName() -> [String: Double] {
        let cached = cachedWeightsByName()
        return cached.isEmpty ? bootstrapWeightsByName : cached
    }

    private nonisolated static func activeCompetitionNameSet() -> Set<String> {
        cacheLock.lock()
        if let cached = allowedCompetitionNamesCache {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let resolved = Set(activeWeightsByName().keys)
        cacheLock.lock()
        allowedCompetitionNamesCache = resolved
        cacheLock.unlock()
        return resolved
    }

    private nonisolated static func cachedUpdatedAt() -> String? {
        cacheLock.lock()
        if let cached = updatedAtCache {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let defaultsSequence = [
            UserDefaults.standard,
            UserDefaults(suiteName: AppGroupConfig.identifier),
        ]
        for defaults in defaultsSequence {
            guard let defaults else { continue }
            let value = defaults.string(forKey: AppGroupConfig.competitionCatalogUpdatedAtKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                cacheLock.lock()
                updatedAtCache = value
                cacheLock.unlock()
                return value
            }
        }
        return nil
    }

    private nonisolated static func cachedFetchedAt() -> Date? {
        cacheLock.lock()
        if let cached = fetchedAtCache {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let defaultsSequence = [
            UserDefaults.standard,
            UserDefaults(suiteName: AppGroupConfig.identifier),
        ]
        for defaults in defaultsSequence {
            guard let defaults else { continue }
            let value = defaults.double(forKey: AppGroupConfig.competitionCatalogFetchedAtKey)
            guard value > 0 else { continue }
            let resolved = Date(timeIntervalSince1970: value)
            cacheLock.lock()
            fetchedAtCache = resolved
            cacheLock.unlock()
            return resolved
        }
        return nil
    }

    private static func persist(weightsByName: [String: Double], updatedAt: String?, fetchedAt: Date) {
        guard let data = try? JSONEncoder().encode(weightsByName) else { return }
        let defaultsSequence = [
            UserDefaults.standard,
            UserDefaults(suiteName: AppGroupConfig.identifier),
        ]

        defaultsSequence.forEach { defaults in
            guard let defaults else { return }
            defaults.set(data, forKey: AppGroupConfig.competitionCatalogWeightsDataKey)
            if let updatedAt, !updatedAt.isEmpty {
                defaults.set(updatedAt, forKey: AppGroupConfig.competitionCatalogUpdatedAtKey)
            } else {
                defaults.removeObject(forKey: AppGroupConfig.competitionCatalogUpdatedAtKey)
            }
            defaults.set(fetchedAt.timeIntervalSince1970, forKey: AppGroupConfig.competitionCatalogFetchedAtKey)
        }

        cacheLock.lock()
        weightsByNameCache = weightsByName
        allowedCompetitionNamesCache = Set(weightsByName.keys)
        updatedAtCache = updatedAt?.isEmpty == false ? updatedAt : nil
        fetchedAtCache = fetchedAt
        cacheLock.unlock()
    }

    private nonisolated static func stripStageDescriptors(from competitionName: String) -> String {
        var normalized = competitionName
        var changed = true

        while changed {
            changed = false
            for pattern in stagePatterns {
                let range = NSRange(location: 0, length: normalized.utf16.count)
                guard pattern.firstMatch(in: normalized, options: [], range: range) != nil else {
                    continue
                }

                normalized = pattern
                    .stringByReplacingMatches(in: normalized, options: [], range: range, withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let separatorRange = NSRange(location: 0, length: normalized.utf16.count)
                normalized = trailingStageSeparatorPattern
                    .stringByReplacingMatches(in: normalized, options: [], range: separatorRange, withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }

        return normalized
    }

    private nonisolated static func stripStageDescriptorsPreservingCase(from competitionName: String) -> String {
        var normalized = competitionName
        var changed = true

        while changed {
            changed = false
            for pattern in stagePatterns {
                let range = NSRange(location: 0, length: normalized.utf16.count)
                guard pattern.firstMatch(in: normalized, options: [], range: range) != nil else {
                    continue
                }

                normalized = pattern
                    .stringByReplacingMatches(in: normalized, options: [], range: range, withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let separatorRange = NSRange(location: 0, length: normalized.utf16.count)
                normalized = trailingStageSeparatorPattern
                    .stringByReplacingMatches(in: normalized, options: [], range: separatorRange, withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }

        return normalized
    }

    private nonisolated static func displayCompetitionName(_ canonicalName: String) -> String {
        canonicalName
            .split(separator: " ")
            .map { token in
                switch token {
                case "uefa", "fifa", "fa":
                    return token.uppercased()
                default:
                    return token.prefix(1).uppercased() + token.dropFirst()
                }
            }
            .joined(separator: " ")
    }
}
