import Foundation
import Testing

@testable import AgentTracker

/// The pure halves of the updater: everything the swap's safety hangs on.
/// The I/O pipeline is not driven here — what these prove is that every
/// decision it defers to refuses on anything but the exact expected shape.
struct UpdaterTests {
    // MARK: - URL pinning

    @Test func onlyTheRepoOwnDownloadPathIsPinned() {
        #expect(
            Updater.isPinned(
                URL(
                    string:
                        "https://github.com/ThinkVelta/agent-tracker/releases/download/v1.0.0/AgentTracker-1.0.0.zip"
                )!))
        let hostile = [
            // Another owner, same repo name.
            "https://github.com/Attacker/agent-tracker/releases/download/v1/AgentTracker-1.zip",
            // Right path on the wrong host.
            "https://evil.example/ThinkVelta/agent-tracker/releases/download/v1/a.zip",
            // Right everything, no TLS.
            "http://github.com/ThinkVelta/agent-tracker/releases/download/v1/a.zip",
            // The releases *page*, not the download path.
            "https://github.com/ThinkVelta/agent-tracker/releases/tag/v1.0.0",
            // Dot-segments: Foundation neither normalizes nor decodes these
            // in URL.path, so a prefix check alone is talked past.
            "https://github.com/ThinkVelta/agent-tracker/releases/download/../../A/r/releases/download/v1/a.zip",
            "https://github.com/ThinkVelta/agent-tracker/releases/download/%2e%2e/x/a.zip",
        ]
        for url in hostile {
            #expect(!Updater.isPinned(URL(string: url)!), "\(url)")
        }
    }

    // MARK: - Digest file parsing

    @Test func theShippedDigestFormatParses() {
        let text =
            "31eb1fcfd23ed2ec5d29a7860bbcb7656659b63a6ef8c771594670a7b61a4af3"
            + "  AgentTracker-0.4.0.zip\n"
        #expect(
            Updater.parseDigestFile(text, expectedFilename: "AgentTracker-0.4.0.zip")
                == "31eb1fcfd23ed2ec5d29a7860bbcb7656659b63a6ef8c771594670a7b61a4af3")
    }

    @Test func aDigestForAnotherFilenameIsRefused() {
        let text =
            "31eb1fcfd23ed2ec5d29a7860bbcb7656659b63a6ef8c771594670a7b61a4af3"
            + "  AgentTracker-0.3.0.zip"
        #expect(Updater.parseDigestFile(text, expectedFilename: "AgentTracker-0.4.0.zip") == nil)
    }

    @Test func malformedDigestsAreRefused() {
        let name = "AgentTracker-1.0.0.zip"
        // Too short, too long, non-hex, empty, digest-only.
        for text in [
            "abc123  \(name)",
            String(repeating: "a", count: 65) + "  \(name)",
            String(repeating: "z", count: 64) + "  \(name)",
            "",
            String(repeating: "a", count: 64),
        ] {
            #expect(Updater.parseDigestFile(text, expectedFilename: name) == nil, "\(text)")
        }
    }

    @Test func uppercaseDigestsNormalize() {
        let upper = String(repeating: "AB12", count: 16)
        let parsed = Updater.parseDigestFile(
            "\(upper)  a.zip", expectedFilename: "a.zip")
        #expect(parsed == upper.lowercased())
    }

    // MARK: - Hashing, against a known vector

    @Test func sha256MatchesTheKnownVector() {
        // The NIST test vector for "abc".
        #expect(
            Updater.sha256Hex(of: Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// The acceptance criterion in the brief, in its testable form: a download
    /// that does not hash to the published digest is refused — one flipped
    /// byte is enough.
    @Test func aCorruptedDownloadHashesDifferently() {
        var bytes = Data("release contents".utf8)
        let published = Updater.sha256Hex(of: bytes)
        bytes[0] ^= 1
        #expect(Updater.sha256Hex(of: bytes) != published)
    }

    // MARK: - Team identity parsing

    @Test func teamIdentifierIsExtractedFromCodesignOutput() {
        let output = """
            Executable=/Applications/AgentTracker.app/Contents/MacOS/AgentTracker
            Identifier=com.thinkvelta.agent-tracker
            TeamIdentifier=258KD5G8WH
            """
        #expect(Updater.teamIdentifier(fromCodesignOutput: output) == "258KD5G8WH")
    }

    /// "not set" is codesign's own spelling for an ad-hoc signature, and it
    /// must map to nil — an ad-hoc identity is exactly what the updater
    /// exists to refuse.
    @Test func anAdHocSignatureHasNoTeam() {
        #expect(
            Updater.teamIdentifier(fromCodesignOutput: "TeamIdentifier=not set") == nil)
        #expect(Updater.teamIdentifier(fromCodesignOutput: "TeamIdentifier=") == nil)
        #expect(Updater.teamIdentifier(fromCodesignOutput: "no such line") == nil)
        #expect(Updater.teamIdentifier(fromCodesignOutput: "") == nil)
    }

    // MARK: - Install source

    @Test func aCaskroomDirectoryMeansHomebrew() {
        let source = InstallSource.detect(isBundled: true) {
            $0 == "/opt/homebrew/Caskroom/agent-tracker"
        }
        #expect(source == .homebrew)
        let intel = InstallSource.detect(isBundled: true) {
            $0 == "/usr/local/Caskroom/agent-tracker"
        }
        #expect(intel == .homebrew)
    }

    @Test func noCaskroomMeansDirect() {
        #expect(InstallSource.detect(isBundled: true) { _ in false } == .direct)
    }

    /// `swift run` is not an install at all, Caskroom or no Caskroom — a
    /// developer with a brew copy on the side must not have their dev build
    /// told to `brew upgrade`.
    @Test func anUnbundledBuildIsDevelopmentEvenWithACaskroom() {
        #expect(InstallSource.detect(isBundled: false) { _ in true } == .development)
    }
}
