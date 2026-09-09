import Foundation
import Testing
@testable import Top_Scores

@MainActor
struct FACupEarlyRoundsTests {
    @Test func hidesQualifyingAndFirstTwoProperRounds() {
        let earlyRounds = [
            "Qualification Round 1", "Qualification Round 2", "Fourth Round Qualifying",
            "Extra Preliminary Round", "Preliminary Round Replay", "First Round Proper",
            "Second Round Replay", "Round 1", "Round 2", "1st Round", "2nd Round",
        ]
        for round in earlyRounds {
            #expect(match(round: round).isFACupEarlyRound, "Expected early round: \(round)")
        }
        #expect(match(round: nil, number: 1).isFACupEarlyRound)
        #expect(match(round: "", number: 2).isFACupEarlyRound)
        #expect(match(round: "First Round", league: "English FA Cup", leagueID: nil).isFACupEarlyRound)
        #expect(match(round: "First Round", league: "Cup", leagueID: "39").isFACupEarlyRound)
    }

    @Test func keepsLaterUnknownAndOtherCompetitionRounds() {
        for round in ["Third Round", "Round 3", "Round of 64", "Round of 32", "Quarter-final", "Final", "Unknown stage"] {
            // Named BSD stages override potentially reused provider round numbers.
            #expect(!match(round: round, number: 1).isFACupEarlyRound, "Expected visible round: \(round)")
        }
        #expect(!match(round: nil, number: nil).isFACupEarlyRound)
        #expect(!match(round: nil, number: 0).isFACupEarlyRound)
        #expect(!match(round: nil, number: 3).isFACupEarlyRound)
        for league in ["Scottish FA Cup", "Women's FA Cup", "EFL Cup", "Premier League"] {
            #expect(!match(round: "Round 1", league: league, leagueID: nil).isFACupEarlyRound)
        }
    }

    @Test func preferenceDefaultsOffAndPersistsInEverySnapshot() throws {
        let suite = "FACupEarlyRoundsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(userDefaults: defaults)
        #expect(!store.showFACupEarlyRounds)
        #expect(!store.snapshot.showFACupEarlyRounds)
        #expect(!store.unfilteredSnapshot.showFACupEarlyRounds)
        let original = store.snapshot

        store.showFACupEarlyRounds = true
        #expect(store.snapshot != original)
        #expect(store.unfilteredSnapshot.showFACupEarlyRounds)
        #expect(PreferencesStore(userDefaults: defaults).showFACupEarlyRounds)
        #expect(PreferencesStore.loadSnapshot(userDefaults: defaults).showFACupEarlyRounds)
        let encoded = try JSONEncoder().encode(store.snapshot)
        #expect(try JSONDecoder().decode(PreferencesSnapshot.self, from: encoded).showFACupEarlyRounds)

        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "showFACupEarlyRounds")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try !JSONDecoder().decode(PreferencesSnapshot.self, from: legacyData).showFACupEarlyRounds)
    }

    @Test func fixtureSelectionsAndShowAllRespectEarlyRoundPreference() {
        let early = match(round: "Qualification Round 2")
        let later = match(round: "Round 3")
        let unknown = match(round: nil)
        for showAll in [false, true] {
            let visible = FixtureBrowseSelectionResolver.filterMatches(
                [early, later, unknown],
                topMatchesOnly: false,
                selectedCompetitionIDs: ["fa-cup"],
                competitions: [competition],
                showAllMatches: showAll,
                includePostponed: false
            )
            #expect(visible.map(\.id) == [later.id, unknown.id])
            let optedIn = FixtureBrowseSelectionResolver.filterMatches(
                [early, later, unknown],
                topMatchesOnly: false,
                selectedCompetitionIDs: ["fa-cup"],
                competitions: [competition],
                showAllMatches: showAll,
                includePostponed: false,
                includeFACupEarlyRounds: true
            )
            #expect(optedIn.count == 3)
        }
    }

    @Test func cachedCalendarCountsExcludeEarlyRoundsAndRestoreWithOptIn() {
        let date = "2026-09-08"
        let early = match(round: "Qualification Round 2")
        for includeEarlyRounds in [false, true] {
            let availability = FixtureBrowseSelectionResolver.matchAvailabilityByDate(
                matchesByDate: [date: [early]],
                todayKey: date,
                topMatchesOnly: false,
                selectedCompetitionIDs: [],
                competitions: [competition],
                fixtureViewOptionIDs: [],
                showAllMatches: true,
                includePostponed: false,
                includeFACupEarlyRounds: includeEarlyRounds,
                topTeamsMatcher: TopTeamsPresetMatcher(definition: .fallback),
                premierLeagueTeamMatcher: .empty
            )
            #expect(availability[date]?.matchCount == (includeEarlyRounds ? 1 : 0))
            #expect(availability[date]?.containsNextScheduledMatch == includeEarlyRounds)
        }
    }

    @Test func nextMatchUsesVisibleAvailabilityBeforeRawCalendarTotals() {
        let today = "2026-09-08"
        let tomorrow = "2026-09-09"
        let matchesByDate = [
            today: [
                match(round: "Round 3", date: today, status: "FT"),
                match(round: "Qualification Round 2", date: today),
            ],
            tomorrow: [match(round: "Round 3", date: tomorrow)],
        ]
        let days = [today, tomorrow].map { date in
            FixtureCalendarDay(
                date: date, matchCount: date == today ? 2 : 1, topMatchCount: 1,
                hasUnfinished: true, topMatchesHaveUnfinished: true,
                competitions: [FixtureCalendarCompetition(
                    id: "fa-cup", matchCount: date == today ? 2 : 1, hasUnfinished: true
                )]
            )
        }
        for showAll in [false, true] {
            for includeEarlyRounds in [false, true] {
                let availability = FixtureBrowseSelectionResolver.matchAvailabilityByDate(
                    matchesByDate: matchesByDate, todayKey: today, topMatchesOnly: false,
                    selectedCompetitionIDs: ["fa-cup"], competitions: [competition],
                    fixtureViewOptionIDs: [], showAllMatches: showAll, includePostponed: false,
                    includeFACupEarlyRounds: includeEarlyRounds,
                    topTeamsMatcher: TopTeamsPresetMatcher(definition: .fallback),
                    premierLeagueTeamMatcher: .empty
                )
                let expectedDate = includeEarlyRounds ? today : tomorrow
                #expect(FixtureBrowseSelectionResolver.upcomingDateKey(
                    from: days, todayKey: today, topMatchesOnly: false,
                    selectedCompetitionIDs: ["fa-cup"], showAllMatches: showAll,
                    knownAvailability: availability
                ) == expectedDate)
                #expect(FixtureBrowseSelectionResolver.defaultDateKey(
                    from: days, todayKey: today, topMatchesOnly: false,
                    selectedCompetitionIDs: ["fa-cup"], showAllMatches: showAll,
                    knownAvailability: availability
                ) == expectedDate)
                // Tomorrow can still be selected before its match bucket arrives.
                #expect(FixtureBrowseSelectionResolver.upcomingDateKey(
                    from: days, todayKey: today, topMatchesOnly: false,
                    selectedCompetitionIDs: ["fa-cup"], showAllMatches: showAll,
                    knownAvailability: availability.filter { $0.key == today }
                ) == expectedDate)
            }
            #expect(FixtureBrowseSelectionResolver.upcomingDateKey(
                from: days, todayKey: today, topMatchesOnly: false,
                selectedCompetitionIDs: ["fa-cup"], showAllMatches: showAll
            ) == today)
        }
    }

    @Test func togglingPreferenceImmediatelyRefiltersCachedResults() {
        let early = match(round: "Round 2", date: dayString(offset: -1), status: "FT")
        let later = match(round: "Round 3", date: dayString(offset: -1), status: "FT")
        let hiddenSnapshot = snapshot()
        MatchCache.save(
            matches: [early, later], lastUpdated: Date(), fixtureCoverageEnd: nil,
            snapshot: hiddenSnapshot
        )
        let store = MatchesStore()
        defer {
            store.stopAutoRefresh()
            MatchCache.clear()
        }
        store.prepareForPreferencesChange(hiddenSnapshot, publishVisibleState: true)
        #expect(store.resultsViewState.matches.map(\.id) == [later.id])
        store.prepareForPreferencesChange(snapshot(includeEarlyRounds: true), publishVisibleState: true)
        #expect(Set(store.resultsViewState.matches.map(\.id)) == Set([early.id, later.id]))
        store.prepareForPreferencesChange(hiddenSnapshot, publishVisibleState: true)
        #expect(store.resultsViewState.matches.map(\.id) == [later.id])
    }

    @Test func resultsAndWidgetShowAllCannotBypassPreference() {
        let early = match(round: "Round 2", date: dayString(offset: -1), status: "FT")
        let later = match(round: "Round 3", date: dayString(offset: -1), status: "FT")
        #expect(MatchesStore.applyPreferenceFilters(
            to: [early, later], snapshot: snapshot(), mode: .results
        ).map(\.id) == [later.id])
        #expect(MatchesStore.applyPreferenceFilters(
            to: [early, later], snapshot: snapshot(includeEarlyRounds: true), mode: .results
        ).count == 2)

        let earlyFixture = match(round: "Round 2", date: dayString(offset: 1))
        let laterFixture = match(round: "Round 3", date: dayString(offset: 1))
        for includeEarlyRounds in [false, true] {
            let payload = SharedMatchesBridge.makeWidgetPayload(
                matches: [],
                unfilteredMatches: [earlyFixture, laterFixture],
                lastUpdated: nil,
                snapshot: snapshot(includeEarlyRounds: includeEarlyRounds),
                generatedAt: Date()
            )
            #expect(payload.matches.count == (includeEarlyRounds ? 2 : 1))
        }
    }

    private var competition: CompetitionCatalogEntry {
        CompetitionCatalogEntry(
            id: "fa-cup", name: "FA Cup", aliases: ["English FA Cup"],
            weight: 65, region: "england", logoURL: nil
        )
    }

    private func snapshot(includeEarlyRounds: Bool = false) -> PreferencesSnapshot {
        PreferencesSnapshot(
            selectedLeagues: [], selectedFixtureViewOptionIDs: [], selectedChannels: [],
            englishPremierLeagueTeamsOnly: false, apiBaseURL: "https://example.com", refreshIntervalMinutes: 10,
            showAllMatches: true, showFACupEarlyRounds: includeEarlyRounds
        )
    }

    private func match(
        round: String?, number: Int? = nil, league: String = "FA Cup", leagueID: String? = "fa-cup",
        date: String = "2026-09-08", status: String? = nil
    ) -> Match {
        Match(
            date: date, time: "15:00", homeTeam: "Home \(round ?? "Unknown")", awayTeam: "Away",
            league: league, leagueId: leagueID, leagueSubcategory: round, roundNumber: number,
            tvChannels: [], scoreStatus: status
        )
    }

    private func dayString(offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
