import AppKit
import Foundation
import PocketAgentCore

/// Rolling in-app log. The debug monitor is the only way to see why an action did or did not fire,
/// so it is deliberately always recording rather than only while its window is open (spec §17).
///
/// Every line is also mirrored to `debug.log` next to the config file: a menu bar app is invisible
/// when it misbehaves, and "it did nothing" is otherwise impossible to diagnose after the fact.
final class DebugLog {
    private(set) var entries: [String] = []
    private let limit = 500
    private let start = Date()
    private var handle: FileHandle?

    var onChange: (() -> Void)?

    static func defaultFileURL() -> URL {
        ConfigStore.defaultURL().deletingLastPathComponent().appendingPathComponent("debug.log")
    }

    init(fileURL: URL? = DebugLog.defaultFileURL()) {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Start fresh each launch — the interesting part is always the current session.
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    func append(_ tag: String, _ message: String) {
        let elapsed = Date().timeIntervalSince(start)
        let line = String(format: "[%8.3f] %-8@ %@", elapsed, tag as NSString, message)
        entries.append(line)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        if let handle, let data = (line + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        onChange?()
    }

    var text: String { entries.joined(separator: "\n") }
}

/// The input monitor window: raw → gesture → action → output, in one place.
final class DebugMonitorWindowController: NSWindowController {
    private let textView = NSTextView()
    private let log: DebugLog

    init(log: DebugLog) {
        self.log = log

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PocketAgentRemote — Input Monitor"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        textView.isEditable = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 6, height: 6)

        scrollView.documentView = textView
        window.contentView?.addSubview(scrollView)

        log.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func refresh() {
        guard isWindowLoaded else { return }
        let wasAtBottom = textView.enclosingScrollView.map { scrollView in
            let visible = scrollView.documentVisibleRect
            let height = scrollView.documentView?.frame.height ?? 0
            return visible.maxY >= height - 24
        } ?? true

        textView.string = log.text
        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func show() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
