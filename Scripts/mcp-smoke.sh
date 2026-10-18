#!/bin/bash
#
# MCP server 冒烟测试。需要 Lookin.app 已启动且 MCP server 已开启。
#
# 用法: Scripts/mcp-smoke.sh [port]
# 默认端口 47200（若被占用，实际端口会顺延，请以 App 设置页显示的地址为准）。
#

set -euo pipefail

PORT="${1:-47200}"
BASE="http://127.0.0.1:${PORT}/mcp"
ACCEPT="Accept: application/json, text/event-stream"
META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}'

post() {
    curl -sS -X POST "$BASE" \
        -H "Content-Type: application/json" \
        -H "$ACCEPT" \
        "$@"
    echo
}

echo "== legacy initialize =="
post -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcp-smoke","version":"1.0"}}}'

echo "== legacy tools/list =="
post -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

echo "== modern server/discover =="
post -H "MCP-Protocol-Version: 2026-07-28" -H "Mcp-Method: server/discover" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"server/discover\",\"params\":{${META}}}"

echo "== modern tools/list =="
post -H "MCP-Protocol-Version: 2026-07-28" -H "Mcp-Method: tools/list" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\",\"params\":{${META}}}"

echo "== modern tools/call lookin_get_status =="
post -H "MCP-Protocol-Version: 2026-07-28" -H "Mcp-Method: tools/call" -H "Mcp-Name: lookin_get_status" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"lookin_get_status\",\"arguments\":{${META}}}}"

echo "== legacy tools/call lookin_list_targets =="
post -d '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"lookin_list_targets","arguments":{}}}'
