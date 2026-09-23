/// A stale native completion cannot invalidate a successor's accepted recommendation.
enum WorldwideScreenNativeApplicationCache {
    static func requiresNativeReconciliation(
        applied: WorldwideScreenVideoEncodingRecommendation?,
        desired: WorldwideScreenVideoEncodingRecommendation,
        force: Bool
    ) -> Bool {
        force || applied != desired
    }

    /// Fences startup spatial authority around a statistics report collected before a corrective
    /// native sender write. Calling this both before reduction and after reduction prevents an
    /// old partial window from terminating on the report and prevents that pre-write report from
    /// seeding the replacement sender epoch.
    static func policyForSenderConfigurationReconciliation(
        _ policy: WorldwideScreenVideoAdaptationPolicy
    ) -> WorldwideScreenVideoAdaptationPolicy {
        var reconciled = policy
        reconciled.resetForSenderConfigurationEpoch()
        return reconciled
    }

    /// Evaluate all ownership inputs on the owning actor after its last suspension.
    static func invalidateIfCurrent(
        _ recommendation: inout WorldwideScreenVideoEncodingRecommendation?,
        expectedPolicyRevision: UInt64,
        currentPolicyRevision: UInt64,
        otherOwnersAreCurrent: Bool
    ) -> Bool {
        guard expectedPolicyRevision == currentPolicyRevision,
              otherOwnersAreCurrent else {
            return false
        }
        recommendation = nil
        return true
    }

    /// Selects the policy that survives an ambiguous current-owner native write, then sanitizes
    /// startup authority on that final value. Keeping selection and reconciliation in one pure
    /// seam prevents a full-proposal assignment from restoring an incomplete demand proof after
    /// the live policy was already reconciled.
    static func reconciledPolicyAfterCurrentOwnerFailure(
        current: WorldwideScreenVideoAdaptationPolicy,
        proposed: WorldwideScreenVideoAdaptationPolicy,
        commitEntireProposal: Bool,
        capacityProbeOnly: Bool
    ) -> WorldwideScreenVideoAdaptationPolicy {
        var reconciled = current
        reconciled.retainStartupSpatialModeTerminalState(from: proposed)
        reconciled.retainFloorRecoveryAttemptConsumption(from: proposed)
        reconciled.retainSpatialRecoveryTerminalState(from: proposed)
        if commitEntireProposal {
            reconciled = proposed
        } else if capacityProbeOnly {
            reconciled.retainCapacityProbeObservationIdentity(from: proposed)
        }
        reconciled.reconcileStartupSpatialStateAfterNativeFailure(from: proposed)
        return reconciled
    }
}
