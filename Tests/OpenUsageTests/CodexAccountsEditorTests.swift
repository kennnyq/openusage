import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class CodexAccountsEditorTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "CodexAccountsEditorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func auth(_ identity: String) -> String {
        "{\"tokens\":{\"account_id\":\"\(identity)\",\"access_token\":\"secret\"}}"
    }

    func testAddingPrimaryPreservesAutomaticSecondaryAndNeverCopiesCredentials() async throws {
        let defaults = defaults()
        let original = ["/secondary/auth.json": auth("secondary"), "/primary/auth.json": auth("primary")]
        let files = FakeFiles(original)
        let editor = CodexAccountsEditor(defaults: defaults, authStore: CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/secondary"]), files: files, keychain: FakeKeychain()
        ))
        try await editor.add(URL(fileURLWithPath: "/primary"))
        XCTAssertEqual(editor.homes, ["/secondary", "/primary"])
        XCTAssertEqual(CodexAccountHomes.load(defaults: defaults), editor.homes)
        XCTAssertTrue(editor.needsRestart)
        XCTAssertEqual(files.files, original)
        XCTAssertFalse(defaults.dictionaryRepresentation().description.contains("secret"))
        let reopened = CodexAccountsEditor(defaults: defaults)
        XCTAssertTrue(reopened.needsRestart)
        XCTAssertEqual(reopened.homes, editor.homes)
    }

    func testInvalidSelectionKeepsExistingConfiguration() async {
        let defaults = defaults()
        defaults.set(["/secondary"], forKey: CodexAccountHomes.key)
        let editor = CodexAccountsEditor(defaults: defaults, authStore: CodexAuthStore(files: FakeFiles()))
        do {
            try await editor.add(URL(fileURLWithPath: "/missing"))
            XCTFail("Missing login must be rejected")
        } catch {
            XCTAssertTrue(error is CodexAccountError)
        }
        XCTAssertEqual(editor.homes, ["/secondary"])
        XCTAssertFalse(editor.needsRestart)
    }

    func testRemoveOnlyChangesMonitoringAndLastRemovalRestoresAutomaticMode() {
        let defaults = defaults()
        defaults.set(["/secondary", "/primary"], forKey: CodexAccountHomes.key)
        let original = ["/secondary/auth.json": auth("secondary"), "/primary/auth.json": auth("primary")]
        let files = FakeFiles(original)
        let editor = CodexAccountsEditor(defaults: defaults, authStore: CodexAuthStore(files: files))
        editor.remove("/secondary")
        XCTAssertEqual(editor.homes, ["/primary"])
        editor.remove("/primary")
        XCTAssertTrue(editor.homes.isEmpty)
        XCTAssertTrue(editor.needsRestart)
        XCTAssertEqual(files.files, original)
    }

    func testAddingSameFolderIsIdempotent() async throws {
        let defaults = defaults()
        defaults.set(["/primary"], forKey: CodexAccountHomes.key)
        let editor = CodexAccountsEditor(defaults: defaults, authStore: CodexAuthStore(files: FakeFiles([
            "/primary/auth.json": auth("primary")
        ])))
        try await editor.add(URL(fileURLWithPath: "/primary/../primary"))
        XCTAssertEqual(editor.homes, ["/primary"])
        XCTAssertFalse(editor.needsRestart)
    }

    func testRenameFollowsIdentityAcrossHomesAndDoesNotChangeCardID() async throws {
        let defaults = defaults()
        defaults.set(["/primary"], forKey: CodexAccountHomes.key)
        let files = FakeFiles(["/primary/auth.json": auth("account-a"), "/moved/auth.json": auth("account-a")])
        let editor = CodexAccountsEditor(defaults: defaults, authStore: CodexAuthStore(files: files))
        try await editor.rename("/primary", to: "  Primary  ")
        XCTAssertEqual(editor.namesByHome["/primary"], "Primary")
        XCTAssertTrue(editor.needsRestart)
        let observer = DefaultAccountObserver(files: files)
        let store = ProviderAccountsStore(defaults: defaults)
        let first = CodexAccountDiscovery.cards(homes: ["/primary"], observer: observer, store: store,
                                                names: CodexAccountNames.load(defaults: defaults))
        let moved = CodexAccountDiscovery.cards(homes: ["/moved"], observer: observer, store: store,
                                                names: CodexAccountNames.load(defaults: defaults))
        XCTAssertEqual(first.first?.displayName, "Codex — Primary")
        XCTAssertEqual(moved.first?.displayName, "Codex — Primary")
        XCTAssertEqual(first.first?.id, moved.first?.id)
        files.files["/primary/auth.json"] = auth("account-b")
        await editor.refreshNames()
        XCTAssertNil(editor.namesByHome["/primary"], "A new login must not inherit another account's name")
    }

    func testBlankNameRestoresDirectoryDefaultAndInvalidNameDoesNotOverwrite() async throws {
        let defaults = defaults()
        defaults.set(["/primary"], forKey: CodexAccountHomes.key)
        let editor = CodexAccountsEditor(defaults: defaults, authStore: CodexAuthStore(files: FakeFiles([
            "/primary/auth.json": auth("account-a")
        ])))
        try await editor.rename("/primary", to: "Primary")
        do {
            try await editor.rename("/primary", to: String(repeating: "x", count: 81))
            XCTFail("Oversized names must be rejected")
        } catch { XCTAssertTrue(error is CodexAccountNames.NameError) }
        XCTAssertEqual(CodexAccountNames.load(defaults: defaults)["account-a"], "Primary")
        try await editor.rename("/primary", to: " ")
        XCTAssertTrue(CodexAccountNames.load(defaults: defaults).isEmpty)
        XCTAssertNil(editor.namesByHome["/primary"])
    }

    func testAccountControlsRenderWithTwoHomesAndRestartAction() throws {
        let defaults = defaults()
        defaults.set(["/Users/example/.codex-secondary", "/Users/example/.codex-primary"], forKey: CodexAccountHomes.key)
        defaults.set(true, forKey: CodexAccountsEditor.restartKey)
        let view = CodexAccountsSection(editor: CodexAccountsEditor(defaults: defaults))
            .padding(12).frame(width: 360).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.height, 200)
        if let path = ProcessInfo.processInfo.environment["OPENUSAGE_ACCOUNTS_QA_IMAGE"] {
            let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
