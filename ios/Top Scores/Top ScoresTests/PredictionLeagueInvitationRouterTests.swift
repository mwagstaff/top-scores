import XCTest
@testable import Top_Scores

@MainActor
final class PredictionLeagueInvitationRouterTests: XCTestCase {
    func testWebsiteAndNativeLinksOpenTheSamePreview() {
        for link in ["https://top-scores.skynolimit.dev/invite/ABCDEFGH2345", "topscores://invite/abcdefgh2345"] {
            let router = PredictionLeagueInvitationRouter()
            XCTAssertTrue(router.handle(URL(string: link)!))
            XCTAssertEqual(router.pendingInvitation?.code, "ABCDEFGH2345")
        }
    }

    func testUntrustedOrAmbiguousLinksCannotReplacePendingInvitation() {
        let router = PredictionLeagueInvitationRouter()
        router.handle(URL(string: "topscores://invite/ABCDEFGH2345")!)
        let original = router.pendingInvitation
        for link in [
            "http://top-scores.skynolimit.dev/invite/ABCDEFGH2345",
            "https://top-scores.skynolimit.dev.evil.example/invite/ABCDEFGH2345",
            "https://user@top-scores.skynolimit.dev/invite/ABCDEFGH2345",
            "https://top-scores.skynolimit.dev:444/invite/ABCDEFGH2345",
            "https://top-scores.skynolimit.dev/invite/ABCDEFGH2345?playerId=someone",
            "https://top-scores.skynolimit.dev/invite/ABCDEFGH2345#join",
            "https://top-scores.skynolimit.dev/invite/ABCDEFGH2345/members",
            "topscores://invite/ABCDEFGH23%34%35",
            "topscores://invite/ABCD0123IOL5",
            "topscores://other/ABCDEFGH2345",
        ] {
            XCTAssertFalse(router.handle(URL(string: link)!), link)
            XCTAssertEqual(router.pendingInvitation, original)
        }
    }

    func testRepeatedLinkGetsANewNavigationIdentity() {
        let router = PredictionLeagueInvitationRouter()
        let link = URL(string: "topscores://invite/ABCDEFGH2345")!
        router.handle(link)
        let first = router.pendingInvitation?.id
        router.handle(link)
        XCTAssertNotEqual(router.pendingInvitation?.id, first)
    }
}
