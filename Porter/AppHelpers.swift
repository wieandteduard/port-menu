import AppKit
import os

@MainActor
func moveToApplicationsIfNeeded() {
    let bundlePath = Bundle.main.bundlePath
    let destinationURL = URL(filePath: "/Applications/Port Menu.app")
    let fileManager = FileManager.default

    // If running from a translocated path and a copy already exists in /Applications,
    // just activate/open that copy silently — no dialog, no "new instance" error.
    if bundlePath.contains("AppTranslocation"),
       fileManager.fileExists(atPath: destinationURL.path()) {
        NSWorkspace.shared.openApplication(
            at: destinationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
        NSApp.terminate(nil)
        return
    }

    var sourcePath = bundlePath
    if bundlePath.contains("AppTranslocation") {
        let home = fileManager.homeDirectoryForCurrentUser.path()
        let appName = URL(filePath: bundlePath).lastPathComponent
        let candidates = [
            "\(home)/Downloads/\(appName)",
            "\(home)/Desktop/\(appName)",
            "\(home)/Documents/\(appName)",
            "\(home)/\(appName)",
        ]
        if let real = candidates.first(where: { fileManager.fileExists(atPath: $0) }) {
            sourcePath = real
        }
    }

    guard !sourcePath.hasPrefix("/Applications/"),
          !sourcePath.contains("DerivedData"),
          !sourcePath.hasPrefix("/tmp/"),
          !sourcePath.contains("AppTranslocation") else { return }

    let sourceURL = URL(filePath: sourcePath)

    guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else { return }

    let alert = NSAlert()
    alert.messageText = "Move to Applications Folder?"
    alert.informativeText = "Port Menu works best when run from the Applications folder."
    alert.addButton(withTitle: "Move to Applications")
    alert.addButton(withTitle: "Don't Move")
    alert.alertStyle = .informational

    guard alert.runModal() == .alertFirstButtonReturn else { return }

    do {
        let backupURL = destinationURL
            .deletingLastPathComponent()
            .appending(path: "Port Menu.backup-\(UUID().uuidString).app")
        let tempInstallURL = destinationURL
            .deletingLastPathComponent()
            .appending(path: "Port Menu.install-\(UUID().uuidString).app")
        var backedUpExistingInstall = false

        defer {
            try? fileManager.removeItem(at: tempInstallURL)
        }

        if fileManager.fileExists(atPath: destinationURL.path()) {
            let replaceAlert = NSAlert()
            replaceAlert.messageText = "Replace Existing Application?"
            replaceAlert.informativeText = "A copy of Port Menu already exists in Applications. Replace it with this version?"
            replaceAlert.addButton(withTitle: "Replace")
            replaceAlert.addButton(withTitle: "Cancel")
            replaceAlert.alertStyle = .warning

            guard replaceAlert.runModal() == .alertFirstButtonReturn else { return }

            try fileManager.moveItem(at: destinationURL, to: backupURL)
            backedUpExistingInstall = true
        }

        try fileManager.copyItem(at: sourceURL, to: tempInstallURL)
        try fileManager.moveItem(at: tempInstallURL, to: destinationURL)

        if backedUpExistingInstall {
            try? fileManager.removeItem(at: backupURL)
        }

        relaunchInstalledApp(from: sourceURL, to: destinationURL)
    } catch {
        Log.lifecycle.error("Failed to move app to Applications: \(error.localizedDescription)")
        showApplicationsInstallError(error)
    }
}

@MainActor
private func relaunchInstalledApp(from sourceURL: URL, to appURL: URL) {
    do {
        let escapedAppPath = appURL.path().replacingOccurrences(of: "'", with: "'\\''")
        let escapedSourcePath = sourceURL.path().replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 0.4; open -n '\(escapedAppPath)' && sleep 1 && rm -rf '\(escapedSourcePath)'"
        ]
        try process.run()
        NSApp.terminate(nil)
    } catch {
        Log.lifecycle.error("Failed to relaunch app from Applications: \(error.localizedDescription)")
        showApplicationsRelaunchError(error)
    }
}

@MainActor
private func showApplicationsInstallError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Couldn't Install Port Menu"
    alert.informativeText = "Port Menu could not be copied to the Applications folder.\n\n\(error.localizedDescription)"
    alert.addButton(withTitle: "OK")
    alert.alertStyle = .warning
    alert.runModal()
}

@MainActor
private func showApplicationsRelaunchError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Installed, But Couldn't Reopen Port Menu"
    alert.informativeText = "Port Menu was copied to the Applications folder, but it could not be reopened automatically.\n\nOpen it from Applications to continue.\n\n\(error.localizedDescription)"
    alert.addButton(withTitle: "OK")
    alert.alertStyle = .warning
    alert.runModal()
}
