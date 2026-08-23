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

    private let managed = InstallSource.homebrewManagedBundlePath

    @Test func aCaskroomEntryPlusTheManagedPathMeansHomebrew() {
        let source = InstallSource.detect(isBundled: true, bundlePath: managed) {
            $0 == "/opt/homebrew/Caskroom/agent-tracker"
        }
        #expect(source == .homebrew)
        let intel = InstallSource.detect(isBundled: true, bundlePath: managed) {
            $0 == "/usr/local/Caskroom/agent-tracker"
        }
        #expect(intel == .homebrew)
    }

    @Test func noCaskroomMeansDirect() {
        let source = InstallSource.detect(isBundled: true, bundlePath: managed) { _ in false }
        #expect(source == .direct)
    }

    /// The Caskroom says brew believes it manages the cask; the bundle path
    /// says whether THIS copy is the one it manages. A direct copy in
    /// ~/Applications beside a stale Caskroom entry must self-update rather
    /// than defer to a brew that does not own it.
    @Test func aBundleOutsideTheManagedPathIsDirectDespiteACaskroom() {
        let source = InstallSource.detect(
            isBundled: true, bundlePath: "/Users/dev/Applications/AgentTracker.app"
        ) { _ in true }
        #expect(source == .direct)
    }

    /// `swift run` is not an install at all, Caskroom or no Caskroom — a
    /// developer with a brew copy on the side must not have their dev build
    /// told to `brew upgrade`.
    @Test func anUnbundledBuildIsDevelopmentEvenWithACaskroom() {
        let source = InstallSource.detect(isBundled: false, bundlePath: managed) { _ in true }
        #expect(source == .development)
    }

    /// The brew binary lives two levels above the Caskroom; every runnable
    /// candidate surfaces, because Caskroom presence alone cannot say which
    /// prefix actually manages the cask — the ownership probe decides that.
    @Test func brewCandidatesDeriveFromEveryMatchingCaskroom() {
        #expect(
            InstallSource.brewExecutableCandidates(
                directoryExists: { $0 == "/opt/homebrew/Caskroom/agent-tracker" },
                isExecutable: { _ in true })
                == ["/opt/homebrew/bin/brew"])
        let all = InstallSource.brewExecutableCandidates(
            directoryExists: { _ in true }, isExecutable: { _ in true })
        #expect(all == ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
        #expect(
            InstallSource.brewExecutableCandidates(
                directoryExists: { _ in false }, isExecutable: { _ in true }
            ).isEmpty)
    }

    /// A machine migrated between prefixes can hold a stale Caskroom whose
    /// brew is gone; the candidate list keeps whichever binary runs, in
    /// either direction, and holds nothing when neither does.
    @Test func aStaleCaskroomDoesNotShadowAWorkingPrefix() {
        let both: (String) -> Bool = { _ in true }
        #expect(
            InstallSource.brewExecutableCandidates(
                directoryExists: both,
                isExecutable: { $0 == "/usr/local/bin/brew" })
                == ["/usr/local/bin/brew"])
        #expect(
            InstallSource.brewExecutableCandidates(
                directoryExists: both,
                isExecutable: { $0 == "/opt/homebrew/bin/brew" })
                == ["/opt/homebrew/bin/brew"])
        #expect(
            InstallSource.brewExecutableCandidates(
                directoryExists: both, isExecutable: { _ in false }
            ).isEmpty)
    }

    // MARK: - Uninstall plans

    /// Who removes the bundle depends on who owns it: brew's manifest must
    /// stay true for brew installs, a direct bundle goes to the Trash, and a
    /// development build has no bundle, so only the hooks are cleaned.
    @Test func uninstallPlansMatchTheInstallSource() {
        #expect(
            Uninstaller.plan(for: .homebrew)
                == [.unhookAgents, .disableLoginItem, .brewUninstall])
        #expect(
            Uninstaller.plan(for: .direct)
                == [.unhookAgents, .disableLoginItem, .trashBundle])
        #expect(Uninstaller.plan(for: .development) == [.unhookAgents])
    }
}
