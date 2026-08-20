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

    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private let liveRefreshInterval: TimeInterval = 30
    private let standardRefreshInterval: TimeInterval = 5 * 60
    private let liveDetailsWarmInterval: TimeInterval = 20
    private var didActivateSession = false
    private var automaticRefreshTimer: Timer?
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
        detailsCache[matchID] = WatchCachedMatchDetails(match: match, cachedAt: Date())
        saveMatchDetailsCache()
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
            }
            return
        }

        let sourceMatches: [WatchMatch]
        if !payload.unfilteredMatches.isEmpty {
            sourceMatches = payload.unfilteredMatches
        } else {
            sourceMatches = payload.matches
        }

        let sorted = WatchMatchGrouping.sortedMatches(sourceMatches)
        let grouped = WatchMatchGrouping.groupedDays(sorted)
        let todaysCount = WatchMatchGrouping.todaysMatchCount(sorted)

        DispatchQueue.main.async {
            self.filteredMatches = sourceMatches
            self.unfilteredMatches = payload.unfilteredMatches
            self.groupedDays = grouped
            self.lastUpdated = payload.lastUpdated
            self.generatedAt = payload.generatedAt
            self.todaysMatchCount = todaysCount
            self.hasData = true
            self.apiBaseURL = payload.snapshot.apiBaseURL
            self.scheduleAutomaticRefresh()
            self.preloadLiveMatchDetailsIfNeeded(from: sourceMatches, apiBaseURL: payload.snapshot.apiBaseURL)
        }
    }

    private func handleIncomingPayloadData(_ data: Data) {
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
