import Foundation

enum MatchStadiumLightContext: String, Sendable {
    case day
    case night
}

struct MatchStadiumArtworkResolver: Sendable {
    static let shared = MatchStadiumArtworkResolver()

    private let genericFamilyCount = 3

    // Add venue-specific asset stems here as licensed stadium photography is
    // introduced, for example "273": "Venue273Stadium". The resolver will
    // continue to append Day/Night and fall back to the deterministic pool.
    private let venueAssetFamilies: [String: String] = [:]

    func assetName(for match: Match) -> String {
        let light = lightContext(for: match)

        if let venueID = match.venueID,
           let venueFamily = venueAssetFamilies[venueID] {
            return "\(venueFamily)\(light.assetSuffix)"
        }

        let family = familyIndex(homeTeamID: match.homeTeamId, homeTeamName: match.homeTeam)
        return String(format: "MatchStadium%02d%@", family, light.assetSuffix)
    }

    func lightContext(for match: Match) -> MatchStadiumLightContext {
        if let value = match.lightContext?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let context = MatchStadiumLightContext(rawValue: value) {
            return context
        }

        let hour = Int(match.time.split(separator: ":").first ?? "")
        return (hour ?? 20) >= 6 && (hour ?? 20) < 18 ? .day : .night
    }

    func familyIndex(homeTeamID: String?, homeTeamName: String) -> Int {
        // The canonical team name is stable across BSD/TSDB source switches,
        // whereas provider-specific numeric IDs are not.
        let identity = homeTeamName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nonEmpty
            ?? homeTeamID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "unknown-home-team"
        return Int(stableHash(identity) % UInt32(genericFamilyCount)) + 1
    }

    private func stableHash(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(2_166_136_261)) { hash, byte in
            (hash ^ UInt32(byte)) &* 16_777_619
        }
    }
}

private extension MatchStadiumLightContext {
    var assetSuffix: String {
        switch self {
        case .day: "Day"
        case .night: "Night"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
