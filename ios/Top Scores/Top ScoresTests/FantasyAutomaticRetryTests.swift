import Foundation
import Testing
@testable import Top_Scores

struct FantasyAutomaticRetryTests {
    @Test func serviceUnavailableIsRetriedWithoutShowingTechnicalDetails() {
        let error = APIClientError.badStatus(
            statusCode: 503,
            url: "https://example.test/fantasy/bootstrap/lookup",
            bodySnippet: #"{"error":"Fantasy bootstrap-static dataset not loaded yet."}"#
        )

        #expect(fantasyLoadFailureShouldAutomaticallyRetry(error))
        #expect(fantasyUserFriendlyLoadErrorMessage(for: error) == fantasyTemporaryUnavailableUserMessage)
        #expect(!fantasyUserFriendlyLoadErrorMessage(for: error).contains("503"))
        #expect(!fantasyUserFriendlyLoadErrorMessage(for: error).contains("https://"))
    }

    @Test func authenticationFailureIsNotAutomaticallyRetried() {
        #expect(!fantasyLoadFailureShouldAutomaticallyRetry(
            FantasyPublicAPIError.authenticationRequired
        ))
    }

    @Test func connectionFailureIsAutomaticallyRetried() {
        #expect(fantasyLoadFailureShouldAutomaticallyRetry(
            URLError(.networkConnectionLost)
        ))
    }

    @Test func retryDelayUsesExponentialBackoffAndCapsAtOneMinute() {
        #expect(fantasyAutomaticRetryDelay(forAttempt: 0, jitter: 0.5) == 3)
        #expect(fantasyAutomaticRetryDelay(forAttempt: 1, jitter: 0.5) == 6)
        #expect(fantasyAutomaticRetryDelay(forAttempt: 2, jitter: 0.5) == 12)
        #expect(fantasyAutomaticRetryDelay(forAttempt: 8, jitter: 0.5) == 60)
    }

    @Test func retryJitterRemainsWithinExpectedBounds() {
        let shortest = fantasyAutomaticRetryDelay(forAttempt: 0, jitter: -1)
        let longest = fantasyAutomaticRetryDelay(forAttempt: 0, jitter: 2)

        #expect(abs(shortest - 2.55) < 0.000_001)
        #expect(abs(longest - 3.45) < 0.000_001)
    }
}
