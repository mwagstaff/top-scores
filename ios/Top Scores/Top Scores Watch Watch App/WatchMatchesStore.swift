import ClockKit
import Combine
import Foundation
import WatchConnectivity

enum WatchAppGroupConfig {
    static let identifier = "group.dev.skynolimit.topscores"
    static let sharedMatchesFileName = "shared-matches.json"
    static let matchesPayloadContextKey = "matches_payload"
    static let requestMatchesSyncMessageKey = "request_matches_sync"
    static let competitionCatalogWeightsDataKey = "catalog.competitionWeightsData"
}

final class WatchMatchesStore: NSObject, ObservableObject {
    @Published private(set) var groupedDays: [WatchMatchDay] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var generatedAt: Date?
    @Published private(set) var todaysMatchCount: Int = 0
    @Published private(set) var hasData = false
    @Published private(set) var apiBaseURL: String = "https://api.skynolimit.dev/top-scores/api/v1"

    private let decoder: JSONDecoder
    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private var didActivateSession = false
    private var filteredMatches: [WatchMatch] = []
    private var unfilteredMatches: [WatchMatch] = []

    var unfilteredGroupedDays: [WatchMatchDay] {
        let sorted = WatchMatchGrouping.sortedMatches(unfilteredMatches)
        return WatchMatchGrouping.groupedDays(sorted)
    }

    override init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        super.init()
        loadLocalPayload()
        activateSessionIfNeeded()
    }

    func refresh(requestPhoneSync: Bool = true) {
        loadLocalPayload()
        if requestPhoneSync {
            requestLatestPayloadFromPhone()
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
        session.transferUserInfo(request)

        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(request) { [weak self] reply in
            guard let self else { return }
            guard let data = reply[WatchAppGroupConfig.matchesPayloadContextKey] as? Data else { return }
            self.handleIncomingPayloadData(data)
        } errorHandler: { _ in }
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

    private var sharedFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WatchAppGroupConfig.identifier)?
            .appendingPathComponent(WatchAppGroupConfig.sharedMatchesFileName)
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
