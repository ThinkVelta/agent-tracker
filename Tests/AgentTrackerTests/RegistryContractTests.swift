import Foundation
import Testing

@testable import AgentTracker

/// The drift check, and the agreements that keep it honest.
///
/// The check is only worth having if its vocabulary is the same one the parsers
/// use. A second, private copy that nobody compares would go stale exactly like
/// the field it is watching, and then report "all values known" about values it
/// no longer knows.
struct RegistryContractTests {
    private func payload(_ json: String, file: String = "1.json") -> (file: String, data: Data) {
        (file: file, data: Data(json.utf8))
    }

    // MARK: - The vocabularies cannot drift apart

    /// What can still go wrong now that the vocabulary is derived.
    ///
    /// An earlier version of this asserted that every known status parsed to
    /// something, and called that "exactly" — it would have stayed green while
    /// `Status(raw:)` grew a case the check knew nothing about, which is the
    /// precise drift this file exists to catch, reproduced inside its own
    /// guard.
    ///
    /// The fix was to delete the second list rather than to compare against it:
    /// `knownStatuses` is now `Status.allCases`, so a new case propagates to
    /// the check on its own and the two *cannot* disagree. Comparing them here
    /// would assert a tautology. What remains genuinely breakable is the
    /// mapping each case carries, so that is what this covers.
    @Test func everyStatusCaseContributesADistinctToken() {
        let cases = ClaudeSessionRegistry.Status.allCases

        // A case added with `raw` returning nil would be invisible to the
        // check while the parser accepted it — the one way the derivation can
        // still be quietly holed. `.unknown` is the only case entitled to it.
        #expect(cases.filter { $0.raw == nil } == [.unknown])

        // Two cases returning the same token would make one unreachable, so a
        // status would parse to the wrong case rather than to `.unknown`.
        let tokens = cases.compactMap(\.raw)
        #expect(tokens.count == Set(tokens).count, "two statuses share a token")

        // Every token round-trips to the case it came from.
        for status in cases where status.raw != nil {
            #expect(ClaudeSessionRegistry.Status(raw: status.raw) == status)
        }
        #expect(ClaudeSessionRegistry.Status(raw: "compacting") == .unknown)
    }

    /// A chosen source must be a known one. A value in `chosenNameSources` that
    /// the check would flag as drift would have the app showing a name and the
    /// doctor calling it unrecognized in the same breath.
    @Test func everyChosenSourceIsAKnownSource() {
        #expect(RegistryContract.chosenNameSources.isSubset(of: RegistryContract.knownNameSources))
    }

    /// The parser reads `chosenNameSources` rather than its own list, so this
    /// asserts the wiring rather than restating the set.
    @Test func theParserAgreesWithTheChosenSet() {
        for source in RegistryContract.knownNameSources {
            let entry = ClaudeSessionRegistry.parse(
                Data(#"{"sessionId":"s1","name":"n","nameSource":"\#(source)"}"#.utf8))
            #expect(
                entry?.nameIsChosen == RegistryContract.chosenNameSources.contains(source),
                "\(source) disagrees between the parser and the contract")
        }
    }

    // MARK: - Observing drift

    @Test func aKnownVocabularyReportsNoDrift() {
        let observation = RegistryContract.observe([
            payload(#"{"sessionId":"a","nameSource":"user","status":"busy"}"#, file: "1.json"),
            payload(#"{"sessionId":"b","nameSource":"derived","status":"idle"}"#, file: "2.json"),
            payload(#"{"sessionId":"c","status":"waiting"}"#, file: "3.json"),
        ])
        #expect(observation.entriesRead == 3)
        #expect(!observation.sawDrift)
        #expect(observation.unreadableFiles.isEmpty)
    }

    /// The regression this whole file exists for: the shape of the 2.1.251
    /// change, had the new token been one nobody had decoded yet.
    @Test func anUnseenNameSourceIsReportedByValue() {
        let observation = RegistryContract.observe([
            payload(#"{"sessionId":"a","name":"n","nameSource":"sponsor"}"#)
        ])
        #expect(observation.unknownNameSources == ["sponsor"])
        #expect(observation.sawDrift)
    }

    @Test func anUnseenStatusIsReportedByValue() {
        let observation = RegistryContract.observe([
            payload(#"{"sessionId":"a","status":"compacting"}"#)
        ])
        #expect(observation.unknownStatuses == ["compacting"])
        #expect(observation.sawDrift)
    }

    /// Deduplicated and sorted: twenty sessions on a new build are one finding,
    /// not twenty, and the order cannot depend on directory enumeration.
    @Test func repeatedValuesCollapseAndSort() {
        let observation = RegistryContract.observe([
            payload(#"{"sessionId":"a","nameSource":"zeta"}"#, file: "1.json"),
            payload(#"{"sessionId":"b","nameSource":"alpha"}"#, file: "2.json"),
            payload(#"{"sessionId":"c","nameSource":"zeta"}"#, file: "3.json"),
        ])
        #expect(observation.unknownNameSources == ["alpha", "zeta"])
    }

    /// Case is folded before comparing, matching how both fields are read. A
    /// differently-spelled known token is not drift, and reporting it as such
    /// sends someone reading a binary for nothing.
    @Test func caseAloneIsNotDrift() {
        let observation = RegistryContract.observe([
            payload(#"{"sessionId":"a","nameSource":"User","status":"BUSY"}"#)
        ])
        #expect(!observation.sawDrift)
    }

    /// A field absent entirely is the commonest healthy case — `nameSource` is
    /// omitted for a name that arrived with no source — and must not read as a
    /// value nobody recognizes.
    @Test func absentFieldsAreNotDrift() {
        let observation = RegistryContract.observe([payload(#"{"sessionId":"a"}"#)])
        #expect(observation.entriesRead == 1)
        #expect(!observation.sawDrift)
    }

    /// A non-string where a string belongs is drift of a kind this check does
    /// not claim to cover: it is skipped, not reported as an unknown value,
    /// because there is no value to name.
    @Test func aFieldOfTheWrongTypeIsSkippedRatherThanNamed() {
        let observation = RegistryContract.observe([
            payload(#"{"sessionId":"a","nameSource":42,"status":true}"#)
        ])
        #expect(observation.entriesRead == 1)
        #expect(!observation.sawDrift)
    }

    @Test func unusableFilesAreNamedNotCounted() {
        let observation = RegistryContract.observe([
            payload("not json at all", file: "broken.json"),
            payload(#"{"pid":1}"#, file: "no-id.json"),
            payload(#"{"sessionId":"a"}"#, file: "fine.json"),
        ])
        #expect(observation.entriesRead == 1)
        #expect(observation.unreadableFiles == ["broken.json", "no-id.json"])
    }

    @Test func nothingAtAllObservesNothing() {
        #expect(RegistryContract.observe([]) == RegistryContract.Observation())
    }
}
