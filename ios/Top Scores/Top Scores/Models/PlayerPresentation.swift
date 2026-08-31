import Foundation

enum PlayerNationalityPresentation {
    static func flag(for nationality: String?) -> String? {
        guard let nationality else { return nil }
        let key = normalized(nationality)
        if let special = subdivisionFlags[key] { return special }
        guard let regionCode = regionCodesByName[key], regionCode.count == 2 else { return nil }
        return regionCode.uppercased().unicodeScalars.compactMap { scalar in
            UnicodeScalar(127_397 + scalar.value).map(String.init)
        }.joined()
    }

    private static let subdivisionFlags: [String: String] = [
        "england": subdivisionFlag("gbeng"),
        "scotland": subdivisionFlag("gbsct"),
        "wales": subdivisionFlag("gbwls"),
        "northern ireland": "🇬🇧",
    ]

    private static let regionCodesByName: [String: String] = {
        let locale = Locale(identifier: "en_GB")
        return Locale.Region.isoRegions.reduce(into: [:]) { result, region in
            guard let name = locale.localizedString(forRegionCode: region.identifier) else { return }
            result[normalized(name)] = region.identifier
        }
    }()

    private static func subdivisionFlag(_ code: String) -> String {
        let scalars = [UnicodeScalar(0x1F3F4)!] + code.unicodeScalars.compactMap { scalar in
            UnicodeScalar(0xE0000 + scalar.value)
        } + [UnicodeScalar(0xE007F)!]
        return String(String.UnicodeScalarView(scalars))
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PlayerValuePresentation {
    static func compact(marketValueEUR: Double?, marketValueGBP: Double?) -> String? {
        if let marketValueGBP, marketValueGBP >= 0 {
            return compact(marketValueGBP, symbol: "£")
        }
        if let marketValueEUR, marketValueEUR >= 0 {
            return compact(marketValueEUR, symbol: "€")
        }
        return nil
    }

    static func compactCount(_ value: Int?) -> String? {
        guard let value, value >= 0 else { return nil }
        return compact(Double(value), symbol: "")
    }

    private static func compact(_ value: Double, symbol: String) -> String {
        let divisor: Double
        let suffix: String
        switch value {
        case 1_000_000_000...:
            divisor = 1_000_000_000
            suffix = "bn"
        case 1_000_000...:
            divisor = 1_000_000
            suffix = "m"
        case 1_000...:
            divisor = 1_000
            suffix = "k"
        default:
            return "\(symbol)\(Int(value.rounded()).formatted())"
        }

        let scaled = value / divisor
        let formatted = scaled >= 100
            ? String(format: "%.0f", scaled)
            : String(format: "%.1f", scaled).replacingOccurrences(of: ".0", with: "")
        return "\(symbol)\(formatted)\(suffix)"
    }
}

enum PlayerDatePresentation {
    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return inputFormatter.date(from: value)
    }

    static func displayDate(_ value: String?) -> String? {
        date(from: value).map(displayFormatter.string(from:))
    }

    static func age(from value: String?, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let birthDate = date(from: value) else { return nil }
        return calendar.dateComponents([.year], from: birthDate, to: now).year
    }

    private static let inputFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
}

enum PlayerPositionPresentation {
    static func display(_ value: String?) -> String {
        guard let value else { return "Unknown" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = [
            "G": "Goalkeeper", "GK": "Goalkeeper",
            "D": "Defender", "DF": "Defender", "CB": "Centre-back",
            "LB": "Left-back", "RB": "Right-back",
            "M": "Midfielder", "MF": "Midfielder", "MID": "Midfielder",
            "DM": "Defensive midfielder", "CM": "Central midfielder",
            "AM": "Attacking midfielder", "LM": "Left midfielder", "RM": "Right midfielder",
            "F": "Forward", "FW": "Forward", "A": "Forward",
            "LW": "Left winger", "RW": "Right winger", "ST": "Striker", "CF": "Centre-forward",
        ]
        return names[trimmed.uppercased()] ?? trimmed
    }
}

enum TeamSquadSortOrder: String, CaseIterable, Identifiable, Sendable {
    case value
    case firstName
    case lastName
    case squadNumber
    case availability
    case fplTotalPoints
    case fplSelectedByCount
    case fplSelectedByPercent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .value: "Value"
        case .firstName: "First name"
        case .lastName: "Last name"
        case .squadNumber: "Squad no."
        case .availability: "Availability"
        case .fplTotalPoints: "FPL total points"
        case .fplSelectedByCount: "FPL selected by #"
        case .fplSelectedByPercent: "FPL selected by %"
        }
    }

    var systemImage: String {
        switch self {
        case .value: "sterlingsign"
        case .firstName: "person.text.rectangle"
        case .lastName: "textformat.abc"
        case .squadNumber: "number"
        case .availability: "cross.case"
        case .fplTotalPoints: "star.fill"
        case .fplSelectedByCount: "person.2.fill"
        case .fplSelectedByPercent: "percent"
        }
    }

    static func availableCases(for players: [PlayerDetails]) -> [TeamSquadSortOrder] {
        allCases.filter { order in
            switch order {
            case .fplTotalPoints:
                players.contains { $0.fplTotalPoints != nil }
            case .fplSelectedByCount:
                players.contains { $0.fplSelectedByCount != nil }
            case .fplSelectedByPercent:
                players.contains { $0.fplSelectedByPercent != nil }
            default:
                true
            }
        }
    }

    func sorted(_ players: [PlayerDetails]) -> [PlayerDetails] {
        players.sorted { lhs, rhs in
            switch self {
            case .value:
                let left = lhs.marketValueEUR ?? -.infinity
                let right = rhs.marketValueEUR ?? -.infinity
                return left == right ? fullNamePrecedes(lhs, rhs) : left > right
            case .firstName:
                return namePrecedes(lhs, rhs, keyPath: \.firstNameSortKey)
            case .lastName:
                return namePrecedes(lhs, rhs, keyPath: \.lastNameSortKey)
            case .squadNumber:
                let left = lhs.jerseyNumber ?? Int.max
                let right = rhs.jerseyNumber ?? Int.max
                return left == right ? fullNamePrecedes(lhs, rhs) : left < right
            case .availability:
                let left = availabilityPriority(lhs.availability)
                let right = availabilityPriority(rhs.availability)
                return left == right ? fullNamePrecedes(lhs, rhs) : left < right
            case .fplTotalPoints:
                return descending(lhs.fplTotalPoints, rhs.fplTotalPoints, lhs: lhs, rhs: rhs)
            case .fplSelectedByCount:
                return descending(lhs.fplSelectedByCount, rhs.fplSelectedByCount, lhs: lhs, rhs: rhs)
            case .fplSelectedByPercent:
                return descending(lhs.fplSelectedByPercent, rhs.fplSelectedByPercent, lhs: lhs, rhs: rhs)
            }
        }
    }

    private func namePrecedes(
        _ lhs: PlayerDetails,
        _ rhs: PlayerDetails,
        keyPath: KeyPath<PlayerDetails, String>
    ) -> Bool {
        let comparison = lhs[keyPath: keyPath].localizedStandardCompare(rhs[keyPath: keyPath])
        return comparison == .orderedSame ? fullNamePrecedes(lhs, rhs) : comparison == .orderedAscending
    }

    private func fullNamePrecedes(_ lhs: PlayerDetails, _ rhs: PlayerDetails) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func descending<T: Comparable>(
        _ left: T?,
        _ right: T?,
        lhs: PlayerDetails,
        rhs: PlayerDetails
    ) -> Bool {
        switch (left, right) {
        case let (left?, right?):
            return left == right ? fullNamePrecedes(lhs, rhs) : left > right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return fullNamePrecedes(lhs, rhs)
        }
    }

    private func availabilityPriority(_ value: String?) -> Int {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "injured": 0
        case "suspended": 1
        case "doubtful": 2
        case "available": 4
        default: 3
        }
    }
}

extension PlayerDetails {
    var displayDateOfBirth: String? { dateOfBirth ?? born }
    var displayPosition: String { PlayerPositionPresentation.display(specificPosition ?? position) }
    var isUnavailable: Bool {
        guard let availability else { return false }
        return availability.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "available"
    }

    var availabilityDisplayName: String {
        guard let availability, !availability.isEmpty else { return "Unknown" }
        return availability.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var firstNameSortKey: String {
        let fplName = fplFirstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fplName.isEmpty { return fplName }
        return name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name
    }

    var lastNameSortKey: String {
        let fplName = fplLastName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fplName.isEmpty { return fplName }
        return name.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? name
    }
}
