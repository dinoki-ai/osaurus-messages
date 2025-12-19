import Cocoa
import Foundation

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

// MARK: - Shell Command Helper

private func runCommand(_ command: String) -> Result<String, Error> {
  let process = Process()
  let pipe = Pipe()

  process.executableURL = URL(fileURLWithPath: "/bin/zsh")
  process.arguments = ["-c", command]
  process.standardOutput = pipe
  process.standardError = pipe

  do {
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    if process.terminationStatus != 0 {
      return .failure(NSError(domain: "CommandError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output]))
    }

    return .success(output)
  } catch {
    return .failure(error)
  }
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

  // If it's already in the correct format (+1XXXXXXXXXX)
  if cleaned.hasPrefix("+1") && cleaned.count == 12 {
    return [cleaned]
  }

  // If it starts with 1 and has 11 digits total
  if cleaned.hasPrefix("1") && cleaned.count == 11 {
    return ["+\(cleaned)"]
  }

  // If it's 10 digits
  if cleaned.count == 10 && !cleaned.hasPrefix("+") {
    return ["+1\(cleaned)"]
  }

  // Try multiple formats
  var formats: Set<String> = []

  if cleaned.hasPrefix("+1") {
    formats.insert(cleaned)
  } else if cleaned.hasPrefix("1") {
    formats.insert("+\(cleaned)")
  } else {
    formats.insert("+1\(cleaned)")
  }

  return Array(formats)
}

// MARK: - Database Path

private func getMessagesDBPath() -> String {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  return "\(home)/Library/Messages/chat.db"
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

    guard !phoneNumbers.isEmpty else {
      return "{\"error\": \"Invalid phone number format\"}"
    }

    // Build SQL conditions for phone number variants
    let phoneConditions = phoneNumbers.map { "h.id = '\($0)'" }.joined(separator: " OR ")

    let dbPath = getMessagesDBPath()

    let query = """
      SELECT
          CASE
              WHEN m.text IS NOT NULL AND m.text != '' THEN m.text
              ELSE '[Media or unsupported content]'
          END as content,
          datetime(m.date/1000000000 + strftime('%s', '2001-01-01'), 'unixepoch', 'localtime') as date,
          h.id as sender,
          m.is_from_me,
          m.cache_has_attachments
      FROM message m
      INNER JOIN handle h ON h.ROWID = m.handle_id
      WHERE (\(phoneConditions))
          AND (m.text IS NOT NULL OR m.cache_has_attachments = 1)
          AND m.item_type = 0
      ORDER BY m.date DESC
      LIMIT \(limit)
      """

    let escapedQuery = query.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
    let command = "sqlite3 -json \"\(dbPath)\" \"\(escapedQuery)\""

    let result = runCommand(command)

    switch result {
    case .success(let output):
      if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "[]"
      }
      let messages = parseMessagesJSON(output)
      return encodeJSON(messages)
    case .failure(let error):
      let errorMessage = error.localizedDescription
      if errorMessage.contains("unable to open database") || errorMessage.contains("permission denied") {
        return "{\"error\": \"Cannot access Messages database. Please grant Full Disk Access to the application in System Settings > Privacy & Security > Full Disk Access.\"}"
      }
      return "{\"error\": \"\(escapeJSON(errorMessage))\"}"
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
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      // Empty args is valid, use defaults
      return runWithDefaults()
    }

    return runWithLimit(input.limit ?? 10)
  }

  private func runWithDefaults() -> String {
    return runWithLimit(10)
  }

  private func runWithLimit(_ limit: Int) -> String {
    let maxLimit = min(limit, 50)
    let dbPath = getMessagesDBPath()

    let query = """
      SELECT
          CASE
              WHEN m.text IS NOT NULL AND m.text != '' THEN m.text
              ELSE '[Media or unsupported content]'
          END as content,
          datetime(m.date/1000000000 + strftime('%s', '2001-01-01'), 'unixepoch', 'localtime') as date,
          h.id as sender,
          m.is_from_me,
          m.cache_has_attachments
      FROM message m
      INNER JOIN handle h ON h.ROWID = m.handle_id
      WHERE m.is_from_me = 0
          AND m.is_read = 0
          AND (m.text IS NOT NULL OR m.cache_has_attachments = 1)
          AND m.item_type = 0
      ORDER BY m.date DESC
      LIMIT \(maxLimit)
      """

    let escapedQuery = query.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
    let command = "sqlite3 -json \"\(dbPath)\" \"\(escapedQuery)\""

    let result = runCommand(command)

    switch result {
    case .success(let output):
      if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "[]"
      }
      let messages = parseMessagesJSON(output)
      return encodeJSON(messages)
    case .failure(let error):
      let errorMessage = error.localizedDescription
      if errorMessage.contains("unable to open database") || errorMessage.contains("permission denied") {
        return "{\"error\": \"Cannot access Messages database. Please grant Full Disk Access to the application in System Settings > Privacy & Security > Full Disk Access.\"}"
      }
      return "{\"error\": \"\(escapeJSON(errorMessage))\"}"
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

private struct SQLiteMessage: Decodable {
  let content: String
  let date: String
  let sender: String
  let is_from_me: Int
  let cache_has_attachments: Int
}

private func parseMessagesJSON(_ jsonOutput: String) -> [Message] {
  guard let data = jsonOutput.data(using: .utf8) else {
    return []
  }

  do {
    let sqliteMessages = try JSONDecoder().decode([SQLiteMessage].self, from: data)
    return sqliteMessages.map { msg in
      Message(
        content: msg.content,
        date: msg.date,
        sender: msg.sender,
        isFromMe: msg.is_from_me == 1,
        attachments: msg.cache_has_attachments == 1 ? ["[Has attachments]"] : nil
      )
    }
  } catch {
    return []
  }
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
        "version": "0.1.0",
        "description": "A messages plugin for macOS Messages.app integration - send and read iMessages",
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
              "requirements": [],
              "permission_policy": "ask"
            },
            {
              "id": "read_messages",
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
              "requirements": [],
              "permission_policy": "auto"
            },
            {
              "id": "get_unread_messages",
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
              "requirements": [],
              "permission_policy": "auto"
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
