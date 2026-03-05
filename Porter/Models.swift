import Foundation

// MARK: - Port Model

struct ActivePort: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let port: UInt16
    let pid: Int32
    let projectName: String
    let branch: String
    let startTime: Date?

    var url: URL {
        URL(string: "http://localhost:\(port)")!
    }

    init(port: UInt16, pid: Int32, projectName: String, branch: String, startTime: Date?) {
        self.id = "\(port)-\(pid)"
        self.port = port
        self.pid = pid
        self.projectName = projectName
        self.branch = branch
        self.startTime = startTime
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
