import Foundation

enum CompetitionWeightConfig {
    private static let fileName = "competition_weights"
    private static let fileExtension = "json"
    private static let weightsByName: [String: Double] = loadWeights()
    private static let fifaWorldCupQualifyingPattern = try! NSRegularExpression(
        pattern: #"^fifa world cup(?:\s+2026)? qualifying\b"#,
        options: [.caseInsensitive]
    )

    static func weight(for competitionName: String) -> Double? {
        let normalized = normalizeCompetitionName(competitionName)
        guard !normalized.isEmpty else { return nil }
        return weightsByName[normalized]
    }

    static func normalizeCompetitionName(_ competitionName: String) -> String {
        competitionName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func canonicalFilterName(_ competitionName: String) -> String {
        let normalized = normalizeCompetitionName(competitionName)
        guard !normalized.isEmpty else { return "" }

        let fullRange = NSRange(location: 0, length: normalized.utf16.count)
        if fifaWorldCupQualifyingPattern.firstMatch(in: normalized, options: [], range: fullRange) != nil {
            return normalizeCompetitionName("FIFA World Cup 2026")
        }

        return normalized
    }

    private static func loadWeights() -> [String: Double] {
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
