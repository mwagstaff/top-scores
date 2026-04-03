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

    func record(title: String, summary: String, recordedAt: Date = Date()) {
        let entry = FixtureLoadDiagnosticEntry(
            recordedAt: recordedAt,
            title: title,
            summary: summary
        )
        entries.insert(entry, at: 0)
        if entries.count > maximumEntries {
            entries.removeLast(entries.count - maximumEntries)
        }
        NSLog("[FixtureLoadDebug] %@ %@", title, summary)
    }

    func clear() {
        entries.removeAll()
    }
}
