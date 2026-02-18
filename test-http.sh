#!/bin/bash

# Test Apple Reminders MCP Server over HTTP
# Usage: ./test-http.sh [command]
#
# Requires a running server: .build/release/apple-events-mcp --http

PORT="${MCP_PORT:-3030}"
API_KEY="${MCP_API_KEY:-}"
BASE_URL="http://localhost:${PORT}/${API_KEY}/mcp"

if [ -z "$API_KEY" ]; then
    echo "Error: Set MCP_API_KEY environment variable"
    echo "Usage: MCP_API_KEY=your-key ./test-http.sh [command]"
    exit 1
fi

send_request() {
    local request="$1"
    echo "Request:"
    echo "$request" | jq '.' 2>/dev/null || echo "$request"
    echo ""
    echo "Response:"
    curl -s -X POST "$BASE_URL" \
        -H "Content-Type: application/json" \
        -d "$request" | jq '.' 2>/dev/null
    echo ""
}

case "$1" in
    "health")
        echo "Health check..."
        curl -s "http://localhost:${PORT}/health" | jq '.'
        ;;

    "auth-test")
        echo "Testing auth rejection with wrong key..."
        curl -s -w "\nHTTP Status: %{http_code}\n" -X POST "http://localhost:${PORT}/wrong-key/mcp" \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
        ;;

    "initialize")
        echo "Initializing..."
        send_request '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"0.1"}}}'
        ;;

    "list-tools")
        echo "Listing available tools..."
        send_request '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
        ;;

    "list-lists")
        echo "Listing reminder lists..."
        send_request '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_reminder_lists","arguments":{}}}'
        ;;

    "today")
        echo "Getting today's reminders..."
        send_request '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_today_reminders","arguments":{}}}'
        ;;

    "list-reminders")
        if [ -z "$2" ]; then
            echo "Listing all incomplete reminders..."
            send_request '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_reminders","arguments":{"completed":false}}}'
        else
            echo "Listing incomplete reminders from '$2'..."
            send_request "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"list_reminders\",\"arguments\":{\"list_name\":\"$2\",\"completed\":false}}}"
        fi
        ;;

    *)
        echo "Apple Reminders MCP Server - HTTP Test Tool"
        echo "============================================"
        echo ""
        echo "Prerequisites:"
        echo "  1. Create config.json with port and apiKey"
        echo "  2. Start server: .build/release/apple-events-mcp --http"
        echo "  3. Set: export MCP_API_KEY=your-api-key"
        echo ""
        echo "Usage:"
        echo "  ./test-http.sh health              - Health check"
        echo "  ./test-http.sh auth-test            - Test auth rejection"
        echo "  ./test-http.sh initialize           - Initialize MCP session"
        echo "  ./test-http.sh list-tools           - List available tools"
        echo "  ./test-http.sh list-lists           - List reminder lists"
        echo "  ./test-http.sh today                - Get today's reminders"
        echo "  ./test-http.sh list-reminders       - List all incomplete reminders"
        echo "  ./test-http.sh list-reminders Work  - List reminders from 'Work' list"
        echo ""
        echo "Environment variables:"
        echo "  MCP_PORT     - Server port (default: 3030)"
        echo "  MCP_API_KEY  - API key (required)"
        exit 0
        ;;
esac
