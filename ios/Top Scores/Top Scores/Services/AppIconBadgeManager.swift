import Foundation
import UIKit
import UserNotifications

enum AppIconBadgeManager {
    private actor BadgeState {
        var lastAppliedCount: Int?

        func shouldApply(_ count: Int) -> Bool {
            if lastAppliedCount == count {
                return false
            }
            lastAppliedCount = count
            return true
        }
    }

    private static let badgeState = BadgeState()

    static func update(preferences: PreferencesSnapshot, matches: [Match]) async {
        guard preferences.showTodayUnfinishedFixturesBadge else {
            await clear()
            return
        }

        await setBadgeCount(unfinishedFixtureCount(for: matches))
    }

    static func clear() async {
        await setBadgeCount(0)
    }

    static func unfinishedFixtureCount(for matches: [Match], now: Date = Date()) -> Int {
        let calendar = Calendar.current
        return matches.reduce(into: 0) { count, match in
            guard let date = match.dateOnly, calendar.isDate(date, inSameDayAs: now) else { return }
            guard !match.isFinished else { return }
            count += 1
        }
    }

    private static func setBadgeCount(_ count: Int) async {
        guard await badgeState.shouldApply(count) else {
            return
        }

        if #available(iOS 16.0, *) {
            do {
                try await UNUserNotificationCenter.current().setBadgeCount(count)
            } catch {
                NSLog("[AppIconBadge] Failed to set badge count to %d: %@", count, error.localizedDescription)
            }
            return
        }

        await MainActor.run {
            UIApplication.shared.applicationIconBadgeNumber = count
        }
    }
}
