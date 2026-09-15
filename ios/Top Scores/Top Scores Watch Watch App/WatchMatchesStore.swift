import ClockKit
import Combine
import Foundation
import WatchConnectivity

enum WatchAppGroupConfig {
    static let identifier = "group.dev.skynolimit.topscores"
    static let sharedMatchesFileName = "shared-matches.json"
    static let matchDetailsCacheFileName = "match-details-cache.json"
    static let matchesPayloadContextKey = "matches_payload"
    static let requestMatchesSyncMessageKey = "request_matches_sync"
}

struct WatchCachedMatchDetails: Codable {
    let match: WatchMatch
    let cachedAt: Date
}

final class WatchMatchesStore: NSObject, ObservableObject {
    @Published private(set) var groupedDays: [WatchMatchDay] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var generatedAt: Date?
    @Published private(set) var todaysMatchCount: Int = 0
    @Published private(set) var hasData = false
    @Published private(set) var apiBaseURL: String = "https://api.skynolimit.dev/top-scores/api/v1"
    @Published private(set) var fantasySnapshot: WatchFantasySnapshot?

    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private let liveRefreshInterval: TimeInterval = 30
    private let standardRefreshInterval: TimeInterval = 5 * 60
    private let liveDetailsWarmInterval: TimeInterval = 20
    private var didActivateSession = false
    private var automaticRefreshTimer: Timer?
    private var todayRefreshTask: Task<Void, Never>?
    private var filteredMatches: [WatchMatch] = []
    private var unfilteredMatches: [WatchMatch] = []
    private var detailsCache: [String: WatchCachedMatchDetails] = [:]

    var unfilteredGroupedDays: [WatchMatchDay] {
        let sorted = WatchMatchGrouping.sortedMatches(unfilteredMatches)
        return WatchMatchGrouping.groupedDays(sorted)
    }

    override init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        super.init()
        loadMatchDetailsCache()
        loadLocalPayload()
        activateSessionIfNeeded()
    }

    deinit {
        automaticRefreshTimer?.invalidate()
        todayRefreshTask?.cancel()
    }

    func refresh(requestPhoneSync: Bool = true) {
        loadLocalPayload()
        if requestPhoneSync {
            requestLatestPayloadFromPhone()
        }
    }

    func startAutomaticRefresh() {
        refresh(requestPhoneSync: true)
        scheduleAutomaticRefresh()
    }

    func cachedDetails(for match: WatchMatch) -> WatchMatch? {
        guard let matchID = match.matchDetailsIDValue else { return nil }
        return detailsCache[matchID]?.match
    }

    func cacheDetails(_ match: WatchMatch) {
        guard let matchID = match.matchDetailsIDValue else { return }
        let didChange = detailsCache[matchID]?.match != match
        detailsCache[matchID] = WatchCachedMatchDetails(match: match, cachedAt: Date())
        saveMatchDetailsCache()
        if didChange {
            reloadComplications()
        }
    }

    private func activateSessionIfNeeded() {
        guard let session, !didActivateSession else { return }
        didActivateSession = true
        session.delegate = self
        session.activate()
    }

    private func requestLatestPayloadFromPhone() {
        guard let session else { return }
        guard session.isCompanionAppInstalled else { return }

        let request = [WatchAppGroupConfig.requestMatchesSyncMessageKey: true]

        if session.activationState == .activated, session.isReachable {
            session.sendMessage(request) { [weak self] reply in
                guard let self else { return }
                guard let data = reply[WatchAppGroupConfig.matchesPayloadContextKey] as? Data else { return }
                self.handleIncomingPayloadData(data)
            } errorHandler: { _ in }
        } else {
            session.transferUserInfo(request)
        }
    }

    private func loadLocalPayload() {
        guard let data = loadRawPayloadData(),
              let payload = try? decoder.decode(WatchSharedMatchesPayload.self, from: data)
        else {
            DispatchQueue.main.async {
                self.filteredMatches = []
                self.unfilteredMatches = []
                self.groupedDays = []
                self.lastUpdated = nil
                self.generatedAt = nil
                self.todaysMatchCount = 0
                self.hasData = false
                self.fantasySnapshot = nil
            }
            return
        }

        let sourceMatches: [WatchMatch]
        if payload.snapshot.showAllMatches, !payload.unfilteredMatches.isEmpty {
            sourceMatches = payload.unfilteredMatches
        } else {
            sourceMatches = payload.matches
        }

        let sourceWithNewerCachedSummaries = sourceMatches.map { match in
            guard let matchID = match.matchDetailsIDValue,
                  let cached = detailsCache[matchID],
                  cached.cachedAt > payload.generatedAt else {
                return match
            }
            return match.mergingLatestSummary(cached.match)
        }
        let sorted = WatchMatchGrouping.sortedMatches(sourceWithNewerCachedSummaries)
        let grouped = WatchMatchGrouping.groupedDays(sorted)
        let todaysCount = WatchMatchGrouping.todaysMatchCount(sorted)

        DispatchQueue.main.async {
            self.filteredMatches = sourceWithNewerCachedSummaries
            self.unfilteredMatches = payload.snapshot.showAllMatches && !payload.unfilteredMatches.isEmpty
                ? sourceWithNewerCachedSummaries
                : []
            self.groupedDays = grouped
            self.lastUpdated = payload.lastUpdated
            self.generatedAt = payload.generatedAt
            self.todaysMatchCount = todaysCount
            self.hasData = true
            self.apiBaseURL = payload.snapshot.apiBaseURL
            self.fantasySnapshot = payload.fantasy
            self.scheduleAutomaticRefresh()
            self.refreshTodayMatchSummaries(
                from: sourceWithNewerCachedSummaries,
                apiBaseURL: payload.snapshot.apiBaseURL
            )
            self.preloadLiveMatchDetailsIfNeeded(
                from: sourceWithNewerCachedSummaries,
                apiBaseURL: payload.snapshot.apiBaseURL
            )
        }
    }

    private func refreshTodayMatchSummaries(from matches: [WatchMatch], apiBaseURL: String) {
        let calendar = Calendar.current
        guard let date = matches.first(where: { match in
            guard let matchDate = WatchMatchDateParser.shared.parse(date: match.date, time: "00:00") else {
                return false
            }
            return calendar.isDateInToday(matchDate)
        })?.date,
        let baseURL = URL(string: apiBaseURL) else {
            return
        }

        todayRefreshTask?.cancel()
        todayRefreshTask = Task {
            do {
                let latestMatches = try await WatchAPIClient(baseURL: baseURL).fetchMatches(on: date)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.applyLatestMatchSummaries(latestMatches, apiBaseURL: apiBaseURL)
                }
            } catch is CancellationError {
                return
            } catch {
                diagnosticLog("[WatchMatchesStore] Failed to refresh today's match summaries: %@", String(describing: error))
            }
        }
    }

    private func applyLatestMatchSummaries(_ latestMatches: [WatchMatch], apiBaseURL: String) {
        let refreshedFiltered = WatchMatchSummaryMerger.merging(
            source: filteredMatches,
            latest: latestMatches
        )
        let refreshedUnfiltered = WatchMatchSummaryMerger.merging(
            source: unfilteredMatches,
            latest: latestMatches
        )
        filteredMatches = refreshedFiltered
        unfilteredMatches = refreshedUnfiltered

        let sorted = WatchMatchGrouping.sortedMatches(refreshedFiltered)
        groupedDays = WatchMatchGrouping.groupedDays(sorted)
        todaysMatchCount = WatchMatchGrouping.todaysMatchCount(sorted)
        lastUpdated = Date()

        let now = Date()
        for match in refreshedFiltered {
            guard let matchID = match.matchDetailsIDValue,
                  latestMatches.contains(where: { $0.matchDetailsIDValue == matchID }) else {
                continue
            }
            let cacheBase = detailsCache[matchID]?.match ?? match
            detailsCache[matchID] = WatchCachedMatchDetails(
                match: cacheBase.mergingLatestSummary(match),
                cachedAt: now
            )
        }
        saveMatchDetailsCache()
        scheduleAutomaticRefresh()
        preloadLiveMatchDetailsIfNeeded(from: refreshedFiltered, apiBaseURL: apiBaseURL)
        reloadComplications()
    }

    private func handleIncomingPayloadData(_ data: Data) {
        guard let incoming = try? decoder.decode(WatchSharedMatchesPayload.self, from: data) else {
            return
        }
        if let existingData = loadRawPayloadData(),
           let existing = try? decoder.decode(WatchSharedMatchesPayload.self, from: existingData),
           existing.generatedAt > incoming.generatedAt {
            return
        }
        saveRawPayloadData(data)
        loadLocalPayload()
        reloadComplications()
    }

    private func reloadComplications() {
        let server = CLKComplicationServer.sharedInstance()
        guard let activeComplications = server.activeComplications else { return }
        for complication in activeComplications {
            server.reloadTimeline(for: complication)
        }
    }

    private func loadRawPayloadData() -> Data? {
        guard let url = sharedFileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    private func saveRawPayloadData(_ data: Data) {
        guard let url = sharedFileURL else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func loadMatchDetailsCache() {
        guard let url = matchDetailsCacheFileURL,
              let data = try? Data(contentsOf: url),
              let cache = try? decoder.decode([String: WatchCachedMatchDetails].self, from: data)
        else {
            detailsCache = [:]
            return
        }
        detailsCache = cache
    }

    private func saveMatchDetailsCache() {
        guard let url = matchDetailsCacheFileURL,
              let data = try? encoder.encode(detailsCache)
        else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func preloadLiveMatchDetailsIfNeeded(from matches: [WatchMatch], apiBaseURL: String) {
        guard let baseURL = URL(string: apiBaseURL) else { return }
        let now = Date()
        let liveMatches = matches.filter { match in
            guard match.isInProgress, match.matchDetailsIDValue != nil else { return false }
            guard let matchID = match.matchDetailsIDValue,
                  let cached = detailsCache[matchID] else {
                return true
            }
            return now.timeIntervalSince(cached.cachedAt) >= liveDetailsWarmInterval
        }
        guard !liveMatches.isEmpty else { return }

        Task {
            let client = WatchAPIClient(baseURL: baseURL)
            for match in liveMatches {
                guard !Task.isCancelled,
                      let matchID = match.matchDetailsIDValue else { continue }
                do {
                    let details = try await client.fetchMatchDetails(matchId: matchID)
                    let updated = match.withDetails(details)
                    await MainActor.run {
                        self.cacheDetails(updated)
                    }
                } catch {
                    diagnosticLog("[WatchMatchesStore] Failed to warm live match details for %@: %@", matchID, String(describing: error))
                }
            }
        }
    }

    private func scheduleAutomaticRefresh() {
        DispatchQueue.main.async {
            self.automaticRefreshTimer?.invalidate()
            let interval = self.filteredMatches.contains(where: \.isInProgress)
                ? self.liveRefreshInterval
                : self.standardRefreshInterval
            self.automaticRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                self?.refresh(requestPhoneSync: true)
            }
        }
    }

    private var sharedFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WatchAppGroupConfig.identifier)?
            .appendingPathComponent(WatchAppGroupConfig.sharedMatchesFileName)
    }

    private var matchDetailsCacheFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WatchAppGroupConfig.identifier)?
            .appendingPathComponent(WatchAppGroupConfig.matchDetailsCacheFileName)
    }
}

enum WatchMatchSummaryMerger {
    static func merging(source: [WatchMatch], latest: [WatchMatch]) -> [WatchMatch] {
        let latestByDetailsID = Dictionary(
            latest.compactMap { match in
                match.matchDetailsIDValue.map { ($0, match) }
            },
            uniquingKeysWith: { _, newest in newest }
        )
        let latestByIdentity = Dictionary(
            latest.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )

        return source.map { match in
            let latestMatch = match.matchDetailsIDValue.flatMap { latestByDetailsID[$0] }
                ?? latestByIdentity[match.id]
            guard let latestMatch else { return match }
            return match.mergingLatestSummary(latestMatch)
        }
    }
}

extension WatchMatchesStore: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated, error == nil else { return }
        DispatchQueue.main.async {
            self.requestLatestPayloadFromPhone()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchAppGroupConfig.matchesPayloadContextKey] as? Data else { return }
        DispatchQueue.main.async {
            self.handleIncomingPayloadData(data)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchAppGroupConfig.matchesPayloadContextKey] as? Data else { return }
        DispatchQueue.main.async {
            self.handleIncomingPayloadData(data)
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        DispatchQueue.main.async {
            self.handleIncomingPayloadData(messageData)
        }
    }
}
