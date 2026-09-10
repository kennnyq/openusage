import Foundation
import Observation

/// Edits source paths only. No token material is copied into preferences.
@MainActor
@Observable
final class CodexAccountsEditor {
    static let restartKey = "openusage.codexAccountsRestartRequired"
    private(set) var homes: [String]
    private(set) var needsRestart: Bool
    private(set) var namesByHome: [String: String] = [:]
    private let defaults: UserDefaults
    private let authStore: CodexAuthStore

    init(defaults: UserDefaults = .standard, authStore: CodexAuthStore = CodexAuthStore()) {
        self.defaults = defaults
        self.authStore = authStore
        homes = CodexAccountHomes.load(defaults: defaults)
        needsRestart = defaults.bool(forKey: Self.restartKey)
    }

    func reload() {
        homes = CodexAccountHomes.load(defaults: defaults)
        needsRestart = defaults.bool(forKey: Self.restartKey)
    }

    func add(_ url: URL) async throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let store = authStore
        let automaticHomes = try await loadOffMainActor {
            let auth = try CodexAccountSession.readAuth(path: path + "/auth.json", files: store.files)
            guard CodexAccountSession.identity(auth) != nil else { throw CodexAccountError.missingIdentity }
            // Entering explicit mode should retain the existing file-backed accounts. Only paths
            // are returned across the actor boundary; credentials stay in their original sources.
            return store.loadAuthCandidates().compactMap { candidate -> String? in
                guard candidate.hasUsableAccessToken, CodexAccountSession.identity(candidate.auth) != nil,
                      case .file(let authPath) = candidate.source else { return nil }
                return URL(fileURLWithPath: (authPath as NSString).expandingTildeInPath)
                    .deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            }
        }
        reload()
        var updated = homes.isEmpty ? automaticHomes : homes
        if !updated.contains(path) { updated.append(path) }
        var seen: Set<String> = []
        updated = updated.filter { seen.insert($0).inserted }
        save(updated)
    }

    func refreshNames() async {
        let files = authStore.files
        let selectedHomes = homes
        let names = CodexAccountNames.load(defaults: defaults)
        namesByHome = await loadOffMainActor {
            var result: [String: String] = [:]
            for home in selectedHomes {
                do {
                    let auth = try CodexAccountSession.readAuth(path: home + "/auth.json", files: files)
                    if let identity = CodexAccountSession.identity(auth) { result[home] = names[identity] }
                } catch {
                    AppLog.warn(LogTag.auth("codex"), "account name unavailable: \(error.localizedDescription)")
                }
            }
            return result
        }
    }

    func rename(_ home: String, to name: String) async throws {
        let files = authStore.files
        let identity = try await loadOffMainActor {
            let auth = try CodexAccountSession.readAuth(path: home + "/auth.json", files: files)
            guard let identity = CodexAccountSession.identity(auth) else { throw CodexAccountError.missingIdentity }
            return identity
        }
        try CodexAccountNames.save(name, identity: identity, defaults: defaults)
        needsRestart = true
        defaults.set(true, forKey: Self.restartKey)
        await refreshNames()
        AppLog.info(.config, "Codex account name updated; restart required")
    }

    func remove(_ home: String) {
        reload()
        save(homes.filter { $0 != home })
    }

    private func save(_ updated: [String]) {
        guard updated != homes else { return }
        homes = updated
        defaults.set(updated, forKey: CodexAccountHomes.key)
        needsRestart = true
        defaults.set(true, forKey: Self.restartKey)
        AppLog.info(.config, "Codex account homes updated; restart required")
    }
}
