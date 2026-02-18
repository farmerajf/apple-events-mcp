#!/bin/bash

# Simple one-shot test - just lists the available tools
echo "Testing: List available tools..."
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | .build/release/apple-events-mcp
