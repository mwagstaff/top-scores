import Foundation

enum FantasyManagerIDParser {
    private static let urlPattern = #"(?i)(?:https?://)?(?:www\.)?fantasy\.premierleague\.com/entry/(\d+)(?:[/?#]|$)"#
    private static let digitsOnlyPattern = #"^\d{3,}$"#

    static func parse(from rawText: String) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let match = trimmed.firstMatch(of: urlPattern),
           let id = match.capturedGroups.first {
            return id
        }

        if trimmed.range(of: digitsOnlyPattern, options: .regularExpression) != nil {
            return trimmed
        }

        return nil
    }
}

private extension String {
    func firstMatch(of pattern: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: self) else {
            return nil
        }

        return RegexMatch(capturedGroups: [String(self[captureRange])])
    }
}

private struct RegexMatch {
    let capturedGroups: [String]
}
