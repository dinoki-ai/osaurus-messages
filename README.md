# osaurus-messages

An Osaurus plugin for interacting with macOS Messages.app. Send and read iMessages programmatically. Based on [apple-mcp message.ts](https://github.com/supermemoryai/apple-mcp/blob/main/utils/message.ts).

## Prerequisites

### Automation Permissions (Required for sending messages)

Grant permission in:

- System Settings > Privacy & Security > Automation

Add the application using this plugin (e.g., Osaurus, or your terminal if running from CLI) and enable access to **Messages**.

### Full Disk Access (Required for reading messages)

Grant permission in:

- System Settings > Privacy & Security > Full Disk Access

Add the application using this plugin. This is required to access the Messages database at `~/Library/Messages/chat.db`.

## Tools

### `send_message`

Send an iMessage to a phone number.

**Parameters:**

- `phoneNumber` (required): The recipient's phone number (e.g., `+1234567890` or `1234567890`)
- `message` (required): The message content to send

**Example:**

```json
{
  "phoneNumber": "+15551234567",
  "message": "Hello from Osaurus!"
}
```

**Response:**

```json
{
  "success": true,
  "message": "Message sent to +15551234567"
}
```

### `read_messages`

Read message history from a specific contact.

**Parameters:**

- `phoneNumber` (required): The contact's phone number to read messages from
- `limit` (optional): Maximum number of messages to return (default: 10, max: 50)

**Example:**

```json
{
  "phoneNumber": "+15551234567",
  "limit": 5
}
```

**Response:**

```json
[
  {
    "content": "Hey, how are you?",
    "date": "2024-01-15 14:30:00",
    "sender": "+15551234567",
    "isFromMe": false,
    "attachments": null
  },
  {
    "content": "I'm good, thanks!",
    "date": "2024-01-15 14:32:00",
    "sender": "+15551234567",
    "isFromMe": true,
    "attachments": null
  }
]
```

### `get_unread_messages`

Get all unread messages from all contacts.

**Parameters:**

- `limit` (optional): Maximum number of messages to return (default: 10, max: 50)

**Example:**

```json
{
  "limit": 10
}
```

**Response:**

```json
[
  {
    "content": "Are you coming to the meeting?",
    "date": "2024-01-15 15:00:00",
    "sender": "+15559876543",
    "isFromMe": false,
    "attachments": null
  }
]
```

## Message Object Format

All message-related tools return messages in this format:

| Field         | Type       | Description                                 |
| ------------- | ---------- | ------------------------------------------- |
| `content`     | `string`   | The message text content                    |
| `date`        | `string`   | Date/time the message was sent (local time) |
| `sender`      | `string`   | Phone number or email of the sender         |
| `isFromMe`    | `boolean`  | Whether you sent this message               |
| `attachments` | `string[]` | List of attachment indicators (if any)      |

## Development

1. Build:

   ```bash
   swift build -c release
   cp .build/release/libosaurus-messages.dylib ./libosaurus-messages.dylib
   ```

2. Install locally:
   ```bash
   osaurus tools install .
   ```

## Publishing

### Code Signing (Required for Distribution)

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  .build/release/libosaurus-messages.dylib
```

### Package and Distribute

```bash
osaurus tools package osaurus.messages 0.1.0
```

This creates `osaurus.messages-0.1.0.zip` for distribution.

## Troubleshooting

### "Cannot access Messages database"

This error means the application doesn't have Full Disk Access. To fix:

1. Open System Settings > Privacy & Security > Full Disk Access
2. Click the lock icon to make changes
3. Add the application (Terminal.app, iTerm.app, or Osaurus)
4. Restart the application

### "Unknown error" when sending messages

This typically means:

1. Messages.app is not set up or logged in
2. The phone number format is incorrect
3. Automation permissions haven't been granted

Ensure you've granted Automation permissions and that Messages.app is properly configured with your iMessage account.

## Credits

- [apple-mcp](https://github.com/supermemoryai/apple-mcp) by supermemoryai
