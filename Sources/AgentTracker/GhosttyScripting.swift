import AppKit
import Foundation

/// Talks to Ghostty over Apple events. Read-only half.
///
/// **Raw `NSAppleEventDescriptor`, never `NSAppleScript`.** The message a
/// scheduled continue sends is a user-editable text field, and building
/// AppleScript source with it interpolated would make any quote in that field an
/// arbitrary-code-execution route into a language that can drive every scriptable
/// app on the machine. A raw event carries the string as data, where it cannot be
/// read as syntax.
///
/// Everything here is `nonisolated` and expects to be called off the main actor.
/// `AEDeterminePermissionToAutomateTarget` was measured **not returning within
/// 100 seconds** for a running-but-ungranted target, so anything on this path
/// that reached the main thread would freeze the menu bar for as long as it took.
enum GhosttyScripting {
    static let bundleIdentifier = "com.mitchellh.ghostty"

    /// Ghostty's four-character scripting codes, from its own
    /// `Ghostty.sdef`. Kept together so the source of every magic constant is
    /// one comment rather than eight.
    private enum Code {
        /// `terminal` class.
        static let terminal: DescType = 0x4774_726D  // 'Gtrm'
        /// `working directory` property.
        static let workingDirectory: AEKeyword = 0x4777_6472  // 'Gwdr'
        /// Standard suite property codes. Swift does not surface the Carbon
        /// names for these, so they are spelled out beside their four-char form
        /// rather than hunted for in a header.
        static let id: AEKeyword = 0x4944_2020  // 'ID  '
        static let name: AEKeyword = 0x706E_616D  // 'pnam'
    }

    enum Failure: Equatable, Error {
        /// Ghostty is not running, so it has no surfaces and nothing to grant.
        case notRunning
        /// The user has not granted, or has refused, permission to control it.
        case notPermitted
        /// It is running and permitted, but the event failed or returned nothing
        /// usable.
        case unreadable(String)

        var reason: String {
            switch self {
            case .notRunning:
                return "Ghostty isn't running"
            case .notPermitted:
                return "macOS hasn't been allowed to let Agent Tracker control Ghostty "
                    + "(System Settings › Privacy & Security › Automation)"
            case .unreadable(let detail):
                return "Couldn't read Ghostty's windows: \(detail)"
            }
        }
    }

    /// The running Ghostty, or nil. Also the reason a preflight can answer
    /// "not running" without sending any event at all.
    static func runningApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    /// Whether this app may control Ghostty, **without ever asking**.
    ///
    /// `askUserIfNeeded: false` is not optional here. The consent prompt belongs
    /// at a moment the user is expecting it — arming a schedule — and never at
    /// fire time, which is by definition when nobody is watching. A prompt raised
    /// at 04:00 would sit unanswered and block the delivery it was meant to
    /// authorise.
    ///
    /// Blocking, and the measured worst case is over 100 seconds, so the caller
    /// must already be off the main actor.
    static func automationPermission(pid: pid_t) -> Result<Void, Failure> {
        var target = AEAddressDesc()
        var pid = pid
        let built = AECreateDesc(
            DescType(typeKernelProcessID), &pid, MemoryLayout<pid_t>.size, &target)
        guard built == noErr else {
            return .failure(.unreadable("could not address Ghostty (\(built))"))
        }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target, DescType(typeWildCard), DescType(typeWildCard), false)
        switch status {
        case noErr:
            return .success(())
        case OSStatus(errAEEventNotPermitted), OSStatus(procNotFound):
            // procNotFound here means the target vanished between the two calls.
            return .failure(status == OSStatus(procNotFound) ? .notRunning : .notPermitted)
        case OSStatus(errAEEventWouldRequireUserConsent):
            // Never asked yet. Deliberately reported as "not permitted": the only
            // honest thing to do is have the user grant it at arming time.
            return .failure(.notPermitted)
        default:
            return .failure(.unreadable("permission check returned \(status)"))
        }
    }

    /// Every Ghostty surface, as `id` / `name` / `working directory`.
    ///
    /// Sends `count` and then one `get` per property, which is more events than a
    /// single `get every terminal` would be — but the whole-collection form
    /// returns a nested descriptor whose shape is undocumented, and guessing at
    /// it is how a surface list silently becomes wrong. Nine windows cost a few
    /// milliseconds and this runs once per delivery.
    static func surfaces(pid: pid_t) -> Result<[ContinueDelivery.Surface], Failure> {
        if case .failure(let failure) = automationPermission(pid: pid) { return .failure(failure) }

        let count: Int
        switch send(
            event: AEEventClass(kAECoreSuite), id: AEEventID(kAECountElements),
            to: pid,
            direct: NSAppleEventDescriptor.null(),
            extras: [AEKeyword(keyAEObjectClass): NSAppleEventDescriptor(typeCode: Code.terminal)])
        {
        case .success(let reply):
            count = Int(reply.int32Value)
        case .failure(let failure):
            return .failure(failure)
        }
        guard count > 0 else { return .success([]) }

        var surfaces: [ContinueDelivery.Surface] = []
        for index in 1...count {
            let specifier = objectSpecifier(
                container: nil, form: AEKeyword(formAbsolutePosition),
                key: NSAppleEventDescriptor(int32: Int32(index)))
            guard let id = property(Code.id, of: specifier, in: pid),
                let name = property(Code.name, of: specifier, in: pid)
            else {
                // A surface that closed mid-enumeration is not an error; it is
                // simply not in the list any more.
                continue
            }
            let directory =
                property(Code.workingDirectory, of: specifier, in: pid) ?? ""
            surfaces.append(
                ContinueDelivery.Surface(id: id, title: name, workingDirectory: directory))
        }
        return .success(surfaces)
    }

    // MARK: - Writing

    /// How a command reports that it did the thing.
    ///
    /// Read straight out of `Ghostty.sdef`, because the two write commands do NOT
    /// agree: `perform action` declares `<result type="boolean"` ("True when the
    /// action was performed"), while `send key` declares no result at all. One
    /// shared rule cannot serve both — requiring a result would report every
    /// successful Return as a failure, and accepting a missing one would let an
    /// unconfirmed write be treated as done.
    private enum Acknowledgement {
        /// The reply must carry an explicit `true`. Anything else — false, a
        /// missing result, an unreadable one — is a failure, because the next
        /// step after a successful write is pressing Return.
        case requiresTrue
        /// The command returns nothing, so completing without an error IS the
        /// acknowledgement.
        case completesWithoutError
    }

    /// Ghostty's own event codes for the two write commands, from `Ghostty.sdef`.
    private enum Write {
        /// `perform action` — takes any keybind action string.
        static let performAction: AEEventID = 0x5066_4163  // 'PfAc'
        /// `send key` — takes a key NAME, not a character.
        static let sendKey: AEEventID = 0x534B_6579  // 'SKey'
        /// Ghostty's own event class.
        static let suite: AEEventClass = 0x4768_7374  // 'Ghst'
        /// The `on` / `to` target parameter.
        static let onTerminal: AEKeyword = 0x476F_6E54  // 'GonT'
        static let toTerminal: AEKeyword = 0x474B_6554  // 'GKeT'
    }

    /// Writes text into one surface, without pressing Return.
    ///
    /// `perform action "text:…"` rather than `input text`. `input text` is
    /// documented in Ghostty's own dictionary as behaving "as if it was pasted",
    /// which puts it behind `clipboard-paste-protection` — a confirmation sheet
    /// this app can neither see nor dismiss. The `text:` keybind action sends the
    /// string directly and has no such gate.
    ///
    /// Verified on a real Ghostty: the `on` target IS honoured for a surface that
    /// is not focused, while five sibling windows shared one title. Without that,
    /// this command would itself have been a type-into-the-wrong-window route.
    static func writeText(_ text: String, toSurface surfaceId: String, pid: pid_t) -> Bool {
        // The action string is Ghostty's, not a shell's, and the message has
        // already been reduced to a single line by `ContinueScheduler.sanitize`
        // — which is what keeps a newline from becoming an unrequested Return.
        performAction(
            onSurface: surfaceId, pid: pid, parameter: Write.onTerminal,
            event: Write.performAction, direct: NSAppleEventDescriptor(string: "text:\(text)"),
            acknowledgement: .requiresTrue)
    }

    /// Presses Return in one surface. Structurally separate from `writeText` so
    /// that no code path can submit a message it did not first succeed in typing.
    static func pressReturn(inSurface surfaceId: String, pid: pid_t) -> Bool {
        performAction(
            onSurface: surfaceId, pid: pid, parameter: Write.toTerminal,
            event: Write.sendKey, direct: NSAppleEventDescriptor(string: "enter"),
            acknowledgement: .completesWithoutError)
    }

    private static func performAction(
        onSurface surfaceId: String, pid target: pid_t, parameter: AEKeyword,
        event id: AEEventID, direct: NSAppleEventDescriptor,
        acknowledgement: Acknowledgement
    ) -> Bool {
        guard case .success = automationPermission(pid: target) else { return false }

        var pid = target
        let address =
            NSAppleEventDescriptor(
                descriptorType: DescType(typeKernelProcessID), bytes: &pid,
                length: MemoryLayout<pid_t>.size) ?? NSAppleEventDescriptor.null()
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: Write.suite, eventID: id, targetDescriptor: address,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(direct, forKeyword: AEKeyword(keyDirectObject))
        event.setDescriptor(surfaceSpecifier(id: surfaceId), forKeyword: parameter)

        do {
            let reply = try event.sendEvent(options: .defaultOptions, timeout: 10)
            if let error = reply.forKeyword(AEKeyword(keyErrorNumber)), error.int32Value != 0 {
                return false
            }
            switch acknowledgement {
            case .completesWithoutError:
                return true
            case .requiresTrue:
                // Fail CLOSED. A missing result used to read as success, which
                // meant an unconfirmed write could be followed by pressing
                // Return — and Return submits whatever is on that prompt.
                guard let result = reply.forKeyword(AEKeyword(keyDirectObject)) else {
                    return false
                }
                return result.booleanValue
            }
        } catch {
            return false
        }
    }

    /// A surface addressed by its own id.
    ///
    /// `formUniqueID`, never an index. Verified against a real Ghostty:
    /// `formUniqueID` resolves to the same surface as index 1 did, while
    /// `formName` fails outright with -1728. An index would be wrong regardless —
    /// it shifts the moment any window closes, which between reading the list and
    /// writing to it is a real interval.
    private static func surfaceSpecifier(id surfaceId: String) -> NSAppleEventDescriptor {
        let specifier =
            NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier))
            ?? NSAppleEventDescriptor.record()
        specifier.setDescriptor(
            NSAppleEventDescriptor(typeCode: Code.terminal),
            forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(
            NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        specifier.setDescriptor(
            NSAppleEventDescriptor(enumCode: AEKeyword(formUniqueID)),
            forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(
            NSAppleEventDescriptor(string: surfaceId), forKeyword: AEKeyword(keyAEKeyData))
        return specifier
    }

    // MARK: - Event plumbing

    /// `terminal <index>` / `every terminal`, as an object specifier.
    private static func objectSpecifier(
        container: NSAppleEventDescriptor?, form: AEKeyword, key: NSAppleEventDescriptor?
    ) -> NSAppleEventDescriptor {
        let specifier =
            NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier))
            ?? NSAppleEventDescriptor.record()
        specifier.setDescriptor(
            NSAppleEventDescriptor(typeCode: Code.terminal),
            forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(
            container ?? NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        specifier.setDescriptor(
            NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(
            key ?? NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEKeyData))
        return specifier
    }

    private static func property(
        _ property: AEKeyword, of specifier: NSAppleEventDescriptor, in pid: pid_t
    ) -> String? {
        let propertySpecifier =
            NSAppleEventDescriptor.record()
            .coerce(toDescriptorType: DescType(typeObjectSpecifier))
            ?? NSAppleEventDescriptor.record()
        propertySpecifier.setDescriptor(
            NSAppleEventDescriptor(typeCode: DescType(typeProperty)),
            forKeyword: AEKeyword(keyAEDesiredClass))
        propertySpecifier.setDescriptor(specifier, forKeyword: AEKeyword(keyAEContainer))
        propertySpecifier.setDescriptor(
            NSAppleEventDescriptor(enumCode: AEKeyword(formPropertyID)),
            forKeyword: AEKeyword(keyAEKeyForm))
        propertySpecifier.setDescriptor(
            NSAppleEventDescriptor(typeCode: property), forKeyword: AEKeyword(keyAEKeyData))

        guard
            case .success(let reply) = send(
                event: AEEventClass(kAECoreSuite), id: AEEventID(kAEGetData), to: pid,
                direct: propertySpecifier,
                extras: [:])
        else { return nil }
        return reply.stringValue
    }

    private static func send(
        event suite: AEEventClass, id: AEEventID, to pid: pid_t,
        direct: NSAppleEventDescriptor, extras: [AEKeyword: NSAppleEventDescriptor]
    ) -> Result<NSAppleEventDescriptor, Failure> {
        var target = pid
        let address =
            NSAppleEventDescriptor(
                descriptorType: DescType(typeKernelProcessID), bytes: &target,
                length: MemoryLayout<pid_t>.size)
            ?? NSAppleEventDescriptor.null()
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: suite, eventID: id, targetDescriptor: address,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(direct, forKeyword: AEKeyword(keyDirectObject))
        for (keyword, descriptor) in extras {
            event.setDescriptor(descriptor, forKeyword: keyword)
        }

        do {
            // `.defaultOptions` waits for a reply, which is what makes a refusal
            // observable. The timeout keeps a wedged Ghostty from holding the
            // delivery task open indefinitely.
            let reply = try event.sendEvent(options: .defaultOptions, timeout: 10)
            if let error = reply.forKeyword(keyErrorNumber), error.int32Value != 0 {
                let code = error.int32Value
                if code == errAEEventNotPermitted { return .failure(.notPermitted) }
                let message = reply.forKeyword(keyErrorString)?.stringValue ?? "error \(code)"
                return .failure(.unreadable(message))
            }
            // The payload is the reply's DIRECT OBJECT, not the reply itself.
            // Reading the reply returns zero with no error set — measured against
            // a real Ghostty holding nine windows, which is exactly the kind of
            // silent wrong answer that would have shipped as "you have no
            // terminals" and quietly refused every delivery.
            guard let result = reply.forKeyword(AEKeyword(keyDirectObject)) else {
                return .failure(.unreadable("reply carried no result"))
            }
            return .success(result)
        } catch {
            let nsError = error as NSError
            if nsError.code == Int(errAEEventNotPermitted) { return .failure(.notPermitted) }
            return .failure(.unreadable(nsError.localizedDescription))
        }
    }
}
