import XCTest
import SwiftUI
@testable import Top_Scores

@MainActor
final class MatchMomentumRenderingTests: XCTestCase {
    func testChartInDarkLightAndLargeText() throws {
        // A deterministic chart with both sides, extra time, missing coverage
        // and colliding markers provides a repeatable visual acceptance fixture.
        let momentum = MatchMomentum(status: "available", segments: [
            .init(id: "home", side: "home", points: [.init(minute: 1, value: 0), .init(minute: 8, value: 75), .init(minute: 19, value: 30), .init(minute: 30, value: 0)]),
            .init(id: "away", side: "away", points: [.init(minute: 31, value: 0), .init(minute: 40, value: -90), .init(minute: 45.5, value: -30)]),
            .init(id: "home2", side: "home", points: [.init(minute: 46, value: 0), .init(minute: 80, value: 60), .init(minute: 90.5, value: 10)]),
            .init(id: "away2", side: "away", points: [.init(minute: 91, value: -20), .init(minute: 106, value: -60), .init(minute: 120.5, value: 0)]),
        ], annotations: [
            .init(id: "1", minute: 8, time: "8′", side: "home", kind: "goal", label: "Goal · Home player"),
            .init(id: "2", minute: 90.5, time: "90+3′", side: "home", kind: "goal", label: "Goal · Home player"),
            .init(id: "3", minute: 90.5, time: "90+5′", side: "home", kind: "red_card", label: "Red card · Home player"),
            .init(id: "4", minute: 40, time: "40′", side: "away", kind: "penalty_missed", label: "Missed penalty · Away player"),
            .init(id: "5", minute: 106, time: "106′", side: "away", kind: "disallowed_goal", label: "Goal disallowed · Away player"),
        ], endMinute: 120.5, scale: 100,
        ticks: [.init(minute: 0, label: "0′"), .init(minute: 45.5, label: "HT"), .init(minute: 90.5, label: "90′"), .init(minute: 105.5, label: "105′"), .init(minute: 120.5, label: "FT")],
        updatedAt: nil, refreshAfterSeconds: nil)
        for (name, scheme, size) in [("dark", ColorScheme.dark, DynamicTypeSize.large), ("light", .light, .large), ("large-text", .dark, .accessibility3)] {
            let content = MatchMomentumCard(momentum: momentum, homeTeam: "Arsenal", awayTeam: "Manchester United", isLive: false)
                .padding(16).frame(width: 390)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme).dynamicTypeSize(size)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, 390)
            let attachment = XCTAttachment(image: image)
            attachment.name = "momentum-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
