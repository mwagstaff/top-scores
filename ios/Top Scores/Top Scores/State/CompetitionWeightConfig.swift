import Foundation

enum CompetitionWeightConfig {
    private nonisolated static let fileName = "competition_weights"
    private nonisolated static let fileExtension = "json"
    private nonisolated static let weightsByName: [String: Double] = loadWeights()
    private nonisolated static let publicDisplayAllowlist: Set<String> = [
        "Bundesliga",
        "Championship",
        "Copa del Rey",
        "English League Cup",
        "FA Cup",
        "FIFA World Cup 2026",
        "International Friendly",
        "La Liga",
        "League One",
        "League Two",
        "Premier League",
        "Scottish Premiership",
        "Scottish Championship",
        "Scottish League One",
        "Scottish League Two",
        "Serie A",
        "UEFA Champions League",
        "UEFA Conference League",
        "UEFA Europa League",
        "UEFA Nations League",
        "UEFA Super Cup"
    ].reduce(into: Set<String>()) { result, name in
        result.insert(normalizeCompetitionName(name))
    }
    private nonisolated static let fifaWorldCupQualifyingPattern = try! NSRegularExpression(
        pattern: #"^fifa world cup(?:\s+2026)? qualifying\b"#,
        options: [.caseInsensitive]
    )

    nonisolated static func weight(for competitionName: String) -> Double? {
        let normalized = normalizeCompetitionName(competitionName)
        guard !normalized.isEmpty else { return nil }
        return weightsByName[normalized]
    }

    nonisolated static func normalizeCompetitionName(_ competitionName: String) -> String {
        competitionName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    nonisolated static func canonicalFilterName(_ competitionName: String) -> String {
        let normalized = normalizeCompetitionName(competitionName)
        guard !normalized.isEmpty else { return "" }

        let fullRange = NSRange(location: 0, length: normalized.utf16.count)
        if fifaWorldCupQualifyingPattern.firstMatch(in: normalized, options: [], range: fullRange) != nil {
            return normalizeCompetitionName("FIFA World Cup 2026")
        }

        return normalized
    }

    nonisolated static func isAllowedCompetitionForPublicDisplay(_ competitionName: String) -> Bool {
        let normalized = canonicalFilterName(competitionName)
        guard !normalized.isEmpty else { return true }
        guard !publicDisplayAllowlist.isEmpty else { return true }
        return publicDisplayAllowlist.contains(normalized)
    }

    private nonisolated static func loadWeights() -> [String: Double] {
        guard let fileURL = Bundle.main.url(forResource: fileName, withExtension: fileExtension) else {
            NSLog("Competition weight config not found in app bundle (%@.%@).", fileName, fileExtension)
            return [:]
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let json = try JSONSerialization.jsonObject(with: data, options: [])
            guard let rawWeights = json as? [String: Any] else {
                NSLog("Competition weight config has invalid format; expected object map.")
                return [:]
            }

            var normalizedWeights: [String: Double] = [:]
            for (competitionName, rawValue) in rawWeights {
                guard let number = rawValue as? NSNumber else { continue }
                let normalized = normalizeCompetitionName(competitionName)
                guard !normalized.isEmpty else { continue }
                normalizedWeights[normalized] = number.doubleValue
            }
            return normalizedWeights
        } catch {
            NSLog("Failed to load competition weights config: %@", String(describing: error))
            return [:]
        }
    }
}
