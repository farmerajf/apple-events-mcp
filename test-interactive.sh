#!/bin/bash

# Interactive test for Apple Reminders MCP Server
# This lets you send individual requests and see responses

EXECUTABLE=".build/release/apple-events-mcp"

if [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Executable not found at $EXECUTABLE"
    echo "Run: swift build -c release"
    exit 1
fi

echo "Apple Reminders MCP Server - Interactive Test"
echo "=============================================="
echo ""
echo "The server is now running. Paste a JSON-RPC request and press Enter."
echo "Press Ctrl+C to exit."
echo ""
echo "Example requests:"
echo ""
echo "1. List tools:"
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
echo ""
echo "2. List reminder lists:"
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_reminder_lists","arguments":{}}}'
echo ""
echo "3. List incomplete reminders from a specific list:"
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_reminders","arguments":{"list_name":"Work Tasks","completed":false}}}'
echo ""
echo "4. Create a reminder:"
echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"create_reminder","arguments":{"title":"Test Reminder","list_name":"Reminders"}}}'
echo ""
echo "---"
echo ""

# Run the server
exec $EXECUTABLE
