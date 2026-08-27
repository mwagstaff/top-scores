import Foundation
import Testing
@testable import Top_Scores

struct PersonalCalendarSubscriptionTests {
    @Test func convertsHTTPSFeedURLToWebcalWithoutChangingTheBearerPath() throws {
        let feedURL = try #require(
            URL(string: "https://api.skynolimit.dev/top-scores/api/v1/calendar-subscriptions/abc_123.ics")
        )
        let subscriptionURL = try #require(
            PersonalCalendarSubscriptionService.webcalURL(from: feedURL)
        )

        #expect(subscriptionURL.scheme == "webcal")
        #expect(subscriptionURL.host == feedURL.host)
        #expect(subscriptionURL.path == feedURL.path)
    }

    @Test func rejectsNonNetworkCalendarURLs() {
        let fileURL = URL(fileURLWithPath: "/tmp/top-scores.ics")
        #expect(PersonalCalendarSubscriptionService.webcalURL(from: fileURL) == nil)
    }
}
