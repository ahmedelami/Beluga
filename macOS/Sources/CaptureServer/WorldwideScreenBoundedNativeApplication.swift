enum WorldwideScreenBoundedNativeApplicationOutcome<Token: Sendable>: Sendable {
    case applied(Token)
    case expired(rollbackWasProven: Bool)
}

/// Bounds admission and publication of a speculative native mutation.
///
/// An expiry before `apply` proves that native state was untouched. If the
/// deadline passes while `apply` is suspended, the result is not published
/// until rollback has been attempted and its certainty is reported.
enum WorldwideScreenBoundedNativeApplication {
    static func apply<Token: Sendable>(
        deadline: ContinuousClock.Instant?,
        now: @Sendable () -> ContinuousClock.Instant,
        apply: @Sendable () async throws -> Token,
        rollback: @Sendable (Token) async throws -> Bool
    ) async throws -> WorldwideScreenBoundedNativeApplicationOutcome<Token> {
        if let deadline, now() >= deadline {
            return .expired(rollbackWasProven: true)
        }

        let token = try await apply()
        guard let deadline, now() >= deadline else {
            return .applied(token)
        }

        do {
            return .expired(rollbackWasProven: try await rollback(token))
        } catch {
            // The caller must treat native state as unknown and reconcile it.
            return .expired(rollbackWasProven: false)
        }
    }
}
