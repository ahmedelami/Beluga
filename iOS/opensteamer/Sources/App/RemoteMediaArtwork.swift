import Foundation
import ImageIO
import WebRTCTransport

/// CGImage is immutable; decoding stays off the main actor and never touches the audio path.
struct RemoteMediaArtworkImage: @unchecked Sendable {
    let image: CGImage
}

protocol RemoteMediaArtworkLoading: Sendable {
    func load(_ reference: WebRTCRemoteMediaArtworkReference) async -> RemoteMediaArtworkImage?
}

class RemoteMediaArtworkRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Uses the header callback rather than awaiting the first body byte before enforcing limits.
private final class ArtworkDownload: RemoteMediaArtworkRequestDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data?, Never>?
    private var finished = false
    private var acceptedResponse = false
    private var buffer = Data()

    init(url: URL) { self.url = url }

    func data(configuration: URLSessionConfiguration) async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let task = lock.withLock { () -> URLSessionDataTask? in
                    guard !finished else { return nil }
                    self.continuation = continuation
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    self.session = session
                    var request = URLRequest(url: url)
                    request.httpShouldHandleCookies = false
                    request.networkServiceType = .background
                    let task = session.dataTask(with: request)
                    task.priority = URLSessionTask.lowPriority
                    self.task = task
                    return task
                }
                if let task { task.resume() } else { continuation.resume(returning: nil) }
            }
        } onCancel: {
            self.finish(nil)
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200, response.url == url,
              ["image/jpeg", "image/png"].contains(response.mimeType ?? ""),
              response.expectedContentLength <= RemoteMediaArtworkLoader.maximumBytes else {
            completionHandler(.cancel)
            finish(nil)
            return
        }
        let accepted = lock.withLock {
            guard !finished, !acceptedResponse else { return false }
            acceptedResponse = true
            return true
        }
        completionHandler(accepted ? .allow : .cancel)
        if !accepted { finish(nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let accepted = lock.withLock {
            guard !finished, acceptedResponse,
                  data.count <= RemoteMediaArtworkLoader.maximumBytes - buffer.count else { return false }
            buffer.append(data)
            return true
        }
        if !accepted { finish(nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = lock.withLock { error == nil && acceptedResponse && !finished ? buffer : nil }
        finish(data)
    }

    private func finish(_ data: Data?) {
        let resources = lock.withLock { () -> (CheckedContinuation<Data?, Never>?, URLSession?)? in
            guard !finished else { return nil }
            finished = true
            let resources = (continuation, session)
            continuation = nil
            session = nil
            task = nil
            buffer = Data()
            return resources
        }
        guard let resources else { return }
        resources.1?.invalidateAndCancel()
        resources.0?.resume(returning: data)
    }
}

struct RemoteMediaArtworkLoader: RemoteMediaArtworkLoading {
    static let maximumBytes = 256 * 1_024
    static let maximumPixels = 4_194_304
    static let maximumDimension = 512
    let configuration: @Sendable () -> URLSessionConfiguration

    init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.configuration = configuration
    }

    func load(_ reference: WebRTCRemoteMediaArtworkReference) async -> RemoteMediaArtworkImage? {
        let configuration = configuration()
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        guard !Task.isCancelled,
              let data = await ArtworkDownload(url: reference.url).data(configuration: configuration),
              !Task.isCancelled else { return nil }
        return Self.decode(data)
    }

    static func decode(_ data: Data) -> RemoteMediaArtworkImage? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              ["public.jpeg", "public.png"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4_096, height <= 4_096,
              width <= maximumPixels / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              image.width <= maximumDimension, image.height <= maximumDimension else { return nil }
        return RemoteMediaArtworkImage(image: image)
    }
}

/// Advisory decoration, fenced independently of command authorization and metadata revisions.
@MainActor
final class RemoteMediaArtworkPresentation {
    private struct Target {
        let owner: RemoteMediaCommandOwnerToken
        let state: WebRTCReceivedRemoteMediaState
        let reference: WebRTCRemoteMediaArtworkReference

        func matches(_ other: Self) -> Bool {
            owner == other.owner && state.isSameNegotiation(as: other.state)
                && state.update.item?.contextID == other.state.update.item?.contextID
                && reference == other.reference
        }
    }

    private let loader: any RemoteMediaArtworkLoading
    private let now: () -> TimeInterval
    private var target: Target?
    private var epoch = UUID()
    private var task: Task<Void, Never>?
    private var cache: [(reference: WebRTCRemoteMediaArtworkReference,
                         image: RemoteMediaArtworkImage, timestamp: TimeInterval)] = []
    private(set) var image: RemoteMediaArtworkImage?
    var pendingLoadTask: Task<Void, Never>? { task }

    init(loader: any RemoteMediaArtworkLoading, now: @escaping () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime
    }) {
        self.loader = loader
        self.now = now
    }

    deinit { task?.cancel() }

    func clear() {
        epoch = UUID()
        task?.cancel()
        task = nil
        target = nil
        image = nil
        cache.removeAll()
    }

    func update(
        state: WebRTCReceivedRemoteMediaState?, owner: RemoteMediaCommandOwnerToken?,
        isReady: Bool, onChange: @escaping @MainActor () -> Void
    ) {
        guard isReady, let owner, let state, let reference = state.update.item?.artwork else {
            clear()
            return
        }
        let next = Target(owner: owner, state: state, reference: reference)
        if target?.matches(next) == true { return }
        let sameOwner = target.map { $0.owner == owner && $0.state.isSameNegotiation(as: state) } ?? false
        if !sameOwner { cache.removeAll() }
        epoch = UUID()
        task?.cancel()
        task = nil
        target = next
        image = nil
        cache.removeAll { now() - $0.timestamp >= 300 }
        if let index = cache.firstIndex(where: { $0.reference == reference }) {
            let cached = cache.remove(at: index)
            cache.append(cached)
            image = cached.image
            return
        }
        let admittedEpoch = epoch
        let loader = loader
        task = Task { [weak self] in
            var loaded = await loader.load(reference)
            // One bounded retry; timeline polls must not create an image-request loop.
            if loaded == nil, !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                loaded = await loader.load(reference)
            }
            guard !Task.isCancelled, let self, self.epoch == admittedEpoch,
                  self.target?.matches(next) == true else { return }
            self.task = nil
            guard let loaded else { return }
            self.image = loaded
            self.cache.append((reference, loaded, self.now()))
            if self.cache.count > 4 { self.cache.removeFirst(self.cache.count - 4) }
            onChange()
        }
    }
}
