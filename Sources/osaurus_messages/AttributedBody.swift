import Foundation

/// Best-effort decoder for the `attributedBody` column of the Messages
/// database (`chat.db`).
///
/// Modern macOS frequently stores a message's text only in `attributedBody`
/// (a legacy `NSArchiver` "streamtyped" blob) rather than the plain `text`
/// column — especially for messages containing links, mentions, or sent from
/// newer clients. Previously this plugin returned the placeholder
/// `"[Rich text message]"` for all such messages, hiding the actual content.
///
/// The text inside a streamtyped attributed string is stored as an `NSString`
/// instance. Its bytes follow the class name marker `NSString`, a short fixed
/// header, and a length-prefixed UTF-8 payload. The length is encoded either as
/// a single byte (< 0x80) or, when 0x81 is seen, as the next two little-endian
/// bytes. This mirrors the approach used by widely-deployed readers such as
/// imessage-exporter and imessage_reader.
enum AttributedBody {
    /// Extract the plain-text content of a streamtyped `attributedBody` blob.
    /// Returns `nil` when the blob does not contain a recognizable string.
    static func extractText(from data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard let markerStart = firstRange(of: marker, in: bytes) else { return nil }

        // After the class name there is a small, fixed control header
        // (`\x01\x94\x84\x01+`) before the length byte(s). Skip it defensively:
        // walk forward to the length prefix rather than assuming an exact
        // offset, so minor format variations don't break extraction.
        var idx = markerStart + marker.count
        // Skip the control bytes up to and including the `+` (0x2B) separator
        // that precedes the length prefix in the common layout.
        if let plus = indexOf(0x2B, in: bytes, from: idx, maxScan: 8) {
            idx = plus + 1
        } else {
            // Fallback to the canonical 5-byte header skip.
            idx += 5
        }
        guard idx < bytes.count else { return nil }

        let length: Int
        if bytes[idx] == 0x81 {
            guard idx + 2 < bytes.count else { return nil }
            length = Int(bytes[idx + 1]) | (Int(bytes[idx + 2]) << 8)
            idx += 3
        } else if bytes[idx] == 0x82 {
            guard idx + 3 < bytes.count else { return nil }
            length =
                Int(bytes[idx + 1]) | (Int(bytes[idx + 2]) << 8) | (Int(bytes[idx + 3]) << 16)
            idx += 4
        } else {
            length = Int(bytes[idx])
            idx += 1
        }

        guard length > 0, idx + length <= bytes.count else { return nil }
        let slice = Data(bytes[idx ..< idx + length])
        return String(data: slice, encoding: .utf8)
    }

    private static func indexOf(
        _ byte: UInt8, in haystack: [UInt8], from: Int, maxScan: Int
    ) -> Int? {
        var i = from
        let end = min(haystack.count, from + maxScan)
        while i < end {
            if haystack[i] == byte { return i }
            i += 1
        }
        return nil
    }

    private static func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        var i = 0
        while i <= last {
            var match = true
            var j = 0
            while j < needle.count {
                if haystack[i + j] != needle[j] {
                    match = false
                    break
                }
                j += 1
            }
            if match { return i }
            i += 1
        }
        return nil
    }
}
