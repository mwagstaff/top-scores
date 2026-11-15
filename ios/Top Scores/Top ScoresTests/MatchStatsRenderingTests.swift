import XCTest
import SwiftUI
import UIKit
@testable import Top_Scores

@MainActor
final class MatchStatsRenderingTests: XCTestCase {
    func testStatsInDarkLightAndAccessibilityText() throws {
        let rows: [MatchStats.Row] = [
            .init(id: "ball_possession", label: "Possession", group: "Key stats", headline: true, home: 58, away: 42, homeDisplay: "58%", awayDisplay: "42%", homeEstimated: false, awayEstimated: false),
            .init(id: "xg", label: "Expected goals (xG)", group: "Key stats", headline: true, home: 1.84, away: 0.92, homeDisplay: "1.84", awayDisplay: "0.92", homeEstimated: true, awayEstimated: false),
            .init(id: "shots_on_target", label: "Shots on target", group: "Key stats", headline: true, home: 0, away: nil, homeDisplay: "0", awayDisplay: "—", homeEstimated: false, awayEstimated: false),
            .init(id: "fouls", label: "Fouls committed", group: "Discipline", headline: false, home: 12, away: 8, homeDisplay: "12", awayDisplay: "8", homeEstimated: false, awayEstimated: false),
        ]
        let stats = MatchStats(status: "available", periods: [.init(id: "all", label: "All", rows: rows),
            .init(id: "first_half", label: "1st half", rows: rows)], updatedAt: nil, refreshAfterSeconds: nil)
        for (name, scheme, size) in [("dark", ColorScheme.dark, DynamicTypeSize.large), ("light", .light, .large), ("large-text", .dark, .accessibility3)] {
            let content = MatchAnalysisCard(momentum: nil, stats: stats, homeTeam: "Brighton & Hove Albion", awayTeam: "Manchester United", isLive: false)
                .padding(16).frame(width: 390)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme).dynamicTypeSize(size)
            // ImageRenderer omits UIKit-backed segmented pickers. Host the view
            // in a real window so the native controls are part of visual QA.
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previousWindow = scene.keyWindow
            let controller = UIHostingController(rootView: content)
            controller.safeAreaRegions = []
            controller.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            let size = controller.sizeThatFits(in: CGSize(width: 390, height: 4000))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
            XCTAssertEqual(image.size.width, 390)
            let attachment = XCTAttachment(image: image)
            attachment.name = "match-stats-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
