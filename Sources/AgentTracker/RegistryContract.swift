import Foundation

/// The values this build knows how to read out of Claude Code's session
/// registry, and a check for anything that turns up there instead.
///
/// `~/.claude/sessions` belongs to Claude Code, which owns the format and may
/// change it whenever it likes. The fields are undocumented, so no changelog
/// carries the notice: watching upstream release notes would not have caught
/// any change this file is here to catch.
///
/// Every parser on this side already degrades quietly on a value it does not
/// recognize, which is right for a menu bar app and wrong as the *only*
/// response. A token added upstream then reads as "not this" indefinitely, and
/// the symptom reaches the user as something that stopped appearing rather than
/// as an error. Measured: 2.1.251 began writing `nameSource: "user"` where
/// rename had written nothing, and every renamed session read as an invented
/// slug until somebody noticed the names were wrong.
///
/// So this is the alarm that the quiet degrading does not raise. It cannot say
/// what a new value *means* — that still needs a human reading the binary — but
/// it says a value exists that this build has never seen, on the first run
/// after the upgrade that introduced it.
///
/// **A smoke alarm, not a proof.** It only sees what the sessions on this
/// machine happen to produce, so a token that only appears for, say, a peer
/// session stays invisible until one runs. Silence here means nothing
/// unrecognized *turned up*, never that the format is unchanged.
enum RegistryContract {
    /// Every `nameSource` Claude keeps rather than discarding, read off the
    /// 2.1.251 binary's own normalizer.
    static let knownNameSources: Set<String> = [
        "user", "peer", "derived", "collision", "auto", "hook",
    ]

    /// The subset meaning a person settled on this name, rather than Claude
    /// generating one. Absence means chosen too, and is not a value — see
    /// `ClaudeSessionRegistry.Entry.nameIsChosen`, which reads this set so the
    /// rule and the check cannot drift apart.
    static let chosenNameSources: Set<String> = ["user", "peer"]

    /// Claude's activity vocabulary. `ClaudeSessionRegistryTests` asserts
    /// `Status(raw:)` recognizes exactly these, so the two cannot disagree.
    static let knownStatuses: Set<String> = ["busy", "shell", "idle", "waiting"]

    /// What one sweep of the registry directory found.
    struct Observation: Equatable {
        /// Entries that parsed far enough to check. Zero is not a finding on
        /// its own — no Claude session has to be running.
        var entriesRead = 0
        /// Files present but unusable: bad JSON, or no `sessionId`. Named
        /// rather than counted, because the file is the only handle on it.
        var unreadableFiles: [String] = []
        /// Values seen in a field this build reads, that it has no case for.
        var unknownNameSources: [String] = []
        var unknownStatuses: [String] = []

        var sawDrift: Bool { !unknownNameSources.isEmpty || !unknownStatuses.isEmpty }
    }

    /// Pure: registry payloads in, observation out. The directory read lives in
    /// `Doctor`, so every rule here is testable without arranging a machine.
    ///
    /// Deliberately re-parses rather than going through
    /// `ClaudeSessionRegistry.parse`, which is the thing under test: it
    /// normalizes an unrecognized value to a default, which is exactly the
    /// evidence this needs to see.
    static func observe(_ payloads: [(file: String, data: Data)]) -> Observation {
        var observation = Observation()
        var nameSources: Set<String> = []
        var statuses: Set<String> = []

        for payload in payloads {
            guard
                let object = try? JSONSerialization.jsonObject(with: payload.data)
                    as? [String: Any],
                let sessionId = object["sessionId"] as? String, !sessionId.isEmpty
            else {
                observation.unreadableFiles.append(payload.file)
                continue
            }
            observation.entriesRead += 1
            // Case-folded before comparing, matching how both fields are read.
            // A differently-spelled known token is not drift, and reporting it
            // as such would send someone reading a binary for nothing.
            if let source = object["nameSource"] as? String,
                !knownNameSources.contains(source.lowercased())
            {
                nameSources.insert(source)
            }
            if let status = object["status"] as? String,
                !knownStatuses.contains(status.lowercased())
            {
                statuses.insert(status)
            }
        }

        observation.unreadableFiles.sort()
        observation.unknownNameSources = nameSources.sorted()
        observation.unknownStatuses = statuses.sorted()
        return observation
    }
}

/// How the observation reports itself.
///
/// Lives beside the vocabulary rather than with the other rules in
/// `Diagnosis`: the set of known values, the sweep, and the sentence describing
/// what the sweep found are one concern, and splitting them across files is how
/// a check and the thing it checks come to disagree.
extension Diagnosis {
    /// Whether Claude's registry still speaks a vocabulary this build knows.
    ///
    /// A `warn`, never a `fail`. An unrecognized value does not mean the
    /// install is broken — every reader here has a defined answer for one — it
    /// means a name or a status may now be read wrongly, which is worth a look
    /// and is not worth a non-zero exit on a machine that works.
    ///
    /// Nothing to read is `unknown` rather than `ok`: with no entries the sweep
    /// did not run, and reporting that as a clean bill is the report concluding
    /// where its evidence does not.
    static func registryFormatFinding(_ input: Input) -> Finding {
        let observation = input.registryContract
        let unreadable = observation.unreadableFiles

        guard observation.entriesRead > 0 else {
            let detail =
                unreadable.isEmpty
                ? "no registry entries to check; nothing concluded"
                : "no readable registry entries; \(unreadable.count) unreadable "
                    + "(\(unreadable.joined(separator: ", ")))"
            return Finding(
                level: .unknown, check: "registry format", detail: detail, anchor: nil)
        }

        // Named individually. The value is the whole point of the finding: it
        // is what someone greps the Claude Code binary for, so a count would
        // report the problem while withholding the only useful part of it.
        var drift: [String] = []
        if !observation.unknownNameSources.isEmpty {
            drift.append("nameSource \(quoted(observation.unknownNameSources))")
        }
        if !observation.unknownStatuses.isEmpty {
            drift.append("status \(quoted(observation.unknownStatuses))")
        }

        // Appended rather than given its own check: a torn read of a file being
        // rewritten is plausible here, so it earns a clause, not a line.
        let trailer =
            unreadable.isEmpty ? "" : "; \(unreadable.count) file(s) unreadable"

        guard !drift.isEmpty else {
            return Finding(
                level: .ok, check: "registry format",
                detail: "\(observation.entriesRead) entr(ies) checked, all values known"
                    + trailer,
                anchor: nil)
        }
        return Finding(
            level: .warn, check: "registry format",
            detail: "Claude writes value(s) this build does not know: "
                + drift.joined(separator: ", ")
                + "; names or statuses may read wrongly" + trailer,
            anchor: "the-doctor-reports-an-unknown-registry-value")
    }

    private static func quoted(_ values: [String]) -> String {
        values.map { "\"\($0)\"" }.joined(separator: ", ")
    }
}
