import XCTest
@testable import TerminalVelocity

final class AccessTransportTests: XCTestCase {
    func envelope(_ extra: String = "", body: String = "{}", token: String = "abc") -> Data {
        Data("POST /v1/access HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nContent-Type: application/json\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)".utf8)
    }
    func testRejectsBrowserOriginsHeaderSmugglingAndPipelining() throws {
        XCTAssertEqual(try AccessHTTP.parse(envelope(), port: 1234)?.token, "abc")
        for extra in ["Origin: https://example.com\r\n", "Transfer-Encoding: chunked\r\n", "Content-Length: 2\r\n", "Authorization: Bearer other\r\n"] {
            XCTAssertThrowsError(try AccessHTTP.parse(envelope(extra), port: 1234))
        }
        XCTAssertThrowsError(try AccessHTTP.parse(envelope(), port: 5678))
        var pipelined = envelope(); pipelined.append(envelope())
        XCTAssertThrowsError(try AccessHTTP.parse(pipelined, port: 1234))
        XCTAssertThrowsError(try AccessHTTP.parse(Data(repeating: 0, count: 32769), port: 1234))
    }
    func testWaitsForCompleteBodyAndRejectsUnknownCapabilities() throws {
        let bytes = envelope(body: "{\"operation\":\"resources\"}")
        XCTAssertNil(try AccessHTTP.parse(Data(bytes.dropLast()), port: 1234))
        XCTAssertNotNil(try AccessHTTP.parse(bytes, port: 1234))
        XCTAssertThrowsError(try JSONDecoder().decode(AccessMessage.self, from: Data("{\"operation\":\"request\",\"action\":\"executeShell\"}".utf8)))
    }
    @MainActor func testLoopbackServerAuthenticatesAndExposesNoPairOrApproveEndpoint() async throws {
        let broker = ResourceBroker(storage: nil, writeAudit: { _ in }) { _, _ in XCTFail("Unexpected action"); return false }
        try broker.addProject(name: "Test")
        let token = try broker.pair(name: "Test agent", project: broker.projects[0].id)
        let server = AccessServer(broker: broker)
        try server.start()
        defer { server.stop() }
        for _ in 0..<100 where broker.endpoint == nil { try await Task.sleep(for: .milliseconds(20)) }
        let url = try XCTUnwrap(broker.endpoint.flatMap(URL.init(string:)))
        XCTAssertEqual(url.host, "127.0.0.1")
        func call(_ operation: String, credential: String) async throws -> (AccessResponse, Int) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(AccessMessage(operation: operation))
            let (data, response) = try await URLSession.shared.data(for: request)
            return (try JSONDecoder().decode(AccessResponse.self, from: data), (response as! HTTPURLResponse).statusCode)
        }
        let valid = try await call("resources", credential: token)
        XCTAssertEqual(valid.1, 200); XCTAssertEqual(valid.0.resources, [])
        let invalid = try await call("resources", credential: "wrong")
        XCTAssertEqual(invalid.1, 403); XCTAssertNil(invalid.0.resources)
        for operation in ["pair", "approve", "assign", "grant", "executeShell"] {
            let denied = try await call(operation, credential: token)
            XCTAssertEqual(denied.1, 403)
        }
    }
    func testBrokerBrowserSelectionChecksURLAndTitleInsideScript() throws {
        let tab = BrowserTab(browserID: "com.google.Chrome", windowID: 1, tabID: 2, title: "Title", url: "https://example.com", minimized: false, windowTitle: "", index: 1)
        let source = BrowserTabs.selectionSource(tab, requireUnchanged: true)
        XCTAssertTrue(source.contains("URL of tab n of w is not"))
        XCTAssertTrue(source.contains("title of tab n of w is not"))
        XCTAssertNotNil(NSAppleScript(source: source))
    }
}
