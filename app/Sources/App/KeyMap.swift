import CoreGraphics
import Foundation

/// A key or chord (`Enter`, `ArrowDown`, `Meta+a`) as the keyboard sends it: a macOS virtual
/// key code of the US layout, the modifier flags held, and the characters it types.
struct KeyPress {
    var flags: CGEventFlags
    var keyCode: CGKeyCode
    /// The character the key types, when it types one and no Control or Command is held.
    var text: String?

    enum ParseError: Error, CustomStringConvertible {
        case unknown(String)
        case forbidden(String)
        var description: String {
            switch self {
            case .unknown(let name): return "the browser does not know the key \"\(name)\""
            case .forbidden(let name): return "the chord \"\(name)\" belongs to the system, not the page"
            }
        }
    }

    /// The modifier keys, as the keys themselves (to hold them) and as event flags.
    static let shiftKey: CGKeyCode = 56
    static let controlKey: CGKeyCode = 59
    static let optionKey: CGKeyCode = 58
    static let commandKey: CGKeyCode = 55

    private static let named: [String: (keyCode: CGKeyCode, text: String?)] = [
        "Enter": (36, "\r"),
        "Tab": (48, "\t"),
        "Escape": (53, nil),
        "Backspace": (51, nil),
        "Delete": (117, nil),
        "Space": (49, " "),
        "ArrowLeft": (123, nil),
        "ArrowUp": (126, nil),
        "ArrowRight": (124, nil),
        "ArrowDown": (125, nil),
        "Home": (115, nil),
        "End": (119, nil),
        "PageUp": (116, nil),
        "PageDown": (121, nil),
        "F1": (122, nil), "F2": (120, nil), "F3": (99, nil), "F4": (118, nil),
        "F5": (96, nil), "F6": (97, nil), "F7": (98, nil), "F8": (100, nil),
        "F9": (101, nil), "F10": (109, nil), "F11": (103, nil), "F12": (111, nil),
    ]

    private static let aliases: [String: String] = [
        "return": "Enter", "enter": "Enter", "esc": "Escape", "escape": "Escape", "del": "Delete",
        "delete": "Delete", "backspace": "Backspace", " ": "Space", "space": "Space", "tab": "Tab",
        "left": "ArrowLeft", "right": "ArrowRight", "up": "ArrowUp", "down": "ArrowDown",
        "arrowleft": "ArrowLeft", "arrowright": "ArrowRight", "arrowup": "ArrowUp", "arrowdown": "ArrowDown",
        "pgup": "PageUp", "pgdn": "PageDown", "pageup": "PageUp", "pagedown": "PageDown",
        "home": "Home", "end": "End",
    ]

    private static let modifierFlags: [String: CGEventFlags] = [
        "alt": .maskAlternate, "option": .maskAlternate,
        "control": .maskControl, "ctrl": .maskControl,
        "meta": .maskCommand, "command": .maskCommand, "cmd": .maskCommand, "controlormeta": .maskCommand,
        "shift": .maskShift,
    ]

    /// The key codes of the US layout for the characters typed without Shift.
    private static let plain: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "`": 50,
    ]

    /// The characters typed with Shift, by the character of the same key without it.
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".",
        "?": "/", "~": "`",
    ]

    /// Chords the system takes before the page does, and that would end or hide the browser.
    private static let forbidden: Set<String> = [
        "Meta+q", "Meta+w", "Meta+h", "Meta+m", "Meta+Tab", "Meta+Space", "Control+Meta+q",
        "Shift+Meta+q", "Alt+Meta+Escape", "Alt+Meta+h", "Alt+Meta+m", "Alt+Meta+w",
    ]

    /// Parses one key or chord: modifiers and a key joined by `+`.
    static func parse(_ text: String) throws -> KeyPress {
        var parts = text.components(separatedBy: "+")
        // A lone "+" key is written "+", which splits into two empty parts.
        if text == "+" { parts = ["+"] }
        else if text.hasSuffix("++") { parts = Array(text.dropLast(2).components(separatedBy: "+")) + ["+"] }

        guard let last = parts.last, !last.isEmpty else { throw ParseError.unknown(text) }
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            guard let flag = modifierFlags[part.lowercased()] else { throw ParseError.unknown(part) }
            flags.insert(flag)
        }

        let name = aliases[last.lowercased()] ?? last
        let press: KeyPress
        if let entry = named[name] {
            press = KeyPress(flags: flags, keyCode: entry.keyCode, text: entry.text)
        } else {
            guard last.count == 1, let character = last.first else { throw ParseError.unknown(last) }
            press = try KeyPress(character: character, flags: flags)
        }
        if forbidden.contains(press.chordName(key: named[name] != nil ? name : String(last).lowercased())) {
            throw ParseError.forbidden(text)
        }
        return press
    }

    init(flags: CGEventFlags, keyCode: CGKeyCode, text: String?) {
        self.flags = flags
        self.keyCode = keyCode
        self.text = text
    }

    /// The press that types one character of the US layout, with the flags held meanwhile.
    init(character: Character, flags: CGEventFlags = []) throws {
        var flags = flags
        let base: Character
        if character.isASCII && character.isUppercase {
            base = Character(character.lowercased())
            flags.insert(.maskShift)
        } else if let unshifted = Self.shifted[character] {
            base = unshifted
            flags.insert(.maskShift)
        } else {
            base = character
        }
        guard let keyCode = Self.plain[base] else { throw ParseError.unknown(String(character)) }
        self.flags = flags
        self.keyCode = keyCode
        // Control and Command chords type nothing.
        let types = flags.isDisjoint(with: [.maskControl, .maskCommand])
        self.text = types ? String(character) : nil
    }

    /// Whether a character is one a US keyboard types with one key (and Shift).
    static func types(_ character: Character) -> Bool {
        (try? KeyPress(character: character)) != nil
    }

    /// The flags for held keys named as the harness writes them: "Shift+Meta".
    static func flags(named text: String) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for part in text.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            guard let flag = modifierFlags[part.lowercased()] else { throw ParseError.unknown(part) }
            flags.insert(flag)
        }
        return flags
    }

    /// The flag a modifier key sets while it is down.
    static func flag(of key: CGKeyCode) -> CGEventFlags {
        switch key {
        case shiftKey: return .maskShift
        case controlKey: return .maskControl
        case optionKey: return .maskAlternate
        case commandKey: return .maskCommand
        default: return []
        }
    }

    /// The modifier keys that make up the flags, to press before and release after.
    static func modifierKeys(_ flags: CGEventFlags) -> [CGKeyCode] {
        var keys: [CGKeyCode] = []
        if flags.contains(.maskShift) { keys.append(shiftKey) }
        if flags.contains(.maskControl) { keys.append(controlKey) }
        if flags.contains(.maskAlternate) { keys.append(optionKey) }
        if flags.contains(.maskCommand) { keys.append(commandKey) }
        return keys
    }

    /// The chord in one spelling, to compare with the forbidden ones.
    private func chordName(key: String) -> String {
        var parts: [String] = []
        if flags.contains(.maskShift) { parts.append("Shift") }
        if flags.contains(.maskControl) { parts.append("Control") }
        if flags.contains(.maskAlternate) { parts.append("Alt") }
        if flags.contains(.maskCommand) { parts.append("Meta") }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}
