#if os(macOS)
import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
import XCTest

final class StartupVideoEncoderBoundaryTraceTests: XCTestCase {
    func testTransparentEncoderCallsAndScalarSnapshotRoundTrip() throws {
        let h = try harness()
        let settings = makeSettings()
        XCTAssertEqual(h.encoder.startEncode(with: settings, numberOfCores: 3), 0)
        XCTAssertTrue(h.native.lastSettings === settings)
        XCTAssertEqual(h.native.lastCores, 3)
        XCTAssertEqual(h.encoder.setBitrate(789, framerate: 5), 0)
        XCTAssertEqual(h.native.lastRate, [789, 5])
        XCTAssertEqual(h.encoder.implementationName(), "boundary-fake")
        XCTAssertNil(h.encoder.scalingSettings())
        XCTAssertEqual(h.encoder.resolutionAlignment, 2)
        XCTAssertTrue(h.encoder.applyAlignmentToAllSimulcastLayers)
        XCTAssertTrue(h.encoder.supportsNativeHandle)
        h.native.emitSynchronously = true
        let info = BoundaryTestCodecInfo()
        var receivedImage: LKRTCEncodedImage?
        h.encoder.setCallback { image, receivedInfo in
            receivedImage = image
            XCTAssertTrue(receivedInfo as AnyObject === h.native.outputInfo)
            return true
        }
        try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
        let frame = try makeFrame(timestamp: 77)
        let types = [NSNumber(value: LKRTCFrameType.videoFrameKey.rawValue), NSNumber(value: 99)]
        XCTAssertEqual(h.encoder.encode(frame, codecSpecificInfo: info, frameTypes: types), 0)
        XCTAssertTrue(h.native.lastFrame === frame)
        XCTAssertTrue(h.native.lastInfo as AnyObject? === info)
        XCTAssertEqual(h.native.lastFrameTypes, types)
        XCTAssertTrue(receivedImage === h.native.lastImage)
        XCTAssertEqual(h.native.callbackResult, true)
        XCTAssertEqual(h.encoder.release(), 0)
        let snapshot = h.trace.finish()
        XCTAssertTrue(snapshot.isVerified, "\(snapshot.failures)")
        XCTAssertEqual(snapshot.schemaVersion, 3)
        XCTAssertEqual(snapshot.capacity, 512)
        XCTAssertEqual(snapshot.rejectionCapacity, 64)
        XCTAssertTrue(snapshot.rejections.isEmpty)
        XCTAssertEqual(snapshot.windowNanoseconds, 6_000_000_000)
        XCTAssertEqual(snapshot.counts.encodeEntryCount, 1)
        XCTAssertEqual(snapshot.counts.encodeReturnCount, 1)
        XCTAssertEqual(snapshot.counts.encodedOutputCount, 1)
        XCTAssertEqual(snapshot.counts.outputCallbackReturnCount, 1)
        let entry = try XCTUnwrap(snapshot.events.first { $0.kind == .encodeEntry })
        let output = try XCTUnwrap(snapshot.events.first { $0.kind == .encodedOutput })
        XCTAssertEqual(entry.sourceTimestampNanoseconds, 1_000_000)
        XCTAssertEqual(output.inputSequence, entry.sequence)
        XCTAssertEqual(output.rtpTimestamp, 77)
        XCTAssertEqual(output.byteCount, 3)
        XCTAssertEqual(output.width, 16)
        XCTAssertEqual(output.height, 16)
        XCTAssertEqual(output.outputOwnership, .active)
        XCTAssertNil(output.releaseRetirementGeneration)
        XCTAssertEqual(snapshot.counts.releaseDrainOutputCount, 0)
        XCTAssertEqual(snapshot.counts.releaseDrainReturnCount, 0)
        XCTAssertEqual(snapshot.events.map(\.sequence), Array(1...UInt64(snapshot.events.count)))
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(StartupVideoEncoderBoundarySnapshot.self, from: data), snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["isVerified"] as? Bool, true)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["pixelBuffer", "payload", "codecInfo", "boundary-fake", "route", "audio"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        XCTAssertEqual(h.trace.finish(), snapshot)
    }

    func testFactoryOptionalCapabilitiesAndNilCreationArePreserved() throws {
        let native = BoundaryTestOptionalFactory()
        let trace = StartupVideoEncoderBoundaryTrace(now: { 100 })
        let factory = try trace.wrapFactory(native)
        XCTAssertTrue(factory.supportedCodecs().first === native.info)
        XCTAssertTrue(factory.implementations?().first === native.alternateInfo)
        XCTAssertTrue(factory.encoderSelector?() as AnyObject? === native.selector)
        let support = factory.queryCodecSupport?(native.info, scalabilityMode: "L1T1")
        XCTAssertTrue(support === native.support)
        XCTAssertTrue(native.queriedInfo === native.info)
        XCTAssertEqual(native.queriedMode, "L1T1")
        for name in optionalFactorySelectors {
            XCTAssertTrue((factory as AnyObject).responds(to: NSSelectorFromString(name)))
        }
        native.returnsNil = true
        XCTAssertNil(factory.createEncoder(native.info))
        XCTAssertTrue(native.createdInfo === native.info)
        try trace.arm(captureStartedAtUptimeNanoseconds: 100)
        let snapshot = trace.finish()
        XCTAssertEqual(snapshot.counts.encoderCreationFailureCount, 1)
        XCTAssertTrue(snapshot.isVerified, "A native nil result is an observed result, not corrupted evidence")
    }

    func testFactoryWithoutOptionalMethodsDoesNotInventCapabilities() throws {
        let native = BoundaryTestFactory()
        let trace = StartupVideoEncoderBoundaryTrace(now: { 100 })
        let factory = try trace.wrapFactory(native)
        for name in optionalFactorySelectors {
            let selector = NSSelectorFromString(name)
            XCTAssertFalse(native.responds(to: selector))
            XCTAssertFalse((factory as AnyObject).responds(to: selector))
        }
        XCTAssertTrue(factory.supportedCodecs().first === native.info)
        XCTAssertNotNil(factory.createEncoder(native.info))
        XCTAssertTrue(native.createdInfo === native.info)
    }

    func testOwnerAndArmAreSingleUseAndRequireValidClocks() throws {
        let trace = StartupVideoEncoderBoundaryTrace(now: { 100 })
        XCTAssertThrowsError(try trace.arm(captureStartedAtUptimeNanoseconds: 100))
        _ = try trace.wrapFactory(BoundaryTestFactory())
        XCTAssertThrowsError(try trace.wrapFactory(BoundaryTestFactory()))
        for invalid in [UInt64(0), UInt64.max] {
            XCTAssertThrowsError(try trace.arm(captureStartedAtUptimeNanoseconds: invalid))
        }
        try trace.arm(captureStartedAtUptimeNanoseconds: 100)
        XCTAssertThrowsError(try trace.arm(captureStartedAtUptimeNanoseconds: 100))
        let snapshot = trace.finish()
        XCTAssertEqual(snapshot.counts.factoryWrapCount, 1)
        XCTAssertEqual(snapshot.counts.armCount, 1)
        XCTAssertTrue(snapshot.failures.contains(.owner))
        XCTAssertTrue(snapshot.failures.contains(.arm))
        XCTAssertThrowsError(try trace.wrapFactory(BoundaryTestFactory()))
        XCTAssertThrowsError(try trace.arm(captureStartedAtUptimeNanoseconds: 100))
        let h = try harness()
        h.clock.set(200)
        _ = h.encoder.setBitrate(100, framerate: 5)
        XCTAssertThrowsError(try h.trace.arm(captureStartedAtUptimeNanoseconds: 201))
    }

    func testFixedWindowKeepsPreCaptureMetadataButExcludesFrameEdges() throws {
        let h = try harness()
        _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 2)
        _ = h.encoder.setBitrate(700, framerate: 5)
        h.encoder.setCallback { _, _ in true }
        _ = h.encoder.encode(try makeFrame(timestamp: 1), codecSpecificInfo: nil, frameTypes: [])
        h.clock.set(200)
        try h.trace.arm(captureStartedAtUptimeNanoseconds: 200)
        XCTAssertEqual(h.native.emit(timestamp: 1), true)
        XCTAssertEqual(h.trace.snapshot().counts.encodedOutputCount, 0,
                       "A pre-capture input cannot become an in-window output witness")
        h.clock.set(6_000_000_199)
        _ = h.encoder.encode(try makeFrame(timestamp: 2), codecSpecificInfo: nil, frameTypes: [])
        h.clock.set(6_000_000_200)
        XCTAssertEqual(h.native.emit(timestamp: 2), true)
        h.native.emitSynchronously = true
        _ = h.encoder.encode(try makeFrame(timestamp: 3), codecSpecificInfo: nil, frameTypes: [])
        _ = h.encoder.setBitrate(500, framerate: 2)
        let snapshot = h.trace.finish()
        XCTAssertTrue(snapshot.isVerified, "Window-edge omissions are not malformed evidence")
        XCTAssertEqual(snapshot.counts.encodeEntryCount, 1)
        XCTAssertEqual(snapshot.counts.encodedOutputCount, 0)
        XCTAssertEqual(snapshot.counts.unmatchedOutputCount, 0)
        XCTAssertGreaterThan(snapshot.counts.outsideWindowEventCount, 0)
        XCTAssertTrue(snapshot.events.filter { $0.kind == .startEntry || $0.kind == .rateEntry }
            .allSatisfy { $0.phase == .beforeCapture })
        XCTAssertTrue(snapshot.events.filter { $0.kind.isFrame }.allSatisfy {
            $0.phase == .captureWindow && $0.uptimeNanoseconds >= 200 && $0.uptimeNanoseconds < 6_000_000_200
        })
    }

    func testCapacityIsBoundedWithoutChangingForwarding() throws {
        let h = try harness(capacity: 4)
        _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
        h.native.emitSynchronously = true
        h.encoder.setCallback { _, _ in true }
        try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
        for timestamp in UInt32(1)...20 {
            XCTAssertEqual(h.encoder.encode(try makeFrame(timestamp: timestamp),
                codecSpecificInfo: nil, frameTypes: []), 0)
        }
        let snapshot = h.trace.finish()
        XCTAssertEqual(snapshot.events.count, 4)
        XCTAssertEqual(snapshot.counts.retainedEventCount, 4)
        XCTAssertGreaterThan(snapshot.counts.droppedEventCount, 0)
        XCTAssertTrue(snapshot.failures.contains(.overflow))
        XCTAssertEqual(h.native.encodeCount, 20)
        XCTAssertEqual(h.native.callbackResult, true)
    }

    func testInvalidAndRegressingClocksCannotCreateEvidence() throws {
        for invalid in [UInt64(0), UInt64(99)] {
            let h = try harness()
            _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
            try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
            let before = h.trace.snapshot().events
            h.clock.set(invalid)
            _ = h.encoder.encode(try makeFrame(timestamp: 1), codecSpecificInfo: nil, frameTypes: [])
            XCTAssertEqual(h.trace.snapshot().events, before)
            XCTAssertTrue(h.trace.finish().failures.contains(.clock))
            XCTAssertEqual(h.native.encodeCount, 1)
        }
        let h = try harness()
        try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
        h.clock.set(200)
        _ = h.encoder.setBitrate(700, framerate: 5)
        h.clock.set(150)
        _ = h.encoder.setBitrate(600, framerate: 5)
        XCTAssertEqual(h.trace.finish().counts.regressingClockCount, 2)

        let armFloor = try harness()
        armFloor.clock.set(200)
        try armFloor.trace.arm(captureStartedAtUptimeNanoseconds: 100)
        armFloor.clock.set(150)
        _ = armFloor.encoder.setBitrate(700, framerate: 5)
        XCTAssertEqual(armFloor.trace.finish().counts.regressingClockCount, 2,
                       "The sampled arm clock is also a monotonic publication floor")
    }

    func testLateCallbacksCannotBorrowReplacementRegistrationOrEncoder() throws {
        let h = try harness()
        _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
        var oldCalls = 0
        h.encoder.setCallback { _, _ in oldCalls += 1; return false }
        try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
        _ = h.encoder.encode(try makeFrame(timestamp: 1), codecSpecificInfo: nil, frameTypes: [])
        let oldCallback = try XCTUnwrap(h.native.callback)
        h.encoder.setCallback(nil)
        XCTAssertFalse(h.native.hasCallback)
        XCTAssertFalse(oldCallback(makeImage(timestamp: 1), h.native.outputInfo))
        XCTAssertEqual(oldCalls, 1)
        XCTAssertEqual(h.trace.snapshot().counts.encodedOutputCount, 0)
        _ = h.encoder.release()
        _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
        h.encoder.setCallback { _, _ in true }
        _ = h.encoder.encode(try makeFrame(timestamp: 1), codecSpecificInfo: nil, frameTypes: [])
        XCTAssertEqual(h.trace.snapshot().counts.duplicateRTPCount, 1,
                       "RTP reuse must not let a prior generation borrow a new submission")
        let second = try XCTUnwrap(h.factory.createEncoder(h.nativeFactory.info))
        _ = second.startEncode(with: makeSettings(), numberOfCores: 1)
        second.setCallback { _, _ in true }
        XCTAssertEqual(h.trace.snapshot().counts.encoderCreatedCount, 2)
        XCTAssertEqual(Set(h.trace.snapshot().events.filter { $0.kind == .encoderCreated }.map(\.encoderID)), [1, 2])
        let snapshot = h.trace.finish()
        let entries = snapshot.events
        XCTAssertFalse(oldCallback(makeImage(timestamp: 1), h.native.outputInfo))
        XCTAssertEqual(h.trace.snapshot().events, entries)
        XCTAssertGreaterThan(h.trace.snapshot().counts.retiredEventCount, 0)
        XCTAssertTrue(snapshot.failures.contains(.callback))
    }

    func testSynchronousCallbackReentryPreservesReturnsAndNil() throws {
        let h = try harness()
        _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
        h.native.emitSynchronously = true
        var callbacks = 0
        h.encoder.setCallback { _, _ in
            callbacks += 1
            _ = h.trace.snapshot()
            _ = h.encoder.release()
            _ = h.encoder.startEncode(with: self.makeSettings(), numberOfCores: 2)
            h.encoder.setCallback(nil)
            return false
        }
        try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
        XCTAssertEqual(h.encoder.encode(try makeFrame(timestamp: 1), codecSpecificInfo: nil, frameTypes: []), 0)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(h.native.callbackResult, false)
        XCTAssertFalse(h.native.hasCallback)
        h.encoder.setCallback { _, _ in true }
        XCTAssertEqual(h.encoder.encode(try makeFrame(timestamp: 2), codecSpecificInfo: nil, frameTypes: []), 0)
        let snapshot = h.trace.finish()
        XCTAssertTrue(snapshot.failures.contains(.callback))
        XCTAssertEqual(snapshot.counts.staleCallbackCount, 1)
        XCTAssertEqual(snapshot.counts.encodedOutputCount, 2)
        XCTAssertEqual(snapshot.counts.outputCallbackReturnCount, 1,
                       "The retired callback return cannot be relabeled as the new generation")
    }

    func testNonzeroNativeResultsAndSuppressedOutputsRemainDiagnostics() throws {
        let h = try harness()
        h.native.startResult = -3
        XCTAssertEqual(h.encoder.startEncode(with: makeSettings(), numberOfCores: 1), -3)
        h.native.startResult = 0
        XCTAssertEqual(h.encoder.startEncode(with: makeSettings(), numberOfCores: 1), 0)
        h.native.rateResult = -4
        XCTAssertEqual(h.encoder.setBitrate(0, framerate: 0), -4)
        h.encoder.setCallback { _, _ in false }
        try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
        h.native.encodeResult = 1
        XCTAssertEqual(h.encoder.encode(try makeFrame(timestamp: 1), codecSpecificInfo: nil, frameTypes: []), 1)
        h.native.encodeResult = -5
        XCTAssertEqual(h.encoder.encode(try makeFrame(timestamp: 2), codecSpecificInfo: nil, frameTypes: []), -5)
        h.native.encodeResult = 0
        h.native.emitSynchronously = true
        _ = h.encoder.encode(try makeFrame(timestamp: 3), codecSpecificInfo: nil, frameTypes: [])
        h.native.releaseResult = -6
        XCTAssertEqual(h.encoder.release(), -6)
        let snapshot = h.trace.finish()
        XCTAssertTrue(snapshot.isVerified, "Return values are observations, not proof of healthy encoding")
        XCTAssertEqual(snapshot.counts.nonzeroReturnCount, 5)
        XCTAssertEqual(snapshot.counts.rejectedCallbackCount, 1)
        XCTAssertEqual(snapshot.counts.encodeEntryCount, 3)
        XCTAssertEqual(snapshot.counts.encodedOutputCount, 1)
    }

    func testMalformedPayloadCannotBecomeEvidence() throws {
        let h = try harness()
        _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
        h.encoder.setCallback { _, _ in true }
        try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
        _ = h.encoder.encode(try makeFrame(timestamp: 1), codecSpecificInfo: nil, frameTypes: [])
        let image = makeImage(timestamp: 1)
        image.encodedWidth = 0
        image.buffer = Data()
        XCTAssertEqual(h.native.callback?(image, h.native.outputInfo), true)
        let snapshot = h.trace.finish()
        XCTAssertEqual(snapshot.counts.encodedOutputCount, 0)
        XCTAssertEqual(snapshot.counts.invalidPayloadCount, 1)
        XCTAssertTrue(snapshot.failures.contains(.payload))
    }

    func testCallbackReceivedDuringReleaseRetainsOriginalInputIdentity() throws {
        let h = try harness()
        _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
        var receivedImage: LKRTCEncodedImage?
        var callbackCount = 0
        h.encoder.setCallback { image, info in
            receivedImage = image
            callbackCount += 1
            XCTAssertTrue(info as AnyObject === h.native.outputInfo)
            return false
        }
        try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
        _ = h.encoder.encode(try makeFrame(timestamp: 77), codecSpecificInfo: nil, frameTypes: [])
        let input = try XCTUnwrap(h.trace.snapshot().events.first { $0.kind == .encodeEntry })
        h.clock.set(200)
        h.native.onRelease = {
            XCTAssertEqual(h.native.emit(timestamp: 77), false)
            XCTAssertTrue(h.trace.snapshot().rejections.isEmpty)
        }
        h.native.releaseResult = -9
        XCTAssertEqual(h.encoder.release(), -9)
        let snapshot = h.trace.finish()
        let submission = try XCTUnwrap(snapshot.events.first { $0.kind == .encodeReturn })
        let releaseEntry = try XCTUnwrap(snapshot.events.first { $0.kind == .releaseEntry })
        let output = try XCTUnwrap(snapshot.events.first { $0.kind == .encodedOutput })
        let returned = try XCTUnwrap(snapshot.events.first { $0.kind == .outputCallbackReturn })
        let releaseReturn = try XCTUnwrap(snapshot.events.first { $0.kind == .releaseReturn })
        XCTAssertEqual(snapshot.schemaVersion, 3)
        XCTAssertEqual(callbackCount, 1)
        XCTAssertTrue(receivedImage === h.native.lastImage)
        XCTAssertEqual(h.native.callbackResult, false)
        XCTAssertEqual(h.native.releaseCount, 1)
        XCTAssertEqual(submission.result, 0)
        XCTAssertLessThan(submission.sequence, releaseEntry.sequence)
        XCTAssertLessThan(releaseEntry.sequence, output.sequence)
        XCTAssertLessThan(output.sequence, returned.sequence)
        XCTAssertLessThan(returned.sequence, releaseReturn.sequence)
        for event in [releaseEntry, output, returned, releaseReturn] {
            XCTAssertEqual(event.encoderID, input.encoderID)
            XCTAssertEqual(event.encoderGeneration, input.encoderGeneration)
            XCTAssertEqual(event.callbackGeneration, input.callbackGeneration)
            XCTAssertEqual(event.releaseRetirementGeneration, input.encoderGeneration + 1)
            XCTAssertEqual(event.uptimeNanoseconds, 200)
        }
        for event in [output, returned] {
            XCTAssertEqual(event.inputSequence, input.sequence)
            XCTAssertEqual(event.rtpTimestamp, 77)
            XCTAssertEqual(event.outputOwnership, .releaseDrain)
        }
        XCTAssertEqual(returned.callbackResult, false)
        XCTAssertEqual(releaseReturn.result, -9)
        XCTAssertTrue(snapshot.rejections.isEmpty)
        XCTAssertEqual(snapshot.counts.staleCallbackCount, 0)
        XCTAssertEqual(snapshot.counts.encodedOutputCount, 1)
        XCTAssertEqual(snapshot.counts.outputCallbackReturnCount, 1)
        XCTAssertEqual(snapshot.counts.releaseDrainOutputCount, 1)
        XCTAssertEqual(snapshot.counts.releaseDrainReturnCount, 1)
        XCTAssertEqual(snapshot.counts.nonzeroReturnCount, 1)
        XCTAssertTrue(snapshot.isVerified, "\(snapshot.failures)")
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(StartupVideoEncoderBoundarySnapshot.self, from: data), snapshot)
    }

    func testReleaseDrainCrossThreadCallbackPreservesOriginalOwnership() throws {
        for returnsWithinRelease in [true, false] {
            let h = try harness()
            let entered = DispatchSemaphore(value: 0)
            let allowReturn = DispatchSemaphore(value: 0)
            let completed = DispatchSemaphore(value: 0)
            defer { allowReturn.signal() }
            _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
            h.encoder.setCallback { image, info in
                XCTAssertEqual(image.timeStamp, 101)
                XCTAssertTrue(info as AnyObject === h.native.outputInfo)
                entered.signal()
                if !returnsWithinRelease {
                    XCTAssertEqual(allowReturn.wait(timeout: .now() + 2), .success)
                }
                return false
            }
            try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
            _ = h.encoder.encode(try makeFrame(timestamp: 101), codecSpecificInfo: nil, frameTypes: [])
            let input = try XCTUnwrap(h.trace.snapshot().events.first { $0.kind == .encodeEntry })
            let invocation = BoundaryTestCallbackInvocation(callback: try XCTUnwrap(h.native.callback),
                image: makeImage(timestamp: 101), info: h.native.outputInfo)
            h.clock.set(200)
            h.native.onRelease = {
                DispatchQueue.global().async {
                    invocation.invoke()
                    completed.signal()
                }
                XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
                if returnsWithinRelease {
                    XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
                }
            }
            XCTAssertEqual(h.encoder.release(), 0)
            if !returnsWithinRelease {
                XCTAssertEqual(h.trace.snapshot().counts.releaseDrainOutputCount, 1)
                XCTAssertEqual(h.trace.snapshot().counts.outputCallbackReturnCount, 0)
                allowReturn.signal()
                XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
            }
            let snapshot = h.trace.finish()
            XCTAssertEqual(invocation.result, false)
            let output = try XCTUnwrap(snapshot.events.first { $0.kind == .encodedOutput })
            XCTAssertEqual(output.inputSequence, input.sequence)
            XCTAssertEqual(output.encoderGeneration, input.encoderGeneration)
            XCTAssertEqual(output.callbackGeneration, input.callbackGeneration)
            XCTAssertEqual(output.outputOwnership, .releaseDrain)
            XCTAssertEqual(output.releaseRetirementGeneration, input.encoderGeneration + 1)
            XCTAssertEqual(snapshot.counts.releaseDrainOutputCount, 1)
            XCTAssertEqual(snapshot.counts.releaseDrainReturnCount, returnsWithinRelease ? 1 : 0)
            XCTAssertEqual(snapshot.counts.outputCallbackReturnCount, returnsWithinRelease ? 1 : 0)
            XCTAssertEqual(snapshot.isVerified, returnsWithinRelease)
            if returnsWithinRelease {
                XCTAssertTrue(snapshot.rejections.isEmpty)
                let returned = try XCTUnwrap(snapshot.events.first { $0.kind == .outputCallbackReturn })
                XCTAssertEqual(returned.outputOwnership, .releaseDrain)
                XCTAssertEqual(returned.releaseRetirementGeneration, output.releaseRetirementGeneration)
                XCTAssertEqual(returned.inputSequence, input.sequence)
            } else {
                let rejection = snapshot.rejections.first
                XCTAssertNotNil(rejection)
                XCTAssertEqual(snapshot.rejections.count, 1)
                XCTAssertEqual(rejection?.reason, .invalidatedDuringCallback)
                XCTAssertEqual(rejection?.releasePhase, .afterRelease)
                XCTAssertEqual(rejection?.inputSequence, input.sequence)
                XCTAssertEqual(rejection?.currentEncoderGeneration, input.encoderGeneration + 1)
                XCTAssertEqual(rejection?.currentCallbackGeneration, input.callbackGeneration)
            }
        }
    }

    func testReleaseDrainRejectsWrongRegistrationAndOtherEncoderIdentity() throws {
        do {
            let h = try harness()
            _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
            h.encoder.setCallback { _, _ in true }
            let oldCallback = try XCTUnwrap(h.native.callback)
            h.encoder.setCallback { _, _ in false }
            try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
            _ = h.encoder.encode(try makeFrame(timestamp: 7), codecSpecificInfo: nil, frameTypes: [])
            let input = try XCTUnwrap(h.trace.snapshot().events.first { $0.kind == .encodeEntry })
            h.native.onRelease = {
                XCTAssertTrue(oldCallback(self.makeImage(timestamp: 7), h.native.outputInfo))
                XCTAssertEqual(h.native.emit(timestamp: 7), false,
                    "An old registration cannot consume the current registration's drain input")
            }
            XCTAssertEqual(h.encoder.release(), 0)
            let snapshot = h.trace.finish()
            let rejection = try XCTUnwrap(snapshot.rejections.first)
            XCTAssertEqual(snapshot.rejections.count, 1)
            XCTAssertEqual(rejection.reason, .staleRegistration)
            XCTAssertEqual(rejection.releasePhase, .duringRelease)
            XCTAssertEqual(rejection.callbackRegistrationGeneration, 1)
            XCTAssertEqual(rejection.currentCallbackGeneration, 2)
            XCTAssertNil(rejection.inputSequence)
            XCTAssertEqual(snapshot.counts.releaseDrainOutputCount, 1)
            XCTAssertEqual(snapshot.counts.releaseDrainReturnCount, 1)
            XCTAssertEqual(snapshot.events.first { $0.kind == .encodedOutput }?.inputSequence, input.sequence)
            XCTAssertFalse(snapshot.isVerified)
        }
        do {
            let h = try harness()
            let otherNative = BoundaryTestEncoder()
            h.nativeFactory.nextEncoder = otherNative
            let other = try XCTUnwrap(h.factory.createEncoder(h.nativeFactory.info))
            _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
            _ = other.startEncode(with: makeSettings(), numberOfCores: 1)
            h.encoder.setCallback { _, _ in true }
            other.setCallback { _, _ in false }
            let otherCallback = try XCTUnwrap(otherNative.callback)
            try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
            _ = h.encoder.encode(try makeFrame(timestamp: 7), codecSpecificInfo: nil, frameTypes: [])
            _ = other.encode(try makeFrame(timestamp: 7), codecSpecificInfo: nil, frameTypes: [])
            XCTAssertEqual(other.release(), 0)
            h.native.onRelease = {
                XCTAssertFalse(otherCallback(self.makeImage(timestamp: 7), otherNative.outputInfo))
                XCTAssertEqual(h.native.emit(timestamp: 7), true)
            }
            XCTAssertEqual(h.encoder.release(), 0)
            let snapshot = h.trace.finish()
            let rejection = try XCTUnwrap(snapshot.rejections.first)
            let output = try XCTUnwrap(snapshot.events.first { $0.kind == .encodedOutput })
            XCTAssertEqual(snapshot.rejections.count, 1)
            XCTAssertEqual(rejection.encoderID, 2)
            XCTAssertEqual(rejection.reason, .inactiveEncoder)
            XCTAssertEqual(rejection.releasePhase, .afterRelease)
            XCTAssertEqual(output.encoderID, 1)
            XCTAssertNotEqual(output.inputSequence, rejection.inputSequence)
            XCTAssertEqual(snapshot.counts.releaseDrainOutputCount, 1)
            XCTAssertEqual(snapshot.counts.releaseDrainReturnCount, 1)
            XCTAssertEqual(snapshot.counts.duplicateRTPCount, 0)
            XCTAssertFalse(snapshot.isVerified)
        }
    }

    func testReleaseDrainRejectsConsumedUnknownAndDuplicateInputs() throws {
        let h = try harness()
        _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
        var callbackCount = 0
        h.encoder.setCallback { _, _ in callbackCount += 1; return true }
        try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
        _ = h.encoder.encode(try makeFrame(timestamp: 1), codecSpecificInfo: nil, frameTypes: [])
        XCTAssertEqual(h.native.emit(timestamp: 1), true)
        _ = h.encoder.encode(try makeFrame(timestamp: 2), codecSpecificInfo: nil, frameTypes: [])
        let inputs = h.trace.snapshot().events.filter { $0.kind == .encodeEntry }
        h.native.onRelease = {
            for timestamp: UInt32 in [1, 2, 2, 3] {
                XCTAssertEqual(h.native.emit(timestamp: timestamp), true)
            }
        }
        XCTAssertEqual(h.encoder.release(), 0)
        let snapshot = h.trace.finish()
        XCTAssertEqual(callbackCount, 5)
        XCTAssertEqual(snapshot.rejections.map(\.rtpTimestamp), [1, 2, 3])
        XCTAssertEqual(snapshot.rejections.map(\.inputSequence), [inputs[0].sequence, inputs[1].sequence, nil])
        XCTAssertTrue(snapshot.rejections.allSatisfy { $0.releasePhase == .duringRelease })
        let outputs = snapshot.events.filter { $0.kind == .encodedOutput }
        XCTAssertEqual(outputs.map(\.rtpTimestamp), [1, 2])
        XCTAssertEqual(outputs.map(\.outputOwnership), [.active, .releaseDrain])
        XCTAssertEqual(snapshot.counts.encodedOutputCount, 2)
        XCTAssertEqual(snapshot.counts.outputCallbackReturnCount, 2)
        XCTAssertEqual(snapshot.counts.releaseDrainOutputCount, 1)
        XCTAssertEqual(snapshot.counts.releaseDrainReturnCount, 1)
        XCTAssertEqual(snapshot.counts.staleCallbackCount, 3)
        XCTAssertFalse(snapshot.isVerified)
    }

    func testReleaseDrainRequiresSuccessfulRecordedEncodeReturn() throws {
        for submissionResult: Int? in [nil, 1, -7] {
            let h = try harness()
            _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
            h.encoder.setCallback { _, _ in false }
            try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
            h.native.encodeResult = submissionResult ?? 0
            h.native.onRelease = {
                if submissionResult == nil {
                    XCTAssertEqual(h.trace.snapshot().counts.encodeReturnCount, 0)
                }
                XCTAssertEqual(h.native.emit(timestamp: 1), false)
            }
            if submissionResult == nil {
                h.native.onEncode = { XCTAssertEqual(h.encoder.release(), 0) }
            }
            XCTAssertEqual(h.encoder.encode(try makeFrame(timestamp: 1), codecSpecificInfo: nil,
                                             frameTypes: []), submissionResult ?? 0)
            if submissionResult != nil { XCTAssertEqual(h.encoder.release(), 0) }
            let snapshot = h.trace.finish()
            XCTAssertEqual(h.native.encodeCount, 1)
            XCTAssertEqual(h.native.releaseCount, 1)
            XCTAssertEqual(snapshot.counts.encodeReturnCount, 1)
            XCTAssertEqual(snapshot.counts.encodedOutputCount, 0)
            XCTAssertEqual(snapshot.counts.outputCallbackReturnCount, 0)
            XCTAssertEqual(snapshot.counts.releaseDrainOutputCount, 0)
            XCTAssertEqual(snapshot.counts.releaseDrainReturnCount, 0)
            XCTAssertEqual(snapshot.rejections.count, 1)
            XCTAssertEqual(snapshot.rejections.first?.releasePhase, .duringRelease)
            XCTAssertNotNil(snapshot.rejections.first?.inputSequence)
            XCTAssertFalse(snapshot.isVerified)
            if submissionResult == nil {
                let released = try XCTUnwrap(snapshot.events.first { $0.kind == .releaseReturn })
                let submitted = try XCTUnwrap(snapshot.events.first { $0.kind == .encodeReturn })
                XCTAssertLessThan(released.sequence, submitted.sequence)
                XCTAssertEqual(submitted.result, 0, "A later successful return cannot authorize an earlier drain")
            }
        }
    }

    func testReleaseDrainLeaseRevokedByLifecycleBeforeOutput() throws {
        for mutation in BoundaryTestLifecycleMutation.allCases {
            let h = try harness()
            _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
            h.encoder.setCallback { _, _ in false }
            let callback = try XCTUnwrap(h.native.callback)
            try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
            _ = h.encoder.encode(try makeFrame(timestamp: 51), codecSpecificInfo: nil, frameTypes: [])
            var releaseCalls = 0
            h.native.onRelease = {
                releaseCalls += 1
                guard releaseCalls == 1 else { return }
                switch mutation {
                case .start: XCTAssertEqual(h.encoder.startEncode(with: self.makeSettings(), numberOfCores: 2), 0)
                case .callback: h.encoder.setCallback { _, _ in true }
                case .nestedRelease: XCTAssertEqual(h.encoder.release(), 0)
                }
                XCTAssertFalse(callback(self.makeImage(timestamp: 51), h.native.outputInfo))
            }
            XCTAssertEqual(h.encoder.release(), 0)
            let snapshot = h.trace.finish()
            XCTAssertEqual(releaseCalls, mutation == .nestedRelease ? 2 : 1)
            XCTAssertEqual(snapshot.counts.encodedOutputCount, 0, "\(mutation)")
            XCTAssertEqual(snapshot.counts.outputCallbackReturnCount, 0)
            XCTAssertEqual(snapshot.counts.releaseDrainOutputCount, 0)
            XCTAssertEqual(snapshot.counts.releaseDrainReturnCount, 0)
            XCTAssertEqual(snapshot.rejections.count, 1)
            XCTAssertEqual(snapshot.rejections.first?.releasePhase, .duringRelease,
                           "Returning from nested release does not restore the outer lease")
            XCTAssertEqual(snapshot.rejections.first?.inputEncoderGeneration, 1)
            XCTAssertEqual(snapshot.failures, [.callback])
        }
    }

    func testReleaseDrainCallbackReturnRejectsLifecycleReentry() throws {
        for mutation in BoundaryTestLifecycleMutation.allCases {
            let h = try harness()
            _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
            h.encoder.setCallback { _, _ in
                switch mutation {
                case .start: XCTAssertEqual(h.encoder.startEncode(with: self.makeSettings(), numberOfCores: 2), 0)
                case .callback: h.encoder.setCallback(nil)
                case .nestedRelease: XCTAssertEqual(h.encoder.release(), 0)
                }
                return false
            }
            try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
            _ = h.encoder.encode(try makeFrame(timestamp: 61), codecSpecificInfo: nil, frameTypes: [])
            var releaseCalls = 0
            h.native.onRelease = {
                releaseCalls += 1
                if releaseCalls == 1 { XCTAssertEqual(h.native.emit(timestamp: 61), false) }
            }
            XCTAssertEqual(h.encoder.release(), 0)
            let snapshot = h.trace.finish()
            let output = try XCTUnwrap(snapshot.events.first { $0.kind == .encodedOutput })
            XCTAssertEqual(output.encoderGeneration, 1)
            XCTAssertEqual(output.outputOwnership, .releaseDrain)
            XCTAssertEqual(output.releaseRetirementGeneration, 2)
            XCTAssertEqual(snapshot.counts.encodedOutputCount, 1)
            XCTAssertEqual(snapshot.counts.outputCallbackReturnCount, 0, "\(mutation)")
            XCTAssertEqual(snapshot.counts.releaseDrainOutputCount, 1)
            XCTAssertEqual(snapshot.counts.releaseDrainReturnCount, 0)
            XCTAssertEqual(snapshot.rejections.count, 1)
            XCTAssertEqual(snapshot.rejections.first?.reason, .invalidatedDuringCallback)
            XCTAssertEqual(snapshot.rejections.first?.releasePhase, .duringRelease)
            XCTAssertEqual(snapshot.rejections.first?.inputSequence, output.inputSequence)
            XCTAssertEqual(snapshot.failures, [.callback])
        }
    }

    func testActiveCallbackCannotBorrowReleaseDrainReturnAuthority() throws {
        let h = try harness()
        let entered = DispatchSemaphore(value: 0)
        let allowReturn = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        defer { allowReturn.signal() }
        _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
        h.encoder.setCallback { _, _ in
            entered.signal()
            XCTAssertEqual(allowReturn.wait(timeout: .now() + 2), .success)
            return true
        }
        try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
        _ = h.encoder.encode(try makeFrame(timestamp: 71), codecSpecificInfo: nil, frameTypes: [])
        let invocation = BoundaryTestCallbackInvocation(callback: try XCTUnwrap(h.native.callback),
            image: makeImage(timestamp: 71), info: h.native.outputInfo)
        h.clock.set(200)
        DispatchQueue.global().async {
            invocation.invoke()
            completed.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        h.native.onRelease = {
            allowReturn.signal()
            XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        }
        XCTAssertEqual(h.encoder.release(), 0)
        let snapshot = h.trace.finish()
        XCTAssertEqual(invocation.result, true)
        let output = try XCTUnwrap(snapshot.events.first { $0.kind == .encodedOutput })
        XCTAssertEqual(output.outputOwnership, .active)
        XCTAssertNil(output.releaseRetirementGeneration)
        XCTAssertEqual(snapshot.counts.encodedOutputCount, 1)
        XCTAssertEqual(snapshot.counts.outputCallbackReturnCount, 0)
        XCTAssertEqual(snapshot.counts.releaseDrainOutputCount, 0)
        XCTAssertEqual(snapshot.counts.releaseDrainReturnCount, 0)
        XCTAssertEqual(snapshot.rejections.count, 1)
        XCTAssertEqual(snapshot.rejections.first?.reason, .invalidatedDuringCallback)
        XCTAssertEqual(snapshot.rejections.first?.releasePhase, .duringRelease)
        XCTAssertEqual(snapshot.rejections.first?.inputSequence, output.inputSequence)
        XCTAssertEqual(snapshot.failures, [.callback])
    }

    func testCallbackReceivedAfterReleaseRetainsOriginalInputIdentity() throws {
        let h = try harness()
        _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
        h.encoder.setCallback { _, _ in true }
        try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
        _ = h.encoder.encode(try makeFrame(timestamp: 88), codecSpecificInfo: nil, frameTypes: [])
        let original = try XCTUnwrap(h.trace.snapshot().events.first { $0.kind == .encodeEntry })
        let oldCallback = try XCTUnwrap(h.native.callback)
        XCTAssertEqual(h.encoder.release(), 0)
        h.clock.set(200)
        XCTAssertTrue(oldCallback(makeImage(timestamp: 88), h.native.outputInfo))
        _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
        h.encoder.setCallback { _, _ in false }
        _ = h.encoder.encode(try makeFrame(timestamp: 99), codecSpecificInfo: nil, frameTypes: [])
        h.clock.set(300)
        XCTAssertTrue(oldCallback(makeImage(timestamp: 88), h.native.outputInfo))
        XCTAssertTrue(oldCallback(makeImage(timestamp: 99), h.native.outputInfo))
        XCTAssertEqual(h.native.emit(timestamp: 99), false,
                       "An old callback must not consume the new registration's pending input")
        let snapshot = h.trace.finish()
        XCTAssertEqual(snapshot.rejections.count, 3)
        let first = snapshot.rejections[0]
        XCTAssertEqual(first.reason, .inactiveEncoder)
        XCTAssertEqual(first.releasePhase, .afterRelease)
        XCTAssertEqual(first.uptimeNanoseconds, 200)
        XCTAssertEqual(first.inputSequence, original.sequence)
        XCTAssertEqual(first.inputEncoderGeneration, 1)
        XCTAssertEqual(first.currentEncoderGeneration, 2)
        let restarted = snapshot.rejections[1]
        XCTAssertEqual(restarted.reason, .staleRegistration)
        XCTAssertEqual(restarted.releasePhase, .afterRelease)
        XCTAssertEqual(restarted.inputSequence, original.sequence)
        XCTAssertEqual(restarted.inputEncoderGeneration, 1)
        XCTAssertEqual(restarted.inputCallbackGeneration, 1)
        XCTAssertEqual(restarted.callbackRegistrationGeneration, 1)
        XCTAssertEqual(restarted.currentEncoderGeneration, 3)
        XCTAssertEqual(restarted.currentCallbackGeneration, 2)
        XCTAssertEqual(restarted.currentEncoderIsActive, true)
        let borrowed = snapshot.rejections[2]
        XCTAssertEqual(borrowed.rtpTimestamp, 99)
        XCTAssertNil(borrowed.inputSequence)
        XCTAssertNil(borrowed.inputEncoderGeneration)
        XCTAssertNil(borrowed.inputCallbackGeneration)
        XCTAssertEqual(snapshot.counts.staleCallbackCount, 3)
        XCTAssertEqual(snapshot.counts.encodedOutputCount, 1)
        XCTAssertEqual(snapshot.counts.outputCallbackReturnCount, 1)
        XCTAssertFalse(snapshot.isVerified)
    }

    func testInvalidationDuringCallbackRetainsOldAndCurrentGenerations() throws {
        for releases in [false, true] {
            let h = try harness()
            _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
            h.encoder.setCallback { _, _ in
                if releases {
                    _ = h.encoder.release()
                    _ = h.encoder.startEncode(with: self.makeSettings(), numberOfCores: 2)
                }
                h.encoder.setCallback(nil)
                h.clock.set(300)
                return false
            }
            try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
            _ = h.encoder.encode(try makeFrame(timestamp: 42), codecSpecificInfo: nil, frameTypes: [])
            h.clock.set(200)
            XCTAssertEqual(h.native.emit(timestamp: 42), false)
            let snapshot = h.trace.finish()
            let rejection = try XCTUnwrap(snapshot.rejections.first)
            XCTAssertEqual(snapshot.rejections.count, 1)
            XCTAssertEqual(rejection.reason, .invalidatedDuringCallback)
            XCTAssertEqual(rejection.releasePhase, releases ? .afterRelease : .none)
            XCTAssertEqual(rejection.uptimeNanoseconds, 300)
            XCTAssertEqual(rejection.rtpTimestamp, 42)
            XCTAssertEqual(rejection.inputEncoderGeneration, 1)
            XCTAssertEqual(rejection.inputCallbackGeneration, 1)
            XCTAssertEqual(rejection.callbackRegistrationGeneration, 1)
            XCTAssertEqual(rejection.currentEncoderGeneration, releases ? 3 : 1)
            XCTAssertEqual(rejection.currentCallbackGeneration, 2)
            XCTAssertEqual(rejection.currentEncoderIsActive, true)
            XCTAssertEqual(snapshot.counts.encodedOutputCount, 1)
            XCTAssertEqual(snapshot.counts.outputCallbackReturnCount, 0)
            XCTAssertEqual(snapshot.counts.staleCallbackCount, 1)
            XCTAssertEqual(snapshot.failures, [.callback])
        }
    }

    func testRejectedObservationsRespectClockCapacityAndRetirement() throws {
        for invalid in [UInt64(0), UInt64(150)] {
            let h = try harness()
            _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
            h.encoder.setCallback { _, _ in
                h.encoder.setCallback(nil)
                h.clock.set(invalid)
                return true
            }
            try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
            _ = h.encoder.encode(try makeFrame(timestamp: 1), codecSpecificInfo: nil, frameTypes: [])
            h.clock.set(200)
            XCTAssertEqual(h.native.emit(timestamp: 1), true)
            let snapshot = h.trace.finish()
            XCTAssertEqual(snapshot.counts.staleCallbackCount, 1)
            XCTAssertTrue(snapshot.rejections.isEmpty)
            XCTAssertTrue(snapshot.failures.contains(.clock))
            XCTAssertTrue(snapshot.failures.contains(.callback))
        }

        let h = try harness()
        _ = h.encoder.startEncode(with: makeSettings(), numberOfCores: 1)
        h.encoder.setCallback { _, _ in true }
        try h.trace.arm(captureStartedAtUptimeNanoseconds: 100)
        _ = h.encoder.encode(try makeFrame(timestamp: 1), codecSpecificInfo: nil, frameTypes: [])
        let callback = try XCTUnwrap(h.native.callback)
        _ = h.encoder.release()
        for index in UInt64(1)...65 {
            h.clock.set(200 + index)
            XCTAssertTrue(callback(makeImage(timestamp: 1), h.native.outputInfo))
        }
        let bounded = h.trace.snapshot()
        XCTAssertEqual(bounded.rejectionCapacity, 64)
        XCTAssertEqual(bounded.rejections.count, 64)
        XCTAssertEqual(bounded.rejections.map(\.sequence), Array(UInt64(1)...64))
        XCTAssertEqual(bounded.rejections.map(\.uptimeNanoseconds), Array(UInt64(201)...264))
        XCTAssertEqual(bounded.counts.retainedRejectionCount, 64)
        XCTAssertEqual(bounded.counts.droppedRejectionCount, 1)
        XCTAssertEqual(bounded.counts.droppedEventCount, 1)
        XCTAssertEqual(bounded.counts.staleCallbackCount, 65)
        XCTAssertTrue(bounded.failures.contains(.overflow))
        h.clock.set(264)
        _ = h.encoder.setBitrate(700, framerate: 5)
        XCTAssertEqual(h.trace.snapshot().counts.regressingClockCount, 2,
                       "Rejected callback observations share the normal event clock floor")
        h.clock.set(6_000_000_100)
        XCTAssertTrue(callback(makeImage(timestamp: 1), h.native.outputInfo))
        XCTAssertEqual(h.trace.snapshot().rejections, bounded.rejections)
        XCTAssertEqual(h.trace.snapshot().counts.staleCallbackCount, 65)
        XCTAssertGreaterThan(h.trace.snapshot().counts.outsideWindowEventCount, 0)
        let retired = h.trace.finish()
        XCTAssertTrue(callback(makeImage(timestamp: 1), h.native.outputInfo))
        XCTAssertEqual(h.trace.snapshot().rejections, retired.rejections)
        XCTAssertGreaterThan(h.trace.snapshot().counts.retiredEventCount, 0)
        XCTAssertFalse(retired.isVerified)
    }

    private var optionalFactorySelectors: [String] {
        ["implementations", "encoderSelector", "queryCodecSupport:scalabilityMode:"]
    }
    private func harness(capacity: Int = 512) throws -> BoundaryTestHarness {
        let clock = BoundaryTestClock()
        let trace = StartupVideoEncoderBoundaryTrace(now: { clock.read() }, capacity: capacity)
        let nativeFactory = BoundaryTestFactory()
        let factory = try trace.wrapFactory(nativeFactory)
        let encoder = try XCTUnwrap(factory.createEncoder(nativeFactory.info))
        return .init(clock: clock, trace: trace, nativeFactory: nativeFactory,
                     factory: factory, native: nativeFactory.encoder, encoder: encoder)
    }
    private func makeSettings() -> LKRTCVideoEncoderSettings {
        let settings = LKRTCVideoEncoderSettings()
        settings.width = 16
        settings.height = 16
        settings.startBitrate = 300
        settings.minBitrate = 100
        settings.maxBitrate = 900
        settings.maxFramerate = 5
        return settings
    }
    private func makeFrame(timestamp: UInt32) throws -> LKRTCVideoFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                                          nil, &buffer), kCVReturnSuccess)
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(buffer)),
                                   rotation: ._0, timeStampNs: 1_000_000)
        frame.timeStamp = Int32(bitPattern: timestamp)
        return frame
    }
    private func makeImage(timestamp: UInt32) -> LKRTCEncodedImage {
        BoundaryTestEncoder.image(timestamp: timestamp)
    }
}

private struct BoundaryTestHarness {
    let clock: BoundaryTestClock
    let trace: StartupVideoEncoderBoundaryTrace
    let nativeFactory: BoundaryTestFactory
    let factory: any LKRTCVideoEncoderFactory
    let native: BoundaryTestEncoder
    let encoder: any LKRTCVideoEncoder
}

private enum BoundaryTestLifecycleMutation: CaseIterable { case start, callback, nestedRelease }

/// One immutable callback invocation crosses the test queue. Its result is published
/// under a lock and all lifetime handshakes are explicit, bounded semaphores.
private final class BoundaryTestCallbackInvocation: @unchecked Sendable {
    private let callback: (LKRTCEncodedImage, any LKRTCCodecSpecificInfo) -> Bool
    private let image: LKRTCEncodedImage
    private let info: any LKRTCCodecSpecificInfo
    private let lock = NSLock()
    private var storedResult: Bool?
    var result: Bool? { lock.withLock { storedResult } }

    init(callback: @escaping (LKRTCEncodedImage, any LKRTCCodecSpecificInfo) -> Bool,
         image: LKRTCEncodedImage, info: any LKRTCCodecSpecificInfo) {
        self.callback = callback
        self.image = image
        self.info = info
    }

    func invoke() {
        let result = callback(image, info)
        lock.withLock { storedResult = result }
    }
}

private final class BoundaryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 100
    func set(_ value: UInt64) { lock.withLock { self.value = value } }
    func read() -> UInt64 { lock.withLock { value } }
}

private final class BoundaryTestCodecInfo: NSObject, LKRTCCodecSpecificInfo {}

private final class BoundaryTestEncoder: NSObject, LKRTCVideoEncoder {
    var callback: ((LKRTCEncodedImage, any LKRTCCodecSpecificInfo) -> Bool)?
    var hasCallback: Bool { callback != nil }
    var emitSynchronously = false
    var startResult = 0
    var encodeResult = 0
    var rateResult: Int32 = 0
    var releaseResult = 0
    var onRelease: (() -> Void)?
    var onEncode: (() -> Void)?
    var lastSettings: LKRTCVideoEncoderSettings?
    var lastCores: Int32?
    var lastRate: [UInt32] = []
    var lastFrame: LKRTCVideoFrame?
    var lastInfo: (any LKRTCCodecSpecificInfo)?
    var lastFrameTypes: [NSNumber] = []
    var lastImage: LKRTCEncodedImage?
    var callbackResult: Bool?
    var encodeCount = 0
    var releaseCount = 0
    let outputInfo = BoundaryTestCodecInfo()
    func setCallback(_ callback: ((LKRTCEncodedImage, any LKRTCCodecSpecificInfo) -> Bool)?) {
        self.callback = callback
    }
    func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        lastSettings = settings
        lastCores = numberOfCores
        return startResult
    }
    func release() -> Int { releaseCount += 1; onRelease?(); return releaseResult }
    func encode(_ frame: LKRTCVideoFrame, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?,
                frameTypes: [NSNumber]) -> Int {
        encodeCount += 1
        lastFrame = frame
        lastInfo = info
        lastFrameTypes = frameTypes
        onEncode?()
        if emitSynchronously { _ = emit(timestamp: UInt32(bitPattern: frame.timeStamp)) }
        return encodeResult
    }
    @discardableResult
    func emit(timestamp: UInt32) -> Bool? {
        let image = Self.image(timestamp: timestamp)
        lastImage = image
        callbackResult = callback?(image, outputInfo)
        return callbackResult
    }
    static func image(timestamp: UInt32) -> LKRTCEncodedImage {
        let image = LKRTCEncodedImage()
        image.timeStamp = timestamp
        image.encodedWidth = 16
        image.encodedHeight = 16
        image.captureTimeMs = 1
        image.buffer = Data([0, 0, 1])
        return image
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        lastRate = [bitrateKbit, framerate]
        return rateResult
    }
    func implementationName() -> String { "boundary-fake" }
    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? { nil }
    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { true }
    var supportsNativeHandle: Bool { true }
}

private class BoundaryTestFactory: NSObject, LKRTCVideoEncoderFactory {
    let encoder = BoundaryTestEncoder()
    var nextEncoder: BoundaryTestEncoder?
    let info = LKRTCVideoCodecInfo(name: "H264", parameters: [:])
    var createdInfo: LKRTCVideoCodecInfo?
    var returnsNil = false
    func createEncoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoEncoder)? {
        createdInfo = info
        return returnsNil ? nil : (nextEncoder ?? encoder)
    }
    func supportedCodecs() -> [LKRTCVideoCodecInfo] { [info] }
}

private final class BoundaryTestSelector: NSObject, LKRTCVideoEncoderSelector {
    func registerCurrentEncoderInfo(_ info: LKRTCVideoCodecInfo) {}
    func encoder(forBitrate bitrate: Int) -> LKRTCVideoCodecInfo? { nil }
    func encoderForBrokenEncoder() -> LKRTCVideoCodecInfo? { nil }
}

private final class BoundaryTestOptionalFactory: BoundaryTestFactory {
    let alternateInfo = LKRTCVideoCodecInfo(name: "H264", parameters: ["profile-level-id": "42e01f"])
    let selector = BoundaryTestSelector()
    let support = LKRTCVideoEncoderCodecSupport(supported: true, isPowerEfficient: true)
    var queriedInfo: LKRTCVideoCodecInfo?
    var queriedMode: String?
    @objc func implementations() -> [LKRTCVideoCodecInfo] { [alternateInfo] }
    @objc func encoderSelector() -> (any LKRTCVideoEncoderSelector)? { selector }
    @objc func queryCodecSupport(_ info: LKRTCVideoCodecInfo, scalabilityMode: String?) -> LKRTCVideoEncoderCodecSupport {
        queriedInfo = info
        queriedMode = scalabilityMode
        return support
    }
}
#endif
