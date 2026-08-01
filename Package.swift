// swift-tools-version: 5.9
import Foundation
import PackageDescription

// With Command Line Tools only (no full Xcode), SwiftPM passes `-I` instead of
// `-F` for its bundled Testing.framework, so `import Testing` fails to resolve.
// These settings fix the test target; skipped when Xcode is installed (SwiftPM
// finds the framework natively there). Note: SwiftPM's synthesized test-runner
// module has the same defect and cannot be reached from the manifest — on a
// CLT-only machine, forward the flags on the command line to actually execute:
//   DEV=/Library/Developer/CommandLineTools/Library/Developer
//   swift test -Xswiftc -F -Xswiftc "$DEV/Frameworks" -Xlinker -F"$DEV/Frameworks" \
//     -Xlinker -rpath -Xlinker "$DEV/Frameworks" -Xlinker -rpath -Xlinker "$DEV/usr/lib"
let cltDeveloperDir = "/Library/Developer/CommandLineTools/Library/Developer"
var testSwiftSettings: [SwiftSetting] = []
var testLinkerSettings: [LinkerSetting] = []
if FileManager.default.fileExists(atPath: "\(cltDeveloperDir)/Frameworks/Testing.framework"),
   !FileManager.default.fileExists(atPath: "/Applications/Xcode.app") {
    testSwiftSettings.append(.unsafeFlags(["-F", "\(cltDeveloperDir)/Frameworks"]))
    testLinkerSettings.append(.unsafeFlags([
        "-F", "\(cltDeveloperDir)/Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", "\(cltDeveloperDir)/Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", "\(cltDeveloperDir)/usr/lib",
    ]))
}

let package = Package(
    name: "AgentTracker",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AgentTracker",
            path: "Sources/AgentTracker"
        ),
        .testTarget(
            name: "AgentTrackerTests",
            dependencies: ["AgentTracker"],
            path: "Tests/AgentTrackerTests",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ]
)
