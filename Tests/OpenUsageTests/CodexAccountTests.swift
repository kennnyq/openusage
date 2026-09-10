import XCTest
@testable import OpenUsage

@MainActor
final class CodexAccountTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "CodexAccountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    nonisolated private static func auth(_ account: String, token: String = "token", expired: Bool = false) -> String {
        """
        {"tokens":{"account_id":"\(account)","access_token":"\(token)","refresh_token":"refresh-\(account)","future_token_field":true},"future_field":42,"last_refresh":"\(expired ? "2000" : "2099")-01-01T00:00:00Z"}
        """
    }

    private func session(_ account: String, files: TextFileAccessing, http: AccountHTTP) -> CodexAccountSession {
        CodexAccountSession(
            card: .init(id: "codex@\(account)", identityKey: account, displayName: "Codex — \(account)", homes: ["/\(account)"]),
            authStore: CodexAuthStore(files: files, keychain: FakeKeychain(Self.auth("wrong"))),
            client: CodexUsageClient(http: http)
        )
    }

    func testDiscoveryDeduplicatesSourcesAndKeepsStableIDsAfterReorderAndRestart() {
        let defaults = defaults()
        let files = FakeFiles(["/a/auth.json": Self.auth("a"), "/b/auth.json": Self.auth("b"), "/copy/auth.json": Self.auth("a")])
        let observer = DefaultAccountObserver(environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain())
        let store = ProviderAccountsStore(defaults: defaults)
        let first = CodexAccountDiscovery.cards(homes: ["/a", "/b", "/copy", "/a/../a"], observer: observer, store: store)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0].id, "codex")
        XCTAssertEqual(first[0].homes, ["/a", "/copy"])
        let next = CodexAccountDiscovery.cards(homes: ["/b", "/a"], observer: observer, store: ProviderAccountsStore(defaults: defaults))
        XCTAssertEqual(next.map(\.id), first.reversed().map(\.id))
        XCTAssertEqual(store.records.count, 2)
    }

    func testMissingAndMalformedSourcesRemainErrorCardsWithoutKeychainFallback() async {
        let files = FakeFiles(["/broken/auth.json": "invalid"])
        let observer = DefaultAccountObserver(files: files, keychain: FakeKeychain(Self.auth("wrong")))
        let cards = CodexAccountDiscovery.cards(homes: ["/missing", "/broken"], observer: observer, store: ProviderAccountsStore(defaults: defaults()))
        XCTAssertEqual(cards.count, 2)
        XCTAssertTrue(cards.allSatisfy { $0.identityKey == nil })
        let http = AccountHTTP { _ in XCTFail("must not make a request"); return Self.usage(1) }
        for card in cards {
            let session = CodexAccountSession(card: card, authStore: CodexAuthStore(files: files), client: CodexUsageClient(http: http))
            let provider = CodexProvider(accountSession: session)
            let snapshot = await provider.refresh()
            XCTAssertNotNil(snapshot.errorCategory)
            let found = await provider.hasLocalCredentials()
            XCTAssertFalse(found)
        }
    }

    func testTwoAccountsUseSeparateTokensAndHeadersAndNoSharedSpend() async {
        let files = FakeFiles(["/a/auth.json": Self.auth("a", token: "token-a"), "/b/auth.json": Self.auth("b", token: "token-b")])
        let http = AccountHTTP { request in
            let account = request.headers["ChatGPT-Account-Id"]!
            XCTAssertEqual(request.headers["Authorization"], "Bearer token-\(account)")
            return Self.usage(account == "a" ? 10 : 80)
        }
        let a = CodexProvider(accountSession: session("a", files: files, http: http))
        let b = CodexProvider(accountSession: session("b", files: files, http: http))
        let first = await a.refresh()
        let second = await b.refresh()
        XCTAssertEqual(first.providerID, "codex@a")
        XCTAssertEqual(second.providerID, "codex@b")
        XCTAssertNotEqual(first.lines, second.lines)
        XCTAssertNil(first.usageHistory)
        let registry = WidgetRegistry.from([a, b])
        XCTAssertEqual(Set(registry.descriptors.map(\.id)).count, 12)
        XCTAssertTrue(registry.historyDescriptorsByProvider.isEmpty)
        XCTAssertTrue(registry.descriptors.allSatisfy { !$0.isSpendTile })
        let reset = a.widgetDescriptors.first { $0.id.hasSuffix("rateLimitResets") }!
        XCTAssertEqual(reset.sample.resetAccountID, "codex@a")
    }

    func testChangingAccountDuringFetchCannotPublishOldUsage() async {
        let files = FakeFiles(["/a/auth.json": Self.auth("a")])
        let http = AccountHTTP { _ in
            files.files["/a/auth.json"] = Self.auth("b")
            return Self.usage(10)
        }
        let provider = CodexProvider(accountSession: session("a", files: files, http: http))
        let snapshot = await provider.refresh()
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testRotationDoesNotOverwriteNewLogin() async {
        let replacement = Self.auth("b")
        let files = FakeFiles(["/a/auth.json": Self.auth("a", expired: true)])
        let http = AccountHTTP { _ in
            files.files["/a/auth.json"] = replacement
            return Self.json(#"{"access_token":"rotated","refresh_token":"rotated-refresh"}"#)
        }
        let provider = CodexProvider(accountSession: session("a", files: files, http: http))
        let snapshot = await provider.refresh()
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertEqual(files.files["/a/auth.json"], replacement)
    }

    func testRotationPreservesUnknownFieldsAndOtherHomes() async throws {
        let other = Self.auth("b")
        let files = FakeFiles(["/a/auth.json": Self.auth("a", expired: true), "/b/auth.json": other])
        let http = AccountHTTP { _ in Self.json(#"{"access_token":"rotated","refresh_token":"rotated-refresh"}"#) }
        let credentials = try await session("a", files: files, http: http).credentials()
        XCTAssertEqual(credentials.auth.tokens?.accessToken, "rotated")
        let object = ProviderParse.jsonObject(Data(files.files["/a/auth.json"]!.utf8))!
        XCTAssertEqual(object["future_field"] as? Int, 42)
        XCTAssertEqual((object["tokens"] as? [String: Any])?["future_token_field"] as? Bool, true)
        XCTAssertEqual(files.files["/b/auth.json"], other)
    }

    func testConcurrentCallersShareOneRotation() async throws {
        let files = FakeFiles(["/a/auth.json": Self.auth("a", expired: true)])
        let http = AccountHTTP { _ in Self.json(#"{"access_token":"rotated"}"#) }
        let session = session("a", files: files, http: http)
        async let first = session.credentials()
        async let second = session.credentials()
        let values = try await [first, second]
        XCTAssertEqual(values.map { $0.auth.tokens?.accessToken }, ["rotated", "rotated"])
        let count = await http.count()
        XCTAssertEqual(count, 1)
    }

    func testResetUsesOnlySelectedAccountAndCancelsOnSwap() async {
        let files = FakeFiles(["/a/auth.json": Self.auth("a"), "/b/auth.json": Self.auth("b")])
        let http = AccountHTTP { request in
            XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "a")
            if request.method == "POST" { XCTFail("swapped login must not consume a reset") }
            files.files["/a/auth.json"] = Self.auth("b")
            return Self.json(#"{"credits":[{"id":"credit-a","expires_at":1800000000}]}"#)
        }
        let service = CodexResetClaimService(session: session("a", files: files, http: http), refreshAfterClaim: {})
        let result = await service.claim(creditExpiringAt: Date(timeIntervalSince1970: 1_800_000_000), redeemRequestID: "one")
        XCTAssertEqual(result, .failed)
        let count = await http.count()
        XCTAssertEqual(count, 1)
    }

    func testAPILoginIsRejected() async {
        let files = FakeFiles(["/a/auth.json": #"{"OPENAI_API_KEY":"api-key"}"#])
        let http = AccountHTTP { _ in XCTFail("API key cannot serve subscription usage"); return Self.usage(1) }
        let provider = CodexProvider(accountSession: session("a", files: files, http: http))
        let snapshot = await provider.refresh()
        XCTAssertNotNil(snapshot.errorCategory)
    }

    func testResetSuccessUsesOneAccountAndRefreshesOnlyItsService() async {
        let files = FakeFiles(["/a/auth.json": Self.auth("a", token: "a-token")])
        let http = AccountHTTP { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer a-token")
            XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "a")
            return request.method == "POST"
                ? Self.json(#"{"code":"reset"}"#)
                : Self.json(#"{"credits":[{"id":"a-credit","expires_at":1800000000}]}"#)
        }
        var refreshes = 0
        let service = CodexResetClaimService(session: session("a", files: files, http: http)) { refreshes += 1 }
        let result = await service.claim(creditExpiringAt: Date(timeIntervalSince1970: 1_800_000_000), redeemRequestID: "request-a")
        XCTAssertEqual(result, .success)
        XCTAssertEqual(refreshes, 1)
        let count = await http.count()
        XCTAssertEqual(count, 2)
    }

    func testAccountRejectionDoesNotFallBackToOtherAccountOrKeychain() async {
        let files = FakeFiles(["/a/auth.json": Self.auth("a"), "/b/auth.json": Self.auth("b")])
        let http = AccountHTTP { request in
            if request.url.host == "auth.openai.com" {
                return Self.json(#"{"access_token":"new-a"}"#)
            }
            XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "a")
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = CodexProvider(accountSession: session("a", files: files, http: http))
        let snapshot = await provider.refresh()
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertEqual(files.files["/b/auth.json"], Self.auth("b"))
    }

    func testNewAccountDefaultsAreEnabledOnDemandAndUnpinnedWithoutChangingExistingLayout() {
        let defaults = defaults()
        let files = FakeFiles()
        let http = AccountHTTP { _ in Self.usage(1) }
        let old = CodexProvider()
        let initial = LayoutStore(registry: .from([old]), defaults: defaults)
        initial.setPinned(false, for: "codex.weekly")
        let next = CodexProvider(accountSession: session("b", files: files, http: http))
        let registry = WidgetRegistry.from([old, next])
        let ids = registry.providers.map(\.id)
        let layout = LayoutStore(
            registry: registry, defaults: defaults,
            defaultMetricIDs: DefaultLayout.forAccountCards(DefaultLayout.metricIDs, providerIDs: ids),
            defaultPinnedMetricIDs: DefaultLayout.forAccountCards(DefaultLayout.pinnedMetricIDs, providerIDs: ids, pins: true),
            defaultExpandedMetricIDs: DefaultLayout.forAccountCards(DefaultLayout.expandedMetricIDs, providerIDs: ids)
        )
        XCTAssertTrue(layout.placed.contains { $0.descriptorID == "codex@b.session" })
        XCTAssertTrue(layout.expandedMetricIDs.contains("codex@b.spark"))
        XCTAssertFalse(layout.expandedMetricIDs.contains("codex@b.session"))
        XCTAssertFalse(layout.pinnedMetricIDs.contains("codex@b.session"))
        XCTAssertFalse(layout.pinnedMetricIDs.contains("codex.weekly"))
    }

    func testExplicitEmptyCatalogCannotFallBackToDefaultLogin() {
        let providers = ProviderCatalog.make(usesExplicitCodexHomes: true)
        XCTAssertFalse(providers.contains { $0 is CodexProvider })
    }

    func testSwappedLoginClearsDisplayedAndPersistedSnapshot() async {
        let files = FakeFiles(["/a/auth.json": Self.auth("a")])
        let http = AccountHTTP { _ in Self.usage(10) }
        let provider = CodexProvider(accountSession: session("a", files: files, http: http))
        let defaults = defaults()
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let store = WidgetDataStore(registry: .from([provider]), providers: [provider], cache: cache,
                                    defaults: defaults, providerIdentityKeys: ["codex@a": "a"])
        let first = await store.refresh(providerID: "codex@a", force: true)
        XCTAssertEqual(first, .refreshed)
        XCTAssertNotNil(store.snapshots["codex@a"])
        files.files["/a/auth.json"] = Self.auth("b")
        let second = await store.refresh(providerID: "codex@a", force: true)
        XCTAssertEqual(second, .failed)
        XCTAssertNil(store.snapshots["codex@a"])
        XCTAssertNil(cache.snapshot(providerID: "codex@a"))
    }

    func testPersistenceFailureIsVisibleAndDoesNotPublishRotatedUsage() async {
        let original = Self.auth("a", expired: true)
        let files = ReadOnlyAccountFiles(text: original)
        let http = AccountHTTP { _ in Self.json(#"{"access_token":"rotated"}"#) }
        let provider = CodexProvider(accountSession: session("a", files: files, http: http))
        let snapshot = await provider.refresh()
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.line(label: "Session"))
        let count = await http.count()
        XCTAssertEqual(count, 1)
    }

    nonisolated private static func json(_ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    nonisolated private static func usage(_ percent: Int) -> HTTPResponse {
        json("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(percent),\"limit_window_seconds\":18000}}}")
    }
}

private actor AccountHTTP: HTTPClient {
    let respond: @Sendable (HTTPRequest) -> HTTPResponse
    private var calls = 0
    init(_ respond: @escaping @Sendable (HTTPRequest) -> HTTPResponse) { self.respond = respond }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        calls += 1
        return respond(request)
    }
    func count() -> Int { calls }
}

private struct ReadOnlyAccountFiles: TextFileAccessing {
    let text: String
    func exists(_ path: String) -> Bool { true }
    func readText(_ path: String) throws -> String { text }
    func writeText(_ path: String, _ text: String) throws { throw CocoaError(.fileWriteNoPermission) }
    func remove(_ path: String) throws { throw CocoaError(.fileWriteNoPermission) }
}
