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
}
