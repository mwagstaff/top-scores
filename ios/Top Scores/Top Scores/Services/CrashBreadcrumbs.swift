import SwiftUI

/// A short rolling trail of screen/sheet events, forwarded with MetricKit crash reports on
/// a later launch. Crashes inside UIKit carry no app frames, so this names the screen.
/// UserDefaults is backed by cfprefsd, so entries written just before a crash survive it.
nonisolated enum CrashBreadcrumbs {
    private static let key = "diagnostics.crashBreadcrumbs"
    private static let maxEntries = 60
    private static let lock = NSLock()

    static func record(_ event: String) {
        let entry = "\(Date().formatted(.iso8601)) \(event)"
        lock.withLock {
            var entries = UserDefaults.standard.stringArray(forKey: key) ?? []
            entries.append(entry)
            UserDefaults.standard.set(Array(entries.suffix(maxEntries)), forKey: key)
        }
    }

    static func recent() -> [String] {
        lock.withLock { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    }
}

extension View {
    /// Records when a sheet/popover/cover driven by `isPresented` opens and closes.
    func crashBreadcrumb(_ name: String, isPresented: Bool) -> some View {
        onChange(of: isPresented) { _, presented in
            CrashBreadcrumbs.record("\(presented ? "present" : "dismiss") \(name)")
        }
    }
}
