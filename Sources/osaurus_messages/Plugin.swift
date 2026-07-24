import Foundation
import OsaurusPluginABI
import OsaurusPluginKit
import SQLite3

// MARK: - AppleScript Helper

enum AppleScriptError: Error {
  case executionFailed(String)
  case timedOut

  var reason: String {
    switch self {
    case .executionFailed(let message): return message
    case .timedOut: return "AppleScript timed out"
    }
  }
}

/// How long an osascript invocation may run before it is killed.
private let appleScriptTimeoutSeconds: TimeInterval = 30

/// Run an AppleScript via the SDK's `ProcessRunner` (`/usr/bin/osascript`).
/// Execution is bounded by `appleScriptTimeoutSeconds` — the previous
/// synchronous `NSAppleScript` execution could hang the caller forever if
/// Messages.app never responded.
private func runAppleScript(_ script: String) -> Result<String, AppleScriptError> {
  let result: ProcessRunner.Output
  do {
    result = try ProcessRunner.run(
      executable: "/usr/bin/osascript", arguments: ["-e", script],
      timeout: appleScriptTimeoutSeconds)
  } catch {
    return .failure(.executionFailed("Failed to launch osascript: \(error.localizedDescription)"))
  }

  if result.timedOut {
    return .failure(.timedOut)
  }

  if result.exitStatus != 0 {
    let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
    return .failure(.executionFailed(stderr.isEmpty ? "Unknown AppleScript error" : stderr))
  }

  return .success(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - Message Model

struct Message: Codable {
  let content: String
  let date: String
  let sender: String
  let isFromMe: Bool
  let attachments: [String]?
}

// MARK: - Phone Number Normalization

/// Normalize a phone number for Messages.app.
///
/// Numbers with an explicit country code (leading `+`, or the US `1` prefix on
/// an 11-digit number) are used as-is. A bare number is assumed to be a US
/// number and prefixed with `+1` ONLY when it is exactly 10 digits with no
/// country-code indicator — this US default is deliberate (matching the
/// plugin's historic behavior) and is not a general locale facility; users
/// outside the US should pass full international numbers with `+`.
func normalizePhoneNumber(_ phone: String) -> [String] {
  // Remove all non-numeric characters except +
  let cleaned = phone.filter { $0.isNumber || $0 == "+" }

  // If it already has a country code (starts with +), use as-is
  if cleaned.hasPrefix("+") && cleaned.count >= 10 {
    return [cleaned]
  }

  // If it starts with 1 and has 11 digits total, assume US number with its
  // country code already present
  if cleaned.hasPrefix("1") && cleaned.count == 11 && cleaned.allSatisfy({ $0.isNumber }) {
    return ["+\(cleaned)"]
  }

  // Exactly 10 digits and no country-code indicator anywhere: assume US
  if cleaned.count == 10 && cleaned.allSatisfy({ $0.isNumber }) {
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

struct DatabaseError: Error {
  let message: String
}

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func queryMessages(query: String, params: [String] = [], dbPath: String? = nil)
  -> Result<[Message], DatabaseError>
{
  let dbPath = dbPath ?? getMessagesDBPath()
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
  var stepResult = sqlite3_step(stmt)
  while stepResult == SQLITE_ROW {
    // Read each column, handling NULLs per-row so one bad row doesn't destroy all results
    let plainText = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    let date = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "Unknown"
    let sender = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "Unknown"
    let isFromMe = sqlite3_column_int(stmt, 3) == 1
    let hasAttachments = sqlite3_column_int(stmt, 4) == 1
    let attachmentInfo = sqlite3_column_text(stmt, 5).map { String(cString: $0) }

    // Decode the message body: prefer the plain `text` column, then fall back
    // to decoding the `attributedBody` blob (col 6), and only then to a
    // placeholder. Previously rich-formatted messages always returned
    // "[Rich text message]" even though their text was recoverable.
    var content: String
    if let plainText, !plainText.isEmpty {
      content = plainText
    } else if let blobPtr = sqlite3_column_blob(stmt, 6) {
      let blobLen = Int(sqlite3_column_bytes(stmt, 6))
      let blob = Data(bytes: blobPtr, count: blobLen)
      content = AttributedBody.extractText(from: blob) ?? (hasAttachments ? "[Attachment]" : "[No content]")
    } else {
      content = hasAttachments ? "[Attachment]" : "[No content]"
    }

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

    stepResult = sqlite3_step(stmt)
  }

  // A row loop that ends on anything other than SQLITE_DONE means iteration
  // failed partway (I/O error, corruption, busy database). Report it instead
  // of returning a silently truncated result set.
  guard stepResult == SQLITE_DONE else {
    let err = String(cString: sqlite3_errmsg(db))
    return .failure(
      DatabaseError(
        message:
          "Query did not complete (SQLite code \(stepResult): \(err)). Read \(messages.count) row(s) before the error; results would be incomplete."
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
      return Envelope.failure(.invalidArgs, "Could not parse arguments. Expected JSON with 'phoneNumber' and 'message'.")
    }

    let trimmedMessage = input.message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMessage.isEmpty else {
      return Envelope.failure(.invalidArgs, "'message' must not be empty.")
    }

    let phoneNumbers = normalizePhoneNumber(input.phoneNumber)
    guard let phoneNumber = phoneNumbers.first, !phoneNumber.isEmpty else {
      return Envelope.failure(.invalidArgs, "Invalid phone number format: \(input.phoneNumber)")
    }

    let escapedMessage = escapeAppleScript(input.message)

    // Try iMessage first. Only fall back to SMS (requires Text Message
    // Forwarding) when the failure indicates iMessage itself is unavailable
    // for this account/recipient. Falling back on EVERY failure masked the
    // original error (e.g. permission denials surfaced as SMS errors).
    let iMessageResult = runAppleScript(
      sendScript(service: "iMessage", phone: phoneNumber, message: escapedMessage))

    let iMessageError: AppleScriptError
    switch iMessageResult {
    case .success:
      return "{\"success\": true, \"service\": \"iMessage\", \"message\": \"Message sent to \(escapeJSON(phoneNumber))\"}"
    case .failure(let error):
      iMessageError = error
    }

    if case .timedOut = iMessageError {
      return Envelope.failure(
        .timeout,
        "Sending via iMessage timed out. Messages may be busy or waiting for user input — try again.")
    }

    let reason = iMessageError.reason
    if isPermissionError(reason) {
      return Envelope.failure(
        .unavailable,
        "Could not send message: \(reason). Ensure Messages.app is running and Osaurus has Automation permission for Messages.",
        retryable: false)
    }

    guard isIMessageUnavailableError(reason) else {
      // Preserve and report the original iMessage failure instead of masking
      // it behind an unrelated SMS error.
      return Envelope.failure(
        .executionError, "Failed to send message to \(phoneNumber) via iMessage: \(reason)")
    }

    let smsResult = runAppleScript(
      sendScript(service: "SMS", phone: phoneNumber, message: escapedMessage))
    switch smsResult {
    case .success:
      return "{\"success\": true, \"service\": \"SMS\", \"message\": \"Message sent to \(escapeJSON(phoneNumber)) via SMS (iMessage unavailable: \(escapeJSON(reason)))\"}"
    case .failure(.timedOut):
      return Envelope.failure(
        .timeout,
        "iMessage was unavailable (\(reason)) and the SMS fallback timed out. Try again.")
    case .failure(let smsError):
      return Envelope.failure(
        .executionError,
        "Failed to send message to \(phoneNumber). iMessage unavailable: \(reason). SMS fallback also failed: \(smsError.reason)"
      )
    }
  }

  private func sendScript(service: String, phone: String, message: String) -> String {
    return """
      tell application "Messages"
          set targetService to 1st service whose service type = \(service)
          set targetBuddy to buddy "\(phone)" of targetService
          send "\(message)" to targetBuddy
      end tell
      """
  }
}

/// Whether an AppleScript send failure is a permission/automation problem the
/// user must resolve (never worth an SMS fallback or retry with same setup).
func isPermissionError(_ reason: String) -> Bool {
  return reason.localizedCaseInsensitiveContains("not allowed")
    || reason.localizedCaseInsensitiveContains("not authorized")
    || reason.localizedCaseInsensitiveContains("permission")
    || reason.localizedCaseInsensitiveContains("-1743")
    || reason.localizedCaseInsensitiveContains("Application isn’t running")
    || reason.localizedCaseInsensitiveContains("Application isn't running")
}

/// Whether a send failure indicates iMessage itself is unavailable for this
/// account or recipient — the only category where an SMS fallback makes sense.
/// Typical shapes: no iMessage service registered ("Can't get 1st service
/// whose service type = iMessage") or the recipient has no iMessage buddy
/// ("Can't get buddy ...").
func isIMessageUnavailableError(_ reason: String) -> Bool {
  let lower = reason.lowercased()
  if isPermissionError(reason) { return false }
  return lower.contains("can't get service") || lower.contains("can’t get service")
    || lower.contains("can't get 1st service") || lower.contains("can’t get 1st service")
    || lower.contains("can't get buddy") || lower.contains("can’t get buddy")
    || lower.contains("not registered with imessage")
    || (lower.contains("imessage") && lower.contains("unavailable"))
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
      return Envelope.failure(.invalidArgs, "Could not parse arguments. Expected JSON with 'phoneNumber' and optional 'limit'.")
    }

    let limit = max(1, min(input.limit ?? 10, 50))
    let phoneNumbers = normalizePhoneNumber(input.phoneNumber)

    guard let phoneNumber = phoneNumbers.first, !phoneNumber.isEmpty else {
      return Envelope.failure(.invalidArgs, "Invalid phone number format: \(input.phoneNumber)")
    }

    let query = """
      SELECT
          m.text as content,
          datetime(m.date/1000000000 + strftime('%s', '2001-01-01'), 'unixepoch', 'localtime') as date,
          COALESCE(h.id, 'Me') as sender,
          m.is_from_me,
          m.cache_has_attachments,
          GROUP_CONCAT(DISTINCT a.transfer_name) as attachment_names,
          m.attributedBody
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
      return mapDatabaseError(error)
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
      limit = max(1, min(input.limit ?? 10, 50))
    } else {
      limit = 10
    }

    let query = """
      SELECT
          m.text as content,
          datetime(m.date/1000000000 + strftime('%s', '2001-01-01'), 'unixepoch', 'localtime') as date,
          COALESCE(h.id, 'Unknown') as sender,
          m.is_from_me,
          m.cache_has_attachments,
          GROUP_CONCAT(DISTINCT a.transfer_name) as attachment_names,
          m.attributedBody
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
      return mapDatabaseError(error)
    }
  }
}

// MARK: - Database Error Mapping

/// Map a `DatabaseError` to a canonical failure envelope. Full Disk Access /
/// open failures are environment issues the user must resolve, so they map to
/// `unavailable`; everything else is an `execution_error`.
private func mapDatabaseError(_ error: DatabaseError) -> String {
  let msg = error.message
  if msg.localizedCaseInsensitiveContains("Full Disk Access")
    || msg.localizedCaseInsensitiveContains("Cannot access")
    || msg.localizedCaseInsensitiveContains("unable to open")
    || msg.localizedCaseInsensitiveContains("permission")
  {
    return Envelope.failure(.unavailable, msg, retryable: false)
  }
  return Envelope.failure(.executionError, msg)
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

// MARK: - C ABI surface (via osaurus-plugin-sdk)

// Context state (simple wrapper class to hold state)
private class PluginContext {
  let sendMessageTool = SendMessageTool()
  let readMessagesTool = ReadMessagesTool()
  let getUnreadMessagesTool = GetUnreadMessagesTool()
}

/// Plugin manifest JSON. Kept at file scope (rather than inline in
/// `get_manifest`) so it can be parsed and validated by the test suite.
/// Each tool MUST declare `id` + `description`: the host's `PluginManifest`
/// decoder requires `id` and will fail to load the whole plugin otherwise.
let messagesManifestJSON = """
  {
    "plugin_id": "osaurus.messages",
    "name": "Messages",
    "version": "1.0.8",
    "description": "A messages plugin for macOS Messages.app integration - send and read iMessages",
    "license": "MIT",
    "authors": ["Dinoki Labs"],
    "min_macos": "13.0",
    "min_osaurus": "0.5.0",
    "capabilities": {
      "tools": [
        {
          "id": "send_message",
          "description": "Send a message to a phone number via iMessage (falls back to SMS when iMessage is unavailable)",
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
            "required": ["phoneNumber", "message"],
            "additionalProperties": false
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
            "required": ["phoneNumber"],
            "additionalProperties": false
          },
          "requirements": ["disk"],
          "permission_policy": "auto"
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
            "required": [],
            "additionalProperties": false
          },
          "requirements": ["disk"],
          "permission_policy": "auto"
        }
      ]
    }
  }
  """

// API Implementation
private var pluginAPI = PluginEntry.makeAPI(
  version: OsrABIVersion.v2,
  init: {
    let ctx = PluginContext()
    return Unmanaged.passRetained(ctx).toOpaque()
  },
  destroy: { ctxPtr in
    guard let ctxPtr = ctxPtr else { return }
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  },
  getManifest: { ctxPtr in
    return osrMakeCString(messagesManifestJSON)
  },
  invoke: { ctxPtr, typePtr, idPtr, payloadPtr in
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
      return osrMakeCString(Envelope.failure(.invalidArgs, "Unknown capability type: \(type)"))
    }

    switch id {
    case ctx.sendMessageTool.name:
      return osrMakeCString(ctx.sendMessageTool.run(args: payload))
    case ctx.readMessagesTool.name:
      return osrMakeCString(ctx.readMessagesTool.run(args: payload))
    case ctx.getUnreadMessagesTool.name:
      return osrMakeCString(ctx.getUnreadMessagesTool.run(args: payload))
    default:
      return osrMakeCString(Envelope.failure(.notFound, "Unknown tool: \(id)"))
    }
  }
)

// MARK: - Entry Points

/// ABI v2 entry: the host injects its API table, captured into
/// `HostBridge.shared`. Newer hosts try this symbol first.
@_cdecl("osaurus_plugin_entry_v2")
public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
  PluginEntry.enterV2(host, api: &pluginAPI)
}

/// Legacy ABI v1 entry — kept so old hosts (which never pass a host API)
/// continue to load this plugin.
@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  PluginEntry.enterV1(api: &pluginAPI)
}
