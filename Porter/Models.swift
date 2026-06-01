import Foundation

// MARK: - Port Model

enum PortEndpointSource: String, Equatable, Hashable, Sendable {
    case local
    case ssh
}

struct ActivePort: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let port: UInt16
    let pid: Int32?
    let projectName: String
    let branch: String
    let startTime: Date?
    let source: PortEndpointSource
    let hostID: String
    let hostDisplayName: String
    let hostAddress: String?
    let bindAddress: String?
    let scannedAt: Date?

    var isLocal: Bool { source == .local }
    var isRemote: Bool { !isLocal }

    var isLoopbackBound: Bool {
        guard isRemote, let bindAddress else { return false }
        return bindAddress == "localhost"
            || bindAddress == "127.0.0.1"
            || bindAddress == "::1"
            || bindAddress.hasPrefix("127.")
    }

    var url: URL {
        if isLocal {
            return URL(string: "http://localhost:\(port)")!
        }
        let host = hostAddress ?? hostDisplayName
        return URL(string: "http://\(host):\(port)")!
    }

    var tunnelCommand: String? {
        guard source == .ssh else { return nil }
        return "ssh -N -L \(port):127.0.0.1:\(port) -- \(Self.shellQuoted(hostID))"
    }

    init(
        port: UInt16,
        pid: Int32?,
        projectName: String,
        branch: String,
        startTime: Date?,
        source: PortEndpointSource = .local,
        hostID: String = "local",
        hostDisplayName: String = "This Mac",
        hostAddress: String? = nil,
        bindAddress: String? = nil,
        scannedAt: Date? = nil
    ) {
        self.id = "\(source.rawValue)-\(hostID)-\(port)-\(pid.map(String.init) ?? "unknown")"
        self.port = port
        self.pid = pid
        self.projectName = projectName
        self.branch = branch
        self.startTime = startTime
        self.source = source
        self.hostID = hostID
        self.hostDisplayName = hostDisplayName
        self.hostAddress = hostAddress
        self.bindAddress = bindAddress
        self.scannedAt = scannedAt
    }

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

// MARK: - Remote Hosts

struct SSHHost: Identifiable, Equatable, Hashable, Sendable {
    let alias: String
    let hostName: String?
    let user: String?
    let port: UInt16?

    var id: String { alias }

    var displayName: String {
        if let hostName, hostName != alias {
            return "\(alias) (\(hostName))"
        }
        return alias
    }

    var addressForURL: String {
        hostName ?? alias
    }
}

// MARK: - Scan Result

enum ScanResult: Sendable {
    case success([ActivePort], ScanDiagnostics)
    case failure(ScanError, [ActivePort])
}

struct ScanDiagnostics: Sendable {
    let duration: TimeInterval
    let portsFound: Int
    let dataSource: String
    let timestamp: Date

    var summary: String {
        let ms = (duration * 1000).formatted(.number.precision(.fractionLength(1)))
        let time = timestamp.formatted(date: .omitted, time: .standard)
        return "Scan: \(ms)ms | \(portsFound) ports | source: \(dataSource) | \(time)"
    }
}

enum ScanError: Error, Sendable, LocalizedError {
    case lsofFailed(String)
    case lsofTimeout

    var errorDescription: String? {
        switch self {
        case .lsofFailed(let msg): return "Port scan failed: \(msg)"
        case .lsofTimeout: return "Port scan timed out"
        }
    }
}

// MARK: - Refresh Interval

enum RefreshInterval: Double, CaseIterable, Sendable {
    case fast = 2
    case normal = 5
    case relaxed = 10
    case slow = 30

    static let defaultInterval: RefreshInterval = .normal
}
