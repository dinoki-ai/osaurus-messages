import XCTest

@testable import osaurus_messages

final class MessagesTests: XCTestCase {

    // MARK: - Manifest

    /// Mirror of the host's `PluginManifest.ToolSpec` requirement: every tool
    /// MUST declare a string `id` and `description`. If `id` is missing the
    /// host fails to decode the manifest and the entire plugin won't load.
    func testManifestIsValidAndToolsHaveIds() throws {
        let data = Data(messagesManifestJSON.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let root = try XCTUnwrap(obj)
        XCTAssertEqual(root["plugin_id"] as? String, "osaurus.messages")
        XCTAssertEqual(root["name"] as? String, "Messages")

        let caps = try XCTUnwrap(root["capabilities"] as? [String: Any])
        let tools = try XCTUnwrap(caps["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 3)
        for tool in tools {
            let id = try XCTUnwrap(tool["id"] as? String, "tool missing required 'id'")
            XCTAssertFalse(id.isEmpty)
            let desc = try XCTUnwrap(tool["description"] as? String, "tool \(id) missing 'description'")
            XCTAssertFalse(desc.isEmpty)
        }
        let ids = Set(tools.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["send_message", "read_messages", "get_unread_messages"])
    }

    // MARK: - Envelope

    func testFailureEnvelopeIsCanonical() throws {
        let json = Envelope.failure(.invalidArgs, "bad input")
        let dict = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(dict["ok"] as? Bool, false)
        XCTAssertEqual(dict["kind"] as? String, "invalid_args")
        XCTAssertEqual(dict["message"] as? String, "bad input")
        XCTAssertEqual(dict["retryable"] as? Bool, true)
        // Host detection sniffs for a leading "ok":false marker.
        XCTAssertTrue(json.hasPrefix("{\"ok\":false"))
    }

    func testFailureEnvelopeRetryableDefaults() {
        XCTAssertTrue(Envelope.failure(.unavailable, "x").contains("\"retryable\":true"))
        XCTAssertTrue(Envelope.failure(.notFound, "x").contains("\"retryable\":false"))
        XCTAssertTrue(Envelope.failure(.executionError, "x", retryable: false).contains("\"retryable\":false"))
    }

    func testFailureEnvelopeEscapesMessage() throws {
        let json = Envelope.failure(.executionError, "line1\nline2 \"quoted\" \\path")
        // Must still parse as valid JSON after escaping.
        let dict = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(dict["message"] as? String, "line1\nline2 \"quoted\" \\path")
    }

    // MARK: - Phone normalization

    func testNormalizePhoneNumber() {
        XCTAssertEqual(normalizePhoneNumber("(555) 123-4567"), ["+15551234567"])
        XCTAssertEqual(normalizePhoneNumber("15551234567"), ["+15551234567"])
        XCTAssertEqual(normalizePhoneNumber("+15551234567"), ["+15551234567"])
        XCTAssertEqual(normalizePhoneNumber("+44 20 7946 0958"), ["+442079460958"])
    }

    // MARK: - attributedBody decoding

    /// Build a minimal streamtyped-style blob: `...NSString` + control header
    /// ending in `+` (0x2B) + single-byte length + UTF-8 payload. The decoder
    /// must recover the embedded text.
    func testAttributedBodyShortLength() throws {
        let text = "Hello, world!"
        var blob = Data("streamtyped".utf8)
        blob.append(Data("NSString".utf8))
        blob.append(contentsOf: [0x01, 0x94, 0x84, 0x01, 0x2B])  // header + '+'
        blob.append(UInt8(text.utf8.count))  // single-byte length (< 0x80)
        blob.append(Data(text.utf8))
        XCTAssertEqual(AttributedBody.extractText(from: blob), text)
    }

    /// Length >= 0x80 uses the 0x81 + little-endian 16-bit form.
    func testAttributedBodyLongLength() throws {
        let text = String(repeating: "a", count: 200)
        var blob = Data("NSString".utf8)
        blob.append(contentsOf: [0x01, 0x94, 0x84, 0x01, 0x2B])
        let len = text.utf8.count
        blob.append(contentsOf: [0x81, UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF)])
        blob.append(Data(text.utf8))
        XCTAssertEqual(AttributedBody.extractText(from: blob), text)
    }

    func testAttributedBodyReturnsNilForGarbage() {
        XCTAssertNil(AttributedBody.extractText(from: Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertNil(AttributedBody.extractText(from: Data()))
    }
}
