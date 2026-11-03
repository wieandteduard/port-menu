import AppKit
import SwiftUI

/// 列表的高度度量与封顶规则。
///
/// 行高**实测**而不是写常数：字号、辅助功能设置、行内内容一变，常数就错，
/// 而封顶算错的表现是"最后一行被切掉半截"，很难和"滚动"区分开。
///
/// 上限不再是一个固定行数：日常有二十来个 dev server 时，固定 8 行等于让人一直滚。
/// 现在按**屏幕可用高度**封顶，装得下就铺开，装不下才滚。
@MainActor
enum PortListMetrics {
    /// 列表底部的 `.padding(.bottom, 6)`。漏掉它，最后一行会被裁掉半截。
    static let bottomInset: CGFloat = 6

    /// 弹窗顶部（标题栏 + 分隔线）大约占掉的高度。
    static let headerAllowance: CGFloat = 42

    /// 弹窗底边与屏幕可用区域之间的留白。
    static let screenMargin: CGFloat = 12

    static let rowHeight: CGFloat = measureRowHeight()

    /// 列表在给定屏幕上最多能占多高；`nil` 时回退 `NSScreen.main`，再回退一个保守值。
    static func availableListHeight(screenHeight: CGFloat? = nil) -> CGFloat {
        let height = screenHeight ?? NSScreen.main?.visibleFrame.height ?? 800
        let usable = height - headerAllowance - screenMargin
        // 保护下限：极小屏或异常数值下也别算出比两行还小的窗口。
        return max(usable, rowHeight * 2 + bottomInset)
    }

    /// 列表的显示高度：内容装得下就是内容高度，装不下是可用高度。
    ///
    /// **永远返回显式高度**，不能有"装得下就返回 nil 让窗口自然生长"的路径：
    /// `MenuBarExtra` 窗口里无约束的 `ScrollView` 会塌缩——拟合查询报内容高度，
    /// 真实窗口布局却按"窗口提议的尺寸"走，而窗口尺寸又取决于内容，循环依赖
    /// 让窗口停在第一次布局的小尺寸上（真机塌成只剩标题栏，18 条数据一条不剩）。
    static func visibleHeight(rowCount: Int, available: CGFloat) -> CGFloat {
        let contentHeight = CGFloat(max(rowCount, 0)) * rowHeight + bottomInset
        return min(contentHeight, available)
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
