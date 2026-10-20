//
//  LKMCPWireProtocol.swift
//  Lookin
//
//  MCP 传输层与协议层的纯逻辑：HTTP 解析、来源校验、协议版本协商、
//  tool 结果模型与属性值解析。
//
//  该文件不依赖 ReactiveObjC / LookinShared / Lookin 的应用类，因此同时被
//  LookinClient 与 LookinMCPTests 两个 target 编译，便于单元测试。
//  仅使用 AppKit 的 NSPoint / NSSize / NSRect 几何类型。
//

import Foundation
import AppKit

// MARK: - HTTP model

struct LKHTTPRequest: Equatable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct LKHTTPResponse {
    let status: Int
    let body: Data?
}

enum LKHTTPParseResult {
    case incomplete
    case invalid(Int)
    case complete(LKHTTPRequest)
}

enum LKHTTPParser {

    /// 单个请求体上限
    static let maxBodySize = 1_048_576
    /// 缓冲区上限：超过后即使请求头仍不完整也直接返回 413
    static let maxBufferedSize = 1_200_000

    static func parse(_ data: Data) -> LKHTTPParseResult {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            return .incomplete
        }
        let headerData = data.subdata(in: 0..<separator.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return .invalid(400)
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid(400) }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return .invalid(400) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else { return .invalid(400) }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        guard contentLength <= maxBodySize else { return .invalid(413) }

        let bodyStart = separator.upperBound
        guard data.count >= bodyStart + contentLength else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return .complete(LKHTTPRequest(method: parts[0].uppercased(),
                                       path: parts[1],
                                       headers: headers,
                                       body: body))
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "Error"
        }
    }

    /// 去掉查询串与 fragment。部分客户端会在路径后追加参数（如 `/mcp?transport=http`），
    /// 路由匹配前先归一化，避免被 404。
    static func normalizedPath(_ path: String) -> String {
        let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? path.endIndex
        return String(path[..<cut])
    }
}

// MARK: - Request payload

enum LKMCPPayload {
    case single([String: Any])
    case batch([[String: Any]])

    /// 解析 POST body：单个 JSON-RPC 消息，或 2025-06-18 之前客户端可能使用的 batch 数组。
    /// 返回 nil 表示 body 不是合法的 JSON-RPC 载荷。
    static func parse(_ data: Data) -> LKMCPPayload? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let message = json as? [String: Any] {
            return .single(message)
        }
        if let messages = json as? [[String: Any]] {
            return .batch(messages)
        }
        return nil
    }
}

// MARK: - Request policy

enum LKMCPRequestPolicy {

    /// 仅允许 loopback。缺少 Origin / Host 视为本地客户端（curl、测试脚本）。
    /// Host / Origin 大小写不敏感；IPv6 loopback 与省略端口的写法也放行——
    /// 监听本身已绑定 127.0.0.1，这里只需挡掉明确的非本机来源。
    static func allows(origin: String?, host: String?, port: UInt16) -> Bool {
        if let origin = origin, !origin.isEmpty {
            let lowered = origin.lowercased()
            let allowed = ["http://127.0.0.1:\(port)",
                           "http://localhost:\(port)",
                           "http://[::1]:\(port)"]
            guard allowed.contains(lowered) else { return false }
        }
        if let host = host, !host.isEmpty {
            guard isLoopbackHost(host, port: port) else { return false }
        }
        return true
    }

    static func isLoopbackHost(_ host: String, port: UInt16) -> Bool {
        let lowered = host.lowercased()
        let names = ["127.0.0.1", "localhost", "[::1]", "::1"]
        return names.contains { lowered == $0 || lowered == "\($0):\(port)" }
    }
}

// MARK: - Protocol versions

enum LKMCPProtocol {

    static let modernVersion = "2026-07-28"
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let defaultLegacyVersion = "2025-11-25"

    /// 客户端请求的版本受支持则原样返回，否则回落到默认 legacy 版本。
    static func negotiatedLegacyVersion(requested: String?) -> String {
        guard let requested = requested, legacyVersions.contains(requested) else {
            return defaultLegacyVersion
        }
        return requested
    }

    static func isModern(method: String, headerVersion: String?, metaVersion: String?) -> Bool {
        method == "server/discover"
            || headerVersion == modernVersion
            || metaVersion == modernVersion
    }

    /// 返回 nil 表示校验通过；否则返回 400 + -32020 的错误消息。
    static func modernHeaderError(method: String,
                                  headers: [String: String],
                                  params: [String: Any]) -> String? {
        guard headers["mcp-protocol-version"] == modernVersion else {
            return "MCP-Protocol-Version must be \(modernVersion)."
        }
        guard headers["mcp-method"] == method else {
            return "Mcp-Method does not match the JSON-RPC method."
        }
        if method == "tools/call" {
            let name = params["name"] as? String ?? ""
            guard headers["mcp-name"] == name else {
                return "Mcp-Name does not match tools/call params.name."
            }
        }
        return nil
    }
}

// MARK: - Errors

struct LKMCPServiceError: Error, Equatable {
    let code: String
    let reason: String
    let suggestion: String

    var json: [String: Any] {
        ["code": code, "reason": reason, "suggestion": suggestion]
    }

    static func internalError(_ reason: String) -> LKMCPServiceError {
        LKMCPServiceError(code: "internal_error", reason: reason, suggestion: "Check the Lookin console for details.")
    }

    static func from(_ error: Error) -> LKMCPServiceError {
        let nsError = error as NSError
        let suggestion = nsError.localizedRecoverySuggestion ?? ""
        switch nsError.code {
        case -403:
            return .init(code: "no_connection",
                         reason: "The iOS app is not connected.",
                         suggestion: "Keep the target app in the foreground and reload Lookin.")
        case -404, -405:
            return .init(code: "timeout",
                         reason: "The iOS app did not respond in time.",
                         suggestion: "Make sure the app is in the foreground and not paused at a breakpoint.")
        case -406:
            return .init(code: "request_superseded",
                         reason: "The request was superseded by another request of the same type.",
                         suggestion: "Retry the tool call.")
        case -407:
            return .init(code: "app_background",
                         reason: "The iOS app is in the background and cannot execute code.",
                         suggestion: "Bring the target app to the foreground and retry.")
        case -500:
            return .init(code: "object_not_found",
                         reason: "The target object no longer exists.",
                         suggestion: "Reload the hierarchy and use a fresh oid.")
        case -600, -601:
            return .init(code: "server_version_mismatch",
                         reason: nsError.localizedDescription,
                         suggestion: suggestion.isEmpty ? "Update LookinServer or Lookin." : suggestion)
        default:
            return .init(code: "internal_error",
                         reason: nsError.localizedDescription.isEmpty ? "Unknown error." : nsError.localizedDescription,
                         suggestion: suggestion)
        }
    }
}

// MARK: - Tool result

struct LKToolCallResult {
    let content: [[String: Any]]
    let isError: Bool

    static func text(_ object: Any) -> LKToolCallResult {
        let data: Data
        if let dict = object as? [String: Any] {
            data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data("{}".utf8)
        } else if let array = object as? [[String: Any]] {
            data = (try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys])) ?? Data("[]".utf8)
        } else {
            data = Data(String(describing: object).utf8)
        }
        return LKToolCallResult(content: [["type": "text", "text": String(data: data, encoding: .utf8) ?? "{}"]],
                                isError: false)
    }

    static func error(_ error: LKMCPServiceError) -> LKToolCallResult {
        let data = (try? JSONSerialization.data(withJSONObject: error.json, options: [.sortedKeys])) ?? Data()
        return LKToolCallResult(content: [["type": "text", "text": String(data: data, encoding: .utf8) ?? "{}"]],
                                isError: true)
    }
}

// MARK: - Attribute value parsing

enum LKAttributeValueParser {

    /// - Parameter attrTypeRaw: `LookinAttrType.rawValue`。这里只用 Int，
    ///   避免协议层依赖 LookinShared 的 ObjC 枚举。
    static func parse(_ raw: Any?, attrTypeRaw: Int) throws -> Any? {
        if raw == nil || raw is NSNull { return nil }
        switch attrTypeRaw {
        case 2...13, 25, 26:
            guard let number = numberValue(raw) else {
                throw invalidValue("Expected a number for attrType \(attrTypeRaw).")
            }
            return NSNumber(value: number)
        case 14:
            return NSNumber(value: boolValue(raw))
        case 15, 16, 24, 28, 29:
            guard let string = raw as? String else {
                throw invalidValue("Expected a string for attrType \(attrTypeRaw).")
            }
            return string
        case 27:
            var comps = try numberArray(raw, minCount: 3)
            if comps.contains(where: { $0 > 1 }) {
                comps = comps.map { $0 / 255.0 }
            }
            if comps.count == 3 { comps.append(1) }
            return comps.prefix(4).map { NSNumber(value: $0) }
        case 17:
            let comps = try numberArray(raw, minCount: 2)
            return NSValue(point: NSPoint(x: comps[0], y: comps[1]))
        case 19:
            let comps = try numberArray(raw, minCount: 2)
            return NSValue(size: NSSize(width: comps[0], height: comps[1]))
        case 20:
            let comps = try rectComponents(raw)
            return NSValue(rect: NSRect(x: comps[0], y: comps[1], width: comps[2], height: comps[3]))
        case 30, 31:
            return raw
        default:
            throw LKMCPServiceError(code: "unsupported_attr_type",
                                    reason: "attrType \(attrTypeRaw) is not writable through MCP yet.",
                                    suggestion: "Use a number, string, BOOL, color, CGPoint, CGSize or CGRect attribute.")
        }
    }

    static func invalidValue(_ reason: String) -> LKMCPServiceError {
        .init(code: "invalid_value", reason: reason, suggestion: "Check the value shape against the attribute's attrType.")
    }

    static func numberValue(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let number = raw as? Double { return number }
        if let number = raw as? Int { return Double(number) }
        if let string = raw as? String { return Double(string) }
        return nil
    }

    static func boolValue(_ raw: Any?) -> Bool {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String {
            return ["1", "true", "yes", "enable", "enabled"].contains(string.lowercased())
        }
        return false
    }

    static func numberArray(_ raw: Any?, minCount: Int) throws -> [Double] {
        if let array = raw as? [Any] {
            let numbers = array.compactMap { numberValue($0) }
            guard numbers.count >= minCount else {
                throw invalidValue("Expected at least \(minCount) numbers.")
            }
            return numbers
        }
        if let dict = raw as? [String: Any] {
            let ordered = ["x", "y", "width", "height"].compactMap { numberValue(dict[$0]) }
            guard ordered.count >= minCount else {
                throw invalidValue("Expected x/y/width/height numbers.")
            }
            return ordered
        }
        if let string = raw as? String {
            let normalized = string.replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: ";", with: " ")
            let numbers = normalized.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
            guard numbers.count >= minCount else {
                throw invalidValue("Expected at least \(minCount) numbers.")
            }
            return numbers
        }
        throw invalidValue("Expected an array or an {x,y,width,height} object.")
    }

    static func rectComponents(_ raw: Any?) throws -> [Double] {
        if let dict = raw as? [String: Any],
           let x = numberValue(dict["x"]), let y = numberValue(dict["y"]),
           let width = numberValue(dict["width"]), let height = numberValue(dict["height"]) {
            return [x, y, width, height]
        }
        return try numberArray(raw, minCount: 4)
    }
}
