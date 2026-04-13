import Foundation
import OSLog

enum PerformanceSignposter {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dev.skynolimit.topscores"
    private static func makeSignposter(category: String) -> OSSignposter {
        #if DEBUG
        OSSignposter(
            logger: Logger(subsystem: subsystem, category: category)
        )
        #else
        OSSignposter.disabled
        #endif
    }

    nonisolated static let startup = makeSignposter(category: "performance.startup")
    nonisolated static let matches = makeSignposter(category: "performance.matches")
    nonisolated static let fantasy = makeSignposter(category: "performance.fantasy")
    nonisolated static let liveActivity = makeSignposter(category: "performance.liveActivity")
    nonisolated static let preferences = makeSignposter(category: "performance.preferences")
}
