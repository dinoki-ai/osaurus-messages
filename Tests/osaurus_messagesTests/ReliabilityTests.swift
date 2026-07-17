import SQLite3
import XCTest

@testable import osaurus_messages

final class SubprocessRunnerTests: XCTestCase {

    func testCapturesStdoutAndExitStatus() throws {
        let result = try runSubprocess(
            executable: "/bin/sh", arguments: ["-c", "printf hello"], timeout: 10)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.stdout, "hello")
        XCTAssertFalse(result.timedOut)
    }

    func testLargeOutputDoesNotDeadlock() throws {
        // 4 MB of output — far beyond the ~64 KB kernel pipe buffer.
        let result = try runSubprocess(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=4096 2>/dev/null | tr '\\0' 'x'"],
            timeout: 20)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.stdout.count, 4 * 1024 * 1024)
    }

    func testHungProcessIsKilledAndReportedAsTimedOut() throws {
        let start = Date()
        let result = try runSubprocess(
            executable: "/bin/sh", arguments: ["-c", "sleep 60"], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }

    func testOutputIsCapped() throws {
        let result = try runSubprocess(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=64 2>/dev/null | tr '\\0' 'x'"],
            timeout: 20, outputCap: 1024)
        XCTAssertEqual(result.stdout.count, 1024)
    }
}

final class SendFailureClassificationTests: XCTestCase {

    func testPermissionErrorsAreNeverFallbackEligible() {
        let cases = [
            "Not authorized to send Apple events to Messages. (-1743)",
            "osascript is not allowed assistive access",
            "Operation not permitted: permission denied",
        ]
        for reason in cases {
            XCTAssertTrue(isPermissionError(reason), reason)
            XCTAssertFalse(isIMessageUnavailableError(reason), reason)
        }
    }

    func testIMessageUnavailabilityIsFallbackEligible() {
        let cases = [
            "Messages got an error: Can't get 1st service whose service type = iMessage.",
            "Messages got an error: Can’t get buddy \"+15551234567\" of service 1.",
        ]
        for reason in cases {
            XCTAssertTrue(isIMessageUnavailableError(reason), reason)
        }
    }

    func testGenericSendFailuresAreNotFallbackEligible() {
        // Random execution errors must be reported as-is, not masked by an
        // SMS fallback attempt.
        let cases = [
            "Messages got an error: AppleEvent handler failed.",
            "Network connection lost while sending.",
        ]
        for reason in cases {
            XCTAssertFalse(isIMessageUnavailableError(reason), reason)
            XCTAssertFalse(isPermissionError(reason), reason)
        }
    }
}

final class SQLiteIterationTests: XCTestCase {

    /// Create a scratch database with a `rows` table holding integers 1...5.
    private func makeTempDB() throws -> String {
        let path = NSTemporaryDirectory() + "osaurus-messages-test-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let rc = sqlite3_exec(
            db, "CREATE TABLE rows(n INTEGER); INSERT INTO rows VALUES (1),(2),(3),(4),(5);",
            nil, nil, nil)
        XCTAssertEqual(rc, SQLITE_OK)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testSuccessfulIterationReadsAllRows() throws {
        let path = try makeTempDB()
        let query = """
            SELECT 'msg' || n, 'date-' || n, ?, n % 2, 0, NULL, NULL
            FROM rows ORDER BY n
            """
        switch queryMessages(query: query, params: ["sender-x"], dbPath: path) {
        case .success(let messages):
            XCTAssertEqual(messages.count, 5)
            XCTAssertEqual(messages[0].content, "msg1")
            XCTAssertEqual(messages[0].sender, "sender-x")
            XCTAssertEqual(messages[0].isFromMe, true)
            XCTAssertEqual(messages[1].isFromMe, false)
        case .failure(let error):
            XCTFail("expected success, got \(error.message)")
        }
    }

    func testMidIterationStepFailureIsReportedNotSilentlyTruncated() throws {
        let path = try makeTempDB()
        // Rows 1-2 read fine; row 3 raises a runtime error via json_extract on
        // malformed JSON. The old loop returned .success with 2 rows.
        let query = """
            SELECT CASE WHEN n < 3 THEN 'msg' || n ELSE json_extract('{bad', '$.a') END,
                   'date', 'sender', 0, 0, NULL, NULL
            FROM rows ORDER BY n
            """
        switch queryMessages(query: query, dbPath: path) {
        case .success(let messages):
            XCTFail("expected failure, got silently truncated success with \(messages.count) rows")
        case .failure(let error):
            XCTAssertTrue(
                error.message.contains("did not complete"), "unexpected message: \(error.message)")
        }
    }

    func testUnreadableDatabaseFailsCleanly() {
        let result = queryMessages(
            query: "SELECT 1,2,3,4,5,6,7", dbPath: "/nonexistent/dir/chat.db")
        guard case .failure = result else {
            return XCTFail("expected failure for unreadable database path")
        }
    }
}

final class EntryPointEnvelopeTests: XCTestCase {

    /// Invoke the plugin through its public C ABI entry point.
    private func invoke(type: String, id: String, payload: String) throws -> [String: Any] {
        let apiPtr = try XCTUnwrap(osaurus_plugin_entry())
        let fnPtrSize = MemoryLayout<UnsafeRawPointer?>.stride

        let initPtr = apiPtr.load(
            fromByteOffset: fnPtrSize * 1, as: (@convention(c) () -> UnsafeMutableRawPointer?).self)
        let ctx = initPtr()

        let invokePtr = apiPtr.load(
            fromByteOffset: fnPtrSize * 4,
            as: (@convention(c) (
                UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
                UnsafePointer<CChar>?
            ) -> UnsafePointer<CChar>?).self)

        let raw = type.withCString { t in
            id.withCString { i in
                payload.withCString { p in invokePtr(ctx, t, i, p) }
            }
        }
        let cStr = try XCTUnwrap(raw)
        let jsonStr = String(cString: cStr)

        let freePtr = apiPtr.load(
            fromByteOffset: fnPtrSize * 0, as: (@convention(c) (UnsafePointer<CChar>?) -> Void).self)
        freePtr(cStr)
        let destroyPtr = apiPtr.load(
            fromByteOffset: fnPtrSize * 2,
            as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
        destroyPtr(ctx)

        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any])
    }

    func testUnknownCapabilityTypeReturnsCanonicalEnvelope() throws {
        let obj = try invoke(type: "resource", id: "anything", payload: "{}")
        XCTAssertEqual(obj["ok"] as? Bool, false)
        XCTAssertEqual(obj["kind"] as? String, "invalid_args")
        XCTAssertEqual(obj["retryable"] as? Bool, false)
        XCTAssertNil(obj["error"], "must not use the legacy ad-hoc {\"error\": ...} shape")
    }

    func testUnknownToolReturnsCanonicalEnvelope() throws {
        let obj = try invoke(type: "tool", id: "does_not_exist", payload: "{}")
        XCTAssertEqual(obj["ok"] as? Bool, false)
        XCTAssertEqual(obj["kind"] as? String, "not_found")
        XCTAssertEqual(obj["retryable"] as? Bool, false)
        XCTAssertNil(obj["error"], "must not use the legacy ad-hoc {\"error\": ...} shape")
    }
}
