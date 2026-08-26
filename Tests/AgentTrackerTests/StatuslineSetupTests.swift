import Foundation
import Testing

@testable import AgentTracker

/// The three-state read behind the Settings picker, and the one write it does
/// itself. Pure bytes in, so no test touches the real ~/.claude or
/// ~/.agent-tracker.
struct StatuslineSetupTests {
    private func bytes(_ object: Any) -> Data {
        // swiftlint:disable:next force_try — fixture construction, not code under test
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func settings(command: String?) -> Data {
        guard let command else { return bytes([:]) }
        return bytes(["statusLine": ["type": "command", "command": command]])
    }

    private let wrapper = "'/Users/dev/.agent-tracker/bin/agent-tracker-statusline.py'"

    @Test func noSettingsFileIsOff() {
        #expect(StatuslineSetup.mode(settings: nil, record: nil) == .off)
    }

    @Test func anEmptySlotIsOff() {
        #expect(StatuslineSetup.mode(settings: settings(command: nil), record: nil) == .off)
    }

    @Test func someoneElsesStatuslineIsOff() {
        let own = settings(command: "bash ~/.claude/statusline.sh")
        #expect(StatuslineSetup.mode(settings: own, record: nil) == .off)
    }

    @Test func theWrapperWithNoDisplayKeyKeepsTheirOwn() {
        let record = bytes(["schema": 1, "wrapped": ["type": "command", "command": "x"]])
        #expect(
            StatuslineSetup.mode(settings: settings(command: wrapper), record: record) == .keepOwn)
    }

    /// An installed wrapper whose record went missing must read as "whatever
    /// you had", never as a display the user did not pick.
    @Test func aMissingRecordKeepsTheirOwn() {
        #expect(StatuslineSetup.mode(settings: settings(command: wrapper), record: nil) == .keepOwn)
    }

    @Test func theBuiltinDisplayIsRecognised() {
        let record = bytes(["schema": 1, "wrapped": NSNull(), "display": "builtin"])
        #expect(
            StatuslineSetup.mode(settings: settings(command: wrapper), record: record) == .builtin)
    }

    @Test func malformedSettingsReadAsOff() {
        let garbage = Data("not json".utf8)
        #expect(StatuslineSetup.mode(settings: garbage, record: nil) == .off)
    }

    // MARK: - The display write

    private func temporaryRecord(_ object: Any?) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("statusline-record-\(UUID().uuidString).json")
        if let object {
            try bytes(object).write(to: url)
        }
        return url
    }

    @Test func switchingToBuiltinWritesTheKeyAndKeepsTheWrappedValue() throws {
        let url = try temporaryRecord(
            ["schema": 1, "wrapped": ["type": "command", "command": "bash mine.sh"]])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(StatuslineSetup.setDisplay(builtin: true, at: url))
        let record =
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(record?["display"] as? String == "builtin")
        #expect((record?["wrapped"] as? [String: Any])?["command"] as? String == "bash mine.sh")
    }

    @Test func switchingBackRemovesTheKey() throws {
        let url = try temporaryRecord(
            ["schema": 1, "wrapped": NSNull(), "display": "builtin"])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(StatuslineSetup.setDisplay(builtin: false, at: url))
        let record =
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(record?["display"] == nil)
        // A recorded null is proof the slot was empty; the write must not
        // drop it, or uninstall loses its licence to restore.
        #expect(record?.keys.contains("wrapped") == true)
    }

    /// No record, or one without a `wrapped` value, is not edited — a record
    /// invented here would let uninstall "restore" something never displaced.
    @Test func anUntrustworthyRecordRefusesTheWrite() throws {
        let missing = try temporaryRecord(nil)
        #expect(StatuslineSetup.setDisplay(builtin: true, at: missing) == false)

        let keyless = try temporaryRecord(["schema": 1])
        defer { try? FileManager.default.removeItem(at: keyless) }
        #expect(StatuslineSetup.setDisplay(builtin: true, at: keyless) == false)
    }
}
