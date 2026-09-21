#if os(macOS)
import Foundation
import RemoteSessionCore

enum WebRTCMacStartupFieldTrials {
    static let baseline = "WebRTC-Bwe-ProbingBehavior/min_packet_size:0/"
}

#if DEBUG
enum WebRTCStartupPacingFactor: String, Sendable {
    case control = "1.0"
    case candidate = "1.15"

    var value: Double { self == .control ? 1 : 1.15 }
}

enum WebRTCStartupProbeDurationExperiment: String, Sendable {
    case control15, candidate40
}

/// Pure composition: preserve the complete baseline, overriding no existing trial.
extension WebRTCMacStartupFieldTrials {
    static func withPacingFactor(
        _ factor: WebRTCStartupPacingFactor, baseline: String = Self.baseline,
        observeEstimator: Bool = false,
        holdDelayGrowthInALR: Bool = false,
        skipProbesBelowCurrentEstimate: Bool = false,
        probeDurationExperiment: WebRTCStartupProbeDurationExperiment? = nil
    ) throws -> String {
        guard baseline.utf8.count <= 16_384, baseline.hasSuffix("/") else {
            throw WebRTCTransportError.nativeFailure("Malformed startup field-trial baseline")
        }
        let fields = baseline.dropLast().split(separator: "/", omittingEmptySubsequences: false)
        guard !fields.isEmpty, fields.count.isMultiple(of: 2),
              fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7f } }) else {
            throw WebRTCTransportError.nativeFailure("Malformed startup field-trial baseline")
        }
        var keys = Set<String>()
        for index in stride(from: 0, to: fields.count, by: 2) {
            let key = String(fields[index])
            guard keys.insert(key).inserted,
                  key != "WebRTC-ProbingScreenshareBwe",
                  key != "WebRTC-Bwe-InjectedCongestionController",
                  key != "WebRTC-DontIncreaseDelayBasedBweInAlr",
                  key != "WebRTC-Bwe-ProbingConfiguration",
                  key != "WebRTC-StrictPacingAndProbing" else {
                throw WebRTCTransportError.nativeFailure("Conflicting startup pacing field trial")
            }
            guard probeDurationExperiment == nil || key != "WebRTC-Bwe-ProbingBehavior"
                    || fields[index + 1] == "min_packet_size:0" else {
                throw WebRTCTransportError.nativeFailure("Probe duration requires unchanged probing behavior")
            }
        }
        guard !observeEstimator || factor == .control else {
            throw WebRTCTransportError.nativeFailure("Estimator observer requires unchanged control factor")
        }
        guard !holdDelayGrowthInALR || (observeEstimator && factor == .control) else {
            throw WebRTCTransportError.nativeFailure("ALR delay-growth hold requires the control estimator observer")
        }
        guard !skipProbesBelowCurrentEstimate || (holdDelayGrowthInALR && observeEstimator && factor == .control) else {
            throw WebRTCTransportError.nativeFailure("ALR probe cap requires the held control estimator observer")
        }
        guard probeDurationExperiment == nil || (factor == .control && observeEstimator
                && holdDelayGrowthInALR && skipProbesBelowCurrentEstimate
                && keys.contains("WebRTC-Bwe-ProbingBehavior")) else {
            throw WebRTCTransportError.nativeFailure("Probe duration requires the complete held probe-cap control")
        }
        let duration = probeDurationExperiment == .candidate40 ? ",min_probe_duration:40ms" : ""
        return baseline + "WebRTC-ProbingScreenshareBwe/\(factor.rawValue),2875,80,40,-60,3/"
            + (observeEstimator ? "WebRTC-Bwe-InjectedCongestionController/Enabled/" : "")
            + (holdDelayGrowthInALR ? "WebRTC-DontIncreaseDelayBasedBweInAlr/Enabled/" : "")
            + (skipProbesBelowCurrentEstimate
               ? "WebRTC-Bwe-ProbingConfiguration/skip_if_est_larger_than_fraction_of_max:1.0,skip_max_allocated_scale:2.0\(duration)/" : "")
    }
}

/// Process-scoped experiments never reopen ordinary admission or retune a live factory.
final class WebRTCStartupPacingAdmission: @unchecked Sendable {
    private struct Session {
        let token: UUID
        let trials: String
        var admittedRoles: UInt8 = 0
    }
    private enum State {
        case pristine, ordinary, experiment(Session), retired(Session)
    }
    private let lock = NSLock()
    private var state: State = .pristine

    func reserve(factor: WebRTCStartupPacingFactor, observeEstimator: Bool = false,
                 holdDelayGrowthInALR: Bool = false,
                 skipProbesBelowCurrentEstimate: Bool = false,
                 probeDurationExperiment: WebRTCStartupProbeDurationExperiment? = nil) throws -> UUID {
        let trials = try WebRTCMacStartupFieldTrials.withPacingFactor(factor,
            observeEstimator: observeEstimator, holdDelayGrowthInALR: holdDelayGrowthInALR,
            skipProbesBelowCurrentEstimate: skipProbesBelowCurrentEstimate,
            probeDurationExperiment: probeDurationExperiment)
        return try lock.withLock {
            guard case .pristine = state else {
                throw WebRTCTransportError.nativeFailure("Pacing experiment requires an unused process")
            }
            let token = UUID()
            state = .experiment(Session(token: token, trials: trials))
            return token
        }
    }

    func admit(role: RemotePeerRole, topology: WebRTCTransportMediaTopology, token: UUID?) throws {
        try lock.withLock {
            switch state {
            case .pristine:
                guard token == nil else { throw rejection }
                state = .ordinary
            case .ordinary:
                guard token == nil else { throw rejection }
            case .experiment(var session):
                guard token == session.token, topology == .videoControlOnly else { throw rejection }
                let roleBit: UInt8 = role == .host ? 1 : 2
                guard session.admittedRoles & roleBit == 0 else { throw rejection }
                session.admittedRoles |= roleBit
                state = .experiment(session)
            case .retired:
                throw rejection
            }
        }
    }

    @discardableResult
    func retire(token: UUID) -> Bool {
        lock.withLock {
            guard case .experiment(let session) = state, token == session.token else { return false }
            // Keep the frozen snapshot for an already-admitted synchronous initializer.
            // No later initializer, including the same token, can enter this process.
            state = .retired(session)
            return true
        }
    }

    var frozenConfiguration: String? {
        lock.withLock {
            switch state {
            case .pristine: nil
            case .ordinary: WebRTCMacStartupFieldTrials.baseline
            case .experiment(let session), .retired(let session): session.trials
            }
        }
    }

    private var rejection: WebRTCTransportError {
        .nativeFailure("Peer is outside the isolated startup pacing experiment")
    }
}

enum WebRTCStartupPacingExperimentOptIn {
    static func validate(selectedTest: String, arguments: [String], environment: [String: String],
                         factor: WebRTCStartupPacingFactor = .control,
                         observeEstimator: Bool = false, holdDelayGrowthInALR: Bool = false,
                         skipProbesBelowCurrentEstimate: Bool = false,
                         defaultPacingCohort: Bool = false,
                         probeDurationExperiment: WebRTCStartupProbeDurationExperiment? = nil,
                         observeEncoderBoundary: Bool = false) throws {
        let ordinary = Set([
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testPacingFactorControlWeak",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testPacingFactorCandidateWeak"
        ])
        let estimator = Set([
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorObserverWeak",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorObserverDelayedDynamic",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorObserverConstruction"
        ])
        let alrGrowthHold = Set([
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRGrowthHoldWeak",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRGrowthHoldDisabledRecovery",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRGrowthHoldEnabledRecovery",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRGrowthHoldSecondDrop",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRGrowthHoldAmple"
        ])
        let alrProbeCap = Set([
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapRecoveryCadenceDiagnostic",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapWeak",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapDisabledRecovery",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapEnabledRecovery",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapSecondDrop",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapAmple"
        ])
        let defaultPacingControl = Set([
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorDefaultPacingDelayedDynamicControl"
        ])
        let defaultPacingCandidate = Set([
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapDefaultPacingDelayedDynamic",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapDefaultPacingWeak",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapDefaultPacingDisabledRecovery",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapDefaultPacingEnabledRecovery",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapDefaultPacingSecondDrop",
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapDefaultPacingAmple"
        ])
        let legacyAllowed = skipProbesBelowCurrentEstimate ? alrProbeCap
            : (holdDelayGrowthInALR ? alrGrowthHold : (observeEstimator ? estimator : ordinary))
        let allowed: Set<String>
        if observeEncoderBoundary {
            allowed = [
                "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEncoderBoundaryMovingRecoveryDiagnostic"
            ]
        } else {
            switch probeDurationExperiment {
            case .some(.control15):
                allowed = [
                    "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration15DelayedControl",
                    "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration15MovingWeakControl",
                    "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration15MovingRecoveryControl"
                ]
            case .some(.candidate40):
                allowed = [
                    "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration40DelayedCandidate",
                    "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration40MovingWeakCandidate",
                    "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration40MovingRecoveryCandidate"
                ]
            case .none:
                allowed = defaultPacingCohort
                    ? (skipProbesBelowCurrentEstimate ? defaultPacingCandidate : defaultPacingControl)
                    : legacyAllowed
            }
        }
        guard !observeEncoderBoundary || (probeDurationExperiment == .control15
                && factor == .control && observeEstimator && holdDelayGrowthInALR
                && skipProbesBelowCurrentEstimate && !defaultPacingCohort) else {
            throw WebRTCTransportError.nativeFailure("Encoder boundary tracing requires its isolated control15 recovery diagnostic")
        }
        guard probeDurationExperiment == nil || (factor == .control && observeEstimator
                && holdDelayGrowthInALR && skipProbesBelowCurrentEstimate && !defaultPacingCohort),
              !defaultPacingCohort || (observeEstimator
                && holdDelayGrowthInALR == skipProbesBelowCurrentEstimate),
              !skipProbesBelowCurrentEstimate || (holdDelayGrowthInALR && observeEstimator),
              !holdDelayGrowthInALR || observeEstimator,
              environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] == "1",
              environment["OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT"] == "1",
              allowed.contains(selectedTest),
              arguments.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) == "xctest",
              arguments.last?.hasSuffix("/BelugaPackageTests.xctest") == true,
              arguments.filter({ $0 == "-XCTest" }).count == 1,
              let selectionIndex = arguments.firstIndex(of: "-XCTest"),
              arguments.indices.contains(selectionIndex + 1),
              arguments[selectionIndex + 1] == selectedTest else {
            throw WebRTCTransportError.nativeFailure("Pacing trial requires one explicitly selected XCTest process")
        }
    }
}
#endif
#endif
