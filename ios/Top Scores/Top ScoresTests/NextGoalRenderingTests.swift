import SwiftUI
import XCTest
@testable import Top_Scores

@MainActor
final class NextGoalRenderingTests: XCTestCase {
    func testNarrowPhoneInLightDarkAndAccessibilitySizes() throws {
        let goal = NextGoal(status: .available, message: nil, score: .init(home: 0, away: 0), minute: 66,
                            probabilities: .init(home: 0.35, no_goal: 0.4, away: 0.25),
                            evidence: .init(shots_home_10m: 2, shots_away_10m: 1), calls: nil,
                            lastSeenAt: nil, refreshAfterSeconds: 30)
        for (name, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large),
                                     ("dark", .dark, .large), ("large-type", .dark, .accessibility3)] {
            let content = NextGoalCard(goal: goal, homeTeam: "Manchester City", awayTeam: "Fulham")
                .padding(12).frame(width: 320)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme).dynamicTypeSize(size)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, 320)
            let attachment = XCTAttachment(image: image)
            attachment.name = "next-goal-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
