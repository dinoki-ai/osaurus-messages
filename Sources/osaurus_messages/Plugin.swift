import Cocoa
import Foundation
import SQLite3

// MARK: - AppleScript Helper

private enum AppleScriptError: Error {
  case executionFailed(String)
  case noResult
}

private func runAppleScript(_ script: String) -> Result<String, Error> {
  var error: NSDictionary?
  let appleScript = NSAppleScript(source: script)

  guard let result = appleScript?.executeAndReturnError(&error) else {
    if let error = error {
      let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
      return .failure(AppleScriptError.executionFailed(message))
    }
    return .failure(AppleScriptError.noResult)
  }

  return .success(result.stringValue ?? "")
}

// MARK: - Message Model

private struct Message: Codable {
  let content: String
  let date: String
  let sender: String
  let isFromMe: Bool
  let attachments: [String]?
}

// MARK: - Phone Number Normalization

private func normalizePhoneNumber(_ phone: String) -> [String] {
  // Remove all non-numeric characters except +
  let cleaned = phone.filter { $0.isNumber || $0 == "+" }

  // If it already has a country code (starts with +), use as-is
  if cleaned.hasPrefix("+") && cleaned.count >= 10 {
    return [cleaned]
  }

  // If it starts with 1 and has 11 digits total, assume US number
  if cleaned.hasPrefix("1") && cleaned.count == 11 {
    return ["+\(cleaned)"]
  }

  // If it's 10 digits, assume US number and add +1
  if cleaned.count == 10 {
    return ["+1\(cleaned)"]
  }

  // For other formats, return as-is with + prefix if missing
  if !cleaned.hasPrefix("+") {
    return ["+\(cleaned)"]
  }

  return [cleaned]
}

// MARK: - Database Path

private func getMessagesDBPath() -> String {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  return "\(home)/Library/Messages/chat.db"
}

// MARK: - SQLite Query Helper

private struct DatabaseError: Error {
  let message: String
}

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func queryMessages(query: String, params: [String] = []) -> Result<[Message], DatabaseError>
{
  let dbPath = getMessagesDBPath()
  var db: OpaquePointer?

  let openResult = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)

  guard openResult == SQLITE_OK, let db = db else {
    let err = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
    sqlite3_close(db)
    if err.contains("unable to open") || err.contains("permission denied") {
      return .failure(
        DatabaseError(
          message:
            "Cannot access Messages database. Please grant Full Disk Access to the application in System Settings > Privacy & Security > Full Disk Access."
        ))
    }
    return .failure(DatabaseError(message: "Database error: \(err)"))
  }
  defer { sqlite3_close(db) }

  var stmt: OpaquePointer?
  guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
    let err = String(cString: sqlite3_errmsg(db))
    return .failure(DatabaseError(message: "Query error: \(err)"))
  }
  defer { sqlite3_finalize(stmt) }

  // Bind string parameters
  for (i, param) in params.enumerated() {
    sqlite3_bind_text(stmt, Int32(i + 1), param, -1, SQLITE_TRANSIENT_PTR)
  }

  var messages: [Message] = []
  while sqlite3_step(stmt) == SQLITE_ROW {
    // Read each column, handling NULLs per-row so one bad row doesn't destroy all results
    let content = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "[No content]"
    let date = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "Unknown"
    let sender = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "Unknown"
    let isFromMe = sqlite3_column_int(stmt, 3) == 1
    let hasAttachments = sqlite3_column_int(stmt, 4) == 1
    let attachmentInfo = sqlite3_column_text(stmt, 5).map { String(cString: $0) }

    var attachments: [String]? = nil
    if hasAttachments {
      if let info = attachmentInfo, !info.isEmpty {
        attachments = info.components(separatedBy: ",")
      } else {
        attachments = ["[Attachment]"]
      }
    }

    messages.append(
      Message(
        content: content,
        date: date,
        sender: sender,
        isFromMe: isFromMe,
        attachments: attachments
      ))
  }

  return .success(messages)
}

// MARK: - Send Message Tool

private struct SendMessageTool {
  let name = "send_message"

  struct Args: Decodable {
    let phoneNumber: String
    let message: String
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return "{\"error\": \"Invalid arguments\"}"
    }

    let phoneNumbers = normalizePhoneNumber(input.phoneNumber)
    guard let phoneNumber = phoneNumbers.first else {
      return "{\"success\": false, \"message\": \"Invalid phone number format\"}"
    }

    let escapedMessage = escapeAppleScript(input.message)

    let script = """
      tell application "Messages"
          set targetService to 1st service whose service type = iMessage
          set targetBuddy to buddy "\(phoneNumber)" of targetService
          send "\(escapedMessage)" to targetBuddy
      end tell
      """

    let result = runAppleScript(script)

    switch result {
    case .success:
      return "{\"success\": true, \"message\": \"Message sent to \(escapeJSON(phoneNumber))\"}"
    case .failure(let error):
      return "{\"success\": false, \"message\": \"\(escapeJSON(error.localizedDescription))\"}"
    }
  }
}

// MARK: - Read Messages Tool

private struct ReadMessagesTool {
  let name = "read_messages"

  struct Args: Decodable {
    let phoneNumber: String
    let limit: Int?
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return "{\"error\": \"Invalid arguments\"}"
    }

    let limit = min(input.limit ?? 10, 50)
    let phoneNumbers = normalizePhoneNumber(input.phoneNumber)

    guard let phoneNumber = phoneNumbers.first else {
      return "{\"error\": \"Invalid phone number format\"}"
    }

    let query = """
      SELECT
          CASE
              WHEN m.text IS NOT NULL AND m.text != '' THEN m.text
              WHEN m.attributedBody IS NOT NULL THEN '[Rich text message]'
              ELSE '[Attachment]'
          END as content,
          datetime(m.date/1000000000 + strftime('%s', '2001-01-01'), 'unixepoch', 'localtime') as date,
          COALESCE(h.id, 'Me') as sender,
          m.is_from_me,
          m.cache_has_attachments,
          GROUP_CONCAT(DISTINCT a.transfer_name) as attachment_names
      FROM message m
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      LEFT JOIN message_attachment_join maj ON maj.message_id = m.ROWID
      LEFT JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE h.id = ?
          AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL OR m.cache_has_attachments = 1)
          AND m.item_type = 0
      GROUP BY m.ROWID
      ORDER BY m.date DESC
      LIMIT \(limit)
      """

    let result = queryMessages(query: query, params: [phoneNumber])

    switch result {
    case .success(let messages):
      return encodeJSON(messages)
    case .failure(let error):
      return "{\"error\": \"\(escapeJSON(error.message))\"}"
    }
  }
}

// MARK: - Get Unread Messages Tool

private struct GetUnreadMessagesTool {
  let name = "get_unread_messages"

  struct Args: Decodable {
    let limit: Int?
  }

  func run(args: String) -> String {
    let limit: Int
    if let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    {
      limit = min(input.limit ?? 10, 50)
    } else {
      limit = 10
    }

    let query = """
      SELECT
          CASE
              WHEN m.text IS NOT NULL AND m.text != '' THEN m.text
              WHEN m.attributedBody IS NOT NULL THEN '[Rich text message]'
              ELSE '[Attachment]'
          END as content,
          datetime(m.date/1000000000 + strftime('%s', '2001-01-01'), 'unixepoch', 'localtime') as date,
          COALESCE(h.id, 'Unknown') as sender,
          m.is_from_me,
          m.cache_has_attachments,
          GROUP_CONCAT(DISTINCT a.transfer_name) as attachment_names
      FROM message m
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      LEFT JOIN message_attachment_join maj ON maj.message_id = m.ROWID
      LEFT JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE m.is_from_me = 0
          AND m.is_read = 0
          AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL OR m.cache_has_attachments = 1)
          AND m.item_type = 0
      GROUP BY m.ROWID
      ORDER BY m.date DESC
      LIMIT \(limit)
      """

    let result = queryMessages(query: query)

    switch result {
    case .success(let messages):
      return encodeJSON(messages)
    case .failure(let error):
      return "{\"error\": \"\(escapeJSON(error.message))\"}"
    }
  }
}

// MARK: - Helper Functions

private func escapeAppleScript(_ str: String) -> String {
  return
    str
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
}

private func escapeJSON(_ str: String) -> String {
  return
    str
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    .replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\r", with: "\\r")
    .replacingOccurrences(of: "\t", with: "\\t")
}

private func encodeJSON<T: Encodable>(_ value: T) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .prettyPrinted
  guard let data = try? encoder.encode(value),
    let json = String(data: data, encoding: .utf8)
  else {
    return "[]"
  }
  return json
}

// MARK: - C ABI surface

// Opaque context
private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

// Function pointers
private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
private typealias osr_invoke_t =
  @convention(c) (
    osr_plugin_ctx_t?,
    UnsafePointer<CChar>?,  // type
    UnsafePointer<CChar>?,  // id
    UnsafePointer<CChar>?  // payload
  ) -> UnsafePointer<CChar>?

private struct osr_plugin_api {
  var free_string: osr_free_string_t?
  var `init`: osr_init_t?
  var destroy: osr_destroy_t?
  var get_manifest: osr_get_manifest_t?
  var invoke: osr_invoke_t?
}

// Context state (simple wrapper class to hold state)
private class PluginContext {
  let sendMessageTool = SendMessageTool()
  let readMessagesTool = ReadMessagesTool()
  let getUnreadMessagesTool = GetUnreadMessagesTool()
}

// Helper to return C strings
private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
  guard let ptr = strdup(s) else { return nil }
  return UnsafePointer(ptr)
}

// API Implementation
private var api: osr_plugin_api = {
  var api = osr_plugin_api()

  api.free_string = { ptr in
    if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
  }

  api.`init` = {
    let ctx = PluginContext()
    return Unmanaged.passRetained(ctx).toOpaque()
  }

  api.destroy = { ctxPtr in
    guard let ctxPtr = ctxPtr else { return }
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  }

  api.get_manifest = { ctxPtr in
    // Manifest JSON matching new spec
    let manifest = """
      {
        "plugin_id": "osaurus.messages",
        "name": "Messages",
        "description": "A messages plugin for macOS Messages.app integration - send and read iMessages",
        "license": "MIT",
        "authors": ["Dinoki Labs"],
        "min_macos": "13.0",
        "min_osaurus": "0.5.0",
        "capabilities": {
          "tools": [
            {
              "id": "send_message",
              "description": "Send an iMessage to a phone number",
              "parameters": {
                "type": "object",
                "properties": {
                  "phoneNumber": {
                    "type": "string",
                    "description": "The recipient's phone number (e.g., +1234567890 or 1234567890)"
                  },
                  "message": {
                    "type": "string",
                    "description": "The message content to send"
                  }
                },
                "required": ["phoneNumber", "message"]
              },
              "requirements": ["automation"],
              "permission_policy": "ask"
            },
            {
              "id": "read_messages",
              "widget": true,
              "description": "Read message history from a specific contact",
              "parameters": {
                "type": "object",
                "properties": {
                  "phoneNumber": {
                    "type": "string",
                    "description": "The contact's phone number to read messages from"
                  },
                  "limit": {
                    "type": "integer",
                    "description": "Maximum number of messages to return (default: 10, max: 50)"
                  }
                },
                "required": ["phoneNumber"]
              },
              "requirements": ["disk"],
              "permission_policy": "ask"
            },
            {
              "id": "get_unread_messages",
              "widget": true,
              "description": "Get all unread messages from all contacts",
              "parameters": {
                "type": "object",
                "properties": {
                  "limit": {
                    "type": "integer",
                    "description": "Maximum number of messages to return (default: 10, max: 50)"
                  }
                },
                "required": []
              },
              "requirements": ["disk"],
              "permission_policy": "ask"
            }
          ]
        }
      }
      """
    return makeCString(manifest)
  }

  api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
    guard let ctxPtr = ctxPtr,
      let typePtr = typePtr,
      let idPtr = idPtr,
      let payloadPtr = payloadPtr
    else { return nil }

    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let type = String(cString: typePtr)
    let id = String(cString: idPtr)
    let payload = String(cString: payloadPtr)

    guard type == "tool" else {
      return makeCString("{\"error\": \"Unknown capability type\"}")
    }

    switch id {
    case ctx.sendMessageTool.name:
      return makeCString(ctx.sendMessageTool.run(args: payload))
    case ctx.readMessagesTool.name:
      return makeCString(ctx.readMessagesTool.run(args: payload))
    case ctx.getUnreadMessagesTool.name:
      return makeCString(ctx.getUnreadMessagesTool.run(args: payload))
    default:
      return makeCString("{\"error\": \"Unknown tool: \(id)\"}")
    }
  }

  return api
}()

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return UnsafeRawPointer(&api)
}
