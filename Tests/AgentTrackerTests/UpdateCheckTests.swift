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

    /// A malformed tag must never claim to be newer than a real version —
    /// including a *partially* numeric one, whose bad segment must not coerce
    /// to 0 and sneak past. A dev build (non-numeric "current") must always
    /// be offered releases.
    @Test func malformedInputStaysConservative() {
        #expect(!UpdateCheck.isNewer("banana", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("0.1.alpha.1", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("0.2-rc1", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("", than: "0.1.0"))
        #expect(UpdateCheck.isNewer("0.0.1", than: "dev"))
        #expect(UpdateCheck.numericVersion("0.1.alpha.1") == nil)
        #expect(UpdateCheck.numericVersion("v1.2.3") == [1, 2, 3])
        // Only a single LEADING v is cosmetic — a suffix or doubled prefix is
        // a malformed tag, not a version.
        #expect(UpdateCheck.numericVersion("1.2.3v") == nil)
        #expect(UpdateCheck.numericVersion("vv1.2.3") == nil)
        #expect(!UpdateCheck.isNewer("1.2.3v", than: "1.2.2"))
    }

    @Test func releasePayloadParses() {
        let payload =
            #"{"tag_name":"v0.2.0","html_url":"https://github.com/x/y/releases/tag/v0.2.0","name":"0.2.0"}"#
        let release = UpdateCheck.parseRelease(Data(payload.utf8))
        #expect(release?.tag == "v0.2.0")
        #expect(release?.page.absoluteString == "https://github.com/x/y/releases/tag/v0.2.0")
        // A payload with no assets still reports the version; installing is
        // simply not offered.
        #expect(release?.zip == nil)
        #expect(release?.digest == nil)
    }

    @Test func unusablePayloadsAreRejected() {
        #expect(UpdateCheck.parseRelease(Data()) == nil)
        #expect(UpdateCheck.parseRelease(Data("not json".utf8)) == nil)
        #expect(UpdateCheck.parseRelease(Data(#"{"tag_name":""}"#.utf8)) == nil)
        // Missing html_url still resolves to the releases page.
        let bare = UpdateCheck.parseRelease(Data(#"{"tag_name":"v1.0"}"#.utf8))
        #expect(bare?.page == UpdateCheck.releasesPage)
    }

    // MARK: - Asset selection, which installing hangs on

    private func payload(assets: [(String, String)]) -> Data {
        let list = assets.map {
            #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)"}"#
        }.joined(separator: ",")
        return Data(
            #"{"tag_name":"v9.9.9","html_url":"https://github.com/ThinkVelta/agent-tracker/releases/tag/v9.9.9","assets":[\#(list)]}"#
                .utf8)
    }

    private let pinnedBase =
        "https://github.com/ThinkVelta/agent-tracker/releases/download/v9.9.9"

    @Test func versionedZipAndItsDigestAreChosen() {
        let release = UpdateCheck.parseRelease(
            payload(assets: [
                ("AgentTracker.zip", "\(pinnedBase)/AgentTracker.zip"),
                ("AgentTracker-9.9.9.zip", "\(pinnedBase)/AgentTracker-9.9.9.zip"),
                (
                    "AgentTracker-9.9.9.zip.sha256",
                    "\(pinnedBase)/AgentTracker-9.9.9.zip.sha256"
                ),
            ]))
        // The versioned name, not the stable one: the digest file is published
        // under the versioned name, and a digest for a different filename
        // verifies nothing.
        #expect(release?.zip?.lastPathComponent == "AgentTracker-9.9.9.zip")
        #expect(release?.digest?.lastPathComponent == "AgentTracker-9.9.9.zip.sha256")
    }

    @Test func assetsOutsideTheRepoDownloadPathAreDropped() {
        let hostile = [
            "https://github.com/Attacker/agent-tracker/releases/download/v9.9.9/AgentTracker-9.9.9.zip",
            "https://example.com/ThinkVelta/agent-tracker/releases/download/v9.9.9/AgentTracker-9.9.9.zip",
            "http://github.com/ThinkVelta/agent-tracker/releases/download/v9.9.9/AgentTracker-9.9.9.zip",
        ]
        for url in hostile {
            let release = UpdateCheck.parseRelease(
                payload(assets: [("AgentTracker-9.9.9.zip", url)]))
            #expect(release?.zip == nil, "\(url)")
            // The check itself survives: the tag needs no assets.
            #expect(release?.tag == "v9.9.9")
        }
    }

    @Test func aDigestForADifferentArchiveIsNotAdopted() {
        let release = UpdateCheck.parseRelease(
            payload(assets: [
                ("AgentTracker-9.9.9.zip", "\(pinnedBase)/AgentTracker-9.9.9.zip"),
                (
                    "AgentTracker-9.9.8.zip.sha256",
                    "\(pinnedBase)/AgentTracker-9.9.8.zip.sha256"
                ),
            ]))
        #expect(release?.zip != nil)
        #expect(release?.digest == nil)
    }
}
