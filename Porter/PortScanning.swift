import Foundation
import os

// MARK: - Protocol

protocol PortScanning: Sendable {
    func scan() async -> ScanResult
}

// MARK: - Live Scanner

struct LivePortScanner: PortScanning {
    private let log = Log.scanner

    private static let branchTTL: TimeInterval = 30
    private static let cache = CacheStore()

    func scan() async -> ScanResult {
        let start = Date()
        let previousPorts: [ActivePort] = []

        do {
            let ports = try await performScan()
            let diag = ScanDiagnostics(
                duration: Date().timeIntervalSince(start),
                portsFound: ports.count,
                dataSource: "lsof",
                timestamp: Date()
            )
            log.info("Scan complete: \(ports.count) ports in \((diag.duration * 1000).formatted(.number.precision(.fractionLength(0))))ms")
            return .success(ports, diag)
        } catch let error as ScanError {
            log.error("Scan failed: \(error.localizedDescription)")
            return .failure(error, previousPorts)
        } catch {
            log.error("Scan failed unexpectedly: \(error.localizedDescription)")
            return .failure(.lsofFailed(error.localizedDescription), previousPorts)
        }
    }

    private func performScan() async throws -> [ActivePort] {
        let lsofOutput = try await runShell(
            "/usr/sbin/lsof", args: ["-iTCP", "-sTCP:LISTEN", "-n", "-P"],
            timeout: 10
        )

        let parsed = Self.parseLsofOutput(lsofOutput)
        if parsed.isEmpty {
            if Log.isVerbose { log.debug("lsof returned no listening ports") }
            return []
        }

        let pids = Set(parsed.map(\.pid))
        async let cwdResult = resolveCWDs(pids: pids)
        async let startTimeResult = resolveStartTimes(pids: pids)
        let (cwds, startTimes) = await (cwdResult, startTimeResult)

        return await resolveProjects(parsed: parsed, cwds: cwds,
                                     startTimes: startTimes)
    }

    // MARK: - lsof Parsing (static for testability)

    struct ParsedPort: Sendable {
        let port: UInt16
        let pid: Int32
    }

    static func parseLsofOutput(_ output: String) -> [ParsedPort] {
        var seen = Set<UInt16>()
        var results: [ParsedPort] = []

        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9 else { continue }
            guard let pid = Int32(cols[1]) else { continue }

            let nameCol = String(cols[cols.count - 2])
            guard let colonIdx = nameCol.lastIndex(of: ":"),
                  let port = UInt16(nameCol[nameCol.index(after: colonIdx)...])
            else { continue }

            let stateCol = String(cols[cols.count - 1])
            guard stateCol == "(LISTEN)" else { continue }

            guard port >= 1024, port < 49152 else {
                if Log.isVerbose {
                    Log.scanner.debug("Skipping out-of-range port \(port)")
                }
                continue
            }

            guard seen.insert(port).inserted else { continue }
            results.append(ParsedPort(port: port, pid: pid))
        }

        return results.sorted { $0.port < $1.port }
    }

    // MARK: - CWD Resolution

    private func resolveCWDs(pids: Set<Int32>) async -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map(String.init).joined(separator: ",")
        guard let output = try? await runShell(
            "/usr/sbin/lsof", args: ["-a", "-p", pidList, "-d", "cwd", "-Fn"],
            timeout: 10
        ) else { return [:] }

        var result: [Int32: String] = [:]
        var currentPID: Int32?

        for line in output.split(separator: "\n") {
            if line.hasPrefix("p"), let pid = Int32(line.dropFirst()) {
                currentPID = pid
            } else if line.hasPrefix("n/"), let pid = currentPID {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    // MARK: - Start Time Resolution

    private func resolveStartTimes(pids: Set<Int32>) async -> [Int32: Date] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map(String.init).joined(separator: ",")
        guard let output = try? await runShell(
            "/bin/ps", args: ["-p", pidList, "-o", "pid=,lstart="],
            timeout: 5,
            environment: ["LC_ALL": "C"]
        ) else { return [:] }

        var result: [Int32: Date] = [:]
        // ps lstart format: "Tue Mar  5 14:23:01 2026"
        let strategy = Date.ParseStrategy(
            format: "\(weekday: .abbreviated) \(month: .abbreviated) \(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) \(year: .defaultDigits)",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: .current
        )
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let normalized = parts[1]
                .split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: " ")
            if let date = try? Date(normalized, strategy: strategy) {
                result[pid] = date
            }
        }
        return result
    }

    // MARK: - Git Resolution

    private func resolveProjects(
        parsed: [ParsedPort],
        cwds: [Int32: String],
        startTimes: [Int32: Date]
    ) async -> [ActivePort] {
        var gitRoots: [String: URL] = [:]
        var branches: [String: String] = [:]

        for (_, cwd) in cwds {
            guard gitRoots[cwd] == nil else { continue }

            let root: URL?
            if let cached = Self.cache.gitRoot(for: cwd) {
                root = cached
            } else {
                root = Self.findGitRoot(from: cwd)
                Self.cache.setGitRoot(root, for: cwd)
            }

            if let root {
                gitRoots[cwd] = root
                let rootPath = root.path()
                if branches[rootPath] == nil {
                    if let cached = Self.cache.branch(for: rootPath, ttl: Self.branchTTL) {
                        branches[rootPath] = cached
                    } else {
                        let branch = await resolveGitBranch(at: rootPath)
                        branches[rootPath] = branch
                        Self.cache.setBranch(branch, for: rootPath)
                    }
                }
            }
        }

        let activeCWDs = Set(cwds.values)
        let activeRootPaths = Set(gitRoots.values.map { $0.path() })
        Self.cache.prune(activeCWDs: activeCWDs, activeRootPaths: activeRootPaths)

        return parsed.compactMap { info -> ActivePort? in
            guard let cwd = cwds[info.pid],
                  let gitRoot = gitRoots[cwd] else { return nil }
            let rootPath = gitRoot.path()

            return ActivePort(
                port: info.port,
                pid: info.pid,
                projectName: gitRoot.lastPathComponent,
                branch: branches[rootPath] ?? "",
                startTime: startTimes[info.pid]
            )
        }
    }

    private func resolveGitBranch(at gitRoot: String) async -> String {
        guard let output = try? await runShell(
            "/usr/bin/git", args: ["-C", gitRoot, "rev-parse", "--abbrev-ref", "HEAD"],
            timeout: 5
        ) else { return "" }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func findGitRoot(from path: String) -> URL? {
        var current = URL(filePath: path)
        let fm = FileManager.default
        while current.path() != "/" {
            if fm.fileExists(atPath: current.appending(path: ".git").path()) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Shell Execution (async, with timeout)

    private func runShell(
        _ executable: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil
    ) async throws -> String {
        // Run the blocking process on a background thread via a detached task,
        // then race it against a timeout task using withTaskGroup.
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Self.runProcess(
                    executable: executable, args: args, environment: environment
                )
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                Log.shell.warning("Process timed out: \(executable) \(args.joined(separator: " "))")
                throw ScanError.lsofTimeout
            }

            // Return the first result (success or error); cancel the other task.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func runProcess(
        executable: String,
        args: [String],
        environment: [String: String]?
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = URL(filePath: executable)
            process.arguments = args
            process.standardOutput = stdout
            process.standardError = stderr

            if let env = environment {
                var combined = ProcessInfo.processInfo.environment
                for (k, v) in env { combined[k] = v }
                process.environment = combined
            }

            do {
                try process.run()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let errData = stderr.fileHandleForReading.availableData
                    let errMsg = String(data: errData, encoding: .utf8) ?? ""
                    if Log.isVerbose {
                        Log.shell.debug("Process exit \(process.terminationStatus): \(executable) — \(errMsg)")
                    }
                    continuation.resume(throwing: ScanError.lsofFailed(
                        "\(executable) exited with \(process.terminationStatus)"))
                    return
                }

                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            } catch {
                continuation.resume(throwing: ScanError.lsofFailed(error.localizedDescription))
            }
        }
    }
}

// MARK: - Cache

final class CacheStore: Sendable {
    private let _gitRoots = OSAllocatedUnfairLock(initialState: [String: URL?]())
    private let _branches = OSAllocatedUnfairLock(initialState: [String: (branch: String, resolved: Date)]())

    func gitRoot(for cwd: String) -> URL?? {
        _gitRoots.withLock { $0[cwd] }
    }

    func setGitRoot(_ root: URL?, for cwd: String) {
        _gitRoots.withLock { $0[cwd] = root }
    }

    func branch(for rootPath: String, ttl: TimeInterval) -> String? {
        _branches.withLock { cache in
            guard let entry = cache[rootPath],
                  Date().timeIntervalSince(entry.resolved) < ttl else { return nil }
            return entry.branch
        }
    }

    func setBranch(_ branch: String, for rootPath: String) {
        _branches.withLock { $0[rootPath] = (branch, Date()) }
    }

    func prune(activeCWDs: Set<String>, activeRootPaths: Set<String>) {
        _gitRoots.withLock { cache in
            cache = cache.filter { activeCWDs.contains($0.key) }
        }
        _branches.withLock { cache in
            cache = cache.filter { activeRootPaths.contains($0.key) }
        }
    }
}

// MARK: - Fake Scanner (for tests & previews)

struct FakePortScanner: PortScanning {
    var ports: [ActivePort]
    var delay: TimeInterval
    var shouldFail: Bool

    init(
        ports: [ActivePort] = FakePortScanner.samplePorts,
        delay: TimeInterval = 0.1,
        shouldFail: Bool = false
    ) {
        self.ports = ports
        self.delay = delay
        self.shouldFail = shouldFail
    }

    func scan() async -> ScanResult {
        try? await Task.sleep(for: .seconds(delay))
        if shouldFail {
            return .failure(.lsofFailed("Simulated failure"), ports)
        }
        let diag = ScanDiagnostics(
            duration: delay,
            portsFound: ports.count,
            dataSource: "fake",
            timestamp: Date()
        )
        return .success(ports, diag)
    }

    static let samplePorts: [ActivePort] = [
        ActivePort(port: 3000, pid: 1001, projectName: "my-frontend",
                   branch: "main", startTime: Date().addingTimeInterval(-3600)),
        ActivePort(port: 5173, pid: 1002, projectName: "vite-app",
                   branch: "feature/dark-mode", startTime: Date().addingTimeInterval(-600)),
        ActivePort(port: 8080, pid: 1003, projectName: "api-server",
                   branch: "develop", startTime: Date().addingTimeInterval(-86400)),
    ]
}
