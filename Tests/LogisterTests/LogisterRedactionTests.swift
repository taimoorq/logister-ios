import Foundation
import XCTest
@testable import Logister

final class LogisterRedactionTests: XCTestCase {
    func testCamelCaseHeaderAndContainsKeysAreRedacted() {
        let policy = LogisterPayloadPolicy.default
        for key in [
            "accessToken", "apiKey", "x-api-key", "refreshToken", "clientSecret", "idToken",
            "access_token", "API_KEY", "X-Auth-Token", "Proxy-Authorization", "Set-Cookie",
            "sessionToken", "session_key", "private-key", "ssn", "credit_card", "cardNumber", "cvv",
            "pwd", "signature", "stripeSecretKey", "userPassword", "githubTokenValue", "myCredentials"
        ] {
            XCTAssertTrue(policy.isSensitiveKey(key), key)
        }
        for key in ["author", "session_id", "trace_id", "request_id", "user_name", "keyboard", "monkey"] {
            XCTAssertFalse(policy.isSensitiveKey(key), key)
        }
    }

    func testCustomKeysAreNormalizedAndAdded() {
        var policy = LogisterPayloadPolicy(
            sensitiveKeys: LogisterPayloadPolicy.defaultSensitiveKeys.union(["pin-code"])
        )
        XCTAssertTrue(policy.isSensitiveKey("pinCode"))
        XCTAssertTrue(policy.isSensitiveKey("accessToken"))
        policy.sensitiveKeys.insert("Account_Number")
        XCTAssertTrue(policy.isSensitiveKey("accountNumber"))
    }

    func testSensitiveValuesAreReplacedThroughoutTheEvent() async throws {
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token", expiresAt: Date().addingTimeInterval(300))
            ]),
            exceptionDataPolicy: .typeAndStacktrace,
            configuration: LogisterConfiguration(
                storageScope: UUID().uuidString,
                storageDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("logister-ios-tests-\(UUID().uuidString)", isDirectory: true)
            ),
            transport: transport
        )
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl"

        _ = try await client.captureMessage(
            "login failed for Bearer abc.def-123 with \(jwt)",
            options: LogisterEventOptions(
                traceID: "4bf92f3577b34da6a3ce929d0e0e4736",
                breadcrumbs: [
                    LogisterBreadcrumb(message: "GET https://user:pass@api.example/v1/me?token=1&page=2#frag",
                                       data: ["apiKey": .string("k"), "status": .number(200)])
                ],
                context: [
                    "accessToken": .string("raw-access"),
                    "headers": .object([
                        "x-api-key": .string("raw-key"),
                        "Authorization": .string("Basic dXNlcjpwYXNz"),
                        "Accept": .string("application/json")
                    ]),
                    "tags": .array([.object(["refreshToken": .string("raw-refresh")])]),
                    "note": .string("basic setup used lgst_abcDEF123 key"),
                    "auth": .string("Basic dXNlcjpwYXNz")
                ]
            )
        )

        let event = try XCTUnwrap(transport.envelope()["event"] as? [String: Any])
        let context = try XCTUnwrap(event["context"] as? [String: Any])
        let serialized = String(decoding: try XCTUnwrap(transport.body), as: UTF8.self)
        for secret in ["raw-access", "raw-key", "raw-refresh", "dXNlcjpwYXNz", "abc.def-123", jwt, "lgst_abcDEF123", "pass@", "token=1"] {
            XCTAssertFalse(serialized.contains(secret), secret)
        }
        XCTAssertEqual(event["message"] as? String, "login failed for Bearer [REDACTED] with [REDACTED]")
        XCTAssertEqual(event["trace_id"] as? String, "4bf92f3577b34da6a3ce929d0e0e4736")
        XCTAssertEqual(context["accessToken"] as? String, "[REDACTED]")
        let headers = try XCTUnwrap(context["headers"] as? [String: Any])
        XCTAssertEqual(headers["x-api-key"] as? String, "[REDACTED]")
        XCTAssertEqual(headers["Authorization"] as? String, "[REDACTED]")
        XCTAssertEqual(headers["Accept"] as? String, "application/json")
        XCTAssertEqual((context["tags"] as? [[String: Any]])?.first?["refreshToken"] as? String, "[REDACTED]")
        XCTAssertEqual(context["note"] as? String, "basic setup used [REDACTED] key")
        XCTAssertEqual(context["auth"] as? String, "Basic [REDACTED]")
        let breadcrumb = try XCTUnwrap((context["breadcrumbs"] as? [[String: Any]])?.first)
        XCTAssertEqual(breadcrumb["message"] as? String, "GET https://api.example/v1/me")
        XCTAssertEqual((breadcrumb["data"] as? [String: Any])?["apiKey"] as? String, "[REDACTED]")
        XCTAssertEqual((breadcrumb["data"] as? [String: Any])?["status"] as? Double, 200)
        XCTAssertEqual(context["trace_id"] as? String, "4bf92f3577b34da6a3ce929d0e0e4736")
    }
}
