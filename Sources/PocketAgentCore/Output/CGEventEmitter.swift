import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid

/// Anything that can turn a `KeyStroke` into real input.
public protocol InputEmitting: AnyObject {
    /// Down and up, back to back — a single key press that can never repeat.
    func press(_ stroke: KeyStroke)
    /// Held key down. Must be balanced by `keyUp`.
    func keyDown(_ stroke: KeyStroke)
    func keyUp(_ stroke: KeyStroke)
    /// Release every modifier and key this emitter still holds. Safe to call at any time.
    func releaseAll()
}

/// Posts one keyboard event. Injectable so the *sequence* the emitter produces can be asserted in
/// tests without touching the real system.
public protocol KeyboardEventPosting: AnyObject {
    func post(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags)
}

public final class QuartzKeyboardEventPoster: KeyboardEventPosting {
    public init() {}

    public func post(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
        else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}

/// Emits keyboard events via Quartz (spec §11).
///
/// Three properties this type exists to guarantee:
/// 1. **Serialisation.** Every recipe runs on one serial queue, so two chords can never interleave
///    their events (spec §11.3).
/// 2. **Real modifier events.** A modified key is sent as
///    `modifier down → key down → key up → modifier up`, not merely as an `event.flags` bitmask
///    (spec §11.2). Measured 2026-09-16: setting flags alone was enough for `⌘N` but **not** for
///    `⌃⇧M` — Codex ignored the latter until the Control key was genuinely pressed. Flags alone are
///    a compatibility gamble; this order is what actually works.
/// 3. **No stuck modifiers.** Anything still held can be force-released by `releaseAll()`, including
///    after a mid-recipe failure.
public final class CGEventEmitter: InputEmitting {
    private let queue: DispatchQueue
    private let poster: KeyboardEventPosting
    private var heldModifiers: Set<ModifierKey> = []
    private var heldKeys: Set<CGKeyCode> = []

    public convenience init(queue: DispatchQueue = DispatchQueue(label: "com.pocketagentremote.emitter")) {
        self.init(queue: queue, poster: QuartzKeyboardEventPoster())
    }

    init(queue: DispatchQueue, poster: KeyboardEventPosting) {
        self.queue = queue
        self.poster = poster
    }

    // MARK: - InputEmitting

    public func press(_ stroke: KeyStroke) {
        queue.async { self.performPress(stroke) }
    }

    public func keyDown(_ stroke: KeyStroke) {
        queue.async { self.performKeyDown(stroke) }
    }

    public func keyUp(_ stroke: KeyStroke) {
        queue.async { self.performKeyUp(stroke) }
    }

    public func releaseAll() {
        queue.async { self.performReleaseAll() }
    }

    // MARK: - Synchronous core (directly testable)

    func performPress(_ stroke: KeyStroke) {
        let modifiers = ordered(stroke.modifiers)
        for modifier in modifiers { pushModifier(modifier) }
        if let key = stroke.key {
            // The key event still carries the flags as well — some apps read one, some the other.
            postDown(key.keyCode, flags: flags(adding: []))
            postUp(key.keyCode, flags: flags(adding: []))
        }
        for modifier in modifiers.reversed() { popModifier(modifier) }
        cleanupIfIdle()
    }

    func performKeyDown(_ stroke: KeyStroke) {
        for modifier in ordered(stroke.modifiers) { pushModifier(modifier) }
        if let key = stroke.key {
            postDown(key.keyCode, flags: flags(adding: []))
            heldKeys.insert(key.keyCode)
        }
    }

    func performKeyUp(_ stroke: KeyStroke) {
        if let key = stroke.key {
            postUp(key.keyCode, flags: flags(adding: []))
            heldKeys.remove(key.keyCode)
        }
        for modifier in ordered(stroke.modifiers).reversed() { popModifier(modifier) }
        cleanupIfIdle()
    }

    func performReleaseAll() {
        let keys = heldKeys
        let modifiers = heldModifiers
        heldKeys.removeAll()
        heldModifiers.removeAll()
        for key in keys.sorted() { postUp(key, flags: []) }
        for modifier in ordered(modifiers) { postUp(modifier.keyCode, flags: []) }
    }

    // MARK: - Queue-confined state

    private func ordered(_ modifiers: Set<ModifierKey>) -> [ModifierKey] {
        modifiers.sorted { $0.rawValue < $1.rawValue }
    }

    /// Nothing is mid-recipe; a leftover modifier at this point is always a bug, so fail safe
    /// rather than leak a stuck Shift/Option into the user's session.
    private func cleanupIfIdle() {
        guard !heldModifiers.isEmpty && heldKeys.isEmpty else { return }
        for modifier in ordered(heldModifiers) { postUp(modifier.keyCode, flags: []) }
        heldModifiers.removeAll()
    }

    private func pushModifier(_ modifier: ModifierKey) {
        guard !heldModifiers.contains(modifier) else { return }
        heldModifiers.insert(modifier)
        postDown(modifier.keyCode, flags: flags(adding: []))
    }

    private func popModifier(_ modifier: ModifierKey) {
        guard heldModifiers.contains(modifier) else { return }
        heldModifiers.remove(modifier)
        postUp(modifier.keyCode, flags: flags(adding: []))
    }

    private func flags(adding extra: Set<ModifierKey>) -> CGEventFlags {
        var flags = CGEventFlags()
        for modifier in heldModifiers.union(extra) {
            flags.insert(modifier.eventFlag)
        }
        return flags
    }

    // MARK: - Quartz

    private func postDown(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        poster.post(keyCode: keyCode, down: true, flags: flags)
    }

    private func postUp(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        poster.post(keyCode: keyCode, down: false, flags: flags)
    }
}

/// Accessibility trust, required before any of the above actually reaches an application
/// (spec §11.1). Never fail silently: the menu bar is expected to surface this state.
public enum AccessibilityPermission {
    public static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks the system to show the "grant Accessibility access" prompt if not yet granted.
    @discardableResult
    public static func requestIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

/// HID access state.
///
/// This matters for exactly one thing: the **generic C variant** (`Wireless Controller`) is read
/// through IOHIDManager, and macOS gates HID device access behind Input Monitoring. The XInput
/// variant is unaffected because it goes through GameController instead. So a user whose controller
/// happens to be in the generic variant can lose *all* input until this is granted — which is a
/// confusing failure to debug without a state readout.
public enum InputMonitoringPermission {
    public enum State: String, Sendable {
        case granted
        case denied
        case unknown
    }

    public static var state: State {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    public static var isGranted: Bool { state == .granted }

    /// Shows the system prompt when the state is still `unknown`. Returns the state afterwards.
    @discardableResult
    public static func request() -> State {
        if state == .unknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        return state
    }
}
