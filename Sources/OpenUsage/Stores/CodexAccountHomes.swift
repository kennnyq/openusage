import Foundation

/// Machine-local, explicitly selected homes. Empty preserves the legacy single-account provider.
enum CodexAccountHomes {
    static let key = "openusage.codexAccountHomes.v1"

    static func load(defaults: UserDefaults) -> [String] {
        guard defaults.object(forKey: key) != nil else { return [] }
        guard let homes = defaults.stringArray(forKey: key) else {
            AppLog.error(.config, "Codex account homes must be an array of directory paths")
            return ["Invalid Codex Account Homes Setting"]
        }
        return homes
    }
}

struct CodexAccountCard: Equatable, Sendable {
    let id: String
    let identityKey: String?
    let displayName: String
    let homes: [String]
}

@MainActor
enum CodexAccountDiscovery {
    /// Explicit mode uses only selected files, never the service-wide Keychain fallback. Broken
    /// sources remain visible as error cards; persisted records are not evidence of a live login.
    static func cards(
        homes: [String], observer: DefaultAccountObserver, store: ProviderAccountsStore
    ) -> [CodexAccountCard] {
        var sources: [(home: String, identity: String?)] = []
        var seen: Set<String> = []
        for home in homes {
            let expanded = home == "~" || home.hasPrefix("~/")
                ? observer.homeDirectory().path + home.dropFirst() : home
            let canonical = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: String(expanded)).standardizedFileURL.resolvingSymlinksInPath().path
                : String(expanded)
            guard seen.insert(canonical).inserted else { continue }
            var identity: String?
            do {
                let auth = try CodexAccountSession.readAuth(path: canonical + "/auth.json", files: observer.files)
                identity = CodexAccountSession.identity(auth)
                if identity == nil { throw CodexAccountError.missingIdentity }
            } catch {
                AppLog.warn(LogTag.auth("codex"), "configured home unavailable: \(error.localizedDescription)")
            }
            sources.append((canonical, identity))
        }
        var observations: [ProviderAccountsStore.Observation] = []
        for source in sources {
            guard let identity = source.identity else { continue }
            let edge = ProviderAccountSource(kind: .codexHome, anchor: source.home, holdsDefaultSource: false)
            if let index = observations.firstIndex(where: { $0.identityKey == identity }) {
                observations[index].sources.append(edge)
            } else {
                observations.append(.init(family: "codex", identityKey: identity, label: nil, sources: [edge]))
            }
        }
        let records = store.reconcile(with: observations)
        var cards: [CodexAccountCard] = []
        for source in sources {
            let id: String
            let cardHomes: [String]
            if let identity = source.identity {
                guard let record = records.first(where: { $0.family == "codex" && $0.identityKey == identity }),
                      !record.removedTombstone else { continue }
                id = record.id
                cardHomes = sources.filter { $0.identity == identity }.map(\.home)
            } else {
                id = ProviderAccountID.make(family: "codex", identityKey: "unresolved-source:" + source.home)
                cardHomes = [source.home]
            }
            guard !cards.contains(where: { $0.id == id }) else { continue }
            let name = source.home.hasPrefix("/") ? URL(fileURLWithPath: source.home).lastPathComponent : "Invalid Home"
            cards.append(.init(id: id, identityKey: source.identity,
                               displayName: "Codex — \(name)", homes: cardHomes))
        }
        let duplicateNames = Dictionary(grouping: cards, by: \.displayName).filter { $0.value.count > 1 }
        return cards.map { card in
            guard duplicateNames[card.displayName] != nil else { return card }
            return CodexAccountCard(id: card.id, identityKey: card.identityKey,
                                    displayName: card.displayName + " (" + card.id + ")", homes: card.homes)
        }
    }
}
