import XCTest

final class LKMCPRouterTests: XCTestCase {

    private static let fakeTools: [[String: Any]] = [
        ["name": "lookin_get_status",
         "description": "fake",
         "inputSchema": ["type": "object", "properties": [String: Any](), "required": [String](), "additionalProperties": false],
         "annotations": ["readOnlyHint": true]]
    ]

    private func makeRouter(callTool: @escaping (String, [String: Any]) async -> LKToolCallResult = { _, _ in
        LKToolCallResult.text(["ok": true])
    }) -> LKMCPRouter {
        LKMCPRouter(dependencies: LKMCPRouterDependencies(
            toolDefinitions: { Self.fakeTools },
            callTool: callTool,
            serverVersion: { "9.9.9" }
        ))
    }

    private func json(_ response: LKHTTPResponse?) throws -> [String: Any] {
        let body = try XCTUnwrap(response?.body, "Expected a response body")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func result(_ response: LKHTTPResponse?) throws -> [String: Any] {
        try XCTUnwrap(try json(response)["result"] as? [String: Any])
    }

    private func error(_ response: LKHTTPResponse?) throws -> [String: Any] {
        try XCTUnwrap(try json(response)["error"] as? [String: Any])
    }

    // MARK: - Envelope

    func testNotificationProducesNoResponse() async {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            headers: [:]
        )
        XCTAssertNil(response)
    }

    func testRejectsNonJSONRPCRequest() async {
        let response = await makeRouter().handle(["id": 1, "method": "ping"], headers: [:])
        XCTAssertEqual(try error(response)["code"] as? Int, -32600)
    }

    func testUnknownMethod() async {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 7, "method": "resources/list"],
            headers: [:]
        )
        XCTAssertEqual(try error(response)["code"] as? Int, -32601)
        XCTAssertEqual(try json(response)["id"] as? Int, 7)
    }

    // MARK: - Legacy handshake

    func testInitializeNegotiatesRequestedVersion() async throws {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2025-06-18"]],
            headers: [:]
        )
        let result = try result(response)
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["version"] as? String, "9.9.9")
        XCTAssertNotNil(result["capabilities"] as? [String: Any])
        XCTAssertNil(result["resultType"])
    }

    func testInitializeFallsBackForUnsupportedVersion() async throws {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "1999-01-01"]],
            headers: [:]
        )
        XCTAssertEqual(try result(response)["protocolVersion"] as? String, "2025-11-25")
    }

    func testInitializeSupportsOldestSpecVersion() async throws {
        // 初版协议（2024-11-05）仍被部分旧客户端使用，握手必须原样接受。
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2024-11-05"]],
            headers: [:]
        )
        XCTAssertEqual(try result(response)["protocolVersion"] as? String, "2024-11-05")
    }

    func testPingReturnsEmptyResult() async throws {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 2, "method": "ping"],
            headers: [:]
        )
        XCTAssertEqual(response?.status, 200)
        XCTAssertTrue(try result(response).isEmpty)
    }

    // MARK: - Modern handshake

    func testServerDiscoverReturnsModernShape() async throws {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 3, "method": "server/discover"],
            headers: [:]
        )
        let result = try result(response)
        XCTAssertEqual(result["supportedVersions"] as? [String], ["2026-07-28"])
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "lookin-mcp")
    }

    func testModernToolsListAddsCacheHints() async throws {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 4, "method": "tools/list"],
            headers: ["mcp-protocol-version": "2026-07-28", "mcp-method": "tools/list"]
        )
        let result = try result(response)
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["ttlMs"] as? Int, 60000)
        XCTAssertEqual(result["cacheScope"] as? String, "private")
        XCTAssertEqual((result["tools"] as? [[String: Any]])?.count, 1)
    }

    func testLegacyToolsListHasNoCacheHints() async throws {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 5, "method": "tools/list"],
            headers: [:]
        )
        let result = try result(response)
        XCTAssertNil(result["resultType"])
        XCTAssertNil(result["ttlMs"])
        XCTAssertNil(result["cacheScope"])
    }

    func testModernRequestRequiresProtocolVersionHeader() async throws {
        // 现代模式由 _meta 版本判断，但缺少 MCP-Protocol-Version 头仍应拒绝。
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 6, "method": "tools/list",
             "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]],
            headers: ["mcp-method": "tools/list"]
        )
        XCTAssertEqual(response?.status, 400)
        XCTAssertEqual(try error(response)["code"] as? Int, -32020)
    }

    func testMcpMethodHeaderAloneFallsBackToLegacy() async throws {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 60, "method": "tools/list"],
            headers: ["mcp-method": "tools/list"]
        )
        XCTAssertEqual(response?.status, 200)
        XCTAssertNil(try result(response)["resultType"])
    }

    func testModernRequestRejectsMethodMismatch() async throws {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 7, "method": "tools/list"],
            headers: ["mcp-protocol-version": "2026-07-28", "mcp-method": "tools/call"]
        )
        XCTAssertEqual(response?.status, 400)
        XCTAssertEqual(try error(response)["code"] as? Int, -32020)
    }

    func testModernToolsCallRejectsNameMismatch() async throws {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 8, "method": "tools/call",
             "params": ["name": "lookin_get_status"]],
            headers: [
                "mcp-protocol-version": "2026-07-28",
                "mcp-method": "tools/call",
                "mcp-name": "lookin_get_hierarchy"
            ]
        )
        XCTAssertEqual(response?.status, 400)
        XCTAssertEqual(try error(response)["code"] as? Int, -32020)
    }

    // MARK: - tools/call

    func testToolsCallRequiresName() async throws {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": [String: Any]()],
            headers: [:]
        )
        XCTAssertEqual(try error(response)["code"] as? Int, -32602)
    }

    func testToolsCallForwardsNameAndArguments() async throws {
        var received: (String, [String: Any])?
        let router = makeRouter { name, arguments in
            received = (name, arguments)
            return LKToolCallResult.text(["invoked": name])
        }
        let response = await router.handle(
            ["jsonrpc": "2.0", "id": 10, "method": "tools/call",
             "params": ["name": "lookin_get_status", "arguments": ["verbose": true]]],
            headers: [:]
        )
        let result = try result(response)
        XCTAssertEqual(received?.0, "lookin_get_status")
        XCTAssertEqual(received?.1["verbose"] as? Bool, true)
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertNotNil(result["content"] as? [[String: Any]])
        XCTAssertNil(result["resultType"])
    }

    func testModernToolsCallAddsResultType() async throws {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 11, "method": "tools/call",
             "params": ["name": "lookin_get_status"]],
            headers: [
                "mcp-protocol-version": "2026-07-28",
                "mcp-method": "tools/call",
                "mcp-name": "lookin_get_status"
            ]
        )
        XCTAssertEqual(response?.status, 200)
        XCTAssertEqual(try result(response)["resultType"] as? String, "complete")
    }

    func testModernDetectionViaMetaVersion() async throws {
        let response = await makeRouter().handle(
            ["jsonrpc": "2.0", "id": 12, "method": "tools/list",
             "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]],
            headers: [
                "mcp-protocol-version": "2026-07-28",
                "mcp-method": "tools/list"
            ]
        )
        XCTAssertEqual(try result(response)["resultType"] as? String, "complete")
    }
}
