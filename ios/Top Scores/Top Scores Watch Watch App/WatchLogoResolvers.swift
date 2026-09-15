import Foundation
import OSLog
import UIKit

enum WatchCompetitionLogoResolver {
    private static let imageCache = NSCache<NSString, UIImage>()

    private static let assetNamesByCompetitionName: [String: String] = [
        "bundesliga": "CompetitionLogo5",
        "champions league": "CompetitionLogo7",
        "championship": "CompetitionLogo12",
        "copa del rey": "CompetitionLogo41",
        "coppa italia": "CompetitionLogo42",
        "coupe de france": "CompetitionLogo44",
        "dfb pokal": "CompetitionLogo43",
        "dfl supercup": "CompetitionLogoGermanSuperCup",
        "dutch eredivisie": "CompetitionLogo10",
        "efl cup": "CompetitionLogo40",
        "efl league one": "CompetitionLogo86",
        "efl league two": "CompetitionLogo87",
        "english league cup": "CompetitionLogo40",
        "english national league": "CompetitionLogo91",
        "english premier league": "FantasyPremierLeagueLion",
        "enterprise national league": "CompetitionLogo91",
        "fa cup": "CompetitionLogo39",
        "fifa world cup": "CompetitionLogo27",
        "fifa world cup 2026": "CompetitionLogo27",
        "german super cup": "CompetitionLogoGermanSuperCup",
        "international friendlies": "CompetitionLogoInternationalFriendly",
        "international friendly": "CompetitionLogoInternationalFriendly",
        "international friendly games": "CompetitionLogoInternationalFriendly",
        "la liga": "CompetitionLogo3",
        "league one": "CompetitionLogo86",
        "league two": "CompetitionLogo87",
        "ligue 1": "CompetitionLogo6",
        "national league": "CompetitionLogo91",
        "premier league": "FantasyPremierLeagueLion",
        "scottish championship": "CompetitionLogo13",
        "scottish league one": "CompetitionLogo13",
        "scottish league two": "CompetitionLogo13",
        "scottish premiership": "CompetitionLogo13",
        "serie a": "CompetitionLogo4",
        "spanish la liga": "CompetitionLogo3",
        "uefa champions league": "CompetitionLogo7",
        "uefa conference league": "CompetitionLogo83",
        "uefa europa conference league": "CompetitionLogo83",
        "uefa europa league": "CompetitionLogo8",
        "uefa nations league": "CompetitionLogo64",
        "uefa super cup": "CompetitionLogo90"
    ]

    static func image(for competitionName: String) -> UIImage? {
        guard let assetName = assetName(for: competitionName) else {
            return nil
        }
        if let cached = imageCache.object(forKey: assetName as NSString) {
            return cached
        }
        let start = DispatchTime.now()
        guard let image = UIImage(named: assetName) else { return nil }
        let rendered = compactCompetitionMark(from: image, assetName: assetName)
        let resolved = assetName == "CompetitionLogo7"
            ? rendered.withRenderingMode(.alwaysTemplate)
            : rendered
        imageCache.setObject(resolved, forKey: assetName as NSString)
        let duration = WatchPerformanceDiagnostics.milliseconds(since: start)
        if duration >= 16 {
            WatchPerformanceDiagnostics.logger.warning(
                "Slow competition logo load: asset=\(assetName, privacy: .public) duration=\(duration, privacy: .public) ms"
            )
        }
        return resolved
    }

    private static func compactCompetitionMark(from image: UIImage, assetName: String) -> UIImage {
        let normalizedCrop: CGRect
        switch assetName {
        case "CompetitionLogo13":
            // The source SPFL artwork is a wide sponsor lockup. Keep the lion mark
            // legible at the watch row's small square size.
            normalizedCrop = CGRect(x: 0, y: 0, width: 0.53, height: 1)
        case "CompetitionLogo91":
            // The National League source includes two lines of sponsor text. The
            // league's red emblem is the recognizable compact mark.
            normalizedCrop = CGRect(x: 0.07, y: 0.43, width: 0.35, height: 0.50)
        default:
            return image
        }

        guard let source = image.cgImage else { return image }
        let sourceWidth = CGFloat(source.width)
        let sourceHeight = CGFloat(source.height)
        let cropRect = CGRect(
            x: normalizedCrop.minX * sourceWidth,
            y: normalizedCrop.minY * sourceHeight,
            width: normalizedCrop.width * sourceWidth,
            height: normalizedCrop.height * sourceHeight
        ).integral
        guard let cropped = source.cropping(to: cropRect) else { return image }

        let outputSize = CGSize(width: 48, height: 48)
        UIGraphicsBeginImageContextWithOptions(outputSize, false, 2)
        defer { UIGraphicsEndImageContext() }
        UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: outputSize))
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }

    static func assetName(for competitionName: String) -> String? {
        assetNamesByCompetitionName[normalizedName(competitionName)]
    }

    private static func normalizedName(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}

private struct BSDTeamLogoAssetCatalog: Decodable {
    let teams: [String: BSDTeamLogoAssetEntry]
}

private struct BSDTeamLogoAssetEntry: Decodable {
    let assetName: String

    private enum CodingKeys: String, CodingKey {
        case assetName = "asset_name"
    }
}

final class WatchTeamLogoResolver {
    static let shared = WatchTeamLogoResolver()

    private let fallbackName = "_noTeamLogo"
    private let lock = NSLock()
    private let assetNameByTeamID: [String: String]
    private var cache: [String: UIImage] = [:]

    private init() {
        let bundles = Self.buildBundlesToSearch()
        assetNameByTeamID = Self.loadBSDAssetNames(from: bundles)
    }

    func image(for teamName: String, teamId: String?, alternateNames: [String] = []) -> UIImage? {
        let normalizedTeamID = teamId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let assetName = assetNameByTeamID[normalizedTeamID] {
            let cacheKey = "id:\(normalizedTeamID)"
            lock.lock()
            if let cached = cache[cacheKey] {
                lock.unlock()
                return cached
            }
            lock.unlock()

            let start = DispatchTime.now()
            if let image = imageFromAssets(named: assetName) {
                lock.lock()
                cache[cacheKey] = image
                lock.unlock()
                let duration = WatchPerformanceDiagnostics.milliseconds(since: start)
                if duration >= 16 {
                    WatchPerformanceDiagnostics.logger.warning(
                        "Slow team logo load: asset=\(assetName, privacy: .public) duration=\(duration, privacy: .public) ms"
                    )
                }
                return image
            }
        }
        return image(for: teamName, alternateNames: alternateNames)
    }

    func image(for teamName: String, alternateNames: [String] = []) -> UIImage? {
        let cacheKey = Self.cacheKey(for: teamName, alternateNames: alternateNames)

        lock.lock()
        if let cached = cache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        if let assetImage = resolveAssetImage(for: teamName, alternateNames: alternateNames) {
            lock.lock()
            cache[cacheKey] = assetImage
            lock.unlock()
            return assetImage
        }

        let fallback = resolveAssetFallbackImage()
        if let fallback {
            lock.lock()
            cache[cacheKey] = fallback
            lock.unlock()
            WatchPerformanceDiagnostics.logger.info(
                "Team logo fallback used: team=\(teamName, privacy: .public)"
            )
        }
        return fallback
    }

    private static func buildBundlesToSearch() -> [Bundle] {
        var output: [Bundle] = []
        var seenURLs = Set<URL>()

        for bundle in [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks {
            let url = bundle.bundleURL
            guard !seenURLs.contains(url) else { continue }
            seenURLs.insert(url)
            output.append(bundle)
        }

        return output
    }

    private func resolveAssetImage(for teamName: String, alternateNames: [String] = []) -> UIImage? {
        for candidate in assetNameCandidates(for: teamName, alternateNames: alternateNames) {
            if let image = imageFromAssets(named: candidate) {
                return image
            }
        }

        return nil
    }

    private func resolveAssetFallbackImage() -> UIImage? {
        for candidate in [fallbackName, "\(fallbackName) 1"] {
            if let image = imageFromAssets(named: candidate) {
                return image
            }
        }
        return nil
    }

    private func imageFromAssets(named name: String) -> UIImage? {
        UIImage(named: name)
    }

    private static func loadBSDAssetNames(from bundles: [Bundle]) -> [String: String] {
        for bundle in bundles {
            guard let url = bundle.url(forResource: "bsd_team_logo_assets", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let catalog = try? JSONDecoder().decode(BSDTeamLogoAssetCatalog.self, from: data) else {
                continue
            }
            return catalog.teams.mapValues(\.assetName)
        }
        return [:]
    }

    private func assetNameCandidates(for teamName: String, alternateNames: [String] = []) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            candidates.append(trimmed)
        }

        for rawCandidate in Self.lookupCandidates(for: teamName, alternateNames: alternateNames) {
            add(rawCandidate)
            add(rawCandidate.replacingOccurrences(of: "’", with: "'"))
            add(rawCandidate.replacingOccurrences(of: "'", with: ""))

            let lowered = rawCandidate.lowercased()
            if let alias = Self.aliasMap[lowered] {
                add(alias)
                add(Self.displayName(forAlias: alias))
            }

            for (fullName, alias) in Self.aliasMap where alias == lowered {
                add(fullName)
                add(Self.displayName(forAlias: fullName))
            }
        }

        return candidates
    }

    private static func displayName(forAlias alias: String) -> String {
        alias
            .split(separator: " ")
            .map { token in
                switch token {
                case "fc":
                    return "FC"
                case "ac":
                    return "AC"
                case "sv":
                    return "SV"
                case "vfl":
                    return "VfL"
                case "vfb":
                    return "VfB"
                case "paok":
                    return "PAOK"
                case "psv":
                    return "PSV"
                default:
                    return token.prefix(1).uppercased() + String(token.dropFirst())
                }
            }
            .joined(separator: " ")
    }

    private nonisolated static func normalizedKey(_ value: String) -> String {
        normalizedTokens(value).joined()
    }

    private nonisolated static func normalizedTokens(_ value: String) -> [String] {
        let lowered = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        return lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0) }
            .filter { token in
                !stopWords.contains(token)
            }
    }

    private static func lookupCandidates(for teamName: String, alternateNames: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()

        func add(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            output.append(trimmed)
        }

        add(teamName)
        alternateNames.forEach(add)
        return output
    }

    private static func cacheKey(for teamName: String, alternateNames: [String]) -> String {
        lookupCandidates(for: teamName, alternateNames: alternateNames)
            .map(normalizedKey)
            .joined(separator: "|")
    }

    private nonisolated static let stopWords: Set<String> = [
        "fc", "cf", "sc", "afc", "ac", "sv", "fk", "bk", "bc", "ks", "nk",
        "club", "de", "the", "and", "atletico", "athletic", "sporting"
    ]

    private static let aliasMap: [String: String] = [
        "manchester united": "man united",
        "manchester city": "man city",
        "tottenham hotspur": "tottenham",
        "wolverhampton wanderers": "wolves",
        "sheffield united": "sheff utd",
        "sheffield wednesday": "sheff wed",
        "nottingham forest": "nottm forest",
        "borussia dortmund": "dortmund",
        "borussia m'gladbach": "m'gladbach",
        "athletic club": "athletic",
        "real betis": "betis",
        "real sociedad": "real sociedad",
        "fc copenhagen": "copenhagen",
        "fc porto": "porto",
        "paok thessaloniki": "paok",
        "paok thessaloniki fc": "paok",
        "inter milan": "inter",
        "ac milan": "ac milan"
    ]
}

final class WatchTvLogoResolver {
    static let shared = WatchTvLogoResolver()

    private let fallbackName = "_noLogo"
    private var resolvedCache: [String: UIImage] = [:]

    private init() {}

    func image(for channelName: String) -> UIImage? {
        if let resolved = imageIfAvailable(for: channelName) {
            return resolved
        }

        let fallback = resolveAssetFallbackImage()
        if let fallback {
            resolvedCache[channelName] = fallback
        }
        return fallback
    }

    func imageIfAvailable(for channelName: String) -> UIImage? {
        if let cached = resolvedCache[channelName] {
            return cached
        }

        let start = DispatchTime.now()
        if let assetImage = resolveAssetImage(for: channelName) {
            resolvedCache[channelName] = assetImage
            let duration = WatchPerformanceDiagnostics.milliseconds(since: start)
            if duration >= 16 {
                WatchPerformanceDiagnostics.logger.warning(
                    "Slow TV logo load: channel=\(channelName, privacy: .public) duration=\(duration, privacy: .public) ms"
                )
            }
            return assetImage
        }

        return nil
    }

    func primaryResolvedLogo(for channels: [String]) -> (channel: String, image: UIImage)? {
        var seen = Set<String>()
        for rawChannel in channels {
            let channel = rawChannel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !channel.isEmpty else { continue }
            let key = Self.normalizedKey(channel)
            guard seen.insert(key).inserted else { continue }
            if let image = imageIfAvailable(for: channel) {
                return (channel, image)
            }
        }
        return nil
    }

    func images(for channels: [String]) -> [UIImage] {
        var output: [UIImage] = []
        var seenChannels = Set<String>()

        for channel in channels {
            let dedupeKey = Self.normalizedKey(channel)
            guard !seenChannels.contains(dedupeKey) else { continue }
            guard let image = imageIfAvailable(for: channel) else { continue }
            seenChannels.insert(dedupeKey)
            output.append(image)
        }

        return output
    }

    private func resolveAssetImage(for channelName: String) -> UIImage? {
        for candidate in assetNameCandidates(for: channelName) {
            if let image = UIImage(named: candidate) {
                return image
            }
        }
        return nil
    }

    private func resolveAssetFallbackImage() -> UIImage? {
        for candidate in ["TVLogoFallback", fallbackName, "\(fallbackName) 1"] {
            if let image = UIImage(named: candidate) {
                return image
            }
        }
        return nil
    }

    private func assetNameCandidates(for channelName: String) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            candidates.append(trimmed)
        }

        add(channelName)

        let normalized = Self.normalizedKey(channelName)
        for (keyword, logoKey) in aliasKeywords where normalized.contains(keyword) {
            add(logoKey)
            add(logoKey.uppercased())
            add(logoKey.capitalized)
            add(assetNameByLogoKey[logoKey])
        }

        return candidates
    }

    private static func normalizedKey(_ value: String) -> String {
        let lowered = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " plus ")

        let tokens = lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0) }

        return tokens.joined()
    }

    private let aliasKeywords: [(String, String)] = [
        ("skysports", "sky"),
        ("sky", "sky"),
        ("tntsports", "tnt"),
        ("tnt", "tnt"),
        ("bt", "tnt"),
        ("amazonprime", "amazon"),
        ("primevideo", "amazon"),
        ("amazon", "amazon"),
        ("dazn", "dazn"),
        ("premiersports", "premiersports"),
        ("laligatv", "laligatv"),
        ("hbomax", "hbomax"),
        ("disneyplus", "disneyplus"),
        ("nowtv", "now"),
        ("now", "now"),
        ("apple", "apple"),
        ("mlsseasonpass", "apple"),
        ("bbc", "bbc"),
        ("itv", "itv"),
        ("channel4", "channel4")
    ]

    private let assetNameByLogoKey: [String: String] = [
        "amazon": "TVLogoAmazon",
        "apple": "TVLogoApple",
        "bbc": "TVLogoBBC",
        "channel4": "TVLogoChannel4",
        "dazn": "TVLogoDAZN",
        "disneyplus": "TVLogoDisneyPlus",
        "hbomax": "TVLogoHBOMax",
        "itv": "TVLogoITV",
        "laligatv": "TVLogoLaLigaTV",
        "now": "TVLogoNOW",
        "premiersports": "TVLogoPremierSports",
        "sky": "TVLogoSky",
        "tnt": "TVLogoTNT"
    ]
}
