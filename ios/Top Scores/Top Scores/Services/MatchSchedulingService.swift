import EventKit
import Foundation

enum MatchSchedulingError: LocalizedError {
    case missingDate
    case calendarUnavailable
    case remindersUnavailable
    case accessDenied(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingDate:
            return "Match time is unavailable."
        case .calendarUnavailable:
            return "No default calendar is available."
        case .remindersUnavailable:
            return "No default reminders list is available."
        case .accessDenied(let message):
            return message
        case .saveFailed(let message):
            return message
        }
    }
}

final class MatchSchedulingService {
    static let shared = MatchSchedulingService()

    private let eventStore = EKEventStore()
    private let defaultMatchDuration: TimeInterval = 2 * 60 * 60
    private let defaults: UserDefaults

    var defaultEventCalendarIdentifier: String? {
        get { defaults.string(forKey: Keys.defaultEventCalendarIdentifier) }
        set { defaults.set(newValue, forKey: Keys.defaultEventCalendarIdentifier) }
    }

    private init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    func eventCalendars() async throws -> [EKCalendar] {
        try await ensureEventAccess()
        return eventStore
            .calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func addEvent(for match: Match, calendarIdentifier: String? = nil) async throws {
        guard let startDate = match.dateTime else {
            throw MatchSchedulingError.missingDate
        }

        try await ensureEventAccess()

        let calendar = calendarIdentifier.flatMap { eventStore.calendar(withIdentifier: $0) }
        let targetCalendar = calendar?.allowsContentModifications == true ? calendar : eventStore.defaultCalendarForNewEvents

        guard let targetCalendar else {
            throw MatchSchedulingError.calendarUnavailable
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = targetCalendar
        event.title = "\(match.homeTeam) vs \(match.awayTeam)"
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(defaultMatchDuration)
        event.notes = buildNotes(for: match)

        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            throw MatchSchedulingError.saveFailed("Unable to save calendar event.")
        }
    }

    func addReminder(for match: Match, leadTime: TimeInterval) async throws {
        guard let startDate = match.dateTime else {
            throw MatchSchedulingError.missingDate
        }

        try await ensureReminderAccess()

        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            throw MatchSchedulingError.remindersUnavailable
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = "\(match.homeTeam) vs \(match.awayTeam)"
        reminder.notes = buildNotes(for: match)
        reminder.dueDateComponents = Calendar.current.dateComponents([
            .year, .month, .day, .hour, .minute
        ], from: startDate)
        reminder.addAlarm(EKAlarm(relativeOffset: -leadTime))

        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            throw MatchSchedulingError.saveFailed("Unable to save reminder.")
        }
    }

    private func buildNotes(for match: Match) -> String {
        var lines: [String] = [match.league]
        if !match.tvChannels.isEmpty {
            lines.append("TV: \(match.tvChannels.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private func ensureEventAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .writeOnly, .authorized:
            return
        case .notDetermined:
            let granted = try await eventStore.requestWriteOnlyAccessToEvents()
            if !granted {
                throw MatchSchedulingError.accessDenied("Calendar access was denied.")
            }
        case .restricted, .denied:
            throw MatchSchedulingError.accessDenied("Calendar access is restricted or denied.")
        @unknown default:
            throw MatchSchedulingError.accessDenied("Calendar access is unavailable.")
        }
    }

    private func ensureReminderAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess, .writeOnly, .authorized:
            return
        case .notDetermined:
            let granted = try await eventStore.requestFullAccessToReminders()
            if !granted {
                throw MatchSchedulingError.accessDenied("Reminder access was denied.")
            }
        case .restricted, .denied:
            throw MatchSchedulingError.accessDenied("Reminder access is restricted or denied.")
        @unknown default:
            throw MatchSchedulingError.accessDenied("Reminder access is unavailable.")
        }
    }

    private enum Keys {
        static let defaultEventCalendarIdentifier = "preferences.defaultEventCalendarIdentifier"
    }
}
