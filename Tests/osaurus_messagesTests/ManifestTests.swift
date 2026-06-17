import Foundation
import Testing

@testable import osaurus_messages

@Suite("Plugin Manifest")
struct ManifestTests {

  private enum ManifestError: Error {
    case entryPointFailed
    case nilManifest
    case invalidJSON
  }

  private func loadManifest() throws -> [String: Any] {
    guard let apiPtr = osaurus_plugin_entry() else {
      throw ManifestError.entryPointFailed
    }

    let fnPtrSize = MemoryLayout<UnsafeRawPointer?>.stride
    let initPtr = apiPtr.load(
      fromByteOffset: fnPtrSize,
      as: (@convention(c) () -> UnsafeMutableRawPointer?).self)
    let ctx = initPtr()

    let getManifestPtr = apiPtr.load(
      fromByteOffset: fnPtrSize * 3,
      as: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?).self)
    guard let cStr = getManifestPtr(ctx) else {
      throw ManifestError.nilManifest
    }
    let jsonString = String(cString: cStr)

    let freeStringPtr = apiPtr.load(
      fromByteOffset: 0,
      as: (@convention(c) (UnsafePointer<CChar>?) -> Void).self)
    freeStringPtr(cStr)

    let destroyPtr = apiPtr.load(
      fromByteOffset: fnPtrSize * 2,
      as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
    destroyPtr(ctx)

    guard let data = jsonString.data(using: .utf8),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw ManifestError.invalidJSON
    }
    return manifest
  }

  private func toolMap(from manifest: [String: Any]) -> [String: [String: Any]] {
    let capabilities = manifest["capabilities"] as? [String: Any]
    let tools = capabilities?["tools"] as? [[String: Any]] ?? []
    return Dictionary(
      uniqueKeysWithValues: tools.compactMap { tool -> (String, [String: Any])? in
        guard let id = tool["id"] as? String else { return nil }
        return (id, tool)
      })
  }

  @Test("manifest has correct plugin identity")
  func pluginIdentity() throws {
    let manifest = try loadManifest()
    #expect(manifest["plugin_id"] as? String == "osaurus.messages")
  }

  @Test("manifest declares expected message tools")
  func toolIDs() throws {
    let map = try toolMap(from: loadManifest())
    #expect(Set(map.keys) == ["send_message", "read_messages", "get_unread_messages"])
  }

  @Test("private message tools require user approval")
  func permissionPolicies() throws {
    let map = try toolMap(from: loadManifest())
    #expect(map["send_message"]?["permission_policy"] as? String == "ask")
    #expect(map["read_messages"]?["permission_policy"] as? String == "ask")
    #expect(map["get_unread_messages"]?["permission_policy"] as? String == "ask")
  }

  @Test("tools declare required platform permissions")
  func requirements() throws {
    let map = try toolMap(from: loadManifest())
    #expect(map["send_message"]?["requirements"] as? [String] == ["automation"])
    #expect(map["read_messages"]?["requirements"] as? [String] == ["disk"])
    #expect(map["get_unread_messages"]?["requirements"] as? [String] == ["disk"])
  }

  @Test("tools with inputs declare required parameters")
  func requiredParameters() throws {
    let map = try toolMap(from: loadManifest())

    let sendParams = map["send_message"]?["parameters"] as? [String: Any]
    let sendRequired = Set(sendParams?["required"] as? [String] ?? [])
    #expect(sendRequired == ["phoneNumber", "message"])

    let readParams = map["read_messages"]?["parameters"] as? [String: Any]
    let readRequired = readParams?["required"] as? [String] ?? []
    #expect(readRequired.contains("phoneNumber"))
  }
}
