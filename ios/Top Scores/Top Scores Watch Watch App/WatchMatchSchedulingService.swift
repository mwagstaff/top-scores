import Foundation

enum WatchMatchSchedulingError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Calendar and reminders are unavailable on this watch."
        }
    }
}

final class WatchMatchSchedulingService {
    static let shared = WatchMatchSchedulingService()

    var canAddCalendarEvent: Bool { false }
    var canAddReminder: Bool { false }

    private init() {}

    func addEvent(for match: WatchMatch) async throws {
        throw WatchMatchSchedulingError.unavailable
    }

    func addReminder(for match: WatchMatch, leadTime: TimeInterval = 30 * 60) async throws {
        throw WatchMatchSchedulingError.unavailable
    }
}
