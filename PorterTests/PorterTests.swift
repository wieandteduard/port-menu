import Testing
import Foundation
import AppKit
import SwiftUI
@testable import Port_Menu

// MARK: - lsof Parser Tests

struct LsofParserTests {

    @Test func parsesStandardLsofOutput() {
        let output = """
        COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node      12345   user   22u  IPv4 0x1234567890      0t0  TCP *:3000 (LISTEN)
        node      12345   user   23u  IPv6 0x1234567891      0t0  TCP *:3000 (LISTEN)
        python3   23456   user   5u   IPv4 0x2345678901      0t0  TCP 127.0.0.1:8080 (LISTEN)
        java      34567   user   10u  IPv4 0x3456789012      0t0  TCP [::1]:5173 (LISTEN)
        """

        let parsed = LivePortScanner.parseLsofOutput(output)

        #expect(parsed.count == 3)
        #expect(parsed[0].port == 3000)
        #expect(parsed[0].pid == 12345)
        #expect(parsed[0].processName == "node")
        #expect(parsed[1].port == 5173)
        #expect(parsed[1].pid == 34567)
        #expect(parsed[1].processName == "java")
        #expect(parsed[2].port == 8080)
        #expect(parsed[2].pid == 23456)
        #expect(parsed[2].processName == "python3")
    }

    @Test func deduplicatesSamePort() {
        let output = """
        COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node      12345   user   22u  IPv4 0x1234567890      0t0  TCP *:3000 (LISTEN)
        node      12345   user   23u  IPv6 0x9876543210      0t0  TCP *:3000 (LISTEN)
        """

        let parsed = LivePortScanner.parseLsofOutput(output)
        #expect(parsed.count == 1)
        #expect(parsed[0].port == 3000)
    }

    @Test func skipsPrivilegedPorts() {
        let output = """
        COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        nginx     12345   root   6u   IPv4 0x1234567890      0t0  TCP *:80 (LISTEN)
        nginx     12345   root   7u   IPv4 0x1234567891      0t0  TCP *:443 (LISTEN)
        node      23456   user   22u  IPv4 0x2345678901      0t0  TCP *:3000 (LISTEN)
        """

        let parsed = LivePortScanner.parseLsofOutput(output)
        #expect(parsed.count == 1)
        #expect(parsed[0].port == 3000)
    }

    @Test func skipsEphemeralPorts() {
        let output = """
        COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        Cursor    13797   user   33u  IPv4 0x1234567890      0t0  TCP 127.0.0.1:52722 (LISTEN)
        Beeper    64785   user   69u  IPv4 0x2345678901      0t0  TCP 127.0.0.1:55829 (LISTEN)
        node      23456   user   22u  IPv4 0x3456789012      0t0  TCP *:3000 (LISTEN)
        """

        let parsed = LivePortScanner.parseLsofOutput(output)
        #expect(parsed.count == 1)
        #expect(parsed[0].port == 3000)
    }

    @Test func skipsNonListenLines() {
        let output = """
        COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node      12345   user   22u  IPv4 0x1234567890      0t0  TCP 127.0.0.1:3000->127.0.0.1:52341 (ESTABLISHED)
        node      23456   user   5u   IPv4 0x2345678901      0t0  TCP *:8080 (LISTEN)
        """

        let parsed = LivePortScanner.parseLsofOutput(output)
        #expect(parsed.count == 1)
        #expect(parsed[0].port == 8080)
    }

    @Test func handlesEmptyOutput() {
        let parsed = LivePortScanner.parseLsofOutput("")
        #expect(parsed.isEmpty)
    }

    @Test func handlesHeaderOnly() {
        let output = "COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME\n"
        let parsed = LivePortScanner.parseLsofOutput(output)
        #expect(parsed.isEmpty)
    }

    @Test func handlesIPv6Addresses() {
        let output = """
        COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node      12345   user   22u  IPv6 0x1234567890      0t0  TCP [::1]:4000 (LISTEN)
        node      23456   user   23u  IPv6 0x2345678901      0t0  TCP [::]:9090 (LISTEN)
        """

        let parsed = LivePortScanner.parseLsofOutput(output)
        #expect(parsed.count == 2)
        #expect(parsed[0].port == 4000)
        #expect(parsed[1].port == 9090)
    }

    @Test func handlesProcessNamesWithVariousLengths() {
        let output = """
        COMMAND          PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        com.docker.be  12345   user   22u  IPv4 0x1234567890      0t0  TCP *:3000 (LISTEN)
        a              23456   user   5u   IPv4 0x2345678901      0t0  TCP *:8080 (LISTEN)
        """

        let parsed = LivePortScanner.parseLsofOutput(output)
        #expect(parsed.count == 2)
    }

    @Test func handlesMalformedLines() {
        let output = """
        COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        this is garbage
        node      12345   user   22u  IPv4 0x1234567890      0t0  TCP *:3000 (LISTEN)
        
        node      badpid  user   22u  IPv4 0x1234567890      0t0  TCP *:4000 (LISTEN)
        """

        let parsed = LivePortScanner.parseLsofOutput(output)
        #expect(parsed.count == 1)
        #expect(parsed[0].port == 3000)
    }

    @Test func sortsPortsNumerically() {
        let output = """
        COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node      12345   user   22u  IPv4 0x1234567890      0t0  TCP *:8080 (LISTEN)
        node      23456   user   5u   IPv4 0x2345678901      0t0  TCP *:3000 (LISTEN)
        node      34567   user   8u   IPv4 0x3456789012      0t0  TCP *:5173 (LISTEN)
        """

        let parsed = LivePortScanner.parseLsofOutput(output)
        #expect(parsed.count == 3)
        #expect(parsed[0].port == 3000)
        #expect(parsed[1].port == 5173)
        #expect(parsed[2].port == 8080)
    }
}

// MARK: - Model Tests

struct ActivePortTests {

    @Test func urlConstruction() {
        let port = ActivePort(port: 3000, pid: 123, projectName: "test", branch: "main", startTime: nil)
        #expect(port.url.absoluteString == "http://localhost:3000")
    }

    @Test func compositeIdentity() {
        let a = ActivePort(port: 3000, pid: 100, projectName: "test", branch: "main", startTime: nil)
        let b = ActivePort(port: 3000, pid: 200, projectName: "test", branch: "main", startTime: nil)
        #expect(a.id != b.id)
    }

    @Test func equalityCheck() {
        let time = Date()
        let a = ActivePort(port: 3000, pid: 100, projectName: "test", branch: "main", startTime: time)
        let b = ActivePort(port: 3000, pid: 100, projectName: "test", branch: "main", startTime: time)
        #expect(a == b)
    }
}

// MARK: - FakeScanner Tests

struct FakeScannerTests {

    @Test func returnsConfiguredPorts() async {
        let ports = [
            ActivePort(port: 3000, pid: 1, projectName: "a", branch: "", startTime: nil),
            ActivePort(port: 8080, pid: 2, projectName: "b", branch: "", startTime: nil),
        ]
        let scanner = FakePortScanner(ports: ports, delay: 0)
        let result = await scanner.scan()
        if case .success(let found, let diag) = result {
            #expect(found.count == 2)
            #expect(diag.dataSource == "fake")
        } else {
            Issue.record("Expected success")
        }
    }

    @Test func simulatesFailure() async {
        let scanner = FakePortScanner(shouldFail: true)
        let result = await scanner.scan()
        if case .failure(let error, _) = result {
            #expect(error.localizedDescription.contains("Simulated"))
        } else {
            Issue.record("Expected failure")
        }
    }
}

// MARK: - Uptime Formatter Tests

struct UptimeFormatterTests {

    @Test func lessThanOneMinute() {
        let result = formatUptime(from: Date().addingTimeInterval(-30))
        #expect(result == "<1m")
    }

    @Test func minutes() {
        let result = formatUptime(from: Date().addingTimeInterval(-300))
        #expect(result == "5m")
    }

    @Test func hoursAndMinutes() {
        let result = formatUptime(from: Date().addingTimeInterval(-3660))
        #expect(result == "1h 1m")
    }

    @Test func daysAndHours() {
        let result = formatUptime(from: Date().addingTimeInterval(-90000))
        #expect(result == "1d 1h")
    }
}

// MARK: - Refresh Interval Tests

struct RefreshIntervalTests {

    @Test func defaultInterval() {
        #expect(RefreshInterval.defaultInterval == .normal)
        #expect(RefreshInterval.defaultInterval.rawValue == 5)
    }

    @Test func allCasesOrdered() {
        let values = RefreshInterval.allCases.map(\.rawValue)
        #expect(values == values.sorted())
    }
}

// MARK: - Git Root Detection Tests

struct GitRootTests {

    @Test func findsGitRootInCurrentDir() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let gitDir = tmpDir.appendingPathComponent(".git")
        try? FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)

        let result = LivePortScanner.findGitRoot(from: tmpDir.path)
        #expect(result?.path == tmpDir.path)

        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func findsGitRootInParentDir() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let childDir = tmpDir.appendingPathComponent("src/components")
        try? FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
        let gitDir = tmpDir.appendingPathComponent(".git")
        try? FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)

        let result = LivePortScanner.findGitRoot(from: childDir.path)
        #expect(result?.path == tmpDir.path)

        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func returnsNilWhenNoGitRoot() {
        let result = LivePortScanner.findGitRoot(from: "/tmp")
        #expect(result == nil)
    }
}

// MARK: - Display Name Tests

struct DisplayNameTests {

    @Test func prefersGitRootName() {
        let name = LivePortScanner.displayName(
            processName: "beam.smp",
            cwd: "/Users/me/work/backend",
            gitRoot: URL(filePath: "/Users/me/work/agidb-backend")
        )
        #expect(name == "agidb-backend")
    }

    @Test func fallsBackToMeaningfulCwdBasename() {
        let name = LivePortScanner.displayName(
            processName: "beam.smp",
            cwd: "/Users/me/work/agidb-backend",
            gitRoot: nil
        )
        #expect(name == "agidb-backend")
    }

    @Test func fallsBackToProcessNameForGenericDirectory() {
        let name = LivePortScanner.displayName(
            processName: "beam.smp",
            cwd: "/Users/me/work/agidb-backend/_build",
            gitRoot: nil
        )
        #expect(name == "beam.smp")
    }

    @Test func fallsBackToProcessNameWithoutCwd() {
        let name = LivePortScanner.displayName(
            processName: "beam.smp",
            cwd: nil,
            gitRoot: nil
        )
        #expect(name == "beam.smp")
    }
}

// MARK: - Fallback Filter Tests

struct FallbackFilterTests {

    @Test func keepsKnownDevRuntimeWithoutGitRoot() {
        #expect(LivePortScanner.shouldKeepFallbackProcess(
            processName: "beam.smp",
            cwd: "/Users/me/work/agidb-backend"
        ))
    }

    @Test func keepsVersionedPythonRuntime() {
        #expect(LivePortScanner.shouldKeepFallbackProcess(
            processName: "python3.12",
            cwd: "/Users/me/work/api"
        ))
    }

    @Test func rejectsDesktopAppWithoutGitRoot() {
        #expect(!LivePortScanner.shouldKeepFallbackProcess(
            processName: "Spotify",
            cwd: "/Applications/Spotify.app/Contents/MacOS"
        ))
    }

    @Test func rejectsFigmaWithoutGitRoot() {
        #expect(!LivePortScanner.shouldKeepFallbackProcess(
            processName: "Figma",
            cwd: "/Applications/Figma.app/Contents/MacOS"
        ))
    }

    @Test func keepsDockerBackendTruncated() {
        #expect(LivePortScanner.shouldKeepFallbackProcess(
            processName: "com.docke",
            cwd: "/"
        ))
    }

    @Test func keepsDockerProxy() {
        #expect(LivePortScanner.shouldKeepFallbackProcess(
            processName: "docker-proxy",
            cwd: "/"
        ))
    }

    @Test func keepsVpnkit() {
        #expect(LivePortScanner.shouldKeepFallbackProcess(
            processName: "vpnkit-bridge",
            cwd: "/"
        ))
    }
}

// MARK: - Docker Display Name Tests

struct DockerDisplayNameTests {

    @Test func dockerBackendShowsDocker() {
        let name = LivePortScanner.displayName(
            processName: "com.docke",
            cwd: "/",
            gitRoot: nil
        )
        #expect(name == "Docker")
    }

    @Test func dockerProxyShowsDocker() {
        let name = LivePortScanner.displayName(
            processName: "docker-pr",
            cwd: "/",
            gitRoot: nil
        )
        #expect(name == "Docker")
    }

    @Test func dockerWithGitRootPrefersGitName() {
        let name = LivePortScanner.displayName(
            processName: "com.docke",
            cwd: "/Users/me/app",
            gitRoot: URL(filePath: "/Users/me/app")
        )
        #expect(name == "app")
    }
}

// MARK: - PortStore Tests

@Suite(.serialized) struct PortStoreTests {

    @Test @MainActor func storeInitializesEmpty() {
        let store = PortStore(scanner: FakePortScanner(ports: [], delay: 0))
        #expect(store.entries.isEmpty)
        #expect(store.lastError == nil)
        #expect(!store.isScanning)
    }

    @Test @MainActor func refreshPopulatesEntries() async throws {
        let ports = [
            ActivePort(port: 3000, pid: 1, projectName: "test", branch: "main", startTime: nil)
        ]
        let store = PortStore(scanner: FakePortScanner(ports: ports, delay: 0))

        store.refresh()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(store.entries.count == 1)
        #expect(store.entries[0].port == 3000)
    }

    @Test @MainActor func refreshHandlesFailure() async throws {
        let store = PortStore(scanner: FakePortScanner(shouldFail: true))

        store.refresh()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(store.lastError != nil)
    }

    @Test @MainActor func killProcessAddsToRecentlyKilled() async throws {
        let ports = [
            ActivePort(port: 3000, pid: 99999, projectName: "test", branch: "", startTime: nil)
        ]
        let store = PortStore(scanner: FakePortScanner(ports: ports, delay: 0))

        store.refresh()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.entries.count == 1)

        store.killProcess(pid: 99999, port: 3000)
        store.refresh()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(store.entries.isEmpty)
    }

    @Test @MainActor func killAllProcessesFiltersRecentlyKilledPorts() async throws {
        let ports = [
            ActivePort(port: 3000, pid: 99998, projectName: "web", branch: "", startTime: nil),
            ActivePort(port: 5173, pid: 99997, projectName: "app", branch: "", startTime: nil)
        ]
        let store = PortStore(scanner: FakePortScanner(ports: ports, delay: 0))

        store.refresh()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.entries.count == 2)

        store.killAllProcesses()
        #expect(store.entries.isEmpty)

        store.refresh()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.entries.isEmpty)
    }

    @Test @MainActor func diagnosticsSnapshot() {
        let store = PortStore(scanner: FakePortScanner(ports: [], delay: 0))
        let snapshot = store.diagnosticsSnapshot
        #expect(snapshot.contains("Port Menu Diagnostics"))
        #expect(snapshot.contains("Ports found: 0"))
    }
}

// MARK: - ScanDiagnostics Tests

struct ScanDiagnosticsTests {

    @Test func summaryFormat() {
        let diag = ScanDiagnostics(
            duration: 0.042,
            portsFound: 3,
            dataSource: "lsof",
            timestamp: Date()
        )
        let summary = diag.summary
        #expect(summary.contains("42"))
        #expect(summary.contains("3 ports"))
        #expect(summary.contains("lsof"))
    }
}

// MARK: - List Metrics Tests

@MainActor
struct PortListMetricsTests {

    @Test func shortListNeedsNoCap() {
        #expect(PortListMetrics.visibleHeight(rowCount: 3, available: 800) == nil)
        #expect(PortListMetrics.visibleHeight(rowCount: 0, available: 800) == nil)
    }

    /// 内容比可用高度高时才封顶，且封顶高度就是可用高度。
    @Test func longListIsCappedToTheAvailableHeight() {
        let available = PortListMetrics.rowHeight * 6 + PortListMetrics.bottomInset
        #expect(PortListMetrics.visibleHeight(rowCount: 9, available: available) == available)
        #expect(PortListMetrics.visibleHeight(rowCount: 21, available: available) == available)
    }

    /// 上限跟随屏幕：屏幕越高，能铺开的行数越多。
    @Test func availableHeightFollowsTheScreen() {
        let tall = PortListMetrics.availableListHeight(screenHeight: 1_000)
        let short = PortListMetrics.availableListHeight(screenHeight: 600)
        #expect(tall > short)
        #expect(tall == 1_000 - PortListMetrics.headerAllowance - PortListMetrics.screenMargin)
    }

    /// 两块屏高度不同时，可用高度必须跟着屏走——这正是多显示器下 `NSScreen.main`
    /// 会算错的那 356pt（本机内建 1084 vs 外接 1440）。
    @Test func differentScreensGiveDifferentCaps() {
        let builtIn = PortListMetrics.availableListHeight(screenHeight: 1084)
        let external = PortListMetrics.availableListHeight(screenHeight: 1440)
        #expect(builtIn == 1084 - PortListMetrics.headerAllowance - PortListMetrics.screenMargin,
                "builtIn was \(builtIn), rowHeight \(PortListMetrics.rowHeight)")
        #expect(external == 1440 - PortListMetrics.headerAllowance - PortListMetrics.screenMargin,
                "external was \(external)")
        #expect(external - builtIn == 356)
    }

    /// 极小屏也别算出比两行还小的窗口。
    @Test func availableHeightKeepsATwoRowFloor() {
        let floorHeight = PortListMetrics.rowHeight * 2 + PortListMetrics.bottomInset
        #expect(PortListMetrics.availableListHeight(screenHeight: 40) == floorHeight)
    }

    /// 封顶高度是"可用高度"本身，而可用高度已经扣掉了顶部与留白——
    /// 这一条把"漏掉 bottomInset 会切掉最后一行"的教训钉住：行数 × 行高之外还有底部 padding。
    @Test func contentHeightIncludesBottomInset() {
        let available = CGFloat(2) * PortListMetrics.rowHeight + PortListMetrics.bottomInset - 1
        #expect(PortListMetrics.visibleHeight(rowCount: 2, available: available) == available)
    }

    /// tracker：读到值就记住，读到 nil 不要覆盖已有值（"这次没读到"≠"屏幕没高度"）。
    @Test func screenTrackerKeepsLastKnownHeight() {
        let tracker = PopoverScreenTracker()
        tracker.update(visibleHeight: 1084)
        #expect(tracker.visibleHeight == 1084)
        tracker.update(visibleHeight: nil)
        #expect(tracker.visibleHeight == 1084)
        tracker.update(visibleHeight: 1440)
        #expect(tracker.visibleHeight == 1440)
    }

    @Test func measuredRowHeightIsPlausible() {
        #expect(PortListMetrics.rowHeight >= 40)
        #expect(PortListMetrics.rowHeight <= 90)
    }
}

// MARK: - Entry List Render Tests

@MainActor
struct PortEntryListRenderTests {

    private func makeStore(entryCount: Int) -> PortStore {
        let store = PortStore(scanner: FakePortScanner(ports: [], delay: 0))
        store.entries = (0..<entryCount).map { index in
            ActivePort(
                port: UInt16(3000 + index),
                pid: Int32(index + 1),
                projectName: "repo › apps/pkg\(index)",
                branch: "main",
                startTime: nil
            )
        }
        return store
    }

    /// 真渲染一遍：条数超过屏幕可用高度时必须封顶，而不是长到内容那么高。
    /// 条数取得足够多，避免依赖具体机器的屏幕高度。
    @Test func listIsCappedWhenEntriesExceedTheScreen() {
        let store = makeStore(entryCount: 60)
        let view = PortEntryListView()
            .environment(store)
            .frame(width: 340)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 4000)
        hosting.layoutSubtreeIfNeeded()

        let height = hosting.fittingSize.height
        let available = PortListMetrics.availableListHeight()
        #expect(abs(height - available) < 2, "rendered \(height), available \(available)")
    }

    /// 装得下时铺开：3 条就只占 3 行 + 底部 padding 的高度。
    @Test func shortListRendersAtItsNaturalHeight() {
        let store = makeStore(entryCount: 3)
        let view = PortEntryListView()
            .environment(store)
            .frame(width: 340)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 4000)
        hosting.layoutSubtreeIfNeeded()

        let expected = 3 * PortListMetrics.rowHeight + PortListMetrics.bottomInset
        #expect(abs(hosting.fittingSize.height - expected) < 2, "rendered \(hosting.fittingSize.height)")
    }
}

// MARK: - Workspace Glob Tests

struct WorkspaceGlobTests {

    @Test func singleStarMatchesExactlyOneSegment() {
        #expect(WorkspaceResolver.matches(pattern: "packages/*", path: "packages/web"))
        #expect(!WorkspaceResolver.matches(pattern: "packages/*", path: "packages/web/sub"))
        #expect(!WorkspaceResolver.matches(pattern: "packages/*", path: "packages"))
    }

    @Test func doubleStarMatchesAnyDepth() {
        #expect(WorkspaceResolver.matches(pattern: "packages/**", path: "packages/web"))
        #expect(WorkspaceResolver.matches(pattern: "packages/**", path: "packages/group/web"))
        #expect(!WorkspaceResolver.matches(pattern: "packages/**", path: "apps/web"))
    }

    @Test func literalSegmentsAreCaseInsensitive() {
        #expect(WorkspaceResolver.matches(pattern: "packages/web", path: "Packages/Web"))
    }

    @Test func leadingDotSlashIsStripped() {
        #expect(WorkspaceResolver.matches(pattern: "./service", path: "service"))
    }
}

// MARK: - Workspace Heuristic Tests

struct WorkspaceHeuristicTests {

    /// 建一个临时仓库骨架：`dirs` 是要创建的目录，`manifests` 是相对文件路径。
    private func makeRepo(dirs: [String], manifests: [String] = []) throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "workspace-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for dir in dirs {
            try FileManager.default.createDirectory(
                at: root.appending(path: dir), withIntermediateDirectories: true
            )
        }
        for manifest in manifests {
            let url = root.appending(path: manifest)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try "{}".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func detectsPackageDirectoryWithManifest() throws {
        let root = try makeRepo(dirs: ["packages/web"], manifests: ["packages/web/package.json"])
        let path = WorkspaceResolver.packagePath(
            cwd: root.appending(path: "packages/web").path(),
            repoRoot: root.path(),
            patterns: nil
        )
        #expect(path == "packages/web")
        try? FileManager.default.removeItem(at: root)
    }

    /// 包里嵌套的构建配置目录（自带 package.json）不能抢走包的身份。
    @Test func nestedBuildConfigurationDoesNotBecomeThePackage() throws {
        let root = try makeRepo(
            dirs: ["packages/rocket/platform/vivo"],
            manifests: ["packages/rocket/package.json", "packages/rocket/platform/vivo/package.json"]
        )
        let path = WorkspaceResolver.packagePath(
            cwd: root.appending(path: "packages/rocket/platform/vivo").path(),
            repoRoot: root.path(),
            patterns: nil
        )
        #expect(path == "packages/rocket")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func climbsToNearestAncestorWithManifest() throws {
        let root = try makeRepo(dirs: ["packages/web/src/deep"], manifests: ["packages/web/package.json"])
        let path = WorkspaceResolver.packagePath(
            cwd: root.appending(path: "packages/web/src/deep").path(),
            repoRoot: root.path(),
            patterns: nil
        )
        #expect(path == "packages/web")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func repoRootItselfIsNotAPackage() throws {
        let root = try makeRepo(dirs: [], manifests: ["package.json"])
        #expect(WorkspaceResolver.packagePath(cwd: root.path(), repoRoot: root.path(), patterns: nil) == nil)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func excludedSegmentsAreRejected() throws {
        let root = try makeRepo(
            dirs: ["packages/web/node_modules/dep"],
            manifests: ["packages/web/node_modules/dep/package.json"]
        )
        let path = WorkspaceResolver.packagePath(
            cwd: root.appending(path: "packages/web/node_modules/dep").path(),
            repoRoot: root.path(),
            patterns: nil
        )
        #expect(path == nil)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func deeperThanTheCapIsRejected() throws {
        let root = try makeRepo(
            dirs: ["a/b/c/d/e"],
            manifests: ["a/b/c/d/e/package.json"]
        )
        #expect(WorkspaceResolver.packagePath(
            cwd: root.appending(path: "a/b/c/d/e").path(), repoRoot: root.path(), patterns: nil
        ) == nil)
        try? FileManager.default.removeItem(at: root)
    }

    /// 清单可以把包直接声明在仓库根下（深度 1），不被 minDepth 拦。
    @Test func declaredPackageAtRepoRootDepthIsAllowed() throws {
        let root = try makeRepo(dirs: ["codex-cli"], manifests: ["codex-cli/package.json"])
        let path = WorkspaceResolver.packagePath(
            cwd: root.appending(path: "codex-cli").path(),
            repoRoot: root.path(),
            patterns: ["codex-cli", "sdk/typescript"]
        )
        #expect(path == "codex-cli")
        try? FileManager.default.removeItem(at: root)
    }

    /// 声明的清单是否决权：没被 pattern 命中的目录不算包，哪怕它自己有 manifest。
    @Test func declaredPatternsVetoTheHeuristic() throws {
        let root = try makeRepo(
            dirs: ["apps/web", "docs/tooling"],
            manifests: ["apps/web/package.json", "docs/tooling/package.json"]
        )
        let web = WorkspaceResolver.packagePath(
            cwd: root.appending(path: "apps/web").path(), repoRoot: root.path(), patterns: ["apps/*"]
        )
        let tooling = WorkspaceResolver.packagePath(
            cwd: root.appending(path: "docs/tooling").path(), repoRoot: root.path(), patterns: ["apps/*"]
        )
        #expect(web == "apps/web")
        #expect(tooling == nil)
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Workspace Elision Tests

struct WorkspaceElisionTests {

    @Test func elidesSharedParent() {
        #expect(WorkspaceResolver.elisionPrefix(for: ["packages/a", "packages/b"]) == "packages/")
    }

    @Test func noElisionWhenParentsDiffer() {
        #expect(WorkspaceResolver.elisionPrefix(for: ["packages/a", "apps/b"]) == nil)
    }

    @Test func noElisionWhenDepthsDiffer() {
        #expect(WorkspaceResolver.elisionPrefix(for: ["packages/a", "toplevel"]) == nil)
    }

    @Test func emptyInputHasNoPrefix() {
        #expect(WorkspaceResolver.elisionPrefix(for: []) == nil)
    }
}

// MARK: - Workspace Manifest Parser Tests

struct WorkspaceManifestParserTests {

    @Test func pnpmWorkspaceList() {
        let yaml = """
        packages:
          - "packages/*"
          - 'apps/*'
          - "!packages/legacy/**"
        catalog:
          react: ^19.0.0
        """
        #expect(WorkspaceResolver.pnpmPatterns(yaml) == ["packages/*", "apps/*", "!packages/legacy/**"])
    }

    @Test func npmWorkspacesArray() {
        let json = #"{"name":"repo","workspaces":["packages/*","apps/*"]}"#
        #expect(WorkspaceResolver.npmPatterns(json) == ["packages/*", "apps/*"])
    }

    @Test func npmWorkspacesObjectForm() {
        let json = #"{"workspaces":{"packages":["packages/*"],"nohoist":["**/react"]}}"#
        #expect(WorkspaceResolver.npmPatterns(json) == ["packages/*"])
    }

    @Test func npmWithoutWorkspacesIsNil() {
        #expect(WorkspaceResolver.npmPatterns(#"{"name":"repo"}"#) == nil)
    }

    @Test func cargoMembersMultiline() {
        let toml = """
        [workspace]
        members = [
            "crates/core",
            "crates/cli",
        ]
        exclude = ["crates/legacy"]
        """
        #expect(WorkspaceResolver.cargoMembers(toml) == ["crates/core", "crates/cli", "!crates/legacy"])
    }

    @Test func goWorkUseBlock() {
        let work = """
        go 1.22

        use (
        	./service
        	../shared
        )
        """
        #expect(WorkspaceResolver.goWorkUse(work) == ["./service", "../shared"])
    }

    @Test func goWorkUseSingleValue() {
        #expect(WorkspaceResolver.goWorkUse("go 1.22\n\nuse ./only\n") == ["./only"])
    }
}

// MARK: - Monorepo Display Name Tests

struct MonorepoDisplayNameTests {

    @Test func packageNameCombinesRepoAndPath() {
        let name = LivePortScanner.displayName(
            processName: "node",
            cwd: "/Users/me/work/gc-2026-10/packages/c3-disco-droids",
            gitRoot: URL(filePath: "/Users/me/work/gc-2026-10"),
            packagePath: "c3-disco-droids"
        )
        #expect(name == "gc-2026-10 › c3-disco-droids")
    }

    @Test func singlePackageRepoStaysBare() {
        let name = LivePortScanner.displayName(
            processName: "node",
            cwd: "/Users/me/work/showyedge",
            gitRoot: URL(filePath: "/Users/me/work/showyedge"),
            packagePath: nil
        )
        #expect(name == "showyedge")
    }

    @Test func emptyPackagePathFallsBackToRepoName() {
        let name = LivePortScanner.displayName(
            processName: "node",
            cwd: "/Users/me/work/showyedge",
            gitRoot: URL(filePath: "/Users/me/work/showyedge"),
            packagePath: ""
        )
        #expect(name == "showyedge")
    }
}

// MARK: - Process Label Tests

struct ProcessLabelTests {

    /// pnpm dlx 的缓存路径：名字藏在最后一个 node_modules 之后的作用域包里。
    @Test func resolvesPackageNameFromPnpmDlxPath() {
        let command = """
        node /Users/me/Library/Caches/pnpm/dlx/fe07/mvyx/node_modules/.bin/../.pacquet/@deepseek-ai+dsh@0.2.1-rc.5_39cc/node_modules/@deepseek-ai/dsh/lib/bin.js web
        """
        #expect(ProcessLabel.label(command: command, processName: "node") == "dsh")
    }

    @Test func resolvesScriptNameFromPlainNode() {
        #expect(ProcessLabel.label(command: "node server.mjs --port 3000", processName: "node") == "server")
        #expect(ProcessLabel.label(command: "/opt/homebrew/bin/node /Users/me/app/index.js", processName: "node") == "index")
    }

    @Test func keepsNonInterpreterProgramName() {
        #expect(ProcessLabel.label(command: "/Users/me/.local/bin/next dev", processName: "next") == "next")
    }

    /// 进程自己改了标题：COMMAND 列是 node，但 ps 的 command 是它自定的名字。
    @Test func usesSelfAssignedProcessTitle() {
        #expect(ProcessLabel.label(command: "Raycast Backend", processName: "node") == "Raycast Backend")
    }

    @Test func resolvesPythonModuleFlag() {
        #expect(ProcessLabel.label(command: "python3 -m http.server 3300", processName: "Python") == "http.server")
        #expect(ProcessLabel.label(command: "python3 app.py", processName: "Python") == "app")
    }

    @Test func fallsBackToProcessNameWithoutCommand() {
        #expect(ProcessLabel.label(command: "", processName: "node") == "node")
    }

    @Test func directoryTailHidesRootAndHome() {
        var home = FileManager.default.homeDirectoryForCurrentUser.path()
        // 测试宿主进程的 HOME 带尾斜杠，先归一化再拼路径。
        if home.count > 1, home.hasSuffix("/") { home.removeLast() }
        #expect(ProcessLabel.directoryTail(cwd: "/") == "")
        let tailOfHome = ProcessLabel.directoryTail(cwd: home)
        #expect(tailOfHome == "", "home=\(home) tail=\(tailOfHome)")
        #expect(ProcessLabel.directoryTail(cwd: nil) == "")
        #expect(ProcessLabel.directoryTail(cwd: home + "/Github") == "~/Github")
        #expect(ProcessLabel.directoryTail(cwd: "/tmp/scratch") == "/tmp/scratch")
    }

    /// 无 git 根时主行用命令身份，而不是容器目录名。
    @Test func displayNamePrefersCommandOverContainerDirectory() {
        let name = LivePortScanner.displayName(
            processName: "node",
            cwd: "/Users/me/Github",
            gitRoot: nil,
            packagePath: nil,
            command: "node /Users/me/.cache/dlx/abc/node_modules/@deepseek-ai/dsh/lib/bin.js web"
        )
        #expect(name == "dsh")
    }

    /// 有 git 根时命令身份不参与命名，仓库名/包路径照旧。
    @Test func commandDoesNotOverrideGitProjectName() {
        let name = LivePortScanner.displayName(
            processName: "node",
            cwd: "/Users/me/work/port-menu",
            gitRoot: URL(filePath: "/Users/me/work/port-menu"),
            packagePath: nil,
            command: "node /Users/me/work/port-menu/scripts/dev.js"
        )
        #expect(name == "port-menu")
    }
}
