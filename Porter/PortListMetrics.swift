import AppKit
import SwiftUI

/// 列表的高度度量与封顶规则。
///
/// 行高**实测**而不是写常数：字号、辅助功能设置、行内内容一变，常数就错，
/// 而封顶算错的表现是"最后一行被切掉半截"，很难和"滚动"区分开。
///
/// 上限高度里那个 `bottomInset` 是列表底部的 `.padding(.bottom, 6)`。
/// 漏掉它，第 8 行的副行就会被裁掉——这一条是画图看出来的，不是推出来的。
@MainActor
enum PortListMetrics {
    static let maxRows = 8
    static let bottomInset: CGFloat = 6

    static let rowHeight: CGFloat = measureRowHeight()
    static let capHeight: CGFloat = CGFloat(maxRows) * rowHeight + bottomInset

    /// 不超过上限时返回 `nil`，让窗口按内容自适应；超过才封顶。
    static func visibleHeight(rowCount: Int) -> CGFloat? {
        rowCount > maxRows ? capHeight : nil
    }

    private static func measureRowHeight() -> CGFloat {
        let sample = ActivePort(
            port: 3000,
            pid: 0,
            projectName: "measure › project/path",
            branch: "measure-branch",
            startTime: nil
        )
        // 带上分隔线量，比真实首行多 1pt：宁可保守，也别切掉半行。
        let row = PortRow(
            entry: sample,
            showTopDivider: true,
            hovered: false,
            onHoverChange: { _ in }
        )
        .frame(width: 340)
        // PortRow 依赖 PortStore 环境；量尺寸时也必须给，否则 @Environment 直接 fatalError。
        .environment(PortStore.shared)

        let hosting = NSHostingView(rootView: row)
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 60)
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        return height > 0 ? height : 56
    }
}
