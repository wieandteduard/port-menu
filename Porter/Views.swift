import ServiceManagement
import Sparkle
import SwiftUI

// MARK: - Check for Updates

struct CheckForUpdatesView: View {
    let updater: SPUUpdater
    @State private var canCheckForUpdates = false

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!canCheckForUpdates)
        .onAppear {
            canCheckForUpdates = updater.canCheckForUpdates
        }
    }
}

// MARK: - Port List

struct PortListView: View {
    @Environment(PortStore.self) private var store
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    var updater: SPUUpdater?

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                PortMainContentView(updater: updater)
            } else {
                OnboardingView()
            }
        }
        .frame(width: 340)
        .animation(.easeInOut(duration: 0.25), value: hasCompletedOnboarding)
    }
}

// MARK: - Main Content

struct PortMainContentView: View {
    @Environment(PortStore.self) private var store
    var updater: SPUUpdater?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PortHeaderView(updater: updater)
            Divider()

            if let error = store.lastError, store.entries.isEmpty {
                PortErrorStateView(error: error)
            } else if store.entries.isEmpty && !store.isScanning {
                PortEmptyStateView()
            } else if store.entries.isEmpty && store.isScanning {
                PortScanningStateView()
            } else {
                PortEntryListView()
            }
        }
        // 挂在弹窗内容上，读到的是弹窗真正所在那块屏的可用高度。
        .background(PopoverScreenReader().frame(width: 0, height: 0))
    }
}

// MARK: - Header

struct PortHeaderView: View {
    @Environment(PortStore.self) private var store
    @State private var menuHovered = false
    @State private var showMenu = false
    @State private var launchAtLoginError: String?
    var updater: SPUUpdater?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLoginError = error.localizedDescription
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("Port Menu").font(.headline)
            Spacer()

            HStack(spacing: 2) {
                if !store.entries.isEmpty {
                    HeaderControlButton(
                        tooltip: nil,
                        destructive: true,
                        action: store.killAllProcesses
                    ) {
                        Text("Kill all")
                    }
                }

                HeaderControlButton(
                    tooltip: "Quit Port Menu",
                    action: { NSApplication.shared.terminate(nil) }
                ) {
                    HeaderIconLabel(systemName: "power")
                }

                Button { showMenu.toggle() } label: {
                    HeaderIconLabel(systemName: "ellipsis")
                }
                .buttonStyle(HeaderButtonStyle(isHovered: menuHovered))
                .background(FloatingTooltipAnchor(text: "Settings", isVisible: menuHovered && !showMenu))
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        menuHovered = hovering
                    }
                }
                .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Port Menu \(appVersion)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Toggle("Launch at Login", isOn: launchAtLogin)
                            .toggleStyle(.switch)
                            .controlSize(.mini)

                        if let updater {
                            Divider()

                            CheckForUpdatesView(updater: updater)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .alert("Couldn't Update Launch at Login", isPresented: launchAtLoginErrorBinding) {
            Button("OK") { launchAtLoginError = nil }
        } message: {
            Text(launchAtLoginError ?? "Port Menu couldn't change its launch-at-login setting.")
        }
    }

    private var launchAtLoginErrorBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginError != nil },
            set: { newValue in
                if !newValue { launchAtLoginError = nil }
            }
        )
    }
}

struct HeaderControlButton<Label: View>: View {
    let tooltip: String?
    var destructive: Bool = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(HeaderButtonStyle(destructive: destructive, isHovered: isHovered))
        .background(FloatingTooltipAnchor(text: tooltip, isVisible: isHovered))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

struct HeaderIconLabel: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .medium))
            .frame(width: 12, height: 14)
    }
}

struct HeaderButtonStyle: ButtonStyle {
    var destructive: Bool = false
    var isHovered: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 4)
            .background(Capsule().fill(backgroundColor(configuration)))
            .foregroundStyle(foregroundColor)
            .scaleEffect(configuration.isPressed ? 0.92 : isHovered ? 1.04 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
    }

    private var horizontalPadding: CGFloat { destructive ? 10 : 7 }

    private func backgroundColor(_ c: ButtonStyleConfiguration) -> Color {
        if destructive {
            if c.isPressed { return .red.opacity(0.18) }
            return isHovered ? .red.opacity(0.12) : .clear
        }
        if c.isPressed { return .primary.opacity(0.14) }
        return isHovered ? .primary.opacity(0.08) : .clear
    }

    private var foregroundColor: Color {
        if destructive {
            return isHovered ? .red : .secondary
        }
        return .secondary
    }
}

// MARK: - Entry List

struct PortEntryListView: View {
    @Environment(PortStore.self) private var store
    /// 状态栏在哪块屏，就按那块屏的可用高度封顶（多显示器时 `NSScreen.main` 可能不对）。
    @State private var screenTracker = PopoverScreenTracker.shared
    /// 只有一行能被 hover。用每行各自的 @State 时，滚走的行不会收到 exit 回调，
    /// Kill/Open 就会一直留在屏幕上。
    @State private var hoveredID: String?
    @State private var scrollOffset: CGFloat = 0

    private static let scrollSpace = "portEntryList"

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                    PortRow(
                        entry: entry,
                        showTopDivider: index > 0,
                        hovered: hoveredID == entry.id,
                        onHoverChange: { hovering in
                            withAnimation(.easeOut(duration: 0.12)) {
                                if hovering {
                                    hoveredID = entry.id
                                } else if hoveredID == entry.id {
                                    hoveredID = nil
                                }
                            }
                        }
                    )
                }
            }
            .padding(.bottom, PortListMetrics.bottomInset)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PortListScrollOffsetKey.self,
                        value: proxy.frame(in: .named(Self.scrollSpace)).minY
                    )
                }
            )
        }
        .coordinateSpace(name: Self.scrollSpace)
        .frame(height: PortListMetrics.visibleHeight(
            rowCount: store.entries.count,
            available: PortListMetrics.availableListHeight(
                screenHeight: screenTracker.resolvedVisibleHeight
            )
        ))
        .onPreferenceChange(PortListScrollOffsetKey.self) { offset in
            // 滚动时指针下的行会换人，exit 回调又不会补发：主动清掉 hover 状态。
            guard abs(offset - scrollOffset) > 0.5 else { return }
            scrollOffset = offset
            if hoveredID != nil { hoveredID = nil }
        }
        .onChange(of: store.entries) { hoveredID = nil }
    }
}

private struct PortListScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Empty State

struct PortEmptyStateView: View {
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.fill")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
                .rotationEffect(.degrees(rotation))
            Text("No dev servers detected")
                .font(.callout.bold())
                .foregroundStyle(.secondary)
            Text("Start a dev server to see it here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.easeInOut(duration: 0.8)) {
                    rotation += 360
                }
            }
        }
    }
}

// MARK: - Scanning State

struct PortScanningStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Scanning ports…")
                .font(.callout.bold())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: - Error State

struct PortErrorStateView: View {
    @Environment(PortStore.self) private var store
    let error: ScanError

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text("Scan failed")
                .font(.callout.bold())
                .foregroundStyle(.secondary)
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button("Retry") { store.refresh() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: - Port Row

struct PortRow: View {
    let entry: ActivePort
    let showTopDivider: Bool
    /// 由 `PortEntryListView` 统一持有：同一时刻只有一行是 hovered。
    let hovered: Bool
    let onHoverChange: (Bool) -> Void

    @Environment(PortStore.self) private var store
    @State private var slidOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showTopDivider {
                Divider()
                    .padding(.horizontal, 16)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                        .offset(y: -1)

                    Text(entry.projectName)
                        .font(.system(.body, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    // 按钮只在 hover 时进布局：非 hover 时名字吃满整行宽度。
                    // 用 opacity 常驻会让每个名字永久少掉约 83pt，长包名直接截断。
                    if hovered {
                        HStack(spacing: 2) {
                            HoverButton("Kill", role: .destructive) { killWithAnimation() }
                            HoverButton("Open") {
                                NSWorkspace.shared.open(entry.url)
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
                    }
                }

                HStack(spacing: 6) {
                    if !entry.branch.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                            Text(entry.branch)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !entry.command.isEmpty {
                        // 有 git 根：branch 之后补一条"跑的是什么"。
                        if !entry.branch.isEmpty {
                            Text("·").foregroundStyle(.tertiary)
                        }
                        Text(entry.command)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }


                    // 端口是这一行里最需要被扫读的信息：只把数字染成强调色，
                    // 冒号留在 tertiary，避免整行变成两条彩色轴线。
                    HStack(spacing: 0) {
                        Text(":")
                            .foregroundStyle(.tertiary)
                        Text(String(entry.port))
                            .foregroundStyle(Color.accentColor)
                    }
                    .fontDesign(.monospaced)

                    Spacer()

                    if let start = entry.startTime {
                        Text(formatUptime(from: start))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .blur(radius: slidOut ? 8 : 0)
        .opacity(slidOut ? 0 : 1)
        .offset(x: slidOut ? 340 : 0)
        .contentShape(Rectangle())
        .onHover { onHoverChange($0) }
        .contextMenu {
            Button("Copy URL") {
                PortStore.copyToClipboard(entry.url.absoluteString)
            }
            Button("Copy Port") {
                PortStore.copyToClipboard(String(entry.port))
            }
            Divider()
            Button("Open in Browser") {
                NSWorkspace.shared.open(entry.url)
            }
            Divider()
            Button("Kill Server", role: .destructive) { killWithAnimation() }
        }
    }

    private func killWithAnimation() {
        store.killProcess(pid: entry.pid, port: entry.port)
        withAnimation(.easeOut(duration: 0.3)) {
            slidOut = true
        }
        Task {
            try? await Task.sleep(for: .seconds(0.3))
            store.removeEntry(port: entry.port)
        }
    }
}

// MARK: - Hover Button

struct HoverButton: View {
    let label: String
    let role: ButtonRole?
    let action: () -> Void

    init(_ label: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.label = label
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .buttonStyle(RowButtonStyle(destructive: role == .destructive))
    }
}

// MARK: - Row Button Style

struct RowButtonStyle: ButtonStyle {
    let destructive: Bool
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(backgroundColor(configuration)))
            .foregroundStyle(foregroundColor(configuration))
            .scaleEffect(configuration.isPressed ? 0.92 : isHovered ? 1.04 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
            .onHover { isHovered = $0 }
    }

    private func backgroundColor(_ c: ButtonStyleConfiguration) -> Color {
        if destructive { return isHovered ? .red.opacity(0.15) : .clear }
        return isHovered ? .primary.opacity(0.1) : .primary.opacity(0.05)
    }

    private func foregroundColor(_ c: ButtonStyleConfiguration) -> Color {
        if destructive { return isHovered ? .red : .secondary }
        return .primary
    }
}

// MARK: - Floating Tooltip

@MainActor
final class FloatingTooltipPanel {
    static let shared = FloatingTooltipPanel()
    private var panel: NSPanel?
    func show(text: String, below anchorFrame: CGRect) {
        present(text: text, below: anchorFrame)
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.alphaValue = 0
    }

    private func present(text: String, below anchorFrame: CGRect) {
        let hosting = NSHostingView(rootView:
            Text(text)
                .font(.caption2)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.white.opacity(0.96))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.black.opacity(0.82))
                )
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        )
        hosting.frame.size = hosting.fittingSize
        let size = hosting.fittingSize

        if panel == nil {
            let p = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .popUpMenu
            p.hasShadow = false
            p.ignoresMouseEvents = true
            panel = p
        }

        panel?.contentView = hosting
        panel?.setContentSize(size)
        panel?.setFrameOrigin(NSPoint(
            x: anchorFrame.midX - size.width / 2,
            y: anchorFrame.minY - size.height - 4
        ))

        panel?.alphaValue = 1
        panel?.orderFront(nil)
    }
}

struct FloatingTooltipAnchor: NSViewRepresentable {
    let text: String?
    let isVisible: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isVisible, let text, !text.isEmpty, let window = nsView.window {
            let windowRect = nsView.convert(nsView.bounds, to: nil)
            let screenRect = window.convertToScreen(windowRect)
            FloatingTooltipPanel.shared.show(text: text, below: screenRect)
        } else {
            FloatingTooltipPanel.shared.hide()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        FloatingTooltipPanel.shared.hide()
    }
}

// MARK: - Helpers

func formatUptime(from start: Date) -> String {
    let s = Int(Date().timeIntervalSince(start))
    if s < 60 { return "<1m" }
    let m = s / 60
    if m < 60 { return "\(m)m" }
    let h = m / 60
    if h < 24 { return "\(h)h \(m % 60)m" }
    return "\(h / 24)d \(h % 24)h"
}
