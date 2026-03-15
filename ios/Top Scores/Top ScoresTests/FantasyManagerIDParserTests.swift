import Foundation
import Testing
@testable import Top_Scores

struct FantasyManagerIDParserTests {

    @Test func parse_extractsEntryIDFromPointsURL() async throws {
        let url = "https://fantasy.premierleague.com/entry/6653695/event/28"

        let parsed = FantasyManagerIDParser.parse(from: url)

        #expect(parsed == "6653695")
    }

    @Test func parse_extractsEntryIDFromURLWithoutScheme() async throws {
        let url = "fantasy.premierleague.com/entry/123456/event/1"

        let parsed = FantasyManagerIDParser.parse(from: url)

        #expect(parsed == "123456")
    }

    @Test func parse_acceptsDigitsOnlyInput() async throws {
        let parsed = FantasyManagerIDParser.parse(from: "9876543")

        #expect(parsed == "9876543")
    }

    @Test func parse_returnsNilForInvalidClipboardText() async throws {
        let parsed = FantasyManagerIDParser.parse(from: "https://fantasy.premierleague.com/leagues")

        #expect(parsed == nil)
    }

    @Test func sharedParser_detectsManagerURL() async throws {
        let url = "https://fantasy.premierleague.com/entry/8984737/event/29"

        let parsed = FantasySharedURLParser.parse(from: url)

        #expect(parsed == .manager("8984737"))
    }

    @Test func sharedParser_detectsLeagueURL() async throws {
        let url = "https://fantasy.premierleague.com/leagues/844129/standings/c"

        let parsed = FantasySharedURLParser.parse(from: url)

        #expect(parsed == .league("844129"))
    }

    @Test func sharedImportStore_roundTripsQueueAndMirrorsLatestLegacyPayload() async throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let queuedPayloads = [
            FantasySharedImportPayload(
                rawURL: "https://fantasy.premierleague.com/entry/111111/event/29",
                updatedAt: 101
            ),
            FantasySharedImportPayload(
                rawURL: "https://fantasy.premierleague.com/entry/222222/event/29",
                updatedAt: 202
            )
        ]

        FantasySharedImportStore.saveQueue(queuedPayloads, to: defaults)

        #expect(FantasySharedImportStore.loadQueue(from: defaults) == queuedPayloads)
        #expect(FantasySharedImportStore.loadLegacyPayload(from: defaults) == queuedPayloads.last)
    }

    @Test func sharedImportStore_roundTripsMultipleLeagueShares() async throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let queuedPayloads = [
            FantasySharedImportPayload(
                rawURL: "https://fantasy.premierleague.com/leagues/111111/standings/c",
                updatedAt: 101
            ),
            FantasySharedImportPayload(
                rawURL: "https://fantasy.premierleague.com/leagues/classic/222222/standings/c",
                updatedAt: 202
            )
        ]

        FantasySharedImportStore.saveQueue(queuedPayloads, to: defaults)

        #expect(FantasySharedImportStore.loadQueue(from: defaults) == queuedPayloads)
        #expect(FantasySharedImportStore.loadLegacyPayload(from: defaults) == queuedPayloads.last)
    }

    @Test func sharedImportStore_clearsLegacyMirrorWhenQueueIsEmpty() async throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let payload = FantasySharedImportPayload(
            rawURL: "https://fantasy.premierleague.com/leagues/844129/standings/c",
            updatedAt: 303
        )
        FantasySharedImportStore.saveLegacyPayload(payload, to: defaults)
        #expect(FantasySharedImportStore.loadLegacyPayload(from: defaults) == payload)

        FantasySharedImportStore.saveQueue([], to: defaults)

        #expect(FantasySharedImportStore.loadQueue(from: defaults).isEmpty)
        #expect(FantasySharedImportStore.loadLegacyPayload(from: defaults) == nil)
    }

    @Test func entryProfile_decodesClassicLeagueMetadataForSetup() async throws {
        let json = #"""
        {
          "id": 6653695,
          "name": "Hornets FC",
          "player_first_name": "Mike",
          "player_last_name": "Wagstaff",
          "summary_overall_points": 1649,
          "summary_event_points": 44,
          "current_event": 30,
          "club_badge_src": "https://example.com/badge.png",
          "leagues": {
            "classic": [
              {
                "id": 247,
                "name": "United Kingdom",
                "short_name": "region-227",
                "league_type": "s",
                "rank_count": 7396,
                "entry_rank": 1653,
                "entry_last_rank": 1715,
                "active_phases": [
                  {
                    "phase": 1,
                    "rank": 1653,
                    "last_rank": 1715,
                    "total": 1634,
                    "rank_count": 7396
                  },
                  {
                    "phase": 9,
                    "rank": 2790,
                    "last_rank": 3428,
                    "total": 87,
                    "rank_count": 7396
                  }
                ]
              },
              {
                "id": 844129,
                "name": "Primark FPL 3.0",
                "short_name": null,
                "league_type": "x",
                "rank_count": 29,
                "entry_rank": 13,
                "entry_last_rank": 16,
                "active_phases": [
                  {
                    "phase": 1,
                    "rank": 13,
                    "last_rank": 16,
                    "total": 1634,
                    "rank_count": 29
                  }
                ]
              }
            ]
          }
        }
        """#

        let profile = try JSONDecoder().decode(FantasyEntryProfile.self, from: Data(json.utf8))

        #expect(profile.currentEvent == 30)
        #expect(profile.summaryEventPoints == 44)
        #expect(profile.leagues?.classic.count == 2)
        #expect(profile.leagues?.classic[0].resolvedEntryRank == 1653)
        #expect(profile.leagues?.classic[0].resolvedEntryLastRank == 1715)
        #expect(profile.leagues?.classic[0].resolvedTotalPoints == 1634)
        #expect(profile.leagues?.classic[1].leagueType == "x")
    }

    @Test func entryLeague_usesFirstPhaseWhenOverallPhaseIsMissing() async throws {
        let json = #"""
        {
          "id": 1,
          "name": "Test League",
          "short_name": null,
          "league_type": "x",
          "rank_count": 12,
          "entry_rank": null,
          "entry_last_rank": null,
          "active_phases": [
            {
              "phase": 9,
              "rank": 4,
              "last_rank": 6,
              "total": 88,
              "rank_count": 12
            }
          ]
        }
        """#

        let league = try JSONDecoder().decode(FantasyEntryClassicLeague.self, from: Data(json.utf8))

        #expect(league.resolvedEntryRank == 4)
        #expect(league.resolvedEntryLastRank == 6)
        #expect(league.resolvedTotalPoints == 88)
    }
}
