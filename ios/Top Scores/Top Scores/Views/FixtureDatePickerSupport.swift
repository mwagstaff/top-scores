import SwiftUI
import UIKit

struct FixtureAvailableDatePicker: UIViewRepresentable {
    @Binding var selection: Date
    let availableDateKeys: Set<String>
    let dateRange: ClosedRange<Date>

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, availableDateKeys: availableDateKeys)
    }

    func makeUIView(context: Context) -> UICalendarView {
        let calendarView = UICalendarView()
        calendarView.calendar = .current
        calendarView.locale = .current
        calendarView.timeZone = .current
        calendarView.tintColor = UIColor(Color.accentColor)
        calendarView.availableDateRange = availableDateInterval

        let dateSelection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        calendarView.selectionBehavior = dateSelection
        updateSelection(dateSelection, in: calendarView, animated: false)
        return calendarView
    }

    func updateUIView(_ calendarView: UICalendarView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.availableDateKeys = availableDateKeys
        calendarView.availableDateRange = availableDateInterval

        guard let dateSelection = calendarView.selectionBehavior
            as? UICalendarSelectionSingleDate else {
            return
        }
        updateSelection(dateSelection, in: calendarView, animated: false)
    }

    private var availableDateInterval: DateInterval {
        let calendar = Calendar.current
        let endOfLastDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: dateRange.upperBound)
        )?.addingTimeInterval(-1) ?? dateRange.upperBound
        return DateInterval(
            start: calendar.startOfDay(for: dateRange.lowerBound),
            end: endOfLastDay
        )
    }

    private func updateSelection(
        _ dateSelection: UICalendarSelectionSingleDate,
        in calendarView: UICalendarView,
        animated: Bool
    ) {
        let calendar = Calendar.current
        let selectedComponents = calendar.dateComponents(
            [.calendar, .era, .year, .month, .day],
            from: selection
        )
        guard Coordinator.dateKey(from: dateSelection.selectedDate) !=
                Coordinator.dateKey(from: selectedComponents) else {
            return
        }
        dateSelection.setSelected(selectedComponents, animated: animated)
        calendarView.setVisibleDateComponents(selectedComponents, animated: animated)
    }

    @MainActor
    final class Coordinator: NSObject, UICalendarSelectionSingleDateDelegate {
        var selection: Binding<Date>
        var availableDateKeys: Set<String>

        init(selection: Binding<Date>, availableDateKeys: Set<String>) {
            self.selection = selection
            self.availableDateKeys = availableDateKeys
        }

        func dateSelection(
            _ selection: UICalendarSelectionSingleDate,
            canSelectDate dateComponents: DateComponents?
        ) -> Bool {
            guard let dateKey = Self.dateKey(from: dateComponents) else { return false }
            return availableDateKeys.contains(dateKey)
        }

        func dateSelection(
            _ dateSelection: UICalendarSelectionSingleDate,
            didSelectDate dateComponents: DateComponents?
        ) {
            guard let dateComponents,
                  let dateKey = Self.dateKey(from: dateComponents),
                  availableDateKeys.contains(dateKey),
                  let date = Calendar.current.date(from: dateComponents) else {
                return
            }
            selection.wrappedValue = date
        }

        static func dateKey(from components: DateComponents?) -> String? {
            guard let year = components?.year,
                  let month = components?.month,
                  let day = components?.day else {
                return nil
            }
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
    }
}

enum FixtureCalendarCompetitionColor {
    static func color(competitionID: String, competitionName: String) -> Color {
        switch CompetitionAccentRole.resolve(
            competitionID: competitionID,
            competitionName: competitionName
        ) {
        case .bundesliga:
            return Color(red: 0.12, green: 0.48, blue: 0.96)
        case .standard:
            let key = competitionID.isEmpty ? competitionName : competitionID
            let hueDegrees = key.utf8.reduce(0) { partialResult, byte in
                ((partialResult * 31) + Int(byte)) % 360
            }
            return Color(
                hue: Double(hueDegrees) / 360,
                saturation: 0.78,
                brightness: 0.84
            )
        case let role:
            return role.color
        }
    }
}
