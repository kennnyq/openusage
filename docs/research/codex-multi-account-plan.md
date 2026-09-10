# Codex Multi-Account Implementation Plan

Status: the subscription-monitoring version is implemented on `feat/codex-multi-account`.
Investigated and implemented September 10, 2026. The original design below records the broader plan;
[the provider documentation](../providers/codex.md#multiple-accounts-personal-build) is the current setup guide.

The implementation includes explicit local homes, stable account cards, isolated refresh and reset
claims, cache invalidation, CLI integration, and regression tests. A follow-up adds an Accounts section
to Codex customization, with a folder picker, removal controls, login instructions, and restart action.
Account-specific spend and Keychain-only accounts remain deferred. Multi-account mode intentionally omits
spend and trends. A failed refresh clears the affected account's cached values.

Validation: the full suite passed (1,327 tests, 3 skipped), followed by 93 passing account/layout tests
including an additional credential-persistence regression. Live two-account verification still
requires signing in to the user's accounts; no credentials were created or copied for the tests.
The implemented release build also completed and launched through `script/build_and_run.sh verify`
using the installed full Xcode toolchain. It used ad-hoc signing; iCloud provisioning was unavailable.
The account-configuration UI follow-up passed the full suite (1,333 tests, 3 skipped) and visual
inspection of a render with two mock homes and the restart action.

## Feasibility and Scope

Feasible: show independent usage cards for several ChatGPT/Codex accounts in one OpenUsage process. Each account needs its own valid login and an explicitly selected credential source. This does not add simultaneous logins to the Codex desktop app, combine subscriptions, or switch the account running a task.

OpenAI documents that file credentials live under `CODEX_HOME`, and that local configuration and state use that directory. Separate homes therefore provide a practical basis for independent CLI logins. This is an implementation inference, not a documented guarantee of multi-account desktop support. See [authentication](https://learn.chatgpt.com/docs/auth) and [state locations](https://learn.chatgpt.com/docs/config-file/config-advanced).

The existing usage client already sends a bearer token and `ChatGPT-Account-Id` per request. No new usage protocol is needed. Its `chatgpt.com/backend-api/wham` endpoints remain an integration dependency that may change; two real accounts must be tested before calling the feature proven.

## What Already Exists

- `Providers/Codex/CodexProvider.swift`: one hardcoded `codex` runtime and descriptor namespace; refresh returns the first successful credential candidate.
- `Providers/Codex/CodexAuthStore.swift`: file sources plus a service-wide Keychain fallback; refresh writes back to the source it read.
- `Stores/ProviderAccountsStore.swift`: account records, source metadata, removal tombstones, and stable IDs (`codex`, then `codex@<hash>`), including collision handling.
- `Services/ProviderAccountAssembly.swift`: launch-time account reconciliation and identity stamps, plus multiple Claude account cards to follow as an example.
- `Providers/DefaultAccountObserver.swift`: Codex account identity extraction already exists. It deliberately refuses to resolve identity when a global Keychain fallback might produce a different account.
- `Stores/WidgetDataStore.swift` and `ProviderSnapshotCache.swift`: per-provider refresh state and account-stamped caches. Duplicate runtime IDs would break dictionary construction.
- `App/AppContainer.swift` and `Views/WidgetRowView.swift`: currently inject one global reset-credit claim service.

`CodexLogUsageScanner` accepts a comma-separated home list, but `CodexAuthStore` treats `CODEX_HOME` as one directory. A comma list is not a multi-account solution: it mixes history while leaving authentication single-account.

## Recommended Personal Version

Use an explicit local list of Codex home directories, read at launch. Reuse the account registry rather than making a second database. Start with file-backed OAuth accounts and require an app restart after adding or removing a home. A dedicated account-management UI and precisely addressed Keychain accounts can follow later.

Keep tokens in the original protected auth files. Store only home paths, labels, and identity metadata in OpenUsage settings; do not sync machine-specific paths or credentials through iCloud or include them in telemetry. Do not copy a rotating login into multiple homes.

### 1. Add Explicit Account Sources

Add a small local settings store for the configured home list and extend `ProviderAccountSource.Kind` with a Codex-home source. Expand `~`, canonicalize paths, deduplicate symlinks, and distinguish missing files, unreadable files, malformed credentials, and API-key-only logins.

Extract reusable Codex identity parsing from `DefaultAccountObserver`. Use the existing account-ID rules, never email or directory name as identity. Group all observed sources for an identity into one observation before reconciliation; the current store replaces an observation's source list.

Add `CodexAccountCard` and `codexCards` to `ProviderAccountAssembly`. Reconcile default and configured homes together, preserving existing record IDs and removal tombstones. Build cards only from validated current sources, not stale persisted source edges. Do not let the Claude-specific early returns skip Codex card assembly.

For the first version, retain legacy behavior when no explicit homes are configured. In explicit multi-account mode, do not use the global Keychain fallback. Explain unsupported Keychain-only accounts visibly instead of guessing their identity.

### 2. Bind Each Runtime to Its Account

Parameterize `CodexProvider` with its card ID, display name, expected account identity, and exact credential source. Generate descriptor IDs from that card ID. Keep metric keys used by the mapper consistent with the descriptor bindings.

Create one runtime per assembled card in the shared provider factory used by the app and one-shot CLI. Reuse per-provider refresh, failure backoff, and snapshot storage. Validate identity on every credential reload and after token refresh; if another login replaces the file, reject the result and clear stale displayed data instead of publishing it under the old card.

Add an account-scoped credential coordinator shared by usage refresh and reset claims. Serialize in-process refreshes, reread live credentials before rotating, and persist atomically with owner-only permissions while preserving unrelated auth fields. Check for external file changes before saving. In-process serialization does not eliminate races with Codex CLI: on a rotation conflict, reread once and adopt a newer credential only if its identity still matches; otherwise show an account-specific re-login error. Never fall through to another account.

### 3. Connect Existing Account-Aware UI and Persistence

Preserve `codex` and its existing layout for the original account; use the registry's stable IDs for additional accounts. Keep Codex cards together in the established provider ordering. Use family identity (`ProviderAccountID.family`) for Codex-specific settings, colors, and capabilities, and card identity for refresh, pins, caches, and exports.

Audit `DefaultLayout`, first-run/new-provider seeding, customization, `CodexPricingSection`, total spend, the local API/CLI, and iCloud history for assumptions that Codex is always exactly `codex`. Keep shared model pricing keyed to the Codex family. Stamp every card's cache with the expected account identity.

Before implementing new metric defaults, confirm the four owner decisions required by AGENTS.md: enabled state, Always Visible/On Demand, menu-bar pins, and row order. Proposed starting point: mirror the existing Codex layout per account, with additional accounts unpinned; this is a proposal, not an approved default.

### 4. Make Reset Claims Account-Specific

Replace the singleton claim service with a lookup keyed by card ID. Bind the row's claim closure to that service and immutable account identity; scope matched credit IDs and idempotency keys to that account. Confirm the account label in the existing two-click confirmation. Refresh only the affected card after a claim.

Preserve the existing explicit confirmation and never retry across accounts. If this routing is deferred, suppress the claim action in multi-account mode until it is safe; displaying the count can remain supported.

### 5. Keep Spend Attribution Honest

Ship subscription meters first. For per-account spend, scan only that account's explicitly associated home directories, with isolated caches and canonical-path deduplication. A directory's current login does not prove the ownership of all historical logs: require homes dedicated to one account, or leave mixed historical usage unattributed.

The current provider also merges global pi and OpenCode usage. Do not add those same totals to every account. Include them only when account attribution is available, or keep them out of account-specific totals with a visible explanation. Verify overall spend and iCloud merging cannot double-count the same source. Keep the existing parent/fork log deduplication.

## Validation and Completion Criteria

Add fixture-based tests without real tokens for:

- Two distinct identities produce two stable cards and unique descriptors; the same identity in two homes produces one card.
- Existing single-account IDs, layout, and cached history survive migration and restart.
- Missing, malformed, API-key-only, and Keychain-only sources fail visibly without changing another account's data.
- Replacing a home with another login cannot publish usage, cached data, or reset actions on the previous card.
- Expired tokens, simultaneous refresh/claim requests, external rotation, and persistence failures remain isolated.
- Reset claims use the selected account's token/header and never another account's credit, including lost-response retries.
- Dedicated-home history is isolated, and shared pi/OpenCode/forked logs are not duplicated.
- App and CLI enumerate the same cards; removal and reordering preserve stable IDs and pins.

Then manually verify two owned accounts: compare both usage cards against each account's usage dashboard, refresh both, invalidate one login, restart, and confirm the other remains functional. Use mocked reset claims for regression tests; a real claim is optional and spends a credit, so requires the user's deliberate UI confirmation.

Update `docs/providers/codex.md`, `docs/provider-enablement.md`, and affected architecture/history docs when behavior is implemented. Capture screenshots if opening a visual-change PR.

Suggested sequence: source discovery and identity tests; two live read-only cards; UI/cache/CLI integration; account-safe reset claims; optional spend attribution. The core work is moderate because the account framework exists; token ownership and history attribution deserve more attention than the network calls.

## Account Setup Walkthrough (For the Implementation)

Create separate directories outside the repository and sign in independently. These example commands are instructions, not actions performed during this investigation:

```sh
mkdir -p "$HOME/.codex-personal" "$HOME/.codex-work"
chmod 700 "$HOME/.codex-personal" "$HOME/.codex-work"
env CODEX_HOME="$HOME/.codex-personal" codex -c 'cli_auth_credentials_store="file"' login
env CODEX_HOME="$HOME/.codex-work" codex -c 'cli_auth_credentials_store="file"' login
```

Choose the intended account in each browser flow. Persist `cli_auth_credentials_store = "file"` in each home's user `config.toml` for subsequent use. File credentials contain secrets; keep their permissions restricted. Register those paths in the proposed OpenUsage local settings after that feature exists. To keep future CLI history separate, launch each CLI with its corresponding `CODEX_HOME`. No global environment change is needed.

## Compile and Run Walkthrough

The project uses SwiftPM, requires Swift tools 6.2 or newer, and targets macOS 15+. Use a matching macOS SDK/toolchain; full Xcode supplies the icon compiler used by the bundle script. Check:

```sh
cd /Users/kenny/Developer/openusage
swift --version
xcode-select -p
```

After implementing, run the focused new tests and existing Codex/account tests, then rebuild and restart through the existing script:

```sh
swift test --filter 'Codex|ProviderAccount|DefaultAccount'
./script/build_and_run.sh verify
```

`verify` is a positional argument, not `--verify`. The script stops OpenUsage, builds release binaries, stages `dist/OpenUsage.app` with resources and Sparkle, signs it, launches it, and checks for a running process. Inspect the menu-bar icon for UI validation; a successful process check alone does not verify account data.

For a debug build or runtime logs:

```sh
CONFIG=debug ./script/build_and_run.sh verify
./script/build_and_run.sh logs
```

Every invocation rebuilds; `logs` also relaunches before streaming logs. The default development bundle ID is `com.robinebers.openusage.dev`, with separate app preferences and no automatic update feed. It still reads real provider credential sources and may rotate their tokens. A missing development signing identity uses ad-hoc signing; missing iCloud provisioning leaves sync unavailable. No version bump or release is needed for personal use.

If selecting a full Xcode installation is necessary, use a per-command `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` prefix, adjusted to the actual installed path, rather than changing the machine-wide toolchain. Dependency fetching needs network access and Swift caches need write access.

### Verification on This Mac

The unchanged application built and launched successfully with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/build_and_run.sh verify
```

The script reported `running`. The full Xcode toolchain is Swift 6.2.4. The globally selected Command Line Tools (Swift 6.4) failed compiling KeyboardShortcuts because the SwiftUI `EntryMacro` plugin was unavailable; using full Xcode resolved that failure without source changes. The successful build used ad-hoc signing. Build details are in `/tmp/openusage-multi-account-xcode-build.log` for this session.

This verifies the existing app's build and process launch only. Multi-account behavior is still a plan, and no real account setup, credential inspection, reset claim, or feature tests were performed during the investigation.
