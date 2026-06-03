import Darwin
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
        let processName: String
        let bindAddress: String?
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
            let bindAddress = normalizedBindAddress(String(nameCol[..<colonIdx]))

            let stateCol = String(cols[cols.count - 1])
            guard stateCol == "(LISTEN)" else { continue }

            guard port >= 1024, port < 49152 else {
                if Log.isVerbose {
                    Log.scanner.debug("Skipping out-of-range port \(port)")
                }
                continue
            }

            guard seen.insert(port).inserted else { continue }
            results.append(ParsedPort(
                port: port, pid: pid, processName: processName,
                bindAddress: bindAddress
            ))
        }

        return results.sorted { $0.port < $1.port }
    }

    static func normalizedBindAddress(_ raw: String) -> String? {
        var value = raw
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value.removeFirst()
            value.removeLast()
        }

        switch value {
        case "*", "::", "0.0.0.0":
            return nil
        case "localhost":
            return "localhost"
        default:
            return value.isEmpty ? nil : value
        }
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
            let cwd = cwds[info.pid]
            let gitRoot = cwd.flatMap { gitRoots[$0] }
            let rootPath = gitRoot?.path()

            if gitRoot == nil, !Self.shouldKeepFallbackProcess(processName: info.processName, cwd: cwd) {
                if Log.isVerbose {
                    Log.scanner.debug("Skipping non-project process '\(info.processName)' on port \(info.port)")
                }
                return nil
            }

            let projectName = Self.displayName(
                processName: info.processName,
                cwd: cwd,
                gitRoot: gitRoot
            )

            if gitRoot == nil, Log.isVerbose {
                Log.scanner.debug("Using fallback label '\(projectName)' for PID \(info.pid) on port \(info.port)")
            }

            return ActivePort(
                port: info.port,
                pid: info.pid,
                projectName: projectName,
                branch: rootPath.flatMap { branches[$0] } ?? "",
                startTime: startTimes[info.pid],
                bindAddress: info.bindAddress
            )
        }
    }

    static func displayName(processName: String, cwd: String?, gitRoot: URL?) -> String {
        if let gitRoot {
            return gitRoot.lastPathComponent
        }

        if isDockerProcess(processName) {
            return "Docker"
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

        if isDockerProcess(normalized) {
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

    // lsof truncates COMMAND to 9 chars by default, so
    // "com.docker.backend" → "com.docke", "docker-proxy" → "docker-pr"
    static func isDockerProcess(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("docker") || lower.hasPrefix("com.dock") || lower.hasPrefix("vpnkit")
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

// MARK: - SSH Host Discovery

struct SSHHostDiscovery: Sendable {
    private static let maxIncludeDepth = 4

    static func discoverHosts() -> [SSHHost] {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".ssh/config")
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return []
        }
        var visited = Set<String>()
        let expanded = expandIncludes(
            in: text,
            relativeTo: configURL.deletingLastPathComponent(),
            visited: &visited,
            depth: 0
        )
        return parseConfig(expanded)
    }

    static func parseConfig(
        _ text: String,
        includeResolver: ((String) -> String?)? = nil
    ) -> [SSHHost] {
        let expandedText: String
        if let includeResolver {
            expandedText = expandIncludes(in: text, includeResolver: includeResolver)
        } else {
            expandedText = text
        }

        struct Block {
            var aliases: [String] = []
            var hostName: String?
            var user: String?
            var port: UInt16?
        }

        var blocks: [Block] = []
        var current: Block?

        func flush() {
            guard let block = current, !block.aliases.isEmpty else { return }
            blocks.append(block)
        }

        for rawLine in expandedText.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard parts.count == 2 else { continue }

            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            guard key != "include" else { continue }

            if key == "host" {
                flush()
                let aliases = value
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                    .filter(Self.isConcreteAlias)
                current = Block(aliases: aliases)
                continue
            }

            guard current != nil else { continue }

            switch key {
            case "hostname":
                current?.hostName = value
            case "user":
                current?.user = value
            case "port":
                current?.port = UInt16(value)
            default:
                break
            }
        }
        flush()

        var seen = Set<String>()
        var hosts: [SSHHost] = []
        for block in blocks {
            for alias in block.aliases where seen.insert(alias).inserted {
                let normalizedHost = normalizedHostName(block.hostName, alias: alias)
                hosts.append(SSHHost(
                    alias: alias,
                    hostName: normalizedHost,
                    user: block.user,
                    port: block.port
                ))
            }
        }

        return hosts.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    private static func expandIncludes(
        in text: String,
        includeResolver: (String) -> String?
    ) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine -> String in
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(
                    maxSplits: 1,
                    omittingEmptySubsequences: true,
                    whereSeparator: \.isWhitespace
                )
                guard parts.count == 2, parts[0].lowercased() == "include" else {
                    return String(rawLine)
                }

                return parts[1]
                    .split(whereSeparator: \.isWhitespace)
                    .compactMap { includeResolver(strippedQuotes(String($0))) }
                    .joined(separator: "\n")
            }
            .joined(separator: "\n")
    }

    private static func expandIncludes(
        in text: String,
        relativeTo baseURL: URL,
        visited: inout Set<String>,
        depth: Int
    ) -> String {
        guard depth < maxIncludeDepth else { return text }
        return expandIncludes(in: text) { pattern in
            resolveIncludePattern(pattern, relativeTo: baseURL)
                .compactMap { url -> String? in
                    let path = url.standardizedFileURL.path()
                    guard visited.insert(path).inserted,
                          let included = try? String(contentsOf: url, encoding: .utf8)
                    else { return nil }
                    return expandIncludes(
                        in: included,
                        relativeTo: url.deletingLastPathComponent(),
                        visited: &visited,
                        depth: depth + 1
                    )
                }
                .joined(separator: "\n")
        }
    }

    private static func resolveIncludePattern(_ pattern: String, relativeTo baseURL: URL) -> [URL] {
        let expandedPattern = expandedPath(pattern, relativeTo: baseURL)
        guard containsGlob(expandedPattern) else {
            return [URL(filePath: expandedPattern)]
        }

        let url = URL(filePath: expandedPattern)
        let directory = url.deletingLastPathComponent()
        let filePattern = url.lastPathComponent
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return children
            .filter { fnmatch(filePattern, $0.lastPathComponent, 0) == 0 }
            .sorted { $0.path().localizedStandardCompare($1.path()) == .orderedAscending }
    }

    private static func expandedPath(_ pattern: String, relativeTo baseURL: URL) -> String {
        if pattern == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path()
        }
        if pattern.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appending(path: String(pattern.dropFirst(2)))
                .path()
        }
        if pattern.hasPrefix("/") {
            return pattern
        }
        return baseURL.appending(path: pattern).path()
    }

    private static func containsGlob(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?") || pattern.contains("[")
    }

    private static func strippedQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func isConcreteAlias(_ alias: String) -> Bool {
        guard !alias.hasPrefix("!") else { return false }
        return !alias.contains("*") && !alias.contains("?")
    }

    private static func normalizedHostName(_ hostName: String?, alias: String) -> String? {
        guard let hostName, !hostName.isEmpty, hostName != "%h", hostName != alias else {
            return nil
        }
        return hostName.replacingOccurrences(of: "%h", with: alias)
    }
}

// MARK: - SSH Port Scanner

struct SSHHostScan: Sendable {
    let host: SSHHost
    let ports: [ActivePort]
    let errorDescription: String?
    let scannedAt: Date
}

protocol SSHPortScanning: Sendable {
    func scan(hosts: [SSHHost]) async -> [SSHHostScan]
}

struct LiveSSHPortScanner: SSHPortScanning {
    private let log = Log.scanner
    private static let processTracker = ProcessTracker()

    func scan(hosts: [SSHHost]) async -> [SSHHostScan] {
        guard !hosts.isEmpty else { return [] }

        return await withTaskGroup(of: SSHHostScan.self) { group in
            for host in hosts {
                group.addTask {
                    await scan(host: host)
                }
            }

            var scans: [SSHHostScan] = []
            for await scan in group {
                scans.append(scan)
            }
            return scans.sorted { $0.host.alias.localizedStandardCompare($1.host.alias) == .orderedAscending }
        }
    }

    private func scan(host: SSHHost) async -> SSHHostScan {
        let scannedAt = Date()
        let remoteCommand = """
        if command -v lsof >/dev/null 2>&1; then
          lsof_output=$(lsof -iTCP -sTCP:LISTEN -n -P 2>/dev/null)
          if [ $? -eq 0 ] && [ -n "$lsof_output" ]; then
            echo __PORT_MENU_LSOF__
            printf '%s\\n' "$lsof_output"
            exit 0
          fi
        fi
        if command -v ss >/dev/null 2>&1; then
          ss_output=$(ss -H -ltnp 2>/dev/null)
          if [ $? -eq 0 ] && [ -n "$ss_output" ]; then
            echo __PORT_MENU_SS__
            printf '%s\\n' "$ss_output"
            exit 0
          fi
        fi
        echo __PORT_MENU_EMPTY__
        """

        do {
            let output = try await runShell(
                "/usr/bin/ssh",
                args: [
                    "-o", "BatchMode=yes",
                    "-o", "NumberOfPasswordPrompts=0",
                    "-o", "ConnectTimeout=3",
                    "-o", "StrictHostKeyChecking=yes",
                    "--",
                    host.alias,
                    remoteCommand
                ],
                timeout: 7
            )
            let ports = Self.parseRemoteOutput(output, host: host, scannedAt: scannedAt)
            if Log.isVerbose {
                log.debug("SSH scan for \(host.alias) found \(ports.count) ports")
            }
            return SSHHostScan(host: host, ports: ports, errorDescription: nil, scannedAt: scannedAt)
        } catch {
            if Log.isVerbose {
                log.debug("SSH scan for \(host.alias) failed: \(error.localizedDescription)")
            }
            return SSHHostScan(
                host: host, ports: [],
                errorDescription: Self.userFacingError(error.localizedDescription),
                scannedAt: scannedAt
            )
        }
    }

    static func parseRemoteOutput(_ output: String, host: SSHHost, scannedAt: Date) -> [ActivePort] {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let markerIndex = lines.firstIndex(where: { $0.hasPrefix("__PORT_MENU_") }) else {
            return []
        }
        let marker = lines[markerIndex]
        lines.removeFirst(markerIndex + 1)
        let body = lines.joined(separator: "\n")

        switch marker {
        case "__PORT_MENU_LSOF__":
            return LivePortScanner.parseLsofOutput(body).map {
                ActivePort(
                    port: $0.port,
                    pid: $0.pid,
                    projectName: $0.processName,
                    branch: "",
                    startTime: nil,
                    source: .ssh,
                    hostID: host.alias,
                    hostDisplayName: host.alias,
                    hostAddress: host.addressForURL,
                    bindAddress: $0.bindAddress,
                    scannedAt: scannedAt
                )
            }
        case "__PORT_MENU_SS__":
            return parseSSOutput(body, host: host, scannedAt: scannedAt)
        default:
            return []
        }
    }

    static func parseSSOutput(_ output: String, host: SSHHost, scannedAt: Date) -> [ActivePort] {
        var seen = Set<UInt16>()
        var ports: [ActivePort] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 4 else { continue }
            let localAddress = cols[3]
            guard let (bindAddress, port) = parseAddressPort(localAddress),
                  port >= 1024, port < 49152,
                  seen.insert(port).inserted
            else { continue }

            let pid = parseSSPID(from: line)
            let processName = parseSSProcessName(from: line) ?? "remote"
            ports.append(ActivePort(
                port: port,
                pid: pid,
                projectName: processName,
                branch: "",
                startTime: nil,
                source: .ssh,
                hostID: host.alias,
                hostDisplayName: host.alias,
                hostAddress: host.addressForURL,
                bindAddress: bindAddress,
                scannedAt: scannedAt
            ))
        }

        return ports.sorted { $0.port < $1.port }
    }

    private static func parseAddressPort(_ raw: String) -> (String?, UInt16)? {
        let address: String
        let portText: Substring

        if raw.hasPrefix("["),
           let close = raw.firstIndex(of: "]"),
           raw.distance(from: close, to: raw.endIndex) > 1 {
            let afterClose = raw.index(after: close)
            guard raw[afterClose] == ":" else { return nil }
            address = String(raw[raw.index(after: raw.startIndex)..<close])
            portText = raw[raw.index(after: afterClose)...]
        } else {
            guard let colon = raw.lastIndex(of: ":") else { return nil }
            address = String(raw[..<colon])
            portText = raw[raw.index(after: colon)...]
        }

        guard let port = UInt16(portText) else { return nil }
        return (LivePortScanner.normalizedBindAddress(address), port)
    }

    private static func parseSSPID(from line: Substring) -> Int32? {
        guard let range = line.range(of: "pid=") else { return nil }
        let suffix = line[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int32(digits)
    }

    private static func parseSSProcessName(from line: Substring) -> String? {
        guard let firstQuote = line.firstIndex(of: "\"") else { return nil }
        let afterFirst = line[line.index(after: firstQuote)...]
        guard let secondQuote = afterFirst.firstIndex(of: "\"") else { return nil }
        let name = String(afterFirst[..<secondQuote])
        return name.isEmpty ? nil : name
    }

    private static func userFacingError(_ message: String) -> String {
        if message.contains("Permission denied") { return "Permission denied" }
        if message.contains("Host key verification failed") { return "Host key verification failed" }
        if message.contains("Operation timed out") || message.contains("timed out") { return "Connection timed out" }
        if message.contains("Could not resolve hostname") { return "Unknown host" }
        return "Could not connect"
    }

    private func runShell(
        _ executable: String,
        args: [String],
        timeout: TimeInterval
    ) async throws -> String {
        let token = UUID()

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Self.runProcess(
                    executable: executable,
                    args: args,
                    token: token
                )
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                Self.processTracker.terminate(token: token)
                throw ScanError.lsofTimeout
            }

            defer {
                Self.processTracker.terminate(token: token)
                group.cancelAll()
            }
            return try await group.next()!
        }
    }

    private static func runProcess(
        executable: String,
        args: [String],
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

            do {
                processTracker.store(process, for: token)
                try process.run()
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                processTracker.clear(token: token)

                if process.terminationStatus != 0 {
                    let errMsg = String(data: errorData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: ScanError.lsofFailed(errMsg))
                    return
                }

                continuation.resume(returning: String(data: outputData, encoding: .utf8) ?? "")
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
