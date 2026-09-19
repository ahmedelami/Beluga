/// Sender-scoped native collection metadata kept outside the serialized diagnostics snapshot.
public struct WebRTCScreenVideoStatisticsReport: Sendable {
    /// Exact native parser output, without cached delegate-route enrichment. Policy authority
    /// must use this, never `snapshot`; see SCREEN_STARTUP_REGRESSION_GUARDRAILS.md.
    public let nativeSnapshot: WebRTCStatisticsSnapshot
    /// Diagnostic projection that may include a previously observed route.
    public let snapshot: WebRTCStatisticsSnapshot
    /// Native report identity survives cached/filtered copies. This UTC-based value is not a
    /// monotonic clock or proof of a new RTT/BWE measurement; consumers must validate freshness.
    public let nativeReportTimestampMicroseconds: Double

    public init(
        snapshot: WebRTCStatisticsSnapshot,
        nativeReportTimestampMicroseconds: Double
    ) {
        self.nativeSnapshot = snapshot
        self.snapshot = snapshot
        self.nativeReportTimestampMicroseconds = nativeReportTimestampMicroseconds
    }

    private init(
        nativeSnapshot: WebRTCStatisticsSnapshot,
        snapshot: WebRTCStatisticsSnapshot,
        nativeReportTimestampMicroseconds: Double
    ) {
        self.nativeSnapshot = nativeSnapshot
        self.snapshot = snapshot
        self.nativeReportTimestampMicroseconds = nativeReportTimestampMicroseconds
    }

    func restoringRouteIfNeeded(
        _ currentRoute: WebRTCICERouteDiagnostics?
    ) -> Self {
        Self(
            nativeSnapshot: nativeSnapshot,
            snapshot: snapshot.restoringRouteIfNeeded(currentRoute),
            nativeReportTimestampMicroseconds: nativeReportTimestampMicroseconds
        )
    }
}
