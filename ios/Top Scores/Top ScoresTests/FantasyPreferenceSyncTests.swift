import Testing
import Foundation
@testable import Top_Scores

@MainActor
struct FantasyPreferenceSyncTests {
    @Test func sceneBrowsingActivityRetainsPairingUntilTheViewConsumesIt() {
        let inbox = FantasyPairingInbox.shared
        inbox.pendingURL = nil
        defer { inbox.pendingURL = nil }
        let url = URL(string: "https://top-scores.skynolimit.dev/fpl/connect#pair=\(String(repeating: "a", count: 43))")!
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        PairingSceneDelegate.receive(activity, source: "test")
        #expect(inbox.pendingURL == url)
        let unrelated = NSUserActivity(activityType: "example.handoff")
        unrelated.webpageURL = URL(string: "https://example.com")!
        PairingSceneDelegate.receive(unrelated, source: "test")
        #expect(inbox.pendingURL == url)
        // Duplicate SwiftUI delivery must retain the same pending request.
        inbox.receive(url, source: "test")
        #expect(inbox.pendingURL == url)
        inbox.pendingURL = nil
        #expect(inbox.pendingURL == nil)
    }

    @Test func pairingLinksAcceptOnlyTheExpectedOriginAndFormat() {
        let secret = String(repeating: "a", count: 43)
        #expect(FantasyPairingURL.secret(from: URL(string: "https://top-scores.skynolimit.dev/fpl/connect#pair=\(secret)")!) == secret)
        #expect(FantasyPairingURL.secret(from: URL(string: "topscores://fpl-connect#pair=\(secret)")!) == secret)
        for value in [
            "https://evil.test/fpl/connect#pair=\(secret)",
            "https://top-scores.skynolimit.dev.evil.test/fpl/connect#pair=\(secret)",
            "http://top-scores.skynolimit.dev/fpl/connect#pair=\(secret)",
            "https://top-scores.skynolimit.dev/fpl/connect?pair=\(secret)",
            "https://user@top-scores.skynolimit.dev/fpl/connect#pair=\(secret)",
            "https://top-scores.skynolimit.dev:443/fpl/connect#pair=\(secret)",
            "topscores://other#pair=\(secret)",
            "topscores://fpl-connect#pair=short",
            "topscores://fpl-connect#pair=\(secret)&extra=true"
        ] { #expect(FantasyPairingURL.secret(from: URL(string: value)!) == nil) }
    }
    @Test func emptyManagerEncodesAsNull() throws {
        let preferences = FantasySyncedPreferences(manager: nil, rivals: [], leagues: [])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as! [String: Any]
        #expect(json["manager"] is NSNull)
    }

    @Test func syncedPreferencesPreserveRivalDetailsAndOrder() throws {
        let suite = "FantasySyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = FantasyRivalManager(entryID: 2, teamName: "Existing team", managerFirstName: "Alex", managerLastName: "Smith", overallPoints: 100, clubBadgeSrc: nil)
        defaults.set(String(decoding: try JSONEncoder().encode([existing]), as: UTF8.self), forKey: "fantasy.rivalManagersJSON")
        let preferences = FantasySyncedPreferences(manager: 1, rivals: [3, 2], leagues: [.init(id: 11, name: "Work"), .init(id: 10, name: "Friends")])
        preferences.apply(defaults: defaults)
        #expect(FantasySyncedPreferences.local(defaults: defaults).hasSameSelection(as: preferences))
        let saved = try JSONDecoder().decode([FantasyRivalManager].self, from: Data(defaults.string(forKey: "fantasy.rivalManagersJSON")!.utf8))
        #expect(saved[1] == existing)
        #expect(saved[0].entryID == 3)
    }
}
