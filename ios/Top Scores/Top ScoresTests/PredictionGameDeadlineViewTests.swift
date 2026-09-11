import SwiftUI
import Testing
import UIKit
@testable import Top_Scores

@Suite(.serialized)
@MainActor
struct PredictionGameDeadlineViewTests {
    @Test func futureSaturdayFixtureUsesCurrentTimeWhenThePillAppears() async throws {
        let now = Date()
        let kickoff = now.addingTimeInterval(3 * 24 * 60 * 60)
        let probe = DeadlineDateProbe()
        let window = makeWindow(deadline: kickoff, probe: probe)
        defer { window.isHidden = true }

        try await waitForDate(probe)
        let renderedDate = try #require(probe.dates.first)
        #expect(renderedDate < kickoff)
        #expect(abs(renderedDate.timeIntervalSince(now)) < 5)
        #expect(PredictionGameStore().canEdit(fixture: fixture(kickoff: kickoff), at: renderedDate))
    }

    @Test func displayedPillRefreshesWhenKickoffArrives() async throws {
        let kickoff = Date().addingTimeInterval(2)
        let probe = DeadlineDateProbe()
        let window = makeWindow(deadline: kickoff, probe: probe)
        defer { window.isHidden = true }

        try await waitForDate(probe)
        #expect(try #require(probe.dates.first) < kickoff)
        for _ in 0..<100 where probe.dates.last.map({ $0 < kickoff }) != false {
            try await Task.sleep(for: .milliseconds(50))
        }
        let renderedDate = try #require(probe.dates.last)
        #expect(renderedDate >= kickoff)
        #expect(!PredictionGameStore().canEdit(fixture: fixture(kickoff: kickoff), at: renderedDate))
    }

    private func makeWindow(deadline: Date, probe: DeadlineDateProbe) -> UIWindow {
        let content = PredictionGameDeadlineView(deadline: deadline) { date in
            Text(date.formatted())
                .onAppear { probe.dates.append(date) }
                .onChange(of: date) { _, value in probe.dates.append(value) }
        }
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        window.rootViewController = UIHostingController(rootView: content)
        window.isHidden = false
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }

    private func waitForDate(_ probe: DeadlineDateProbe) async throws {
        for _ in 0..<100 where probe.dates.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!probe.dates.isEmpty)
    }

    private func fixture(kickoff: Date) -> PredictionGameFixture {
        PredictionGameFixture(
            id: "123", homeTeam: "Liverpool", awayTeam: "Fulham",
            seasonId: "2026", seasonLabel: "2026/27", kickoffAt: kickoff,
            status: "notstarted", locked: false, settled: false, void: false,
            challengeId: nil,
            ai: PredictionGameAI(homeScore: 1, awayScore: 1, modelVersion: "v1", sourceRevision: "v1", frozenAt: nil),
            prediction: nil, result: nil
        )
    }
}

@MainActor
private final class DeadlineDateProbe {
    var dates: [Date] = []
}
