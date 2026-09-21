#!/usr/bin/env swift
//
// Opens a *live* menu session on a running application via the Accessibility API and presses an
// entry by id — the manual harness for `PocketAgentCore/Focus/AccessibilityMenuReader.swift`
// (G4 通用菜单, contract v2).
//
// Why a copy of the walk rather than an import: a `swift` script cannot link PocketAgentCore, so
// this file mirrors the reader's traversal, budget and press checks instead of calling them. It
// therefore verifies the *approach* — that entries are addressable by id, that a press lands on a
// backgrounded app, and that a changed focused window is refused — not the class itself. Keep the
// two in step when either changes.
//
// Usage:  swift Tools/press-menu-item.swift <bundleID> [list]
//         swift Tools/press-menu-item.swift <bundleID> press <id> [waitSeconds]
//
// `waitSeconds` holds the session open before pressing, which is how the `contextChanged` refusal
// is demonstrated by hand: start the press, switch the app to another window, watch it refuse.
// Entries are pressed by id because a title path is not an identity — two windows can produce two
// rows with exactly the same path, and WeChat has a menu item literally called "Pin/Unpin".
//
// Requires the calling process to hold Accessibility permission.

import AppKit
import ApplicationServices
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: swift Tools/press-menu-item.swift <bundleID> [list | press <id> [waitSeconds]]\n".utf8))
    exit(64)
}
let bundleID = arguments[1]
let command = arguments.count > 2 ? arguments[2] : "list"

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Accessibility permission is required\n".utf8))
    exit(2)
}

// Mirrors AppMenuReadBudget and AccessibilityMenuReader, so the numbers printed here are the
// numbers the app sees.
let maxDuration: TimeInterval = 0.3
let messagingTimeout: Float = 0.5
let maxMessages = 1500
let maxEntriesPerMenu = 60
let maxDepth = 4

let timeoutResult = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
if timeoutResult != .success {
    print("warning: AXUIElementSetMessagingTimeout returned AXError \(timeoutResult.rawValue)")
}

let menuRole = kAXMenuRole as String
let menuItemRole = kAXMenuItemRole as String

enum FocusedWindow {
    case window(AXUIElement)
    case none
    case unreadable(String)

    static func read(_ application: AXUIElement) -> FocusedWindow {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value)
        switch error {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return .unreadable("focused window is not an AXUIElement")
            }
            return .window(value as! AXUIElement)
        case .noValue, .attributeUnsupported: return .none
        default: return .unreadable("AXError \(error.rawValue)")
        }
    }
}

struct Node {
    var element: AXUIElement
    var role: String?
    var title: String?
    var children: [AXUIElement]
}

final class Probe {
    private let deadline: TimeInterval
    private(set) var messages = 0
    private(set) var aborted = false
    private(set) var abortReason: String?
    private let started = Date()

    init() { deadline = Date().timeIntervalSinceReferenceDate + maxDuration }

    var elapsedMs: Int { Int((Date().timeIntervalSince(started) * 1000).rounded()) }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard !aborted else { return nil }
        guard messages < maxMessages else { return abort("message budget of \(maxMessages) reads exhausted") }
        guard Date().timeIntervalSinceReferenceDate < deadline else { return abort("deadline reached before \(name)") }
        messages += 1
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if error == .cannotComplete { return abort("Accessibility message timed out reading \(name)") }
        guard Date().timeIntervalSinceReferenceDate < deadline else { return abort("deadline reached after \(name)") }
        guard error == .success else { return nil }
        return value
    }

    /// Several attributes of one element in one message — the whole reason Chrome and Mail fit
    /// inside the 0.3 s budget (Mail: 1990 reads / 298 ms one at a time, 782 / 151 ms batched).
    private func attribute(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef]? {
        guard !aborted else { return nil }
        guard messages < maxMessages else { _ = abort("message budget of \(maxMessages) reads exhausted"); return nil }
        guard Date().timeIntervalSinceReferenceDate < deadline else { _ = abort("deadline reached"); return nil }
        messages += 1
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &values)
        if error == .cannotComplete { _ = abort("Accessibility message timed out"); return nil }
        guard Date().timeIntervalSinceReferenceDate < deadline else { _ = abort("deadline reached"); return nil }
        guard error == .success, let values = values as? [CFTypeRef], values.count == names.count else { return nil }
        return values
    }

    /// A failed attribute comes back *inside* the array as an AXValue of type .axError while the
    /// call itself returns .success, so the error has to be decoded: .noValue/.attributeUnsupported
    /// are ordinary absences, anything else is a read that did not happen and ends the session.
    func values(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef?]? {
        guard let raw = attribute(element, names) else { return nil }
        var decoded: [CFTypeRef?] = []
        for (index, value) in raw.enumerated() {
            guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError
            else { decoded.append(value); continue }
            var error = AXError.success
            guard AXValueGetValue(value as! AXValue, .axError, &error) else {
                _ = abort("undecodable per-attribute error reading \(names[index])")
                return nil
            }
            switch error {
            case .noValue, .attributeUnsupported, .success: decoded.append(nil)
            default:
                _ = abort("per-attribute AXError \(error.rawValue) reading \(names[index])")
                return nil
            }
        }
        return decoded
    }

    func node(_ element: AXUIElement) -> Node? {
        guard let v = values(element, [kAXRoleAttribute as String, kAXTitleAttribute as String, kAXChildrenAttribute as String])
        else { return nil }
        return Node(element: element, role: v[0] as? String, title: v[1] as? String,
                    children: (v[2] as? [AXUIElement]) ?? [])
    }

    func children(_ element: AXUIElement) -> [AXUIElement]? {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]
    }
    func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func abort(_ reason: String) -> CFTypeRef? {
        aborted = true
        abortReason = reason
        return nil
    }
}

func modifierPrefix(_ mask: Int?) -> String {
    guard let mask else { return "" }
    var parts: [String] = []
    if mask & 8 == 0 { parts.append("cmd") }
    if mask & 1 != 0 { parts.append("shift") }
    if mask & 2 != 0 { parts.append("option") }
    if mask & 4 != 0 { parts.append("control") }
    return parts.isEmpty ? "" : parts.joined(separator: "+") + "+"
}

/// Names the key from AXMenuItemCmdChar. The glyph table in dump-menu-accelerators.swift is wrong
/// on this OS (arrows come back as 104/106/100/101, and its 0x02 "left" is really tab).
func keyName(_ key: String) -> String? {
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

struct Entry {
    var id: Int
    var path: [String]
    var shortcut: String?
    var isEnabled: Bool
    var pathKey: String { path.joined(separator: "/") }
}

final class Session {
    let pid: pid_t
    let application: AXUIElement
    let focusedWindow: AXUIElement?
    let entries: [Entry]
    let elements: [AXUIElement]
    let readMs: Int
    let messages: Int

    init(pid: pid_t, application: AXUIElement, focusedWindow: AXUIElement?,
         entries: [Entry], elements: [AXUIElement], readMs: Int, messages: Int) {
        self.pid = pid
        self.application = application
        self.focusedWindow = focusedWindow
        self.entries = entries
        self.elements = elements
        self.readMs = readMs
        self.messages = messages
    }

    func focusedWindowTitle() -> String {
        guard case .window(let window) = currentFocusedWindow() else {
            if case .unreadable(let reason) = currentFocusedWindow() { return "<unreadable: \(reason)>" }
            return "<none>"
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success
        else { return "<untitled>" }
        return (value as? String) ?? "<untitled>"
    }

    /// Three answers, not two: "there is no focused window" must not be reachable from "the read
    /// failed", or a session opened with no window approves a press into an unknown one.
    func currentFocusedWindow() -> FocusedWindow {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value)
        switch error {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return .unreadable("focused window is not an AXUIElement")
            }
            return .window(value as! AXUIElement)
        case .noValue, .attributeUnsupported: return .none
        default: return .unreadable("AXError \(error.rawValue)")
        }
    }

    /// The same five checks, in the same order, as AccessibilityMenuSession.press(id:).
    func press(id: Int) -> String {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return "appUnavailable" }
        switch currentFocusedWindow() {
        case .window(let current):
            guard let recorded = focusedWindow, CFEqual(recorded, current) else { return "contextChanged" }
        case .none:
            guard focusedWindow == nil else { return "contextChanged" }
        case .unreadable(let reason):
            return "failed: focused window unreadable: \(reason)"
        }
        guard elements.indices.contains(id) else { return "notFound (id out of range)" }
        let element = elements[id]
        var enabled: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
              (enabled as? NSNumber)?.boolValue == true
        else { return "disabled" }
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        switch error {
        case .success: return "pressed"
        case .invalidUIElement: return "notFound (element went away)"
        default: return "failed: AXError \(error.rawValue)"
        }
    }
}

/// Same two filters as the reader: drop terminated instances, prefer the active one.
func runningApplication(for bundleID: String) -> NSRunningApplication? {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    return running.first { $0.isActive } ?? running.first
}

func openSession() -> Session? {
    guard let app = runningApplication(for: bundleID) else {
        FileHandle.standardError.write(Data("no running application with bundle id \(bundleID)\n".utf8))
        exit(1)
    }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    let probe = Probe()

    func giveUp(_ reason: String) -> Session? {
        print("no session: \(reason) (after \(probe.messages) reads in \(probe.elapsedMs) ms)")
        return nil
    }

    guard let menuBar = probe.element(application, kAXMenuBarAttribute as String) else {
        return giveUp(probe.abortReason ?? "no menu bar")
    }

    var entries: [Entry] = []
    var elements: [AXUIElement] = []
    var budget = 0

    let detailAttributes = [kAXMenuItemCmdCharAttribute as String,
                            kAXMenuItemCmdModifiersAttribute as String,
                            kAXEnabledAttribute as String]

    /// The AXMenu hanging off a row, or nil when the row is a leaf. Free for a leaf (no children);
    /// the role check is not skippable because Finder puts AXButton/AXImage/AXRadioGroup children
    /// on ordinary View-menu rows.
    func submenu(of node: Node) -> Node? {
        for child in node.children {
            guard let child = probe.node(child) else { return nil }
            if child.role == menuRole { return child }
        }
        return nil
    }

    @discardableResult
    func forEachMenuItem(in items: [AXUIElement], _ body: (Node) -> Bool) -> Bool {
        for item in items {
            guard !probe.aborted else { return false }
            guard let node = probe.node(item) else {
                guard !probe.aborted else { return false }
                continue
            }
            switch node.role {
            case menuRole: guard forEachMenuItem(in: node.children, body) else { return false }
            case menuItemRole: guard body(node) else { return false }
            default: continue
            }
        }
        return true
    }

    func collect(in items: [AXUIElement], path: [String]) {
        forEachMenuItem(in: items) { node in
            guard budget > 0 else { return false }
            guard let title = node.title, !title.isEmpty else { return !probe.aborted }
            let itemPath = path + [title]
            if let child = submenu(of: node) {
                if itemPath.count < maxDepth { collect(in: child.children, path: itemPath) }
                return !probe.aborted
            }
            guard let detail = probe.values(node.element, detailAttributes) else { return !probe.aborted }
            let key = (detail[0] as? String).flatMap(keyName).map {
                modifierPrefix((detail[1] as? NSNumber)?.intValue) + $0
            }
            entries.append(Entry(id: elements.count, path: itemPath, shortcut: key,
                                 isEnabled: (detail[2] as? NSNumber)?.boolValue ?? false))
            elements.append(node.element)
            budget -= 1
            return true
        }
    }

    // dropFirst is the Apple menu: the system's, not the app's, and where Shut Down… lives.
    guard let topLevel = probe.children(menuBar) else { return giveUp(probe.abortReason ?? "no menus") }
    for menu in topLevel.dropFirst() {
        guard let node = probe.node(menu) else {
            if probe.aborted { break }
            continue
        }
        guard let title = node.title, !title.isEmpty else { continue }
        budget = maxEntriesPerMenu
        collect(in: node.children, path: [title])
        guard !probe.aborted else { break }
    }
    var focusedWindow: AXUIElement?
    switch FocusedWindow.read(application) {
    case .window(let window): focusedWindow = window
    case .none: focusedWindow = nil
    case .unreadable(let reason): return giveUp("focused window unreadable: \(reason)")
    }
    // An aborted read must never hand back a partial menu: a missing favourite is worse than
    // no menu, because the user cannot see that it is missing.
    if probe.aborted { return giveUp(probe.abortReason ?? "aborted") }
    return Session(pid: app.processIdentifier, application: application, focusedWindow: focusedWindow,
                   entries: entries, elements: elements, readMs: probe.elapsedMs, messages: probe.messages)
}

switch command {
case "list":
    guard let session = openSession() else { exit(3) }
    for entry in session.entries {
        let flag = entry.isEnabled ? "on " : "OFF"
        let key = entry.pathKey.padding(toLength: max(46, entry.pathKey.count), withPad: " ", startingAt: 0)
        print("  [\(String(format: "%3d", entry.id))] [\(flag)] \(key) \(entry.shortcut ?? "")")
    }
    print("\n\(session.entries.count) entries in \(session.readMs) ms, \(session.messages) AX reads "
        + "(\(bundleID), pid \(session.pid), focused window: \(session.focusedWindowTitle()))")

case "press":
    guard arguments.count > 3, let id = Int(arguments[3]) else {
        FileHandle.standardError.write(Data("press needs an id, e.g. press 42\n".utf8))
        exit(64)
    }
    let wait = arguments.count > 4 ? (TimeInterval(arguments[4]) ?? 0) : 0
    guard let session = openSession() else { exit(3) }
    guard let entry = session.entries.first(where: { $0.id == id }) else {
        print("no entry with id \(id) (session has \(session.entries.count))")
        exit(4)
    }
    print("session: pid \(session.pid), \(session.entries.count) entries in \(session.readMs) ms, "
        + "focused window: \(session.focusedWindowTitle())")
    print("target:  [\(id)] \(entry.pathKey)")
    if wait > 0 {
        print("waiting \(wait) s — switch windows now to test the contextChanged refusal")
        Thread.sleep(forTimeInterval: wait)
    }
    let outcome = session.press(id: id)
    print("outcome: \(outcome) (focused window now: \(session.focusedWindowTitle()))")
    exit(outcome == "pressed" ? 0 : 5)

default:
    FileHandle.standardError.write(Data("unknown command \(command); use list or press\n".utf8))
    exit(64)
}
