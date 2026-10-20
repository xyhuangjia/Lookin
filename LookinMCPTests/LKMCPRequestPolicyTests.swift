import XCTest

final class LKMCPRequestPolicyTests: XCTestCase {

    private let port: UInt16 = 47200

    func testAllowsRequestsWithoutOriginOrHost() {
        XCTAssertTrue(LKMCPRequestPolicy.allows(origin: nil, host: nil, port: port))
        XCTAssertTrue(LKMCPRequestPolicy.allows(origin: "", host: "", port: port))
    }

    func testAllowsLoopbackOrigins() {
        XCTAssertTrue(LKMCPRequestPolicy.allows(origin: "http://127.0.0.1:47200", host: nil, port: port))
        XCTAssertTrue(LKMCPRequestPolicy.allows(origin: "http://localhost:47200", host: nil, port: port))
    }

    func testRejectsRemoteOrigin() {
        XCTAssertFalse(LKMCPRequestPolicy.allows(origin: "http://evil.example", host: nil, port: port))
        XCTAssertFalse(LKMCPRequestPolicy.allows(origin: "http://192.168.1.2:47200", host: nil, port: port))
    }

    func testRejectsOriginWithDifferentPort() {
        XCTAssertFalse(LKMCPRequestPolicy.allows(origin: "http://127.0.0.1:47190", host: nil, port: port))
    }

    func testAllowsLoopbackHosts() {
        XCTAssertTrue(LKMCPRequestPolicy.allows(origin: nil, host: "127.0.0.1:47200", port: port))
        XCTAssertTrue(LKMCPRequestPolicy.allows(origin: nil, host: "localhost:47200", port: port))
        XCTAssertTrue(LKMCPRequestPolicy.allows(origin: nil, host: "LOCALHOST:47200", port: port))
        XCTAssertTrue(LKMCPRequestPolicy.allows(origin: nil, host: "[::1]:47200", port: port))
        XCTAssertTrue(LKMCPRequestPolicy.allows(origin: nil, host: "127.0.0.1", port: port))
        XCTAssertTrue(LKMCPRequestPolicy.allows(origin: nil, host: "localhost", port: port))
    }

    func testRejectsNonLoopbackHost() {
        XCTAssertFalse(LKMCPRequestPolicy.allows(origin: nil, host: "lookin.example:47200", port: port))
        XCTAssertFalse(LKMCPRequestPolicy.allows(origin: nil, host: "127.0.0.1:47190", port: port))
        XCTAssertFalse(LKMCPRequestPolicy.allows(origin: nil, host: "192.168.1.2:47200", port: port))
        XCTAssertFalse(LKMCPRequestPolicy.allows(origin: nil, host: "[::1]:47190", port: port))
        XCTAssertFalse(LKMCPRequestPolicy.allows(origin: nil, host: "evil.example", port: port))
    }

    func testRejectsMismatchedOriginEvenWithValidHost() {
        XCTAssertFalse(LKMCPRequestPolicy.allows(origin: "http://evil.example",
                                                 host: "127.0.0.1:47200",
                                                 port: port))
    }
}
