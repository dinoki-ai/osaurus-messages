import Foundation

/// Canonical tool-result envelope expected by the Osaurus host.
///
/// The host (`ToolEnvelope` in osaurus) classifies a tool result as a failure
/// only when it is shaped like `{"ok": false, "kind": ..., "retryable": ...}`
/// (or the legacy `{"error": ..., "retryable": ...}` form). Any other JSON —
/// including a bare `{"error": "..."}` — is auto-wrapped by the host as a
/// SUCCESS envelope, which means the model never learns the tool failed.
///
/// Every failure path in this plugin must therefore return
/// `Envelope.failure(...)`. Success payloads may be returned as-is (the host
/// wraps them into `{"ok": true, "result": ...}`), but `Envelope.success(...)`
/// is provided for explicitness.
enum Envelope {
    /// Failure classification understood by the host's agent loop.
    enum Kind: String {
        case invalidArgs = "invalid_args"
        case executionError = "execution_error"
        case notFound = "not_found"
        case unavailable = "unavailable"
        case timeout = "timeout"
    }

    /// Build a canonical failure envelope JSON string.
    static func failure(
        _ kind: Kind,
        _ message: String,
        retryable: Bool? = nil
    ) -> String {
        let retry = retryable ?? defaultRetryable(for: kind)
        return "{\"ok\":false,\"kind\":\"\(kind.rawValue)\",\"message\":\"\(escape(message))\",\"retryable\":\(retry)}"
    }

    /// Build a canonical success envelope wrapping a pre-encoded JSON payload.
    static func successRaw(_ jsonPayload: String) -> String {
        return "{\"ok\":true,\"result\":\(jsonPayload)}"
    }

    private static func defaultRetryable(for kind: Kind) -> Bool {
        switch kind {
        case .executionError, .unavailable, .timeout: return true
        // invalid_args and not_found are deterministic — retrying cannot succeed
        case .invalidArgs, .notFound: return false
        }
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 2)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if let a = ch.asciiValue, a < 0x20 {
                    out += String(format: "\\u%04x", a)
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }
}
