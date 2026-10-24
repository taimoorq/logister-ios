import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Logister

final class LogisterDeliveryHardeningTests: XCTestCase {
    func testDefaultTransportUsesBoundedEphemeralSessionWithoutRedirects() throws {
        let configuration = URLSessionLogisterTransport.session.configuration
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
        XCTAssertTrue(URLSessionLogisterTransport.session.delegate is LogisterRedirectRefusal)

        let redirect = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://logister.example/api/v1/ingest_events")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "https://elsewhere.example/"]
        ))
        let task = URLSession.shared.dataTask(with: URL(string: "https://logister.example/")!)
        let followed = expectation(description: "redirect decision")
        LogisterRedirectRefusal().urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: URL(string: "https://elsewhere.example/")!)
        ) { request in
            XCTAssertNil(request)
            followed.fulfill()
        }
        wait(for: [followed], timeout: 1)
    }

    func testPlainHTTPIsRefusedUnlessLoopbackOrExplicitlyAllowed() {
        let permitted = { (url: String, allow: Bool) in
            LogisterClient.permitsEndpoint(URL(string: url)!, allowInsecure: allow)
        }
        XCTAssertTrue(permitted("https://logister.example/api/v1/ingest_events", false))
        XCTAssertFalse(permitted("http://logister.example/api/v1/ingest_events", false))
        XCTAssertFalse(permitted("ftp://logister.example/", true))
        XCTAssertTrue(permitted("http://localhost:3000/api/v1/ingest_events", false))
        XCTAssertTrue(permitted("http://127.0.0.1:3000/", false))
        XCTAssertTrue(permitted("http://[::1]:3000/", false))
        XCTAssertTrue(permitted("http://logister.localhost/", false))
        XCTAssertFalse(permitted("http://localhost.example.com/", false))
        XCTAssertTrue(permitted("http://10.0.2.2:3000/", true))
    }

    func testInsecureEndpointDropsWithoutQueueingOrSending() async throws {
        let transport = CapturingTransport()
        let directory = hardeningTestDirectory()
        let client = hardeningClient(
            endpoint: "http://logister.example/api/v1/ingest_events",
            transport: transport,
            directory: directory
        )

        let response = try await client.captureMessage("over http")

        let health = await client.healthSnapshot()
        XCTAssertEqual(response.deliveryState, .dropped)
        XCTAssertEqual(transport.sendCount, 0)
        XCTAssertEqual(health.queuedEventCount, 0)
        XCTAssertEqual(health.lastError, "endpoint must use https")

        var configuration = LogisterConfiguration(storageScope: UUID().uuidString, storageDirectory: directory)
        configuration.allowsInsecureTransport = true
        let allowed = hardeningClient(
            endpoint: "http://logister.example/api/v1/ingest_events",
            transport: transport,
            configuration: configuration
        )
        let accepted = try await allowed.captureMessage("explicitly allowed")
        XCTAssertTrue(accepted.accepted)
    }

    func testTokenProviderThatIgnoresCancellationTimesOutAndQueues() async throws {
        var configuration = LogisterConfiguration(storageScope: UUID().uuidString, storageDirectory: hardeningTestDirectory())
        configuration.tokenProviderTimeout = 1
        let transport = CapturingTransport()
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: StubbornTokenProvider(),
            exceptionDataPolicy: .typeAndStacktrace,
            configuration: configuration,
            transport: transport
        )
        let started = Date()

        let response = try await client.captureMessage("slow token")

        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(response.deliveryState, .queued)
        XCTAssertEqual(transport.sendCount, 0)
        let health = await client.healthSnapshot()
        XCTAssertEqual(health.queuedEventCount, 1)
    }

    func testInvalidateDoesNotCancelARefreshOtherCallersAreAwaiting() async throws {
        let store = LogisterTokenStore(provider: SlowCancellableTokenProvider(), refreshSkew: 0, timeout: 10)

        async let waiting = store.mobileIngestToken()
        try await Task.sleep(nanoseconds: 50_000_000)
        await store.invalidate()

        let token = try await waiting
        XCTAssertEqual(token, "slow-token")
    }

    func testRepeatedUnauthorizedResponseKeepsTheEnvelopeQueued() async throws {
        let transport = CapturingTransport(responses: [
            LogisterResponse(statusCode: 401),
            LogisterResponse(statusCode: 401)
        ])
        let provider = SequenceTokenProvider(tokens: [
            LogisterToken(token: "mobile-token-1", expiresAt: Date().addingTimeInterval(300)),
            LogisterToken(token: "mobile-token-2", expiresAt: Date().addingTimeInterval(300))
        ])
        let client = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: provider,
            retryPolicy: .disabled,
            exceptionDataPolicy: .typeAndStacktrace,
            configuration: LogisterConfiguration(storageScope: UUID().uuidString, storageDirectory: hardeningTestDirectory()),
            transport: transport
        )

        let response = try await client.captureMessage("unauthorized")

        let health = await client.healthSnapshot()
        let fetchCount = await provider.fetchCount
        XCTAssertEqual(response.deliveryState, .queued)
        XCTAssertEqual(transport.sendCount, 2)
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(health.queuedEventCount, 1)
        XCTAssertEqual(health.discardedEventCount, 0)
    }

    func testComputedRetryDelaysAreJitteredWithinHalfToFullBackoff() {
        let policy = LogisterRetryPolicy(maximumAttempts: 5, baseDelay: 1, maximumDelay: 30)
        let delays = (0..<200).map { _ in policy.delay(after: 3) }
        XCTAssertTrue(delays.allSatisfy { (2...4).contains($0) })
        XCTAssertGreaterThan(Set(delays).count, 1)
        XCTAssertTrue((0..<50).map { _ in policy.delay(after: 10) }.allSatisfy { (15...30).contains($0) })
        XCTAssertEqual(policy.delay(after: 1, response: LogisterResponse(statusCode: 429, headers: ["Retry-After": "7"])), 7)
        XCTAssertEqual(LogisterRetryPolicy(baseDelay: 0).delay(after: 3), 0)
    }

    func testQueueStoresOneFilePerEnvelopeAndMigratesTheLegacyFile() async throws {
        let directory = hardeningTestDirectory()
        let scope = "per-entry"
        let offline = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: FailingTokenProvider(),
            retryPolicy: .disabled,
            exceptionDataPolicy: .typeAndStacktrace,
            configuration: LogisterConfiguration(storageScope: scope, storageDirectory: directory),
            transport: CapturingTransport()
        )
        _ = try await offline.captureMessage("first")
        _ = try await offline.captureMessage("second")

        let queueDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("delivery-") && $0.pathExtension.isEmpty }
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: queueDirectory.path).count, 2)

        let legacyID = UUID()
        let legacyBody = try JSONSerialization.data(withJSONObject: ["event": ["event_type": "log", "message": "legacy"]])
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "entries": [[
                "id": legacyID.uuidString,
                "capturedAt": Date().timeIntervalSinceReferenceDate,
                "body": legacyBody.base64EncodedString(),
                "attemptCount": 0,
                "priority": 1
            ]]
        ]
        let legacyURL = directory.appendingPathComponent(queueDirectory.lastPathComponent + ".json", isDirectory: false)
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)

        let transport = CapturingTransport()
        let online = LogisterClient(
            endpoint: URL(string: "https://logister.example/api/v1/ingest_events")!,
            tokenProvider: SequenceTokenProvider(tokens: [
                LogisterToken(token: "mobile-token", expiresAt: Date().addingTimeInterval(300))
            ]),
            retryPolicy: .disabled,
            exceptionDataPolicy: .typeAndStacktrace,
            configuration: LogisterConfiguration(storageScope: scope, storageDirectory: directory),
            transport: transport
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))

        let flushed = await online.flushQueuedEvents()

        XCTAssertEqual(flushed, 3)
        XCTAssertTrue(transport.bodies.contains(legacyBody))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: queueDirectory.path).count, 0)
    }
}

private func hardeningTestDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("logister-ios-tests-\(UUID().uuidString)", isDirectory: true)
}

private func hardeningClient(
    endpoint: String,
    transport: CapturingTransport,
    directory: URL = hardeningTestDirectory(),
    configuration: LogisterConfiguration? = nil
) -> LogisterClient {
    LogisterClient(
        endpoint: URL(string: endpoint)!,
        tokenProvider: SequenceTokenProvider(tokens: [
            LogisterToken(token: "mobile-token", expiresAt: Date().addingTimeInterval(300))
        ]),
        exceptionDataPolicy: .typeAndStacktrace,
        configuration: configuration ?? LogisterConfiguration(storageScope: UUID().uuidString, storageDirectory: directory),
        transport: transport
    )
}

/// Ignores cancellation, like a provider wrapping a callback API with no
/// cancellation support.
private struct StubbornTokenProvider: LogisterTokenProvider {
    func fetchToken() async throws -> LogisterToken {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return LogisterToken(token: "late-token", expiresAt: Date().addingTimeInterval(300))
    }
}

/// Throws if its task is cancelled, so a cancelled shared refresh is visible.
private struct SlowCancellableTokenProvider: LogisterTokenProvider {
    func fetchToken() async throws -> LogisterToken {
        try await Task.sleep(nanoseconds: 300_000_000)
        return LogisterToken(token: "slow-token", expiresAt: Date().addingTimeInterval(300))
    }
}
