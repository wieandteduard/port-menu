import AppKit
import os

@MainActor
func moveToApplicationsIfNeeded() {
    let bundlePath = Bundle.main.bundlePath

    var sourcePath = bundlePath
    if bundlePath.contains("AppTranslocation") {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path()
        let appName = URL(filePath: bundlePath).lastPathComponent
        let candidates = ["\(home)/Downloads/\(appName)", "\(home)/Desktop/\(appName)"]
        if let real = candidates.first(where: { fm.fileExists(atPath: $0) }) {
            sourcePath = real
        }
    }

    guard !sourcePath.hasPrefix("/Applications/"),
          !sourcePath.contains("DerivedData"),
          !sourcePath.hasPrefix("/tmp/"),
          !sourcePath.contains("AppTranslocation") else { return }

    let destination = "/Applications/Port Menu.app"

    let alert = NSAlert()
    alert.messageText = "Move to Applications Folder?"
    alert.informativeText = "Port Menu works best when run from the Applications folder."
    alert.addButton(withTitle: "Move to Applications")
    alert.addButton(withTitle: "Don't Move")
    alert.alertStyle = .informational

    guard alert.runModal() == .alertFirstButtonReturn else { return }

    do {
        if FileManager.default.fileExists(atPath: destination) {
            try FileManager.default.removeItem(atPath: destination)
        }
        try FileManager.default.moveItem(atPath: sourcePath, toPath: destination)
        let task = Process()
        task.executableURL = URL(filePath: "/usr/bin/open")
        task.arguments = [destination]
        try task.run()
        NSApp.terminate(nil)
    } catch {
        Log.lifecycle.error("Failed to move app to Applications: \(error.localizedDescription)")
    }
}
