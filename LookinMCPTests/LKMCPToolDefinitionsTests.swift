import XCTest

final class LKMCPToolDefinitionsTests: XCTestCase {

    private var tools: [[String: Any]] { LKMCPToolDefinitions.all }

    private func tool(named name: String) throws -> [String: Any] {
        try XCTUnwrap(tools.first { $0["name"] as? String == name }, "Missing tool \(name)")
    }

    func testToolCount() {
        XCTAssertEqual(tools.count, 14)
    }

    func testToolNamesAreUniqueAndPrefixed() {
        let names = LKMCPToolDefinitions.names
        XCTAssertEqual(names.count, tools.count)
        XCTAssertEqual(Set(names).count, names.count)
        for name in names {
            XCTAssertTrue(name.hasPrefix("lookin_"), "Unexpected tool name: \(name)")
        }
    }

    func testEveryToolHasValidSchema() throws {
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty, "\(name) has no description")

            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any], "\(name) has no inputSchema")
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)

            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let required = try XCTUnwrap(schema["required"] as? [String])
            for key in required {
                XCTAssertNotNil(properties[key], "\(name) requires undeclared property \(key)")
            }

            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
            XCTAssertNotNil(annotations["readOnlyHint"] as? Bool, "\(name) has no readOnlyHint")
        }
    }

    func testReadToolsAreNonDestructive() throws {
        let readOnlyTools = ["lookin_list_targets", "lookin_get_status", "lookin_get_hierarchy",
                             "lookin_get_details", "lookin_get_attributes", "lookin_get_screenshot",
                             "lookin_get_current_vc", "lookin_get_object", "lookin_list_selectors"]
        for name in readOnlyTools {
            let annotations = try XCTUnwrap(try tool(named: name)["annotations"] as? [String: Any])
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true, name)
            XCTAssertNil(annotations["destructiveHint"], "\(name) should not set destructiveHint")
        }
    }

    func testWriteToolsRequireWritesButAreNotDestructive() throws {
        let writeTools = ["lookin_set_attribute", "lookin_set_custom_attribute",
                          "lookin_set_gesture_recognizer_enabled"]
        for name in writeTools {
            let annotations = try XCTUnwrap(try tool(named: name)["annotations"] as? [String: Any])
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false, name)
            XCTAssertEqual(annotations["destructiveHint"] as? Bool, false, name)
        }
    }

    func testInvokeToolIsDestructive() throws {
        let annotations = try XCTUnwrap(try tool(named: "lookin_invoke_selector")["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(annotations["destructiveHint"] as? Bool, true)
    }

    func testWriteToolsRequireDryRunCapability() throws {
        let dryRunTools = ["lookin_set_attribute", "lookin_set_custom_attribute", "lookin_invoke_selector"]
        for name in dryRunTools {
            let schema = try XCTUnwrap(try tool(named: name)["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertNotNil(properties["dryRun"], "\(name) should accept dryRun")
        }
    }

    func testSelectorsRequireNoArgumentName() throws {
        let schema = try XCTUnwrap(try tool(named: "lookin_list_selectors")["inputSchema"] as? [String: Any])
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertEqual(required, ["className"])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual((properties["hasArg"] as? [String: Any])?["type"] as? String, "boolean")
    }
}
