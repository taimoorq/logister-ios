import XCTest
@testable import Logister

final class LogisterTraceContextTests: XCTestCase {
    func testWireContextAndOriginBoundaries() throws {
        let parent = try XCTUnwrap(LogisterTraceContext(traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00", requestID: "request-1"))
        let child = LogisterTraceContext(parent: parent)
        XCTAssertEqual(child.traceID, parent.traceID)
        XCTAssertEqual(child.parentSpanID, parent.spanID)
        XCTAssertNotEqual(child.spanID, parent.spanID)
        XCTAssertEqual(child.flags, "00")
        let allowed = [try XCTUnwrap(URL(string: "https://api.example.test"))]
        XCTAssertEqual(child.headers(for: URL(string: "https://api.example.test:443/path")!, allowedOrigins: allowed)["traceparent"], child.traceparent)
        for url in ["http://api.example.test", "https://api.example.test.evil", "https://api.example.test:444", "https://user@api.example.test"] {
            XCTAssertTrue(child.headers(for: URL(string: url)!, allowedOrigins: allowed).isEmpty)
        }
        XCTAssertEqual(child.eventOptions.context["span_id"], .string(child.spanID))
    }

    func testMalformedAndZeroHeadersAreRejected() {
        for header in ["00-\(String(repeating: "0", count: 32))-00f067aa0ba902b7-01", "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01", "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "garbage"] {
            XCTAssertNil(LogisterTraceContext(traceparent: header))
        }
    }
}
