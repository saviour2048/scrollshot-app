import Foundation
import AppKit
import CoreGraphics

/// A single keyboard remapping rule, e.g. "command + h → left arrow".
struct KeyMappingRule: Identifiable, Codable, Equatable {
    let id: UUID
    var isEnabled: Bool
    var fromKeyCode: Int
    var fromModifiers: KeyModifiers
    var toKeyCode: Int
    var toModifiers: KeyModifiers

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        fromKeyCode: Int,
        fromModifiers: KeyModifiers = [],
        toKeyCode: Int,
        toModifiers: KeyModifiers = []
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.fromKeyCode = fromKeyCode
        self.fromModifiers = fromModifiers
        self.toKeyCode = toKeyCode
        self.toModifiers = toModifiers
    }
}

/// Modifier flags stored independently of NSEvent/Apple's shifting raw values.
struct KeyModifiers: OptionSet, Codable, Equatable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let command = KeyModifiers(rawValue: 1 << 0)
    static let option   = KeyModifiers(rawValue: 1 << 1)
    static let control  = KeyModifiers(rawValue: 1 << 2)
    static let shift    = KeyModifiers(rawValue: 1 << 3)

    /// Convert from NSEvent.ModifierFlags observed in the event tap.
    init(_ nsFlags: NSEvent.ModifierFlags) {
        var result = KeyModifiers()
        if nsFlags.contains(.command) { result.insert(.command) }
        if nsFlags.contains(.option)   { result.insert(.option) }
        if nsFlags.contains(.control)  { result.insert(.control) }
        if nsFlags.contains(.shift)    { result.insert(.shift) }
        self = result
    }

    /// Convert from CGEventFlags (used by CGEventTap callbacks).
    init(_ cgFlags: CGEventFlags) {
        self.init(NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: cgFlags.rawValue)))
    }

    /// Convert to NSEvent.ModifierFlags for synthesized events.
    var nsFlags: NSEvent.ModifierFlags {
        var result = NSEvent.ModifierFlags()
        if contains(.command) { result.insert(.command) }
        if contains(.option)   { result.insert(.option) }
        if contains(.control)  { result.insert(.control) }
        if contains(.shift)    { result.insert(.shift) }
        return result
    }

    var cgFlags: CGEventFlags {
        var result = CGEventFlags()
        if contains(.command) { result.insert(.maskCommand) }
        if contains(.option)   { result.insert(.maskAlternate) }
        if contains(.control)  { result.insert(.maskControl) }
        if contains(.shift)    { result.insert(.maskShift) }
        return result
    }
}

// MARK: - Common key codes

enum KeyCode: Int, CaseIterable, Identifiable {
    case a = 0, s = 1, d = 2, f = 3, h = 4, g = 5, z = 6, x = 7, c = 8, v = 9
    case b = 11, q = 12, w = 13, e = 14, r = 15, y = 16, t = 17
    case one = 18, two = 19, three = 20, four = 21, six = 22, five = 23
    case equal = 24, nine = 25, seven = 26, minus = 27, eight = 28, zero = 29
    case rightBracket = 30, o = 31, u = 32, leftBracket = 33, i = 34, p = 35
    case returnKey = 36, l = 37, j = 38, quote = 39, k = 40, semicolon = 41
    case backslash = 42, comma = 43, slash = 44, n = 45, m = 46, period = 47
    case tab = 48, space = 49, grave = 50, delete = 51
    case escape = 53
    case leftCommand = 55, leftShift = 56, leftOption = 58, leftControl = 59
    case rightShift = 60, rightOption = 61, rightControl = 62, rightCommand = 54
    case f17 = 64, decimal = 65
    case f18 = 79, f19 = 80
    case f20 = 90
    case f5 = 96, f6 = 97, f7 = 98, f3 = 99, f8 = 100, f9 = 101, f11 = 103
    case f13 = 105, f16 = 106, f14 = 107
    case f10 = 109, f12 = 111, f15 = 113
    case help = 114, home = 115, pageUp = 116, forwardDelete = 117, f4 = 118
    case end = 119, f2 = 120, pageDown = 121, f1 = 122
    case leftArrow = 123, rightArrow = 124, downArrow = 125, upArrow = 126

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .a: return "A"; case .s: return "S"; case .d: return "D"; case .f: return "F"
        case .h: return "H"; case .g: return "G"; case .z: return "Z"; case .x: return "X"
        case .c: return "C"; case .v: return "V"; case .b: return "B"; case .q: return "Q"
        case .w: return "W"; case .e: return "E"; case .r: return "R"; case .y: return "Y"
        case .t: return "T"
        case .one: return "1"; case .two: return "2"; case .three: return "3"; case .four: return "4"
        case .six: return "6"; case .five: return "5"; case .equal: return "="; case .nine: return "9"
        case .seven: return "7"; case .minus: return "-"; case .eight: return "8"; case .zero: return "0"
        case .rightBracket: return "]"; case .o: return "O"; case .u: return "U"
        case .leftBracket: return "["; case .i: return "I"; case .p: return "P"
        case .returnKey: return "↩"
        case .l: return "L"; case .j: return "J"; case .quote: return "'"; case .k: return "K"
        case .semicolon: return ";"; case .backslash: return "\\"; case .comma: return ","
        case .slash: return "/"; case .n: return "N"; case .m: return "M"; case .period: return "."
        case .tab: return "⇥"; case .space: return "Space"; case .grave: return "`"
        case .delete: return "⌫"; case .escape: return "Esc"
        case .leftCommand: return "Left ⌘"; case .leftShift: return "Left ⇧"
        case .leftOption: return "Left ⌥"; case .leftControl: return "Left ⌃"
        case .rightShift: return "Right ⇧"; case .rightOption: return "Right ⌥"
        case .rightControl: return "Right ⌃"; case .rightCommand: return "Right ⌘"
        case .f17: return "F17"; case .decimal: return "."
        case .f18: return "F18"; case .f19: return "F19"; case .f20: return "F20"
        case .f5: return "F5"; case .f6: return "F6"; case .f7: return "F7"; case .f3: return "F3"
        case .f8: return "F8"; case .f9: return "F9"; case .f11: return "F11"
        case .f13: return "F13"; case .f16: return "F16"; case .f14: return "F14"
        case .f10: return "F10"; case .f12: return "F12"; case .f15: return "F15"
        case .help: return "Help"; case .home: return "Home"; case .pageUp: return "Page Up"
        case .forwardDelete: return "Del"; case .f4: return "F4"; case .end: return "End"
        case .f2: return "F2"; case .pageDown: return "Page Down"; case .f1: return "F1"
        case .leftArrow: return "←"; case .rightArrow: return "→"
        case .downArrow: return "↓"; case .upArrow: return "↑"
        }
    }

    static func name(for keyCode: Int) -> String {
        KeyCode(rawValue: keyCode)?.displayName ?? "Key \(keyCode)"
    }
}

// MARK: - Presets

extension KeyMappingRule {
    /// The classic Vim-style arrow-key mapping: command + hjkl → arrow keys.
    static let vimArrowPresets: [KeyMappingRule] = [
        KeyMappingRule(fromKeyCode: KeyCode.h.rawValue, fromModifiers: .command,
                       toKeyCode: KeyCode.leftArrow.rawValue),
        KeyMappingRule(fromKeyCode: KeyCode.j.rawValue, fromModifiers: .command,
                       toKeyCode: KeyCode.downArrow.rawValue),
        KeyMappingRule(fromKeyCode: KeyCode.k.rawValue, fromModifiers: .command,
                       toKeyCode: KeyCode.upArrow.rawValue),
        KeyMappingRule(fromKeyCode: KeyCode.l.rawValue, fromModifiers: .command,
                       toKeyCode: KeyCode.rightArrow.rawValue),
    ]
}
