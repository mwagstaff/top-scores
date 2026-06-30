import Combine
import Foundation

/// Cross-tab navigation request: jump to the Tables tab with a specific
/// league/team pre-selected. ContentView switches tabs on a new request;
/// TablesView consumes it (selects the league, scrolls to + highlights the
/// team's row) and clears it.
@MainActor
final class TablesNavigationCoordinator: ObservableObject {
    static let shared = TablesNavigationCoordinator()

    struct Target: Equatable {
        let leagueID: String
        let teamName: String
    }

    @Published private(set) var pendingTarget: Target?

    // The tab the user was on when they tapped a league position chip, so
    // TablesView can offer a small "Back to match" affordance. ContentView
    // stashes this (before switching tabs) and consumes it again when the
    // user taps that affordance.
    @Published private(set) var returnTabIndex: Int?
    // Incremented when the user taps "Back to match" — ContentView observes
    // this (rather than returnTabIndex directly) so it fires even if the
    // return tab index is unchanged from last time.
    @Published private(set) var returnRequestToken: Int = 0

    private init() {}

    func navigate(leagueID: String, teamName: String) {
        pendingTarget = Target(leagueID: leagueID, teamName: teamName)
    }

    func consumeTarget() -> Target? {
        defer { pendingTarget = nil }
        return pendingTarget
    }

    func setReturnTabIndex(_ index: Int) {
        returnTabIndex = index
    }

    func consumeReturnTabIndex() -> Int? {
        defer { returnTabIndex = nil }
        return returnTabIndex
    }

    func requestReturnToMatch() {
        returnRequestToken += 1
    }
}
