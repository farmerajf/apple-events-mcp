#!/bin/bash

# Test Apple Reminders MCP Server
# Usage: ./test.sh [list-tools|list-lists|list-reminders <list-name>]

EXECUTABLE=".build/release/apple-events-mcp"

if [ ! -f "$EXECUTABLE" ]; then
    echo "❌ Error: Executable not found at $EXECUTABLE"
    echo "Run: swift build -c release"
    exit 1
fi

# Helper function to send request and format output
send_request() {
    local request="$1"
    echo "📤 Request:"
    echo "$request" | jq '.' 2>/dev/null || echo "$request"
    echo ""
    echo "📥 Response:"
    echo "$request" | $EXECUTABLE 2>&1 | grep '^{' | jq '.' 2>/dev/null || echo "$request" | $EXECUTABLE 2>&1
    echo ""
}

case "$1" in
    "list-tools")
        echo "🔧 Listing available tools..."
        echo ""
        send_request '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
        ;;

    "list-lists")
        echo "📋 Listing reminder lists..."
        echo ""
        send_request '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_reminder_lists","arguments":{}}}'
        ;;

    "create-list")
        if [ -z "$2" ]; then
            echo "❌ Error: Missing list name"
            echo "Usage: ./test.sh create-list \"List Name\""
            exit 1
        fi
        echo "📝 Creating reminder list '$2'..."
        echo ""
        send_request "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"create_reminder_list\",\"arguments\":{\"name\":\"$2\"}}}"
        ;;

    "today")
        echo "📅 Getting today's reminders (due today and past due)..."
        echo ""
        send_request '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_today_reminders","arguments":{}}}'
        ;;

    "list-reminders")
        if [ -z "$2" ]; then
            echo "📝 Listing all incomplete reminders..."
            echo ""
            send_request '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_reminders","arguments":{"completed":false}}}'
        else
            echo "📝 Listing incomplete reminders from '$2'..."
            echo ""
            send_request "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"list_reminders\",\"arguments\":{\"list_name\":\"$2\",\"completed\":false}}}"
        fi
        ;;

    "create")
        if [ -z "$2" ]; then
            echo "❌ Error: Missing reminder title"
            echo "Usage: ./test.sh create \"Reminder title\" [list-name]"
            exit 1
        fi
        LIST_NAME="${3:-Reminders}"
        echo "➕ Creating reminder '$2' in '$LIST_NAME'..."
        echo ""
        send_request "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"create_reminder\",\"arguments\":{\"title\":\"$2\",\"list_name\":\"$LIST_NAME\"}}}"
        ;;

    "update")
        if [ -z "$2" ]; then
            echo "❌ Error: Missing reminder ID"
            echo "Usage: ./test.sh update <reminder-id> [--title \"New Title\"] [--notes \"New Notes\"] [--priority 5]"
            exit 1
        fi
        REMINDER_ID="$2"
        shift 2

        # Build arguments JSON
        ARGS="{\"reminder_id\":\"$REMINDER_ID\""

        while [ $# -gt 0 ]; do
            case "$1" in
                --title)
                    ARGS="$ARGS,\"title\":\"$2\""
                    shift 2
                    ;;
                --notes)
                    ARGS="$ARGS,\"notes\":\"$2\""
                    shift 2
                    ;;
                --priority)
                    ARGS="$ARGS,\"priority\":\"$2\""
                    shift 2
                    ;;
                --due-date)
                    ARGS="$ARGS,\"due_date\":\"$2\""
                    shift 2
                    ;;
                *)
                    echo "❌ Unknown option: $1"
                    exit 1
                    ;;
            esac
        done

        ARGS="$ARGS}"
        echo "✏️  Updating reminder..."
        echo ""
        send_request "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"update_reminder\",\"arguments\":$ARGS}}"
        ;;

    *)
        echo "Apple Reminders MCP Server - Test Tool"
        echo "======================================"
        echo ""
        echo "Usage:"
        echo "  ./test.sh list-tools                           - List available MCP tools"
        echo "  ./test.sh list-lists                           - List all reminder lists"
        echo "  ./test.sh create-list \"Name\"                   - Create a new reminder list"
        echo "  ./test.sh today                                - Get today's and past due reminders"
        echo "  ./test.sh list-reminders [list-name]           - List incomplete reminders"
        echo "  ./test.sh create \"Title\" [list-name]           - Create a test reminder"
        echo "  ./test.sh update <id> [--title] [--notes] ...  - Update a reminder"
        echo ""
        echo "Examples:"
        echo "  ./test.sh list-tools"
        echo "  ./test.sh list-lists"
        echo "  ./test.sh create-list \"Shopping\""
        echo "  ./test.sh today"
        echo "  ./test.sh list-reminders"
        echo "  ./test.sh list-reminders \"Work Tasks\""
        echo "  ./test.sh create \"Test Reminder\""
        echo "  ./test.sh create \"Buy milk\" \"Shopping\""
        echo "  ./test.sh update <reminder-id> --title \"New Title\""
        echo "  ./test.sh update <reminder-id> --notes \"Updated notes\" --priority 5"
        echo ""
        exit 0
        ;;
esac
