/// Sender-scoped native collection metadata kept outside the serialized diagnostics snapshot.
public struct WebRTCScreenVideoStatisticsReport: Sendable {
    public let snapshot: WebRTCStatisticsSnapshot
    /// Native report identity survives cached/filtered copies. This UTC-based value is not a
    /// monotonic clock or proof of a new RTT/BWE measurement; consumers must validate freshness.
    public let nativeReportTimestampMicroseconds: Double

    public init(
        snapshot: WebRTCStatisticsSnapshot,
        nativeReportTimestampMicroseconds: Double
    ) {
        self.snapshot = snapshot
        self.nativeReportTimestampMicroseconds = nativeReportTimestampMicroseconds
    }

    func restoringRouteIfNeeded(
        _ currentRoute: WebRTCICERouteDiagnostics?
    ) -> Self {
        Self(
            snapshot: snapshot.restoringRouteIfNeeded(currentRoute),
            nativeReportTimestampMicroseconds: nativeReportTimestampMicroseconds
        )
    }
}
