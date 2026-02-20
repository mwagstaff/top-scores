import Foundation

enum ChannelSelection {
    static let specialOptions = ["Amazon (all)", "BBC (all)", "ITV (all)", "Sky (all)", "TNT (all)"]

    private static let specialKeywords: [String: String] = [
        "Amazon (all)": "amazon",
        "BBC (all)": "bbc",
        "ITV (all)": "itv",
        "Sky (all)": "sky",
        "TNT (all)": "tnt"
    ]

    static func selectableChannels(from matches: [Match]) -> [String] {
        selectableChannels(from: matches.flatMap(\.tvChannels))
    }

    static func selectableChannels(from channels: [String]) -> [String] {
        var options = Set(specialOptions)
        for channel in normalizedSelectedOptions(channels) {
            options.insert(channel)
        }
        return sortedChannels(Array(options))
    }

    static func filterChannels(_ channels: [String], selectedOptions: [String]) -> [String] {
        let normalizedSelections = normalizedSelectedOptions(selectedOptions)
        guard !normalizedSelections.isEmpty else { return channels }

        return channels.filter { channel in
            normalizedSelections.contains { selection in
                channelMatchesSelection(channelName: channel, selection: selection)
            }
        }
    }

    static func sortedChannels(_ channels: [String]) -> [String] {
        channels.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    static func normalizedSelectedOptions(_ selections: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for selection in selections {
            let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let canonical = canonicalSpecialOption(for: trimmed) ?? trimmed
            let dedupeKey = normalized(canonical)
            if !seen.contains(dedupeKey) {
                seen.insert(dedupeKey)
                output.append(canonical)
            }
        }

        return sortedChannels(output)
    }

    static func apiQueryValues(from selections: [String]) -> [String] {
        normalizedSelectedOptions(selections).map { selection in
            if let special = canonicalSpecialOption(for: selection) {
                return baseName(for: special)
            }
            return selection
        }
    }

    private static func channelMatchesSelection(channelName: String, selection: String) -> Bool {
        if let special = canonicalSpecialOption(for: selection),
           let keyword = specialKeywords[special] {
            let tokens = normalizedTokens(channelName)
            return tokens.contains { token in
                token.hasPrefix(keyword)
            }
        }

        return normalized(channelName) == normalized(selection)
    }

    private static func normalizedTokens(_ value: String) -> [String] {
        normalized(value)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalSpecialOption(for selection: String) -> String? {
        let normalizedSelection = normalized(selection)
        return specialOptions.first { option in
            let canonical = normalized(option)
            let base = normalized(baseName(for: option))
            return normalizedSelection == canonical || normalizedSelection == base
        }
    }

    private static func baseName(for option: String) -> String {
        option.replacingOccurrences(of: "(all)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
