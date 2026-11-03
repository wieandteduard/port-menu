import Sparkle
import SwiftUI

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/wieandteduard/port-menu/main/packaging/appcast.xml"
    }
}

/// 本地开发分支一律关掉自动更新。
///
/// `UpdaterDelegate` 里的 feed 指向上游的 appcast.xml，开着自动更新会把上游
/// 构建下载下来覆盖本地改动。关掉之后 `updaterController` 为 nil，UI 里也不再有
/// "Check for Updates…" 入口，而不是留一个会推回上游版本的按钮。
enum UpdaterPolicy {
    static let isEnabled = false
}

@main
struct PorterApp: App {
    @State private var store = PortStore.shared
    private let updaterController: SPUStandardUpdaterController?
    private let updaterDelegate = UpdaterDelegate()

    init() {
        if UpdaterPolicy.isEnabled {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: updaterDelegate,
                userDriverDelegate: nil
            )
        } else {
            updaterController = nil
        }
        moveToApplicationsIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            PortListView(updater: updaterController?.updater)
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
            .onAppear { store.ensurePolling() }
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                if let updater = updaterController?.updater {
                    CheckForUpdatesView(updater: updater)
                }
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
