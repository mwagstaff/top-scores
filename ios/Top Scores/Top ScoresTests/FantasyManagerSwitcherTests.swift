import SwiftUI
import Testing
@testable import Top_Scores

@MainActor
struct FantasyManagerSwitcherTests {
    @Test func managerInitialsIncludeAllThreeNames() {
        #expect(fantasyManagerInitials("Jose Olivares Chandler") == "JOC")
        #expect(fantasyManagerInitials("Matthew Wagstaff") == "MW")
        #expect(fantasyManagerInitials("  José  Olivares-Chandler ") == "JOC")
        #expect(fantasyManagerInitials("Matthew") == "MA")
        #expect(fantasyManagerInitials(" ") == "?")
    }

    @Test func ownTeamComesFirstAndRivalsSortByScoreWithUnknownLast() {
        let own = entry(1, name: "Matthew Wagstaff", score: 2, isUser: true)
        let firstRival = entry(2, name: "Jose Olivares Chandler", score: 110)
        let secondRival = entry(3, name: "Alex King", score: nil)
        let ordered = fantasyManagerSwitcherEntries(
            [firstRival, secondRival, own], rivalEntryIDs: [3, 2, 2, 1, 99]
        )
        #expect(ordered.map(\.entryID) == [1, 2, 3])
        #expect(ordered[2].currentGameweekScore == nil)
        let refreshed = fantasyManagerSwitcherEntries(
            [own, secondRival, firstRival], rivalEntryIDs: [3, 2]
        )
        #expect(refreshed.map(\.entryID) == ordered.map(\.entryID))
    }

    @Test func refreshedScoresReorderRivalsAndTiesKeepSavedOrder() {
        let own = entry(1, name: "Own", score: -5, isUser: true)
        let entries = [own, entry(2, name: "Second", score: 10), entry(3, name: "Third", score: 10), entry(4, name: "Fourth", score: -2), entry(5, name: "Unknown", score: nil)]
        #expect(fantasyManagerSwitcherEntries(entries, rivalEntryIDs: [3, 2, 5, 4]).map(\.entryID) == [1, 3, 2, 4, 5])
        let updated = [own, entry(2, name: "Second", score: 15), entries[2], entries[3], entries[4]]
        #expect(fantasyManagerSwitcherEntries(updated, rivalEntryIDs: [3, 2, 5, 4]).map(\.entryID) == [1, 2, 3, 4, 5])
    }

    @Test func renderCompactAndAccessibilitySwitcherStates() async throws {
        let entries = [
            entry(1, name: "Matthew Wagstaff", score: 108, isUser: true),
            entry(2, name: "Jose Olivares Chandler", score: 64),
            entry(3, name: "Alex King", score: nil),
            entry(4, name: "Sam Jones", score: -2)
        ]
        for (label, size, selection) in [
            ("own", DynamicTypeSize.large, 1),
            ("rival", DynamicTypeSize.large, 2),
            ("accessibility", DynamicTypeSize.accessibility3, 2)
        ] {
            let view = FantasyManagerSwitcher(
                entries: entries, selectedEntryID: selection, gameweekID: 11,
                staleEntryIDs: [2], select: { _ in }, addRival: {}
            )
            .padding(14)
            .frame(width: 375)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, size)
            let host = UIHostingController(rootView: view)
            host.safeAreaRegions = []
            let size = host.sizeThatFits(in: CGSize(width: 375, height: 1000))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            #expect(image.size.width == 375)
            #expect(image.size.height >= 100)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("fpl-switcher-validation", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(image.pngData()).write(to: directory.appendingPathComponent("\(label).png"))
            print("FPL switcher render: \(directory.path)/\(label).png")
        }
    }

    @Test func renderPlayerCardsAtStandardAndAccessibilitySizes() async throws {
        for (label, typeSize) in [("players", DynamicTypeSize.large), ("players-accessibility", DynamicTypeSize.accessibility3)] {
            let view = HStack(alignment: .top, spacing: 8) {
                FantasyPlayerCard(player: player(name: "Gabriel", points: 8, live: false), width: 72, detailMode: .opponent, scorePhase: .provisional)
                FantasyPlayerCard(player: player(name: "De Cuyper", points: 6, live: true), width: 72, detailMode: .opponent, scorePhase: .provisional)
                FantasyPlayerCard(player: player(name: "Haaland", points: 12, live: true, captain: true), width: 72, detailMode: .opponent, scorePhase: .provisional)
                FantasyPlayerCard(player: player(name: "Manzambi", points: 0, live: false, started: false), width: 72, detailMode: .opponent, scorePhase: .provisional)
            }
            .padding(14)
            .background(Color(red: 0.03, green: 0.22, blue: 0.14))
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, typeSize)
            let host = UIHostingController(rootView: view)
            host.safeAreaRegions = []
            let size = host.sizeThatFits(in: CGSize(width: 375, height: 1000))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            #expect(size.width <= 375)
            #expect(size.height >= 146)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fpl-switcher-validation")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(image.pngData()).write(to: directory.appendingPathComponent("\(label).png"))
            print("FPL player render: \(directory.path)/\(label).png")
        }
    }

    private func player(name: String, points: Int, live: Bool, captain: Bool = false, started: Bool = true) -> FantasyDisplayPlayer {
        FantasyDisplayPlayer(
            elementID: 1, pickPosition: 1, positionType: .defender,
            displayName: name, fullName: name, teamName: "Arsenal", profileImageURL: nil,
            nowCostMillions: 5, hasStartedCurrentSeason: true, ownershipPercent: nil,
            ownershipCount: nil, form: nil, pointsPerMatch: nil, totalPoints: nil, averageMinutes: nil,
            rawPoints: points, appliedPoints: points, displayPoints: points, multiplier: captain ? 2 : 1,
            isCaptain: captain, isViceCaptain: false, isPlayingNow: live, isUnavailable: false,
            isDefinitelyUnavailable: false, hasAnyFixtureThisGameweek: true,
            hasStartedFixtureThisGameweek: started, hasUpcomingFixtureThisGameweek: !started,
            hasActiveFixtureThisGameweek: live, hasFutureAvailabilityIssue: false,
            futureAvailabilityIssueGameweek: nil, minutesPlayed: started ? 60 : 0,
            upcomingOpponentDisplay: "HUL (H)", fixtureDifficulty: 2, nextFiveFixtureDifficulties: [],
            expectedPointsThisGameweek: nil, officialExpectedPointsNextGameweek: nil,
            goalsScored: live ? 1 : 0, assists: 0, yellowCards: live ? 1 : 0, redCards: 0
        )
    }

    private func entry(_ id: Int, name: String, score: Int?, isUser: Bool = false) -> FantasyLeagueTableEntry {
        FantasyLeagueTableEntry(
            entryID: id, teamName: "Team \(id)", managerName: name,
            currentGameweekScore: score, allGameweeksScore: nil,
            projectedGameweekPoints: nil, isExpectedPointsLoading: false,
            hasActiveChipInCurrentGameweek: false, activeBadgeChip: nil,
            hasPlayerInPlay: false, squad: nil, clubBadgeSrc: nil, isUser: isUser
        )
    }
}
