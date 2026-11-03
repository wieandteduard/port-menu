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

    @Test func capsOnlyAboveTheRowLimit() {
        #expect(PortListMetrics.visibleHeight(rowCount: PortListMetrics.maxRows + 1) == PortListMetrics.capHeight)
        #expect(PortListMetrics.visibleHeight(rowCount: PortListMetrics.maxRows) == nil)
        #expect(PortListMetrics.visibleHeight(rowCount: 3) == nil)
    }

    /// 封顶高度必须含列表底部的 padding，漏掉就会把最后一行切掉半截。
    @Test func capIncludesBottomInset() {
        let expected = CGFloat(PortListMetrics.maxRows) * PortListMetrics.rowHeight + PortListMetrics.bottomInset
        #expect(PortListMetrics.capHeight == expected)
    }

    /// 行高是量出来的，不是一个写死的常数；这里只守住合理区间。
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

    private func renderedHeight(_ store: PortStore) -> CGFloat {
        let view = PortEntryListView()
            .environment(store)
            .frame(width: 340)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 2000)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    /// 真渲染一遍：12 条必须封顶在 capHeight，而不是长到内容那么高。
    @Test func listIsCappedWhenEntriesExceedTheLimit() {
        let height = renderedHeight(makeStore(entryCount: 12))
        #expect(abs(height - PortListMetrics.capHeight) < 2, "rendered height was \(height)")
    }

    /// 3 条时不封顶，窗口按内容自适应。
    @Test func shortListKeepsNaturalHeight() {
        let height = renderedHeight(makeStore(entryCount: 3))
        #expect(height < PortListMetrics.capHeight)
        #expect(height > PortListMetrics.rowHeight * 2)
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
