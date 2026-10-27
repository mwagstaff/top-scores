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

    @Test func tvFeedsKeepIndependentWatchabilityFilters() throws {
        let feedURL = try #require(URL(string: "https://example.com/calendar-subscriptions/abc.ics"))
        for (feed, minimum) in [(PersonalCalendarFeed.tvMustWatch, "85"), (.tvHighlyWatchable, "70"), (.tvWatchable, "55"), (.tvAll, "0")] {
            let url = try #require(PersonalCalendarSubscriptionService.webcalURL(from: feedURL, feed: feed))
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(url.scheme == "webcal")
            #expect(url.path == feedURL.path)
            #expect(components.queryItems == [URLQueryItem(name: "type", value: "tv"), URLQueryItem(name: "minimumScore", value: minimum)])
        }
        #expect(PersonalCalendarSubscriptionService.webcalURL(from: feedURL)?.query == nil)
    }

    @Test func rejectsNonNetworkCalendarURLs() {
        let fileURL = URL(fileURLWithPath: "/tmp/top-scores.ics")
        #expect(PersonalCalendarSubscriptionService.webcalURL(from: fileURL) == nil)
    }
}
