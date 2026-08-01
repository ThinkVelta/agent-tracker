import Foundation
import Testing

@testable import AgentTracker

final class UpdateCheckTests {
    @Test func dottedVersionsCompareNumerically() {
        #expect(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
        #expect(UpdateCheck.isNewer("0.1.1", than: "0.1.0"))
        #expect(UpdateCheck.isNewer("1.0", than: "0.9.9"))
        // Numeric, not lexicographic: 0.10 > 0.9.
        #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("0.0.9", than: "0.1.0"))
        // Trailing zeros are cosmetic.
        #expect(!UpdateCheck.isNewer("1.0.0", than: "1.0"))
    }

    @Test func tagPrefixesAreCosmetic() {
        #expect(UpdateCheck.isNewer("v0.2.0", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("v0.1.0", than: "v0.1.0"))
    }

    /// A malformed tag must never claim to be newer than a real version, and
    /// a dev build (non-numeric "current") must always be offered releases.
    @Test func malformedInputStaysConservative() {
        #expect(!UpdateCheck.isNewer("banana", than: "0.1.0"))
        #expect(UpdateCheck.isNewer("0.0.1", than: "dev"))
    }

    @Test func releasePayloadParses() {
        let payload =
            #"{"tag_name":"v0.2.0","html_url":"https://github.com/x/y/releases/tag/v0.2.0","name":"0.2.0"}"#
        let release = UpdateCheck.parseRelease(Data(payload.utf8))
        #expect(release?.tag == "v0.2.0")
        #expect(release?.url.absoluteString == "https://github.com/x/y/releases/tag/v0.2.0")
    }

    @Test func unusablePayloadsAreRejected() {
        #expect(UpdateCheck.parseRelease(Data()) == nil)
        #expect(UpdateCheck.parseRelease(Data("not json".utf8)) == nil)
        #expect(UpdateCheck.parseRelease(Data(#"{"tag_name":""}"#.utf8)) == nil)
        // Missing html_url still resolves to the releases page.
        let bare = UpdateCheck.parseRelease(Data(#"{"tag_name":"v1.0"}"#.utf8))
        #expect(bare?.url == UpdateCheck.releasesPage)
    }
}
