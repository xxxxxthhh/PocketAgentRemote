import CoreGraphics
import Foundation

/// Modifier keys we may need to synthesise (spec §11.2).
public enum ModifierKey: String, Codable, CaseIterable, Sendable {
    case shift
    case control
    case option
    case command

    public var keyCode: CGKeyCode {
        switch self {
        case .shift: return 56
        case .control: return 59
        case .option: return 58
        case .command: return 55
        }
    }

    public var eventFlag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        }
    }
}

/// A key we can emit. Virtual key codes are the ANSI positions on a US layout.
public enum Key: String, Codable, CaseIterable, Sendable {
    // Navigation / editing
    case upArrow, downArrow, leftArrow, rightArrow
    case enter, escape, tab, space

    // Letters
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z

    // Digits and punctuation (needed for command-palette style shortcuts)
    case digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9
    case minus, equal, leftBracket, rightBracket, backslash
    case semicolon, quote, comma, period, slash, grave

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

/// A key plus the modifiers held while it is pressed.
public struct KeyStroke: Equatable, Hashable, Sendable {
    public var key: Key
    public var modifiers: Set<ModifierKey>

    public init(_ key: Key, modifiers: Set<ModifierKey> = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func key(_ key: Key) -> KeyStroke { KeyStroke(key) }
}
