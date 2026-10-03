import Foundation

// MARK: - Port Model

struct ActivePort: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let port: UInt16
    let pid: Int32
    let projectName: String
    /// A stable, non-display identifier used to keep ports from the same project together.
    /// Git-backed entries use the repository root; fallback entries use their working directory.
    let projectIdentifier: String
    let branch: String
    let startTime: Date?
    /// The process's current physical memory footprint in bytes, when available.
    let memoryBytes: UInt64?

    var url: URL {
        URL(string: "http://localhost:\(port)")!
    }

    init(
        port: UInt16,
        pid: Int32,
        projectName: String,
        projectIdentifier: String? = nil,
        branch: String,
        startTime: Date?,
        memoryBytes: UInt64? = nil
    ) {
        self.id = "\(port)-\(pid)"
        self.port = port
        self.pid = pid
        self.projectName = projectName
        // Keep hand-created entries and older call sites deterministic as well.
        self.projectIdentifier = projectIdentifier ?? "name:\(projectName)"
        self.branch = branch
        self.startTime = startTime
        self.memoryBytes = memoryBytes
    }
}

func formatMemory(bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

// MARK: - Project Port Group

struct ProjectPortGroup: Identifiable, Equatable, Sendable {
    let id: String
    let projectName: String
    let branch: String
    let entries: [ActivePort]
}

extension Array where Element == ActivePort {
    /// Groups ports by their stable project identity, then sorts groups and entries for a stable menu.
    func groupedByProject() -> [ProjectPortGroup] {
        let groups = Dictionary(grouping: self, by: \.projectIdentifier)

        return groups.map { identifier, entries in
            let sortedEntries = entries.sorted {
                $0.port == $1.port ? $0.pid < $1.pid : $0.port < $1.port
            }
            let representative = sortedEntries[0]
            return ProjectPortGroup(
                id: identifier,
                projectName: representative.projectName,
                branch: representative.branch,
                entries: sortedEntries
            )
        }
        .sorted {
            let nameOrder = $0.projectName.localizedStandardCompare($1.projectName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.id < $1.id
        }
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
