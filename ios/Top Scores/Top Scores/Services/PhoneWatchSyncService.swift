import Foundation
import WatchConnectivity

final class PhoneWatchSyncService: NSObject {
    static let shared = PhoneWatchSyncService()

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private var isActivated = false

    private override init() {
        super.init()
    }

    func activate() {
        guard let session, !isActivated else { return }
        isActivated = true
        session.delegate = self
        session.activate()
    }

    func sendLatestPayload(_ data: Data) {
        guard let session else { return }
        guard session.isPaired, session.isWatchAppInstalled else { return }
        let payload = [AppGroupConfig.matchesPayloadContextKey: data]

        do {
            try session.updateApplicationContext(payload)
        } catch {
            diagnosticLog("Watch sync context update failed: \(error)")
        }

        session.transferUserInfo(payload)
        if session.isReachable {
            session.sendMessageData(data, replyHandler: nil) { error in
                diagnosticLog("Watch sync message failed: \(error)")
            }
        }
    }

    private func replyWithLatestPayloadIfAvailable(_ replyHandler: @escaping ([String: Any]) -> Void) {
        guard let data = latestWatchPayloadData() else {
            replyHandler([:])
            return
        }
        replyHandler([AppGroupConfig.matchesPayloadContextKey: data])
    }

    private func pushLatestPayloadIfAvailable() {
        guard let data = latestWatchPayloadData() else { return }
        sendLatestPayload(data)
    }

    private func latestWatchPayloadData() -> Data? {
        SharedMatchesBridge.loadWatchTransferData() ?? SharedMatchesBridge.loadRawData()
    }
}

extension PhoneWatchSyncService: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated, error == nil else { return }
        DispatchQueue.main.async {
            self.pushLatestPayloadIfAvailable()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard (message[AppGroupConfig.requestMatchesSyncMessageKey] as? Bool) == true else { return }
        DispatchQueue.main.async {
            self.pushLatestPayloadIfAvailable()
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard (message[AppGroupConfig.requestMatchesSyncMessageKey] as? Bool) == true else {
            replyHandler([:])
            return
        }
        DispatchQueue.main.async {
            self.replyWithLatestPayloadIfAvailable(replyHandler)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard (userInfo[AppGroupConfig.requestMatchesSyncMessageKey] as? Bool) == true else { return }
        DispatchQueue.main.async {
            self.pushLatestPayloadIfAvailable()
        }
    }
}
