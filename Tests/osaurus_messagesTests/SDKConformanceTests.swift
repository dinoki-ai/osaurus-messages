import OsaurusPluginKit
import OsaurusPluginTestSupport
import XCTest

@testable import osaurus_messages

final class SDKConformanceTests: XCTestCase {

    func testManifestPassesSDKRegistryConformance() throws {
        try ManifestConformance.assertConformant(messagesManifestJSON)
    }

    func testV2EntryPointReturnsConformantPluginAPI() throws {
        try ABIConformance.assertEntryConformance(
            osaurus_plugin_entry_v2(nil), manifestJSON: messagesManifestJSON)
    }

    func testV1EntryPointReturnsConformantPluginAPI() throws {
        try ABIConformance.assertEntryConformance(
            osaurus_plugin_entry(), manifestJSON: messagesManifestJSON)
    }

    func testInvalidArgsFailureIsCanonical() throws {
        try assertCanonicalFailure(
            Envelope.failure(.invalidArgs, "Could not parse arguments."), kind: .invalidArgs)
        try assertCanonicalFailure(
            Envelope.failure(.notFound, "Unknown tool: nope"), kind: .notFound)
    }
}
