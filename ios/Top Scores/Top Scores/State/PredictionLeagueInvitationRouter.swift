import Combine
import Foundation

/// Links only open the invitation preview. Membership changes require a verified session and Join.
@MainActor
final class PredictionLeagueInvitationRouter: ObservableObject {
    static let shared = PredictionLeagueInvitationRouter()

    struct Invitation: Identifiable, Hashable {
        let id = UUID()
        let code: String
    }

    @Published var pendingInvitation: Invitation?

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let code = Self.invitationCode(in: url) else { return false }
        pendingInvitation = Invitation(code: code)
        return true
    }

    nonisolated static func invitationCode(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else { return nil }

        let path: String
        switch (components.scheme?.lowercased(), components.host?.lowercased()) {
        case ("https", "top-scores.skynolimit.dev"):
            guard components.percentEncodedPath.hasPrefix("/invite/") else { return nil }
            path = String(components.percentEncodedPath.dropFirst("/invite/".count))
        case ("topscores", "invite"):
            guard components.percentEncodedPath.hasPrefix("/") else { return nil }
            path = String(components.percentEncodedPath.dropFirst())
        default:
            return nil
        }
        // Reject escaped separators, alternate hosts and extra path components.
        let code = path.uppercased()
        guard code.range(of: "^[A-HJ-NP-Z2-9]{12}$", options: .regularExpression) != nil else { return nil }
        return code
    }
}
