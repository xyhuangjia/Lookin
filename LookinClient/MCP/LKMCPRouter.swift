//
//  LKMCPRouter.swift
//  Lookin
//
//  双版本 JSON-RPC 路由。依赖通过 LKMCPRouterDependencies 注入，
//  使路由逻辑可以脱离 App 运行环境做单元测试。
//

import Foundation

struct LKMCPRouterDependencies {
    let toolDefinitions: () -> [[String: Any]]
    let callTool: (String, [String: Any]) async -> LKToolCallResult
    let serverVersion: () -> String
}

final class LKMCPRouter {

    private let dependencies: LKMCPRouterDependencies

    init(dependencies: LKMCPRouterDependencies) {
        self.dependencies = dependencies
    }

    func handle(_ message: [String: Any], headers: [String: String]) async -> LKHTTPResponse? {
        guard let method = message["method"] as? String else {
            // JSON-RPC response from a client is not expected in this server.
            return nil
        }
        guard message["jsonrpc"] as? String == "2.0" else {
            return errorResponse(id: message["id"], code: -32600, message: "Invalid Request")
        }

        let rawId = message["id"]
        if rawId == nil || rawId is NSNull {
            // JSON-RPC notification: notifications/initialized, notifications/cancelled, ...
            return nil
        }
        guard let id = rawId else { return nil }

        let params = message["params"] as? [String: Any] ?? [:]
        let headerVersion = headers["mcp-protocol-version"]
        let metaVersion = (params["_meta"] as? [String: Any])?["io.modelcontextprotocol/protocolVersion"] as? String
        let modern = LKMCPProtocol.isModern(method: method,
                                            headerVersion: headerVersion,
                                            metaVersion: metaVersion)

        if modern, method != "server/discover" {
            if let mismatch = LKMCPProtocol.modernHeaderError(method: method,
                                                              headers: headers,
                                                              params: params) {
                return errorResponse(id: id, code: -32020, message: mismatch, status: 400)
            }
        }

        switch method {
        case "initialize":
            return legacyInitialize(id: id, params: params)
        case "server/discover":
            return modernDiscover(id: id)
        case "ping":
            return successResponse(id: id, result: [:], modern: false)
        case "tools/list":
            return toolsList(id: id, modern: modern)
        case "tools/call":
            return await toolsCall(id: id, params: params, modern: modern)
        default:
            return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Methods

    private func legacyInitialize(id: Any, params: [String: Any]) -> LKHTTPResponse {
        let requested = params["protocolVersion"] as? String
        let negotiated = LKMCPProtocol.negotiatedLegacyVersion(requested: requested)
        let result: [String: Any] = [
            "protocolVersion": negotiated,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": serverInfo
        ]
        return successResponse(id: id, result: result, modern: false)
    }

    private func modernDiscover(id: Any) -> LKHTTPResponse {
        let result: [String: Any] = [
            "supportedVersions": [LKMCPProtocol.modernVersion],
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": serverInfo,
            "resultType": "complete"
        ]
        return successResponse(id: id, result: result, modern: true)
    }

    private func toolsList(id: Any, modern: Bool) -> LKHTTPResponse {
        var result: [String: Any] = ["tools": dependencies.toolDefinitions()]
        if modern {
            result["resultType"] = "complete"
            result["ttlMs"] = 60000
            result["cacheScope"] = "server"
        }
        return successResponse(id: id, result: result, modern: modern)
    }

    private func toolsCall(id: Any, params: [String: Any], modern: Bool) async -> LKHTTPResponse {
        guard let name = params["name"] as? String, !name.isEmpty else {
            return errorResponse(id: id, code: -32602, message: "tools/call requires params.name.")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let toolResult = await dependencies.callTool(name, arguments)
        var result: [String: Any] = [
            "content": toolResult.content,
            "isError": toolResult.isError
        ]
        if modern {
            result["resultType"] = "complete"
        }
        return successResponse(id: id, result: result, modern: modern)
    }

    // MARK: - Responses

    private var serverInfo: [String: Any] {
        ["name": "lookin-mcp", "version": dependencies.serverVersion()]
    }

    private func successResponse(id: Any, result: [String: Any], modern: Bool) -> LKHTTPResponse {
        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        if modern, result["resultType"] == nil {
            payload["result"] = result.merging(["resultType": "complete"]) { current, _ in current }
        }
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return LKHTTPResponse(status: 200, body: body)
    }

    private func errorResponse(id: Any?, code: Int, message: String, status: Int = 200) -> LKHTTPResponse {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id = id {
            payload["id"] = id
        } else {
            payload["id"] = NSNull()
        }
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return LKHTTPResponse(status: status, body: body)
    }
}
