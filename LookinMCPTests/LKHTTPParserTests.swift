import XCTest

final class LKHTTPParserTests: XCTestCase {

    private func request(_ head: String, body: Data = Data()) -> Data {
        var data = Data("\(head)\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    func testParsesPostRequest() {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let data = request("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47200\r\nContent-Length: \(body.count)", body: body)

        guard case .complete(let parsed) = LKHTTPParser.parse(data) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/mcp")
        XCTAssertEqual(parsed.headers["host"], "127.0.0.1:47200")
        XCTAssertEqual(parsed.body, body)
    }

    func testLowercasesHeaderNames() {
        let data = request("POST /mcp HTTP/1.1\r\nMCP-Protocol-Version: 2026-07-28\r\nContent-Length: 0")
        guard case .complete(let parsed) = LKHTTPParser.parse(data) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(parsed.headers["mcp-protocol-version"], "2026-07-28")
    }

    func testUpperCaseMethod() {
        let data = request("post /mcp HTTP/1.1\r\nContent-Length: 0")
        guard case .complete(let parsed) = LKHTTPParser.parse(data) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(parsed.method, "POST")
    }

    func testIncompleteWithoutHeaderTerminator() {
        let data = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8)
        guard case .incomplete = LKHTTPParser.parse(data) else {
            return XCTFail("Expected incomplete")
        }
    }

    func testIncompleteWhenBodyIsShort() {
        let data = request("POST /mcp HTTP/1.1\r\nContent-Length: 10", body: Data("{}".utf8))
        guard case .incomplete = LKHTTPParser.parse(data) else {
            return XCTFail("Expected incomplete")
        }
    }

    func testIgnoresBytesBeyondContentLength() {
        let body = Data("{}".utf8)
        var data = request("POST /mcp HTTP/1.1\r\nContent-Length: 2", body: body)
        data.append(Data("extra".utf8))
        guard case .complete(let parsed) = LKHTTPParser.parse(data) else {
            return XCTFail("Expected a complete request")
        }
        XCTAssertEqual(parsed.body, body)
    }

    func testInvalidRequestLine() {
        let data = request("POST")
        guard case .invalid(let status) = LKHTTPParser.parse(data) else {
            return XCTFail("Expected invalid")
        }
        XCTAssertEqual(status, 400)
    }

    func testInvalidNonNumericContentLength() {
        let data = request("POST /mcp HTTP/1.1\r\nContent-Length: abc")
        guard case .invalid(let status) = LKHTTPParser.parse(data) else {
            return XCTFail("Expected invalid")
        }
        XCTAssertEqual(status, 400)
    }

    func testInvalidNegativeContentLength() {
        let data = request("POST /mcp HTTP/1.1\r\nContent-Length: -1")
        guard case .invalid(let status) = LKHTTPParser.parse(data) else {
            return XCTFail("Expected invalid")
        }
        XCTAssertEqual(status, 400)
    }

    func testRejectsOversizedBodyDeclaration() {
        let data = request("POST /mcp HTTP/1.1\r\nContent-Length: \(LKHTTPParser.maxBodySize + 1)")
        guard case .invalid(let status) = LKHTTPParser.parse(data) else {
            return XCTFail("Expected invalid")
        }
        XCTAssertEqual(status, 413)
    }

    func testAcceptsBodyAtLimit() {
        let data = request("POST /mcp HTTP/1.1\r\nContent-Length: \(LKHTTPParser.maxBodySize)")
        // Header is complete but the body is not, so parsing stays incomplete
        // instead of failing with 413.
        guard case .incomplete = LKHTTPParser.parse(data) else {
            return XCTFail("Expected incomplete")
        }
    }

    func testReasonPhrases() {
        XCTAssertEqual(LKHTTPParser.reason(for: 200), "OK")
        XCTAssertEqual(LKHTTPParser.reason(for: 405), "Method Not Allowed")
        XCTAssertEqual(LKHTTPParser.reason(for: 413), "Payload Too Large")
        XCTAssertEqual(LKHTTPParser.reason(for: 999), "Error")
    }
}
