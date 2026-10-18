//
//  LKMCPToolDefinitions.swift
//  Lookin
//
//  MCP tool 的静态定义。与执行层分离，便于单元测试校验 tool 契约。
//

import Foundation

enum LKMCPToolDefinitions {

    static let all: [[String: Any]] = [
        tool("lookin_list_targets",
             "List all iOS apps currently reachable by Lookin. Returns id, name, bundle, device, os, screen and server version. Call this first when multiple apps are connected.",
             schema([:], required: []), annotations: readAnnotations),
        tool("lookin_select_target",
             "Select the target app that subsequent lookin_* tools operate on.",
             schema(["targetId": targetId], required: ["targetId"]), annotations: readAnnotations),
        tool("lookin_get_status",
             "Return MCP server status: endpoint, protocol versions, selected target, and whether writes/invoke are enabled.",
             schema([:], required: []), annotations: readAnnotations),
        tool("lookin_get_hierarchy",
             "Get the UI view hierarchy of the selected app. Each node contains oid, title, frame, hidden, alpha, view/layer objects and children. Use oid with other tools.",
             schema([
                "maxDepth": property("number", "Maximum depth. Omit or pass 0 for unlimited.")
             ], required: []), annotations: readAnnotations),
        tool("lookin_get_details",
             "Fetch rich details for one or more display items: attributes, screenshots, frame/bounds/alpha and optionally subitems. Prefer this when you need both attrs and a screenshot.",
             schema([
                "oids": ["type": "array", "items": ["type": "number"], "description": "Display item oids."],
                "screenshot": ["type": "string", "enum": ["none", "solo", "group"]],
                "attrs": ["type": "string", "enum": ["auto", "need", "none"]],
                "basis": property("boolean", "Also return frame, bounds, hidden and alpha."),
                "subitems": property("boolean", "Also return the item's subitems.")
             ], required: ["oids"]), annotations: readAnnotations),
        tool("lookin_get_attributes",
             "Get all attributes of a view/layer, grouped by group and section. Each attribute includes identifier, attrType, value and setterSelector.",
             schema(["oid": oid], required: ["oid"]), annotations: readAnnotations),
        tool("lookin_get_screenshot",
             "Capture a PNG screenshot of a view. If oid is omitted, captures the key window.",
             schema(["oid": oid], required: []), annotations: readAnnotations),
        tool("lookin_get_current_vc",
             "Detect the currently visible view controllers, ranked by area and depth. Returns business candidates and overlay-like controllers separately.",
             schema([:], required: []), annotations: readAnnotations),
        tool("lookin_get_object",
             "Get object metadata for an oid: class name, class chain, memory address and ivar traces.",
             schema(["oid": oid], required: ["oid"]), annotations: readAnnotations),
        tool("lookin_list_selectors",
             "List selectors of a class. Use hasArg=false before lookin_invoke_selector.",
             schema([
                "className": property("string", "Class name, e.g. UILabel."),
                "hasArg": property("boolean", "Whether the selector takes an argument.")
             ], required: ["className"]), annotations: readAnnotations),
        tool("lookin_set_attribute",
             "Modify a built-in UI attribute. Requires writes to be enabled in Lookin settings. The attributeIdentifier must come from lookin_get_attributes. Supports dryRun.",
             schema([
                "oid": oid,
                "attributeIdentifier": property("string", "Attribute identifier from lookin_get_attributes."),
                "value": value,
                "dryRun": dryRun
             ], required: ["oid", "attributeIdentifier", "value"]), annotations: writeAnnotations),
        tool("lookin_set_custom_attribute",
             "Modify a user-custom attribute (lookin_customDebugInfos). Requires writes to be enabled. Supports dryRun.",
             schema([
                "oid": oid,
                "attributeIdentifier": property("string", "Custom attribute identifier from lookin_get_attributes."),
                "value": value,
                "dryRun": dryRun
             ], required: ["oid", "attributeIdentifier", "value"]), annotations: writeAnnotations),
        tool("lookin_invoke_selector",
             "Invoke a no-argument selector on an object. Requires invoke to be enabled and the selector to be in the allowlist in Lookin settings. Supports dryRun.",
             schema([
                "oid": oid,
                "selector": property("string", "No-argument selector name, e.g. reloadData."),
                "dryRun": dryRun
             ], required: ["oid", "selector"]), annotations: invokeAnnotations),
        tool("lookin_set_gesture_recognizer_enabled",
             "Enable or disable a gesture recognizer. Requires writes to be enabled.",
             schema([
                "oid": oid,
                "enabled": property("boolean", "Desired enabled state.")
             ], required: ["oid", "enabled"]), annotations: writeAnnotations)
    ]

    static var names: [String] {
        all.compactMap { $0["name"] as? String }
    }

    // MARK: - Schema helpers

    private static let targetId = property("string", "Target id returned by lookin_list_targets.")
    private static let oid = property("number", "Object id from lookin_get_hierarchy.")
    private static let value = ["description": "New value. Type depends on the attribute's attrType."]
    private static let dryRun = property("boolean", "If true, validate and return the resolved modification without applying it.")

    private static let readAnnotations: [String: Any] = ["readOnlyHint": true]
    private static let writeAnnotations: [String: Any] = ["readOnlyHint": false, "destructiveHint": false]
    private static let invokeAnnotations: [String: Any] = ["readOnlyHint": false, "destructiveHint": true]

    private static func property(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    private static func schema(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static func tool(_ name: String, _ description: String,
                             _ inputSchema: [String: Any],
                             annotations: [String: Any]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema, "annotations": annotations]
    }
}
