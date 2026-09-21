/// A stale native completion cannot invalidate a successor's accepted recommendation.
enum WorldwideScreenNativeApplicationCache {
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
}
