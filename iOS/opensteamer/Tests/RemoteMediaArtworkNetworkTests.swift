import XCTest
import UIKit
@testable import opensteamer
@testable import WebRTCTransport

private final class ArtworkURLProtocol: URLProtocol, @unchecked Sendable {
    enum Delivery: Equatable, Sendable {
        case complete
        case holdBeforeHeaders
        case holdAfterBody
    }

    struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let data: Data
        var delivery: Delivery = .complete
        var onHold: (@Sendable () -> Void)? = nil
        var onStop: (@Sendable () -> Void)? = nil
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [URL: Reply] = [:]
    nonisolated(unsafe) private static var requests: [URL: URLRequest] = [:]
    nonisolated(unsafe) private static var active: [URL: ArtworkURLProtocol] = [:]
    private let stateLock = NSLock()
    private var stopped = false
    private var completed = false
    private var reply: Reply?

    static func prepare(_ reply: Reply, url: URL) {
        lock.withLock { replies[url] = reply; requests[url] = nil }
    }

    static func request(for url: URL) -> URLRequest? {
        lock.withLock { requests[url] }
    }

    static func cleanUp(url: URL) {
        let pending = lock.withLock {
            replies[url] = nil
            requests[url] = nil
            return active.removeValue(forKey: url)
        }
        // A failing cancellation mutant must not leave a ten-second fixture request alive.
        pending?.finishFixture()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.lock.withLock({
            Self.requests[url] = request
            Self.active[url] = self
            return Self.replies[url]
        }), let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                          httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        stateLock.withLock { self.reply = reply }
        if reply.delivery == .holdBeforeHeaders {
            reply.onHold?()
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: reply.data.count, by: 4_096) {
            guard !stateLock.withLock({ stopped }) else { return }
            client?.urlProtocol(self, didLoad: reply.data.subdata(in: offset..<min(offset + 4_096, reply.data.count)))
        }
        if reply.delivery == .holdAfterBody {
            reply.onHold?()
            return
        }
        guard stateLock.withLock({
            guard !stopped else { return false }
            completed = true
            return true
        }) else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        let callback = stateLock.withLock { () -> (@Sendable () -> Void)? in
            guard !stopped else { return nil }
            stopped = true
            return reply?.onStop
        }
        if let url = request.url {
            Self.lock.withLock {
                if Self.active[url] === self { Self.active[url] = nil }
            }
        }
        callback?()
    }

    private func finishFixture() {
        let shouldFinish = stateLock.withLock {
            guard !stopped, !completed else { return false }
            completed = true
            return true
        }
        if shouldFinish { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
    }
}

@MainActor
final class RemoteMediaArtworkNetworkTests: XCTestCase {
    private func png() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format)
        return try XCTUnwrap(renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
    }

    private func load(id: String, status: Int = 200, headers: [String: String], data: Data) async throws
        -> RemoteMediaArtworkImage? {
        let reference = try XCTUnwrap(WebRTCRemoteMediaArtworkReference(videoID: id))
        ArtworkURLProtocol.prepare(.init(status: status, headers: headers, data: data), url: reference.url)
        return await loader().load(reference)
    }

    private func loader() -> RemoteMediaArtworkLoader {
        RemoteMediaArtworkLoader {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ArtworkURLProtocol.self]
            return configuration
        }
    }

    func testProductionLoaderReadsBoundedImageWithoutCredentialsOrCookies() async throws {
        let image = try await load(id: "artwork0001", headers: ["Content-Type": "image/png"], data: png())
        XCTAssertEqual(image?.image.width, 8)
        let reference = try XCTUnwrap(WebRTCRemoteMediaArtworkReference(videoID: "artwork0001"))
        let request = try XCTUnwrap(ArtworkURLProtocol.request(for: reference.url))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testBadStatusContentTypeAndOversizedContentLengthFailIndependently() async throws {
        let data = try png()
        let failed = try await load(id: "artwork0002", status: 404, headers: ["Content-Type": "image/png"], data: data)
        let wrongType = try await load(id: "artwork0003", headers: ["Content-Type": "text/html"], data: data)
        let oversized = try await load(id: "artwork0004", headers: [
            "Content-Type": "image/png", "Content-Length": String(RemoteMediaArtworkLoader.maximumBytes + 1)
        ], data: data)
        XCTAssertNil(failed)
        XCTAssertNil(wrongType)
        XCTAssertNil(oversized)
    }

    func testChunkedBodyCannotExceedByteLimitEvenIfImageHeaderIsValid() async throws {
        var data = try png()
        data.append(Data(repeating: 0, count: RemoteMediaArtworkLoader.maximumBytes))
        let oversized = try await load(id: "artwork0005", headers: ["Content-Type": "image/png"], data: data)
        XCTAssertNil(oversized)
    }

    func testStreamingLimitCancelsAnOversizedBodyBeforeItFinishes() async throws {
        let reference = try XCTUnwrap(WebRTCRemoteMediaArtworkReference(videoID: "artwork0007"))
        var data = try png()
        data.append(Data(repeating: 0, count: RemoteMediaArtworkLoader.maximumBytes + 1 - data.count))
        let stopped = expectation(description: "oversized response cancelled before EOF")
        let returned = expectation(description: "streaming bound returns before resource timeout")
        ArtworkURLProtocol.prepare(.init(status: 200, headers: ["Content-Type": "image/png"],
            data: data, delivery: .holdAfterBody, onStop: { stopped.fulfill() }), url: reference.url)
        let loader = loader()
        let task = Task {
            let image = await loader.load(reference)
            XCTAssertNil(image)
            returned.fulfill()
        }
        defer {
            task.cancel()
            ArtworkURLProtocol.cleanUp(url: reference.url)
        }
        // No EOF is delivered: the later decode size check cannot satisfy this oracle.
        await fulfillment(of: [returned, stopped], timeout: 2.5)
    }

    func testOversizedDeclaredLengthCancelsAStalledSmallBody() async throws {
        let reference = try XCTUnwrap(WebRTCRemoteMediaArtworkReference(videoID: "artwork0008"))
        var body = try png()
        body.append(Data(repeating: 0, count: 4_096 - body.count))
        let stopped = expectation(description: "oversized declared response cancelled")
        let returned = expectation(description: "header bound rejects before the small body finishes")
        ArtworkURLProtocol.prepare(.init(status: 200, headers: [
            "Content-Type": "image/png", "Content-Length": String(RemoteMediaArtworkLoader.maximumBytes + 1)
        ], data: body, delivery: .holdAfterBody, onStop: { stopped.fulfill() }), url: reference.url)
        let loader = loader()
        let task = Task {
            let image = await loader.load(reference)
            XCTAssertNil(image)
            returned.fulfill()
        }
        defer {
            task.cancel()
            ArtworkURLProtocol.cleanUp(url: reference.url)
        }
        // A small positive body makes this URLProtocol response observable to URLSession.
        // Only the declared-length guard can reject this valid image prefix before EOF.
        await fulfillment(of: [returned, stopped], timeout: 2.5)
    }

    func testParentCancellationStopsARequestBeforeResponseHeaders() async throws {
        try await assertParentCancellation(id: "artwork0009", delivery: .holdBeforeHeaders, data: Data())
    }

    func testParentCancellationStopsARequestDuringItsBody() async throws {
        try await assertParentCancellation(id: "artwork0010", delivery: .holdAfterBody,
                                           data: Data(try png().prefix(32)))
    }

    private func assertParentCancellation(id: String, delivery: ArtworkURLProtocol.Delivery,
                                          data: Data) async throws {
        let reference = try XCTUnwrap(WebRTCRemoteMediaArtworkReference(videoID: id))
        let held = expectation(description: "request reached selected stalled boundary")
        let stopped = expectation(description: "parent cancellation stops the URL loading task")
        let returned = expectation(description: "cancelled parent returns without an image")
        ArtworkURLProtocol.prepare(.init(status: 200, headers: ["Content-Type": "image/png"],
            data: data, delivery: delivery, onHold: { held.fulfill() }, onStop: { stopped.fulfill() }),
            url: reference.url)
        let loader = loader()
        let task = Task {
            let image = await loader.load(reference)
            XCTAssertNil(image)
            returned.fulfill()
        }
        defer {
            task.cancel()
            ArtworkURLProtocol.cleanUp(url: reference.url)
        }
        await fulfillment(of: [held], timeout: 1)
        task.cancel()
        await fulfillment(of: [returned, stopped], timeout: 2)
    }

    func testRedirectIsRejectedRatherThanFollowingAnUntrustedDestination() throws {
        let reference = try XCTUnwrap(WebRTCRemoteMediaArtworkReference(videoID: "artwork0006"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: reference.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: reference.url, statusCode: 302,
                                                    httpVersion: nil, headerFields: nil))
        let completion = expectation(description: "redirect rejected")
        RemoteMediaArtworkRequestDelegate().urlSession(session, task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://example.invalid/private")!)) { request in
                XCTAssertNil(request)
                completion.fulfill()
            }
        wait(for: [completion], timeout: 1)
    }

    func testAuthenticationChallengeNeverSuppliesCredentials() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://i.ytimg.com")!)
        let space = URLProtectionSpace(host: "i.ytimg.com", port: 443, protocol: "https",
                                       realm: "test", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: ArtworkChallengeSender())
        let completion = expectation(description: "credentials refused")
        RemoteMediaArtworkRequestDelegate().urlSession(session, task: task, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
            completion.fulfill()
        }
        wait(for: [completion], timeout: 1)
    }
}

private final class ArtworkChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
