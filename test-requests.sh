#!/bin/bash

# Test script for Apple Reminders MCP Server
# This sends MCP protocol requests to the server via stdin

EXECUTABLE=".build/release/apple-events-mcp"

if [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Executable not found at $EXECUTABLE"
    echo "Run: swift build -c release"
    exit 1
fi

echo "Testing Apple Reminders MCP Server..."
echo "======================================="
echo ""

# Test 1: List tools
echo "Test 1: Listing available tools..."
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | $EXECUTABLE &
sleep 2
pkill -P $$ apple-events-mcp 2>/dev/null
echo ""
echo "---"
echo ""

# Test 2: List reminder lists
echo "Test 2: List all reminder lists..."
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_reminder_lists","arguments":{}}}' | $EXECUTABLE &
sleep 2
pkill -P $$ apple-events-mcp 2>/dev/null
echo ""
echo "---"
echo ""

# Test 3: List reminders from a specific list (change "Work Tasks" to one of your lists)
echo "Test 3: List reminders from 'Work Tasks' (incomplete only)..."
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_reminders","arguments":{"list_name":"Work Tasks","completed":false}}}' | $EXECUTABLE &
sleep 2
pkill -P $$ apple-events-mcp 2>/dev/null
echo ""
echo "---"
echo ""

echo "Tests complete!"
echo ""
echo "Note: The server runs continuously, so we kill it after each test."
echo "In production, Claude Desktop keeps it running and sends multiple requests."
