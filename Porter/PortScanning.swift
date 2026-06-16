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
    private static let processTracker = ProcessTracker()
    private static let allowedFallbackProcessNames: Set<String> = [
        "air",
        "beam.smp",
        "bun",
        "deno",
        "elixir",
        "erl",
        "go",
        "gunicorn",
        "java",
        "mix",
        "node",
        "php",
        "puma",
        "python",
        "python3",
        "reflex",
        "ruby",
        "uvicorn"
    ]

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
        let hasContainerPorts = parsed.contains {
            Self.containerRuntimeName(for: $0.processName) != nil
        }
        async let cwdResult = resolveCWDs(pids: pids)
        async let startTimeResult = resolveStartTimes(pids: pids)
        async let containerResult = resolveContainers(enabled: hasContainerPorts)
        let (cwds, startTimes, containers) = await (cwdResult, startTimeResult, containerResult)

        return await resolveProjects(parsed: parsed, cwds: cwds,
                                     startTimes: startTimes, containers: containers)
    }

    // MARK: - Container Resolution

    struct ContainerInfo: Sendable {
        let project: String   // compose project, or container name if standalone
        let service: String   // compose service name (empty for standalone containers)
    }

    // Common install locations for the `docker`-compatible CLI. The same binary
    // works for Docker Desktop and OrbStack (which the active context points at).
    private static func dockerExecutable() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path()
        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "\(home)/.orbstack/bin/docker",
            "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Maps published host ports to their container's compose project/service by
    /// querying the container CLI. Best-effort: returns empty if no runtime ports
    /// were seen, the CLI is missing, or the daemon is unreachable.
    private func resolveContainers(enabled: Bool) async -> [UInt16: ContainerInfo] {
        guard enabled, let docker = Self.dockerExecutable() else { return [:] }
        let format = #"{{.Names}}\t{{.Ports}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}"#
        guard let output = try? await runShell(
            docker, args: ["ps", "--no-trunc", "--format", format],
            timeout: 5
        ) else {
            if Log.isVerbose { log.debug("docker ps lookup failed or timed out") }
            return [:]
        }
        return Self.parseContainerOutput(output)
    }

    /// Parses the tab-separated `docker ps` output into a host-port → container map.
    static func parseContainerOutput(_ output: String) -> [UInt16: ContainerInfo] {
        var result: [UInt16: ContainerInfo] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 2 else { continue }
            let name = cols[0].trimmingCharacters(in: .whitespaces)
            let portsField = cols[1]
            let projectLabel = cols.count > 2 ? cols[2].trimmingCharacters(in: .whitespaces) : ""
            let serviceLabel = cols.count > 3 ? cols[3].trimmingCharacters(in: .whitespaces) : ""
            let info = ContainerInfo(
                project: projectLabel.isEmpty ? name : projectLabel,
                service: serviceLabel
            )
            for port in parseContainerHostPorts(portsField) {
                result[port] = info
            }
        }
        return result
    }

    /// Extracts published host ports from a docker `Ports` field, e.g.
    /// "0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp" → [3000]. Unpublished
    /// ports like "8000/tcp" (no "->") are ignored.
    static func parseContainerHostPorts(_ portsField: String) -> [UInt16] {
        var seen = Set<UInt16>()
        var ports: [UInt16] = []
        for match in portsField.matches(of: #/:(\d{1,5})->/#) {
            guard let port = UInt16(match.1), seen.insert(port).inserted else { continue }
            ports.append(port)
        }
        return ports
    }

    // MARK: - lsof Parsing (static for testability)

    struct ParsedPort: Sendable {
        let port: UInt16
        let pid: Int32
        let processName: String
    }

    static func parseLsofOutput(_ output: String) -> [ParsedPort] {
        var seen = Set<UInt16>()
        var results: [ParsedPort] = []

        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9 else { continue }
            let processName = String(cols[0])
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
            results.append(ParsedPort(port: port, pid: pid, processName: processName))
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
        startTimes: [Int32: Date],
        containers: [UInt16: ContainerInfo]
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
            let cwd = cwds[info.pid]
            let gitRoot = cwd.flatMap { gitRoots[$0] }
            let rootPath = gitRoot?.path()
            let isContainerRuntime = Self.containerRuntimeName(for: info.processName) != nil
            let container = isContainerRuntime ? containers[info.port] : nil

            if gitRoot == nil, !isContainerRuntime,
               !Self.shouldKeepFallbackProcess(processName: info.processName, cwd: cwd) {
                if Log.isVerbose {
                    Log.scanner.debug("Skipping non-project process '\(info.processName)' on port \(info.port)")
                }
                return nil
            }

            let projectName: String
            let branch: String
            if let container {
                // Container runtime port matched to a running container: prefer the
                // compose project/service over the generic runtime label.
                projectName = container.project
                branch = container.service
            } else {
                projectName = Self.displayName(
                    processName: info.processName,
                    cwd: cwd,
                    gitRoot: gitRoot
                )
                branch = rootPath.flatMap { branches[$0] } ?? ""
            }

            if gitRoot == nil, container == nil, Log.isVerbose {
                Log.scanner.debug("Using fallback label '\(projectName)' for PID \(info.pid) on port \(info.port)")
            }

            return ActivePort(
                port: info.port,
                pid: info.pid,
                projectName: projectName,
                branch: branch,
                startTime: startTimes[info.pid],
                isContainer: isContainerRuntime
            )
        }
    }

    static func displayName(processName: String, cwd: String?, gitRoot: URL?) -> String {
        if let gitRoot {
            return gitRoot.lastPathComponent
        }

        if let runtime = containerRuntimeName(for: processName) {
            return runtime
        }

        if let cwd {
            let basename = URL(filePath: cwd).lastPathComponent
            if isMeaningfulDirectoryName(basename) {
                return basename
            }
        }

        return processName
    }

    static func shouldKeepFallbackProcess(processName: String, cwd: String?) -> Bool {
        let normalized = processName.lowercased()
        if allowedFallbackProcessNames.contains(normalized) {
            return true
        }

        if containerRuntimeName(for: normalized) != nil {
            return true
        }

        if normalized.hasPrefix("python"),
           normalized.dropFirst("python".count).allSatisfy({ $0.isNumber || $0 == "." }) {
            return true
        }

        if let cwd {
            let basename = URL(filePath: cwd).lastPathComponent
            if isMeaningfulDirectoryName(basename),
               allowedFallbackProcessNames.contains(basename.lowercased()) {
                return true
            }
        }

        return false
    }

    // Returns the display label for a container runtime if `name` is one, else nil.
    // lsof truncates COMMAND to 9 chars by default, so
    // "com.docker.backend" → "com.docke", "docker-proxy" → "docker-pr".
    // OrbStack ("OrbStack", 8 chars) is not truncated.
    static func containerRuntimeName(for name: String) -> String? {
        let lower = name.lowercased()
        if lower.contains("orbstack") {
            return "OrbStack"
        }
        if lower.contains("docker") || lower.hasPrefix("com.dock") || lower.hasPrefix("vpnkit") {
            return "Docker"
        }
        return nil
    }

    static func isMeaningfulDirectoryName(_ name: String) -> Bool {
        guard !name.isEmpty, name != "/", !name.hasPrefix(".") else { return false }
        let ignored = Set(["_build", "build", "tmp", "dist", "deps"])
        return !ignored.contains(name)
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
        let command = ([executable] + args).joined(separator: " ")
        let token = UUID()

        // Run the blocking process on a background thread via a detached task,
        // then race it against a timeout task using withTaskGroup.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Self.runProcess(
                    executable: executable,
                    args: args,
                    environment: environment,
                    token: token
                )
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                Self.processTracker.terminate(token: token)
                Log.shell.warning("Process timed out: \(command)")
                throw ScanError.lsofTimeout
            }

            // Return the first result (success or error); cancel the other task.
            defer {
                Self.processTracker.terminate(token: token)
                group.cancelAll()
            }
            let result = try await group.next()!
            return result
        }
    }

    private static func runProcess(
        executable: String,
        args: [String],
        environment: [String: String]?,
        token: UUID
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
                processTracker.store(process, for: token)
                try process.run()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                processTracker.clear(token: token)

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
                processTracker.clear(token: token)
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

final class ProcessTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]

    func store(_ process: Process, for token: UUID) {
        lock.lock()
        processes[token] = process
        lock.unlock()
    }

    func clear(token: UUID) {
        lock.lock()
        processes[token] = nil
        lock.unlock()
    }

    func terminate(token: UUID) {
        lock.lock()
        let process = processes[token]
        lock.unlock()

        guard let process, process.isRunning else { return }
        process.terminate()
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
