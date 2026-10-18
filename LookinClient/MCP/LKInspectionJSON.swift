//
//  LKInspectionJSON.swift
//  Lookin
//
//  将 LookinShared 的模型序列化为 MCP tool 返回的 JSON。
//  序列化逻辑对齐 LookinCLI/main.m 中的实现，保证两条路径输出一致。
//

import Foundation
import AppKit

final class LKInspectionJSON: NSObject {

    // MARK: - App / targets

    static func appInfoJSON(_ info: LookinAppInfo?) -> [String: Any] {
        guard let info = info else { return [:] }
        var dict: [String: Any] = [
            "name": info.appName ?? "",
            "bundle": info.appBundleIdentifier ?? "",
            "device": info.deviceDescription ?? "",
            "os": info.osDescription ?? "",
            "deviceType": deviceTypeName(info.deviceType),
            "screen": [
                "width": safeNumber(info.screenWidth),
                "height": safeNumber(info.screenHeight),
                "scale": safeNumber(info.screenScale)
            ],
            "serverVersion": info.serverVersion,
            "serverReadableVersion": info.serverReadableVersion ?? ""
        ]
        if info.appInfoIdentifier != 0 {
            dict["id"] = String(info.appInfoIdentifier)
        }
        return dict
    }

    private static func deviceTypeName(_ type: LookinAppInfoDevice) -> String {
        switch Int(type.rawValue) {
        case 0: return "simulator"
        case 1: return "ipad"
        case 3: return "mac"
        default: return "iphone"
        }
    }

    // MARK: - Hierarchy

    static func itemJSON(_ item: LookinDisplayItem, depth: Int, maxDepth: Int) -> [String: Any] {
        // attributes / details 请求使用 layer oid；与 LookinServer HTTP bridge 保持一致。
        let primaryObject = item.layerObject ?? item.viewObject ?? item.displayingObject()
        var dict: [String: Any] = [
            "oid": primaryObject?.oid ?? 0,
            "title": itemTitle(item),
            "hidden": item.isHidden,
            "alpha": safeNumber(Double(item.alpha)),
            "frame": rectJSON(item.frame),
            "bounds": rectJSON(item.bounds),
            "view": objectJSON(item.viewObject),
            "layer": objectJSON(item.layerObject),
            "representedAsKeyWindow": item.representedAsKeyWindow,
            "shouldCaptureImage": item.shouldCaptureImage,
            "eventHandlerCount": item.eventHandlers?.count ?? 0
        ]
        if let vc = item.hostViewControllerObject {
            dict["viewController"] = objectJSON(vc)
        }
        if let title = item.customInfo?.title, !title.isEmpty {
            dict["customInfo"] = ["title": title]
        }
        if let handlers = item.eventHandlers, !handlers.isEmpty {
            dict["eventHandlers"] = handlers.map { eventHandlerJSON($0) }
        }
        if depth < maxDepth, let subitems = item.subitems, !subitems.isEmpty {
            dict["children"] = subitems.map { itemJSON($0, depth: depth + 1, maxDepth: maxDepth) }
        }
        return dict
    }

    static func hierarchyJSON(_ hierarchy: LookinHierarchyInfo, maxDepth: Int) -> [String: Any] {
        let items = (hierarchy.displayItems ?? []).map { itemJSON($0, depth: 0, maxDepth: maxDepth) }
        return [
            "app": appInfoJSON(hierarchy.appInfo),
            "totalViews": countItems(items),
            "hierarchy": items
        ]
    }

    private static func countItems(_ items: [[String: Any]]) -> Int {
        var count = 0
        for item in items {
            count += 1
            if let children = item["children"] as? [[String: Any]] {
                count += countItems(children)
            }
        }
        return count
    }

    // MARK: - Object

    static func objectJSON(_ object: LookinObject?) -> [String: Any] {
        guard let object = object else { return [:] }
        var dict: [String: Any] = [
            "oid": object.oid,
            "class": objectClassName(object),
            "address": object.memoryAddress ?? ""
        ]
        if let trace = object.specialTrace, !trace.isEmpty {
            dict["trace"] = trace
        }
        if let chain = object.classChainList, !chain.isEmpty {
            dict["classChain"] = chain
        }
        if let traces = object.ivarTraces, !traces.isEmpty {
            dict["ivarTraces"] = traces.map { trace -> [String: Any] in
                return [
                    "relation": trace.relation ?? "",
                    "hostClass": trace.hostClassName ?? "",
                    "ivar": trace.ivarName ?? ""
                ]
            }
        }
        return dict
    }

    static func objectClassName(_ object: LookinObject?) -> String {
        guard let object = object else { return "" }
        let raw = object.rawClassName() ?? ""
        if !raw.isEmpty { return raw }
        return object.classChainList?.first ?? ""
    }

    static func itemTitle(_ item: LookinDisplayItem) -> String {
        if let title = item.customInfo?.title, !title.isEmpty { return title }
        if let title = item.customDisplayTitle, !title.isEmpty { return title }
        let viewName = objectClassName(item.viewObject)
        if !viewName.isEmpty { return viewName }
        let layerName = objectClassName(item.layerObject)
        if !layerName.isEmpty { return layerName }
        return "<unknown>"
    }

    private static func eventHandlerJSON(_ handler: LookinEventHandler) -> [String: Any] {
        var dict: [String: Any] = [
            "type": Int(handler.handlerType.rawValue) == 1 ? "gesture" : "targetAction",
            "event": handler.eventName ?? ""
        ]
        if let actions = handler.targetActions, !actions.isEmpty {
            dict["targetActions"] = actions.map {
                ["first": $0.first ?? "", "second": $0.second ?? ""]
            }
        }
        if let inherited = handler.inheritedRecognizerName, !inherited.isEmpty {
            dict["inheritedRecognizerName"] = inherited
        }
        if handler.recognizerOid != 0 {
            dict["recognizerOid"] = handler.recognizerOid
            dict["recognizerEnabled"] = handler.gestureRecognizerIsEnabled
        }
        if let delegator = handler.gestureRecognizerDelegator, !delegator.isEmpty {
            dict["recognizerDelegator"] = delegator
        }
        if let traces = handler.recognizerIvarTraces, !traces.isEmpty {
            dict["recognizerIvarTraces"] = traces
        }
        return dict
    }

    // MARK: - Attributes

    static func attributeGroupsJSON(_ groups: [LookinAttributesGroup]?) -> [[String: Any]] {
        guard let groups = groups else { return [] }
        return groups.map { groupJSON($0) }
    }

    static func groupJSON(_ group: LookinAttributesGroup) -> [String: Any] {
        var dict: [String: Any] = [
            "identifier": group.identifier ?? "",
            "title": group.userCustomTitle ?? group.identifier ?? "",
            "custom": group.isUserCustom()
        ]
        if let uniqueKey = group.uniqueKey() {
            dict["uniqueKey"] = uniqueKey
        }
        dict["sections"] = (group.attrSections ?? []).map { sectionJSON($0) }
        return dict
    }

    private static func sectionJSON(_ section: LookinAttributesSection) -> [String: Any] {
        [
            "identifier": section.identifier ?? "",
            "custom": section.isUserCustom(),
            "attributes": (section.attributes ?? []).map { attributeJSON($0) }
        ]
    }

    static func attributeJSON(_ attribute: LookinAttribute) -> [String: Any] {
        var dict: [String: Any] = [
            "identifier": attribute.identifier ?? "",
            "attrType": Int(attribute.attrType.rawValue),
            "attrTypeName": attrTypeName(attribute.attrType),
            "value": jsonObject(attribute.value),
            "custom": attribute.isUserCustom()
        ]
        if let title = attribute.displayTitle, !title.isEmpty {
            dict["displayTitle"] = title
        }
        if let extra = attribute.extraValue {
            dict["extraValue"] = jsonObject(extra)
        }
        let setter: Selector? = LookinDashboardBlueprint.setter(withAttrID: attribute.identifier)
        if let setter = setter {
            dict["setterSelector"] = NSStringFromSelector(setter)
        }
        if let customSetterID = attribute.customSetterID, !customSetterID.isEmpty {
            dict["customSetterID"] = customSetterID
        }
        return dict
    }

    static func findAttribute(identifier: String, in groups: [LookinAttributesGroup]?) -> LookinAttribute? {
        for group in groups ?? [] {
            for section in group.attrSections ?? [] {
                for attribute in section.attributes ?? [] {
                    if attribute.identifier == identifier {
                        return attribute
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Details

    static func detailJSON(_ detail: LookinDisplayItemDetail) -> [String: Any] {
        var dict: [String: Any] = [
            "displayItemOid": detail.displayItemOid
        ]
        if detail.failureCode != 0 {
            dict["failureCode"] = detail.failureCode
        }
        if let image = detail.groupScreenshot {
            dict["groupScreenshot"] = imageJSON(image)
        }
        if let image = detail.soloScreenshot {
            dict["soloScreenshot"] = imageJSON(image)
        }
        if let frame = detail.frameValue {
            dict["frame"] = valueJSON(frame)
        }
        if let bounds = detail.boundsValue {
            dict["bounds"] = valueJSON(bounds)
        }
        if let hidden = detail.hiddenValue {
            dict["hidden"] = hidden
        }
        if let alpha = detail.alphaValue {
            dict["alpha"] = alpha
        }
        if let title = detail.customDisplayTitle, !title.isEmpty {
            dict["customDisplayTitle"] = title
        }
        if let groups = detail.attributesGroupList {
            dict["attributes"] = attributeGroupsJSON(groups)
        }
        if let groups = detail.customAttrGroupList {
            dict["customAttributes"] = attributeGroupsJSON(groups)
        }
        if let subitems = detail.subitems {
            dict["subitems"] = subitems.map { itemJSON($0, depth: 0, maxDepth: Int.max) }
        }
        return dict
    }

    // MARK: - Current view controllers

    static func currentViewControllersJSON(_ items: [LookinDisplayItem]) -> [[String: Any]] {
        var byKey: [String: [String: Any]] = [:]
        collectViewControllers(items, path: [], depth: 0, byKey: &byKey)

        let sorted = byKey.values.sorted { lhs, rhs in
            let overlayA = lhs["overlay"] as? Bool ?? false
            let overlayB = rhs["overlay"] as? Bool ?? false
            if overlayA != overlayB { return !overlayA }
            let areaA = lhs["area"] as? Double ?? 0
            let areaB = rhs["area"] as? Double ?? 0
            if areaA != areaB { return areaA > areaB }
            let depthA = lhs["depth"] as? Int ?? 0
            let depthB = rhs["depth"] as? Int ?? 0
            if depthA != depthB { return depthA > depthB }
            let classA = lhs["class"] as? String ?? ""
            let classB = rhs["class"] as? String ?? ""
            return classA < classB
        }

        return sorted.enumerated().map { index, dict in
            var copy = dict
            copy["rank"] = index
            return copy
        }
    }

    private static func collectViewControllers(_ items: [LookinDisplayItem],
                                               path: [String],
                                               depth: Int,
                                               byKey: inout [String: [String: Any]]) {
        for item in items {
            let title = itemTitle(item)
            let nextPath = path + [title]
            if let vc = item.hostViewControllerObject {
                let className = objectClassName(vc)
                let key = "\(className)-\(vc.oid)"
                let pathString = nextPath.joined(separator: " > ")
                let area = max(0, Double(item.frame.width)) * max(0, Double(item.frame.height))
                var dict = byKey[key] ?? ["count": 0]
                dict["count"] = (dict["count"] as? Int ?? 0) + 1
                let previousArea = dict["area"] as? Double ?? 0
                let previousDepth = dict["depth"] as? Int ?? 0
                if dict["class"] == nil || area > previousArea || (area == previousArea && depth >= previousDepth) {
                    dict["class"] = className
                    dict["oid"] = vc.oid
                    dict["address"] = vc.memoryAddress ?? ""
                    dict["depth"] = depth
                    dict["title"] = title
                    dict["path"] = pathString
                    dict["overlay"] = looksLikeOverlay(className: className, path: pathString)
                    dict["area"] = area
                    dict["frame"] = rectJSON(item.frame)
                    dict["view"] = objectJSON(item.viewObject)
                    dict["layer"] = objectJSON(item.layerObject)
                }
                byKey[key] = dict
            }
            if let subitems = item.subitems, !subitems.isEmpty {
                collectViewControllers(subitems, path: nextPath, depth: depth + 1, byKey: &byKey)
            }
        }
    }

    private static func looksLikeOverlay(className: String, path: String) -> Bool {
        let classPrefixes = ["UIInput", "UIEditing", "FLEX", "BDTracker"]
        if classPrefixes.contains(where: { className.hasPrefix($0) }) { return true }
        let pathPrefixes = ["UITextEffectsWindow", "FLEXWindow", "BDTrackerGUI"]
        return pathPrefixes.contains(where: { path.hasPrefix($0) })
    }

    // MARK: - Images / values

    static func pngData(from image: NSImage?) -> Data? {
        guard let image = image else { return nil }
        var rect = NSRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        }
        guard let tiff = image.tiffRepresentation else { return nil }
        if let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:]) ?? tiff
        }
        return tiff
    }

    static func imageJSON(_ image: NSImage?) -> [String: Any] {
        guard let image = image else { return [:] }
        return [
            "width": safeNumber(Double(image.size.width)),
            "height": safeNumber(Double(image.size.height)),
            "bytes": pngData(from: image)?.count ?? 0
        ]
    }

    static func valueJSON(_ value: NSValue) -> [String: Any] {
        // 不同架构下 CGRect 等结构体的 encoding 是嵌套的（例如
        // {CGRect={CGPoint=dd}{CGSize=dd}}），因此按结构体名判断。
        let type = String(cString: value.objCType)
        if type.contains("CGPoint") || type.contains("NSPoint") {
            let point = value.pointValue
            return ["kind": "point", "x": safeNumber(Double(point.x)), "y": safeNumber(Double(point.y))]
        }
        if type.contains("CGSize") || type.contains("NSSize") {
            let size = value.sizeValue
            return ["kind": "size", "width": safeNumber(Double(size.width)), "height": safeNumber(Double(size.height))]
        }
        if type.contains("CGRect") || type.contains("NSRect") {
            return ["kind": "rect"].merging(rectJSON(value.rectValue)) { _, new in new }
        }
        return ["kind": "value", "description": value.description]
    }

    static func rectJSON(_ rect: CGRect) -> [String: Any] {
        [
            "x": safeNumber(Double(rect.origin.x)),
            "y": safeNumber(Double(rect.origin.y)),
            "width": safeNumber(Double(rect.size.width)),
            "height": safeNumber(Double(rect.size.height))
        ]
    }

    static func jsonObject(_ object: Any?) -> Any {
        guard let object = object else { return NSNull() }
        if object is NSNull { return NSNull() }
        if let value = object as? String { return value }
        if let value = object as? NSNumber { return value }
        if let value = object as? [Any] {
            return value.map { jsonObject($0) }
        }
        if let value = object as? [String: Any] {
            return value.mapValues { jsonObject($0) }
        }
        if let value = object as? NSImage {
            return imageJSON(value)
        }
        if let value = object as? NSValue {
            return valueJSON(value)
        }
        if let value = object as? LookinObject {
            return objectJSON(value)
        }
        if let value = object as? LookinAttributesGroup {
            return groupJSON(value)
        }
        if let value = object as? NSData {
            return ["bytes": value.count]
        }
        return ["class": String(describing: type(of: object)),
                "description": String(describing: object)]
    }

    static func safeNumber(_ value: Double) -> Any {
        value.isFinite ? value : 0
    }

    private static func attrTypeName(_ type: LookinAttrType) -> String {
        switch Int(type.rawValue) {
        case 0: return "none"
        case 1: return "void"
        case 2: return "char"
        case 3: return "int"
        case 4: return "short"
        case 5: return "long"
        case 6: return "longLong"
        case 7: return "unsignedChar"
        case 8: return "unsignedInt"
        case 9: return "unsignedShort"
        case 10: return "unsignedLong"
        case 11: return "unsignedLongLong"
        case 12: return "float"
        case 13: return "double"
        case 14: return "bool"
        case 15: return "selector"
        case 16: return "class"
        case 17: return "point"
        case 18: return "vector"
        case 19: return "size"
        case 20: return "rect"
        case 21: return "affineTransform"
        case 22: return "edgeInsets"
        case 23: return "offset"
        case 24: return "string"
        case 25: return "enumInt"
        case 26: return "enumLong"
        case 27: return "color"
        case 28: return "customObject"
        case 29: return "enumString"
        case 30: return "shadow"
        case 31: return "json"
        default: return "unknown"
        }
    }
}
