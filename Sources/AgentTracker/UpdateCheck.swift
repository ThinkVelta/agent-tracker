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

    enum Outcome: Equatable {
        case upToDate
        case updateAvailable(version: String, url: URL)
        /// The repo has no published releases — true today; say so rather
        /// than pretending "up to date" means something.
        case noReleases
        case failed(String)
    }

    /// Numeric dotted-version comparison; a tag's leading "v" is cosmetic.
    /// Non-numeric segments compare as 0 — a malformed tag must never claim
    /// to be newer than a real version.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0) ?? 0 }
        }
        let lhs = parts(candidate)
        let rhs = parts(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// Extracts (tag, html page) from a GitHub "latest release" payload.
    static func parseRelease(_ data: Data) -> (tag: String, url: URL)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = object["tag_name"] as? String, !tag.isEmpty
        else { return nil }
        let page = (object["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        return (tag, page)
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
                ? .updateAvailable(version: release.tag, url: release.url)
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
