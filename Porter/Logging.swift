import Foundation
import os

// MARK: - Logging

enum Log {
    static let scanner = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Porter", category: "scanner")
    static let store = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Porter", category: "store")
    static let ui = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Porter", category: "ui")
    static let lifecycle = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Porter", category: "lifecycle")
    static let shell = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Porter", category: "shell")

    /// Enable verbose logging. Toggle via UserDefaults key "debugLogging".
    static var isVerbose: Bool {
        UserDefaults.standard.bool(forKey: "debugLogging")
    }
}
