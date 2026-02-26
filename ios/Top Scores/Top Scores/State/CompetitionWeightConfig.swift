import Foundation

enum CompetitionWeightConfig {
    private static let fileName = "competition_weights"
    private static let fileExtension = "json"
    private static let weightsByName: [String: Double] = loadWeights()

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
