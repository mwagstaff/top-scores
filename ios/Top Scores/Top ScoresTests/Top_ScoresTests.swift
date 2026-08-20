//
//  Top_ScoresTests.swift
//  Top ScoresTests
//
//  Created by Mike Wagstaff on 11/02/2026.
//

import Foundation
import Testing
@testable import Top_Scores

struct Top_ScoresTests {

    @Test @MainActor func stadiumBackdrop_rotatesAtLaunchAndAfterOneHour() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("HeaderStadium01", forKey: "appearance.previousHeaderStadiumAssetName")
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let store = StadiumBackdropStore(defaults: defaults, now: start)
        let startupAssetName = store.assetName

        #expect(StadiumBackdropStore.assetNames.count == 22)
        #expect(startupAssetName != "HeaderStadium01")

        store.rotateIfNeeded(now: start.addingTimeInterval(3_599))
        #expect(store.assetName == startupAssetName)

        store.rotateIfNeeded(now: start.addingTimeInterval(3_600))
        #expect(store.assetName != startupAssetName)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test @MainActor func competitionDockIntro_isPresentedOnlyOncePerSession() {
        let coordinator = FixturesViewCoordinator()

        coordinator.prepareCompetitionDockForScoresEntry()

        #expect(coordinator.isCompetitionDockExpanded)
        #expect(coordinator.isCompetitionDockIntroPending)
        #expect(coordinator.hasPresentedCompetitionDockIntro)

        coordinator.resetPresentation()
        coordinator.prepareCompetitionDockForScoresEntry()

        #expect(!coordinator.isCompetitionDockExpanded)
        #expect(!coordinator.isCompetitionDockIntroPending)
    }

    @Test @MainActor func competitionDockIntro_interactionCancelsAutomaticCollapse() async {
        let coordinator = FixturesViewCoordinator()
        coordinator.prepareCompetitionDockForScoresEntry()
        coordinator.scheduleCompetitionDockAutoCollapse(
            reduceMotion: true,
            voiceOverRunning: false,
            delayNanoseconds: 20_000_000
        )

        coordinator.noteCompetitionDockInteraction()
        try? await Task.sleep(nanoseconds: 40_000_000)

        #expect(coordinator.isCompetitionDockExpanded)
    }

    @Test @MainActor func competitionDockIntro_voiceOverKeepsCarouselExpanded() {
        let coordinator = FixturesViewCoordinator()
        coordinator.prepareCompetitionDockForScoresEntry()

        coordinator.scheduleCompetitionDockAutoCollapse(
            reduceMotion: false,
            voiceOverRunning: true,
            delayNanoseconds: 0
        )

        #expect(coordinator.isCompetitionDockExpanded)
        #expect(!coordinator.isCompetitionDockIntroPending)
    }

    @Test func fantasyExpectedPoints_usesNearestFPLForecastToModelLaterFixtures() {
        let gw1 = makeUpcomingFixture(gameweek: 1, difficulty: 2)
        let gw2 = makeUpcomingFixture(gameweek: 2, difficulty: 4)
        let details = makeFantasyPlayerDetails(
            fplNextGameweekID: 1,
            fplExpectedPointsNextGameweek: 4.0,
            upcomingFixtures: [gw1, gw2]
        )

        let gw1Projection = FantasyExpectedPointsEstimator.estimate(
            details: details,
            fixture: gw1,
            fixtureIndex: 0
        )
        let gw2Projection = FantasyExpectedPointsEstimator.estimate(
            details: details,
            fixture: gw2,
            fixtureIndex: 1
        )

        #expect(gw1Projection == 3.7)
        #expect(gw2Projection == 3.3)
    }

    @Test func fantasyExpectedPoints_usesPositionBaselineWithoutHistoryOrFPLForecast() {
        let fixture = makeUpcomingFixture(gameweek: 3, difficulty: 3)
        let details = makeFantasyPlayerDetails(upcomingFixtures: [fixture])

        let projection = FantasyExpectedPointsEstimator.estimate(
            details: details,
            fixture: fixture,
            fixtureIndex: 0
        )

        #expect(projection == 2.7)
    }

    @Test func fantasyClassicLeague_resolvesPlayerCreatedRankAndMemberCount() {
        let league = FantasyEntryClassicLeague(
            id: 101,
            name: "Shirley Super League",
            shortName: nil,
            leagueType: "x",
            rankCount: 18,
            entryRank: 2,
            entryLastRank: 4,
            activePhases: []
        )
        let systemLeague = FantasyEntryClassicLeague(
            id: 102,
            name: "Overall",
            shortName: nil,
            leagueType: "s",
            rankCount: nil,
            entryRank: nil,
            entryLastRank: nil,
            activePhases: [
                FantasyEntryLeagueActivePhase(
                    phase: 1,
                    rank: 10,
                    lastRank: 8,
                    total: 100,
                    rankCount: 1_000
                )
            ]
        )

        #expect(league.isPlayerCreated)
        #expect(league.resolvedEntryRank == 2)
        #expect(league.resolvedMemberCount == 18)
        #expect(!systemLeague.isPlayerCreated)
        #expect(systemLeague.resolvedEntryRank == 10)
        #expect(systemLeague.resolvedMemberCount == 1_000)
    }

    @Test func fantasyPlayerProfileImageURL_usesBootstrapPlayerCode() {
        let url = FantasyPlayerProfileImageURL.make(fromPlayerCode: 141746)

        #expect(
            url?.absoluteString ==
                "https://resources.premierleague.com/premierleague25/photos/players/110x140/141746.png"
        )
        #expect(FantasyPlayerProfileImageURL.make(fromPlayerCode: nil) == nil)
        #expect(FantasyPlayerProfileImageURL.make(fromPlayerCode: 0) == nil)
    }

    @Test func fantasyBootstrapElement_playerCodeFallsBackToPhotoFilename() {
        let player = makeFantasyBootstrapElement(
            id: 1,
            team: 1,
            elementType: 1,
            webName: "Raya",
            photo: "154561.jpg"
        )

        #expect(player.playerCode == 154561)
    }

    @Test @MainActor func preferencesStore_usesRequestedDefaultsForNewInstalls() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let store = PreferencesStore(userDefaults: defaults)

        #expect(store.englishPremierLeagueTeamsOnly)
        #expect(store.homeNationsFilterEnabled)
        #expect(store.majorTournamentsFilterEnabled)
        #expect(store.fixtureAllMajorMatchesEnabled)
        #expect(store.notificationAllMajorMatchesEnabled)
        #expect(!store.competitionFilterEnabled)
        #expect(store.notificationsEnabled)
        #expect(store.notificationDelayMinutes == 2)
        #expect(store.notificationEventTypes == PreferencesStore.defaultNotificationEventTypes)
        #expect(store.fantasyDeadlineRemindersEnabled)
        #expect(store.matchGroupSortOrder == .kickoffThenTeamScore)
        #expect(!store.showTodayUnfinishedFixturesBadge)
        #expect(store.fixturesViewDensity == .compact)
        #expect(store.showCompactFixtureTvLogo)
        #expect(store.showCompactFixtureFantasyLogo)
        #expect(!store.showKickoffTimeDividers)
        #expect(!store.showFantasyFixtureLogos)
        #expect(!store.showFantasyExpectedPoints)
        #expect(!store.showFantasyRealTimePoints)
        #expect(!store.showsFantasyDataInFixtures)
        #expect(!store.showPredictedScores)
        #expect(!store.favouriteShowPredictedScores)
        #expect(!store.channelFilterEnabled)
    }

    @Test @MainActor func preferencesStore_persistsFavouritePredictionsSetting() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let store = PreferencesStore(userDefaults: defaults)
        #expect(!store.hasUnsavedFixtureViewChanges)
        store.showPredictedScores = true
        #expect(store.hasUnsavedFixtureViewChanges)
        store.favouriteShowPredictedScores = true
        #expect(!store.hasUnsavedFixtureViewChanges)

        let reloadedStore = PreferencesStore(userDefaults: defaults)
        #expect(reloadedStore.showPredictedScores)
        #expect(reloadedStore.favouriteShowPredictedScores)
    }

    @Test @MainActor func preferencesStore_persistsCompactFixtureDisplaySettings() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let store = PreferencesStore(userDefaults: defaults)
        store.showCompactFixtureTvLogo = false
        store.showCompactFixtureFantasyLogo = false
        store.showKickoffTimeDividers = true

        let reloaded = PreferencesStore(userDefaults: defaults)
        #expect(reloaded.fixturesViewDensity == .compact)
        #expect(!reloaded.showCompactFixtureTvLogo)
        #expect(!reloaded.showCompactFixtureFantasyLogo)
        #expect(reloaded.showKickoffTimeDividers)
    }

    @Test @MainActor func preferencesStore_mapsLegacyFixturesViewDensityValuesToCompact() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set("ultraCompact", forKey: "preferences.fixturesViewDensity")

        let store = PreferencesStore(userDefaults: defaults)
        #expect(store.fixturesViewDensity == .compact)
    }

    @Test @MainActor func preferencesStore_migratesLegacyFixturesFantasyToggle() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(true, forKey: "preferences.showFantasyMatchPills")

        let store = PreferencesStore(userDefaults: defaults)

        #expect(store.showFantasyFixtureLogos)
        #expect(store.showFantasyExpectedPoints)
        #expect(store.showFantasyRealTimePoints)
        #expect(store.showsFantasyDataInFixtures)
    }

    @Test func preferencesSnapshot_keepsCategoryFlagsEffectiveWhenMasterFilterIsOff() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: PreferencesStore.defaultSelectedLeagues,
            selectedChannels: PreferencesStore.defaultSelectedChannels,
            competitionFilterEnabled: false,
            channelFilterEnabled: false,
            englishPremierLeagueTeamsOnly: true,
            majorUEFAClubGamesEnabled: true,
            homeNationsFilterEnabled: true,
            majorTournamentsFilterEnabled: true,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )

        #expect(snapshot.effectiveEnglishPremierLeagueTeamsOnly)
        #expect(snapshot.effectiveMajorUEFAClubGamesEnabled)
        #expect(snapshot.effectiveHomeNationsFilterEnabled)
        #expect(snapshot.effectiveMajorTournamentsFilterEnabled)
    }

    @Test func matchesPageQueryItems_useSelectedViewOptionsWhenMasterFilterIsOff() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: PreferencesStore.defaultSelectedLeagues,
            selectedFixtureViewOptionIDs: [FixtureViewOptionID.competition("premier-league")],
            selectedChannels: PreferencesStore.defaultSelectedChannels,
            fixtureAllMajorMatchesEnabled: false,
            competitionFilterEnabled: false,
            channelFilterEnabled: false,
            englishPremierLeagueTeamsOnly: true,
            majorUEFAClubGamesEnabled: true,
            homeNationsFilterEnabled: true,
            majorTournamentsFilterEnabled: true,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )
        let queryItems = APIClient.matchesPageQueryItems(
            preferences: snapshot,
            mode: .fixtures,
            page: 1,
            pageSize: 120,
            dateRangeQueryItems: [
                URLQueryItem(name: "start", value: "2026-04-01"),
                URLQueryItem(name: "end", value: "2026-06-30")
            ]
        )

        let names = Set(queryItems.map(\.name))
        #expect(queryItems.contains(URLQueryItem(
            name: "view_option",
            value: FixtureViewOptionID.competition("premier-league")
        )))
        #expect(!names.contains("league"))
        #expect(names.contains("time_zone"))
        #expect(!names.contains("epl_only"))
        #expect(!names.contains("major_uefa"))
        #expect(!names.contains("home_nations"))
        #expect(!names.contains("major_tournaments"))
    }

    @MainActor
    @Test func playerDetails_usesShortTimeoutAndRetriesOnceAfterTimeout() async throws {
        let recorder = PlayerDetailsRequestRecorder()
        PlayerDetailsURLProtocol.requestHandler = { request in
            let attempt = recorder.record(timeout: request.timeoutInterval)
            if attempt == 1 {
                throw URLError(.timedOut)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(#"{"id":"34167754","name":"Nicolas Pépé"}"#.utf8)
            return (response, data)
        }
        defer { PlayerDetailsURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlayerDetailsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let client = APIClient(
            baseURL: URL(string: "https://example.com/api/v1")!,
            session: session
        )

        let details = try await client.fetchPlayerDetails(playerId: "34167754")

        #expect(details.name == "Nicolas Pépé")
        #expect(recorder.recordedTimeouts == [5, 5])
    }

    @Test func playerPortraitPixelSize_rejectsBSDMissingImagePlaceholder() {
        #expect(!playerPortraitPixelSizeIsRenderable(width: 1, height: 1))
        #expect(!playerPortraitPixelSizeIsRenderable(width: 150, height: 1))
        #expect(playerPortraitPixelSizeIsRenderable(width: 150, height: 150))
    }

    @Test func playerPortraitURLNeedsBackgroundRemoval_onlyTargetsBSDPortraits() throws {
        #expect(playerPortraitURLNeedsBackgroundRemoval(
            try #require(URL(string: "https://sports.bzzoiro.com/img/player/6525/"))
        ))
        #expect(!playerPortraitURLNeedsBackgroundRemoval(
            try #require(URL(string: "https://sports.bzzoiro.com/img/team/208/"))
        ))
        #expect(!playerPortraitURLNeedsBackgroundRemoval(
            try #require(URL(string: "https://www.thesportsdb.com/images/player.png"))
        ))
    }

    @Test func matchesPageQueryItems_omitCategoryParamsWhenPremierLeagueTeamsOnlyIsOff() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: PreferencesStore.defaultSelectedLeagues,
            selectedChannels: PreferencesStore.defaultSelectedChannels,
            competitionFilterEnabled: false,
            channelFilterEnabled: false,
            englishPremierLeagueTeamsOnly: false,
            majorUEFAClubGamesEnabled: true,
            homeNationsFilterEnabled: true,
            majorTournamentsFilterEnabled: true,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )
        let queryItems = APIClient.matchesPageQueryItems(
            preferences: snapshot,
            mode: .results,
            page: 1,
            pageSize: 120,
            dateRangeQueryItems: [
                URLQueryItem(name: "start", value: "2026-04-01"),
                URLQueryItem(name: "end", value: "2026-04-29")
            ]
        )

        let names = Set(queryItems.map(\.name))
        #expect(!snapshot.effectiveEnglishPremierLeagueTeamsOnly)
        #expect(!snapshot.effectiveMajorUEFAClubGamesEnabled)
        #expect(!snapshot.effectiveHomeNationsFilterEnabled)
        #expect(!snapshot.effectiveMajorTournamentsFilterEnabled)
        #expect(!names.contains("league"))
        #expect(!names.contains("epl_only"))
        #expect(!names.contains("major_uefa"))
        #expect(!names.contains("home_nations"))
        #expect(!names.contains("major_tournaments"))
    }

    @Test func matchesPageQueryItems_useFavouriteViewOptionsWhenMasterFilterIsOn() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: PreferencesStore.defaultSelectedLeagues,
            selectedFixtureViewOptionIDs: [FixtureViewOptionID.competition("fa-cup")],
            favouriteFixtureViewOptionIDs: [FixtureViewOptionID.competition("premier-league")],
            selectedChannels: PreferencesStore.defaultSelectedChannels,
            fixtureAllMajorMatchesEnabled: true,
            competitionFilterEnabled: true,
            channelFilterEnabled: false,
            englishPremierLeagueTeamsOnly: true,
            majorUEFAClubGamesEnabled: true,
            homeNationsFilterEnabled: true,
            majorTournamentsFilterEnabled: true,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )
        let queryItems = APIClient.matchesPageQueryItems(
            preferences: snapshot,
            mode: .fixtures,
            page: 1,
            pageSize: 120,
            dateRangeQueryItems: [
                URLQueryItem(name: "start", value: "2026-04-01"),
                URLQueryItem(name: "end", value: "2026-07-31")
            ]
        )

        let names = Set(queryItems.map(\.name))
        #expect(queryItems.contains(URLQueryItem(
            name: "view_option",
            value: FixtureViewOptionID.competition("premier-league")
        )))
        #expect(!queryItems.contains(URLQueryItem(
            name: "view_option",
            value: FixtureViewOptionID.competition("fa-cup")
        )))
        #expect(!names.contains("epl_only"))
        #expect(!names.contains("major_uefa"))
        #expect(!names.contains("home_nations"))
        #expect(!names.contains("major_tournaments"))
    }

    @Test func matchesPageQueryItems_useIndividualCompetitionSelectionWhenAllMajorMatchesIsOff() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: ["FA Cup"],
            selectedFixtureViewOptionIDs: [FixtureViewOptionID.competition("fa-cup")],
            selectedChannels: [],
            fixtureAllMajorMatchesEnabled: false,
            englishPremierLeagueTeamsOnly: false,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )
        let queryItems = APIClient.matchesPageQueryItems(
            preferences: snapshot,
            mode: .fixtures,
            page: 1,
            dateRangeQueryItems: []
        )

        #expect(queryItems.contains(URLQueryItem(
            name: "view_option",
            value: FixtureViewOptionID.competition("fa-cup")
        )))
        #expect(!queryItems.contains { $0.name == "league" })
        #expect(!queryItems.contains(URLQueryItem(name: "epl_only", value: "true")))
    }

    @Test func matchesPageQueryItems_omitAllPreferenceFiltersWhenDisabledForRequest() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: ["Premier League"],
            selectedChannels: ["Sky (all)"],
            competitionFilterEnabled: true,
            channelFilterEnabled: true,
            englishPremierLeagueTeamsOnly: true,
            homeNationsFilterEnabled: true,
            majorTournamentsFilterEnabled: true,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )
        let queryItems = APIClient.matchesPageQueryItems(
            preferences: snapshot,
            mode: .fixtures,
            page: 1,
            pageSize: 120,
            dateRangeQueryItems: [
                URLQueryItem(name: "start", value: "2026-04-01"),
                URLQueryItem(name: "end", value: "2026-04-05")
            ],
            includePreferenceFilters: false
        )

        let names = Set(queryItems.map(\.name))
        #expect(!names.contains("league"))
        #expect(!names.contains("channel"))
        #expect(!names.contains("epl_only"))
        #expect(!names.contains("major_uefa"))
        #expect(!names.contains("home_nations"))
        #expect(!names.contains("major_tournaments"))
    }

    @Test func matchesPageQueryItems_applyTeamSelectionsToResultsWithoutLegacyCategoryIntersection() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: ["Premier League"],
            favouriteFixtureViewOptionIDs: [
                FixtureViewOptionID.competition("premier-league"),
                FixtureViewOptionID.team("watford"),
                FixtureViewOptionID.team("norwich-city"),
            ],
            selectedChannels: [],
            fixtureAllMajorMatchesEnabled: true,
            englishPremierLeagueTeamsOnly: true,
            majorUEFAClubGamesEnabled: true,
            homeNationsFilterEnabled: true,
            majorTournamentsFilterEnabled: true,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )

        let queryItems = APIClient.matchesPageQueryItems(
            preferences: snapshot,
            mode: .results,
            page: 1,
            dateRangeQueryItems: []
        )
        let viewOptions = queryItems
            .filter { $0.name == "view_option" }
            .compactMap(\.value)

        #expect(viewOptions.contains(FixtureViewOptionID.team("watford")))
        #expect(viewOptions.contains(FixtureViewOptionID.team("norwich-city")))
        #expect(!queryItems.contains { $0.name == "epl_only" })
        #expect(!queryItems.contains { $0.name == "major_uefa" })
        #expect(!queryItems.contains { $0.name == "home_nations" })
        #expect(!queryItems.contains { $0.name == "major_tournaments" })
    }

    @Test func fixtureBrowserSelection_mapsDefaultSelectionsPresentInCatalog() {
        let competitions = [
            CompetitionCatalogEntry(
                id: "la-liga",
                name: "La Liga",
                aliases: ["Spanish La Liga"],
                weight: 47,
                region: "spain",
                logoURL: nil
            ),
        ]

        let selected = FixtureBrowseSelectionResolver.selectedCompetitionIDs(
            selectedLeagues: ["Spanish La Liga"],
            competitions: competitions
        )

        #expect(selected == ["la-liga"])
    }

    @Test func scoresCompetitionAccent_resolvesSupportedCompetitionsAndFallback() {
        #expect(CompetitionAccentRole.resolve(
            competitionID: "premier-league",
            competitionName: "Premier League"
        ) == .premierLeague)
        #expect(CompetitionAccentRole.resolve(
            competitionID: nil,
            competitionName: "Spanish La Liga"
        ) == .laLiga)
        #expect(CompetitionAccentRole.resolve(
            competitionID: "uefa-champions-league",
            competitionName: "UEFA Champions League"
        ) == .championsLeague)
        #expect(CompetitionAccentRole.resolve(
            competitionID: "uefa-europa-conference-league",
            competitionName: "UEFA Conference League"
        ) == .conferenceLeague)
        #expect(CompetitionAccentRole.resolve(
            competitionID: "club-world-cup",
            competitionName: "Club World Cup"
        ) == .standard)
    }

    @Test func fixtureBrowserAutoRefresh_usesLiveAndPendingTodayCadences() {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = .current
        timeFormatter.dateFormat = "HH:mm"
        let now = Date()
        let today = dateFormatter.string(from: now)
        let currentTime = timeFormatter.string(from: now)

        let live = makeMatch(
            date: today,
            time: currentTime,
            homeScore: 1,
            awayScore: 0,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "84"
        )
        let upcoming = makeMatch(
            date: today,
            time: currentTime,
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: nil
        )
        let finished = makeMatch(
            date: today,
            time: currentTime,
            homeScore: 2,
            awayScore: 0,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "FT"
        )

        #expect(FixtureBrowseAutoRefreshPolicy.intervalSeconds(
            selectedDateKey: today,
            todayKey: today,
            matches: [live]
        ) == FixtureBrowseAutoRefreshPolicy.liveIntervalSeconds)
        #expect(FixtureBrowseAutoRefreshPolicy.intervalSeconds(
            selectedDateKey: today,
            todayKey: today,
            matches: [upcoming]
        ) == FixtureBrowseAutoRefreshPolicy.pendingTodayIntervalSeconds)
        #expect(FixtureBrowseAutoRefreshPolicy.intervalSeconds(
            selectedDateKey: today,
            todayKey: today,
            matches: [finished]
        ) == nil)
    }

    @Test func fixtureBrowserSelection_showsOnlyDatesForSelectedCompetitions() {
        let days = [
            FixtureCalendarDay(
                date: "2026-08-15",
                matchCount: 2,
                topMatchCount: 1,
                hasUnfinished: false,
                topMatchesHaveUnfinished: false,
                competitions: [
                    FixtureCalendarCompetition(id: "premier-league", matchCount: 2, hasUnfinished: false),
                ]
            ),
            FixtureCalendarDay(
                date: "2026-08-22",
                matchCount: 3,
                topMatchCount: 2,
                hasUnfinished: true,
                topMatchesHaveUnfinished: true,
                competitions: [
                    FixtureCalendarCompetition(id: "bundesliga", matchCount: 3, hasUnfinished: true),
                ]
            ),
        ]

        let available = FixtureBrowseSelectionResolver.availableDays(
            calendarDays: days,
            topMatchesOnly: false,
            selectedCompetitionIDs: ["bundesliga"]
        )

        #expect(available.map(\.date) == ["2026-08-22"])
    }

    @Test func fixtureBrowserSelection_defaultsToNextUnfinishedSelectedDate() {
        let days = [
            FixtureCalendarDay(
                date: "2026-08-15",
                matchCount: 1,
                topMatchCount: 1,
                hasUnfinished: false,
                topMatchesHaveUnfinished: false,
                competitions: [
                    FixtureCalendarCompetition(id: "bundesliga", matchCount: 1, hasUnfinished: false),
                ]
            ),
            FixtureCalendarDay(
                date: "2026-08-22",
                matchCount: 2,
                topMatchCount: 2,
                hasUnfinished: true,
                topMatchesHaveUnfinished: true,
                competitions: [
                    FixtureCalendarCompetition(id: "bundesliga", matchCount: 2, hasUnfinished: true),
                ]
            ),
        ]

        let selectedDate = FixtureBrowseSelectionResolver.defaultDateKey(
            from: days,
            todayKey: "2026-08-15",
            topMatchesOnly: false,
            selectedCompetitionIDs: ["bundesliga"]
        )

        #expect(selectedDate == "2026-08-22")
    }

    @Test func fixtureBrowserSelection_mapsFavouriteCompetitionsFromPreferenceDefaults() {
        let competitions = [
            CompetitionCatalogEntry(
                id: "premier-league",
                name: "Premier League",
                aliases: [],
                weight: 50,
                region: "england",
                logoURL: nil
            ),
            CompetitionCatalogEntry(
                id: "uefa-champions-league",
                name: "UEFA Champions League",
                aliases: ["Champions League"],
                weight: 49,
                region: "europe",
                logoURL: nil
            ),
            CompetitionCatalogEntry(
                id: "la-liga",
                name: "La Liga",
                aliases: [],
                weight: 47,
                region: "spain",
                logoURL: nil
            ),
        ]

        let favouriteIDs = FixtureBrowseSelectionResolver.selectedCompetitionIDs(
            selectedLeagues: PreferencesStore.defaultSelectedLeagues,
            competitions: competitions
        )

        #expect(favouriteIDs == ["premier-league"])
    }

    @Test func fixtureBrowserSelection_resetsToImmediateUpcomingDateAfterAddingCompetition() {
        let days = [
            FixtureCalendarDay(
                date: "2026-08-14",
                matchCount: 1,
                topMatchCount: 1,
                hasUnfinished: false,
                topMatchesHaveUnfinished: false,
                competitions: [
                    FixtureCalendarCompetition(id: "premier-league", matchCount: 1, hasUnfinished: false),
                ]
            ),
            FixtureCalendarDay(
                date: "2026-08-15",
                matchCount: 2,
                topMatchCount: 0,
                hasUnfinished: true,
                topMatchesHaveUnfinished: false,
                competitions: [
                    FixtureCalendarCompetition(id: "la-liga", matchCount: 2, hasUnfinished: true),
                ]
            ),
        ]
        let selectedIDs: Set<String> = ["premier-league", "la-liga"]
        let available = FixtureBrowseSelectionResolver.availableDays(
            calendarDays: days,
            topMatchesOnly: false,
            selectedCompetitionIDs: selectedIDs
        )

        let selectedDate = FixtureBrowseSelectionResolver.defaultDateKey(
            from: available,
            todayKey: "2026-08-15",
            topMatchesOnly: false,
            selectedCompetitionIDs: selectedIDs
        )

        #expect(selectedDate == "2026-08-15")
    }

    @Test func fixtureBrowserSelection_excludesPostponedMatchesWhenPreferenceIsOff() {
        let postponed = makeMatch(
            date: "2026-02-07",
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "POSTPONED"
        )

        let hidden = FixtureBrowseSelectionResolver.filterMatches(
            [postponed],
            topMatchesOnly: true,
            selectedCompetitionIDs: [],
            competitions: [],
            includePostponed: false
        )
        let included = FixtureBrowseSelectionResolver.filterMatches(
            [postponed],
            topMatchesOnly: true,
            selectedCompetitionIDs: [],
            competitions: [],
            includePostponed: true
        )

        #expect(hidden.isEmpty)
        #expect(included.map(\.id) == [postponed.id])
    }

    @Test func fixtureBrowserSelection_showAllDoesNotReusePreviousCompetitionFilter() {
        let competitions = [
            CompetitionCatalogEntry(
                id: "premier-league",
                name: "Premier League",
                aliases: [],
                weight: 100,
                region: "england",
                logoURL: nil
            ),
            CompetitionCatalogEntry(
                id: "la-liga",
                name: "La Liga",
                aliases: ["Spanish La Liga"],
                weight: 50,
                region: "spain",
                logoURL: nil
            ),
        ]
        let premierLeagueMatch = Match(
            date: "2026-08-22",
            time: "15:00",
            homeTeam: "Arsenal",
            awayTeam: "Chelsea",
            league: "Premier League",
            tvChannels: []
        )
        let laLigaMatch = Match(
            date: "2026-08-22",
            time: "20:00",
            homeTeam: "Barcelona",
            awayTeam: "Valencia",
            league: "La Liga",
            tvChannels: []
        )

        let filtered = FixtureBrowseSelectionResolver.filterMatches(
            [premierLeagueMatch, laLigaMatch],
            topMatchesOnly: false,
            selectedCompetitionIDs: ["la-liga"],
            competitions: competitions,
            showAllMatches: true,
            includePostponed: false
        )

        #expect(filtered.map(\.id) == [premierLeagueMatch.id, laLigaMatch.id])
    }

    @Test func fixtureBrowserSelection_matchesDerKlassikerOutsideBundesliga() {
        let fixture = Match(
            date: "2026-08-22",
            time: "19:30",
            homeTeam: "Borussia Dortmund",
            awayTeam: "Bayern Munich",
            league: "German Super Cup",
            tvChannels: []
        )

        let filtered = FixtureBrowseSelectionResolver.filterMatches(
            [fixture],
            topMatchesOnly: false,
            selectedCompetitionIDs: [],
            competitions: [],
            fixtureViewOptionIDs: [FixtureViewOptionID.rivalry("der-klassiker")],
            includePostponed: false
        )

        #expect(filtered.map(\.id) == [fixture.id])
    }

    @Test func fixtureBrowserSelection_includesArbitraryTeamsWithoutTheirCompetition() {
        let watford = Match(
            date: "2026-08-22",
            time: "15:00",
            homeTeam: "Watford",
            awayTeam: "Arsenal",
            league: "FA Cup",
            tvChannels: []
        )
        let norwich = Match(
            date: "2026-08-22",
            time: "15:00",
            homeTeam: "Norwich City",
            awayTeam: "Chelsea",
            league: "EFL Cup",
            tvChannels: []
        )
        let unrelated = Match(
            date: "2026-08-22",
            time: "15:00",
            homeTeam: "Coventry City",
            awayTeam: "Stoke City",
            league: "Championship",
            tvChannels: []
        )

        let filtered = FixtureBrowseSelectionResolver.filterMatches(
            [watford, norwich, unrelated],
            topMatchesOnly: false,
            selectedCompetitionIDs: [],
            competitions: [],
            fixtureViewOptionIDs: [
                FixtureViewOptionID.team("watford"),
                FixtureViewOptionID.team("norwich-city"),
            ],
            includePostponed: false
        )

        #expect(filtered.map(\.id) == [watford.id, norwich.id])
    }

    @Test func fixtureViewOptions_uefaTeamRulesAreMutuallyExclusiveAndOptional() {
        let competitions: Set<String> = [
            FixtureViewOptionID.competition("uefa-champions-league"),
        ]
        let topTeams = FixtureViewOptionID.toggling(
            FixtureViewOptionID.topUEFAClubs,
            in: competitions
        )
        let premierLeagueTeams = FixtureViewOptionID.toggling(
            FixtureViewOptionID.premierLeagueTeams,
            in: topTeams
        )
        let allTeams = FixtureViewOptionID.toggling(
            FixtureViewOptionID.premierLeagueTeams,
            in: premierLeagueTeams
        )

        #expect(topTeams.contains(FixtureViewOptionID.topUEFAClubs))
        #expect(!premierLeagueTeams.contains(FixtureViewOptionID.topUEFAClubs))
        #expect(premierLeagueTeams.contains(FixtureViewOptionID.premierLeagueTeams))
        #expect(allTeams == competitions)
        #expect(FixtureViewOptionID.premierLeagueMatchesPresetOptionIDs == Set([
            FixtureViewOptionID.competition("premier-league"),
            FixtureViewOptionID.competition("uefa-champions-league"),
            FixtureViewOptionID.competition("uefa-europa-league"),
            FixtureViewOptionID.competition("uefa-conference-league"),
            FixtureViewOptionID.competition("uefa-super-cup"),
            FixtureViewOptionID.premierLeagueTeams,
        ]))
    }

    @Test func fixtureViewOptions_replacingTeamsPreservesCompetitionsAndRules() {
        let premierLeague = FixtureViewOptionID.competition("premier-league")
        let championsLeague = FixtureViewOptionID.competition("uefa-champions-league")
        let rivalry = FixtureViewOptionID.rivalry("el-clasico")
        let existing: Set<String> = [
            premierLeague,
            championsLeague,
            rivalry,
            FixtureViewOptionID.topUEFAClubs,
            FixtureViewOptionID.team("barcelona"),
        ]

        let updated = FixtureViewOptionID.replacingTeams(
            in: existing,
            with: ["millwall", "rangers"]
        )

        #expect(updated.contains(premierLeague))
        #expect(updated.contains(championsLeague))
        #expect(updated.contains(rivalry))
        #expect(updated.contains(FixtureViewOptionID.topUEFAClubs))
        #expect(!updated.contains(FixtureViewOptionID.team("barcelona")))
        #expect(updated.contains(FixtureViewOptionID.team("millwall")))
        #expect(updated.contains(FixtureViewOptionID.team("rangers")))
    }

    @Test func fixtureBrowserSelection_premierLeagueTeamsRuleFiltersSelectedUEFACompetitions() {
        let competitions = [
            CompetitionCatalogEntry(
                id: "uefa-champions-league",
                name: "UEFA Champions League",
                aliases: [],
                weight: 90,
                region: "europe",
                logoURL: nil
            ),
        ]
        let arsenal = Match(
            date: "2026-09-15",
            time: "20:00",
            homeTeam: "Arsenal",
            awayTeam: "Paris Saint-Germain",
            league: "UEFA Champions League",
            tvChannels: []
        )
        let realMadrid = Match(
            date: "2026-09-15",
            time: "20:00",
            homeTeam: "Real Madrid",
            awayTeam: "Paris Saint-Germain",
            league: "UEFA Champions League",
            tvChannels: []
        )
        let options: Set<String> = [
            FixtureViewOptionID.competition("uefa-champions-league"),
            FixtureViewOptionID.premierLeagueTeams,
        ]

        let filtered = FixtureBrowseSelectionResolver.filterMatches(
            [arsenal, realMadrid],
            topMatchesOnly: false,
            selectedCompetitionIDs: [],
            competitions: competitions,
            fixtureViewOptionIDs: options,
            includePostponed: false
        )

        #expect(filtered.map(\.id) == [arsenal.id])
    }

    @Test func fixtureBrowserSelection_resolvesSwipeAndNextMatchNavigation() {
        let days = [
            FixtureCalendarDay(
                date: "2026-08-14",
                matchCount: 1,
                topMatchCount: 1,
                hasUnfinished: false,
                topMatchesHaveUnfinished: false,
                competitions: []
            ),
            FixtureCalendarDay(
                date: "2026-08-15",
                matchCount: 1,
                topMatchCount: 1,
                hasUnfinished: true,
                topMatchesHaveUnfinished: true,
                competitions: []
            ),
            FixtureCalendarDay(
                date: "2026-08-16",
                matchCount: 1,
                topMatchCount: 1,
                hasUnfinished: true,
                topMatchesHaveUnfinished: true,
                competitions: []
            ),
        ]

        #expect(
            FixtureBrowseSelectionResolver.adjacentDateKey(
                in: days,
                from: "2026-08-15",
                offset: -1
            ) == "2026-08-14"
        )
        #expect(
            FixtureBrowseSelectionResolver.adjacentDateKey(
                in: days,
                from: "2026-08-15",
                offset: 1
            ) == "2026-08-16"
        )
        #expect(
            FixtureBrowseSelectionResolver.dateJumpDirection(
                from: "2026-08-14",
                to: "2026-08-15"
            ) == .later
        )
        #expect(
            FixtureBrowseSelectionResolver.dateJumpDirection(
                from: "2026-08-16",
                to: "2026-08-15"
            ) == .earlier
        )
        #expect(
            FixtureBrowseSelectionResolver.dateJumpDirection(
                from: "2026-08-15",
                to: "2026-08-15"
            ) == nil
        )
        #expect(
            FixtureBrowseSelectionResolver.upcomingDateKey(
                from: Array(days.prefix(1)),
                todayKey: "2026-08-15",
                topMatchesOnly: true,
                selectedCompetitionIDs: []
            ) == nil
        )
    }

    @Test func fixtureBrowserSelection_commitsIntentionalHorizontalDateSwipes() {
        #expect(
            FixtureBrowseSelectionResolver.swipeDateOffset(
                translationWidth: -90,
                translationHeight: 12,
                predictedEndTranslationWidth: -120,
                containerWidth: 390
            ) == 1
        )
        #expect(
            FixtureBrowseSelectionResolver.swipeDateOffset(
                translationWidth: 38,
                translationHeight: 8,
                predictedEndTranslationWidth: 180,
                containerWidth: 390
            ) == -1
        )
        #expect(
            FixtureBrowseSelectionResolver.swipeDateOffset(
                translationWidth: 40,
                translationHeight: 8,
                predictedEndTranslationWidth: 50,
                containerWidth: 390
            ) == nil
        )
        #expect(
            FixtureBrowseSelectionResolver.swipeDateOffset(
                translationWidth: 95,
                translationHeight: 90,
                predictedEndTranslationWidth: 170,
                containerWidth: 390
            ) == nil
        )
    }

    @Test func appIconBadgeManager_countsOnlyTodayUnfinishedFixtures() async throws {
        let today = formattedDate(offsetDays: 0)
        let yesterday = formattedDate(offsetDays: -1)
        let tomorrow = formattedDate(offsetDays: 1)

        let matches = [
            makeMatch(date: today, time: "12:30", homeScore: nil, awayScore: nil, aggregateHomeScore: nil, aggregateAwayScore: nil, scoreStatus: nil),
            makeMatch(date: today, time: "15:00", homeScore: 1, awayScore: 0, aggregateHomeScore: nil, aggregateAwayScore: nil, scoreStatus: "33"),
            makeMatch(date: today, time: "17:30", homeScore: 2, awayScore: 1, aggregateHomeScore: nil, aggregateAwayScore: nil, scoreStatus: "FT"),
            makeMatch(date: yesterday, time: "19:45", homeScore: 1, awayScore: 1, aggregateHomeScore: nil, aggregateAwayScore: nil, scoreStatus: "FT"),
            makeMatch(date: tomorrow, time: "20:00", homeScore: nil, awayScore: nil, aggregateHomeScore: nil, aggregateAwayScore: nil, scoreStatus: nil)
        ]

        #expect(AppIconBadgeManager.unfinishedFixtureCount(for: matches) == 2)
    }

    @Test func fixturesFilter_excludesStalePreviousDayInProgressMatches() async throws {
        let today = formattedDate(offsetDays: 0)
        let yesterday = formattedDate(offsetDays: -1)

        let liveLateKickoff = makeMatch(
            date: yesterday,
            time: "00:00",
            homeScore: 1,
            awayScore: 1,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "77"
        )
        let finishedYesterday = makeMatch(
            date: yesterday,
            time: "19:45",
            homeScore: 2,
            awayScore: 1,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "FT"
        )
        let upcomingToday = makeMatch(
            date: today,
            time: "15:00",
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: nil
        )

        let fixtures = MatchesStore.filterMatches(
            [liveLateKickoff, finishedYesterday, upcomingToday],
            for: .fixtures
        )

        #expect(!fixtures.contains(liveLateKickoff))
        #expect(!fixtures.contains(finishedYesterday))
        #expect(fixtures.contains(upcomingToday))
    }

    @Test func withScore_adjustsAggregateByScoreDelta() async throws {
        let match = makeMatch(
            homeScore: 0,
            awayScore: 0,
            aggregateHomeScore: 3,
            aggregateAwayScore: 3
        )

        let updated = match.withScore(home: 1, away: 0, status: "33")

        #expect(updated.homeScore == 1)
        #expect(updated.awayScore == 0)
        #expect(updated.aggregateHomeScore == 4)
        #expect(updated.aggregateAwayScore == 3)
    }

    @Test func withScore_keepsAggregateWhenBaseScoresMissing() async throws {
        let match = makeMatch(
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: 3,
            aggregateAwayScore: 3
        )

        let updated = match.withScore(home: 1, away: 0, status: "33")

        #expect(updated.aggregateHomeScore == 3)
        #expect(updated.aggregateAwayScore == 3)
    }

    @Test func matchDecodesServerControlledCompetitionWeight() async throws {
        let data = Data("""
        {
          "date": "2026-07-19",
          "time": "20:00",
          "home_team": "TBC",
          "away_team": "TBC",
          "league": "FIFA World Cup 2026",
          "league_subcategory": "Final",
          "competition_weight": 90,
          "tv_channels": []
        }
        """.utf8)

        let match = try JSONDecoder().decode(Match.self, from: data)

        #expect(match.competitionWeight == 90)
        #expect(match.displayLeague == "FIFA World Cup 2026: Final")
    }

    @Test func matchDetailsDecodesSubstitutionPlayersWithoutShirtNumbers() throws {
        let data = Data("""
        {
          "id": "213528",
          "home_goal_scorers": [
            { "player": "J. Guridi", "goal_times": ["52'"] }
          ],
          "team_lineups": {
            "home": {
              "starting_lineup": [],
              "substitutes": [],
              "substitutions": [
                {
                  "minute": "46'",
                  "player_off": { "number": null, "name": "I. Romero" },
                  "player_on": { "number": null, "name": "R. Ure" }
                }
              ]
            }
          }
        }
        """.utf8)

        let details = try JSONDecoder().decode(MatchDetailsPayload.self, from: data)
        let substitution = try #require(details.teamLineups?.home?.substitutions.first)

        #expect(details.homeGoalScorers.first?.player == "J. Guridi")
        #expect(substitution.playerOff.number == nil)
        #expect(substitution.playerOn.number == nil)
    }

    @Test func withDetails_preservesFinishedStatusWhenDetailsRegressToLiveMinute() async throws {
        let match = makeMatch(
            homeScore: 2,
            awayScore: 1,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "FT"
        )

        let updated = match.withDetails(
            makeDetailsPayload(scoreStatus: "90+7")
        )

        #expect(updated.scoreStatus == "FT")
    }

    @Test func withDetails_upgradesFirstHalfStoppageTimeToHalfTime() async throws {
        let match = makeMatch(
            homeScore: 0,
            awayScore: 1,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "45+5"
        )

        let updated = match.withDetails(
            makeDetailsPayload(scoreStatus: "HT")
        )

        #expect(updated.scoreStatus == "HT")
    }

    @Test func withLiveState_updatesScoreWithoutDiscardingExistingIncidents() throws {
        let scorer = MatchGoalScorer(player: "A. Forward", goalTimes: ["12'"])
        let match = Match(
            date: "2026-02-24",
            time: "17:45",
            homeTeam: "Atletico Madrid",
            awayTeam: "Club Brugge",
            league: "UEFA Champions League",
            matchDetailsID: "c8r1zve354lt",
            tvChannels: [],
            homeScore: 1,
            awayScore: 0,
            scoreStatus: "75",
            homeGoalScorers: [scorer]
        )
        let data = Data("""
        {
          "id": "c8r1zve354lt",
          "date": "2026-02-24",
          "time": "17:45",
          "league": "UEFA Champions League",
          "home_team": "Atletico Madrid",
          "away_team": "Club Brugge",
          "home_score": 2,
          "away_score": 0,
          "score_status": "84",
          "in_progress": true
        }
        """.utf8)
        let state = try JSONDecoder().decode(MatchDetailsPayload.self, from: data)

        let updated = match.withLiveState(state)

        #expect(updated.homeScore == 2)
        #expect(updated.awayScore == 0)
        #expect(updated.scoreStatus == "84")
        #expect(updated.homeGoalScorers == [scorer])
    }

    @Test func compactFixtureLayout_allowsBroadcastLogoForUpcomingMatchWithUnknownStatus() async throws {
        let match = makeMatch(
            date: "",
            time: "14:30",
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "scheduled"
        )

        #expect(
            MatchRow.shouldShowCompactBroadcastLogo(for: match)
        )
    }

    @Test func compactFixtureLayout_allowsBroadcastLogoForUpcomingMatchWithoutScores() async throws {
        let match = makeMatch(
            date: formattedDate(offsetDays: 1),
            time: "18:30",
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: nil
        )

        #expect(
            MatchRow.shouldShowCompactBroadcastLogo(for: match)
        )
    }

    @Test func filterMatches_fixturesAllowCanonicalNonBbcSources() async throws {
        let fixtures = [
            makeMatch(
                date: formattedDate(offsetDays: 0),
                homeScore: nil,
                awayScore: nil,
                aggregateHomeScore: nil,
                aggregateAwayScore: nil,
                scoreStatus: nil,
                matchDetailsID: nil,
                hasBbcSource: false
            ),
            makeMatch(
                date: formattedDate(offsetDays: 0),
                homeScore: nil,
                awayScore: nil,
                aggregateHomeScore: nil,
                aggregateAwayScore: nil,
                scoreStatus: nil,
                matchDetailsID: nil,
                hasBbcSource: true
            )
        ]

        let filtered = MatchesStore.filterMatches(fixtures, for: .fixtures)

        #expect(filtered.count == 2)
        #expect(filtered.contains { !$0.hasBbcMatchEntry })
        #expect(filtered.contains { $0.hasBbcMatchEntry })
    }

    @Test func filterMatches_resultsDoNotRequireBbcMatchEntry() async throws {
        let results = [
            makeMatch(
                date: formattedDate(offsetDays: -1),
                homeScore: 2,
                awayScore: 1,
                aggregateHomeScore: nil,
                aggregateAwayScore: nil,
                scoreStatus: "FT",
                matchDetailsID: nil
            )
        ]

        let filtered = MatchesStore.filterMatches(results, for: .results)

        #expect(filtered.count == 1)
    }

    @Test func applyPreferenceFilters_fixtures_doesNotReapplyServerCompetitionSelectionLocally() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: [],
            selectedChannels: [],
            competitionFilterEnabled: false,
            channelFilterEnabled: false,
            englishPremierLeagueTeamsOnly: true,
            homeNationsFilterEnabled: false,
            majorTournamentsFilterEnabled: false,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )
        let matches = [
            Match(
                date: formattedDate(offsetDays: 1),
                time: "20:00",
                homeTeam: "Arsenal",
                awayTeam: "Real Madrid",
                league: "UEFA Champions League",
                matchDetailsID: "premteam",
                hasBbcSource: true,
                tvChannels: []
            ),
            Match(
                date: formattedDate(offsetDays: 1),
                time: "20:00",
                homeTeam: "Real Madrid",
                awayTeam: "Barcelona",
                league: "La Liga",
                matchDetailsID: "nonpremteam",
                hasBbcSource: true,
                tvChannels: []
            )
        ]

        let filtered = MatchesStore.applyPreferenceFilters(
            to: matches,
            snapshot: snapshot,
            mode: .fixtures
        )

        #expect(filtered.compactMap(\.matchDetailsID) == ["premteam", "nonpremteam"])
    }

    @Test func applyPreferenceFilters_fixtures_doesNotReapplyServerCategorySelectionLocally() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: [],
            selectedChannels: [],
            competitionFilterEnabled: false,
            channelFilterEnabled: false,
            englishPremierLeagueTeamsOnly: true,
            majorUEFAClubGamesEnabled: true,
            homeNationsFilterEnabled: false,
            majorTournamentsFilterEnabled: false,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )
        let matches = [
            Match(
                date: formattedDate(offsetDays: 9),
                time: "20:00",
                homeTeam: "Arsenal",
                awayTeam: "Sporting CP",
                league: "UEFA Champions League Quarter-Final 2nd Leg",
                leagueSubcategory: "Quarter-finals",
                matchDetailsID: "arsenalucl",
                hasBbcSource: true,
                tvChannels: []
            ),
            Match(
                date: formattedDate(offsetDays: 9),
                time: "19:45",
                homeTeam: "AFC Wimbledon",
                awayTeam: "Stockport County",
                league: "League One",
                matchDetailsID: "leagueone",
                hasBbcSource: true,
                tvChannels: []
            )
        ]

        let filtered = MatchesStore.applyPreferenceFilters(
            to: matches,
            snapshot: snapshot,
            mode: .fixtures
        )

        #expect(filtered.compactMap(\.matchDetailsID) == ["arsenalucl", "leagueone"])
    }

    @Test func applyPreferenceFilters_fixtures_doesNotReapplyServerLeagueSelectionLocally() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: ["UEFA Champions League"],
            selectedChannels: [],
            competitionFilterEnabled: true,
            channelFilterEnabled: false,
            englishPremierLeagueTeamsOnly: false,
            majorUEFAClubGamesEnabled: false,
            homeNationsFilterEnabled: false,
            majorTournamentsFilterEnabled: false,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )
        let matches = [
            Match(
                date: formattedDate(offsetDays: 9),
                time: "20:00",
                homeTeam: "Arsenal",
                awayTeam: "Sporting CP",
                league: "UEFA Champions League Quarter-Final 2nd Leg",
                leagueSubcategory: "Quarter-finals",
                matchDetailsID: "arsenalucl",
                hasBbcSource: true,
                tvChannels: []
            ),
            Match(
                date: formattedDate(offsetDays: 9),
                time: "20:00",
                homeTeam: "Sevilla",
                awayTeam: "Valencia",
                league: "La Liga",
                matchDetailsID: "laliga",
                hasBbcSource: true,
                tvChannels: []
            )
        ]

        let filtered = MatchesStore.applyPreferenceFilters(
            to: matches,
            snapshot: snapshot,
            mode: .fixtures
        )

        #expect(filtered.compactMap(\.matchDetailsID) == ["arsenalucl", "laliga"])
    }

    @Test func applyPreferenceFilters_results_showAllCompetitionsWhenFiltersAreOff() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: ["UEFA Champions League"],
            selectedChannels: [],
            competitionFilterEnabled: false,
            channelFilterEnabled: false,
            englishPremierLeagueTeamsOnly: false,
            majorUEFAClubGamesEnabled: true,
            homeNationsFilterEnabled: true,
            majorTournamentsFilterEnabled: true,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )
        let matches = [
            Match(
                date: formattedDate(offsetDays: -2),
                time: "20:00",
                homeTeam: "Manchester United",
                awayTeam: "Brentford",
                league: "Premier League",
                matchDetailsID: "manutdbrentford",
                hasBbcSource: true,
                tvChannels: [],
                homeScore: 2,
                awayScore: 1,
                scoreStatus: "FT"
            ),
            Match(
                date: formattedDate(offsetDays: -2),
                time: "20:00",
                homeTeam: "PSG",
                awayTeam: "Bayern Munich",
                league: "UEFA Champions League",
                leagueSubcategory: "Semi-finals",
                matchDetailsID: "psgbayern",
                hasBbcSource: true,
                tvChannels: [],
                homeScore: 5,
                awayScore: 4,
                scoreStatus: "FT"
            )
        ]

        let filtered = MatchesStore.applyPreferenceFilters(
            to: matches,
            snapshot: snapshot,
            mode: .results
        )

        #expect(filtered.compactMap(\.matchDetailsID) == ["manutdbrentford", "psgbayern"])
    }

    @Test func applyPreferenceFilters_results_doesNotReapplyServerCompetitionSelectionLocally() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: ["Premier League"],
            selectedChannels: [],
            competitionFilterEnabled: true,
            channelFilterEnabled: false,
            englishPremierLeagueTeamsOnly: false,
            majorUEFAClubGamesEnabled: false,
            homeNationsFilterEnabled: false,
            majorTournamentsFilterEnabled: false,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )
        let matches = [
            Match(
                date: formattedDate(offsetDays: -2),
                time: "20:00",
                homeTeam: "Manchester United",
                awayTeam: "Brentford",
                league: "Premier League",
                matchDetailsID: "manutdbrentford",
                hasBbcSource: true,
                tvChannels: [],
                homeScore: 2,
                awayScore: 1,
                scoreStatus: "FT"
            ),
            Match(
                date: formattedDate(offsetDays: -2),
                time: "20:00",
                homeTeam: "PSG",
                awayTeam: "Bayern Munich",
                league: "UEFA Champions League",
                matchDetailsID: "psgbayern",
                hasBbcSource: true,
                tvChannels: [],
                homeScore: 5,
                awayScore: 4,
                scoreStatus: "FT"
            )
        ]

        let filtered = MatchesStore.applyPreferenceFilters(
            to: matches,
            snapshot: snapshot,
            mode: .results
        )

        #expect(filtered.compactMap(\.matchDetailsID) == ["manutdbrentford", "psgbayern"])
    }

    @Test func applyPreferenceFilters_results_emptySelectionDoesNotHideServerResultsLocally() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: [],
            selectedChannels: [],
            competitionFilterEnabled: true,
            channelFilterEnabled: false,
            englishPremierLeagueTeamsOnly: false,
            majorUEFAClubGamesEnabled: false,
            homeNationsFilterEnabled: false,
            majorTournamentsFilterEnabled: false,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )
        let matches = [
            Match(
                date: formattedDate(offsetDays: -2),
                time: "20:00",
                homeTeam: "Manchester United",
                awayTeam: "Brentford",
                league: "Premier League",
                matchDetailsID: "manutdbrentford",
                hasBbcSource: true,
                tvChannels: [],
                homeScore: 2,
                awayScore: 1,
                scoreStatus: "FT"
            )
        ]

        let filtered = MatchesStore.applyPreferenceFilters(
            to: matches,
            snapshot: snapshot,
            mode: .results
        )

        #expect(filtered.compactMap(\.matchDetailsID) == ["manutdbrentford"])
    }

    @Test func applyPreferenceFilters_fixtures_doesNotReapplyServerTournamentSelectionLocally() async throws {
        let snapshot = PreferencesSnapshot(
            selectedLeagues: [],
            selectedChannels: [],
            competitionFilterEnabled: false,
            channelFilterEnabled: false,
            englishPremierLeagueTeamsOnly: true,
            homeNationsFilterEnabled: false,
            majorTournamentsFilterEnabled: true,
            apiBaseURL: PreferencesStore.defaultApiBaseURL,
            refreshIntervalMinutes: PreferencesStore.defaultRefreshIntervalMinutes
        )
        let matches = [
            Match(
                date: formattedDate(offsetDays: 2),
                time: "20:00",
                homeTeam: "TBC",
                awayTeam: "TBC",
                league: "FIFA World Cup",
                leagueSubcategory: "Final",
                matchDetailsID: "worldcupfinal",
                hasBbcSource: true,
                tvChannels: []
            ),
            Match(
                date: formattedDate(offsetDays: 2),
                time: "20:00",
                homeTeam: "England",
                awayTeam: "France",
                league: "UEFA European Championship 2028",
                matchDetailsID: "major",
                hasBbcSource: true,
                tvChannels: []
            ),
            Match(
                date: formattedDate(offsetDays: 2),
                time: "20:00",
                homeTeam: "Brazil",
                awayTeam: "Argentina",
                league: "FIFA World Cup Qualifying - South America",
                matchDetailsID: "qualifying",
                hasBbcSource: true,
                tvChannels: []
            )
        ]

        let filtered = MatchesStore.applyPreferenceFilters(
            to: matches,
            snapshot: snapshot,
            mode: .fixtures
        )

        #expect(filtered.compactMap(\.matchDetailsID) == ["worldcupfinal", "major", "qualifying"])
    }

    @Test func hasBbcMatchEntry_acceptsLegacyBbcSportWebsiteChannel() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "15:00",
            homeTeam: "Arsenal",
            awayTeam: "Chelsea",
            league: "Premier League",
            matchDetailsID: nil,
            hasBbcSource: nil,
            tvChannels: [
                TvChannel(name: "Sky Sports Main Event"),
                TvChannel(name: "BBC Sport Website")
            ]
        )

        #expect(match.hasBbcMatchEntry)
    }

    @Test func matchStatusFormatter_prefersHalfTimeOverFirstHalfStoppageTime() async throws {
        #expect(MatchStatusFormatter.preferredStatus(current: "45+5", incoming: "HT") == "HT")
        #expect(MatchStatusFormatter.preferredStatus(current: "HT", incoming: "45+5") == "HT")
        #expect(MatchStatusFormatter.preferredStatus(current: "47", incoming: "HT") == "47")
    }

    @Test func stabilizedScoreStatus_clampsOverdueLiveMatchesToFullTime() async throws {
        let match = makeMatch(
            date: "2026-03-07",
            time: "15:00",
            homeScore: 1,
            awayScore: 0,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "90+7"
        )
        let kickoff = try #require(match.dateTime)
        let now = kickoff.addingTimeInterval((3.5 * 60 * 60) + 60)

        #expect(match.stabilizedScoreStatus(now: now) == "FT")
    }

    @Test func winnerSummaryText_formatsPenaltyShootoutWinners() async throws {
        let match = Match(
            date: "2026-03-01",
            time: "19:45",
            homeTeam: "West Ham United",
            awayTeam: "Brentford",
            league: "FA Cup",
            tvChannels: [],
            homeScore: 1,
            awayScore: 1,
            scoreStatus: "AET",
            penaltyResult: "West Ham United win 5-3 on penalties"
        )

        #expect(match.winnerSummaryText == "West Ham United win 5 - 3 on penalties")
    }

    @Test func displayScoreStatus_formatsHomeAwayPenaltyTallyForHomeWinner() async throws {
        let match = Match(
            date: "2026-03-01",
            time: "19:45",
            homeTeam: "West Ham United",
            awayTeam: "Brentford",
            league: "FA Cup",
            tvChannels: [],
            homeScore: 1,
            awayScore: 1,
            scoreStatus: "AET",
            penaltyResult: "West Ham United win 5-3 on penalties"
        )

        #expect(match.displayScoreStatus == "P 5-3")
    }

    @Test func displayScoreStatus_formatsHomeAwayPenaltyTallyForAwayWinner() async throws {
        let match = Match(
            date: "2026-04-18",
            time: "20:00",
            homeTeam: "Atlético Madrid",
            awayTeam: "Real Sociedad",
            league: "Copa del Rey",
            tvChannels: [],
            homeScore: 2,
            awayScore: 2,
            scoreStatus: "AET",
            penaltyResult: "Real Sociedad win 4 - 3 on penalties"
        )

        #expect(match.displayScoreStatus == "P 3-4")
    }

    @Test func winnerSummaryText_formatsAggregateWinners() async throws {
        let match = Match(
            date: "2026-02-25",
            time: "20:00",
            homeTeam: "Paris Saint-Germain",
            awayTeam: "Monaco",
            league: "UEFA Champions League",
            leagueSubcategory: "Knockout Round Play-offs",
            tvChannels: [],
            homeScore: 2,
            awayScore: 2,
            aggregateHomeScore: 5,
            aggregateAwayScore: 4,
            scoreStatus: "FT"
        )

        #expect(match.winnerSummaryText == "Paris Saint-Germain win 5 - 4 on aggregate")
    }

    @Test func upcomingScorelessFixture_showsAggregateBracketScoresInline() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "20:00",
            homeTeam: "Aston Villa",
            awayTeam: "Lille",
            league: "UEFA Europa League",
            tvChannels: [],
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: 1,
            aggregateAwayScore: 0,
            scoreStatus: nil
        )

        #expect(match.shouldShowAggregateBracketScoresInline)
    }

    @Test func upcomingScorelessFixture_hidesPlaceholderAggregateBracketScores() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "20:00",
            homeTeam: "Aston Villa",
            awayTeam: "Lille",
            league: "UEFA Europa League",
            tvChannels: [],
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: 0,
            aggregateAwayScore: 0,
            scoreStatus: nil
        )

        #expect(!match.shouldShowAggregateBracketScoresInline)
    }

    @Test func upcomingScorelessFixture_showsKnownZeroAggregateBracketScoresInline() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "17:45",
            homeTeam: "AEK Larnaca",
            awayTeam: "Crystal Palace",
            league: "UEFA Conference League",
            leagueSubcategory: "Last 16",
            tvChannels: [],
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: 0,
            aggregateAwayScore: 0,
            firstLegHomeScore: 0,
            firstLegAwayScore: 0,
            scoreStatus: nil
        )

        #expect(match.shouldShowAggregateBracketScoresInline)
        #expect(match.aggregateSummaryText == "Agg: 0-0")
    }

    @Test func upcomingScorelessFixture_usesFirstLegScoresWhenAggregateIsMissing() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "20:00",
            homeTeam: "Atletico Madrid",
            awayTeam: "Barcelona",
            league: "UEFA Champions League",
            leagueSubcategory: "Semi-finals",
            tvChannels: [],
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            firstLegHomeScore: 2,
            firstLegAwayScore: 0,
            scoreStatus: nil
        )

        #expect(match.shouldShowAggregateBracketScoresInline)
        #expect(match.resolvedAggregateHomeScore == 2)
        #expect(match.resolvedAggregateAwayScore == 0)
        #expect(match.aggregateSummaryText == "Agg: 2-0")
    }

    @Test func withScore_derivesAggregateFromFirstLegWhenAggregateIsMissing() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "20:00",
            homeTeam: "Liverpool",
            awayTeam: "Paris Saint-Germain",
            league: "UEFA Champions League",
            leagueSubcategory: "Semi-finals",
            tvChannels: [],
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            firstLegHomeScore: 0,
            firstLegAwayScore: 2,
            scoreStatus: nil
        )

        let updated = match.withScore(home: 1, away: 0, status: "12'")

        #expect(updated.aggregateHomeScore == 1)
        #expect(updated.aggregateAwayScore == 2)
        #expect(updated.aggregateSummaryText == "Agg: 1-2")
    }

    @Test func compactFixtureBroadcast_allowsLogoWhenAggregateBracketsShow() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "20:00",
            homeTeam: "Atletico Madrid",
            awayTeam: "Barcelona",
            league: "UEFA Champions League",
            leagueSubcategory: "Quarter-finals",
            tvChannels: [TvChannel(name: "TNT Sports 1")],
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: 2,
            aggregateAwayScore: 0,
            scoreStatus: nil
        )

        #expect(
            MatchRow.shouldShowCompactBroadcastLogo(for: match)
        )
    }

    @Test func compactFixtureBroadcast_allowsLogoForStandardPreKickoffFixtures() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "20:00",
            homeTeam: "Arsenal",
            awayTeam: "Sporting CP",
            league: "UEFA Champions League",
            leagueSubcategory: "Quarter-finals",
            tvChannels: [TvChannel(name: "TNT Sports 1")],
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: nil
        )

        #expect(
            MatchRow.shouldShowCompactBroadcastLogo(for: match)
        )
    }

    @Test func compactFixtureBroadcast_allowsLogoForUnfinishedMatchWithoutChannels() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "15:00",
            homeTeam: "Leeds United",
            awayTeam: "Wolverhampton Wanderers",
            league: "Premier League",
            tvChannels: [],
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: nil
        )

        #expect(
            MatchRow.shouldShowCompactBroadcastLogo(for: match)
        )
    }

    @Test func compactFixtureBroadcast_allowsLogoForPostponedFixtures() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "14:00",
            homeTeam: "Burnley",
            awayTeam: "Manchester City",
            league: "Premier League",
            tvChannels: [TvChannel(name: "Sky Sports Main Event")],
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "POSTPONED"
        )

        #expect(
            MatchRow.shouldShowCompactBroadcastLogo(for: match)
        )
    }

    @Test func compactFixtureBroadcast_hidesLogoForFullTimeFixtures() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "19:45",
            homeTeam: "Chelsea",
            awayTeam: "Leeds United",
            league: "FA Cup",
            tvChannels: [TvChannel(name: "BBC One")],
            homeScore: 2,
            awayScore: 1,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "FT"
        )

        #expect(!MatchRow.shouldShowCompactBroadcastLogo(for: match))
    }

    @Test func compactFixtureBroadcast_hidesLogoForAfterExtraTimeFixtures() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "20:00",
            homeTeam: "Inter Milan",
            awayTeam: "Napoli",
            league: "Coppa Italia",
            tvChannels: [TvChannel(name: "TNT Sports 2")],
            homeScore: 3,
            awayScore: 2,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "AET"
        )

        #expect(!MatchRow.shouldShowCompactBroadcastLogo(for: match))
    }

    @Test func compactFixtureBroadcast_allowsLogoForLiveFixtures() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "12:30",
            homeTeam: "Brentford",
            awayTeam: "Fulham",
            league: "Premier League",
            tvChannels: [TvChannel(name: "Sky Sports")],
            homeScore: 1,
            awayScore: 0,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "38'"
        )

        #expect(
            MatchRow.shouldShowCompactBroadcastLogo(for: match)
        )
    }

    @Test func compactFixture_showsInlineAggregateBracketsForLiveMatches() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "20:00",
            homeTeam: "Atletico Madrid",
            awayTeam: "Barcelona",
            league: "UEFA Champions League",
            leagueSubcategory: "Quarter-finals",
            tvChannels: [TvChannel(name: "TNT Sports 1")],
            homeScore: 1,
            awayScore: 0,
            aggregateHomeScore: 3,
            aggregateAwayScore: 2,
            scoreStatus: "38'"
        )

        #expect(
            MatchRow.shouldShowInlineAggregateBrackets(
                match: match,
                layoutStyle: .compactFixture,
                showsFinishedInlineAggregateBrackets: false
            )
        )
    }

    @Test func compactFixture_showsInlineAggregateBracketsForFinishedMatches() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "20:00",
            homeTeam: "Atletico Madrid",
            awayTeam: "Barcelona",
            league: "UEFA Champions League",
            leagueSubcategory: "Quarter-finals",
            tvChannels: [TvChannel(name: "TNT Sports 1")],
            homeScore: 1,
            awayScore: 2,
            aggregateHomeScore: 3,
            aggregateAwayScore: 2,
            scoreStatus: "FT"
        )

        #expect(
            MatchRow.shouldShowInlineAggregateBrackets(
                match: match,
                layoutStyle: .compactFixture,
                showsFinishedInlineAggregateBrackets: false
            )
        )
    }

    @Test func standardMatchRow_showsInlineAggregateBracketsWhenEnabledForResults() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "20:00",
            homeTeam: "Atletico Madrid",
            awayTeam: "Barcelona",
            league: "UEFA Champions League",
            leagueSubcategory: "Quarter-finals",
            tvChannels: [TvChannel(name: "TNT Sports 1")],
            homeScore: 1,
            awayScore: 2,
            aggregateHomeScore: 3,
            aggregateAwayScore: 2,
            scoreStatus: "FT"
        )

        #expect(
            MatchRow.shouldShowInlineAggregateBrackets(
                match: match,
                layoutStyle: .standard,
                showsFinishedInlineAggregateBrackets: true
            )
        )
    }

    @Test func standardMatchRow_keepsFinishedAggregateOutOfInlineBracketsByDefault() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "20:00",
            homeTeam: "Atletico Madrid",
            awayTeam: "Barcelona",
            league: "UEFA Champions League",
            leagueSubcategory: "Quarter-finals",
            tvChannels: [TvChannel(name: "TNT Sports 1")],
            homeScore: 1,
            awayScore: 2,
            aggregateHomeScore: 3,
            aggregateAwayScore: 2,
            scoreStatus: "FT"
        )

        #expect(
            !MatchRow.shouldShowInlineAggregateBrackets(
                match: match,
                layoutStyle: .standard,
                showsFinishedInlineAggregateBrackets: false
            )
        )
    }

    @Test func withDetails_preservesAggregateForUpcomingScorelessFixture() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "17:45",
            homeTeam: "Midtjylland",
            awayTeam: "Nottingham Forest",
            league: "UEFA Europa League",
            leagueSubcategory: "Last 16",
            detailsURL: "https://www.bbc.co.uk/sport/football/live/c8r1zve354lt",
            matchDetailsID: "c8r1zve354lt",
            tvChannels: [],
            homeScore: nil,
            awayScore: nil,
            aggregateHomeScore: 1,
            aggregateAwayScore: 0,
            firstLegHomeScore: 1,
            firstLegAwayScore: 0,
            scoreStatus: nil
        )

        let payload: [String: Any?] = [
            "id": "c8r1zve354lt",
            "details_url": "https://www.bbc.co.uk/sport/football/live/c8r1zve354lt",
            "date": formattedDate(offsetDays: 0),
            "time": "17:45",
            "league": "UEFA Europa League",
            "home_team": "Midtjylland",
            "away_team": "Nottingham Forest",
            "home_score": nil,
            "away_score": nil,
            "aggregate_home_score": 1,
            "aggregate_away_score": 0,
            "first_leg_home_score": 1,
            "first_leg_away_score": 0,
            "score_status": nil,
            "home_goal_scorers": [],
            "away_goal_scorers": [],
            "home_assists": [],
            "away_assists": [],
            "home_red_cards": [],
            "away_red_cards": [],
            "penalty_result": nil,
            "in_progress": false,
            "updated_at": "2026-03-19T01:42:59.740Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
        let details = try JSONDecoder().decode(MatchDetailsPayload.self, from: data)

        let merged = match.withDetails(details)

        #expect(merged.homeScore == nil)
        #expect(merged.awayScore == nil)
        #expect(merged.aggregateHomeScore == 1)
        #expect(merged.aggregateAwayScore == 0)
        #expect(merged.firstLegHomeScore == 1)
        #expect(merged.firstLegAwayScore == 0)
        #expect(merged.shouldShowAggregateBracketScoresInline)
    }

    @Test func winnerSummaryText_formatsExtraTimeWinners() async throws {
        let match = Match(
            date: "2026-03-01",
            time: "20:00",
            homeTeam: "Chelsea",
            awayTeam: "Liverpool",
            league: "FA Cup",
            tvChannels: [],
            homeScore: 2,
            awayScore: 1,
            scoreStatus: "AET"
        )

        #expect(match.winnerSummaryText == "Chelsea win 2 - 1 after extra time")
    }

    @Test @MainActor func mergeRefreshedMatches_preservesTerminalStateAcrossResetRefresh() async throws {
        let existing = makeMatch(
            date: "2026-03-07",
            time: "15:00",
            homeScore: 2,
            awayScore: 1,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "FT"
        )
        let incoming = makeMatch(
            date: "2026-03-07",
            time: "15:00",
            homeScore: 2,
            awayScore: 1,
            aggregateHomeScore: nil,
            aggregateAwayScore: nil,
            scoreStatus: "90+7"
        )

        let merged = MatchesStore.mergeRefreshedMatches(existing: [existing], incoming: [incoming])

        #expect(merged.count == 1)
        #expect(merged[0].scoreStatus == "FT")
    }

    @Test func matchScoreResolver_applyScores_acceptsHalfTimeAfterFirstHalfStoppageTime() async throws {
        let match = Match(
            date: formattedDate(offsetDays: 0),
            time: "17:30",
            homeTeam: "Chelsea",
            awayTeam: "Newcastle United",
            league: "Premier League",
            tvChannels: [],
            homeScore: 0,
            awayScore: 1,
            scoreStatus: "45+5"
        )

        let updated = MatchScoreResolver.applyScores(
            to: [match],
            using: [makeBbcMatch(
                homeTeam: "Chelsea",
                awayTeam: "Newcastle United",
                homeScore: 0,
                awayScore: 1,
                matchTime: "HT"
            )]
        )

        #expect(updated.count == 1)
        #expect(updated[0].scoreStatus == "HT")
    }

    @Test func fantasySquadDisplayData_matchSquadSection_splitsStartersAndBenchByTeam() async throws {
        let squad = FantasySquadDisplayData(
            gameweekID: 29,
            gameweekTitle: "GW29",
            deadlineGameweekID: nil,
            deadlineTime: nil,
            totalPoints: 0,
            hasActiveFixtures: false,
            hasStartedFixturesInGameweek: false,
            hasFixturesPlayedToday: false,
            isEstimatedScore: false,
            estimatedCurrentScore: 0,
            scoreCalculationRulesApplied: [],
            rank: nil,
            overallRank: nil,
            transfersCost: nil,
            pointsOnBench: nil,
            activeChips: [],
            goalkeepers: [
                makeFantasyPlayer(
                    elementID: 1,
                    pickPosition: 1,
                    positionType: .goalkeeper,
                    displayName: "Trafford",
                    fullName: "James Trafford",
                    teamName: "Burnley"
                )
            ],
            defenders: [],
            midfielders: [
                makeFantasyPlayer(
                    elementID: 2,
                    pickPosition: 6,
                    positionType: .midfielder,
                    displayName: "Brownhill",
                    fullName: "Josh Brownhill",
                    teamName: "Burnley"
                ),
                makeFantasyPlayer(
                    elementID: 3,
                    pickPosition: 7,
                    positionType: .midfielder,
                    displayName: "Saka",
                    fullName: "Bukayo Saka",
                    teamName: "Arsenal"
                )
            ],
            forwards: [],
            bench: [
                makeFantasyPlayer(
                    elementID: 4,
                    pickPosition: 12,
                    positionType: .goalkeeper,
                    displayName: "Foster",
                    fullName: "Mark Flekken Foster",
                    teamName: "Burnley"
                ),
                makeFantasyPlayer(
                    elementID: 5,
                    pickPosition: 13,
                    positionType: .defender,
                    displayName: "Mykolenko",
                    fullName: "Vitalii Mykolenko",
                    teamName: "Everton"
                )
            ]
        )

        let section = squad.matchSquadSection(forTeamName: "Burnley")

        #expect(section?.teamName == "Burnley")
        #expect(section?.starters.map(\.displayName) == ["Trafford", "Brownhill"])
        #expect(section?.bench.map(\.displayName) == ["Foster"])
    }

    @Test func fantasySquadBuilder_countsBenchBoostBenchPointsInCurrentScore() async throws {
        let gameweek = FantasyGameweek(
            id: 30,
            name: "Gameweek 30",
            isCurrent: true,
            isNext: false,
            finished: false,
            deadlineTime: "2026-03-14T11:00:00Z"
        )
        let bootstrap = FantasyBootstrapLookup(
            updatedAt: nil,
            elements: [
                makeFantasyBootstrapElement(id: 1, team: 1, elementType: 1, webName: "Keeper A"),
                makeFantasyBootstrapElement(id: 2, team: 1, elementType: 2, webName: "Def A"),
                makeFantasyBootstrapElement(id: 3, team: 1, elementType: 2, webName: "Def B"),
                makeFantasyBootstrapElement(id: 4, team: 1, elementType: 2, webName: "Def C"),
                makeFantasyBootstrapElement(id: 5, team: 1, elementType: 3, webName: "Mid A"),
                makeFantasyBootstrapElement(id: 6, team: 1, elementType: 3, webName: "Mid B"),
                makeFantasyBootstrapElement(id: 7, team: 1, elementType: 3, webName: "Mid C"),
                makeFantasyBootstrapElement(id: 8, team: 1, elementType: 4, webName: "Fwd A"),
                makeFantasyBootstrapElement(id: 9, team: 1, elementType: 4, webName: "Fwd B"),
                makeFantasyBootstrapElement(id: 10, team: 1, elementType: 3, webName: "Mid D"),
                makeFantasyBootstrapElement(id: 11, team: 1, elementType: 2, webName: "Def D"),
                makeFantasyBootstrapElement(id: 12, team: 2, elementType: 1, webName: "Keeper B"),
                makeFantasyBootstrapElement(id: 13, team: 2, elementType: 2, webName: "Bench Def"),
                makeFantasyBootstrapElement(id: 14, team: 2, elementType: 3, webName: "Bench Mid"),
                makeFantasyBootstrapElement(id: 15, team: 2, elementType: 4, webName: "Bench Fwd")
            ],
            teams: [
                FantasyBootstrapTeam(id: 1, name: "Arsenal", shortName: "ARS"),
                FantasyBootstrapTeam(id: 2, name: "Everton", shortName: "EVE")
            ],
            elementTypes: [
                FantasyBootstrapElementType(id: 1, singularName: "Goalkeeper", singularNameShort: "GKP"),
                FantasyBootstrapElementType(id: 2, singularName: "Defender", singularNameShort: "DEF"),
                FantasyBootstrapElementType(id: 3, singularName: "Midfielder", singularNameShort: "MID"),
                FantasyBootstrapElementType(id: 4, singularName: "Forward", singularNameShort: "FWD")
            ],
            events: [gameweek]
        )
        let picks = FantasyPicksResponse(
            picks: [
                makeFantasyPick(element: 1, position: 1, elementType: 1),
                makeFantasyPick(element: 2, position: 2, elementType: 2),
                makeFantasyPick(element: 3, position: 3, elementType: 2),
                makeFantasyPick(element: 4, position: 4, elementType: 2),
                makeFantasyPick(element: 5, position: 5, elementType: 3),
                makeFantasyPick(element: 6, position: 6, elementType: 3),
                makeFantasyPick(element: 7, position: 7, elementType: 3),
                makeFantasyPick(element: 8, position: 8, elementType: 4),
                makeFantasyPick(element: 9, position: 9, elementType: 4),
                makeFantasyPick(element: 10, position: 10, elementType: 3),
                makeFantasyPick(element: 11, position: 11, elementType: 2),
                makeFantasyPick(element: 12, position: 12, elementType: 1),
                makeFantasyPick(element: 13, position: 13, elementType: 2),
                makeFantasyPick(element: 14, position: 14, elementType: 3),
                makeFantasyPick(element: 15, position: 15, elementType: 4)
            ],
            entryHistory: FantasyEntryHistory(
                event: 30,
                points: 7,
                rank: nil,
                overallRank: nil,
                eventTransfersCost: nil,
                pointsOnBench: 11
            ),
            activeChipCodes: ["bboost"]
        )
        let liveResponse = FantasyEventLiveResponse(
            elements: [
                makeLiveElement(id: 1, points: 0),
                makeLiveElement(id: 2, points: 0),
                makeLiveElement(id: 3, points: 0),
                makeLiveElement(id: 4, points: 0),
                makeLiveElement(id: 5, points: 2),
                makeLiveElement(id: 6, points: 3),
                makeLiveElement(id: 7, points: 2),
                makeLiveElement(id: 8, points: 0),
                makeLiveElement(id: 9, points: 0),
                makeLiveElement(id: 10, points: 0),
                makeLiveElement(id: 11, points: 0),
                makeLiveElement(id: 12, points: 0),
                makeLiveElement(id: 13, points: 8),
                makeLiveElement(id: 14, points: 3),
                makeLiveElement(id: 15, points: 0)
            ]
        )
        let fixtures = [
            FantasyFixture(
                id: 101,
                event: 30,
                teamH: 1,
                teamA: 2,
                kickoffTime: "2026-03-14T15:00:00Z",
                started: true,
                finished: false,
                finishedProvisional: false
            )
        ]

        let squad = FantasySquadBuilder.build(
            gameweek: gameweek,
            picksResponse: picks,
            liveResponse: liveResponse,
            fixtures: fixtures,
            seasonFixtures: fixtures,
            bootstrap: bootstrap,
            now: Date(timeIntervalSince1970: 1_773_571_200)
        )

        #expect(squad.hasBenchBoostActive)
        #expect(squad.resolvedCurrentScore == 18)
        #expect(squad.resolvedCurrentScoreDisplay == "18*")
        #expect(squad.activeChipSummaryText == "Active chip: Bench Boost")
        #expect(
            squad.effectivePlayerContributions.contains {
                $0.elementID == 13 && $0.points == 8
            }
        )
        #expect(
            squad.effectivePlayerContributions.contains {
                $0.elementID == 14 && $0.points == 3
            }
        )
    }

    @Test func fantasySquadDisplayData_sumsOfficialExpectedPointsForStartersOnly() async throws {
        let squad = FantasySquadDisplayData(
            gameweekID: 1,
            gameweekTitle: "GW1",
            deadlineGameweekID: 1,
            deadlineTime: nil,
            totalPoints: 0,
            hasActiveFixtures: false,
            hasStartedFixturesInGameweek: false,
            hasFixturesPlayedToday: false,
            isEstimatedScore: false,
            estimatedCurrentScore: 0,
            scoreCalculationRulesApplied: [],
            rank: nil,
            overallRank: nil,
            transfersCost: nil,
            pointsOnBench: nil,
            activeChips: [],
            goalkeepers: [
                makeFantasyPlayer(
                    elementID: 1,
                    pickPosition: 1,
                    positionType: .goalkeeper,
                    displayName: "Keeper",
                    fullName: "Test Keeper",
                    teamName: "Arsenal",
                    officialExpectedPointsNextGameweek: 3.2
                )
            ],
            defenders: [
                makeFantasyPlayer(
                    elementID: 2,
                    pickPosition: 2,
                    positionType: .defender,
                    displayName: "Captain",
                    fullName: "Test Captain",
                    teamName: "Arsenal",
                    multiplier: 2,
                    officialExpectedPointsNextGameweek: 4.5
                )
            ],
            midfielders: [],
            forwards: [],
            bench: [
                makeFantasyPlayer(
                    elementID: 3,
                    pickPosition: 12,
                    positionType: .midfielder,
                    displayName: "Bench",
                    fullName: "Test Bench",
                    teamName: "Arsenal",
                    officialExpectedPointsNextGameweek: 9.9
                )
            ]
        )

        #expect(abs((squad.officialExpectedPointsNextGameweek ?? 0) - 12.2) < 0.001)
    }

    @Test func fantasySquadBuilder_appliesBenchPointsForLiveZeroMinuteStarter() async throws {
        let gameweek = FantasyGameweek(
            id: 30,
            name: "Gameweek 30",
            isCurrent: true,
            isNext: false,
            finished: false,
            deadlineTime: "2026-03-14T11:00:00Z"
        )
        let bootstrap = FantasyBootstrapLookup(
            updatedAt: nil,
            elements: [
                makeFantasyBootstrapElement(id: 1, team: 1, elementType: 1, webName: "Keeper A"),
                makeFantasyBootstrapElement(id: 2, team: 1, elementType: 2, webName: "Def A"),
                makeFantasyBootstrapElement(id: 3, team: 1, elementType: 2, webName: "Def B"),
                makeFantasyBootstrapElement(id: 4, team: 1, elementType: 2, webName: "Def C"),
                makeFantasyBootstrapElement(id: 5, team: 1, elementType: 3, webName: "Mid A"),
                makeFantasyBootstrapElement(id: 6, team: 1, elementType: 3, webName: "Mid B"),
                makeFantasyBootstrapElement(id: 7, team: 1, elementType: 3, webName: "Mid C"),
                makeFantasyBootstrapElement(id: 8, team: 1, elementType: 3, webName: "Mid D"),
                makeFantasyBootstrapElement(id: 9, team: 1, elementType: 3, webName: "Mid E"),
                makeFantasyBootstrapElement(id: 10, team: 2, elementType: 4, webName: "Fwd A"),
                makeFantasyBootstrapElement(id: 11, team: 3, elementType: 4, webName: "Fwd B"),
                makeFantasyBootstrapElement(id: 12, team: 4, elementType: 1, webName: "Keeper B"),
                makeFantasyBootstrapElement(id: 13, team: 5, elementType: 2, webName: "Bench Def"),
                makeFantasyBootstrapElement(id: 14, team: 5, elementType: 3, webName: "Bench Mid"),
                makeFantasyBootstrapElement(id: 15, team: 5, elementType: 4, webName: "Bench Fwd")
            ],
            teams: [
                FantasyBootstrapTeam(id: 1, name: "Arsenal", shortName: "ARS"),
                FantasyBootstrapTeam(id: 2, name: "Liverpool", shortName: "LIV"),
                FantasyBootstrapTeam(id: 3, name: "Manchester City", shortName: "MCI"),
                FantasyBootstrapTeam(id: 4, name: "Burnley", shortName: "BUR"),
                FantasyBootstrapTeam(id: 5, name: "Leeds United", shortName: "LEE"),
                FantasyBootstrapTeam(id: 6, name: "Tottenham Hotspur", shortName: "TOT")
            ],
            elementTypes: [
                FantasyBootstrapElementType(id: 1, singularName: "Goalkeeper", singularNameShort: "GKP"),
                FantasyBootstrapElementType(id: 2, singularName: "Defender", singularNameShort: "DEF"),
                FantasyBootstrapElementType(id: 3, singularName: "Midfielder", singularNameShort: "MID"),
                FantasyBootstrapElementType(id: 4, singularName: "Forward", singularNameShort: "FWD")
            ],
            events: [gameweek]
        )
        let picks = FantasyPicksResponse(
            picks: [
                makeFantasyPick(element: 1, position: 1, elementType: 1),
                makeFantasyPick(element: 2, position: 2, elementType: 2),
                makeFantasyPick(element: 3, position: 3, elementType: 2),
                makeFantasyPick(element: 4, position: 4, elementType: 2),
                makeFantasyPick(element: 5, position: 5, elementType: 3),
                makeFantasyPick(element: 6, position: 6, elementType: 3),
                makeFantasyPick(element: 7, position: 7, elementType: 3),
                makeFantasyPick(element: 8, position: 8, elementType: 3),
                makeFantasyPick(element: 9, position: 9, elementType: 3),
                makeFantasyPick(element: 10, position: 10, elementType: 4),
                makeFantasyPick(element: 11, position: 11, elementType: 4),
                makeFantasyPick(element: 12, position: 12, elementType: 1),
                makeFantasyPick(element: 13, position: 13, elementType: 2),
                makeFantasyPick(element: 14, position: 14, elementType: 3),
                makeFantasyPick(element: 15, position: 15, elementType: 4)
            ],
            entryHistory: FantasyEntryHistory(
                event: 30,
                points: 40,
                rank: nil,
                overallRank: nil,
                eventTransfersCost: nil,
                pointsOnBench: 8
            ),
            activeChipCodes: []
        )
        let liveResponse = FantasyEventLiveResponse(
            elements: [
                makeLiveElement(id: 1, points: 2),
                makeLiveElement(id: 2, points: 9),
                makeLiveElement(id: 3, points: 10),
                makeLiveElement(id: 4, points: 2),
                makeLiveElement(id: 5, points: 2),
                makeLiveElement(id: 6, points: 1),
                makeLiveElement(id: 7, points: 6),
                makeLiveElement(id: 8, points: 3),
                makeLiveElement(id: 9, points: 4),
                makeLiveElement(id: 10, points: 0),
                makeLiveElement(id: 11, points: 1),
                makeLiveElement(id: 12, points: 0),
                makeLiveElement(id: 13, points: 8),
                makeLiveElement(id: 14, points: 0),
                makeLiveElement(id: 15, points: 0)
            ]
        )
        let fixtures = [
            FantasyFixture(
                id: 101,
                event: 30,
                teamH: 1,
                teamA: 3,
                kickoffTime: "2026-03-15T14:00:00Z",
                started: true,
                finished: true,
                finishedProvisional: false
            ),
            FantasyFixture(
                id: 102,
                event: 30,
                teamH: 4,
                teamA: 5,
                kickoffTime: "2026-03-15T14:00:00Z",
                started: true,
                finished: true,
                finishedProvisional: false
            ),
            FantasyFixture(
                id: 103,
                event: 30,
                teamH: 2,
                teamA: 6,
                kickoffTime: "2026-03-15T16:30:00Z",
                started: true,
                finished: false,
                finishedProvisional: false
            )
        ]

        let squad = FantasySquadBuilder.build(
            gameweek: gameweek,
            picksResponse: picks,
            liveResponse: liveResponse,
            fixtures: fixtures,
            seasonFixtures: fixtures,
            bootstrap: bootstrap,
            now: Date(timeIntervalSince1970: 1_773_961_200)
        )

        #expect(squad.resolvedCurrentScore == 48)
        #expect(
            squad.scoreCalculationRulesApplied.contains {
                $0.contains("Bench Def") && $0.contains("Fwd A")
            }
        )
        #expect(
            squad.effectivePlayerContributions.contains {
                $0.elementID == 13 && $0.points == 8
            }
        )
        #expect(
            !squad.effectivePlayerContributions.contains {
                $0.elementID == 10
            }
        )
    }

    @Test func fantasySquadDisplayData_marksNonScoringChipsWithAsterisk() async throws {
        let squad = FantasySquadDisplayData(
            gameweekID: 30,
            gameweekTitle: "GW30",
            deadlineGameweekID: nil,
            deadlineTime: nil,
            totalPoints: 52,
            hasActiveFixtures: false,
            hasStartedFixturesInGameweek: true,
            hasFixturesPlayedToday: false,
            isEstimatedScore: false,
            estimatedCurrentScore: 52,
            scoreCalculationRulesApplied: [],
            rank: nil,
            overallRank: nil,
            transfersCost: nil,
            pointsOnBench: nil,
            activeChips: [FantasyChip(code: "freehit")],
            goalkeepers: [],
            defenders: [],
            midfielders: [],
            forwards: [],
            bench: []
        )

        #expect(squad.hasActiveChip)
        #expect(squad.resolvedCurrentScore == 52)
        #expect(squad.resolvedCurrentScoreDisplay == "52*")
        #expect(squad.activeChipSummaryText == "Active chip: Free Hit")
    }

    @Test func fantasyTeamGameweekResolver_usesNextEventForCurrentTeamBeforeSeasonStarts() async throws {
        let events = [
            FantasyGameweek(
                id: 1,
                name: "Gameweek 1",
                isCurrent: false,
                isNext: true,
                finished: false,
                deadlineTime: "2026-08-14T17:30:00Z"
            ),
            FantasyGameweek(
                id: 2,
                name: "Gameweek 2",
                isCurrent: false,
                isNext: false,
                finished: false,
                deadlineTime: "2026-08-21T17:30:00Z"
            )
        ]

        #expect(FantasyTeamGameweekResolver.currentTeamGameweek(from: events)?.id == 1)
        #expect(FantasyTeamGameweekResolver.previousTeamGameweek(from: events) == nil)
    }

    @Test func fantasyTeamGameweekResolver_usesLatestFinishedEventForPreviousTeam() async throws {
        let events = [
            FantasyGameweek(
                id: 1,
                name: "Gameweek 1",
                isCurrent: false,
                isNext: false,
                finished: true,
                deadlineTime: nil
            ),
            FantasyGameweek(
                id: 2,
                name: "Gameweek 2",
                isCurrent: true,
                isNext: false,
                finished: false,
                deadlineTime: nil
            ),
            FantasyGameweek(
                id: 3,
                name: "Gameweek 3",
                isCurrent: false,
                isNext: true,
                finished: false,
                deadlineTime: nil
            )
        ]

        #expect(FantasyTeamGameweekResolver.currentTeamGameweek(from: events)?.id == 3)
        #expect(FantasyTeamGameweekResolver.previousTeamGameweek(from: events)?.id == 1)
    }

    @Test func fantasyCurrentTeamResponse_convertsPicksWithoutInventingPoints() async throws {
        let json = """
        {
          "picks": [
            {
              "element": 42,
              "position": 1,
              "multiplier": 1,
              "is_captain": false,
              "is_vice_captain": true,
              "selling_price": 55
            }
          ],
          "chips": [],
          "transfers": { "bank": 10 }
        }
        """

        let response = try JSONDecoder().decode(
            FantasyCurrentTeamResponse.self,
            from: Data(json.utf8)
        )
        let picks = response.asPicksResponse(eventID: 1)

        #expect(picks.picks.map(\.element) == [42])
        #expect(picks.entryHistory.event == 1)
        #expect(picks.entryHistory.points == 0)
    }

    @Test func lineupPlayerInitials_handlesParticlesAndHyphenatedSurnames() async throws {
        #expect(lineupPlayerInitials("Virgil van Dijk") == "VvD")
        #expect(lineupPlayerInitials("Declan Rice") == "DR")
        #expect(lineupPlayerInitials("Micky van de Ven") == "MvdV")
        #expect(lineupPlayerInitials("Trent Alexander-Arnold") == "TAA")
    }

    @Test func lineupPlayerMarkerLabel_prefersFantasyPointsWhenAvailable() async throws {
        #expect(lineupPlayerMarkerLabel(name: "Virgil van Dijk", fantasyPoints: 12) == "12")
        #expect(lineupPlayerMarkerLabel(name: "Virgil van Dijk", fantasyPoints: nil) == "VvD")
    }

    @Test func shouldShowFantasySubstituteWarning_treatsZeroPointFantasyPlayersAsTracked() async throws {
        #expect(shouldShowFantasySubstituteWarning(fantasyPoints: nil) == false)
        #expect(shouldShowFantasySubstituteWarning(fantasyPoints: 0) == true)
        #expect(shouldShowFantasySubstituteWarning(fantasyPoints: 7) == true)
    }

    @Test func fantasyDisplayPlayerGameweekScoreState_prefersRemainingFixtureOverMinutesPlayed() async throws {
        let player = makeFantasyPlayer(
            elementID: 1,
            pickPosition: 5,
            positionType: .midfielder,
            displayName: "Mid A",
            fullName: "Midfielder A",
            teamName: "Arsenal",
            hasAnyFixtureThisGameweek: true,
            hasUpcomingFixtureThisGameweek: true,
            hasActiveFixtureThisGameweek: false,
            minutesPlayed: 90
        )

        #expect(player.gameweekScoreState == .upcoming)
        #expect(player.hasRemainingFixtureThisGameweek)
        #expect(!player.hasFinishedScoringForGameweek)
    }

    @Test func fantasyDisplayPlayerShouldAutoSub_onlyForLiveOrClosedZeroMinuteCases() async throws {
        let liveZeroMinutePlayer = makeFantasyPlayer(
            elementID: 1,
            pickPosition: 10,
            positionType: .forward,
            displayName: "Live Fwd",
            fullName: "Live Forward",
            teamName: "Liverpool",
            hasAnyFixtureThisGameweek: true,
            hasUpcomingFixtureThisGameweek: false,
            hasActiveFixtureThisGameweek: true,
            minutesPlayed: 0
        )
        let upcomingZeroMinutePlayer = makeFantasyPlayer(
            elementID: 2,
            pickPosition: 11,
            positionType: .forward,
            displayName: "Upcoming Fwd",
            fullName: "Upcoming Forward",
            teamName: "Liverpool",
            hasAnyFixtureThisGameweek: true,
            hasUpcomingFixtureThisGameweek: true,
            hasActiveFixtureThisGameweek: false,
            minutesPlayed: 0
        )

        #expect(liveZeroMinutePlayer.shouldAutoSubAsNonParticipant)
        #expect(!upcomingZeroMinutePlayer.shouldAutoSubAsNonParticipant)
    }

    @Test func fantasyDisplayPlayerGameweekScoreState_distinguishesCompletedAndBlankGameweeks() async throws {
        let completed = makeFantasyPlayer(
            elementID: 2,
            pickPosition: 6,
            positionType: .midfielder,
            displayName: "Mid B",
            fullName: "Midfielder B",
            teamName: "Chelsea",
            hasAnyFixtureThisGameweek: true,
            hasUpcomingFixtureThisGameweek: false,
            hasActiveFixtureThisGameweek: false,
            minutesPlayed: 12
        )
        let blank = makeFantasyPlayer(
            elementID: 3,
            pickPosition: 7,
            positionType: .forward,
            displayName: "Fwd A",
            fullName: "Forward A",
            teamName: "Liverpool",
            hasAnyFixtureThisGameweek: false,
            hasUpcomingFixtureThisGameweek: false,
            hasActiveFixtureThisGameweek: false,
            minutesPlayed: 0
        )

        #expect(completed.gameweekScoreState == .completed)
        #expect(blank.gameweekScoreState == .noFixture)
        #expect(completed.hasFinishedScoringForGameweek)
        #expect(blank.hasFinishedScoringForGameweek)
    }

    @Test func fantasyExpectedPointsSection_sumsFullSquadForSelectedTeamXP() async throws {
        let section = FantasyAssistantManagerResponse.ExpectedPointsSection(
            starters: [
                makeExpectedPointsPlayer(elementID: 1, pickPosition: 1, expectedPointsNextGameweek: 5.4),
                makeExpectedPointsPlayer(elementID: 2, pickPosition: 2, expectedPointsNextGameweek: 6.1)
            ],
            bench: [
                makeExpectedPointsPlayer(elementID: 12, pickPosition: 12, expectedPointsNextGameweek: 3.8)
            ]
        )

        #expect(abs(section.selectedTeamExpectedPointsNextGameweek - 15.3) < 0.001)
    }

    @Test func fantasySquadProjectedGameweekPoints_addsCurrentScoreToRemainingExpectedPoints() async throws {
        let playedStarter = makeFantasyPlayer(
            elementID: 1,
            pickPosition: 1,
            positionType: .goalkeeper,
            displayName: "Keeper",
            fullName: "Keeper",
            teamName: "Everton",
            hasAnyFixtureThisGameweek: true,
            hasUpcomingFixtureThisGameweek: false,
            hasActiveFixtureThisGameweek: false,
            minutesPlayed: 90,
            rawPoints: 6,
            appliedPoints: 6,
            displayPoints: 6
        )
        let upcomingCaptain = makeFantasyPlayer(
            elementID: 2,
            pickPosition: 2,
            positionType: .forward,
            displayName: "Captain",
            fullName: "Captain",
            teamName: "Liverpool",
            hasAnyFixtureThisGameweek: true,
            hasUpcomingFixtureThisGameweek: true,
            hasActiveFixtureThisGameweek: false,
            minutesPlayed: 0,
            multiplier: 2,
            isCaptain: true
        )
        let squad = FantasySquadDisplayData(
            gameweekID: 30,
            gameweekTitle: "GW30",
            deadlineGameweekID: nil,
            deadlineTime: nil,
            totalPoints: 26,
            hasActiveFixtures: false,
            hasStartedFixturesInGameweek: true,
            hasFixturesPlayedToday: true,
            isEstimatedScore: false,
            estimatedCurrentScore: 26,
            scoreCalculationRulesApplied: [],
            rank: nil,
            overallRank: nil,
            transfersCost: nil,
            pointsOnBench: nil,
            activeChips: [],
            goalkeepers: [playedStarter],
            defenders: [],
            midfielders: [],
            forwards: [upcomingCaptain],
            bench: []
        )
        let section = FantasyAssistantManagerResponse.ExpectedPointsSection(
            starters: [
                makeExpectedPointsPlayer(elementID: 1, pickPosition: 1, expectedPointsNextGameweek: 2.5),
                makeExpectedPointsPlayer(elementID: 2, pickPosition: 2, expectedPointsNextGameweek: 5.0)
            ],
            bench: []
        )

        #expect(abs(squad.remainingExpectedPoints(using: section) - 10.0) < 0.001)
        #expect(abs(squad.projectedGameweekPoints(using: section) - 36.0) < 0.001)
    }

    @Test func fantasySquadMatchesExpectedPointsSection_requiresMatchingPlayersAndGameweek() async throws {
        let squad = FantasySquadDisplayData(
            gameweekID: 31,
            gameweekTitle: "GW31",
            deadlineGameweekID: nil,
            deadlineTime: nil,
            totalPoints: 0,
            hasActiveFixtures: false,
            hasStartedFixturesInGameweek: false,
            hasFixturesPlayedToday: false,
            isEstimatedScore: false,
            estimatedCurrentScore: 0,
            scoreCalculationRulesApplied: [],
            rank: nil,
            overallRank: nil,
            transfersCost: nil,
            pointsOnBench: nil,
            activeChips: [],
            goalkeepers: [
                makeFantasyPlayer(
                    elementID: 1,
                    pickPosition: 1,
                    positionType: .goalkeeper,
                    displayName: "Keeper",
                    fullName: "Keeper",
                    teamName: "Everton"
                )
            ],
            defenders: [
                makeFantasyPlayer(
                    elementID: 2,
                    pickPosition: 2,
                    positionType: .defender,
                    displayName: "Defender",
                    fullName: "Defender",
                    teamName: "Liverpool"
                )
            ],
            midfielders: [],
            forwards: [],
            bench: [
                makeFantasyPlayer(
                    elementID: 12,
                    pickPosition: 12,
                    positionType: .goalkeeper,
                    displayName: "Bench",
                    fullName: "Bench Keeper",
                    teamName: "Chelsea"
                )
            ]
        )

        let matchingSection = FantasyAssistantManagerResponse.ExpectedPointsSection(
            starters: [
                makeExpectedPointsPlayer(elementID: 1, pickPosition: 1, expectedPointsNextGameweek: 4.0),
                makeExpectedPointsPlayer(elementID: 2, pickPosition: 2, expectedPointsNextGameweek: 5.0)
            ],
            bench: [
                makeExpectedPointsPlayer(elementID: 12, pickPosition: 12, expectedPointsNextGameweek: 3.0)
            ]
        )
        let mismatchedSection = FantasyAssistantManagerResponse.ExpectedPointsSection(
            starters: [
                makeExpectedPointsPlayer(elementID: 1, pickPosition: 1, expectedPointsNextGameweek: 4.0),
                makeExpectedPointsPlayer(elementID: 99, pickPosition: 2, expectedPointsNextGameweek: 5.0)
            ],
            bench: [
                makeExpectedPointsPlayer(elementID: 12, pickPosition: 12, expectedPointsNextGameweek: 3.0)
            ]
        )

        #expect(squad.matchesAssistantExpectedPointsSection(matchingSection, eventID: 31))
        #expect(!squad.matchesAssistantExpectedPointsSection(matchingSection, eventID: 32))
        #expect(!squad.matchesAssistantExpectedPointsSection(mismatchedSection, eventID: 31))
    }

    @Test func fantasyTeamLookupKeys_handleClubPrefixesAndSuffixes() async throws {
        seedTeamIdentityStore()
        #expect(fantasyTeamLookupKeys("AFC Bournemouth").contains("bournemouth"))
        #expect(fantasyTeamLookupKeys("Bournemouth FC").contains("bournemouth"))
        #expect(fantasyTeamLookupKeys("Valencia CF").contains("valencia"))
    }

    @Test func fantasyTeamLookupKeys_handleFantasyShortTeamAliases() async throws {
        seedTeamIdentityStore()
        #expect(fantasyTeamLookupKeys("Man City").contains("manchester city"))
        #expect(fantasyTeamLookupKeys("Manchester City").contains("man city"))
    }

    @Test func fantasySquadMembershipLookup_marksRealMatchSubstitutesInContributionStrip() async throws {
        let squad = FantasySquadDisplayData(
            gameweekID: 30,
            gameweekTitle: "GW30",
            deadlineGameweekID: nil,
            deadlineTime: nil,
            totalPoints: 0,
            hasActiveFixtures: true,
            hasStartedFixturesInGameweek: true,
            hasFixturesPlayedToday: true,
            isEstimatedScore: true,
            estimatedCurrentScore: 0,
            scoreCalculationRulesApplied: [],
            rank: nil,
            overallRank: nil,
            transfersCost: nil,
            pointsOnBench: nil,
            activeChips: [],
            goalkeepers: [],
            defenders: [],
            midfielders: [
                makeFantasyPlayer(
                    elementID: 9,
                    pickPosition: 5,
                    positionType: .midfielder,
                    displayName: "Ekitike",
                    fullName: "Hugo Ekitike",
                    teamName: "Liverpool"
                )
            ],
            forwards: [],
            bench: []
        )
        let lookup = try #require(FantasySquadMembershipLookup(squad: squad))
        let substitute = MatchLineupPlayer(
            number: 22,
            name: "Hugo Ekitike",
            positionCategory: "attacker",
            formationRowIndex: nil,
            formationSlotIndex: nil,
            formationRowSize: nil
        )
        let match = Match(
            date: "2026-03-15",
            time: "16:30",
            homeTeam: "Liverpool",
            awayTeam: "Tottenham Hotspur",
            league: "Premier League",
            tvChannels: [],
            teamLineups: MatchTeamLineups(
                home: MatchTeamLineup(
                    team: "Liverpool",
                    manager: nil,
                    formation: "4-3-3",
                    startingLineup: [],
                    substitutes: [substitute],
                    substitutions: []
                ),
                away: MatchTeamLineup(
                    team: "Tottenham Hotspur",
                    manager: nil,
                    formation: "4-3-3",
                    startingLineup: [],
                    substitutes: [],
                    substitutions: []
                )
            )
        )

        let contribution = try #require(lookup.involvedPlayers(in: match).first)

        #expect(contribution.displayName == "Ekitike")
        #expect(contribution.isRealMatchSubstitute)
    }

    @Test func fantasySquadMembershipLookup_usesRawFixturePointsForMatchBadgesAndPlayers() async throws {
        let squad = FantasySquadDisplayData(
            gameweekID: 30,
            gameweekTitle: "GW30",
            deadlineGameweekID: nil,
            deadlineTime: nil,
            totalPoints: 0,
            hasActiveFixtures: true,
            hasStartedFixturesInGameweek: true,
            hasFixturesPlayedToday: true,
            isEstimatedScore: true,
            estimatedCurrentScore: 0,
            scoreCalculationRulesApplied: [],
            rank: nil,
            overallRank: nil,
            transfersCost: nil,
            pointsOnBench: nil,
            activeChips: [],
            goalkeepers: [],
            defenders: [],
            midfielders: [
                makeFantasyPlayer(
                    elementID: 1,
                    pickPosition: 5,
                    positionType: .midfielder,
                    displayName: "Salah",
                    fullName: "Mohamed Salah",
                    teamName: "Liverpool",
                    hasUpcomingFixtureThisGameweek: false,
                    minutesPlayed: 90,
                    rawPoints: 4,
                    appliedPoints: 8,
                    displayPoints: 8,
                    multiplier: 2,
                    isCaptain: true
                )
            ],
            forwards: [],
            bench: [
                makeFantasyPlayer(
                    elementID: 2,
                    pickPosition: 13,
                    positionType: .defender,
                    displayName: "Rodon",
                    fullName: "Joe Rodon",
                    teamName: "Leeds United",
                    hasUpcomingFixtureThisGameweek: false,
                    minutesPlayed: 90,
                    rawPoints: 8,
                    appliedPoints: 8,
                    displayPoints: 8
                )
            ]
        )

        let lookup = try #require(FantasySquadMembershipLookup(squad: squad))
        let match = Match(
            date: "2026-03-15",
            time: "14:00",
            homeTeam: "Leeds United",
            awayTeam: "Liverpool",
            league: "Premier League",
            tvChannels: []
        )

        #expect(lookup.effectiveScore(in: match) == 12)
        #expect(
            lookup.points(
                for: MatchLineupPlayer(
                    number: 6,
                    name: "Joe Rodon",
                    positionCategory: "defender",
                    formationRowIndex: nil,
                    formationSlotIndex: nil,
                    formationRowSize: nil
                ),
                teamName: "Leeds United"
            ) == 8
        )
        #expect(
            lookup.points(
                for: MatchLineupPlayer(
                    number: 11,
                    name: "Mohamed Salah",
                    positionCategory: "attacker",
                    formationRowIndex: nil,
                    formationSlotIndex: nil,
                    formationRowSize: nil
                ),
                teamName: "Liverpool"
            ) == 4
        )

        let involvedPlayers = lookup.involvedPlayers(in: match)
        #expect(involvedPlayers.count == 2)
        #expect(involvedPlayers.first(where: { $0.displayName == "Rodon" })?.pointsDisplay == .actual(8))
        #expect(involvedPlayers.first(where: { $0.displayName == "Salah" })?.pointsDisplay == .actual(4))
    }

    private func makeMatch(
        date: String = "2026-02-24",
        time: String = "17:45",
        homeScore: Int?,
        awayScore: Int?,
        aggregateHomeScore: Int?,
        aggregateAwayScore: Int?,
        scoreStatus: String? = "30",
        detailsURL: String? = nil,
        matchDetailsID: String? = "c8r1zve354lt",
        hasBbcSource: Bool? = nil
    ) -> Match {
        Match(
            date: date,
            time: time,
            homeTeam: "Atletico Madrid",
            awayTeam: "Club Brugge",
            league: "UEFA Champions League",
            detailsURL: detailsURL,
            matchDetailsID: matchDetailsID,
            hasBbcSource: hasBbcSource,
            tvChannels: [TvChannel(name: "TNT Sports 3")],
            homeScore: homeScore,
            awayScore: awayScore,
            aggregateHomeScore: aggregateHomeScore,
            aggregateAwayScore: aggregateAwayScore,
            scoreStatus: scoreStatus
        )
    }

    @Test func fantasyFixture_decodesTeamSpecificDifficulty() throws {
        let payload = """
        {
          "id": 101,
          "event": 1,
          "team_h": 1,
          "team_a": 2,
          "team_h_difficulty": 2,
          "team_a_difficulty": 4,
          "kickoff_time": "2026-08-21T18:30:00Z",
          "started": false,
          "finished": false,
          "finished_provisional": false
        }
        """

        let fixture = try JSONDecoder().decode(FantasyFixture.self, from: Data(payload.utf8))

        #expect(fixture.difficulty(forTeamID: 1) == 2)
        #expect(fixture.difficulty(forTeamID: 2) == 4)
        #expect(fixture.difficulty(forTeamID: 999) == nil)
    }

    private func formattedDate(offsetDays: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let date = Calendar.current.date(byAdding: .day, value: offsetDays, to: Date())!
        return formatter.string(from: date)
    }

    private func makeDetailsPayload(scoreStatus: String) -> MatchDetailsPayload {
        let payload: [String: Any?] = [
            "id": "abc123",
            "details_url": nil,
            "date": "2026-02-24",
            "time": "17:45",
            "league": "UEFA Champions League",
            "home_team": "Atletico Madrid",
            "away_team": "Club Brugge",
            "home_score": 2,
            "away_score": 1,
            "aggregate_home_score": nil,
            "aggregate_away_score": nil,
            "score_status": scoreStatus,
            "home_goal_scorers": [],
            "away_goal_scorers": [],
            "home_assists": [],
            "away_assists": [],
            "home_red_cards": [],
            "away_red_cards": [],
            "penalty_result": nil,
            "in_progress": true,
            "updated_at": "2026-02-24T20:10:00Z",
        ]

        let data = try! JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
        return try! JSONDecoder().decode(MatchDetailsPayload.self, from: data)
    }

    private func makeBbcMatch(
        homeTeam: String,
        awayTeam: String,
        homeScore: Int,
        awayScore: Int,
        matchTime: String
    ) -> BbcMatch {
        let payload: [String: Any?] = [
            "home_team": homeTeam,
            "away_team": awayTeam,
            "home_score": homeScore,
            "away_score": awayScore,
            "aggregate_home_score": nil,
            "aggregate_away_score": nil,
            "match_time": matchTime,
            "details_url": nil,
            "home_goal_scorers": [],
            "away_goal_scorers": [],
            "home_assists": [],
            "away_assists": [],
            "home_red_cards": [],
            "away_red_cards": [],
        ]

        let data = try! JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
        return try! JSONDecoder().decode(BbcMatch.self, from: data)
    }

    private func makeFantasyPlayer(
        elementID: Int,
        pickPosition: Int,
        positionType: FantasyPositionType,
        displayName: String,
        fullName: String,
        teamName: String,
        hasAnyFixtureThisGameweek: Bool = true,
        hasUpcomingFixtureThisGameweek: Bool = true,
        hasActiveFixtureThisGameweek: Bool = false,
        minutesPlayed: Int = 0,
        rawPoints: Int = 0,
        appliedPoints: Int = 0,
        displayPoints: Int = 0,
        multiplier: Int = 1,
        isCaptain: Bool = false,
        officialExpectedPointsNextGameweek: Double? = nil
    ) -> FantasyDisplayPlayer {
        FantasyDisplayPlayer(
            elementID: elementID,
            pickPosition: pickPosition,
            positionType: positionType,
            displayName: displayName,
            fullName: fullName,
            teamName: teamName,
            profileImageURL: nil,
            nowCostMillions: 5.0,
            hasStartedCurrentSeason: true,
            ownershipPercent: nil,
            ownershipCount: nil,
            form: nil,
            pointsPerMatch: nil,
            totalPoints: nil,
            averageMinutes: nil,
            rawPoints: rawPoints,
            appliedPoints: appliedPoints,
            displayPoints: displayPoints,
            multiplier: multiplier,
            isCaptain: isCaptain,
            isViceCaptain: false,
            isPlayingNow: false,
            isUnavailable: false,
            isDefinitelyUnavailable: false,
            hasAnyFixtureThisGameweek: hasAnyFixtureThisGameweek,
            hasUpcomingFixtureThisGameweek: hasUpcomingFixtureThisGameweek,
            hasActiveFixtureThisGameweek: hasActiveFixtureThisGameweek,
            hasFutureAvailabilityIssue: false,
            futureAvailabilityIssueGameweek: nil,
            minutesPlayed: minutesPlayed,
            upcomingOpponentDisplay: nil,
            fixtureDifficulty: nil,
            nextFiveFixtureDifficulties: [],
            expectedPointsThisGameweek: nil,
            officialExpectedPointsNextGameweek: officialExpectedPointsNextGameweek,
            goalsScored: 0,
            assists: 0,
            yellowCards: 0,
            redCards: 0
        )
    }

    private func makeUpcomingFixture(
        gameweek: Int,
        difficulty: Int
    ) -> FantasyPlayerDetailsData.UpcomingFixture {
        FantasyPlayerDetailsData.UpcomingFixture(
            gameweek: gameweek,
            opponentTeamID: 2,
            opponentTeamName: "Opponent",
            isHome: true,
            difficulty: difficulty,
            isBlank: false,
            teamAttackingStrengthMultiplier: 1.0,
            opponentDefensiveWeaknessMultiplier: 1.0
        )
    }

    private func makeFantasyPlayerDetails(
        fplCurrentGameweekID: Int? = nil,
        fplNextGameweekID: Int? = nil,
        fplExpectedPointsThisGameweek: Double? = nil,
        fplExpectedPointsNextGameweek: Double? = nil,
        upcomingFixtures: [FantasyPlayerDetailsData.UpcomingFixture]
    ) -> FantasyPlayerDetailsData {
        FantasyPlayerDetailsData(
            elementID: 1,
            playerName: "Test Defender",
            teamName: "Arsenal",
            profileImageURL: nil,
            teamID: 1,
            position: "Defender",
            positionType: .defender,
            fplCurrentGameweekID: fplCurrentGameweekID,
            fplNextGameweekID: fplNextGameweekID,
            fplExpectedPointsThisGameweek: fplExpectedPointsThisGameweek,
            fplExpectedPointsNextGameweek: fplExpectedPointsNextGameweek,
            chanceOfPlayingThisRound: 100,
            chanceOfPlayingNextRound: 100,
            ownershipPercent: 0,
            totalManagers: nil,
            seasonTotals: .init(
                minutes: 0,
                goals: 0,
                assists: 0,
                cleanSheets: 0,
                goalsConceded: 0,
                saves: 0,
                bonus: 0,
                penaltiesSaved: 0,
                yellowCards: 0,
                redCards: 0
            ),
            statusUpdates: [],
            metrics: [
                .init(title: "Form", value: "0.0"),
                .init(title: "Pts / Match", value: "0.0")
            ],
            latestPointsBreakdown: [],
            formItems: [],
            upcomingFixtures: upcomingFixtures,
            historyRows: []
        )
    }

    private func makeExpectedPointsPlayer(
        elementID: Int,
        pickPosition: Int,
        expectedPointsNextGameweek: Double
    ) -> FantasyAssistantManagerResponse.ExpectedPointsPlayer {
        FantasyAssistantManagerResponse.ExpectedPointsPlayer(
            elementID: elementID,
            pickPosition: pickPosition,
            isStarter: pickPosition <= 11,
            playerName: "Player \(elementID)",
            teamName: "Arsenal",
            teamShortName: "ARS",
            opponentTeamName: "Chelsea",
            opponentLabel: "CHE (H)",
            difficulty: 3,
            expectedPointsNextGameweek: expectedPointsNextGameweek,
            isBlank: false
        )
    }

    private func makeFantasyBootstrapElement(
        id: Int,
        team: Int,
        elementType: Int,
        webName: String,
        photo: String? = nil,
        expectedPointsNextGameweek: String? = nil
    ) -> FantasyBootstrapElement {
        FantasyBootstrapElement(
            id: id,
            code: nil,
            webName: webName,
            firstName: webName,
            secondName: "Test",
            team: team,
            elementType: elementType,
            photo: photo,
            status: "a",
            news: nil,
            nowCost: 50,
            form: "0.0",
            expectedPointsThisGameweek: nil,
            expectedPointsNextGameweek: expectedPointsNextGameweek,
            pointsPerGame: "0.0",
            eventPoints: 0,
            totalPoints: 0,
            minutes: 0,
            starts: 0,
            bonus: 0,
            ictIndex: "0.0",
            selectedByPercent: "0.0",
            chanceOfPlayingThisRound: 100,
            chanceOfPlayingNextRound: 100
        )
    }

    private func makeFantasyPick(element: Int, position: Int, elementType: Int) -> FantasyPick {
        FantasyPick(
            element: element,
            position: position,
            multiplier: 1,
            isCaptain: false,
            isViceCaptain: false,
            elementType: elementType
        )
    }

    private func makeLiveElement(id: Int, points: Int) -> FantasyLiveElement {
        FantasyLiveElement(
            id: id,
            stats: FantasyLiveStats(
                totalPoints: points,
                minutes: points > 0 ? 90 : 0,
                goalsScored: 0,
                assists: 0,
                yellowCards: 0,
                redCards: 0
            )
        )
    }

    private func seedTeamIdentityStore() {
        TeamIdentityStore.shared.update(
            from: TeamColorsCatalogResponse(
                updatedAt: "2026-03-14T00:00:00Z",
                defaultStyle: TeamColorStyleResponse(
                    primary: "#111111",
                    secondary: "#FFFFFF",
                    scheme: "default-dark"
                ),
                teams: [
                    TeamColorRecordResponse(
                        name: "Bournemouth",
                        aliases: ["AFC Bournemouth", "BOU"],
                        primary: "#DA291C",
                        secondary: "#000000",
                        scheme: "red-black"
                    ),
                    TeamColorRecordResponse(
                        name: "Manchester City",
                        aliases: ["Man City", "MCI"],
                        primary: "#6CABDD",
                        secondary: "#FFFFFF",
                        scheme: "sky-white"
                    )
                ],
                identityGroups: [
                    TeamIdentityGroupResponse(name: "Bournemouth", aliases: ["AFC Bournemouth", "BOU"]),
                    TeamIdentityGroupResponse(name: "Manchester City", aliases: ["Man City", "MCI"])
                ]
            )
        )
    }

}

private final class PlayerDetailsRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts: [TimeInterval] = []

    var recordedTimeouts: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return timeouts
    }

    @discardableResult
    func record(timeout: TimeInterval) -> Int {
        lock.lock()
        defer { lock.unlock() }
        timeouts.append(timeout)
        return timeouts.count
    }
}

private final class PlayerDetailsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
