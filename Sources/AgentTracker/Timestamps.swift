import Foundation

/// Reading the timestamps agent tooling writes.
///
/// Two spellings, because the tools are not consistent about fractional
/// seconds and `ISO8601DateFormatter` will not accept both from one instance —
/// it returns nil for a string that does not match its options exactly. Trying
/// the fractional form first and the plain one after is the whole trick.
enum Timestamps {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()

    static func iso8601(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}
