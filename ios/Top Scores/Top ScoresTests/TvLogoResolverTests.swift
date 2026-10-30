import Testing
import UIKit
@testable import Top_Scores

struct TvLogoResolverTests {
    @Test func additionalBroadcastersHaveBundledArtwork() throws {
        let groups = [
            ["Ligue1+", "Ligue 1+ (UK IR)", "Ligue 1 Plus"],
            ["S4C", "S4C Online"],
            ["STV", "STV Player", "STV Scotland"],
            ["DeeTV"]
        ]
        for names in groups {
            let canonical = try #require(TvLogoResolver.shared.expandedImage(for: names[0]))
            for name in names {
                for dark in [false, true] {
                    let image = try #require(TvLogoResolver.shared.expandedImage(
                        for: name, isDarkAppearance: dark
                    ))
                    #expect(image.pngData() == canonical.pngData())
                }
                #expect(TvLogoResolver.shared.image(for: name)?.pngData() == canonical.pngData())
            }
        }
        #expect(TvLogoResolver.shared.expandedImage(for: "TBC") == nil)
    }
}
