import ApplicationServices
import CoreGraphics
import Foundation

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

public enum InputEmitterError: Error, CustomStringConvertible {
    case accessibilityNotGranted

    public var description: String {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission is required to synthesise keyboard events"
        }
    }
}

/// Emits keyboard events via Quartz (spec §11).
///
/// Two properties this type exists to guarantee:
/// 1. **Serialisation.** Every recipe runs on one serial queue, so two chords can never interleave
///    their events (spec §11.3).
/// 2. **No stuck modifiers.** Modifiers are pushed and popped around the key, and anything still
///    held can be force-released by `releaseAll()` — including after a mid-recipe failure
///    (spec §11.2, §17).
public final class CGEventEmitter: InputEmitting {
    private let queue: DispatchQueue
    private var heldModifiers: Set<ModifierKey> = []
    private var heldKeys: Set<CGKeyCode> = []

    public init(queue: DispatchQueue = DispatchQueue(label: "com.pocketagentremote.emitter")) {
        self.queue = queue
    }

    // MARK: - InputEmitting

    public func press(_ stroke: KeyStroke) {
        queue.async {
            self.perform {
                self.postDown(stroke.key.keyCode, flags: self.flags(adding: stroke.modifiers))
                self.postUp(stroke.key.keyCode, flags: self.flags(adding: stroke.modifiers))
            }
        }
    }

    public func keyDown(_ stroke: KeyStroke) {
        queue.async {
            self.perform {
                for modifier in stroke.modifiers.sorted(by: { $0.rawValue < $1.rawValue }) {
                    self.pushModifier(modifier)
                }
                self.postDown(stroke.key.keyCode, flags: self.flags(adding: []))
                self.heldKeys.insert(stroke.key.keyCode)
            }
        }
    }

    public func keyUp(_ stroke: KeyStroke) {
        queue.async {
            self.perform {
                self.postUp(stroke.key.keyCode, flags: self.flags(adding: []))
                self.heldKeys.remove(stroke.key.keyCode)
                for modifier in stroke.modifiers.sorted(by: { $0.rawValue < $1.rawValue }) {
                    self.popModifier(modifier)
                }
            }
        }
    }

    public func releaseAll() {
        queue.async {
            let keys = self.heldKeys
            let modifiers = self.heldModifiers
            self.heldKeys.removeAll()
            self.heldModifiers.removeAll()
            for key in keys.sorted() { self.postUp(key, flags: []) }
            for modifier in modifiers.sorted(by: { $0.rawValue < $1.rawValue }) {
                self.postUp(modifier.keyCode, flags: [])
            }
        }
    }

    // MARK: - Queue-confined state

    /// Runs `body`, and on any failure still releases everything this emitter holds.
    private func perform(_ body: () -> Void) {
        body()
        if !heldModifiers.isEmpty && heldKeys.isEmpty {
            // Nothing is mid-recipe; a leftover modifier at this point is always a bug.
            // Fail safe rather than leak a stuck Shift/Option into the user's session.
            for modifier in heldModifiers.sorted(by: { $0.rawValue < $1.rawValue }) {
                postUp(modifier.keyCode, flags: [])
            }
            heldModifiers.removeAll()
        }
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
        post(keyCode, down: true, flags: flags)
    }

    private func postUp(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        post(keyCode, down: false, flags: flags)
    }

    private func post(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
        else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
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
