import Foundation

/// Local display preferences keyed by account identity, never by a mutable directory or token.
enum CodexAccountNames {
    static let key = "openusage.codexAccountNames.v1"

    static func load(defaults: UserDefaults) -> [String: String] {
        guard defaults.object(forKey: key) != nil else { return [:] }
        guard let names = defaults.dictionary(forKey: key) as? [String: String] else {
            AppLog.error(.config, "Codex account names could not be decoded")
            return [:]
        }
        return names
    }

    static func save(_ name: String, identity: String, defaults: UserDefaults) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 80, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw NameError.invalid
        }
        var names = load(defaults: defaults)
        names[identity] = trimmed.isEmpty ? nil : trimmed
        defaults.set(names, forKey: key)
    }

    enum NameError: Error, LocalizedError {
        case invalid
        var errorDescription: String? { "Use a name of up to 80 characters without line breaks." }
    }
}
