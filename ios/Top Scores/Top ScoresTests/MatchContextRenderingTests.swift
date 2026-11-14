import XCTest
import SwiftUI
@testable import Top_Scores

@MainActor
final class MatchContextRenderingTests: XCTestCase {
    func testContextInDarkLightAndLargeText() throws {
        var meetings: [MatchHeadToHeadMeeting] = []
        for index in 0..<10 {
            let meeting = MatchHeadToHeadMeeting(eventID: String(index), matchID: index == 0 ? "42" : nil, date: "2026-10-01T15:00:00Z",
                homeTeam: "Arsenal", awayTeam: "Manchester United", homeTeamID: nil, awayTeamID: nil,
                homeScore: index == 9 ? nil : 2, awayScore: index == 9 ? nil : 1)
            meetings.append(meeting)
        }
        let history = MatchHeadToHead(totalMatches: 24, homeWins: 12, draws: 7, awayWins: 5, recentMatches: meetings)
        for (name, scheme, size) in [("dark", ColorScheme.dark, DynamicTypeSize.large), ("light", .light, .large), ("large-text", .dark, .accessibility3)] {
            let content = VStack(alignment: .leading, spacing: 16) {
                MatchPreviewSection(preview: .init(text: "Arsenal host Manchester United, with both sides looking to build on their recent form.\n\nThe midfield contest could decide this match.", generatedAt: nil))
                MatchLineupStatusBadge(status: "predicted")
                MatchLineupStatusBadge(status: "confirmed")
                MatchHeadToHeadSection(data: history, homeTeam: "Arsenal", awayTeam: "Manchester United")
                MatchFunFactsSection(facts: ["Both teams scored in their last three meetings."])
            }.padding(16).frame(width: 390)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme).dynamicTypeSize(size)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, 390)
            let attachment = XCTAttachment(image: image)
            attachment.name = "match-context-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
