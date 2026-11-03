import AppKit
import SwiftUI

/// 弹窗所在那块屏幕的可用高度。
///
/// `NSScreen.main` 是"当前活动窗口所在屏"，多显示器时**不一定是弹窗所在的那块**：
/// 本机内建屏 visibleFrame 高 1084pt，外接屏 1440pt。按 `NSScreen.main` 算会少铺 6 行。
///
/// 为什么不从菜单栏图标（`MenuBarExtra` 的 label）读：多显示器下状态栏图标可能在每块屏上
/// 都镜像一份，多个 label 实例会互相覆盖同一个 tracker，谁最后写入谁生效，结果不确定。
/// 挂在**弹窗内容**上读 `window?.screen` 就没有这个歧义。
///
/// 只存**数字**而不是 `NSScreen`：好测试，也不持有可能失效的屏幕引用。
@MainActor
@Observable
final class PopoverScreenTracker {
    static let shared = PopoverScreenTracker()

    /// 弹窗所在屏的 `visibleFrame.height`；弹窗开过一次之前为 nil。
    private(set) var visibleHeight: CGFloat?

    func update(visibleHeight: CGFloat?) {
        // nil 表示"这次没读到"，不要用它覆盖已经读到的高度。
        guard let visibleHeight else { return }
        self.visibleHeight = visibleHeight
    }

    /// 解析顺序：弹窗的屏 → 鼠标所在的屏 → `NSScreen.main`。
    ///
    /// 鼠标这一层是首帧用的：用户是"在某块屏上点了图标"才让弹窗出现的，
    /// 所以指针当时就在那块屏上，比 `NSScreen.main` 可靠。
    var resolvedVisibleHeight: CGFloat? {
        if let visibleHeight { return visibleHeight }
        if let mouseScreen = Self.screenContainingMouse() { return mouseScreen.visibleFrame.height }
        return NSScreen.main?.visibleFrame.height
    }

    static func screenContainingMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}

/// 挂在弹窗内容上。`window?.screen` 就是弹窗真正所在的那块屏。
struct PopoverScreenReader: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackingView { TrackingView() }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.publish()
    }

    final class TrackingView: NSView {
        private var screenObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            publish()
            observeWindowScreenChanges()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            // 离开窗口时摘掉监听；deinit 里做不了（nonisolated 无法访问 non-Sendable 的 token）。
            if newWindow == nil { removeScreenObserver() }
        }

        func publish() {
            guard let screen = window?.screen else { return }
            PopoverScreenTracker.shared.update(visibleHeight: screen.visibleFrame.height)
        }

        private func removeScreenObserver() {
            if let screenObserver {
                NotificationCenter.default.removeObserver(screenObserver)
                self.screenObserver = nil
            }
        }

        private func observeWindowScreenChanges() {
            removeScreenObserver()
            guard let window else { return }
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                // 通知固定投递到主队列；这里只是把"哪块屏"同步回去。
                MainActor.assumeIsolated {
                    self?.publish()
                }
            }
        }
    }
}
