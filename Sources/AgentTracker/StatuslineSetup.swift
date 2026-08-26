import Foundation

/// Which statusline the user has chosen, read from the two files that define
/// it, plus the one write that switches the display.
///
/// Three states, matching the Settings picker: the wrapper is not registered
/// (off), it captures behind the user's own display (keepOwn), or it captures
/// and shows agent-tracker's built-in statusline (builtin). Installing and
/// restoring go through the bundled installer script — the app never edits
/// `~/.claude/settings.json` itself. Switching the display between the two
/// installed states edits only agent-tracker's own record file, which is why
/// that one is done here directly.
enum StatuslineSetup {
    enum Mode: String, CaseIterable, Identifiable {
        case off
        case keepOwn
        case builtin

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return "Off"
            case .keepOwn: return "Keep my statusline"
            case .builtin: return "Agent Tracker's"
            }
        }
    }

    /// The wrapper's install-time record: what it displaced, and which display
    /// to show. The same file the wrapper and the installers read.
    nonisolated static var recordURL: URL {
        SessionStore.baseDirectory.appendingPathComponent("claude-statusline-wrapped.json")
    }

    nonisolated static var claudeSettingsURL: URL {
        StatuslineDirectory.defaultDirectory.appendingPathComponent("settings.json")
    }

    static func currentMode() -> Mode {
        mode(
            settings: try? Data(contentsOf: claudeSettingsURL),
            record: try? Data(contentsOf: recordURL))
    }

    /// Whether the user has a statusline of their own — the thing that decides
    /// onboarding's default: displace nothing, or fill an empty slot with the
    /// built-in display.
    static func hasOwnStatusline() -> Bool {
        ownStatusline(
            settings: try? Data(contentsOf: claudeSettingsURL),
            record: try? Data(contentsOf: recordURL))
    }

    /// The wrapper's own registration does not count as theirs — but what it
    /// *displaced* does, read from the record, so a re-run of onboarding over
    /// an existing keep-mine install cannot misread "wrapper" as "no statusline"
    /// and default someone's own display away. Mirrors `own_statusline` in
    /// `integrations/onboard.py`; the two must keep agreeing.
    static func ownStatusline(settings: Data?, record: Data?) -> Bool {
        guard let settings,
            let object = (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any],
            let command = Doctor.statusLineCommand(in: object),
            !command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        guard command.contains("agent-tracker-statusline") else { return true }
        guard let record,
            let stored = (try? JSONSerialization.jsonObject(with: record)) as? [String: Any],
            let wrapped = stored["wrapped"] as? [String: Any],
            let wrappedCommand = wrapped["command"] as? String,
            !wrappedCommand.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        return true
    }

    /// Pure, so tests can feed it raw bytes. Unreadable input reads as the
    /// safe answer for its half: no settings means not installed, and an
    /// installed wrapper with no readable record means "whatever you had",
    /// never a display the user did not pick.
    static func mode(settings: Data?, record: Data?) -> Mode {
        guard let settings,
            let object = (try? JSONSerialization.jsonObject(with: settings)) as? [String: Any],
            let command = Doctor.statusLineCommand(in: object),
            command.contains("agent-tracker-statusline")
        else { return .off }
        guard let record,
            let stored = (try? JSONSerialization.jsonObject(with: record)) as? [String: Any],
            stored["display"] as? String == "builtin"
        else { return .keepOwn }
        return .builtin
    }

    /// Flips the display key in the wrapper's record, between the two
    /// installed states. Refuses when there is no trustworthy record to edit —
    /// it never invents one, because a record without a real `wrapped` value
    /// is exactly what uninstall refuses to restore from.
    static func setDisplay(builtin: Bool, at url: URL = recordURL) -> Bool {
        guard let data = try? Data(contentsOf: url),
            var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            record.keys.contains("wrapped")
        else { return false }
        if builtin {
            record["display"] = "builtin"
        } else {
            record.removeValue(forKey: "display")
        }
        guard
            let updated = try? JSONSerialization.data(
                withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        return (try? updated.write(to: url)) != nil
    }
}
