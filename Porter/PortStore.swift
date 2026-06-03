import SwiftUI
import os

// MARK: - PortStore

@MainActor
@Observable
final class PortStore {
    static let shared = PortStore()

    var entries: [ActivePort] = []
    var sshHosts: [SSHHost] = []
    var sshHostErrors: [String: String] = [:]
    var lastError: ScanError?
    var isScanning: Bool = false
    var lastDiagnostics: ScanDiagnostics?

    @ObservationIgnored
    @AppStorage("refreshInterval") private var storedInterval: Double = RefreshInterval.defaultInterval.rawValue
    @ObservationIgnored
    @AppStorage("enabledSSHHosts") private var enabledSSHHostsStorage: String = ""

    var refreshInterval: RefreshInterval {
        get { RefreshInterval(rawValue: storedInterval) ?? .defaultInterval }
        set {
            storedInterval = newValue.rawValue
            restartTimer()
            Log.store.info("Refresh interval changed to \(newValue.rawValue)s")
        }
    }

    @ObservationIgnored private let scanner: PortScanning
    @ObservationIgnored private let sshScanner: SSHPortScanning
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var recentlyKilled: [UInt16: Date] = [:]
    @ObservationIgnored private var remoteEntriesByHost: [String: [ActivePort]] = [:]
    @ObservationIgnored private var lastRemoteScanAt: [String: Date] = [:]
    @ObservationIgnored private var sleepObserver: Any?
    @ObservationIgnored private var wakeObserver: Any?

    private static let remoteRefreshInterval: TimeInterval = 60

    init(
        scanner: PortScanning = LivePortScanner(),
        sshScanner: SSHPortScanning = LiveSSHPortScanner()
    ) {
        self.scanner = scanner
        self.sshScanner = sshScanner
        self.sshHosts = SSHHostDiscovery.discoverHosts()
        setupLifecycleObservers()
        Log.lifecycle.info("PortStore initialized")
    }

    var enabledSSHHostIDs: Set<String> {
        Set(enabledSSHHostsStorage
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init))
    }

    var enabledSSHHosts: [SSHHost] {
        let enabled = enabledSSHHostIDs
        return sshHosts.filter { enabled.contains($0.id) }
    }

    var hasRemoteDiscovery: Bool {
        !sshHosts.isEmpty
    }

    func isSSHHostEnabled(_ host: SSHHost) -> Bool {
        enabledSSHHostIDs.contains(host.id)
    }

    func setSSHHost(_ host: SSHHost, enabled: Bool) {
        var enabledIDs = enabledSSHHostIDs
        if enabled {
            enabledIDs.insert(host.id)
            lastRemoteScanAt[host.id] = nil
        } else {
            enabledIDs.remove(host.id)
            remoteEntriesByHost[host.id] = nil
            sshHostErrors[host.id] = nil
            lastRemoteScanAt[host.id] = nil
        }
        enabledSSHHostsStorage = enabledIDs.sorted().joined(separator: "\n")
        if !enabled {
            removeEntries(forHost: host.id)
        }
        if enabled {
            refreshSSHHost(host.id)
        }
    }

    func reloadSSHHosts() {
        sshHosts = SSHHostDiscovery.discoverHosts()
        let knownIDs = Set(sshHosts.map(\.id))
        let pruned = enabledSSHHostIDs.intersection(knownIDs)
        enabledSSHHostsStorage = pruned.sorted().joined(separator: "\n")
        remoteEntriesByHost = remoteEntriesByHost.filter { knownIDs.contains($0.key) }
        sshHostErrors = sshHostErrors.filter { knownIDs.contains($0.key) }
        lastRemoteScanAt = lastRemoteScanAt.filter { knownIDs.contains($0.key) }
        refresh()
    }

    func refreshSSHHost(_ hostID: String) {
        guard let host = sshHosts.first(where: { $0.id == hostID }),
              enabledSSHHostIDs.contains(hostID) else { return }

        Task { [sshScanner] in
            isScanning = true
            defer { isScanning = false }

            let scans = await sshScanner.scan(hosts: [host])
            guard !Task.isCancelled else { return }
            guard enabledSSHHostIDs.contains(hostID) else { return }

            applyRemoteScans(scans, enabledHosts: enabledSSHHosts)
            let localEntries = entries.filter(\.isLocal)
            applyUpdate(localEntries + remoteEntriesByHost.values.flatMap { $0 })
        }
    }

    // MARK: - Polling

    func ensurePolling() {
        guard timer == nil else { return }
        Log.lifecycle.info("Starting polling (interval: \(self.refreshInterval.rawValue)s)")
        refresh()
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = refreshInterval.rawValue
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private func restartTimer() {
        guard timer != nil else { return }
        startTimer()
    }

    // MARK: - Refresh

    func refresh() {
        guard !isScanning else {
            if Log.isVerbose { Log.store.debug("Refresh skipped — already scanning") }
            return
        }

        scanTask?.cancel()
        scanTask = Task { [scanner, sshScanner] in
            isScanning = true
            defer { isScanning = false }

            let remoteHosts = enabledSSHHosts.filter { shouldRefreshRemoteHost($0) }
            async let localResult = scanner.scan()
            async let remoteResult = sshScanner.scan(hosts: remoteHosts)
            let result = await localResult
            let remoteScans = await remoteResult

            guard !Task.isCancelled else { return }

            applyRemoteScans(remoteScans, enabledHosts: enabledSSHHosts)

            switch result {
            case .success(let ports, let diag):
                lastError = nil
                lastDiagnostics = diag
                pruneRecentlyKilled()
                let filtered = ports.filter {
                    !($0.isLocal && recentlyKilled.keys.contains($0.port))
                }
                applyUpdate(filtered + remoteEntriesByHost.values.flatMap { $0 })

            case .failure(let error, _):
                lastError = error
                Log.store.error("Scan error: \(error.localizedDescription)")
                let localEntries = entries.filter(\.isLocal)
                applyUpdate(localEntries + remoteEntriesByHost.values.flatMap { $0 })
            }
        }
    }

    private func applyRemoteScans(_ scans: [SSHHostScan], enabledHosts: [SSHHost]) {
        let enabledIDs = Set(enabledHosts.map(\.id))
        remoteEntriesByHost = remoteEntriesByHost.filter { enabledIDs.contains($0.key) }
        sshHostErrors = sshHostErrors.filter { enabledIDs.contains($0.key) }

        for scan in scans {
            guard enabledIDs.contains(scan.host.id) else { continue }
            lastRemoteScanAt[scan.host.id] = scan.scannedAt
            if let error = scan.errorDescription {
                sshHostErrors[scan.host.id] = error
                continue
            }

            sshHostErrors[scan.host.id] = nil
            remoteEntriesByHost[scan.host.id] = scan.ports
        }
    }

    private func shouldRefreshRemoteHost(_ host: SSHHost) -> Bool {
        guard let lastScan = lastRemoteScanAt[host.id] else { return true }
        return Date().timeIntervalSince(lastScan) >= Self.remoteRefreshInterval
    }

    /// Smoothly updates entries, preserving existing items during transition.
    private func applyUpdate(_ newEntries: [ActivePort]) {
        let sortedEntries = newEntries.sorted { lhs, rhs in
            if lhs.isLocal != rhs.isLocal { return lhs.isLocal }
            if lhs.hostDisplayName != rhs.hostDisplayName {
                return lhs.hostDisplayName.localizedStandardCompare(rhs.hostDisplayName) == .orderedAscending
            }
            return lhs.port < rhs.port
        }

        let oldIDs = Set(entries.map(\.id))
        let newIDs = Set(sortedEntries.map(\.id))

        if oldIDs == newIDs && entries.count == sortedEntries.count {
            var needsUpdate = false
            for (old, new) in zip(entries, sortedEntries) {
                if old != new { needsUpdate = true; break }
            }
            if !needsUpdate { return }
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            entries = sortedEntries
        }
    }

    // MARK: - Actions

    func killProcess(pid: Int32, port: UInt16) {
        kill(pid, SIGTERM)
        recentlyKilled[port] = Date()
        Log.store.info("Killed PID \(pid) on port \(port)")
    }

    func killAllProcesses() {
        let currentEntries = entries.filter(\.isLocal)
        guard !currentEntries.isEmpty else { return }

        for entry in currentEntries {
            guard let pid = entry.pid else { continue }
            kill(pid, SIGTERM)
            recentlyKilled[entry.port] = Date()
        }

        Log.store.info("Killed \(currentEntries.count) processes")
        withAnimation(.easeInOut(duration: 0.25)) {
            entries.removeAll { $0.isLocal }
        }
    }

    func removeEntry(port: UInt16) {
        withAnimation(.easeInOut(duration: 0.3)) {
            entries.removeAll { $0.isLocal && $0.port == port }
        }
    }

    func removeEntry(id: String) {
        withAnimation(.easeInOut(duration: 0.3)) {
            entries.removeAll { $0.id == id }
        }
    }

    private func removeEntries(forHost hostID: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            entries.removeAll { $0.hostID == hostID }
        }
    }

    static func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: - Recently Killed Cleanup

    private func pruneRecentlyKilled() {
        let cutoff = Date().addingTimeInterval(-8)
        recentlyKilled = recentlyKilled.filter { $0.value > cutoff }
    }

    // MARK: - Sleep / Wake

    private func setupLifecycleObservers() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSleep()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWake()
            }
        }
    }

    private func handleSleep() {
        Log.lifecycle.info("System going to sleep — pausing polling")
        timer?.invalidate()
        timer = nil
        scanTask?.cancel()
    }

    private func handleWake() {
        Log.lifecycle.info("System woke — resuming polling")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.ensurePolling()
        }
    }

    // MARK: - Diagnostics

    var diagnosticsSnapshot: String {
        """
        === Port Menu Diagnostics ===
        Ports found: \(entries.count)
        Is scanning: \(isScanning)
        Last error: \(lastError?.localizedDescription ?? "none")
        Refresh interval: \(refreshInterval.rawValue)s
        Last scan: \(lastDiagnostics?.summary ?? "none")
        SSH hosts: \(sshHosts.count) discovered, \(enabledSSHHostIDs.count) enabled
        Recently killed: \(recentlyKilled.keys.sorted().map(String.init).joined(separator: ", "))
        Entries: \(entries.map { "\($0.hostDisplayName):\($0.port) (\($0.projectName))" }.joined(separator: ", "))
        ============================
        """
    }
}
