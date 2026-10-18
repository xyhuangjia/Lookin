import XCTest

final class LKAttributeValueParserTests: XCTestCase {

    private func assertError(_ raw: Any?, attrType: Int, code: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try LKAttributeValueParser.parse(raw, attrTypeRaw: attrType),
                             file: file, line: line) { error in
            XCTAssertEqual((error as? LKMCPServiceError)?.code, code, file: file, line: line)
        }
    }

    func testNilReturnsNil() throws {
        XCTAssertNil(try LKAttributeValueParser.parse(nil, attrTypeRaw: 12))
        XCTAssertNil(try LKAttributeValueParser.parse(NSNull(), attrTypeRaw: 12))
    }

    func testNumericTypesAcceptNumbersAndStrings() throws {
        for raw in [5, 5.5, "6", NSNumber(value: 7)] as [Any] {
            let value = try LKAttributeValueParser.parse(raw, attrTypeRaw: 12)
            XCTAssertNotNil(value as? NSNumber)
        }
    }

    func testNumericTypeRejectsNonNumber() {
        assertError(["x"], attrType: 12, code: "invalid_value")
    }

    func testBoolTypeAcceptsCommonForms() throws {
        let trueValues: [Any] = [true, 1, "true", "YES", "enabled"]
        for raw in trueValues {
            XCTAssertEqual((try LKAttributeValueParser.parse(raw, attrTypeRaw: 14) as? NSNumber)?.boolValue, true,
                           "\(raw) should parse as true")
        }
        XCTAssertEqual((try LKAttributeValueParser.parse("no", attrTypeRaw: 14) as? NSNumber)?.boolValue, false)
    }

    func testStringTypeRequiresString() throws {
        XCTAssertEqual(try LKAttributeValueParser.parse("hello", attrTypeRaw: 15) as? String, "hello")
        assertError(12, attrType: 15, code: "invalid_value")
    }

    func testColorNormalizesBytesAndAppendsAlpha() throws {
        let bytes = try XCTUnwrap(try LKAttributeValueParser.parse([255, 128, 0], attrTypeRaw: 27) as? [NSNumber])
        XCTAssertEqual(bytes.map { $0.doubleValue }, [1.0, 128.0 / 255.0, 0.0, 1.0])

        let floats = try XCTUnwrap(try LKAttributeValueParser.parse([0.5, 0.25, 1.0, 0.75],
                                                                   attrTypeRaw: 27) as? [NSNumber])
        XCTAssertEqual(floats.map { $0.doubleValue }, [0.5, 0.25, 1.0, 0.75])
    }

    func testColorRequiresThreeComponents() {
        assertError([1, 2], attrType: 27, code: "invalid_value")
    }

    func testPointAcceptsArrayAndString() throws {
        let fromArray = try XCTUnwrap(try LKAttributeValueParser.parse([10, 20], attrTypeRaw: 17) as? NSValue)
        XCTAssertEqual(fromArray.pointValue, NSPoint(x: 10, y: 20))

        let fromString = try XCTUnwrap(try LKAttributeValueParser.parse("10, 20", attrTypeRaw: 17) as? NSValue)
        XCTAssertEqual(fromString.pointValue, NSPoint(x: 10, y: 20))
    }

    func testSizeAcceptsDictionary() throws {
        let value = try XCTUnwrap(try LKAttributeValueParser.parse(
            ["width": 30, "height": 40], attrTypeRaw: 19
        ) as? NSValue)
        XCTAssertEqual(value.sizeValue, NSSize(width: 30, height: 40))
    }

    func testRectAcceptsDictionaryAndSpaceSeparatedString() throws {
        let fromDict = try XCTUnwrap(try LKAttributeValueParser.parse(
            ["x": 1, "y": 2, "width": 3, "height": 4], attrTypeRaw: 20
        ) as? NSValue)
        XCTAssertEqual(fromDict.rectValue, NSRect(x: 1, y: 2, width: 3, height: 4))

        let fromString = try XCTUnwrap(try LKAttributeValueParser.parse("1;2;3;4", attrTypeRaw: 20) as? NSValue)
        XCTAssertEqual(fromString.rectValue, NSRect(x: 1, y: 2, width: 3, height: 4))
    }

    func testRectRequiresFourComponents() {
        assertError([1, 2, 3], attrType: 20, code: "invalid_value")
    }

    func testOpaqueTypesPassThrough() throws {
        let json = ["nested": true]
        let value = try LKAttributeValueParser.parse(json, attrTypeRaw: 30) as? [String: Bool]
        XCTAssertEqual(value, ["nested": true])
    }

    func testUnsupportedType() {
        assertError(1, attrType: 99, code: "unsupported_attr_type")
    }

    // MARK: - Error mapping

    func testServiceErrorMapping() {
        XCTAssertEqual(LKMCPServiceError.from(NSError(domain: "t", code: -403)).code, "no_connection")
        XCTAssertEqual(LKMCPServiceError.from(NSError(domain: "t", code: -404)).code, "timeout")
        XCTAssertEqual(LKMCPServiceError.from(NSError(domain: "t", code: -406)).code, "request_superseded")
        XCTAssertEqual(LKMCPServiceError.from(NSError(domain: "t", code: -407)).code, "app_background")
        XCTAssertEqual(LKMCPServiceError.from(NSError(domain: "t", code: -500)).code, "object_not_found")
        XCTAssertEqual(LKMCPServiceError.from(NSError(domain: "t", code: -601)).code, "server_version_mismatch")
    }

    func testToolResultEncoding() throws {
        let text = LKToolCallResult.text(["b": 2, "a": 1])
        XCTAssertFalse(text.isError)
        XCTAssertEqual(text.content.count, 1)
        XCTAssertEqual(text.content[0]["type"] as? String, "text")

        let payload = try XCTUnwrap((text.content[0]["text"] as? String)?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Int])
        XCTAssertEqual(object, ["a": 1, "b": 2])

        let failure = LKToolCallResult.error(LKMCPServiceError(code: "write_disabled",
                                                               reason: "off",
                                                               suggestion: "enable"))
        XCTAssertTrue(failure.isError)
        let errorText = try XCTUnwrap((failure.content[0]["text"] as? String)?.data(using: .utf8))
        let errorObject = try XCTUnwrap(JSONSerialization.jsonObject(with: errorText) as? [String: String])
        XCTAssertEqual(errorObject["code"], "write_disabled")
        XCTAssertEqual(errorObject["reason"], "off")
        XCTAssertEqual(errorObject["suggestion"], "enable")
    }
}
