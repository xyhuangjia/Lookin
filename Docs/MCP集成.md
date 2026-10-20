# Lookin 内置 MCP Server

Lookin.app 内置了一个 MCP server，让 Claude Code、Codex 等 AI Agent 可以直接读取并修改正在运行的 iOS App 的 UI。

它复用 Lookin.app 已有的 PeerTalk 连接，因此：

- 不需要额外启动 `lookinctl`，也不会顶掉 App 的连接；
- 模拟器与真机都可用；
- 不需要 LookinServer 的 HTTP REST bridge。

## 架构

```
Claude Code / Codex
        │  Streamable HTTP (POST /mcp)
        ▼
Lookin.app
  ├─ LKMCPServer      127.0.0.1:47200，HTTP/1.1 + JSON-RPC
  ├─ LKMCPService     tool 实现、写权限、目标选择
  └─ LKInspectableApp 已有的 PeerTalk channel
        │
        ▼
iOS App (LookinServer)
```

MCP 模块位于 `LookinClient/MCP/`：

| 文件 | 职责 |
|---|---|
| `LKMCPServer.swift` | `NWListener`、连接处理、handshake 文件、菜单栏状态项、router 与 service 的接线 |
| `LKMCPRouter.swift` | 双版本 JSON-RPC 路由（依赖注入，可独立测试） |
| `LKMCPWireProtocol.swift` | HTTP 解析、Host/Origin 校验、协议版本协商、tool 结果与属性值解析 |
| `LKMCPToolDefinitions.swift` | 14 个 tool 的静态契约 |
| `LKMCPService.swift` | 14 个 tool 的实现、target 管理、错误映射 |
| `LKInspectionJSON.swift` | 层级/属性/对象/detail/当前 VC 的 JSON 序列化 |
| `LKMCPSettingsWindowController.swift` | MCP 设置窗口 |
| `LKInspectionRequestGate.{h,m}` | MCP 与 UI 共用 channel 的互斥闸门 |

单元测试位于 `LookinMCPTests/`，是一个不启动宿主 App 的 macOS 测试 bundle，直接编译上述纯逻辑文件。

## 环境要求

- macOS 14.0 及以上
- 目标 iOS App 已集成 LookinServer，并处于前台
- Claude Code v2.1.281+（支持 MCP `2026-07-28`）或带 HTTP MCP 支持的 Codex
- 无需安装 Node.js

## 启用

1. 打开 Lookin.app。
2. 菜单 **Lookin → MCP Server…**。
3. 勾选 **Enable MCP server**。
4. 默认地址为 `http://127.0.0.1:47200/mcp`。端口被占用时会自动在 47200–47209 内顺延，实际地址显示在设置窗口和菜单栏状态项中。

MCP 开启期间，关闭最后一个窗口不会退出 App（否则 Agent 会断连）。请通过菜单栏的 **Quit Lookin** 退出。

## 客户端配置

### Claude Code

```bash
claude mcp add --transport http lookin http://127.0.0.1:47200/mcp
```

或写入 `.mcp.json`：

```json
{
  "mcpServers": {
    "lookin": {
      "type": "http",
      "url": "http://127.0.0.1:47200/mcp"
    }
  }
}
```

### Codex

```bash
codex mcp add lookin --url http://127.0.0.1:47200/mcp
```

或写入 `~/.codex/config.toml`：

```toml
[mcp_servers.lookin]
url = "http://127.0.0.1:47200/mcp"
```

### Cursor / Windsurf / Trae / Cline

写入项目 `.mcp.json` 或全局 `~/.cursor/mcp.json`（Cursor）/ `~/.codeium/windsurf/mcp_config.json`（Windsurf）：

```json
{
  "mcpServers": {
    "lookin": {
      "url": "http://127.0.0.1:47200/mcp"
    }
  }
}
```

### Gemini CLI

写入 `~/.gemini/settings.json`：

```json
{
  "mcpServers": {
    "lookin": {
      "httpUrl": "http://127.0.0.1:47200/mcp"
    }
  }
}
```

### 只支持 stdio 的 Agent

用 `mcp-remote` 桥接（需要 Node.js）：

```json
{
  "mcpServers": {
    "lookin": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://127.0.0.1:47200/mcp"]
    }
  }
}
```

设置窗口提供 **Copy Claude Code Command** / **Copy Codex Config** / **Copy All Agents**（包含以上全部形态）三个按钮，菜单栏状态项提供 **Copy MCP Config**，均不会自动改写你的配置文件。

## 协议兼容

server 同时支持两代 Streamable HTTP：

| 版本 | 握手 | 使用者 |
|---|---|---|
| `2026-07-28` | `server/discover`，无状态、仅 POST | Claude Code |
| `2025-11-25` / `2025-06-18` | `initialize` + `notifications/initialized` | Codex（默认 `2025-06-18`）、Cursor |
| `2025-03-26` / `2024-11-05` | 同上 | 旧版 SDK 客户端（Windsurf 早期版本、老版 Python/TS SDK） |

已用真实客户端验证过：

- Claude Code 2.1.303（`claude mcp list` 显示 ✔ Connected）
- Codex CLI 0.163.0（`codex exec` 实际调用 `lookin_get_status` 成功）
- Cursor CLI 2026.07.23（`cursor-agent mcp list-tools lookin` 列出全部 14 个 tool）

实现要点：

- 仅 `POST /mcp`（忽略路径后的查询串），GET/DELETE 返回 405 + `Allow: POST`；
- 支持 JSON-RPC batch（`2025-06-18` 之前的老 SDK 会发），响应为 JSON 数组，空 batch 返回 `-32600`；
- 所有 tool 同步返回 `application/json`，v1 不使用 SSE；
- 无 session id，不依赖 `Mcp-Session-Id`；
- Host / Origin 校验接受全部 loopback 写法（`127.0.0.1` / `localhost` / `[::1]`，带端口或不带，大小写不敏感），端口取自连接自身的本地端点；非本机来源返回 403；
- 现代版本校验 `MCP-Protocol-Version`、`Mcp-Method`、`Mcp-Name`，不匹配返回 400 + `-32020`；
- 现代版本 `tools/list` 的 `cacheScope` 只能是 `"public"` 或 `"private"`（Claude Code 会做枚举校验）。

## 工具清单

| Tool | 类型 | 说明 |
|---|---|---|
| `lookin_list_targets` | 读 | 列出当前可连接的 App（id、名称、bundle、设备、系统、屏幕、server 版本） |
| `lookin_select_target` | 控制 | 选择后续 tool 操作的目标 App |
| `lookin_get_status` | 读 | server 地址、协议版本、active target、写/invoke 开关 |
| `lookin_get_hierarchy` | 读 | 视图层级树；节点 `oid` 为 layer oid，可直接用于属性/detail |
| `lookin_get_details` | 读 | 批量拉取属性、截图、frame/bounds/alpha、可选 subitems |
| `lookin_get_attributes` | 读 | built-in 与 custom 属性组，含 `identifier`、`attrType`、`value`、`setterSelector` |
| `lookin_get_screenshot` | 读 | 指定 view 或 key window 的 PNG 截图 |
| `lookin_get_current_vc` | 读 | 按面积/深度排序的当前可见 VC，区分业务 VC 与 overlay |
| `lookin_get_object` | 读 | 对象 class、class chain、地址、ivar traces |
| `lookin_list_selectors` | 读 | 某个 class 的 selector 列表 |
| `lookin_set_attribute` | 写 | 修改 built-in 属性；需开启写权限；支持 `dryRun` |
| `lookin_set_custom_attribute` | 写 | 修改 `lookin_customDebugInfos` 自定义属性 |
| `lookin_invoke_selector` | 写 + invoke | 调用无参 selector；需开启 invoke 且命中白名单 |
| `lookin_set_gesture_recognizer_enabled` | 写 | 启用/禁用手势识别器 |

`oid` 的语义：hierarchy 节点的顶层 `oid` 是 **layer oid**（与 LookinServer 的属性/detail 接口一致）。节点里同时包含 `view.oid` / `layer.oid`；`lookin_get_attributes`、`lookin_get_details`、`lookin_get_screenshot` 也接受 view oid，并会自动解析为对应的 layer oid。

## 写操作安全

默认只读。写能力需要显式开启：

- **Allow MCP writes**：允许 `lookin_set_attribute`、`lookin_set_custom_attribute`、`lookin_set_gesture_recognizer_enabled`；
- **Allow MCP invoke**：在上面的基础上，额外允许 `lookin_invoke_selector`；
- **Invoke allowlist**：每行一个无参 selector，默认空。只有白名单内的 selector 才会被调用。

约束：

- `lookin_set_attribute` 只接受 `lookin_get_attributes` 返回的 `identifier`，setter 由 `LookinDashboardBlueprint` 解析；
- `lookin_invoke_selector` 只允许无参 selector（不能包含 `:`），且会先确认该 selector 存在于目标对象；
- 所有写操作默认串行执行；
- 修改只作用于运行时对象，不会改写源码。

## 安全模型

- 仅绑定 `127.0.0.1`；
- 校验 `Host` 与 `Origin`，非本地来源返回 403；
- 请求体上限 1 MB；
- v1 不提供 token；威胁模型是同一台机器上的其他本地进程。若后续需要多租户或远程访问，应增加 bearer token 与 TLS；
- handshake 文件 `~/Library/Application Support/Lookin/mcp-handshake.json` 以 `0600` 权限写入，内容包含地址、端口、pid、协议版本与权限开关。

## 已知限制

- **单一 active target**：底层 PeerTalk 通道同一时间只服务一个目标 App；用 `lookin_list_targets` 与 `lookin_select_target` 切换。
- **目标 App 必须在前台**：处于后台时 LookinServer 无法执行代码。
- **日志流与性能数据**：v1 不包含。日志流需要扩展 LookinServer 线协议并提升协议版本，另行立项。
- **MCP 与 UI 并发**：MCP 执行 detail/screenshot 期间会暂停 UI 的自动 detail 刷新；hierarchy 请求仍可能与 UI 轮询撞车，此时 MCP 会自动重试一次。
- **App 必须保持运行**：MCP server 随 Lookin.app 生命周期存在；开启 MCP 后关闭最后一个窗口不会退出 App。

## 验证

构建：

```bash
cd Lookin
LOOKIN_CODESIGN_IDENTITY="-" Scripts/build-app.sh
```

单元测试（不需要启动 App，也不需要连接 iOS 目标）：

```bash
xcodebuild test -workspace Lookin.xcworkspace -scheme LookinClient \
  -configuration Debug -destination 'platform=macOS'
```

协议冒烟（需 App 已启动并开启 MCP）：

```bash
Scripts/mcp-smoke.sh 47200
```

脚本会依次验证：

- legacy `initialize` + `tools/list`（Codex 路径）；
- modern `server/discover` + `tools/list`（Claude Code 路径）；
- modern `tools/call lookin_get_status`；
- legacy `tools/call lookin_list_targets`。

端到端建议：

1. 启动一个集成 LookinServer 的 App（可用 `LookinServer/LookinDemo/OC_Pod`）。
2. `lookin_list_targets` → `lookin_get_hierarchy` → `lookin_get_attributes`。
3. 开启写权限后，先 `dryRun: true`，再真实修改一个无害属性（例如 `vl_v_o` / `opacity`），读取确认后恢复。
4. 开启 invoke 权限并加入白名单，先 `dryRun` 再调用一个无参 selector。

## 故障排查

| 现象 | 排查 |
|---|---|
| `no_target` | App 未集成 LookinServer，或处于后台；确认前台后重试 |
| `target_not_selected` | 连接了多个 App；先调用 `lookin_list_targets` + `lookin_select_target` |
| `write_disabled` / `invoke_disabled` | 在 **MCP Server…** 中开启对应开关 |
| `selector_not_allowed` | 把 selector 加入 invoke 白名单 |
| `object_not_found` | 对象已释放或层级已变化；重新调用 `lookin_get_hierarchy` |
| `server_version_mismatch` | LookinServer 与 Lookin.app 版本不兼容；升级任一端 |
| 端口被占用 | server 会自动顺延 47200–47209；以设置窗口显示的地址为准 |

## 与旧 REST bridge 的关系

LookinServer 1.3.0 引入了 `Src/Main/Server/HTTP/` 的 REST bridge（`127.0.0.1:47190`），供外部 `lookin-mcp-ios` npm 包使用。

- 1.3.1：标记 deprecated，保留兼容；
- App 内置 MCP 发布后：推荐所有 Lookin.app 用户迁移到本文档的配置；
- 1.4.0：删除 REST bridge。届时外部 npm 包不再兼容本仓库的 LookinServer；纯命令行/无 App 场景需要另行评估。

线协议版本 `LOOKIN_SERVER_VERSION` 不因该删除而变化。
