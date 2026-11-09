import AppKit
import Foundation

/// The IME's own health: noticing a run that ended abnormally, and giving
/// memory back when macOS asks.
///
/// Goose turns a stack overflow on the main thread into a silent `_exit`,
/// with no crash report. So when the core starts a marker file is written,
/// and removed when it stops cleanly: the launcher stops it on quitting, on
/// SIGTERM (what logout and kill send), and before loading a newer core. If
/// the marker is still there at the next start, the last run ended some
/// other way: it is counted, logged (with no user data), and shown in the
/// input menu.
@MainActor
enum Health {
    private static let abnormalKey = "abnormalExits"
    private static var marker: URL { Learning.directory.appendingPathComponent("running") }
    private static var sources: [any DispatchSourceProtocol] = []

    /// Runs that ended without a clean stop, since the count was last cleared.
    static var abnormalExits: Int {
        get { UserDefaults.standard.integer(forKey: abnormalKey) }
        set { UserDefaults.standard.set(newValue, forKey: abnormalKey) }
    }

    static func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Learning.directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: marker.path) {
            abnormalExits += 1
            log.error("the previous run ended without a clean stop (\(abnormalExits, privacy: .public) so far)")
        }
        try? Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: marker, options: .atomic)

        // Memory pressure: the engine returns the pages it no longer uses.
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler {
            MainActor.assumeIsolated { Engine.shared.trim() }
        }
        pressure.resume()
        sources = [pressure]
    }

    /// The core stops cleanly.
    static func stop() {
        for source in sources { source.cancel() }
        sources = []
        try? FileManager.default.removeItem(at: marker)
    }

    /// A line for the input menu, if any run ended abnormally.
    static var menuLine: String? {
        let n = abnormalExits
        return n > 0 ? "OctoDot ended unexpectedly \(n) time\(n == 1 ? "" : "s"); please report it" : nil
    }
}
