//
//  LKMCPService.swift
//  Lookin
//
//  MCP tool 的实现层。所有数据都通过 App 自己的 PeerTalk channel 获取，
//  不启动 lookinctl，也不经过 LookinServer 的 HTTP bridge。
//

import Foundation
import AppKit

// MARK: - Service

final class LKMCPService: NSObject {

    static let shared = LKMCPService()

    private static let activeTargetKey = "LKMCPService.activeTargetId"

    private var activeTarget: LKInspectableApp?
    private var lastHierarchy: LookinHierarchyInfo?

    // MARK: - Dispatch

    func callTool(name: String, arguments: [String: Any]) async -> LKToolCallResult {
        let gate = LKInspectionRequestGate.shared()!
        gate.beginMCPOperation()
        defer { gate.endMCPOperation() }

        do {
            switch name {
            case "lookin_list_targets":
                return try await handleListTargets()
            case "lookin_select_target":
                return try await handleSelectTarget(arguments)
            case "lookin_get_status":
                return LKToolCallResult.text(statusJSON())
            case "lookin_get_hierarchy":
                return try await handleGetHierarchy(arguments)
            case "lookin_get_details":
                return try await handleGetDetails(arguments)
            case "lookin_get_attributes":
                return try await handleGetAttributes(arguments)
            case "lookin_get_screenshot":
                return try await handleGetScreenshot(arguments)
            case "lookin_get_current_vc":
                return try await handleGetCurrentVC()
            case "lookin_get_object":
                return try await handleGetObject(arguments)
            case "lookin_list_selectors":
                return try await handleListSelectors(arguments)
            case "lookin_set_attribute":
                return try await handleSetAttribute(arguments, custom: false)
            case "lookin_set_custom_attribute":
                return try await handleSetAttribute(arguments, custom: true)
            case "lookin_invoke_selector":
                return try await handleInvokeSelector(arguments)
            case "lookin_set_gesture_recognizer_enabled":
                return try await handleSetGestureRecognizer(arguments)
            default:
                return .error(.init(code: "unknown_tool",
                                    reason: "Unknown tool: \(name)",
                                    suggestion: "Call tools/list to see the supported tools."))
            }
        } catch let error as LKMCPServiceError {
            return .error(error)
        } catch {
            return .error(.from(error))
        }
    }

    // MARK: - Status

    func statusJSON() -> [String: Any] {
        let manager = LKPreferenceManager.main()!
        let running = LKMCPServer.shared.isRunning
        let port = running ? LKMCPServer.shared.actualPort : UInt16(clamping: manager.mcpPort)
        var dict: [String: Any] = [
            "running": running,
            "port": port,
            "url": LKMCPServer.shared.endpointURL,
            "writesEnabled": manager.mcpAllowWrites,
            "invokeEnabled": manager.mcpAllowInvoke,
            "invokeAllowlistCount": (manager.mcpInvokeAllowlist() ?? []).count,
            "protocolVersions": [LKMCPProtocol.modernVersion] + LKMCPProtocol.legacyVersions
        ]
        if let app = activeTarget {
            dict["target"] = LKInspectionJSON.appInfoJSON(app.appInfo)
            dict["targetConnected"] = (app.channel != nil)
        } else {
            dict["target"] = NSNull()
            dict["targetConnected"] = false
        }
        return dict
    }

    // MARK: - Targets

    private func handleListTargets() async throws -> LKToolCallResult {
        let apps = try await fetchTargetApps()
        let result = apps.enumerated().map { index, app -> [String: Any] in
            var dict = LKInspectionJSON.appInfoJSON(app.appInfo)
            dict["index"] = index
            if dict["id"] == nil {
                dict["id"] = "index-\(index)"
            }
            if let error = app.serverVersionError as NSError? {
                dict["error"] = [
                    "code": error.code,
                    "reason": error.localizedDescription,
                    "suggestion": error.localizedRecoverySuggestion ?? ""
                ]
            }
            dict["selected"] = (app === activeTarget)
            return dict
        }
        return .text(["targets": result, "count": result.count])
    }

    private func handleSelectTarget(_ arguments: [String: Any]) async throws -> LKToolCallResult {
        let targetId = try requireString(arguments, "targetId")
        let apps = try await fetchTargetApps()

        var match: LKInspectableApp?
        for (index, app) in apps.enumerated() {
            if targetId == "index-\(index)" || targetId == "\(index)" {
                match = app
                break
            }
            if let info = app.appInfo,
               String(info.appInfoIdentifier) == targetId
                || info.appBundleIdentifier == targetId
                || info.appName == targetId {
                match = app
                break
            }
        }

        guard let app = match else {
            throw LKMCPServiceError(code: "target_not_found",
                                    reason: "No target matches \(targetId).",
                                    suggestion: "Call lookin_list_targets and use one of the returned ids.")
        }
        activeTarget = app
        lastHierarchy = nil
        UserDefaults.standard.set(targetId, forKey: Self.activeTargetKey)
        var dict = LKInspectionJSON.appInfoJSON(app.appInfo)
        dict["selected"] = true
        return .text(dict)
    }

    private func fetchTargetApps() async throws -> [LKInspectableApp] {
        let value = try await awaitSignalWithRetry {
            LKAppsManager.sharedInstance().fetchAppInfos(withImage: false, localInfos: nil)
        }
        let apps = (value as? [LKInspectableApp]) ?? []
        return apps.filter { $0.appInfo != nil || $0.serverVersionError != nil }
    }

    private func ensureTarget() async throws -> LKInspectableApp {
        if let app = activeTarget {
            if app.channel != nil { return app }
            activeTarget = nil
        }
        let apps = try await fetchTargetApps()
        if let saved = UserDefaults.standard.string(forKey: Self.activeTargetKey),
           let match = apps.first(where: { app in
               guard let info = app.appInfo else { return false }
               return String(info.appInfoIdentifier) == saved
                   || info.appBundleIdentifier == saved
                   || info.appName == saved
           }) {
            activeTarget = match
            return match
        }
        if apps.count == 1 {
            activeTarget = apps[0]
            return apps[0]
        }
        if apps.isEmpty {
            throw LKMCPServiceError(code: "no_target",
                                    reason: "No Lookin-instrumented iOS app is connected.",
                                    suggestion: "Run the app with LookinServer integrated, keep it in the foreground, then call lookin_list_targets.")
        }
        throw LKMCPServiceError(code: "target_not_selected",
                                reason: "Multiple apps are connected and no target has been selected.",
                                suggestion: "Call lookin_list_targets and then lookin_select_target.")
    }

    // MARK: - Read tools

    private func handleGetHierarchy(_ arguments: [String: Any]) async throws -> LKToolCallResult {
        let app = try await ensureTarget()
        let maxDepthRaw = optionalInt(arguments, "maxDepth") ?? 0
        let maxDepth = maxDepthRaw > 0 ? maxDepthRaw : Int.max
        let value = try await awaitSignalWithRetry { app.fetchHierarchyData() }
        guard let hierarchy = value as? LookinHierarchyInfo else {
            throw LKMCPServiceError.internalError("Unexpected hierarchy response.")
        }
        lastHierarchy = hierarchy
        return .text(LKInspectionJSON.hierarchyJSON(hierarchy, maxDepth: maxDepth))
    }

    private func handleGetDetails(_ arguments: [String: Any]) async throws -> LKToolCallResult {
        let app = try await ensureTarget()
        let oids = resolveLayerOids(try requireOids(arguments, "oids"))
        let screenshot = parseScreenshotType(optionalString(arguments, "screenshot") ?? "none")
        let attrs = parseAttrRequest(optionalString(arguments, "attrs") ?? "auto")
        let basis = optionalBool(arguments, "basis") ?? false
        let subitems = optionalBool(arguments, "subitems") ?? false
        let details = try await fetchDetails(app: app, oids: oids, screenshot: screenshot,
                                             attrs: attrs, basis: basis, subitems: subitems)
        return .text(details.map { LKInspectionJSON.detailJSON($0) })
    }

    private func handleGetAttributes(_ arguments: [String: Any]) async throws -> LKToolCallResult {
        let app = try await ensureTarget()
        let oid = try requireUInt(arguments, "oid")
        let resolvedOid = resolveLayerOids([oid]).first ?? oid
        let groups = try await fetchAttributeGroups(app: app, oid: resolvedOid)
        return .text([
            "oid": resolvedOid,
            "requestedOid": oid,
            "groups": LKInspectionJSON.attributeGroupsJSON(groups.builtIn),
            "customGroups": LKInspectionJSON.attributeGroupsJSON(groups.custom)
        ])
    }

    private func handleGetScreenshot(_ arguments: [String: Any]) async throws -> LKToolCallResult {
        let app = try await ensureTarget()
        var oid = optionalUInt(arguments, "oid")
        if let requested = oid {
            oid = resolveLayerOids([requested]).first ?? requested
        }
        var taskType = LookinStaticAsyncUpdateTaskType(rawValue: 1)! // solo
        if oid == nil {
            let hierarchy = try await fetchHierarchy(app)
            guard let root = preferredScreenshotRoot(in: hierarchy.displayItems ?? []) else {
                throw LKMCPServiceError(code: "screenshot_unavailable",
                                        reason: "No root window was found in the hierarchy.",
                                        suggestion: "Make sure the app is in the foreground and retry.")
            }
            let layerOid = root.layerObject?.oid
            let viewOid = root.viewObject?.oid
            let displayOid = root.displayingObject()?.oid
            guard let rootOid = layerOid ?? viewOid ?? displayOid else {
                throw LKMCPServiceError(code: "screenshot_unavailable",
                                        reason: "The root window has no object id.",
                                        suggestion: "Reload the hierarchy and retry.")
            }
            oid = rootOid
            taskType = LookinStaticAsyncUpdateTaskType(rawValue: 2)! // group
        }
        let details = try await fetchDetails(app: app, oids: [oid!], screenshot: taskType,
                                             attrs: .init(rawValue: 2)!, // notNeed
                                             basis: false, subitems: false)
        guard let detail = details.first,
              let image = detail.soloScreenshot ?? detail.groupScreenshot else {
            throw LKMCPServiceError(code: "screenshot_unavailable",
                                    reason: "LookinServer returned no screenshot for this view.",
                                    suggestion: "The view may be hidden or too large to capture. Try another oid.")
        }
        guard let png = LKInspectionJSON.pngData(from: image) else {
            throw LKMCPServiceError.internalError("Failed to encode the screenshot as PNG.")
        }
        return LKToolCallResult(content: [
            ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
            ["type": "text", "text": "Screenshot captured: \(Int(image.size.width))×\(Int(image.size.height))"]
        ], isError: false)
    }

    private func handleGetCurrentVC() async throws -> LKToolCallResult {
        let app = try await ensureTarget()
        let hierarchy = try await fetchHierarchy(app)
        let all = LKInspectionJSON.currentViewControllersJSON(hierarchy.displayItems ?? [])
        let business = all.filter { !($0["overlay"] as? Bool ?? false) }
        let overlays = all.filter { ($0["overlay"] as? Bool ?? false) }
        return .text([
            "app": LKInspectionJSON.appInfoJSON(app.appInfo),
            "current": business.first ?? all.first ?? [:],
            "businessCandidates": business,
            "overlays": overlays,
            "all": all
        ])
    }

    private func handleGetObject(_ arguments: [String: Any]) async throws -> LKToolCallResult {
        let app = try await ensureTarget()
        let oid = try requireUInt(arguments, "oid")
        let value = try await awaitSignalWithRetry { app.fetchObject(withOid: oid) }
        return .text(LKInspectionJSON.objectJSON(value as? LookinObject))
    }

    private func handleListSelectors(_ arguments: [String: Any]) async throws -> LKToolCallResult {
        let app = try await ensureTarget()
        let className = try requireString(arguments, "className")
        let hasArg = optionalBool(arguments, "hasArg") ?? false
        let value = try await awaitSignalWithRetry {
            app.fetchSelectorNames(withClass: className, hasArg: hasArg)
        }
        let selectors = (value as? [String]) ?? []
        return .text([
            "className": className,
            "hasArg": hasArg,
            "count": selectors.count,
            "selectors": selectors
        ])
    }

    // MARK: - Write tools

    private func handleSetAttribute(_ arguments: [String: Any], custom: Bool) async throws -> LKToolCallResult {
        let manager = LKPreferenceManager.main()!
        guard manager.mcpAllowWrites else {
            throw LKMCPServiceError(code: "write_disabled",
                                    reason: "MCP write access is disabled.",
                                    suggestion: "Enable \"Allow MCP writes\" in Lookin > MCP Server settings.")
        }
        let app = try await ensureTarget()
        let oid = try requireUInt(arguments, "oid")
        let identifier = try requireString(arguments, "attributeIdentifier")
        let dryRun = optionalBool(arguments, "dryRun") ?? false

        let hierarchy = try await fetchHierarchy(app, useCache: true)
        guard let item = findDisplayItem(in: hierarchy.displayItems ?? [], oid: oid) else {
            throw LKMCPServiceError(code: "object_not_found",
                                    reason: "No display item with oid \(oid) in the current hierarchy.",
                                    suggestion: "Call lookin_get_hierarchy again and use a fresh oid.")
        }

        let attributeOid = item.layerObject?.oid ?? oid
        let groups = try await fetchAttributeGroups(app: app, oid: attributeOid)
        let candidates = custom ? groups.custom : groups.builtIn
        guard let attribute = LKInspectionJSON.findAttribute(identifier: identifier, in: candidates) else {
            throw LKMCPServiceError(code: "attribute_not_found",
                                    reason: "Attribute \(identifier) was not found on oid \(oid).",
                                    suggestion: "Call lookin_get_attributes and use an identifier from the response.")
        }
        if custom != attribute.isUserCustom() {
            throw LKMCPServiceError(code: "wrong_tool",
                                    reason: custom ? "This is a built-in attribute, not a custom attribute."
                                                   : "This is a custom attribute. Use lookin_set_custom_attribute.",
                                    suggestion: custom ? "Use lookin_set_attribute." : "Use lookin_set_custom_attribute.")
        }

        let parsedValue = try LKAttributeValueParser.parse(arguments["value"],
                                                           attrTypeRaw: Int(attribute.attrType.rawValue))
        if dryRun {
            var preview: [String: Any] = [
                "dryRun": true,
                "oid": oid,
                "attributeIdentifier": identifier,
                "attrType": Int(attribute.attrType.rawValue),
                "value": LKInspectionJSON.jsonObject(parsedValue)
            ]
            let setter: Selector? = LookinDashboardBlueprint.setter(withAttrID: identifier)
            if let setter = setter {
                preview["setterSelector"] = NSStringFromSelector(setter)
            }
            if attribute.isUserCustom() {
                preview["customSetterID"] = attribute.customSetterID ?? ""
            }
            return .text(preview)
        }

        if attribute.isUserCustom() {
            let modification = LookinCustomAttrModification()
            modification.customSetterID = attribute.customSetterID
            modification.attrType = attribute.attrType
            modification.value = parsedValue
            let value = try await awaitSignalWithRetry { app.submitCustomModification(modification) }
            return .text([
                "ok": true,
                "oid": oid,
                "attributeIdentifier": identifier,
                "result": LKInspectionJSON.jsonObject(value)
            ])
        }

        let resolvedSetter: Selector? = LookinDashboardBlueprint.setter(withAttrID: identifier)
        guard let setter = resolvedSetter else {
            throw LKMCPServiceError(code: "unsupported_attribute",
                                    reason: "No setter is registered for attribute \(identifier).",
                                    suggestion: "This attribute is read-only in Lookin.")
        }

        let targetOid: UInt
        if LookinDashboardBlueprint.isUIViewProperty(withAttrID: identifier) {
            targetOid = item.viewObject?.oid ?? 0
        } else if LookinDashboardBlueprint.isWindowProperty(withAttrID: identifier) {
            targetOid = item.windowObject?.oid ?? 0
        } else {
            targetOid = item.layerObject?.oid ?? 0
        }
        guard targetOid != 0 else {
            throw LKMCPServiceError(code: "object_not_found",
                                    reason: "The target object for attribute \(identifier) is no longer available.",
                                    suggestion: "Reload the hierarchy and try again.")
        }

        let modification = LookinAttributeModification()
        modification.targetOid = targetOid
        modification.setterSelector = setter
        modification.attrType = attribute.attrType
        modification.value = parsedValue
        modification.clientReadableVersion = LKHelper.lookinReadableVersion()

        let value = try await awaitSignalWithRetry { app.submitInbuiltModification(modification) }
        if let detail = value as? LookinDisplayItemDetail {
            return .text([
                "ok": true,
                "oid": oid,
                "targetOid": targetOid,
                "attributeIdentifier": identifier,
                "detail": LKInspectionJSON.detailJSON(detail)
            ])
        }
        return .text([
            "ok": true,
            "oid": oid,
            "targetOid": targetOid,
            "attributeIdentifier": identifier,
            "result": LKInspectionJSON.jsonObject(value)
        ])
    }

    private func handleInvokeSelector(_ arguments: [String: Any]) async throws -> LKToolCallResult {
        let manager = LKPreferenceManager.main()!
        guard manager.mcpAllowWrites && manager.mcpAllowInvoke else {
            throw LKMCPServiceError(code: "invoke_disabled",
                                    reason: "MCP selector invocation is disabled.",
                                    suggestion: "Enable \"Allow MCP writes\" and \"Allow MCP invoke\" in Lookin > MCP Server settings.")
        }
        let selector = try requireString(arguments, "selector")
        guard !selector.contains(":") else {
            throw LKMCPServiceError(code: "selector_has_arguments",
                                    reason: "Only no-argument selectors can be invoked.",
                                    suggestion: "Pass a selector without a colon, e.g. reloadData.")
        }
        let allowlist: Set<String> = manager.mcpInvokeAllowlist() ?? []
        guard allowlist.contains(selector) else {
            throw LKMCPServiceError(code: "selector_not_allowed",
                                    reason: "Selector \(selector) is not in the allowlist.",
                                    suggestion: "Add it to the invoke allowlist in Lookin > MCP Server settings.")
        }
        let app = try await ensureTarget()
        let oid = try requireUInt(arguments, "oid")
        let objectValue = try await awaitSignalWithRetry { app.fetchObject(withOid: oid) }
        guard let object = objectValue as? LookinObject else {
            throw LKMCPServiceError(code: "object_not_found",
                                    reason: "No object with oid \(oid).",
                                    suggestion: "Use lookin_get_hierarchy to get a fresh oid.")
        }
        let className = LKInspectionJSON.objectClassName(object)
        let selectorsValue = try await awaitSignalWithRetry {
            app.fetchSelectorNames(withClass: className, hasArg: false)
        }
        let selectors = (selectorsValue as? [String]) ?? []
        guard selectors.contains(selector) else {
            throw LKMCPServiceError(code: "selector_not_found",
                                    reason: "\(className) does not expose a no-argument selector \(selector).",
                                    suggestion: "Call lookin_list_selectors with hasArg=false.")
        }
        let dryRun = optionalBool(arguments, "dryRun") ?? false
        if dryRun {
            return .text(["dryRun": true, "oid": oid, "selector": selector, "className": className])
        }
        let value = try await awaitSignalWithRetry { app.invokeMethod(withOid: oid, text: selector) }
        return .text([
            "ok": true,
            "oid": oid,
            "selector": selector,
            "result": LKInspectionJSON.jsonObject(value)
        ])
    }

    private func handleSetGestureRecognizer(_ arguments: [String: Any]) async throws -> LKToolCallResult {
        guard LKPreferenceManager.main()!.mcpAllowWrites else {
            throw LKMCPServiceError(code: "write_disabled",
                                    reason: "MCP write access is disabled.",
                                    suggestion: "Enable \"Allow MCP writes\" in Lookin > MCP Server settings.")
        }
        let app = try await ensureTarget()
        let oid = try requireUInt(arguments, "oid")
        let enabled = try requireBool(arguments, "enabled")
        let value = try await awaitSignalWithRetry {
            app.modifyGestureRecognizer(oid, toBeEnabled: enabled)
        }
        return .text([
            "ok": true,
            "oid": oid,
            "enabled": LKInspectionJSON.jsonObject(value)
        ])
    }

    // MARK: - Data helpers

    private func fetchHierarchy(_ app: LKInspectableApp, useCache: Bool = false) async throws -> LookinHierarchyInfo {
        if useCache, let cached = lastHierarchy { return cached }
        let value = try await awaitSignalWithRetry { app.fetchHierarchyData() }
        guard let hierarchy = value as? LookinHierarchyInfo else {
            throw LKMCPServiceError.internalError("Unexpected hierarchy response.")
        }
        lastHierarchy = hierarchy
        return hierarchy
    }

    /// 一次性拿到 built-in 与 custom 两组属性。
    /// AllAttrGroups 只返回 built-in；custom 属性只存在于 detail 的 customAttrGroupList 中。
    private func fetchAttributeGroups(app: LKInspectableApp, oid: UInt) async throws
        -> (builtIn: [LookinAttributesGroup], custom: [LookinAttributesGroup]) {
        let details = try await fetchDetails(app: app,
                                             oids: [oid],
                                             screenshot: LookinStaticAsyncUpdateTaskType(rawValue: 0)!,
                                             attrs: LookinDetailUpdateTaskAttrRequest(rawValue: 1)!,
                                             basis: false,
                                             subitems: false)
        guard let detail = details.first, detail.failureCode == 0 else {
            if details.first?.failureCode == -1 {
                throw LKMCPServiceError(code: "object_not_found",
                                        reason: "The target layer no longer exists.",
                                        suggestion: "Reload the hierarchy and use a fresh oid.")
            }
            return ([], [])
        }
        return (detail.attributesGroupList ?? [], detail.customAttrGroupList ?? [])
    }

    private func fetchDetails(app: LKInspectableApp,
                              oids: [UInt],
                              screenshot: LookinStaticAsyncUpdateTaskType,
                              attrs: LookinDetailUpdateTaskAttrRequest,
                              basis: Bool,
                              subitems: Bool) async throws -> [LookinDisplayItemDetail] {
        // UI 可能正在拉取 detail；先安静地取消它，避免同类型请求互相顶掉。
        await MainActor.run {
            LKStaticAsyncUpdateManager.sharedInstance().endUpdating()
        }
        let tasks = oids.map { oid -> LookinStaticAsyncUpdateTask in
            let task = LookinStaticAsyncUpdateTask()
            task.oid = oid
            task.taskType = screenshot
            task.attrRequest = attrs
            task.needBasisVisualInfo = basis
            task.needSubitems = subitems
            task.clientReadableVersion = LKHelper.lookinReadableVersion()
            return task
        }
        let package = LookinStaticAsyncUpdateTasksPackage()
        package.tasks = tasks
        let value = try await awaitSignalWithRetry {
            app.fetchHierarchyDetail(withTaskPackages: [package])
        }
        return (value as? [LookinDisplayItemDetail]) ?? []
    }

    private func preferredScreenshotRoot(in items: [LookinDisplayItem]) -> LookinDisplayItem? {
        if let keyWindow = items.first(where: { $0.representedAsKeyWindow && ($0.layerObject?.oid ?? 0) != 0 }) {
            return keyWindow
        }
        if let window = items.first(where: { LKInspectionJSON.itemTitle($0) == "UIWindow" && ($0.layerObject?.oid ?? 0) != 0 }) {
            return window
        }
        return items.first { ($0.layerObject?.oid ?? 0) != 0 }
    }

    /// 把 view / layer / display oid 统一解析为 layer oid。
    /// attributes 与 details 请求在 LookinServer 侧都是按 layer oid 查找的。
    private func resolveLayerOids(_ oids: [UInt]) -> [UInt] {
        guard let hierarchy = lastHierarchy else { return oids }
        let items = hierarchy.displayItems ?? []
        return oids.map { oid in
            guard let item = findDisplayItem(in: items, oid: oid),
                  let layerOid = item.layerObject?.oid else {
                return oid
            }
            return layerOid
        }
    }

    private func findDisplayItem(in items: [LookinDisplayItem], oid: UInt) -> LookinDisplayItem? {
        for item in items {
            if item.layerObject?.oid == oid
                || item.viewObject?.oid == oid
                || item.displayingObject()?.oid == oid {
                return item
            }
            if let subitems = item.subitems, let found = findDisplayItem(in: subitems, oid: oid) {
                return found
            }
        }
        return nil
    }

    // MARK: - Argument parsing

    private func requireUInt(_ arguments: [String: Any], _ key: String) throws -> UInt {
        guard let value = optionalUInt(arguments, key) else {
            throw LKMCPServiceError(code: "invalid_argument",
                                    reason: "Missing or invalid \(key).",
                                    suggestion: "Pass a positive integer oid from lookin_get_hierarchy.")
        }
        return value
    }

    private func optionalUInt(_ arguments: [String: Any], _ key: String) -> UInt? {
        if let number = arguments[key] as? NSNumber { return number.uintValue }
        if let string = arguments[key] as? String { return UInt(string) }
        return nil
    }

    private func requireOids(_ arguments: [String: Any], _ key: String) throws -> [UInt] {
        guard let raw = arguments[key] as? [Any], !raw.isEmpty else {
            throw LKMCPServiceError(code: "invalid_argument",
                                    reason: "\(key) must be a non-empty array of oids.",
                                    suggestion: "Use oids from lookin_get_hierarchy.")
        }
        let oids = raw.compactMap { value -> UInt? in
            if let number = value as? NSNumber { return number.uintValue }
            if let string = value as? String { return UInt(string) }
            return nil
        }
        guard oids.count == raw.count else {
            throw LKMCPServiceError(code: "invalid_argument",
                                    reason: "\(key) contains a non-integer value.",
                                    suggestion: "Use numeric oids from lookin_get_hierarchy.")
        }
        return oids
    }

    private func requireString(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw LKMCPServiceError(code: "invalid_argument",
                                    reason: "Missing or empty \(key).",
                                    suggestion: "Check the tool's input schema.")
        }
        return value
    }

    private func optionalString(_ arguments: [String: Any], _ key: String) -> String? {
        arguments[key] as? String
    }

    private func optionalInt(_ arguments: [String: Any], _ key: String) -> Int? {
        if let number = arguments[key] as? NSNumber { return number.intValue }
        if let string = arguments[key] as? String { return Int(string) }
        return nil
    }

    private func optionalBool(_ arguments: [String: Any], _ key: String) -> Bool? {
        if let value = arguments[key] as? Bool { return value }
        if let number = arguments[key] as? NSNumber { return number.boolValue }
        if let string = arguments[key] as? String {
            return ["1", "true", "yes", "enable", "enabled"].contains(string.lowercased())
        }
        return nil
    }

    private func requireBool(_ arguments: [String: Any], _ key: String) throws -> Bool {
        guard let value = optionalBool(arguments, key) else {
            throw LKMCPServiceError(code: "invalid_argument",
                                    reason: "Missing or invalid \(key).",
                                    suggestion: "Pass true or false.")
        }
        return value
    }

    private func parseScreenshotType(_ value: String) -> LookinStaticAsyncUpdateTaskType {
        switch value.lowercased() {
        case "solo": return LookinStaticAsyncUpdateTaskType(rawValue: 1)!
        case "group": return LookinStaticAsyncUpdateTaskType(rawValue: 2)!
        default: return LookinStaticAsyncUpdateTaskType(rawValue: 0)!
        }
    }

    private func parseAttrRequest(_ value: String) -> LookinDetailUpdateTaskAttrRequest {
        switch value.lowercased() {
        case "need", "yes", "true": return LookinDetailUpdateTaskAttrRequest(rawValue: 1)!
        case "none", "no", "false", "notneed": return LookinDetailUpdateTaskAttrRequest(rawValue: 2)!
        default: return LookinDetailUpdateTaskAttrRequest(rawValue: 0)!
        }
    }

    // MARK: - Signal bridge

    private func awaitSignalWithRetry(_ factory: @escaping () -> RACSignal<AnyObject>) async throws -> Any? {
        do {
            return try await awaitSignal(factory())
        } catch {
            let nsError = error as NSError
            if nsError.code == -406 { // LookinErrCode_Discard
                try await Task.sleep(nanoseconds: 150_000_000)
                return try await awaitSignal(factory())
            }
            throw error
        }
    }

    private func awaitSignal(_ signal: RACSignal<AnyObject>) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                var resumed = false
                _ = signal.take(1).subscribeNext({ value in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: value)
                }, error: { error in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: error ?? LKMCPServiceError.internalError("Unknown RAC error."))
                }, completed: {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: nil)
                })
            }
        }
    }
}
