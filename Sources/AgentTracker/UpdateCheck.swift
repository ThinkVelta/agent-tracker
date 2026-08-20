import Foundation

/// Manual "check for updates" against GitHub releases — no Sparkle, no
/// dependencies, no background phoning home: one request, only when the user
/// clicks the button. Parsing and version comparison are pure and tested; the
/// network call is the thin part.
enum UpdateCheck {
    static let releasesURL = URL(
        string: "https://api.github.com/repos/ThinkVelta/agent-tracker/releases/latest")!
    static let releasesPage = URL(
        string: "https://github.com/ThinkVelta/agent-tracker/releases")!

    /// One release, as much of it as the payload offered. `zip`/`digest` are
    /// nil when the assets are missing or fail `Updater.isPinned` — the check
    /// still reports the version, and installing is simply not offered.
    struct Release: Equatable {
        let tag: String
        let page: URL
        let zip: URL?
        let digest: URL?
    }

    enum Outcome: Equatable {
        case upToDate
        case updateAvailable(Release)
        /// The repo has no published releases — true today; say so rather
        /// than pretending "up to date" means something.
        case noReleases
        case failed(String)
    }

    /// Strictly numeric dotted version; one leading "v" is cosmetic — only
    /// leading, and only one, because trimming both ends would launder
    /// malformed tags like "1.2.3v" into valid ones. nil for anything else:
    /// coercing bad segments to 0 would let "0.1.alpha.1" read as [0,1,0,1]
    /// and outrank a real 0.1.0.
    static func numericVersion(_ raw: String) -> [Int]? {
        let normalized =
            raw.hasPrefix("v") || raw.hasPrefix("V") ? String(raw.dropFirst()) : raw
        let segments = normalized.split(separator: ".")
        guard !segments.isEmpty else { return nil }
        var values: [Int] = []
        for segment in segments {
            guard let value = Int(segment) else { return nil }
            values.append(value)
        }
        return values
    }

    /// Asymmetric on malformed input, deliberately: a malformed *tag* must
    /// never claim to be newer than a real version, while a non-numeric
    /// *current* version (a "dev" build) should always be offered releases.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let lhs = numericVersion(candidate) else { return false }
        guard let rhs = numericVersion(current) else { return true }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// Extracts the release from a GitHub "latest release" payload. The
    /// versioned zip is chosen over the stable-named `AgentTracker.zip`
    /// because the digest file is published under the versioned name, and a
    /// digest for a different filename verifies nothing. Asset URLs that fail
    /// the pin are dropped rather than failing the parse: the *check* is
    /// trustworthy from the tag alone, only *installing* needs the assets.
    static func parseRelease(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = object["tag_name"] as? String, !tag.isEmpty
        else { return nil }
        let page = (object["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage

        var zip: URL?
        var digest: URL?
        let assets = object["assets"] as? [[String: Any]] ?? []
        let named: [(name: String, url: URL)] = assets.compactMap { asset in
            guard let name = asset["name"] as? String,
                let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
                Updater.isPinned(url)
            else { return nil }
            return (name, url)
        }
        // The exact name this repo's releases publish for this tag, nothing
        // broader: a first-match pattern would make installability depend on
        // asset order the moment a release carried a second matching zip.
        let normalized =
            tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let expected = "AgentTracker-\(normalized).zip"
        if let archive = named.first(where: { $0.name == expected }) {
            zip = archive.url
            digest = named.first(where: { $0.name == expected + ".sha256" })?.url
        }
        return Release(tag: tag, page: page, zip: zip, digest: digest)
    }

    static func check(currentVersion: String) async -> Outcome {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("unexpected response")
            }
            if http.statusCode == 404 { return .noReleases }
            guard http.statusCode == 200 else { return .failed("HTTP \(http.statusCode)") }
            guard let release = parseRelease(data) else { return .failed("unrecognized payload") }
            return isNewer(release.tag, than: currentVersion)
                ? .updateAvailable(release)
                : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// What this build calls itself. A bundled app reads its Info.plist; a bare
/// `swift run` binary has none and says so instead of inventing a number.
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
    }

    static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}
