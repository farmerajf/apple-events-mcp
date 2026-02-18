# Apple Reminders & Calendar MCP Server

A Model Context Protocol (MCP) server that integrates **Apple Reminders** and **Apple Calendar** with Claude, enabling task management and calendar scheduling directly through conversations.

**Built entirely in Swift** using EventKit for native, fast, and reliable access.

## Features

**Reminders / Task Management:**
- Create, update, complete, and delete reminders across multiple lists
- Daily planning with `list_today_reminders` (due today + overdue)
- Priority levels (0=none, 1-4=high, 5=medium, 6-9=low)

**Calendar Events:**
- Create, update, and delete calendar events
- View today's schedule with `list_today_events`
- Query events by date range with `list_events`
- Support for location, URL (video call links), and all-day events

**Transport:**
- Stdio for local use (Claude Desktop)
- Streamable HTTP for remote access (Claude Web, iOS, etc.)
- API key authentication for HTTP mode

## Prerequisites

- macOS 14.0 (Sonoma) or later
- Swift 5.9 or later
- Claude Desktop app (for stdio mode) or any MCP client (for HTTP mode)

## Installation

1. Clone this repository
2. Build the Swift package:
```bash
swift build -c release
```

3. The executable will be built at `.build/release/apple-events-mcp`

## Transport Modes

### Stdio (default)

For local use with Claude Desktop. No configuration file needed.

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "apple-events": {
      "command": "/absolute/path/to/apple-events-mcp/.build/release/apple-events-mcp"
    }
  }
}
```

### Streamable HTTP

For remote access from Claude Web, Claude iOS, or other MCP clients.

1. Create a `config.json` in the working directory:

```json
{
  "port": 3030,
  "apiKey": "your-secret-api-key"
}
```

Generate a secure API key:
```bash
openssl rand -hex 32
```

2. Start the server:
```bash
.build/release/apple-events-mcp --http
```

3. The MCP endpoint will be available at:
```
POST http://localhost:3030/{apiKey}/mcp
```

4. Health check (no auth required):
```
GET http://localhost:3030/health
```

**Important**: Use HTTPS in production (e.g., behind a reverse proxy) since the API key is in the URL path.

## Permissions

The first time you run this, macOS will prompt you to grant access to both Reminders and Calendar. Click "Allow" for each.

## License

MIT
