import AppKit
import ApplicationServices
import Foundation

/// Reads another application's own menu bar through Accessibility and hands back a session
/// that can press what it read (G4 通用菜单).
///
/// ## Why the menu is read rather than remembered
///
/// An app's menu bar is the only list of "things this app can do" that is guaranteed to be current:
/// it is what the app itself is about to draw, greyed-out states included. A static table per app
/// would go stale the moment the app updates, and would have to be written by hand for every app
/// the user happens to be in — which is the opposite of 通用.
///
/// ## Why nothing is typed
///
/// Entries carry their shortcut for *display only*. Synthesising `⌘1` would land wherever the
/// keyboard focus happens to be and depends on the app being frontmost; `AXPress` names the item
/// and works even while the app is in the background — verified by pressing Claude's
/// `View/Hide Sidebar` with WeChat in front: the title flipped to `Show Sidebar`, WeChat stayed.
///
/// ## Why a session (v2, after the security review)
///
/// A read and the press that follows it are one transaction. The session pins the **pid** and the
/// **focused window** the entries were read from, and holds the very `AXUIElement`s it read, so a
/// press cannot re-resolve a title onto a different window's object (review §3) or onto the first
/// of two identically named rows (review §4). Nothing is located by title at press time.
///
/// ## Measured cost (macOS 27, 2026-09-21)
///
/// Whole `openSession` calls, first read in a fresh process and then a repeat. Entry counts move
/// with what the app has open, so they are the shape of the menu rather than a constant:
///
/// | App | entries | first | repeat |
/// |---|---|---|---|
/// | WeChat | 85 | 51 ms | 6 ms |
/// | Codex (ChatGPT) | 110 | 69 ms | 9 ms |
/// | Claude | 142 | 56 ms | 11 ms |
/// | Finder | 206 | 101 ms | 23 ms |
/// | Chrome | 259 | 124 ms | 21 ms |
/// | Mail | 307 | 83 ms | 25 ms |
///
/// Two apps set the limits. **Chrome** is why there is a per-menu entry budget: uncapped it
/// returns 1015 entries and its first read cost 1.9 s, because every bookmark is a menu item.
/// **Mail** is why attributes are read in batches: one attribute per message, its menu bar came to
/// 1990 Accessibility reads and 298 ms — past `AppMenuReadBudget.maxDuration` on an idle machine,
/// and past `maxMessages` as well.
public final class AccessibilityMenuReader: AppMenuReading {
    /// Longest title path produced, counted from the top-level menu: `Window/Move & Resize/Left`
    /// is 3. Nothing useful has been seen deeper, and the cap keeps a pathological app bounded.
    public static let maxDepth = 4

    /// Entries harvested per **top-level** menu before the rest of it is skipped.
    ///
    /// Per menu rather than per app so that a huge menu cannot starve the ones after it — with a
    /// single total budget, Chrome's Bookmarks would swallow the whole allowance and Window, Tab
    /// and Help would never be read at all. 60 keeps every measured normal menu whole (the largest
    /// were Chrome History 40, WeChat Window 39, Finder File/View 34) and truncates only Chrome's
    /// 1163-item Bookmarks. Unlike the two limits below, running out of it is **not** an abort:
    /// it is a deliberate "this menu is a data dump, take the head of it".
    public static let maxEntriesPerMenu = 60

    /// Accessibility messages one `openSession` may send before it gives up.
    ///
    /// The wall clock alone is not a complete answer: a *fast* app that answers a pathological
    /// menu in microseconds could still be walked forever by a structure that recurses into
    /// itself. Mail, the widest menu bar measured, spends 774 messages, so 1500 is about twice the
    /// worst real case — headroom that only exists because attributes are read in batches.
    public static let maxMessages = 1500

    /// Why the per-message Accessibility timeout could not be installed, or nil when it was.
    ///
    /// Exposed rather than swallowed because it changes what the other limits mean: without it a
    /// single unanswered message blocks for the system default of 6 s, so `maxDuration` can only
    /// be honoured *between* messages, never inside one. The review's point (§2) was that the
    /// return value was being ignored; a caller that wants to warn can now read this.
    public private(set) var messagingTimeoutFailure: String?

    /// Installed once per process, on the system-wide element, because that is the only scope
    /// documented to reach elements this process derives later (a per-element timeout covers that
    /// element alone). Process-global is acceptable here: the only other Accessibility call in the
    /// app is `AXIsProcessTrusted`, which sends no message.
    private static let messagingTimeoutResult: AXError = AXUIElementSetMessagingTimeout(
        AXUIElementCreateSystemWide(), Float(AppMenuReadBudget.messagingTimeout)
    )

    public init() {
        let result = AccessibilityMenuReader.messagingTimeoutResult
        messagingTimeoutFailure = result == .success
            ? nil
            : "AXUIElementSetMessagingTimeout(\(AppMenuReadBudget.messagingTimeout) s) returned AXError \(result.rawValue); "
                + "a single Accessibility message can block for the system default instead"
    }

    // MARK: - AppMenuReading

    public func openSession(bundleID: String) -> AppMenuSession? {
        guard let app = AccessibilityMenuReader.runningApplication(for: bundleID) else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let probe = MenuProbe(
            maxDuration: AppMenuReadBudget.maxDuration,
            maxMessages: AccessibilityMenuReader.maxMessages
        )
        guard let menuBar = probe.element(application, kAXMenuBarAttribute as String) else { return nil }

        let walk = MenuWalk(probe: probe)
        // `dropFirst` is the Apple menu. It is the system's, not "该 App 自己菜单栏", it is identical
        // in every app, and it is where Sleep / Restart… / Shut Down… live — none of which anyone
        // wants a game controller to reach past a title blocklist.
        guard let topLevel = probe.children(menuBar) else { return nil }
        for menu in topLevel.dropFirst() {
            guard let node = probe.node(menu) else {
                // Unreadable because the budget ran out, or because this item answers nothing.
                if probe.aborted { return nil }
                continue
            }
            guard let title = node.title, !title.isEmpty else { continue }
            walk.collectTopLevel(node, title: title)
            guard !probe.aborted else { return nil }
        }

        // Read *after* the menu, so the window recorded is the one focused at the end of the read —
        // the closest thing to "what was focused when the user saw the menu".
        let focusedWindow: AXUIElement?
        switch probe.focusedWindow(of: application) {
        case .window(let window): focusedWindow = window
        case .none: focusedWindow = nil
        // No session at all rather than one that cannot police itself: a session whose recorded
        // context is a guess would have to either refuse every press or approve an unknown one.
        case .unreadable: return nil
        }
        // An aborted read must never return a partial menu.
        guard !probe.aborted else { return nil }

        return AccessibilityMenuSession(
            bundleID: bundleID,
            pid: app.processIdentifier,
            application: application,
            focusedWindow: focusedWindow,
            entries: walk.entries,
            elements: walk.elements
        )
    }

    // MARK: - Choosing the process

    /// The instance of `bundleID` a menu should be read from.
    ///
    /// Two filters, both from review §3. **Terminated instances are dropped**: `NSRunningApplication`
    /// keeps handing back an object after the process dies, and `AXUIElementCreateApplication` on a
    /// dead pid answers nothing, so `.first` alone could pick a corpse while a live instance sits
    /// behind it. **The active one wins**: with two copies of the same app running (two Chrome
    /// channels, a second Finder), the one the user is looking at is the one the menu is for.
    /// Neither is a guarantee — the pid is what the session pins, and that is what makes the press
    /// unambiguous — but it is the best guess available at open time.
    static func runningApplication(for bundleID: String) -> NSRunningApplication? {
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
        return running.first { $0.isActive } ?? running.first
    }
}

// MARK: - The walk

/// Collects leaf menu items, depth-first, in menu order.
///
/// A class rather than a set of `inout` parameters because the per-top-level-menu budget, the
/// entries and the element table all have to be shared across a recursion that runs inside a
/// closure — and because `MenuProbe` can stop the whole thing at any point.
private final class MenuWalk {
    private let probe: MenuProbe
    private(set) var entries: [AppMenuEntry] = []
    /// `elements[id]` is the element `entries[id]` was read from. Parallel arrays rather than a
    /// dictionary because `id` *is* the index, which is what makes an unknown id a bounds check.
    private(set) var elements: [AXUIElement] = []
    private var budget = 0

    init(probe: MenuProbe) {
        self.probe = probe
    }

    func collectTopLevel(_ menu: MenuNode, title: String) {
        budget = AccessibilityMenuReader.maxEntriesPerMenu
        collect(in: menu.children, path: [title])
    }

    /// Emits **leaves only**. A submenu's parent row ("Services", "Move & Resize") is an
    /// `AXMenuItem` too, but pressing it only opens the submenu — as a dial slot it would be a row
    /// that visibly does nothing, so the path it contributes is passed down instead of emitted.
    private func collect(in items: [AXUIElement], path: [String]) {
        forEachMenuItem(in: items) { node in
            guard self.budget > 0 else { return false }
            guard let title = node.title, !title.isEmpty else {
                // A separator has no title; so does a node whose read just failed. Only the abort
                // flag distinguishes them, and only the abort flag is allowed to stop the walk.
                return !self.probe.aborted
            }
            let itemPath = path + [title]

            if let submenu = self.submenu(of: node) {
                if itemPath.count < AccessibilityMenuReader.maxDepth {
                    self.collect(in: submenu.children, path: itemPath)
                }
                return !self.probe.aborted
            }

            guard let detail = self.probe.values(node.element, MenuWalk.detailAttributes) else {
                return !self.probe.aborted
            }
            self.entries.append(AppMenuEntry(
                id: self.elements.count,
                path: itemPath,
                shortcut: MenuWalk.shortcut(char: detail[0] as? String, modifiers: (detail[1] as? NSNumber)?.intValue),
                // Unreadable counts as disabled: an item whose state cannot be established is one
                // we should not promise the user we can run.
                isEnabled: (detail[2] as? NSNumber)?.boolValue ?? false
            ))
            self.elements.append(node.element)
            self.budget -= 1
            return true
        }
    }

    /// Visits menu rows, flattening the `AXMenu` container layer away.
    ///
    /// Expands **one child at a time** and lets `body` stop it (review §2: the old version read the
    /// role of every child of a menu before the caller's budget was consulted even once, so a menu
    /// with five hundred rows cost five hundred messages no matter how few were wanted). Returns
    /// false when the walk must not continue.
    @discardableResult
    private func forEachMenuItem(in items: [AXUIElement], _ body: (MenuNode) -> Bool) -> Bool {
        for item in items {
            guard !probe.aborted else { return false }
            guard let node = probe.node(item) else {
                guard !probe.aborted else { return false }
                continue
            }
            switch node.role {
            case MenuWalk.menuRole:
                guard forEachMenuItem(in: node.children, body) else { return false }
            case MenuWalk.menuItemRole:
                guard body(node) else { return false }
            default:
                continue
            }
        }
        return true
    }

    /// The `AXMenu` hanging off a row, or nil when the row is a leaf.
    ///
    /// Costs **nothing** for the common case, because the children came back with the node and a
    /// leaf has none. The role check is not skippable: Finder puts `AXButton`, `AXImage` and
    /// `AXRadioGroup` children on ordinary View-menu rows (the icon/list/column control), and
    /// treating "has a child" as "has a submenu" would drop those rows from the menu entirely.
    private func submenu(of node: MenuNode) -> MenuNode? {
        for child in node.children {
            guard let child = probe.node(child) else { return nil }
            if child.role == MenuWalk.menuRole { return child }
        }
        return nil
    }

    static let menuRole = kAXMenuRole as String
    static let menuItemRole = kAXMenuItemRole as String
    /// Read in one message once a row is known to be a leaf, in this order.
    static let detailAttributes = [
        kAXMenuItemCmdCharAttribute as String,
        kAXMenuItemCmdModifiersAttribute as String,
        kAXEnabledAttribute as String,
    ]

    /// `"cmd+shift+n"`, `"cmd+option+down"`, or nil when the item has no readable accelerator.
    ///
    /// Display text, never an input recipe — nothing is ever synthesised from it.
    static func shortcut(char: String?, modifiers: Int?) -> String? {
        guard let char, let name = keyName(char) else { return nil }
        return modifierPrefix(modifiers) + name
    }

    /// Documented encoding: 0 means Command; bit 0 Shift, bit 1 Option, bit 2 Control, and bit 3
    /// set means "no Command modifier at all".
    static func modifierPrefix(_ mask: Int?) -> String {
        guard let mask else { return "" }
        var parts: [String] = []
        if mask & 8 == 0 { parts.append("cmd") }
        if mask & 1 != 0 { parts.append("shift") }
        if mask & 2 != 0 { parts.append("option") }
        if mask & 4 != 0 { parts.append("control") }
        return parts.isEmpty ? "" : parts.joined(separator: "+") + "+"
    }

    /// Names the key from `AXMenuItemCmdChar` rather than from `AXMenuItemCmdGlyph`.
    ///
    /// `Tools/dump-menu-accelerators.swift` reads the glyph, and its table is wrong on this OS:
    /// measured across WeChat, Codex, Claude, Chrome, Finder, Mail and iTerm, ↑↓←→ come back as
    /// glyphs 104/106/100/101, not the 0x04/0x05/0x02/0x03 that table assumes (0x02 is in fact
    /// tab), so every arrow accelerator printed as a bare `"option+"`. The character is the
    /// reliable half of the pair: it was present on **every** accelerator seen, and function keys
    /// arrive as the documented `NSEvent` private-use codepoints. When it is missing or has no
    /// readable name (🎤 for Dictation) the entry simply carries no shortcut, which costs a label
    /// and nothing else.
    static func keyName(_ key: String) -> String? {
        guard let scalar = key.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x08, 0x7F: return "delete"
        case 0x09: return "tab"
        case 0x03, 0x0D: return "return"
        case 0x19: return "backtab"
        case 0x1B, 0x238B: return "escape"
        case 0x20: return "space"
        case 0x21...0x7E: return key.lowercased()
        case 0xF700: return "up"
        case 0xF701: return "down"
        case 0xF702: return "left"
        case 0xF703: return "right"
        case 0xF704...0xF726: return "f\(scalar.value - 0xF703)"
        case 0xF728: return "forwarddelete"
        case 0xF729: return "home"
        case 0xF72B: return "end"
        case 0xF72C: return "pageup"
        case 0xF72D: return "pagedown"
        default: return nil
        }
    }
}

// MARK: - The budget

/// What a read of `kAXFocusedWindowAttribute` actually established.
///
/// Three cases, not two, and that is the whole point (review N1). Collapsing "we could not tell"
/// into "there is no window" let a session that had been opened with no focused window approve a
/// press once the app had grown one, because `nil == nil` looked like a match. An error is never
/// allowed to stand in for a fact here.
enum FocusedWindow {
    case window(AXUIElement)
    /// The application genuinely has no focused window — a menu-bar-only app, or one whose windows
    /// are all closed. `kAXFocusedWindowAttribute` says so with `.noValue`/`.attributeUnsupported`.
    case none
    /// The read did not answer, or answered with something that is not a window.
    case unreadable(String)

    init(_ read: (value: CFTypeRef?, error: AXError)) {
        switch read.error {
        case .success:
            guard let value = read.value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                self = .unreadable("focused window is not an AXUIElement")
                return
            }
            self = .window(value as! AXUIElement)
        case .noValue, .attributeUnsupported:
            self = .none
        case .cannotComplete:
            self = .unreadable("the app did not answer (AXError \(read.error.rawValue))")
        default:
            self = .unreadable("AXError \(read.error.rawValue)")
        }
    }

    /// Read outside a session's budget — one message, on the press path.
    static func read(of application: AXUIElement) -> FocusedWindow {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            application, kAXFocusedWindowAttribute as CFString, &value
        )
        return FocusedWindow((value: value, error: error))
    }
}

/// One menu-bar node's role, title and children, read together in a single Accessibility message.
private struct MenuNode {
    var element: AXUIElement
    var role: String?
    var title: String?
    var children: [AXUIElement]
}

/// Every Accessibility read one `openSession` makes, and the two limits that can stop them.
///
/// It exists because of review §2: a per-message timeout is not a bound on a walk that sends
/// hundreds of messages. Once `aborted` is set every further read returns nil without touching
/// Accessibility, so an abort unwinds the recursion in memory rather than over IPC.
private final class MenuProbe {
    private let deadline: TimeInterval
    private let maxMessages: Int
    private(set) var messages = 0
    private(set) var aborted = false
    /// Why the read stopped — carried for diagnostics, not for the contract.
    private(set) var abortReason: String?

    init(maxDuration: TimeInterval, maxMessages: Int) {
        self.deadline = Date().timeIntervalSinceReferenceDate + maxDuration
        self.maxMessages = maxMessages
    }

    /// One read, charged and deadline-checked, with the error kept.
    ///
    /// The error is part of the answer, not noise: only it separates "this element has no such
    /// attribute" from "the app did not answer", and treating the second as the first is exactly
    /// how the focused-window check could be talked into approving an unknown context (review N1).
    func read(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, error: AXError) {
        guard !aborted else { return (nil, .cannotComplete) }
        guard messages < maxMessages else {
            abort("message budget of \(maxMessages) Accessibility reads exhausted")
            return (nil, .cannotComplete)
        }
        guard Date().timeIntervalSinceReferenceDate < deadline else {
            abort("read deadline reached before \(name)")
            return (nil, .cannotComplete)
        }
        messages += 1

        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        // `.cannotComplete` is what a messaging timeout looks like. One of them means the app has
        // stopped answering, and the next few hundred reads would each pay the same wait, so it
        // ends the read rather than being swallowed as "this node has no title".
        if error == .cannotComplete {
            abort("Accessibility message timed out reading \(name)")
            return (nil, error)
        }
        // Checked after the call as well: a read that returns just inside the deadline can still
        // have spent most of it, and the next one would start over budget.
        guard Date().timeIntervalSinceReferenceDate < deadline else {
            abort("read deadline reached after \(name)")
            return (nil, .cannotComplete)
        }
        return (value, error)
    }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        let (value, error) = read(element, name)
        guard error == .success else { return nil }
        return value
    }

    /// The focused window of an application, with "there is none" kept apart from "we could not
    /// tell". Charged against the same budget as everything else.
    func focusedWindow(of application: AXUIElement) -> FocusedWindow {
        FocusedWindow(read(application, kAXFocusedWindowAttribute as String))
    }

    /// Several attributes of one element in **one** message.
    ///
    /// This is the difference between G4 working in Chrome and Mail and not working there at all.
    /// Read one attribute at a time, a row costs six round trips and Mail's menu bar came to 1990
    /// reads / 298 ms — over `AppMenuReadBudget.maxDuration` on a machine doing nothing else.
    /// Batched, the same menu is 782 reads / 151 ms.
    ///
    /// Values come back in the order asked, and a failed attribute comes back **inside the array**
    /// as an `AXValue` of type `.axError` while the call itself still returns `.success`. Those
    /// have to be decoded, not merely recognised (review N2): a missing shortcut and an
    /// unanswered `AXChildren` look identical until the error is unwrapped, and swallowing the
    /// second would silently turn a submenu into a leaf and still hand the menu over.
    func values(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef?]? {
        guard let raw = attribute(element, names) else { return nil }
        var decoded: [CFTypeRef?] = []
        decoded.reserveCapacity(raw.count)
        for (index, value) in raw.enumerated() {
            guard CFGetTypeID(value) == AXValueGetTypeID(),
                  AXValueGetType(value as! AXValue) == .axError
            else {
                decoded.append(value)
                continue
            }
            var error = AXError.success
            guard AXValueGetValue(value as! AXValue, .axError, &error) else {
                abort("undecodable per-attribute error reading \(names[index])")
                return nil
            }
            switch error {
            // The ordinary absences: this row has no accelerator, this leaf has no children.
            case .noValue, .attributeUnsupported, .success:
                decoded.append(nil)
            default:
                // Anything else is a read that did not happen. Aborting the whole session is the
                // point: a menu assembled out of reads that failed is one the user cannot tell is
                // incomplete, and a favourite missing from it looks like a favourite deleted.
                abort("per-attribute AXError \(error.rawValue) reading \(names[index])")
                return nil
            }
        }
        return decoded
    }

    /// Role, title and children of one node — the three things the walk needs to decide what a
    /// node is — in one message.
    func node(_ element: AXUIElement) -> MenuNode? {
        guard let values = values(element, MenuProbe.nodeAttributes) else { return nil }
        return MenuNode(
            element: element,
            role: values[0] as? String,
            title: values[1] as? String,
            children: (values[2] as? [AXUIElement]) ?? []
        )
    }

    private static let nodeAttributes = [
        kAXRoleAttribute as String,
        kAXTitleAttribute as String,
        kAXChildrenAttribute as String,
    ]

    func children(_ element: AXUIElement) -> [AXUIElement]? {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]
    }

    /// The batched form of `attribute`, charged as the one message it is.
    private func attribute(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef]? {
        guard !aborted else { return nil }
        guard messages < maxMessages else {
            abort("message budget of \(maxMessages) Accessibility reads exhausted")
            return nil
        }
        guard Date().timeIntervalSinceReferenceDate < deadline else {
            abort("read deadline reached before \(names.first ?? "?")")
            return nil
        }
        messages += 1

        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element, names as CFArray, AXCopyMultipleAttributeOptions(), &values
        )
        if error == .cannotComplete {
            abort("Accessibility message timed out reading \(names.first ?? "?")")
            return nil
        }
        guard Date().timeIntervalSinceReferenceDate < deadline else {
            abort("read deadline reached after \(names.first ?? "?")")
            return nil
        }
        guard error == .success, let values = values as? [CFTypeRef], values.count == names.count
        else { return nil }
        return values
    }

    func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func abort(_ reason: String) {
        aborted = true
        abortReason = reason
    }
}

// MARK: - The session

/// One opened menu, pinned to the process and the focused window it was read from.
final class AccessibilityMenuSession: AppMenuSession {
    let bundleID: String
    let entries: [AppMenuEntry]

    private let pid: pid_t
    private let application: AXUIElement
    /// The window focused when the menu was read. `nil` is a real value — a menu-bar-only app has
    /// no focused window — and a press then requires it to *still* be nil.
    private let focusedWindow: AXUIElement?
    /// Parallel to `entries`: the element each entry was read from, which is the one pressed.
    private let elements: [AXUIElement]

    init(
        bundleID: String,
        pid: pid_t,
        application: AXUIElement,
        focusedWindow: AXUIElement?,
        entries: [AppMenuEntry],
        elements: [AXUIElement]
    ) {
        self.bundleID = bundleID
        self.pid = pid
        self.application = application
        self.focusedWindow = focusedWindow
        self.entries = entries
        self.elements = elements
    }

    func press(id: Int) -> AppMenuPressOutcome {
        // By pid, not by bundle ID: the app may have quit and been relaunched since the menu was
        // read, and the new process is a different context wearing the same name (review §3).
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return .appUnavailable
        }
        switch FocusedWindow.read(of: application) {
        case .window(let current):
            // `CFEqual` rather than `==`: two `AXUIElement`s for the same window are distinct CF
            // objects, and `CFEqual` is what compares their identity. This is the review's Finder
            // case — choose a file in window A, open the menu, switch to window B, press "Move to
            // Trash" — and it is why a mismatch does nothing at all.
            guard let recorded = focusedWindow, CFEqual(recorded, current) else { return .contextChanged }
        case .none:
            guard focusedWindow == nil else { return .contextChanged }
        case .unreadable(let reason):
            // Reported as a failure rather than as `.contextChanged`, because the context may well
            // be unchanged — what happened is that it could not be established, and claiming a
            // change we did not observe would put a false explanation in front of the user. Either
            // way nothing is pressed; if the lead would rather this read as "blocked" next to the
            // frontmost-app refusal, one line in `ActionDispatcher` moves it.
            return .failed("focused window unreadable: \(reason)")
        }
        guard elements.indices.contains(id) else { return .notFound }

        let element = elements[id]
        // Re-read rather than trusting the entry: the app may have greyed the item out since.
        guard (copyAttribute(element, kAXEnabledAttribute as String) as? NSNumber)?.boolValue == true else {
            return .disabled
        }

        // The element that was read, pressed directly. No lookup by title, so two identically
        // named rows cannot collapse into one (review §4); and no menu is opened on screen, so the
        // target app never has to be frontmost.
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        switch error {
        case .success: return .pressed
        // The app rebuilt its menu and threw this element away — that is "the row is gone", not a
        // failure the user could do anything about.
        case .invalidUIElement: return .notFound
        default: return .failed("AXError \(error.rawValue)")
        }
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
