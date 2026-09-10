import SwiftUI

struct CodexAccountsSection: View {
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var editor: CodexAccountsEditor
    @State private var isAdding = false
    @State private var actionError: String?
    @State private var renamingHome: String?
    @State private var draftName = ""

    init(editor: CodexAccountsEditor = CodexAccountsEditor()) {
        _editor = State(initialValue: editor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Accounts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 10) {
                if editor.homes.isEmpty {
                    Text("Automatic Discovery")
                    Text("Add another account's Codex home folder. Your current file-backed login will be kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(editor.homes, id: \.self) { home in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(editor.namesByHome[home] ?? URL(fileURLWithPath: home).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(home)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        Button("Rename") {
                            draftName = editor.namesByHome[home] ?? ""
                            renamingHome = home
                            actionError = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isAdding)
                        Button("Remove") {
                            editor.remove(home)
                            if renamingHome == home { renamingHome = nil }
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isAdding)
                    }
                }
                if let home = renamingHome {
                    TextField("Account Name", text: $draftName, prompt: Text("Primary"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { rename(home) }
                    Text("Leave blank to use the folder name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Save Name") { rename(home) }
                            .disabled(isAdding)
                        Button("Cancel") { renamingHome = nil }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("Add Account…") { addAccount() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isAdding)
                Text("Each folder needs its own Codex login stored in auth.json. Keychain-only logins need a file-backed home first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Need a Separate Login?") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Run these commands in Terminal, sign in to the account you want to add, then select the new folder with Add Account.")
                        Text(Self.loginInstructions)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if editor.needsRestart {
                    Text("Restart to apply account changes. Removing a folder does not sign you out; removing all folders restores automatic discovery.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Restart OpenUsage") {
                        do { try CodexAccountPanel.restart() }
                        catch { report(error) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isAdding)
                }
                if let actionError {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(Theme.notice)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .task { editor.reload(); await editor.refreshNames() }
    }

    private func addAccount() {
        isAdding = true
        actionError = nil
        Task {
            defer { isAdding = false }
            guard let home = await CodexAccountPanel.chooseHome() else { return }
            do { try await editor.add(home); await editor.refreshNames() }
            catch { report(error) }
        }
    }

    private func rename(_ home: String) {
        guard !isAdding else { return }
        isAdding = true
        actionError = nil
        Task {
            defer { isAdding = false }
            do {
                try await editor.rename(home, to: draftName)
                renamingHome = nil
            } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        actionError = error.localizedDescription
        AppLog.error(LogTag.auth("codex"), "account configuration failed: \(error.localizedDescription)")
    }

    private static let loginInstructions = """
    mkdir -m 700 -p "$HOME/.codex-primary"
    env CODEX_HOME="$HOME/.codex-primary" codex -c 'cli_auth_credentials_store="file"' login
    """
}
