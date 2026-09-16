import Foundation
import Observation

struct WatchFantasyLeague: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let entries: [WatchFantasyStanding]
}

struct WatchFantasyStanding: Codable, Hashable, Identifiable {
    let entry: Int
    let rank: Int
    let lastRank: Int?
    let entryName: String
    let playerName: String
    let total: Int?
    let clubBadgeSrc: String?

    var id: Int { entry }

    func preservingBadge(from previous: WatchFantasyStanding?) -> WatchFantasyStanding {
        guard WatchFantasyImageLoader.normalizedURL(clubBadgeSrc) == nil,
              let badge = previous?.clubBadgeSrc else { return self }
        return WatchFantasyStanding(entry: entry, rank: rank, lastRank: lastRank, entryName: entryName,
                                    playerName: playerName, total: total, clubBadgeSrc: badge)
    }
    var trend: String {
        guard let lastRank, lastRank > 0, rank > 0 else { return "minus" }
        if rank < lastRank { return "arrow.up" }
        if rank > lastRank { return "arrow.down" }
        return "arrow.right"
    }
    var trendDescription: String {
        guard let lastRank, lastRank > 0, rank > 0 else { return "Trend unavailable" }
        if rank < lastRank { return "Up \(lastRank - rank) places" }
        if rank > lastRank { return "Down \(rank - lastRank) places" }
        return "No change"
    }
}

enum WatchFantasyPresentation {
    static func points(_ value: Double?) -> String {
        value.map { String(format: "%.1f xP", $0) } ?? "— xP"
    }

    static func deadline(_ raw: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let raw, let date = parseDate(raw) else { return "Deadline unavailable" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE"
        let ordinal = NumberFormatter()
        ordinal.locale = formatter.locale
        ordinal.numberStyle = .ordinal
        let day = calendar.component(.day, from: date)
        let dateLabel = "\(formatter.string(from: date)) \(ordinal.string(from: NSNumber(value: day)) ?? String(day))"
        guard date > now else { return "\(dateLabel) (passed)" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let remaining = days == 0 ? "today" : "\(days) \(days == 1 ? "day" : "days")"
        return "\(dateLabel) (\(remaining))"
    }

    static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: raw)
    }

    static func surname(_ name: String) -> String {
        // FPL web names preserve compound surnames; strip only disambiguating initials.
        name.replacingOccurrences(of: "^(?:[A-Z]\\.\\s*)+", with: "", options: .regularExpression)
    }

    static func opponent(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value.replacingOccurrences(of: " (H)", with: "")
            .replacingOccurrences(of: " (A)", with: "")
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        return words.prefix(3).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

extension WatchFantasySnapshot {
    var scoreDisplay: String {
        if scorePhase == "expected" { return WatchFantasyPresentation.points(expectedPoints) }
        return totalPoints.map { "\($0) pts" } ?? "— pts"
    }

    var scoreDescription: String {
        switch scorePhase {
        case "expected": return "Expected points"
        case "provisional": return "Live · provisional"
        case "final": return "Confirmed points"
        default: return "Open FPL on iPhone to update"
        }
    }
}

@MainActor @Observable
final class WatchFantasyLeagueStore {
    private(set) var entries: [WatchFantasyStanding]
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasNext = true
    private var page = 0

    init(entries: [WatchFantasyStanding]) {
        self.entries = entries.sorted { $0.rank < $1.rank }
    }

    func loadNextPage(leagueID: Int) async {
        guard leagueID > 0, !isLoading, hasNext else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await fetch(leagueID: leagueID, page: page + 1)
            try Task.checkCancellation()
            let knownEntries = Dictionary(entries.map { ($0.entry, $0) }, uniquingKeysWith: { first, _ in first })
            let rows = response.standings.results.map { $0.preservingBadge(from: knownEntries[$0.entry]) }
            if page == 0 { entries = rows }
            else {
                let existing = Set(entries.map(\.id))
                entries.append(contentsOf: rows.filter { !existing.contains($0.id) })
            }
            entries.sort { $0.rank < $1.rank }
            page = response.standings.page
            hasNext = response.standings.hasNext
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            errorMessage = "Couldn't load standings. Try again."
        }
    }

    private struct Response: Decodable {
        let standings: Standings
        struct Standings: Decodable {
            let hasNext: Bool
            let page: Int
            let results: [WatchFantasyStanding]
        }
    }

    private func fetch(leagueID: Int, page: Int) async throws -> Response {
        let url = URL(string: "https://fantasy.premierleague.com/api/leagues-classic/\(leagueID)/standings/?page_standings=\(page)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<3 {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if (http.statusCode == 429 || http.statusCode >= 500), attempt < 2 {
                try await Task.sleep(for: .seconds(1 << attempt))
                continue
            }
            guard (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Response.self, from: data)
        }
        throw URLError(.badServerResponse)
    }
}
