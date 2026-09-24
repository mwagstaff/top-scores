import Combine
import Foundation
@preconcurrency import GameKit
import UIKit

/// Created lazily by the prediction game. Ordinary scores browsing never initializes GameKit.
@MainActor
protocol PredictionGameCenterServing: AnyObject {
    var isPresentingAuthentication: Bool { get }
    var currentTeamPlayerID: String? { get }
    var isMultiplayerGamingRestricted: Bool { get }
    var authenticationChanges: AnyPublisher<Void, Never> { get }
    func isAuthenticated(expectedTeamPlayerID: String) -> Bool
    func authenticate() async throws -> PredictionGameCenterIdentity
    func cancelAuthentication()
    func showLeaderboards(expectedTeamPlayerID: String, leaderboardID: String?) throws
    func showAchievements(expectedTeamPlayerID: String) throws
    func submit(_ submissions: PredictionGameCenterSubmissions, expectedTeamPlayerID: String) async throws
}

@MainActor
extension PredictionGameCenterServing {
    var isMultiplayerGamingRestricted: Bool { false }
    var authenticationChanges: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
}

@MainActor
final class PredictionGameCenterService: NSObject, GKGameCenterControllerDelegate, PredictionGameCenterServing {
    private var authenticationContinuation: CheckedContinuation<Void, Error>?
    private weak var authenticationController: UIViewController?

    var isPresentingAuthentication: Bool {
        guard let authenticationController else { return false }
        return authenticationController.isBeingPresented || authenticationController.presentingViewController != nil
    }

    var currentTeamPlayerID: String? {
        GKLocalPlayer.local.isAuthenticated ? GKLocalPlayer.local.teamPlayerID : nil
    }

    var isMultiplayerGamingRestricted: Bool { GKLocalPlayer.local.isMultiplayerGamingRestricted }

    var authenticationChanges: AnyPublisher<Void, Never> {
        NotificationCenter.default.publisher(for: .GKPlayerAuthenticationDidChangeNotificationName)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func isAuthenticated(expectedTeamPlayerID: String) -> Bool {
        GKLocalPlayer.local.isAuthenticated && GKLocalPlayer.local.teamPlayerID == expectedTeamPlayerID
    }

    func authenticate() async throws -> PredictionGameCenterIdentity {
        try Task.checkCancellation()
        GKAccessPoint.shared.isActive = false
        if !GKLocalPlayer.local.isAuthenticated {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    authenticationContinuation = continuation
                    GKLocalPlayer.local.authenticateHandler = { [weak self] controller, error in
                        Task { @MainActor in
                            guard let self, self.authenticationContinuation != nil else { return }
                            if let controller {
                                guard let presenter = self.presenter() else {
                                    self.finishAuthentication(error: GameCenterError.presentationUnavailable)
                                    return
                                }
                                self.authenticationController = controller
                                CrashBreadcrumbs.record("present game_center_sign_in")
                                presenter.present(controller, animated: true)
                            } else if let error {
                                self.finishAuthentication(error: error)
                            } else if GKLocalPlayer.local.isAuthenticated {
                                self.finishAuthentication(error: nil)
                            } else {
                                self.finishAuthentication(error: GameCenterError.notAuthenticated)
                            }
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelAuthentication() }
            }
        }
        try Task.checkCancellation()
        let localPlayer = GKLocalPlayer.local
        guard localPlayer.isAuthenticated else { throw GameCenterError.notAuthenticated }
        let teamPlayerID = localPlayer.teamPlayerID
        let gamePlayerID = localPlayer.gamePlayerID
        let displayName = localPlayer.displayName
        let (publicKeyURL, signature, salt, timestamp) = try await localPlayer.fetchItemsForIdentityVerificationSignature()
        try Task.checkCancellation()
        guard isAuthenticated(expectedTeamPlayerID: teamPlayerID), localPlayer.gamePlayerID == gamePlayerID else {
            throw GameCenterError.accountChanged
        }
        return PredictionGameCenterIdentity(
            gamePlayerId: gamePlayerID,
            teamPlayerId: teamPlayerID,
            publicKeyUrl: publicKeyURL.absoluteString,
            signature: signature.base64EncodedString(),
            salt: salt.base64EncodedString(),
            timestamp: timestamp,
            displayName: displayName
        )
    }

    enum Operation { case connection, linking, dashboard, publication }

    /// A system welcome banner only confirms the Apple account. App recognition,
    /// verified account linking and progress publication can fail independently.
    static func statusMessage(
        for error: Error,
        operation: Operation,
        isSignedIn: Bool,
        hasLinkedPlayer: Bool
    ) -> String {
        let failure = error as NSError
        if failure.domain == GKErrorDomain {
            let account = isSignedIn ? "Your Game Center account is signed in, but " : ""
            switch GKError.Code(rawValue: failure.code) {
            case .gameUnrecognized:
                return account + "Game Center hasn’t recognised this version of Top Scores. Your predictions and progress remain available; Game Center sync and recovery are unavailable."
            case .notSupported:
                return account + (isSignedIn ? "this" : "This")
                    + " version of Top Scores doesn’t have Game Center enabled. Your predictions and progress remain available."
            default: break
            }
        }
        switch operation {
        case .publication:
            return "Your game progress is saved. Game Center could not update: \(error.localizedDescription)"
        case .dashboard:
            return "Game Center couldn’t open. Your game progress is unchanged. \(error.localizedDescription)"
        case .linking:
            let account = isSignedIn ? "Your Game Center account is signed in, but Top Scores" : "Top Scores"
            return account + " couldn’t link your game. Your predictions remain available. \(error.localizedDescription)"
        case .connection:
            if isSignedIn {
                return "Your Game Center account is signed in, but Top Scores couldn’t verify your game identity. Your predictions remain available. \(error.localizedDescription)"
            }
            if hasLinkedPlayer {
                return "Game Center is unavailable. Your linked game and progress are unchanged. \(error.localizedDescription)"
            }
            return "Playing as a guest. \(error.localizedDescription)"
        }
    }

    func cancelAuthentication() {
        authenticationController?.dismiss(animated: true)
        finishAuthentication(error: CancellationError())
    }

    func showLeaderboards(expectedTeamPlayerID: String, leaderboardID: String?) throws {
        try ensurePlayer(expectedTeamPlayerID)
        guard let leaderboardID, !leaderboardID.isEmpty else { throw GameCenterError.leaderboardUnavailable }
        guard let presenter = presenter() else { throw GameCenterError.presentationUnavailable }
        GKAccessPoint.shared.isActive = false
        let controller = GKGameCenterViewController(
            leaderboardID: leaderboardID, playerScope: .friendsOnly, timeScope: .allTime
        )
        controller.gameCenterDelegate = self
        CrashBreadcrumbs.record("present game_center_dashboard")
        presenter.present(controller, animated: true)
    }

    func showAchievements(expectedTeamPlayerID: String) throws {
        try presentDashboard(state: .achievements, expectedTeamPlayerID: expectedTeamPlayerID)
    }

    // Values come exclusively from the authenticated game API. A changed Game Center account
    // must be verified and linked again before it can receive this player's progress.
    func submit(_ submissions: PredictionGameCenterSubmissions, expectedTeamPlayerID: String) async throws {
        try ensurePlayer(expectedTeamPlayerID)
        for leaderboard in submissions.leaderboards {
            try Task.checkCancellation()
            try ensurePlayer(expectedTeamPlayerID)
            try await GKLeaderboard.submitScore(
                leaderboard.score, context: 0, player: GKLocalPlayer.local,
                leaderboardIDs: [leaderboard.id]
            )
        }
        try Task.checkCancellation()
        try ensurePlayer(expectedTeamPlayerID)
        let achievements = submissions.achievements.map { progress in
            let achievement = GKAchievement(identifier: progress.id)
            achievement.percentComplete = min(100, max(0, progress.percentComplete))
            achievement.showsCompletionBanner = false
            return achievement
        }
        if !achievements.isEmpty { try await GKAchievement.report(achievements) }
    }

    func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
        gameCenterViewController.dismiss(animated: true)
    }

    private func ensurePlayer(_ expectedTeamPlayerID: String) throws {
        guard isAuthenticated(expectedTeamPlayerID: expectedTeamPlayerID) else {
            throw GameCenterError.notAuthenticated
        }
    }

    private func presentDashboard(state: GKGameCenterViewControllerState, expectedTeamPlayerID: String) throws {
        try ensurePlayer(expectedTeamPlayerID)
        guard let presenter = presenter() else { throw GameCenterError.presentationUnavailable }
        GKAccessPoint.shared.isActive = false
        let controller = GKGameCenterViewController(state: state)
        controller.gameCenterDelegate = self
        CrashBreadcrumbs.record("present game_center_dashboard")
        presenter.present(controller, animated: true)
    }

    private func finishAuthentication(error: Error?) {
        guard let continuation = authenticationContinuation else { return }
        authenticationContinuation = nil
        // Do not let a later system sign-in change display UI outside the game flow.
        GKLocalPlayer.local.authenticateHandler = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    private func presenter() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }
}

private nonisolated enum GameCenterError: LocalizedError {
    case notAuthenticated
    case presentationUnavailable
    case accountChanged
    case leaderboardUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Game Center sign-in is unavailable. Sign-in is automatic when you open Beat the AI."
        case .presentationUnavailable: "Game Center cannot open right now. Please try again from Beat the AI."
        case .leaderboardUnavailable: "This competition’s friends leaderboard is not available yet."
        case .accountChanged: "Game Center account changed while signing in. Your current game is unchanged."
        }
    }
}
