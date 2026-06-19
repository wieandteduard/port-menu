import Sparkle
import SwiftUI

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/wieandteduard/port-menu/main/packaging/appcast.xml"
    }
}

@main
struct PorterApp: App {
    @State private var store = PortStore.shared
    private let updaterController: SPUStandardUpdaterController
    private let updaterDelegate = UpdaterDelegate()
    @AppStorage("hideMenuBarWhenEmpty") private var hideMenuBarWhenEmpty = false

    init() {
        // Singleton: if another instance is already running, just quit.
        let bundleId = Bundle.main.bundleIdentifier
        let other = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleId && $0 != NSRunningApplication.current
        }
        if other != nil {
            NSApp.terminate(nil)
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
        moveToApplicationsIfNeeded()
        Task { @MainActor in
            PortStore.shared.ensurePolling()
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: isMenuBarExtraInserted) {
            PortListView(updater: updaterController.updater)
                .environment(store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: store.entries.isEmpty
                      ? "square.fill"
                      : "circle.fill")
                    .font(.system(size: 5.5))
                    .foregroundStyle(statusColor)
                Text(store.entries.count, format: .number)
                    .fontDesign(.monospaced)
            }
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }

    private var isMenuBarExtraInserted: Binding<Bool> {
        Binding(
            get: { hideMenuBarWhenEmpty ? !store.entries.isEmpty : true },
            set: { _ in }
        )
    }

    private var statusColor: Color {
        if store.lastError != nil && store.entries.isEmpty {
            return .orange
        }
        return store.entries.isEmpty ? .gray : .green
    }
}
