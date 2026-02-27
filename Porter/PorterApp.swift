import SwiftUI
import Network

// ──────────────────────────────────────────────
// App entry point
// ──────────────────────────────────────────────

@main
struct PorterApp: App {
    var body: some Scene {
        MenuBarExtra("Porter", systemImage: "network") {
            PortListView()
        }
        .menuBarExtraStyle(.window)
    }
}

// ──────────────────────────────────────────────
// Model
// ──────────────────────────────────────────────

struct ActivePort: Identifiable, Equatable {
    let id: UInt16
    let pid: Int32
    let command: String
    let projectName: String
    let projectPath: String

    var label: String { "localhost:\(id)" }
    var url: URL { URL(string: "http://localhost:\(id)")! }
}

// ──────────────────────────────────────────────
// ViewModel – singleton, polls via lsof
// ──────────────────────────────────────────────

final class PortStore: ObservableObject {
    static let shared = PortStore()

    @Published var entries: [ActivePort] = []

    private var timer: Timer?

    private init() {}

    func ensurePolling() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ports = Self.discoverPorts()
            DispatchQueue.main.async {
                guard let self else { return }
                if self.entries != ports {
                    self.entries = ports
                }
            }
        }
    }

    // MARK: - Port discovery via lsof

    private static func discoverPorts() -> [ActivePort] {
        guard let output = shell("/usr/sbin/lsof -iTCP -sTCP:LISTEN -n -P 2>/dev/null") else { return [] }

        var seen = Set<UInt16>()
        var portInfos: [(port: UInt16, pid: Int32, command: String)] = []

        for line in output.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 10 else { continue }
            guard let pid = Int32(cols[1]) else { continue }

            let lastCol = String(cols[cols.count - 1])
            guard lastCol == "(LISTEN)" else { continue }
            let namePart = String(cols[cols.count - 2])
            guard let colonIdx = namePart.lastIndex(of: ":"),
                  let port = UInt16(namePart[namePart.index(after: colonIdx)...]) else { continue }

            guard port >= 1024 else { continue }
            guard seen.insert(port).inserted else { continue }

            portInfos.append((port, pid, String(cols[0])))
        }

        let cwds = resolveCWDs(pids: Set(portInfos.map(\.pid)))

        return portInfos
            .sorted { $0.port < $1.port }
            .compactMap { info -> ActivePort? in
                guard let cwd = cwds[info.pid],
                      let gitRoot = findGitRoot(from: cwd) else { return nil }
                return ActivePort(
                    id: info.port,
                    pid: info.pid,
                    command: info.command,
                    projectName: gitRoot.lastPathComponent,
                    projectPath: cwd
                )
            }
    }

    // MARK: - CWD + project name resolution

    private static func resolveCWDs(pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map(String.init).joined(separator: ",")
        guard let output = shell("/usr/sbin/lsof -a -p \(pidList) -d cwd -Fn 2>/dev/null") else { return [:] }

        var result = [Int32: String]()
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

    private static func findGitRoot(from path: String) -> URL? {
        var current = URL(fileURLWithPath: path)
        let fm = FileManager.default
        while current.path != "/" {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Shell helper (deadlock-safe)

    private static func shell(_ command: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }

        // Read BEFORE waitUntilExit — prevents pipe-buffer deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8)
    }
}

// ──────────────────────────────────────────────
// Views
// ──────────────────────────────────────────────

struct PortListView: View {
    @ObservedObject private var store = PortStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if store.entries.isEmpty {
                emptyState
            } else {
                ForEach(store.entries) { entry in
                    PortRow(entry: entry)
                }
            }

            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear { store.ensurePolling() }
    }

    private var header: some View {
        HStack {
            Text("Porter").font(.headline)
            Spacer()
            Button(action: store.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "network.slash")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No active ports")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack {
            Text("\(store.entries.count) active")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct PortRow: View {
    let entry: ActivePort

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.projectName)
                    .font(.system(.body, weight: .medium))

                HStack(spacing: 4) {
                    Text(":\(entry.id)")
                        .font(.system(.caption, design: .monospaced))
                    Text("·")
                    Text(entry.command)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button { NSWorkspace.shared.open(entry.url) } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open in browser")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help(entry.projectPath)
    }
}
