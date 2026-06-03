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

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
        moveToApplicationsIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            PortListView(updater: updaterController.updater)
                .environment(store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: store.entries.isEmpty
                      ? "square.fill"
                      : "circle.fill")
                    .font(.system(size: 5.5))
                    .foregroundStyle(statusColor)
                Text("Ports \(store.entries.count)")
                    .fontDesign(.monospaced)
            }
            .onAppear { store.ensurePolling() }
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }

    private var statusColor: Color {
        if store.lastError != nil && store.entries.isEmpty {
            return .orange
        }
        return store.entries.isEmpty ? .gray : .green
    }
}
