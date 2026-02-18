# Testing the Apple Reminders MCP Server

This document explains how to test the MCP server without integrating it into Claude Desktop.

## Quick Test

The simplest way to test is with the provided test script:

```bash
# Show help
./test.sh

# List all available MCP tools
./test.sh list-tools

# List all your reminder lists
./test.sh list-lists

# Create a new reminder list
./test.sh create-list "Shopping"

# Get today's and past due reminders
./test.sh today

# List all incomplete reminders
./test.sh list-reminders

# List reminders from a specific list
./test.sh list-reminders "Work Tasks"

# Create a test reminder
./test.sh create "Test Reminder"

# Create a reminder in a specific list
./test.sh create "Buy milk" "Shopping"

# Update a reminder
./test.sh update <reminder-id> --title "New Title"
./test.sh update <reminder-id> --notes "Updated notes" --priority 5
```

## How It Works

The MCP server communicates via JSON-RPC over stdin/stdout. The test scripts send JSON requests and parse JSON responses.

### Example Request/Response

**Request** (list all reminder lists):
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "list_reminder_lists",
    "arguments": {}
  }
}
```

**Response**:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"lists\":[{\"id\":\"...\",\"name\":\"Work Tasks\"}],\"count\":1}"
      }
    ]
  }
}
```

## Manual Testing

You can also test manually by running the server and typing JSON requests:

```bash
# Start the server
.build/release/apple-events-mcp

# Then paste this request and press Enter:
{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}

# Press Ctrl+C to exit
```

## Interactive Testing

Use the interactive test script for a live session:

```bash
./test-interactive.sh
```

This starts the server and waits for you to paste JSON-RPC requests.

## Checking Logs

The server logs to stderr, which you can see by redirecting:

```bash
./test.sh list-lists 2>&1 | grep "^\["
```

Example log output:
```
[2025-11-10T04:46:21Z] Successfully obtained access to Reminders
[2025-11-10T04:46:21Z] Apple Reminders MCP Server running on stdio
[2025-11-10T04:46:22Z] Starting listReminders for list: Work Tasks
[2025-11-10T04:46:22Z] Fetched 345 reminders in 234ms
[2025-11-10T04:46:22Z] After filtering: 53 reminders (showCompleted=false)
[2025-11-10T04:46:22Z] Total operation took 236ms
```

## Available Tools

1. **list_reminder_lists** - Get all reminder lists
2. **create_reminder_list** - Create a new reminder list
3. **list_today_reminders** - Get all incomplete reminders due today or past due (includes pastDue flag)
4. **list_reminders** - Get reminders (with optional list_name and completed filters)
5. **create_reminder** - Create a new reminder
6. **update_reminder** - Update an existing reminder's title, notes, due date, or priority
7. **complete_reminder** - Mark a reminder as completed (needs reminder_id)
8. **delete_reminder** - Delete a reminder (needs reminder_id)

## Integration with Claude Desktop

Once testing is complete, integrate with Claude Desktop by adding to:
`~/Library/Application Support/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "apple-events": {
      "command": "/absolute/path/to/apple-events-mcp/.build/release/apple-events-mcp"
    }
  }
}
```

Then restart Claude Desktop. The server implements the full MCP protocol including:
- `initialize` - Initial handshake with protocol version, capabilities, and usage instructions
- `tools/list` - Lists all available tools
- `tools/call` - Executes a specific tool

**Usage Instructions**: When the server connects, it sends comprehensive usage instructions to Claude, explaining that Apple Reminders can be used for task management, not just simple reminders. This helps Claude understand how to best utilize the tools for project management, daily planning, and task organization.
