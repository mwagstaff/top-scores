import Testing
@testable import Top_Scores

struct PreferencesSyncOrderingTests {
    @Test func scoresOrderingSettingsAreUploaded() {
        for premierLeagueMatchesFirst in [true, false] {
            let snapshot = PreferencesSnapshot(
                selectedLeagues: [],
                selectedChannels: [],
                englishPremierLeagueTeamsOnly: false,
                apiBaseURL: PreferencesStore.defaultApiBaseURL,
                refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes,
                matchGroupSortOrder: .kickoffThenTeamScore,
                premierLeagueMatchesFirst: premierLeagueMatchesFirst
            )
            let payload = PreferencesSyncService.shared.preferencesPayload(snapshot)
            #expect(payload["matchGroupSortOrder"] as? String == "kickoffThenTeamScore")
            #expect(payload["premierLeagueMatchesFirst"] as? Bool == premierLeagueMatchesFirst)
        }
    }
}

@MainActor
private final class SyncTestState {
    var snapshot: PreferencesSnapshot
    var sent: [PreferencesSnapshot] = []
    var failuresRemaining: Int
    let replacement: PreferencesSnapshot?

    init(snapshot: PreferencesSnapshot, failures: Int = 0, replacement: PreferencesSnapshot? = nil) {
        self.snapshot = snapshot
        self.failuresRemaining = failures
        self.replacement = replacement
    }

    func current() -> PreferencesSnapshot { snapshot }
    func change(to value: PreferencesSnapshot) { snapshot = value }
    func send(_ value: PreferencesSnapshot) -> Bool {
        sent.append(value)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            if let replacement { snapshot = replacement }
            return false
        }
        return true
    }
    func sentScopes() -> [Bool] { sent.map(\.showAllMatches) }
}

@MainActor
extension PreferencesSyncOrderingTests {
    private func snapshot(showAll: Bool) -> PreferencesSnapshot {
        PreferencesSnapshot(
            selectedLeagues: [],
            selectedFixtureViewOptionIDs: [FixtureViewOptionID.topTeamsPreset],
            selectedChannels: [],
            englishPremierLeagueTeamsOnly: false,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: 10,
            showAllMatches: showAll
        )
    }

    @Test func deferredSyncReadsLatestSettingsInsteadOfStartupSnapshot() async {
        let state = SyncTestState(snapshot: snapshot(showAll: true))
        let service = PreferencesSyncService(
            minSyncInterval: 0,
            snapshotProvider: { await state.current() },
            sendSnapshot: { await state.send($0) }
        )
        await service.flushPreferences()
        state.change(to: snapshot(showAll: false))
        // A deferred startup/background caller can only request a fresh sync;
        // it can no longer supply the Show all snapshot it captured earlier.
        await service.flushPreferences()
        #expect(state.sentScopes() == [true, false])
    }

    @Test func retryReloadsTopTeamsAfterFailedShowAllUpload() async {
        let state = SyncTestState(snapshot: snapshot(showAll: true), failures: 1,
                                  replacement: snapshot(showAll: false))
        let service = PreferencesSyncService(
            minSyncInterval: 0, retryInterval: 0,
            snapshotProvider: { await state.current() },
            sendSnapshot: { await state.send($0) }
        )
        await service.flushPreferences()
        #expect(state.sentScopes() == [true, false])
    }

    @Test func retriesAreBoundedAndLaterFlushCanRecover() async {
        let state = SyncTestState(snapshot: snapshot(showAll: false), failures: 3)
        let service = PreferencesSyncService(
            minSyncInterval: 0, retryInterval: 0,
            snapshotProvider: { await state.current() },
            sendSnapshot: { await state.send($0) }
        )
        await service.flushPreferences()
        #expect(state.sentScopes().count == 3)
        await service.flushPreferences()
        #expect(state.sentScopes() == [false, false, false, false])
    }
}
