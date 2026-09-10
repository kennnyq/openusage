import Foundation

extension CodexProvider {
    /// Explicit account cards expose subscription limits only. Legacy machine-wide history cannot
    /// safely be assigned to whichever account currently occupies a home.
    func refreshAccount(_ session: CodexAccountSession) async -> ProviderSnapshot {
        do {
            var state = try await session.credentials()
            var response = try await session.client.fetchUsage(
                accessToken: state.auth.tokens!.accessToken!, accountID: session.card.identityKey
            )
            if response.statusCode == 401 || response.statusCode == 403 {
                state = try await session.credentials(rejectedToken: state.auth.tokens?.accessToken)
                response = try await session.client.fetchUsage(
                    accessToken: state.auth.tokens!.accessToken!, accountID: session.card.identityKey
                )
            }
            var credits: HTTPResponse?
            do {
                credits = try await session.client.fetchResetCredits(
                    accessToken: state.auth.tokens!.accessToken!, accountID: session.card.identityKey
                )
            } catch {
                AppLog.warn(LogTag.plugin(provider.id), "reset-credit fetch failed: \(error.localizedDescription)")
            }
            try session.validate(state)
            let mapped = try CodexUsageMapper.mapUsageResponse(response, resetCredits: credits, now: now())
            return .make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
        } catch {
            AppLog.error(LogTag.auth(provider.id), "account refresh failed: \(error.localizedDescription)")
            return .error(provider: provider, error: error)
        }
    }
}
