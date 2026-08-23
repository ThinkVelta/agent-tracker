import AppKit
import CryptoKit
import Foundation

/// Downloads, verifies, and installs a release — the write half of what
/// `UpdateCheck` reads. An updater is a code-execution path, so every step
/// that could be skipped is instead the gate for the next one:
///
/// 1. Only a direct install updates itself (`InstallSource`); brew owns its
///    bundles and development builds have nothing to swap.
/// 2. The download must match the digest the release published beside it.
/// 3. The new bundle must pass `codesign --verify --strict` and carry the
///    same Team ID as the running app, so nobody who can serve a zip can
///    become code running as the user. `spctl` then confirms notarization.
/// 4. Quarantine is stripped only after all of that succeeds, never before.
/// 5. The swap is atomic (`replaceItemAt`), and a parent directory this user
///    cannot write fails cleanly before anything is downloaded.
enum Updater {
    // MARK: - Pinning and parsing (pure, tested)

    /// A release asset may only be fetched from the repo's own download path.
    /// The release JSON is data from the network, so its URLs are claims, not
    /// facts. The pin constrains the first hop; GitHub then redirects to its
    /// asset host over TLS, which is how every release download works. What
    /// the pin buys is that the *request* can only name this repo's assets.
    ///
    /// Checked on the raw path with a closed alphabet: dot-segments and
    /// percent-escapes are how a prefix check gets talked past (Foundation
    /// neither normalizes `..` nor decodes `%2e` in `URL.path`), so any
    /// character outside the release path's own refuses.
    static func isPinned(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "github.com" else { return false }
        let path = url.path
        guard path.hasPrefix("/ThinkVelta/agent-tracker/releases/download/"),
            !path.contains("..")
        else { return false }
        return path.allSatisfy { $0.isLetter || $0.isNumber || "./-_".contains($0) }
    }

    /// The published digest file: `<64 hex>  <filename>`. The filename must
    /// match the asset it claims to describe — a digest for a different file
    /// proves nothing about this one.
    static func parseDigestFile(_ text: String, expectedFilename: String) -> String? {
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2,
            parts[0].count == 64,
            parts[0].allSatisfy(\.isHexDigit),
            parts[1] == expectedFilename[...]
        else { return nil }
        return parts[0].lowercased()
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The `TeamIdentifier=` line from `codesign -dv` output. "not set" — an
    /// ad-hoc signature — maps to nil, which every caller treats as a refusal:
    /// team identity is the property the whole verification hangs on.
    static func teamIdentifier(fromCodesignOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = String(line.dropFirst("TeamIdentifier=".count))
            return value == "not set" || value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - The pipeline (I/O)

    enum Outcome: Equatable {
        case installed
        case failed(String)
    }

    /// Everything up to and including the swap. The relaunch is the caller's
    /// call — Settings wants to say "restarting…" first, the launch-time path
    /// just goes.
    static func downloadAndInstall(_ release: UpdateCheck.Release) async -> Outcome {
        guard InstallSource.current == .direct else {
            return .failed(
                InstallSource.current == .homebrew
                    ? "This install is managed by Homebrew; update with "
                        + "brew upgrade --cask agent-tracker"
                    : "Development builds update by rebuilding.")
        }
        guard let zipURL = release.zip, let digestURL = release.digest else {
            return .failed("The release carries no verifiable download.")
        }
        guard isPinned(zipURL), isPinned(digestURL) else {
            return .failed("The release's download URLs are not this repo's own.")
        }

        let bundleURL = Bundle.main.bundleURL
        let parent = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return .failed(
                "\(parent.path) is not writable by this user; "
                    + "download the release and replace the app by hand.")
        }
        guard let runningTeam = await teamIdentifier(ofBundleAt: bundleURL) else {
            return .failed(
                "This build is not Developer ID signed, so a downloaded update "
                    + "cannot be verified against it; replace the app by hand once.")
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-tracker-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true)

            // The digest first: it is tiny, and a bad one fails the whole
            // update before the download spends anyone's bandwidth.
            let (digestData, digestResponse) = try await URLSession.shared.data(from: digestURL)
            guard (digestResponse as? HTTPURLResponse)?.statusCode == 200,
                let digestText = String(bytes: digestData, encoding: .utf8),
                let expected = parseDigestFile(
                    digestText, expectedFilename: zipURL.lastPathComponent)
            else {
                return .failed("The published digest could not be read.")
            }

            let (downloaded, zipResponse) = try await URLSession.shared.download(from: zipURL)
            guard (zipResponse as? HTTPURLResponse)?.statusCode == 200 else {
                return .failed("Download failed (HTTP).")
            }
            let archive = staging.appendingPathComponent(zipURL.lastPathComponent)
            try FileManager.default.moveItem(at: downloaded, to: archive)

            let actual = sha256Hex(of: try Data(contentsOf: archive))
            guard actual == expected else {
                return .failed("The download does not match the digest the release published.")
            }

            // ditto, not unzip: it preserves the signature and resource forks,
            // same reason the release packs with it.
            let unpack = await ProcessRunner.run(
                "/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
            guard unpack.ok else {
                return .failed("The archive could not be unpacked.")
            }
            let newBundle = staging.appendingPathComponent("AgentTracker.app")
            guard FileManager.default.fileExists(atPath: newBundle.path) else {
                return .failed("The archive does not contain AgentTracker.app.")
            }

            // Signature, then identity, then notarization — in that order,
            // and all before quarantine is touched.
            guard
                await ProcessRunner.run(
                    "/usr/bin/codesign", ["--verify", "--deep", "--strict", newBundle.path]
                ).ok
            else {
                return .failed("The downloaded app fails signature verification.")
            }
            guard let newTeam = await teamIdentifier(ofBundleAt: newBundle),
                newTeam == runningTeam
            else {
                return .failed("The downloaded app is signed by a different team.")
            }
            guard
                await ProcessRunner.run(
                    "/usr/sbin/spctl", ["--assess", "--type", "execute", newBundle.path]
                ).ok
            else {
                return .failed("Gatekeeper does not accept the downloaded app.")
            }

            // The delivered bytes must be NEWER, read from the verified
            // bundle itself and never from the release JSON: signature, team,
            // and notarization all pass for any genuine release, including an
            // old one a tampered API response points at — a forced downgrade
            // would quietly reintroduce whatever that release got wrong.
            guard
                let newVersion = Bundle(url: newBundle)?
                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                UpdateCheck.isNewer(newVersion, than: AppInfo.version)
            else {
                return .failed("The downloaded app is not newer than this one.")
            }

            // Only now: a quarantined bundle would be blocked on relaunch, but
            // stripping before verification would launder whatever failed it.
            _ = await ProcessRunner.run(
                "/usr/bin/xattr", ["-dr", "com.apple.quarantine", newBundle.path])

            _ = try FileManager.default.replaceItemAt(bundleURL, withItemAt: newBundle)
            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The update path for a Homebrew-managed install: ask brew, which owns
    /// the bundle and its manifest, to do what the app must not do itself.
    /// brew replaces the bundle on disk while this process keeps running from
    /// its old inode; the caller relaunches into the new one exactly as after
    /// a self-swap. `HOMEBREW_NO_AUTO_UPDATE` keeps the run scoped to this
    /// cask instead of a general brew refresh nobody asked for.
    static func upgradeViaHomebrew() async -> Outcome {
        guard InstallSource.current == .homebrew else {
            return .failed("This install is not Homebrew's.")
        }
        guard let brew = await InstallSource.owningHomebrewExecutable() else {
            return .failed("No Homebrew prefix claims this cask.")
        }
        let result = await ProcessRunner.run(
            brew, ["upgrade", "--cask", "agent-tracker"],
            environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
        guard result.ok else {
            let lines = result.output.split(whereSeparator: \.isNewline).suffix(2)
            return .failed("brew upgrade failed: \(lines.joined(separator: " "))")
        }
        return .installed
    }

    /// Restart into the swapped bundle. A detached shell waits for this
    /// process to exit and only then opens the new one, so two instances
    /// never watch the same state directory at once. `SMAppService` keys the
    /// login item to the bundle identifier, which the swap preserves, so no
    /// re-registration is needed.
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        // Bounded to ~60s, and re-checked: a termination stalled that long is
        // the user's doing, and a watcher that opens the app hours after they
        // deliberately quit would override them.
        let script =
            "n=0; while kill -0 \(pid) 2>/dev/null && [ $n -lt 300 ]; "
            + "do sleep 0.2; n=$((n+1)); done; "
            + "kill -0 \(pid) 2>/dev/null || open \"$0\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, path]
        do {
            try task.run()
        } catch {
            // The swap already happened; quitting anyway would leave no app
            // running and nothing to bring it back. Stay up — the old code
            // keeps working from memory, and the next manual launch is the
            // new version.
            print("[update] relaunch helper failed to spawn: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Process plumbing

    private static func teamIdentifier(ofBundleAt url: URL) async -> String? {
        let result = await ProcessRunner.run("/usr/bin/codesign", ["-dv", url.path])
        guard result.ok else { return nil }
        return teamIdentifier(fromCodesignOutput: result.output)
    }
}
