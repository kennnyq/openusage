import Foundation

enum CodexAccountError: Error, LocalizedError {
    case missingLogin, invalidLogin, missingIdentity, accountChanged, credentialsChanged
    var errorDescription: String? {
        switch self {
        case .missingLogin: "No file login in this Codex home. Sign in with file credential storage, then restart OpenUsage."
        case .invalidLogin: "This Codex home's login could not be read. Sign in again with file credential storage."
        case .missingIdentity: "This Codex login does not identify an account. Sign in again, then restart OpenUsage."
        case .accountChanged: "The account in this Codex home changed. Restart OpenUsage to load its new account."
        case .credentialsChanged: "Codex changed this login during refresh. Refresh again to use the updated credentials."
        }
    }
}

/// Shared by the card and its reset service. Coalesces token rotation across concurrent callers.
/// Each source is independently authenticated; tokens are never copied between homes.
@MainActor
final class CodexAccountSession {
    let card: CodexAccountCard
    let authStore: CodexAuthStore
    let client: CodexUsageClient
    private var refreshTask: Task<CodexAuthState, Error>?

    init(card: CodexAccountCard, authStore: CodexAuthStore = CodexAuthStore(),
         client: CodexUsageClient = CodexUsageClient()) {
        self.card = card
        self.authStore = authStore
        self.client = client
    }

    nonisolated static func readAuth(path: String, files: TextFileAccessing) throws -> CodexAuth {
        guard path.hasPrefix("/"), path != "/auth.json" else { throw CodexAccountError.invalidLogin }
        guard let text = try files.readTextIfPresent(path) else { throw CodexAccountError.missingLogin }
        guard let auth = CodexAuthStore.parseAuth(text) else { throw CodexAccountError.invalidLogin }
        guard auth.tokens?.accessToken?.nilIfEmpty != nil else {
            if auth.apiKey?.nilIfEmpty != nil { throw CodexAuthError.usageAPIKey }
            throw CodexAccountError.invalidLogin
        }
        return auth
    }

    nonisolated static func identity(_ auth: CodexAuth) -> String? {
        auth.tokens?.accountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty?.lowercased()
            ?? DefaultAccountObserver.chatGPTAccountID(
                inIDTokenPayload: auth.tokens?.idToken.flatMap(ProviderParse.jwtPayload)
            )?.lowercased()
    }

    func load() async throws -> CodexAuthState {
        let card = card
        let files = authStore.files
        return try await loadOffMainActor {
            var firstError: Error?
            for home in card.homes {
                do {
                    let auth = try Self.readAuth(path: home + "/auth.json", files: files)
                    guard let identity = Self.identity(auth) else { throw CodexAccountError.missingIdentity }
                    guard let expected = card.identityKey, identity == expected else {
                        throw CodexAccountError.accountChanged
                    }
                    return CodexAuthState(auth: auth, source: .file(path: home + "/auth.json"))
                } catch { if firstError == nil { firstError = error } }
            }
            throw firstError ?? CodexAccountError.missingLogin
        }
    }

    func validate(_ state: CodexAuthState) throws {
        guard case .file(let path) = state.source else { throw CodexAccountError.invalidLogin }
        let live = try Self.readAuth(path: path, files: authStore.files)
        guard Self.identity(live) == card.identityKey, card.identityKey != nil,
              Self.identity(state.auth) == card.identityKey else { throw CodexAccountError.accountChanged }
    }

    /// `rejectedToken` forces rotation only if no other caller/CLI has already replaced that token.
    func credentials(rejectedToken: String? = nil) async throws -> CodexAuthState {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { @MainActor in
            var state = try await self.load()
            let forced = rejectedToken != nil && state.auth.tokens?.accessToken == rejectedToken
            guard forced || self.authStore.needsRefresh(state.auth) else { return state }
            guard let refresh = state.auth.tokens?.refreshToken?.nilIfEmpty else { throw CodexAuthError.tokenExpired }
            let original = state
            let response: CodexRefreshResponse
            do {
                response = try await self.client.refreshToken(refresh)
            } catch {
                let live = try await self.load()
                if live.auth.tokens != original.auth.tokens { return live }
                throw error
            }
            try self.validate(original)
            guard case .file(let path) = original.source else { throw CodexAccountError.invalidLogin }
            let live = try Self.readAuth(path: path, files: self.authStore.files)
            guard live.tokens == original.auth.tokens else {
                throw CodexAccountError.credentialsChanged
            }
            state.auth.tokens?.accessToken = response.accessToken
            if let refresh = response.refreshToken { state.auth.tokens?.refreshToken = refresh }
            if let id = response.idToken {
                let identity = DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload: ProviderParse.jwtPayload(id))
                if let identity, identity.lowercased() != self.card.identityKey { throw CodexAccountError.accountChanged }
                state.auth.tokens?.idToken = id
            }
            state.auth.lastRefresh = OpenUsageISO8601.string(from: self.authStore.now())
            try self.save(state, replacing: original)
            return state
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func save(_ state: CodexAuthState, replacing original: CodexAuthState) throws {
        guard case .file(let path) = state.source else { throw CodexAccountError.invalidLogin }
        let text = try authStore.files.readText(path)
        guard let live = CodexAuthStore.parseAuth(text), live.tokens == original.auth.tokens else {
            throw CodexAccountError.credentialsChanged
        }
        // Keep fields owned by newer Codex versions. Atomic, 0600 replacement is provided by files.
        guard var object = ProviderParse.jsonObject(Data(text.utf8)),
              let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state.auth)) as? [String: Any]
        else { throw CodexAccountError.invalidLogin }
        var tokens = object["tokens"] as? [String: Any] ?? [:]
        tokens.merge(encoded["tokens"] as? [String: Any] ?? [:]) { _, new in new }
        object["tokens"] = tokens
        object["last_refresh"] = encoded["last_refresh"]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        try authStore.files.writeText(path, String(decoding: data, as: UTF8.self))
    }
}
