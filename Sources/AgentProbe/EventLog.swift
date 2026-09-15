import Foundation

/// Thread-safe logger: writes human-readable lines to stdout and, optionally,
/// a machine-readable JSONL record per line so probe sessions can be diffed later.
final class EventLog {
    static let shared = EventLog()

    private let lock = NSLock()
    private var handle: FileHandle?
    private let start = Date()
    private(set) var logPath: String?

    private init() {}

    func openFile(at path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        logPath = handle == nil ? nil : url.path
    }

    func log(_ tag: String, _ message: String, _ json: [String: Any] = [:]) {
        let dt = Date().timeIntervalSince(start)
        let stamp = String(format: "%8.3f", dt)
        let paddedTag = tag.padding(toLength: 12, withPad: " ", startingAt: 0)

        lock.lock()
        print("[\(stamp)] \(paddedTag) \(message)")
        fflush(stdout)

        if let handle {
            var record: [String: Any] = ["t": dt, "tag": tag, "msg": message]
            for (k, v) in json { record[k] = v }
            if let data = try? JSONSerialization.data(withJSONObject: record) {
                handle.write(data)
                handle.write(Data([0x0A]))
            }
        }
        lock.unlock()
    }
}

/// Tracks which physical inputs are currently held, so a chord (e.g. B + Right)
/// is visible directly in the log instead of having to be reconstructed by hand.
final class HeldState {
    private let lock = NSLock()
    private var held = Set<String>()

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return held.count
    }

    /// Returns the rendered held set after applying the change.
    func set(_ name: String, pressed: Bool) -> String {
        lock.lock(); defer { lock.unlock() }
        if pressed { held.insert(name) } else { held.remove(name) }
        return render()
    }

    /// Clears all state (disconnect, sleep, focus loss) and returns the previous set.
    func clear() -> String {
        lock.lock(); defer { lock.unlock() }
        let previous = render()
        held.removeAll()
        return previous
    }

    private func render() -> String {
        held.isEmpty ? "-" : held.sorted().joined(separator: " + ")
    }
}
