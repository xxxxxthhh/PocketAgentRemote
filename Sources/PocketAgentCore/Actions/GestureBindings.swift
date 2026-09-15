import Foundation

/// Maps gestures to semantic actions (spec §6.1/§6.2/§13).
public struct GestureBindings: Equatable, Sendable {
    /// Base layer: directions and A behave normally when B is not down.
    public var base: [PhysicalButton: AgentAction]
    /// B layer: the key that, pressed while B is held, produces this action.
    public var bLayer: [PhysicalButton: AgentAction]

    public init(base: [PhysicalButton: AgentAction], bLayer: [PhysicalButton: AgentAction]) {
        self.base = base
        self.bLayer = bLayer
    }

    /// Default map. Base layer is universal navigation; the B layer mixes two things the user asked
    /// for: jumping to the two most recent chats, and the three commands worth a permanent slot.
    ///
    /// History: an all-chat-jump B layer (six slots) was tried first and rejected as too many
    /// (2026-09-16) — two recent chats turned out to be the useful number.
    public static let `default` = GestureBindings(
        base: [
            .up: .navigateUp,
            .down: .navigateDown,
            .left: .navigateLeft,
            .right: .navigateRight,
            .a: .submit,
            .b: .cancelOrInterrupt,
        ],
        bLayer: [
            .up: .goToRecentChat1,             // ⌥⌘1 — most recent chat
            .down: .goToRecentChat2,           // ⌥⌘2 — second most recent
            .left: .newChat,                   // ⌘N  — start a new agent task
            .right: .nextChatNeedingAttention, // ⌥⌘A — whichever agent wants you
            .a: .inspectChanges,               // ⌥⌘B — review the diff
        ]
    )
}

/// The phase of an action, which the output layer needs in order to decide between a key press
/// (one-shot) and a held key down/up pair (repeatable).
public enum KeyPhase: Equatable, Sendable {
    case press
    case down
    case up
}

public enum ActionTrigger: Equatable, Sendable {
    case press(AgentAction)
    case down(AgentAction)
    case up(AgentAction)
    /// A keystroke bound straight to a gesture, bypassing the semantic vocabulary.
    ///
    /// Still goes through the guard: a raw key is by definition unclassified, so it is treated as
    /// tool-specific and needs an explicit profile plus an allowlisted frontmost app.
    case raw(KeyStroke, KeyPhase)

    /// Nil for `.raw` triggers, which have no semantic action.
    public var action: AgentAction? {
        switch self {
        case .press(let action), .down(let action), .up(let action): return action
        case .raw: return nil
        }
    }

    public var phase: KeyPhase {
        switch self {
        case .press: return .press
        case .down: return .down
        case .up: return .up
        case .raw(_, let phase): return phase
        }
    }
}

public extension ResolvedEvent {
    var phase: KeyPhase {
        switch self {
        case .keyDown: return .down
        case .keyUp: return .up
        case .gesture(.chordReleased): return .up
        case .gesture: return .press
        }
    }
}

/// Stable, human-writable identifiers for gestures, used as configuration keys.
///
/// ```text
/// up · down · left · right · a      base layer
/// b.tap · b.hold                    B released as a tap / after the hold threshold
/// b.up · b.down · b.left · b.right · b.a   chords
/// ```
public enum GestureID {
    /// Buttons that can act as a layer modifier. Only B does — A is a plain action button.
    public static let modifiers: [PhysicalButton] = [.b]

    public static func of(_ event: ResolvedEvent) -> String {
        switch event {
        case .keyDown(let button), .keyUp(let button):
            return button.rawValue
        case .gesture(.tap(let button)):
            return "\(button.rawValue).tap"
        case .gesture(.hold(let button)):
            return "\(button.rawValue).hold"
        case .gesture(.chord(let modifier, let key)), .gesture(.chordReleased(let modifier, let key)):
            // Start and end share one identifier, so a single override covers the whole gesture.
            return "\(modifier.rawValue).\(key.rawValue)"
        }
    }

    /// Every identifier the config may use — exactly the 11 gestures the hardware can produce.
    /// Handy for validation and for documenting the config surface.
    public static let all: [String] = {
        var ids = PhysicalButton.allCases
            .filter { !modifiers.contains($0) }
            .map(\.rawValue)
        for modifier in modifiers {
            ids.append("\(modifier.rawValue).tap")
            ids.append("\(modifier.rawValue).hold")
            for key in PhysicalButton.allCases where key != modifier {
                ids.append("\(modifier.rawValue).\(key.rawValue)")
            }
        }
        return ids
    }()
}

/// A keystroke a gesture sends directly, bypassing the semantic vocabulary.
public struct GestureOverride: Equatable, Sendable {
    public var stroke: KeyStroke
    /// Hold the stroke for the whole chord instead of tapping it.
    ///
    /// Only meaningful for **modifier-only** strokes, and only some targets want it: Doubao's voice
    /// input, for example, offers both "单击左option+左shift" (a tap) and "长按右option" (a hold).
    /// Ignored for strokes that have a key, where a tap is the only sensible reading.
    public var isHeld: Bool

    public init(stroke: KeyStroke, isHeld: Bool = false) {
        self.stroke = stroke
        self.isHeld = isHeld
    }

    public var holdsModifiersOnly: Bool { isHeld && stroke.isModifiersOnly }
}

public struct EventResolver: Sendable {
    public let bindings: GestureBindings
    /// Gesture identifier → keystroke. Takes precedence over the semantic binding for that gesture,
    /// which is how a user can point any gesture at any command without touching code.
    public let gestureOverrides: [String: GestureOverride]

    public init(bindings: GestureBindings = .default, gestureOverrides: [String: GestureOverride] = [:]) {
        self.bindings = bindings
        self.gestureOverrides = gestureOverrides
    }

    public func triggers(for event: ResolvedEvent) -> [ActionTrigger] {
        if let override = gestureOverrides[GestureID.of(event)] {
            let stroke = override.stroke
            if override.holdsModifiersOnly {
                // Held modifier-only binding: press on chord start, release when the chord ends.
                switch event {
                case .gesture(.chord): return [.raw(stroke, .down)]
                case .gesture(.chordReleased): return [.raw(stroke, .up)]
                default: break
                }
            }
            // Everything else is a tap. In particular a one-shot gesture ignores the release.
            if case .gesture(.chordReleased) = event { return [] }
            return [.raw(stroke, event.phase)]
        }

        switch event {
        case .keyDown(let button):
            guard let action = bindings.base[button] else { return [] }
            return [.down(action)]

        case .keyUp(let button):
            guard let action = bindings.base[button] else { return [] }
            return [.up(action)]

        case .gesture(.tap(let button)), .gesture(.hold(let button)):
            guard let action = bindings.base[button] else { return [] }
            return [.press(action)]

        case .gesture(.chord(_, let key)):
            guard let action = bindings.bLayer[key] else { return [] }
            return [.press(action)]

        case .gesture(.chordReleased):
            // Semantic actions are one-shot; only held bindings care about the release.
            return []
        }
    }

    public func triggers(for events: [ResolvedEvent]) -> [ActionTrigger] {
        events.flatMap { triggers(for: $0) }
    }
}
