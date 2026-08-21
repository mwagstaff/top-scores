import Foundation
import Testing
@testable import Top_Scores

struct LeagueTableZoneTests {
    @Test func tableDecodesBSDZones() throws {
        let payload = """
        {
          "league_id": "12",
          "league_name": "Championship",
          "realtime": false,
          "zones": [
            { "key": "promo", "label": "Promotion", "type": "promotion", "from": 1, "to": 2 },
            { "key": "playoff", "label": "Promotion Playoffs", "type": "promotion", "from": 3, "to": 8 },
            { "key": "rel", "label": "Relegation", "type": "relegation", "from": 22, "to": 24 }
          ],
          "groups": [],
          "rows": []
        }
        """

        let table = try JSONDecoder().decode(LeagueTable.self, from: Data(payload.utf8))

        #expect(table.zones.count == 3)
        #expect(table.zones[1].label == "Promotion Playoffs")
        #expect(table.zones[1].contains(position: 3))
        #expect(table.zones[1].contains(position: 8))
        #expect(!table.zones[1].contains(position: 9))
        #expect(!table.zones[0].usesLookDownBoundary)
        #expect(table.zones[2].usesLookDownBoundary)
    }

    @Test func scottishSplitUsesAdjacentOpposingBoundaries() throws {
        let payload = """
        {
          "league_id": "13",
          "league_name": "Scottish Premiership",
          "zones": [
            { "key": "promo", "label": "Championship round", "type": "promotion", "from": 1, "to": 6 },
            { "key": "rel", "label": "Relegation Round", "type": "relegation", "from": 7, "to": 12 }
          ],
          "groups": [],
          "rows": []
        }
        """

        let table = try JSONDecoder().decode(LeagueTable.self, from: Data(payload.utf8))

        #expect(table.zones[0].to + 1 == table.zones[1].from)
        #expect(!table.zones[0].usesLookDownBoundary)
        #expect(table.zones[1].usesLookDownBoundary)
    }

    @Test func tableDefaultsMissingZonesForSavedCacheCompatibility() throws {
        let payload = """
        {
          "league_id": "1",
          "league_name": "Premier League",
          "groups": [],
          "rows": []
        }
        """

        let table = try JSONDecoder().decode(LeagueTable.self, from: Data(payload.utf8))

        #expect(table.zones.isEmpty)
    }
}
