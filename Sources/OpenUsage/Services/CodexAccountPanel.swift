import AppKit

@MainActor
enum CodexAccountPanel {
    /// Attached sheets are already exempt from the menu-bar panel's outside-click dismissal.
    static func chooseHome() async -> URL? {
        guard let window = NSApp.keyWindow else { return nil }
        let panel = NSOpenPanel()
        panel.title = "Add Codex Account"
        panel.message = "Choose the Codex home folder containing this account's auth.json."
        panel.prompt = "Add Account"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    /// Wait for the old process to release its single-instance lock before launching the bundle.
    /// Arguments are positional shell parameters, so spaces and shell syntax in paths stay literal.
    static func restart() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
        attempts=0
        while /bin/kill -0 "$1" 2>/dev/null; do
          attempts=$((attempts + 1))
          if [ "$attempts" -ge 100 ]; then
            /usr/bin/logger -t OpenUsage "Restart failed: previous process did not exit"
            exit 1
          fi
          /bin/sleep 0.1
        done
        /usr/bin/open -n "$2" || /usr/bin/logger -t OpenUsage "Restart failed: app could not be opened"
        """, "openusage-restart", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        AppLog.info(.config, "Restarting to apply Codex account homes")
        NSApp.terminate(nil)
    }
}
