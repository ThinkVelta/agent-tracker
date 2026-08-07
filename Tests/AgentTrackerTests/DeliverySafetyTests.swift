import Foundation
import Testing

@testable import AgentTracker

/// Source-level guards on the delivery path.
///
/// Unusual for this repo, and earned: each of these forbids a construct that
/// would be *correct-looking* and catastrophic. None of them can be caught by a
/// behavioural test, because the failure is that someone later writes the wrong
/// thing and every existing test still passes.
final class DeliverySafetyTests {
    private func source(_ file: String) throws -> String {
        // Located from this file rather than the working directory, so it works
        // under `swift test` and in CI alike.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AgentTrackerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = root.appendingPathComponent("Sources/AgentTracker/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Code only. These files *name* the forbidden constructs in their comments,
    /// to explain why they are forbidden — which is exactly the documentation
    /// that should survive, so the guard must not trip over it.
    private func code(_ file: String) throws -> String {
        try source(file)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    private var deliveryFiles: [String] {
        ["GhosttyScripting.swift", "ContinueSender.swift", "ContinueSchedules.swift"]
    }

    /// The message is a user-editable text field. Interpolating it into
    /// AppleScript source would make any quote in it an arbitrary-code-execution
    /// route into a language that can drive every scriptable app on the machine.
    @Test func noneOfTheDeliveryPathUsesAppleScriptSource() throws {
        for file in deliveryFiles {
            let text = try code(file)
            #expect(text.contains("NSAppleScript") == false, "\(file) builds AppleScript source")
            #expect(text.contains("osascript") == false, "\(file) shells out to osascript")
        }
    }

    /// A permission prompt at fire time is a prompt nobody is there to answer,
    /// and it would block the delivery it was meant to authorise.
    @Test func automationIsNeverPreflightedWithAPrompt() throws {
        let text = try code("GhosttyScripting.swift")
        #expect(text.contains("askUserIfNeeded: true") == false)
        // The call is made with a literal false, not a variable that could be
        // flipped somewhere else.
        #expect(text.contains("DescType(typeWildCard), false)"))
    }

    /// `chooseAmbiguous` deliberately cycles candidates so repeated clicks reach
    /// different windows, driven by an in-memory click count. Correct for
    /// focusing; catastrophic for typing. Delivery must resolve its own target.
    @Test func deliveryNeverReusesTheFocusRotation() throws {
        for file in deliveryFiles + ["ContinueDelivery.swift"] {
            let text = try code(file)
            for forbidden in ["chooseAmbiguous", "nextFocusRotation", "TerminalFocuser.focus"] {
                #expect(text.contains(forbidden) == false, "\(file) references \(forbidden)")
            }
        }
    }

    /// Addressing a surface by index is wrong: an index shifts the moment any
    /// window closes, and between reading the list and writing to it that is a
    /// real interval. Verified separately that `formUniqueID` resolves the same
    /// surface an index did, while `formName` fails outright.
    @Test func writesAddressASurfaceByIdRatherThanPosition() throws {
        let text = try source("GhosttyScripting.swift")
        #expect(text.contains("formUniqueID"))
        // The write helpers take a surface ID, never an index. Asserted on the
        // parameter rather than the whole signature: pinning the signature made
        // this fail when an unrelated argument was added, which trains people to
        // update the guard instead of reading it.
        #expect(text.contains("toSurface surfaceId: String"))
        #expect(text.contains("inSurface surfaceId: String"))
        // Reads legitimately enumerate by index; only the WRITE path must not.
        // The single specifier the writes build is the id one.
        #expect(text.contains("surfaceSpecifier(id:"))
        #expect(text.contains("private static func surfaceSpecifier(id surfaceId: String)"))
    }

    /// The text write must fail CLOSED.
    ///
    /// It previously returned `true` when the reply carried no result, so an
    /// unconfirmed write read as a success — and the next step after a successful
    /// write is pressing Return, which submits whatever is on that prompt.
    ///
    /// The two commands genuinely differ, which is what made the bug easy to
    /// write: per `Ghostty.sdef`, `perform action` declares
    /// `<result type="boolean"` while `send key` declares no result at all. So the
    /// rule is per command, and only the one that can be confirmed is required to
    /// confirm.
    @Test func theTextWriteRequiresAnExplicitAcknowledgement() throws {
        let text = try code("GhosttyScripting.swift")
        #expect(text.contains("acknowledgement: .requiresTrue"))
        #expect(text.contains("acknowledgement: .completesWithoutError"))

        // The fail-open default is gone: no `else { return true }` guarding a
        // missing direct object.
        #expect(
            text.contains(
                "guard let result = reply.forKeyword(AEKeyword(keyDirectObject)) else { return true }"
            )
                == false)
        #expect(text.contains("case .requiresTrue:"))
    }

    /// Return is its own call, reachable only after a successful write. If these
    /// ever merge into one command, the ordering test in ContinueSenderTests
    /// stops proving anything.
    @Test func typingAndPressingReturnStayTwoSeparateOperations() throws {
        let scripting = try source("GhosttyScripting.swift")
        #expect(scripting.contains("send key") || scripting.contains("sendKey"))
        // `input text` is a paste and sits behind clipboard-paste-protection, a
        // sheet this app can neither see nor dismiss.
        #expect(scripting.contains("performAction"))

        let sender = try source("ContinueSender.swift")
        #expect(sender.contains("guard ops.writeText("))
        #expect(sender.contains("guard ops.pressReturn("))
    }
}
