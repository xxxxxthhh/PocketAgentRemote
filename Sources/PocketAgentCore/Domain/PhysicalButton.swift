import Foundation

/// The six inputs the L1162 physically has.
///
/// The hardware exposes a full Xbox controller profile (35 elements), but only these six ever
/// fire — see `docs/hardware-probe.md` §6.2. The pairing key is deliberately not modelled: it
/// switches the device variant and powers the controller off.
public enum PhysicalButton: String, Codable, CaseIterable, Sendable {
    case up
    case down
    case left
    case right
    case a
    case b

    /// Directions are the only inputs that are allowed to repeat while held (spec §19).
    public var isDirection: Bool {
        switch self {
        case .up, .down, .left, .right: return true
        case .a, .b: return false
        }
    }
}

/// A raw press or release coming from an input source, with a monotonic timestamp.
public enum InputEvent: Equatable, Sendable {
    case pressed(PhysicalButton, timestamp: TimeInterval)
    case released(PhysicalButton, timestamp: TimeInterval)

    public var button: PhysicalButton {
        switch self {
        case .pressed(let button, _), .released(let button, _): return button
        }
    }

    public var timestamp: TimeInterval {
        switch self {
        case .pressed(_, let timestamp), .released(_, let timestamp): return timestamp
        }
    }

    public var isPress: Bool {
        if case .pressed = self { return true }
        return false
    }
}

/// What the gesture engine recognises (spec §10.2).
public enum ControllerGesture: Equatable, Sendable {
    /// Button released within the tap threshold.
    case tap(PhysicalButton)
    /// Button held past the hold threshold and released without forming a chord.
    case hold(PhysicalButton)
    /// `modifier` was held while `key` went down. Fires exactly once per chord.
    case chord(modifier: PhysicalButton, key: PhysicalButton)
    /// The chord's secondary key came back up (or the controller went away mid-chord).
    ///
    /// Only matters for bindings that have to be *held* — a modifier-only chord like `⌥⇧`, where
    /// the release is what ends the gesture. Action bindings ignore it, which is what keeps a
    /// chord's action a single one-shot press.
    case chordReleased(modifier: PhysicalButton, key: PhysicalButton)
    /// A single button crossed the hold threshold **while still down**, so a hold-type binding can
    /// start now rather than at release.
    ///
    /// This is what makes push-to-talk a one-button gesture: the key goes down when the threshold is
    /// crossed and comes back up when the button is released. A plain `hold` is a *completed* press
    /// (it fires on release) and so cannot express "still holding".
    case holdBegan(PhysicalButton)
    /// The button that began a hold came back up. Ends the gesture `holdBegan` started.
    case holdEnded(PhysicalButton)
}

/// Output of the gesture engine, before semantic-action resolution.
///
/// Directions become key down/up pairs so the target application (not this app) performs key
/// repeat — that keeps repeat rate and delay native. Buttons that must never repeat are emitted
/// as an immediate down+up pair instead.
public enum ResolvedEvent: Equatable, Sendable {
    case keyDown(PhysicalButton)
    case keyUp(PhysicalButton)
    case gesture(ControllerGesture)
}
