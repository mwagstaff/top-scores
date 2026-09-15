import Foundation

private struct WatchTeamNameCatalog: Decodable {
    let teams: [WatchTeamNameRecord]
    let identityGroups: [WatchTeamNameRecord]

    private enum CodingKeys: String, CodingKey {
        case teams
        case identityGroups = "identity_groups"
    }
}

private struct WatchTeamNameRecord: Decodable {
    let name: String
    let aliases: [String]
}

final class WatchTeamNameResolver {
    static let shared = WatchTeamNameResolver()

    private let candidatesByNameKey: [String: [String]]

    init(bundles: [Bundle] = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks) {
        guard let catalog = Self.loadCatalog(from: bundles) else {
            candidatesByNameKey = [:]
            return
        }

        var namesByCanonicalKey: [String: [String]] = [:]
        var canonicalKeyByNameKey: [String: String] = [:]

        for record in catalog.teams + catalog.identityGroups {
            let canonicalKey = Self.normalizedKey(record.name)
            guard !canonicalKey.isEmpty else { continue }

            var names = namesByCanonicalKey[canonicalKey] ?? []
            for candidate in [record.name] + record.aliases {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if !names.contains(trimmed) {
                    names.append(trimmed)
                }

                let nameKey = Self.normalizedKey(trimmed)
                if !nameKey.isEmpty, canonicalKeyByNameKey[nameKey] == nil {
                    canonicalKeyByNameKey[nameKey] = canonicalKey
                }
            }
            namesByCanonicalKey[canonicalKey] = names
        }

        candidatesByNameKey = canonicalKeyByNameKey.reduce(into: [:]) { output, entry in
            output[entry.key] = namesByCanonicalKey[entry.value] ?? []
        }
    }

    func displayName(for fullName: String, providerShortName: String?) -> String {
        if let providerName = Self.displayShortName(providerShortName, for: fullName) {
            return providerName
        }

        let candidates = candidatesByNameKey[Self.normalizedKey(fullName)] ?? []
        return Self.preferredShortName(fullName: fullName, candidates: candidates) ?? fullName
    }

    private static func loadCatalog(from bundles: [Bundle]) -> WatchTeamNameCatalog? {
        var seenURLs = Set<URL>()
        for bundle in bundles where seenURLs.insert(bundle.bundleURL).inserted {
            guard let url = bundle.url(forResource: "team_colors", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let catalog = try? JSONDecoder().decode(WatchTeamNameCatalog.self, from: data) else {
                continue
            }
            return catalog
        }
        return nil
    }

    private static func displayShortName(_ candidate: String?, for fullName: String) -> String? {
        let trimmedFullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmedCandidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedFullName.isEmpty,
              !trimmedCandidate.isEmpty,
              normalizedKey(trimmedCandidate) != normalizedKey(trimmedFullName) else {
            return nil
        }

        let fullNameWords = trimmedFullName.split { !$0.isLetter && !$0.isNumber }
        if fullNameWords.contains(where: { String($0).caseInsensitiveCompare("United") == .orderedSame }) {
            var candidateWords = trimmedCandidate.split(separator: " ").map(String.init)
            if candidateWords.last?.caseInsensitiveCompare("U") == .orderedSame {
                candidateWords[candidateWords.count - 1] = "Utd"
                trimmedCandidate = candidateWords.joined(separator: " ")
            }
        }

        let characters = Array(trimmedCandidate)
        let isUppercaseCode = (2...4).contains(characters.count) &&
            characters.allSatisfy(\.isLetter) &&
            trimmedCandidate == trimmedCandidate.uppercased()
        if isUppercaseCode {
            let firstFullNameWord = fullNameWords.first.map(String.init) ?? ""
            let isLeadingName = firstFullNameWord.caseInsensitiveCompare(trimmedCandidate) == .orderedSame
            let isClubDesignator = ["AFC", "FC", "CF", "SC"].contains(trimmedCandidate)
            guard isLeadingName, !isClubDesignator else { return nil }
        }

        return trimmedCandidate
    }

    private static func preferredShortName(fullName: String, candidates: [String]) -> String? {
        let trimmedFullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFullName.isEmpty else { return nil }
        let fullNameKey = normalizedKey(trimmedFullName)
        let shorterNames = candidates
            .compactMap { displayShortName($0, for: trimmedFullName) }
            .filter {
                !$0.isEmpty &&
                    $0.count < trimmedFullName.count &&
                    normalizedKey($0) != fullNameKey
            }

        guard !shorterNames.isEmpty else { return nil }
        let readableNames = shorterNames.filter { candidate in
            candidate.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) }
        }
        return (readableNames.isEmpty ? shorterNames : readableNames).min { left, right in
            if left.count != right.count {
                return left.count < right.count
            }
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .joined()
    }
}
