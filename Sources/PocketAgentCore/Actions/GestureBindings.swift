import Foundation

/// Maps gestures to semantic actions (spec §6.1/§6.2/§13).
public struct GestureBindings: Equatable, Sendable {
    /// Base layer: directions and A behave normally when B is not down.
    public var base: [PhysicalButton: AgentAction]
    /// B layer: the key that, pressed while B is held, produces this action.
    public var bLayer: [PhysicalButton: AgentAction]
    /// What releasing B *after the hold threshold* means.
    ///
    /// B has always produced two different gestures from one button — `b.tap` and `b.hold` — but
    /// both used to resolve through `base[.b]`. This field splits them, so a long press can mean
    /// something other than a tap without the recognizer changing at all. It is nil-safe: leaving
    /// it unset falls back to `base[.b]`, which is the previous behaviour.
    public var bHold: AgentAction?

    public init(
        base: [PhysicalButton: AgentAction],
        bLayer: [PhysicalButton: AgentAction],
        bHold: AgentAction? = nil
    ) {
        self.base = base
        self.bLayer = bLayer
        self.bHold = bHold
    }

    /// Default map. Base layer is universal navigation; the B layer mixes two things the user asked
    /// for: jumping to the two most recent chats, and the three commands worth a permanent slot.
    ///
    /// History: an all-chat-jump B layer (six slots) was tried first and rejected as too many
    /// (2026-09-16) — two recent chats turned out to be the useful number.
    ///
    /// `b.hold` became "focus the other agent" on 2026-09-16 at the user's request: the goal is to
    /// drive both apps without ever reaching for the keyboard, and with twelve gestures already
    /// spoken for, holding B was the only slot that cost no other function. It changes the approval
    /// flow — a long press of B used to mean "decline", and is now a cross-app jump, so declining
    /// is a tap. That trade was made deliberately, not by omission.
    ///
    /// `b.left` became "open the menu" in the same session, for the opposite reason: the gesture set
    /// is full, so the way to add more commands is not more chords but a visible list. `newChat`
    /// moved from this slot to the menu's first row, which costs one extra press and buys room for
    /// every command that would otherwise need its own gesture.
    ///
    /// `b.hold` changed again on 2026-09-18, from the two-app toggle to the **app switcher**: the
    /// same strip-of-icons idea as ⌘⇥, driven by ←/→ and confirmed with A. The highlight starts on
    /// the previous app, so "hold B, A" is still a one-gesture jump back — the old toggle survives
    /// as a special case — while any other running app is a few presses of → away.
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
            .left: .openMenu,                  // the menu itself; 新建会话 is its first row
            .right: .nextChatNeedingAttention, // ⌥⌘A — whichever agent wants you
            .a: .deleteBackward,               // ⌫ — fix a misheard word after voice input (2026-09-21)
        ],
        bHold: .openAppSwitcher
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
        case .gesture(.holdBegan(let button)), .gesture(.holdEnded(let button)):
            // Same trick for single-button holds: `a.hold` covers the whole press.
            return "\(button.rawValue).hold"
        }
    }

    /// Every identifier the config may use: `up`/`down`/`left`/`right`/`a`, then `b.tap`, `b.hold`,
    /// the four B chords, and `a.hold` (push-to-talk on one button).
    /// Handy for validation and for documenting the config surface.
    /// Buttons that are both a one-shot action and a hold gesture. `a` is the only one: held, it is
    /// push-to-talk instead of `submit`.
    public static let holdableButtons: [PhysicalButton] = [.a]

    public static let all: [String] = {
        var ids = PhysicalButton.allCases
            .filter { !modifiers.contains($0) }
            .map(\.rawValue)
        for button in holdableButtons {
            ids.append("\(button.rawValue).hold")
        }
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

/// Resolves recognizer events into triggers.
///
/// This is a **value type with no history on purpose**: the same resolver can be handed a different
/// override table between a press and its release (that is exactly what happens when the frontmost
/// app changes, the profile switches, or the config is reloaded). Deciding what a *start* event
/// means and what its *end* means are therefore two separate calls — `pressTriggers` and
/// `releaseTriggers` — so the caller can hold the table from the start across to the end. A single
/// entry point that resolved both from "the current table" is what used to lose the release.
public struct EventResolver: Sendable {
    public let bindings: GestureBindings
    /// Gesture identifier → keystroke. Takes precedence over the semantic binding for that gesture,
    /// which is how a user can point any gesture at any command without touching code.
    public let gestureOverrides: [String: GestureOverride]

    public init(
        bindings: GestureBindings = .default,
        gestureOverrides: [String: GestureOverride] = [:]
    ) {
        self.bindings = bindings
        self.gestureOverrides = gestureOverrides
    }

    /// Triggers for anything that is not the end of a gesture.
    ///
    /// `overrides` is consulted instead of `gestureOverrides` so the caller can pass the table it
    /// froze when the gesture started.
    public func pressTriggers(
        for event: ResolvedEvent,
        overrides: [String: GestureOverride]? = nil
    ) -> [ActionTrigger] {
        let table = overrides ?? gestureOverrides

        if let override = table[GestureID.of(event)] {
            let stroke = override.stroke
            if override.holdsModifiersOnly {
                // Held modifier-only binding: press when the gesture starts, release when it ends —
                // whether that is a chord (`b.a`) or one button held down (`a.hold`).
                switch event {
                case .gesture(.chord), .gesture(.holdBegan): return [.raw(stroke, .down)]
                case .gesture(.chordReleased), .gesture(.holdEnded): return [.raw(stroke, .up)]
                default: break
                }
            }
            // Everything else is a tap. In particular a one-shot gesture ignores the release.
            switch event {
            case .gesture(.chordReleased), .gesture(.holdEnded):
                return []
            default:
                return [.raw(stroke, event.phase)]
            }
        }

        switch event {
        case .keyDown(let button):
            guard let action = bindings.base[button] else { return [] }
            return [.down(action)]

        case .keyUp(let button):
            guard let action = bindings.base[button] else { return [] }
            return [.up(action)]

        case .gesture(.tap(let button)), .gesture(.hold(let button)):
            // B is the only button with two gestures on one press, and they may mean different
            // things: `bHold` overrides the base binding for the hold gesture only. A tap is
            // unaffected, which is what keeps "tap B = Escape" intact.
            if button == .b, case .gesture(.hold(.b)) = event, let holdAction = bindings.bHold {
                return [.press(holdAction)]
            }
            guard let action = bindings.base[button] else { return [] }
            return [.press(action)]

        case .gesture(.chord(_, let key)):
            guard let action = bindings.bLayer[key] else { return [] }
            // A repeatable action is *held* for the life of the chord, exactly like a base-layer
            // direction: key down now, key up when the chord ends (see `chordReleased` below).
            // Everything else on the B layer is a one-shot jump or command.
            return action.allowsRepeat ? [.down(action)] : [.press(action)]

        case .gesture(.holdBegan):
            // A hold gesture is a *binding* gesture, never a semantic action: it starts a held key,
            // so it is resolved only through `gestureOverrides`.
            return []

        case .gesture(.chordReleased(_, let key)):
            // Only a held B-layer action has anything to release.
            guard let action = bindings.bLayer[key], action.allowsRepeat else { return [] }
            return [.up(action)]

        case .gesture(.holdEnded):
            // Semantic actions are one-shot; only held bindings care about the release.
            return []
        }
    }

    /// Triggers for the end of a gesture — currently only `chordReleased`, which exists to finish a
    /// held binding.
    ///
    /// Deliberately *not* routed through the semantic path: a chord that ended must be released with
    /// the binding that started it, never with a fresh lookup. This is where a profile switch during
    /// push-to-talk used to strand the modifier key down.
    public func releaseTriggers(
        for event: ResolvedEvent,
        overrides: [String: GestureOverride]? = nil
    ) -> [ActionTrigger] {
        let isRelease: Bool
        switch event {
        case .gesture(.chordReleased), .gesture(.holdEnded): isRelease = true
        default: isRelease = false
        }
        guard isRelease else {
            return pressTriggers(for: event, overrides: overrides)
        }

        let table = overrides ?? gestureOverrides
        if let override = table[GestureID.of(event)] {
            // An override owns the whole gesture: a held modifier-only one is released here, a
            // tap-style one was sent in full on the press and has nothing to release. Either way the
            // semantic binding underneath must not get a say — it would key-up something that never
            // went down.
            return override.holdsModifiersOnly ? [.raw(override.stroke, .up)] : []
        }
        // No override (or it started before this table existed). A held B-layer *action* still
        // needs its key up; a one-shot one has nothing to release.
        if case .gesture(.chordReleased(_, let key)) = event,
           let action = bindings.bLayer[key], action.allowsRepeat {
            return [.up(action)]
        }
        return []
    }

    public func triggers(for event: ResolvedEvent) -> [ActionTrigger] {
        pressTriggers(for: event)
    }

    public func triggers(for events: [ResolvedEvent]) -> [ActionTrigger] {
        events.flatMap { triggers(for: $0) }
    }
}
