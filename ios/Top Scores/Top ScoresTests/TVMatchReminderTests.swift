import XCTest
@testable import Top_Scores

@MainActor
final class TVMatchReminderTests: XCTestCase {
    func testDefaultsAndPersistence() throws {
        let suite = "TVMatchReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(userDefaults: defaults)
        XCTAssertTrue(store.tvMatchRemindersEnabled)
        XCTAssertEqual(store.tvMatchReminderMinimumScore, 70)
        XCTAssertEqual(store.tvMatchReminderMinutes, 10)
        store.tvMatchRemindersEnabled = false
        store.tvMatchReminderMinimumScore = 85
        store.tvMatchReminderMinutes = 30
        let reloaded = PreferencesStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.tvMatchRemindersEnabled)
        XCTAssertEqual(reloaded.tvMatchReminderMinimumScore, 85)
        XCTAssertEqual(reloaded.tvMatchReminderMinutes, 30)
        let data = try JSONEncoder().encode(store.snapshot)
        let decoded = try JSONDecoder().decode(PreferencesSnapshot.self, from: data)
        XCTAssertFalse(decoded.tvMatchRemindersEnabled)
        XCTAssertEqual(decoded.tvMatchReminderMinimumScore, 85)
        XCTAssertEqual(decoded.tvMatchReminderMinutes, 30)
    }

    func testOldSnapshotsDefaultToHighlyWatchableReminders() throws {
        let suite = "TVMatchReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try JSONEncoder().encode(PreferencesStore(userDefaults: defaults).snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["tvMatchRemindersEnabled", "tvMatchReminderMinimumScore", "tvMatchReminderMinutes"] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(PreferencesSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.tvMatchRemindersEnabled)
        XCTAssertEqual(decoded.tvMatchReminderMinimumScore, 70)
        XCTAssertEqual(decoded.tvMatchReminderMinutes, 10)
    }

    func testNotificationTargetRetainsMatchIDsAndKickoffDate() throws {
        let payload: [AnyHashable: Any] = ["type": "tv_match_reminder", "matchIDs": ["bsd_1", "bsd_2"], "kickoffAt": "2026-10-25T23:55:00.000Z"]
        let target = try XCTUnwrap(TVReminderTarget(userInfo: payload))
        XCTAssertEqual(target.matchIDs, ["bsd_1", "bsd_2"])
        XCTAssertEqual(target.kickoff.timeIntervalSince1970, 1792972500)
        XCTAssertNil(TVReminderTarget(userInfo: ["type": "goal"]))
        XCTAssertNil(TVReminderTarget(userInfo: ["type": "tv_match_reminder", "matchIDs": [], "kickoffAt": "invalid"]))
    }
}
