import ImageIO
@preconcurrency import MediaPlayer
import UIKit
import XCTest
@testable import opensteamer
@testable import WebRTCTransport

/// Hosted native-presentation oracles, not proof of Lock Screen pixels on a physical iPhone.
/// Every asynchronous assertion awaits the exact production task, including cancelled tasks whose
/// deliberately noncooperative loader still returns an image.
@MainActor
final class RemoteMediaArtworkTests: XCTestCase {
    func testSuspendedArtworkDoesNotDelayMetadataOrControlsAndAttachesToLatestRevision() async throws {
        let loader = makeLoader()
        let coordinator = BackgroundPlaybackCoordinator(
            artworkLoader: loader, installNativeCommandTargets: false
        )
        let owner = coordinator.claimRemoteMediaCommandSender { _ in }
        defer { coordinator.releaseRemoteMediaCommandSender(owner: owner); coordinator.clear() }
        let negotiation = WebRTCRemoteMediaAuthorization()
        coordinator.setRemoteMediaTransportReady(true, owner: owner)
        coordinator.publishRemoteMedia(state(item: item(title: "Initial", elapsed: 12),
                                             negotiation: negotiation), owner: owner)

        // No yield or image completion is needed to publish genuine metadata and controls.
        assertMetadata(title: "Initial", elapsed: 12, rate: 1)
        assertControls(play: false, pause: true)
        XCTAssertNil(nativeArtwork)
        let task = try XCTUnwrap(coordinator.pendingArtworkLoadTask)
        await loader.waitForRequestCount(1)
        coordinator.publishRemoteMedia(state(item: item(title: "Timeline update", elapsed: 32),
                                             revision: 2, negotiation: negotiation), owner: owner)
        coordinator.publishRemoteMedia(state(item: item(title: "Latest paused title", elapsed: 47,
                                                        playing: false), revision: 3,
                                             negotiation: negotiation), owner: owner)
        assertMetadata(title: "Latest paused title", elapsed: 47, rate: 0)
        assertControls(play: true, pause: false)
        XCTAssertNil(nativeArtwork)
        let suspendedCount = await loader.requestCount
        XCTAssertEqual(suspendedCount, 1, "Timeline, title and pause revisions must not refetch")

        let green = try image(color: .green)
        await loader.complete(0, with: green)
        await task.value
        assertMetadata(title: "Latest paused title", elapsed: 47, rate: 0)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused)
        assertControls(play: true, pause: false)
        try assertArtwork(green)

        coordinator.publishRemoteMedia(state(item: item(title: "Resumed title", elapsed: 50),
                                             revision: 4, negotiation: negotiation), owner: owner)
        assertMetadata(title: "Resumed title", elapsed: 50, rate: 1)
        try assertArtwork(green)
        XCTAssertNil(coordinator.pendingArtworkLoadTask)
        let completedCount = await loader.requestCount
        XCTAssertEqual(completedCount, 1)
    }

    func testLateCompletionCannotCrossItemABAWithIdenticalReturningReference() async throws {
        let loader = makeLoader()
        let coordinator = BackgroundPlaybackCoordinator(
            artworkLoader: loader, installNativeCommandTargets: false
        )
        let owner = coordinator.claimRemoteMediaCommandSender { _ in }
        defer { coordinator.releaseRemoteMediaCommandSender(owner: owner); coordinator.clear() }
        let negotiation = WebRTCRemoteMediaAuthorization()
        coordinator.setRemoteMediaTransportReady(true, owner: owner)
        coordinator.publishRemoteMedia(state(item: item(context: "A", title: "Old A"),
                                             negotiation: negotiation), owner: owner)
        let oldA = try XCTUnwrap(coordinator.pendingArtworkLoadTask)
        await loader.waitForRequestCount(1)
        coordinator.publishRemoteMedia(state(item: item(context: "B", title: "B", videoID: "bbbbbbbbbbb"),
                                             revision: 2, negotiation: negotiation), owner: owner)
        let oldB = try XCTUnwrap(coordinator.pendingArtworkLoadTask)
        await loader.waitForRequestCount(2)
        coordinator.publishRemoteMedia(state(item: item(context: "A", title: "Current A", playing: false),
                                             revision: 3, negotiation: negotiation), owner: owner)
        let currentA = try XCTUnwrap(coordinator.pendingArtworkLoadTask)
        await loader.waitForRequestCount(3)
        XCTAssertTrue(oldA.isCancelled)
        XCTAssertTrue(oldB.isCancelled)

        await loader.complete(0, with: try image(color: .red))
        await oldA.value
        XCTAssertNil(nativeArtwork, "An old A image cannot reattach after A → B → A")
        await loader.complete(1, with: try image(color: .blue))
        await oldB.value
        XCTAssertNil(nativeArtwork)
        assertMetadata(title: "Current A", elapsed: 12, rate: 0)
        let green = try image(color: .green)
        await loader.complete(2, with: green)
        await currentA.value
        try assertArtwork(green)
        let references = await loader.references
        XCTAssertEqual(references.map(\.videoID), ["aaaaaaaaaaa", "bbbbbbbbbbb", "aaaaaaaaaaa"])
    }

    func testOwnerReplacementRevokesLateImageEvenWithSameNegotiationContextAndReference() async throws {
        let loader = makeLoader()
        let coordinator = BackgroundPlaybackCoordinator(
            artworkLoader: loader, installNativeCommandTargets: false
        )
        let firstOwner = coordinator.claimRemoteMediaCommandSender { _ in }
        let negotiation = WebRTCRemoteMediaAuthorization()
        let first = state(item: item(), negotiation: negotiation)
        coordinator.setRemoteMediaTransportReady(true, owner: firstOwner)
        coordinator.publishRemoteMedia(first, owner: firstOwner)
        let old = try XCTUnwrap(coordinator.pendingArtworkLoadTask)
        await loader.waitForRequestCount(1)
        let currentOwner = coordinator.claimRemoteMediaCommandSender { _ in }
        defer { coordinator.releaseRemoteMediaCommandSender(owner: currentOwner); coordinator.clear() }
        coordinator.setRemoteMediaTransportReady(true, owner: currentOwner)
        coordinator.publishRemoteMedia(state(item: item(title: "New owner"), negotiation: negotiation),
                                       owner: currentOwner)
        let current = try XCTUnwrap(coordinator.pendingArtworkLoadTask)
        await loader.waitForRequestCount(2)
        await loader.complete(0, with: try image(color: .red))
        await old.value
        XCTAssertNil(nativeArtwork)
        assertMetadata(title: "New owner", elapsed: 12, rate: 1)
        let green = try image(color: .green)
        await loader.complete(1, with: green)
        await current.value
        try assertArtwork(green)
        coordinator.publishRemoteMedia(state(item: item(title: "Retired owner"), revision: 99,
                                             negotiation: negotiation), owner: firstOwner)
        coordinator.setRemoteMediaTransportReady(false, owner: firstOwner)
        coordinator.clearRemoteMedia(owner: firstOwner)
        coordinator.releaseRemoteMediaCommandSender(owner: firstOwner)
        XCTAssertEqual(nativeInfo[MPMediaItemPropertyTitle] as? String, "New owner")
        try assertArtwork(green)
        assertControls(play: false, pause: true)
    }

    func testNegotiationABACannotReattachCancelledImageForSameItem() async throws {
        let loader = makeLoader()
        let presentation = RemoteMediaArtworkPresentation(loader: loader)
        defer { presentation.clear() }
        let owner = RemoteMediaCommandOwnerToken()
        let firstNegotiation = WebRTCRemoteMediaAuthorization()
        let secondNegotiation = WebRTCRemoteMediaAuthorization()
        var changes = 0
        presentation.update(state: state(item: item(), negotiation: firstNegotiation), owner: owner,
                            isReady: true) { changes += 1 }
        let first = try XCTUnwrap(presentation.pendingLoadTask)
        await loader.waitForRequestCount(1)
        presentation.update(state: state(item: item(), revision: 2, negotiation: secondNegotiation),
                            owner: owner, isReady: true) { changes += 1 }
        let second = try XCTUnwrap(presentation.pendingLoadTask)
        await loader.waitForRequestCount(2)
        presentation.update(state: state(item: item(), revision: 3, negotiation: firstNegotiation),
                            owner: owner, isReady: true) { changes += 1 }
        let current = try XCTUnwrap(presentation.pendingLoadTask)
        await loader.waitForRequestCount(3)
        await loader.complete(0, with: try image(color: .red))
        await first.value
        await loader.complete(1, with: try image(color: .blue))
        await second.value
        XCTAssertNil(presentation.image)
        XCTAssertEqual(changes, 0)
        let green = try image(color: .green)
        await loader.complete(2, with: green)
        await current.value
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(presentation.image?.image === green.image)
    }

    func testEachTargetIdentityChangeRetiresImageIndependentlyOfOtherFields() async throws {
        for field in ["owner", "context", "reference"] {
            let loader = makeLoader()
            let presentation = RemoteMediaArtworkPresentation(loader: loader)
            defer { presentation.clear() }
            let owner = RemoteMediaCommandOwnerToken()
            let negotiation = WebRTCRemoteMediaAuthorization()
            var changes = 0
            presentation.update(state: state(item: item(), negotiation: negotiation), owner: owner,
                                isReady: true) { changes += 1 }
            let old = try XCTUnwrap(presentation.pendingLoadTask)
            await loader.waitForRequestCount(1)
            let replacement = item(context: field == "context" ? "B" : "A",
                                   videoID: field == "reference" ? "bbbbbbbbbbb" : "aaaaaaaaaaa")
            presentation.update(state: state(item: replacement, revision: 2, negotiation: negotiation),
                                owner: field == "owner" ? RemoteMediaCommandOwnerToken() : owner,
                                isReady: true) { changes += 1 }
            let current = try XCTUnwrap(presentation.pendingLoadTask)
            XCTAssertTrue(old.isCancelled, field)
            await loader.waitForRequestCount(2)
            await loader.complete(0, with: try image(color: .red))
            await old.value
            XCTAssertNil(presentation.image, field)
            XCTAssertEqual(changes, 0, field)
            let green = try image(color: .green)
            await loader.complete(1, with: green)
            await current.value
            XCTAssertTrue(presentation.image?.image === green.image, field)
            XCTAssertEqual(changes, 1, field)
        }
    }

    func testInitialReadinessStartsDelayedRequestAndRecoveryClearsPictureAndRetiresRequest() async throws {
        let loader = makeLoader()
        let coordinator = BackgroundPlaybackCoordinator(
            artworkLoader: loader, installNativeCommandTargets: false
        )
        let owner = coordinator.claimRemoteMediaCommandSender { _ in }
        defer { coordinator.releaseRemoteMediaCommandSender(owner: owner); coordinator.clear() }
        coordinator.publishRemoteMedia(state(item: item(playing: false)), owner: owner)
        assertMetadata(title: "Track", elapsed: 12, rate: 0)
        assertControls(play: false, pause: false)
        XCTAssertNil(coordinator.pendingArtworkLoadTask)
        let beforeReady = await loader.requestCount
        XCTAssertEqual(beforeReady, 0)

        coordinator.setRemoteMediaTransportReady(true, owner: owner)
        let initial = try XCTUnwrap(coordinator.pendingArtworkLoadTask)
        await loader.waitForRequestCount(1)
        let green = try image(color: .green)
        await loader.complete(0, with: green)
        await initial.value
        try assertArtwork(green)
        coordinator.setRemoteMediaTransportReady(false, owner: owner)
        XCTAssertNil(nativeArtwork, "A recovery boundary immediately removes already visible artwork")
        assertControls(play: false, pause: false)
        coordinator.setRemoteMediaTransportReady(true, owner: owner)
        let retiredRecovery = try XCTUnwrap(coordinator.pendingArtworkLoadTask)
        await loader.waitForRequestCount(2)
        coordinator.setRemoteMediaTransportReady(false, owner: owner)
        coordinator.setRemoteMediaTransportReady(true, owner: owner)
        let freshRecovery = try XCTUnwrap(coordinator.pendingArtworkLoadTask)
        await loader.waitForRequestCount(3)
        await loader.complete(1, with: try image(color: .red))
        await retiredRecovery.value
        XCTAssertNil(nativeArtwork, "Same-item ready false → true must not revive a retired request")
        let blue = try image(color: .blue)
        await loader.complete(2, with: blue)
        await freshRecovery.value
        try assertArtwork(blue)
        assertControls(play: true, pause: false)
        let count = await loader.requestCount
        XCTAssertEqual(count, 3, "Recovery must not reuse the pre-recovery image cache")
    }

    func testMusicWithoutArtworkImmediatelyClearsPictureAndKeepsItsOwnControls() async throws {
        let loader = makeLoader()
        let coordinator = BackgroundPlaybackCoordinator(
            artworkLoader: loader, installNativeCommandTargets: false
        )
        let owner = coordinator.claimRemoteMediaCommandSender { _ in }
        defer { coordinator.releaseRemoteMediaCommandSender(owner: owner); coordinator.clear() }
        let negotiation = WebRTCRemoteMediaAuthorization()
        coordinator.setRemoteMediaTransportReady(true, owner: owner)
        coordinator.publishRemoteMedia(state(item: item(), negotiation: negotiation), owner: owner)
        let initial = try XCTUnwrap(coordinator.pendingArtworkLoadTask)
        await loader.waitForRequestCount(1)
        let green = try image(color: .green)
        await loader.complete(0, with: green)
        await initial.value
        try assertArtwork(green)
        coordinator.publishRemoteMedia(state(item: item(context: "music", title: "Music track",
                                                        playing: false, videoID: nil, source: "Music"),
                                             revision: 2, negotiation: negotiation), owner: owner)
        XCTAssertNil(nativeArtwork)
        XCTAssertNil(coordinator.pendingArtworkLoadTask)
        assertMetadata(title: "Music track", elapsed: 12, rate: 0)
        assertControls(play: true, pause: false)
        let count = await loader.requestCount
        XCTAssertEqual(count, 1)
    }

    func testEveryClearBoundaryRejectsNoncooperativePendingImage() async throws {
        for boundary in ["clearRemoteMedia", "nilItem", "releaseOwner", "musicWithoutArtwork"] {
            let loader = makeLoader()
            let coordinator = BackgroundPlaybackCoordinator(
                artworkLoader: loader, installNativeCommandTargets: false
            )
            let owner = coordinator.claimRemoteMediaCommandSender { _ in }
            defer { coordinator.releaseRemoteMediaCommandSender(owner: owner); coordinator.clear() }
            let negotiation = WebRTCRemoteMediaAuthorization()
            coordinator.setRemoteMediaTransportReady(true, owner: owner)
            coordinator.publishRemoteMedia(state(item: item(), negotiation: negotiation), owner: owner)
            let pending = try XCTUnwrap(coordinator.pendingArtworkLoadTask)
            await loader.waitForRequestCount(1)
            switch boundary {
            case "clearRemoteMedia": coordinator.clearRemoteMedia(owner: owner)
            case "nilItem":
                coordinator.publishRemoteMedia(state(item: nil, revision: 2, negotiation: negotiation),
                                               owner: owner)
            case "releaseOwner": coordinator.releaseRemoteMediaCommandSender(owner: owner)
            default:
                coordinator.publishRemoteMedia(state(item: item(context: "music", title: "Music",
                                                                videoID: nil, source: "Music"),
                                                     revision: 2, negotiation: negotiation), owner: owner)
            }
            XCTAssertTrue(pending.isCancelled, boundary)
            XCTAssertNil(nativeArtwork, boundary)
            await loader.complete(0, with: try image(color: .red))
            await pending.value
            XCTAssertNil(nativeArtwork, boundary)
            if boundary == "musicWithoutArtwork" {
                XCTAssertEqual(nativeInfo[MPMediaItemPropertyTitle] as? String, "Music")
                assertControls(play: false, pause: true)
            } else {
                XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo, boundary)
                assertControls(play: false, pause: false)
            }
        }
    }

    func testPresentationClearRetiresPendingLoadAndClearsCache() async throws {
        let loader = makeLoader()
        let presentation = RemoteMediaArtworkPresentation(loader: loader)
        defer { presentation.clear() }
        let owner = RemoteMediaCommandOwnerToken()
        let received = state(item: item())
        var changes = 0
        presentation.update(state: received, owner: owner, isReady: true) { changes += 1 }
        let old = try XCTUnwrap(presentation.pendingLoadTask)
        await loader.waitForRequestCount(1)
        presentation.clear()
        presentation.update(state: received, owner: owner, isReady: true) { changes += 1 }
        let current = try XCTUnwrap(presentation.pendingLoadTask)
        await loader.waitForRequestCount(2)
        await loader.complete(0, with: try image(color: .red))
        await old.value
        XCTAssertNil(presentation.image)
        XCTAssertEqual(changes, 0)
        await loader.complete(1, with: try image(color: .green))
        await current.value
        XCTAssertNotNil(presentation.image)
        XCTAssertEqual(changes, 1)
        presentation.clear()
        XCTAssertNil(presentation.image)
        presentation.update(state: received, owner: owner, isReady: true) { changes += 1 }
        let afterClear = try XCTUnwrap(presentation.pendingLoadTask)
        await loader.waitForRequestCount(3)
        presentation.clear()
        await loader.complete(2, with: try image(color: .blue))
        await afterClear.value
        XCTAssertNil(presentation.image)
        XCTAssertEqual(changes, 1)
    }

    func testCacheHitRefreshesFourEntryLRUButDoesNotExtendFiveMinuteTTL() async throws {
        let loader = makeLoader()
        var now: TimeInterval = 0
        let presentation = RemoteMediaArtworkPresentation(loader: loader, now: { now })
        defer { presentation.clear() }
        let owner = RemoteMediaCommandOwnerToken()
        let negotiation = WebRTCRemoteMediaAuthorization()
        let green = try image(color: .green)
        var revision: UInt64 = 0
        func select(_ key: String) {
            revision += 1
            presentation.update(
                state: state(item: item(context: key, videoID: String(repeating: key, count: 11)),
                             revision: revision, negotiation: negotiation),
                owner: owner, isReady: true, onChange: {}
            )
        }
        for (index, key) in ["a", "b", "c", "d"].enumerated() {
            select(key)
            let pending = try XCTUnwrap(presentation.pendingLoadTask)
            await loader.waitForRequestCount(index + 1)
            await loader.complete(index, with: green)
            await pending.value
        }
        select("a")
        XCTAssertNil(presentation.pendingLoadTask)
        XCTAssertTrue(presentation.image?.image === green.image)
        let hitCount = await loader.requestCount
        XCTAssertEqual(hitCount, 4)

        select("e")
        let fifth = try XCTUnwrap(presentation.pendingLoadTask)
        await loader.waitForRequestCount(5)
        await loader.complete(4, with: green)
        await fifth.value
        // A was touched most recently; B, not A, must be evicted by the fifth entry.
        select("b")
        XCTAssertNil(presentation.image)
        let evicted = try XCTUnwrap(presentation.pendingLoadTask)
        await loader.waitForRequestCount(6)
        await loader.complete(5, with: green)
        await evicted.value
        now = 299
        select("a")
        XCTAssertNil(presentation.pendingLoadTask)
        XCTAssertTrue(presentation.image?.image === green.image)
        let beforeExpiry = await loader.requestCount
        XCTAssertEqual(beforeExpiry, 6)
        select("e")
        XCTAssertNil(presentation.pendingLoadTask)

        now = 300
        select("a")
        XCTAssertNil(presentation.image)
        let expired = try XCTUnwrap(presentation.pendingLoadTask)
        await loader.waitForRequestCount(7)
        await loader.complete(6, with: green)
        await expired.value
        XCTAssertTrue(presentation.image?.image === green.image)
        let finalCount = await loader.requestCount
        XCTAssertEqual(finalCount, 7)
    }

    func testPNGAndJPEGDecodeIntoBoundedRealImages() throws {
        let source = try image(width: 24, height: 12, color: .green)
        let uiImage = UIImage(cgImage: source.image)
        for data in [try XCTUnwrap(uiImage.pngData()), try XCTUnwrap(uiImage.jpegData(compressionQuality: 0.9))] {
            let decoded = try XCTUnwrap(RemoteMediaArtworkLoader.decode(data))
            XCTAssertEqual(decoded.image.width, 24)
            XCTAssertEqual(decoded.image.height, 12)
            let components = try pixel(decoded.image)
            XCTAssertLessThan(components[0], 8)
            XCTAssertGreaterThan(components[1], 245)
            XCTAssertLessThan(components[2], 8)
            XCTAssertEqual(components[3], 255)
        }
        let large = try image(width: 1_024, height: 768, color: .blue)
        let downsampled = try XCTUnwrap(RemoteMediaArtworkLoader.decode(
            try XCTUnwrap(UIImage(cgImage: large.image).pngData())
        ))
        XCTAssertEqual(downsampled.image.width, RemoteMediaArtworkLoader.maximumDimension)
        XCTAssertEqual(downsampled.image.height, 384)
    }

    func testDecodeRejectsInvalidAndOversizedBytesWithoutRejectingExactLimit() throws {
        XCTAssertNil(RemoteMediaArtworkLoader.decode(Data()))
        XCTAssertNil(RemoteMediaArtworkLoader.decode(Data("not an image".utf8)))
        let png = try XCTUnwrap(UIImage(cgImage: image(color: .green).image).pngData())
        XCTAssertNil(RemoteMediaArtworkLoader.decode(Data(png.prefix(12))))
        var atLimit = png
        atLimit.append(Data(repeating: 0, count: RemoteMediaArtworkLoader.maximumBytes - png.count))
        XCTAssertNotNil(RemoteMediaArtworkLoader.decode(atLimit))
        atLimit.append(0)
        XCTAssertNil(RemoteMediaArtworkLoader.decode(atLimit), "Valid image prefix must not bypass byte cap")
    }

    func testDecodeEnforcesEachSourceDimensionAndTotalPixelBound() throws {
        for (width, height, accepted) in [
            (4_096, 1, true), (1, 4_096, true), (4_097, 1, false), (1, 4_097, false),
            (2_048, 2_048, true), (2_049, 2_048, false)
        ] {
            let source = try image(width: width, height: height, color: .blue)
            let data = try XCTUnwrap(UIImage(cgImage: source.image).pngData())
            XCTAssertLessThan(data.count, RemoteMediaArtworkLoader.maximumBytes,
                              "Fixture must isolate dimensions from compressed byte size")
            let decoded = RemoteMediaArtworkLoader.decode(data)
            XCTAssertEqual(decoded != nil, accepted, "\(width) × \(height)")
            if let decoded {
                XCTAssertLessThanOrEqual(decoded.image.width, 512)
                XCTAssertLessThanOrEqual(decoded.image.height, 512)
            }
        }
    }

    func testDecodeRejectsUnsupportedAndMultipleImageContainers() throws {
        let source = try image(color: .green)
        for (type, count) in [("com.compuserve.gif", 1), ("com.compuserve.gif", 2), ("public.tiff", 1)] {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, count, nil))
            for _ in 0..<count { CGImageDestinationAddImage(destination, source.image, nil) }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            XCTAssertNil(RemoteMediaArtworkLoader.decode(data as Data), "\(type), \(count) images")
        }
    }

    private var nativeInfo: [String: Any] { MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:] }
    private var nativeArtwork: MPMediaItemArtwork? { nativeInfo[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork }

    private func makeLoader() -> SuspendedArtworkLoader {
        let loader = SuspendedArtworkLoader()
        addTeardownBlock { await loader.completeAll() }
        return loader
    }

    private func item(
        context: String = "A", title: String = "Track", elapsed: TimeInterval = 12,
        playing: Bool = true, videoID: String? = "aaaaaaaaaaa", source: String = "YouTube"
    ) -> WebRTCRemoteMediaItem {
        WebRTCRemoteMediaItem(
            contextID: context, sourceName: source, title: title, artist: "Artist", album: "Album",
            playbackState: playing ? .playing : .paused, elapsedTime: elapsed, duration: 120,
            playbackRate: playing ? 1 : 0,
            capabilities: .init(canPlay: !playing, canPause: playing, canSkipForward: true, canSkipBackward: true),
            artwork: videoID.flatMap { WebRTCRemoteMediaArtworkReference(videoID: $0) }
        )
    }

    private func state(
        item: WebRTCRemoteMediaItem?, revision: UInt64 = 1,
        negotiation: WebRTCRemoteMediaAuthorization = WebRTCRemoteMediaAuthorization()
    ) -> WebRTCReceivedRemoteMediaState {
        WebRTCReceivedRemoteMediaState(envelope: WebRTCRemoteMediaStateEnvelope(
            authorization: negotiation, update: .init(revision: revision, item: item)
        ))
    }

    private func assertMetadata(
        title: String, elapsed: TimeInterval, rate: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let info = nativeInfo
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, title, file: file, line: line)
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Artist", file: file, line: line)
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Album", file: file, line: line)
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 120, file: file, line: line)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, elapsed, file: file, line: line)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, rate, file: file, line: line)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, false, file: file, line: line)
    }

    private func assertControls(
        play: Bool, pause: Bool, file: StaticString = #filePath, line: UInt = #line
    ) {
        let commands = MPRemoteCommandCenter.shared()
        XCTAssertEqual(commands.playCommand.isEnabled, play, file: file, line: line)
        XCTAssertEqual(commands.pauseCommand.isEnabled, pause, file: file, line: line)
        XCTAssertEqual(commands.nextTrackCommand.isEnabled, play || pause, file: file, line: line)
        XCTAssertEqual(commands.previousTrackCommand.isEnabled, play || pause, file: file, line: line)
    }

    private func assertArtwork(
        _ expected: RemoteMediaArtworkImage, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let artwork = try XCTUnwrap(nativeArtwork, file: file, line: line)
        let nativeImage = try XCTUnwrap(artwork.image(at: CGSize(width: CGFloat(expected.image.width),
                                                               height: CGFloat(expected.image.height))),
                                        file: file, line: line)
        let decoded = try XCTUnwrap(nativeImage.cgImage, file: file, line: line)
        XCTAssertEqual(decoded.width, expected.image.width, file: file, line: line)
        XCTAssertEqual(decoded.height, expected.image.height, file: file, line: line)
        XCTAssertEqual(try pixel(decoded), try pixel(expected.image), file: file, line: line)
    }

    private func image(width: Int = 4, height: Int = 3, color: UIColor) throws -> RemoteMediaArtworkImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return RemoteMediaArtworkImage(image: try XCTUnwrap(context.makeImage()))
    }

    private func pixel(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: 4))
    }
}

/// Intentionally ignores cancellation until the test returns a value. No sockets, sleeps or disks.
private actor SuspendedArtworkLoader: RemoteMediaArtworkLoading {
    private(set) var references: [WebRTCRemoteMediaArtworkReference] = []
    private var pending: [Int: CheckedContinuation<RemoteMediaArtworkImage?, Never>] = [:]
    private var arrivals: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    var requestCount: Int { references.count }

    func load(_ reference: WebRTCRemoteMediaArtworkReference) async -> RemoteMediaArtworkImage? {
        let index = references.count
        references.append(reference)
        return await withCheckedContinuation { continuation in
            pending[index] = continuation
            let ready = arrivals.filter { $0.count <= references.count }
            arrivals.removeAll { $0.count <= references.count }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    func waitForRequestCount(_ count: Int) async {
        if references.count >= count { return }
        await withCheckedContinuation { arrivals.append((count, $0)) }
    }

    func complete(_ index: Int, with image: RemoteMediaArtworkImage?) {
        pending.removeValue(forKey: index)?.resume(returning: image)
    }

    func completeAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(returning: nil) }
        let waiters = arrivals
        arrivals.removeAll()
        for waiter in waiters { waiter.continuation.resume() }
    }
}
