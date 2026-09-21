import CoreGraphics
import Foundation

/// Modifier keys we may need to synthesise (spec §11.2).
///
/// Left and right are separate cases because some targets care: Doubao's voice input, for example,
/// distinguishes 长按**右**option from its left-hand shortcuts. The two sides share an event flag
/// but have different virtual key codes.
public enum ModifierKey: String, Codable, CaseIterable, Sendable {
    case shift
    case control
    case option
    case command
    case rightShift
    case rightControl
    case rightOption
    case rightCommand

    public var keyCode: CGKeyCode {
        switch self {
        case .shift: return 56
        case .control: return 59
        case .option: return 58
        case .command: return 55
        case .rightShift: return 60
        case .rightControl: return 62
        case .rightOption: return 61
        case .rightCommand: return 54
        }
    }

    public var eventFlag: CGEventFlags {
        switch self {
        case .shift, .rightShift: return .maskShift
        case .control, .rightControl: return .maskControl
        case .option, .rightOption: return .maskAlternate
        case .command, .rightCommand: return .maskCommand
        }
    }

    /// The flag-only view of this modifier, for the `event.flags` bitmask.
    public var side: Side {
        switch self {
        case .shift, .control, .option, .command: return .left
        case .rightShift, .rightControl, .rightOption, .rightCommand: return .right
        }
    }

    public enum Side: String, Sendable {
        case left
        case right
    }
}

/// A key we can emit. Virtual key codes are the ANSI positions on a US layout.
public enum Key: String, Codable, CaseIterable, Sendable {
    // Navigation / editing
    case upArrow, downArrow, leftArrow, rightArrow
    case enter, escape, tab, space
    case delete, forwardDelete

    // Letters
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z

    // Digits and punctuation (needed for command-palette style shortcuts)
    case digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9
    case minus, equal, leftBracket, rightBracket, backslash
    case semicolon, quote, comma, period, slash, grave

    /// Names a person would naturally type in the config, mapped onto the cases above.
    ///
    /// `digit1` is the case name, but nobody writes `{"key": "digit1"}` — they write `{"key": "1"}`.
    /// Failing that lookup would mean a hand-edited config silently refusing to load.
    private static let aliases: [String: Key] = [
        "0": .digit0, "1": .digit1, "2": .digit2, "3": .digit3, "4": .digit4,
        "5": .digit5, "6": .digit6, "7": .digit7, "8": .digit8, "9": .digit9,
        "-": .minus, "=": .equal, "+": .equal,
        "[": .leftBracket, "]": .rightBracket, "\\": .backslash,
        ";": .semicolon, "'": .quote, ",": .comma, ".": .period, "/": .slash, "`": .grave,
        "up": .upArrow, "down": .downArrow, "left": .leftArrow, "right": .rightArrow,
        "return": .enter, "esc": .escape, "spacebar": .space,
        "backspace": .delete, "del": .forwardDelete,
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let key = Key(rawValue: raw) {
            self = key
        } else if let key = Key.aliases[raw] {
            self = key
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown key \"\(raw)\"; use a letter, a digit, or one of \(Key.aliases.keys.sorted().joined(separator: " "))"
            )
        }
    }

    public var keyCode: CGKeyCode {
        switch self {
        case .upArrow: return 126
        case .downArrow: return 125
        case .leftArrow: return 123
        case .rightArrow: return 124
        case .enter: return 36
        case .escape: return 53
        case .tab: return 48
        case .space: return 49
        case .delete: return 51
        case .forwardDelete: return 117

        case .a: return 0
        case .s: return 1
        case .d: return 2
        case .f: return 3
        case .h: return 4
        case .g: return 5
        case .z: return 6
        case .x: return 7
        case .c: return 8
        case .v: return 9
        case .b: return 11
        case .q: return 12
        case .w: return 13
        case .e: return 14
        case .r: return 15
        case .y: return 16
        case .t: return 17
        case .digit1: return 18
        case .digit2: return 19
        case .digit3: return 20
        case .digit4: return 21
        case .digit6: return 22
        case .digit5: return 23
        case .equal: return 24
        case .digit9: return 25
        case .digit7: return 26
        case .minus: return 27
        case .digit8: return 28
        case .digit0: return 29
        case .rightBracket: return 30
        case .o: return 31
        case .u: return 32
        case .leftBracket: return 33
        case .i: return 34
        case .p: return 35
        case .l: return 37
        case .j: return 38
        case .quote: return 39
        case .k: return 40
        case .semicolon: return 41
        case .backslash: return 42
        case .comma: return 43
        case .slash: return 44
        case .n: return 45
        case .m: return 46
        case .period: return 47
        case .grave: return 50
        }
    }
}

/// A key plus the modifiers held while it is pressed — or, when `key` is nil, **modifiers alone**.
///
/// A modifier-only chord is a real thing (push-to-talk, sticky modifiers): nothing else is pressed,
/// but the modifier keys themselves are held down. `CGEventEmitter` treats a modifier-only stroke as
/// *held* rather than tapped, because a bare down-and-up of ⌥⇧ with no key is invisible to almost
/// every application.
public struct KeyStroke: Equatable, Hashable, Sendable {
    public var key: Key?
    public var modifiers: Set<ModifierKey>

    public init(_ key: Key, modifiers: Set<ModifierKey> = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// `key` may be nil, which means modifiers only.
    public init(key: Key?, modifiers: Set<ModifierKey> = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Modifiers only — no character key.
    public init(modifiers: Set<ModifierKey>) {
        self.key = nil
        self.modifiers = modifiers
    }

    public static func key(_ key: Key) -> KeyStroke { KeyStroke(key) }

    public var isModifiersOnly: Bool { key == nil }

    /// Whether this stroke can be expressed as a plain key press. Modifier-only strokes cannot:
    /// they have to be held and released.
    public var isHoldOnly: Bool { isModifiersOnly }
}
