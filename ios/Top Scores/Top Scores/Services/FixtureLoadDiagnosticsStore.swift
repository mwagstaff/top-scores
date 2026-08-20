import Foundation
import Combine

struct FixtureLoadDiagnosticEntry: Identifiable, Equatable {
    let id = UUID()
    let recordedAt: Date
    let title: String
    let summary: String
}

@MainActor
final class FixtureLoadDiagnosticsStore: ObservableObject {
    static let shared = FixtureLoadDiagnosticsStore()

    @Published private(set) var entries: [FixtureLoadDiagnosticEntry] = []

    private let maximumEntries = 40

    private init() {}

    func record(
        title: @autoclosure () -> String,
        summary: @autoclosure () -> String,
        recordedAt: Date = Date()
    ) {
        #if DEBUG
        let entry = FixtureLoadDiagnosticEntry(
            recordedAt: recordedAt,
            title: title(),
            summary: summary()
        )
        entries.insert(entry, at: 0)
        if entries.count > maximumEntries {
            entries.removeLast(entries.count - maximumEntries)
        }
        diagnosticLog("[FixtureLoadDebug] %@ %@", entry.title, entry.summary)
        #endif
    }

    func clear() {
        entries.removeAll()
    }
}
