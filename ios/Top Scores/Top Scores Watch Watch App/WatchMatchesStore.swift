import ClockKit
import Combine
import Foundation
import OSLog
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

private struct WatchPreparedPayload {
    let payload: WatchSharedMatchesPayload
    let filteredMatches: [WatchMatch]
    let unfilteredMatches: [WatchMatch]
    let groupedDays: [WatchMatchDay]
    let todaysMatchCount: Int
    let homeSnapshot: WatchHomeSnapshot
}

final class WatchMatchesStore: NSObject, ObservableObject {
    private(set) var groupedDays: [WatchMatchDay] = []
    private(set) var lastUpdated: Date?
    private(set) var generatedAt: Date?
    private(set) var todaysMatchCount: Int = 0
    private(set) var hasData = false
    private(set) var apiBaseURL: String = "https://api.skynolimit.dev/top-scores/api/v1"
    @Published private(set) var fantasySnapshot: WatchFantasySnapshot?
    @Published private(set) var homeSnapshot: WatchHomeSnapshot = .empty

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private let liveRefreshInterval: TimeInterval = 30
    private let standardRefreshInterval: TimeInterval = 5 * 60
    private let foregroundRefreshCoalescingInterval: TimeInterval = 5
    private let phoneRequestCoalescingInterval: TimeInterval = 5
    private let maximumDetailsCacheEntries = 64
    private let persistenceQueue = DispatchQueue(
        label: "dev.skynolimit.topscores.watch-persistence",
        qos: .utility
    )
    private var didActivateSession = false
    private var didStartAutomaticRefresh = false
    private var isSceneActive = false
    private var hasDeferredComplicationReload = false
    private var lastRefreshRequestAt: Date?
    private var lastPhonePayloadRequestAt: Date?
    private var lastTodaySummaryRefreshAt: Date?
    private var lastLoadedPayloadData: Data?
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
        let start = DispatchTime.now()
        super.init()
        loadMatchDetailsCache()
        activateSessionIfNeeded()
        WatchPerformanceDiagnostics.logger.notice(
            "Store initialized: \(WatchPerformanceDiagnostics.milliseconds(since: start), privacy: .public) ms detailsCache=\(self.detailsCache.count, privacy: .public)"
        )
    }

    deinit {
        automaticRefreshTimer?.invalidate()
        todayRefreshTask?.cancel()
    }

    func refresh(requestPhoneSync: Bool = true) {
        let now = Date()
        if let lastRefreshRequestAt,
           now.timeIntervalSince(lastRefreshRequestAt) < foregroundRefreshCoalescingInterval {
            WatchPerformanceDiagnostics.logger.debug("Refresh coalesced")
            return
        }
        lastRefreshRequestAt = now

        scheduleAutomaticRefresh()
        refreshTodayMatchSummaries(from: filteredMatches, apiBaseURL: apiBaseURL)
        WatchPerformanceDiagnostics.logger.info(
            "Refresh started: matches=\(self.filteredMatches.count, privacy: .public) phoneSync=\(requestPhoneSync, privacy: .public)"
        )
        if requestPhoneSync {
            requestLatestPayloadFromPhone()
        }
    }

    func startAutomaticRefresh() {
        guard !didStartAutomaticRefresh else { return }
        didStartAutomaticRefresh = true
        refresh(requestPhoneSync: true)
    }

    func setSceneActive(_ isActive: Bool) {
        isSceneActive = isActive
        guard !isActive, hasDeferredComplicationReload else { return }
        hasDeferredComplicationReload = false
        reloadComplications()
    }

    func cachedDetails(for match: WatchMatch) -> WatchMatch? {
        guard let matchID = match.matchDetailsIDValue else { return nil }
        return detailsCache[matchID]?.match
    }

    func cacheDetails(_ match: WatchMatch) {
        guard let matchID = match.matchDetailsIDValue else { return }
        let didChange = detailsCache[matchID]?.match != match
        guard didChange else { return }
        detailsCache[matchID] = WatchCachedMatchDetails(match: match, cachedAt: Date())
        trimDetailsCacheIfNeeded()
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

        let now = Date()
        if let lastPhonePayloadRequestAt,
           now.timeIntervalSince(lastPhonePayloadRequestAt) < phoneRequestCoalescingInterval {
            WatchPerformanceDiagnostics.logger.debug("Phone payload request coalesced")
            return
        }
        lastPhonePayloadRequestAt = now

        let request = [WatchAppGroupConfig.requestMatchesSyncMessageKey: true]

        if session.activationState == .activated, session.isReachable {
            WatchPerformanceDiagnostics.logger.info("Requesting latest phone payload")
            session.sendMessage(request) { [weak self] reply in
                guard let self else { return }
                guard let data = reply[WatchAppGroupConfig.matchesPayloadContextKey] as? Data else { return }
                DispatchQueue.main.async {
                    self.handleIncomingPayloadData(data)
                }
            } errorHandler: { _ in }
        } else {
            WatchPerformanceDiagnostics.logger.debug(
                "Phone payload request skipped: activation=\(session.activationState.rawValue, privacy: .public) reachable=\(session.isReachable, privacy: .public)"
            )
        }
    }

    private func loadLocalPayload() {
        guard let url = sharedFileURL else { return }
        let detailsCacheSnapshot = detailsCache

        Task.detached(priority: .userInitiated) { [weak self] in
            let start = DispatchTime.now()
            let interval = WatchPerformanceDiagnostics.signposter.beginInterval("LoadLocalPayload")
            defer {
                WatchPerformanceDiagnostics.signposter.endInterval("LoadLocalPayload", interval)
            }
            guard let data = try? Data(contentsOf: url) else { return }
            let shouldPrepare = await MainActor.run {
                guard let self, self.lastLoadedPayloadData != data else { return false }
                self.lastLoadedPayloadData = data
                return true
            }
            guard shouldPrepare else {
                WatchPerformanceDiagnostics.logger.debug("Duplicate local payload ignored")
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let payload = try? decoder.decode(WatchSharedMatchesPayload.self, from: data) else {
                WatchPerformanceDiagnostics.logger.error(
                    "Failed to decode local payload: bytes=\(data.count, privacy: .public) duration=\(WatchPerformanceDiagnostics.milliseconds(since: start), privacy: .public) ms"
                )
                return
            }
            let prepared = Self.prepare(payload: payload, detailsCache: detailsCacheSnapshot)
            WatchPerformanceDiagnostics.logger.notice(
                "Loaded local payload: bytes=\(data.count, privacy: .public) matches=\(prepared.filteredMatches.count, privacy: .public) duration=\(WatchPerformanceDiagnostics.milliseconds(since: start), privacy: .public) ms"
            )

            await MainActor.run {
                guard let self else { return }
                if let generatedAt = self.generatedAt,
                   generatedAt > payload.generatedAt {
                    WatchPerformanceDiagnostics.logger.debug("Older local payload ignored")
                    return
                }
                self.applyPreparedPayload(prepared)
            }
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

        let now = Date()
        let minimumInterval = matches.contains(where: \.isInProgress)
            ? liveRefreshInterval
            : standardRefreshInterval
        if let lastTodaySummaryRefreshAt,
           now.timeIntervalSince(lastTodaySummaryRefreshAt) < minimumInterval {
            WatchPerformanceDiagnostics.logger.debug("Today summary refresh throttled")
            return
        }
        lastTodaySummaryRefreshAt = now
        WatchPerformanceDiagnostics.logger.info(
            "Today summary request started: date=\(date, privacy: .public) live=\(matches.contains(where: \.isInProgress), privacy: .public)"
        )

        todayRefreshTask?.cancel()
        todayRefreshTask = Task {
            do {
                let latestMatches = try await WatchAPIClient(baseURL: baseURL).fetchMatches(on: date)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.applyLatestMatchSummaries(latestMatches)
                }
            } catch is CancellationError {
                return
            } catch {
                diagnosticLog("[WatchMatchesStore] Failed to refresh today's match summaries: %@", String(describing: error))
            }
        }
    }

    private func applyLatestMatchSummaries(_ latestMatches: [WatchMatch]) {
        let start = DispatchTime.now()
        let interval = WatchPerformanceDiagnostics.signposter.beginInterval("ApplyLatestSummaries")
        defer {
            WatchPerformanceDiagnostics.signposter.endInterval("ApplyLatestSummaries", interval)
        }
        let refreshedFiltered = WatchMatchSummaryMerger.merging(
            source: filteredMatches,
            latest: latestMatches
        )
        let refreshedUnfiltered = WatchMatchSummaryMerger.merging(
            source: unfilteredMatches,
            latest: latestMatches
        )
        guard refreshedFiltered != filteredMatches || refreshedUnfiltered != unfilteredMatches else {
            lastUpdated = Date()
            scheduleAutomaticRefresh()
            WatchPerformanceDiagnostics.logger.info(
                "Today summary unchanged: received=\(latestMatches.count, privacy: .public) duration=\(WatchPerformanceDiagnostics.milliseconds(since: start), privacy: .public) ms"
            )
            return
        }
        filteredMatches = refreshedFiltered
        unfilteredMatches = refreshedUnfiltered

        let sorted = WatchMatchGrouping.sortedMatches(refreshedFiltered)
        groupedDays = WatchMatchGrouping.groupedDays(sorted)
        todaysMatchCount = WatchMatchGrouping.todaysMatchCount(sorted)
        lastUpdated = Date()
        homeSnapshot = WatchMatchCollections.homeSnapshot(from: sorted)

        let now = Date()
        let latestMatchIDs = Set(latestMatches.compactMap(\.matchDetailsIDValue))
        for match in refreshedFiltered {
            guard let matchID = match.matchDetailsIDValue,
                  latestMatchIDs.contains(matchID) else {
                continue
            }
            let cacheBase = detailsCache[matchID]?.match ?? match
            detailsCache[matchID] = WatchCachedMatchDetails(
                match: cacheBase.mergingLatestSummary(match),
                cachedAt: now
            )
        }
        trimDetailsCacheIfNeeded()
        saveMatchDetailsCache()
        scheduleAutomaticRefresh()
        reloadComplications()
        WatchPerformanceDiagnostics.logger.notice(
            "Today summary applied: received=\(latestMatches.count, privacy: .public) visible=\(refreshedFiltered.count, privacy: .public) duration=\(WatchPerformanceDiagnostics.milliseconds(since: start), privacy: .public) ms"
        )
    }

    private func handleIncomingPayloadData(_ data: Data) {
        guard data != lastLoadedPayloadData else {
            WatchPerformanceDiagnostics.logger.debug("Duplicate phone payload ignored")
            return
        }
        lastLoadedPayloadData = data
        let detailsCacheSnapshot = detailsCache
        WatchPerformanceDiagnostics.logger.info(
            "Phone payload received: bytes=\(data.count, privacy: .public)"
        )

        Task.detached(priority: .userInitiated) { [weak self] in
            let start = DispatchTime.now()
            let interval = WatchPerformanceDiagnostics.signposter.beginInterval("DecodePhonePayload")
            defer {
                WatchPerformanceDiagnostics.signposter.endInterval("DecodePhonePayload", interval)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let payload = try? decoder.decode(WatchSharedMatchesPayload.self, from: data) else {
                return
            }
            let prepared = Self.prepare(payload: payload, detailsCache: detailsCacheSnapshot)
            WatchPerformanceDiagnostics.logger.notice(
                "Phone payload prepared: matches=\(prepared.filteredMatches.count, privacy: .public) duration=\(WatchPerformanceDiagnostics.milliseconds(since: start), privacy: .public) ms"
            )

            await MainActor.run {
                guard let self else { return }
                if let generatedAt = self.generatedAt,
                   generatedAt >= payload.generatedAt {
                    WatchPerformanceDiagnostics.logger.debug("Older phone payload ignored")
                    return
                }
                self.saveRawPayloadData(data)
                self.applyPreparedPayload(prepared)
                self.reloadComplications()
            }
        }
    }

    private static func prepare(
        payload: WatchSharedMatchesPayload,
        detailsCache: [String: WatchCachedMatchDetails]
    ) -> WatchPreparedPayload {
        let sourceMatches = payload.snapshot.showAllMatches && !payload.unfilteredMatches.isEmpty
            ? payload.unfilteredMatches
            : payload.matches
        let filteredMatches = sourceMatches.map { match in
            guard let matchID = match.matchDetailsIDValue,
                  let cached = detailsCache[matchID],
                  cached.cachedAt > payload.generatedAt else {
                return match
            }
            return match.mergingLatestSummary(cached.match)
        }
        let sorted = WatchMatchGrouping.sortedMatches(filteredMatches)

        return WatchPreparedPayload(
            payload: payload,
            filteredMatches: filteredMatches,
            unfilteredMatches: payload.snapshot.showAllMatches && !payload.unfilteredMatches.isEmpty
                ? filteredMatches
                : [],
            groupedDays: WatchMatchGrouping.groupedDays(sorted),
            todaysMatchCount: WatchMatchGrouping.todaysMatchCount(sorted),
            homeSnapshot: WatchMatchCollections.homeSnapshot(from: sorted)
        )
    }

    private func applyPreparedPayload(_ prepared: WatchPreparedPayload) {
        let payload = prepared.payload
        filteredMatches = prepared.filteredMatches
        unfilteredMatches = prepared.unfilteredMatches
        groupedDays = prepared.groupedDays
        lastUpdated = payload.lastUpdated
        generatedAt = payload.generatedAt
        todaysMatchCount = prepared.todaysMatchCount
        hasData = true
        apiBaseURL = payload.snapshot.apiBaseURL
        fantasySnapshot = payload.fantasy
        homeSnapshot = prepared.homeSnapshot
        WatchPerformanceDiagnostics.logger.notice(
            "Published home snapshot: matches=\(prepared.filteredMatches.count, privacy: .public) todaySections=\(prepared.homeSnapshot.todaySections.count, privacy: .public) competitions=\(prepared.homeSnapshot.todayCompetitions.count, privacy: .public)"
        )
        scheduleAutomaticRefresh()
        refreshTodayMatchSummaries(
            from: prepared.filteredMatches,
            apiBaseURL: payload.snapshot.apiBaseURL
        )
    }

    private func reloadComplications() {
        guard !isSceneActive else {
            hasDeferredComplicationReload = true
            WatchPerformanceDiagnostics.logger.debug("Complication reload deferred while app is active")
            return
        }
        let server = CLKComplicationServer.sharedInstance()
        guard let activeComplications = server.activeComplications else { return }
        for complication in activeComplications {
            server.reloadTimeline(for: complication)
        }
    }

    private func saveRawPayloadData(_ data: Data) {
        guard let url = sharedFileURL else { return }
        persistenceQueue.async {
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                WatchPerformanceDiagnostics.logger.error("Failed to save watch payload: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func loadMatchDetailsCache() {
        guard let url = matchDetailsCacheFileURL else {
            loadLocalPayload()
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let start = DispatchTime.now()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cache: [String: WatchCachedMatchDetails]
            if let data = try? Data(contentsOf: url),
               let decoded = try? decoder.decode([String: WatchCachedMatchDetails].self, from: data) {
                cache = decoded
            } else {
                cache = [:]
            }

            await MainActor.run {
                guard let self else { return }
                for (matchID, cached) in cache {
                    if let current = self.detailsCache[matchID], current.cachedAt >= cached.cachedAt {
                        continue
                    }
                    self.detailsCache[matchID] = cached
                }
                self.trimDetailsCacheIfNeeded()
                if cache.count > self.maximumDetailsCacheEntries {
                    WatchPerformanceDiagnostics.logger.notice(
                        "Details cache pruned: before=\(cache.count, privacy: .public) after=\(self.detailsCache.count, privacy: .public)"
                    )
                    self.saveMatchDetailsCache()
                }
                WatchPerformanceDiagnostics.logger.notice(
                    "Details cache loaded: entries=\(self.detailsCache.count, privacy: .public) duration=\(WatchPerformanceDiagnostics.milliseconds(since: start), privacy: .public) ms"
                )
                self.loadLocalPayload()
            }
        }
    }

    private func saveMatchDetailsCache() {
        guard let url = matchDetailsCacheFileURL else { return }
        let cacheSnapshot = detailsCache
        persistenceQueue.async {
            let start = DispatchTime.now()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(cacheSnapshot) else { return }
            do {
                try data.write(to: url, options: [.atomic])
                let duration = WatchPerformanceDiagnostics.milliseconds(since: start)
                if duration >= 50 {
                    WatchPerformanceDiagnostics.logger.warning(
                        "Slow details cache write: entries=\(cacheSnapshot.count, privacy: .public) bytes=\(data.count, privacy: .public) duration=\(duration, privacy: .public) ms"
                    )
                }
            } catch {
                WatchPerformanceDiagnostics.logger.error("Failed to save details cache: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func trimDetailsCacheIfNeeded() {
        guard detailsCache.count > maximumDetailsCacheEntries else { return }
        let newestEntries = detailsCache
            .sorted { $0.value.cachedAt > $1.value.cachedAt }
            .prefix(maximumDetailsCacheEntries)
        detailsCache = Dictionary(uniqueKeysWithValues: newestEntries.map { ($0.key, $0.value) })
    }

    private func scheduleAutomaticRefresh() {
        DispatchQueue.main.async {
            self.automaticRefreshTimer?.invalidate()
            let interval = self.filteredMatches.contains(where: \.isInProgress)
                ? self.liveRefreshInterval
                : self.standardRefreshInterval
            self.automaticRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                self?.refresh(requestPhoneSync: false)
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
