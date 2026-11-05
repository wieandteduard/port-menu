import Sparkle
import SwiftUI

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/wieandteduard/port-menu/main/packaging/appcast.xml"
    }
}

/// 自动更新只在发布构建里启用。
///
/// Debug 构建是开发者本地跑的：`UpdaterDelegate` 的 feed 指向本仓库的 appcast，
/// 开着自动更新会把正式版本下载下来覆盖本地改动，所以 Debug 下不创建 updater，
/// UI 里也不留一个"点了就会还原成正式版"的按钮。
/// Release 构建（发布流程）行为不变。
enum UpdaterPolicy {
    #if DEBUG
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif
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
