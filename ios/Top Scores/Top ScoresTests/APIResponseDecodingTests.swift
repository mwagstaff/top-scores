import Foundation
import Testing
@testable import Top_Scores

struct APIResponseDecodingTests {
    @MainActor
    @Test func responseDecodingDoesNotRunOnTheMainThread() async throws {
        let value = try await APIClient.decodeResponse(
            DecodingThreadProbe.self,
            from: Data(#"{"value":42}"#.utf8),
            operation: "decoding_thread_test"
        )

        #expect(value.value == 42)
        #expect(!value.decodedOnMainThread)
    }

    @MainActor
    @Test func cancelledResponseDoesNotDeliverDecodedData() async {
        let task = Task { @MainActor in
            try await APIClient.decodeResponse(
                [String].self,
                from: Data(#"["cached"]"#.utf8),
                operation: "cancelled_decode_test"
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @MainActor
    @Test func malformedResponseStillReportsADecodingError() async {
        await #expect(throws: DecodingError.self) {
            try await APIClient.decodeResponse(
                [String].self,
                from: Data(#"{"unexpected":"object"}"#.utf8),
                operation: "malformed_decode_test"
            )
        }
    }
}

private struct DecodingThreadProbe: Decodable, Sendable {
    let value: Int
    let decodedOnMainThread: Bool

    private enum CodingKeys: String, CodingKey {
        case value
    }

    nonisolated init(from decoder: Decoder) throws {
        value = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .value)
        decodedOnMainThread = Thread.isMainThread
    }
}
