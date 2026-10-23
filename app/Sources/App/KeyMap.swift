import Foundation

/// A key or chord (`Enter`, `ArrowDown`, `Meta+a`) as the DevTools `Input.dispatchKeyEvent`
/// method wants it.
struct KeyPress {
    /// The `modifiers` bit mask: Alt 1, Control 2, Meta (Command) 4, Shift 8.
    var modifiers: Int
    var key: String
    var code: String
    var keyCode: Int
    /// The character the key types, when it types one and no Control or Meta is held.
    var text: String?
    /// macOS editing commands a Command chord stands for (`selectAll`, `copy`, ...), which the
    /// page only runs when the event names them.
    var commands: [String]

    enum ParseError: Error, CustomStringConvertible {
        case unknown(String)
        var description: String {
            switch self {
            case .unknown(let name): return "the browser does not know the key \"\(name)\""
            }
        }
    }

    private static let named: [String: (code: String, keyCode: Int, text: String?)] = [
        "Enter": ("Enter", 13, "\r"),
        "Tab": ("Tab", 9, "\t"),
        "Escape": ("Escape", 27, nil),
        "Backspace": ("Backspace", 8, nil),
        "Delete": ("Delete", 46, nil),
        "Space": ("Space", 32, " "),
        "ArrowLeft": ("ArrowLeft", 37, nil),
        "ArrowUp": ("ArrowUp", 38, nil),
        "ArrowRight": ("ArrowRight", 39, nil),
        "ArrowDown": ("ArrowDown", 40, nil),
        "Home": ("Home", 36, nil),
        "End": ("End", 35, nil),
        "PageUp": ("PageUp", 33, nil),
        "PageDown": ("PageDown", 34, nil),
    ]

    private static let aliases: [String: String] = [
        "return": "Enter", "esc": "Escape", "del": "Delete", " ": "Space", "space": "Space",
        "left": "ArrowLeft", "right": "ArrowRight", "up": "ArrowUp", "down": "ArrowDown",
        "pgup": "PageUp", "pgdn": "PageDown",
    ]

    private static let modifierBits: [String: Int] = [
        "alt": 1, "option": 1,
        "control": 2, "ctrl": 2,
        "meta": 4, "command": 4, "cmd": 4, "controlormeta": 4,
        "shift": 8,
    ]

    /// The key codes of the punctuation keys of a US keyboard, unshifted.
    private static let punctuation: [String: Int] = [
        ";": 186, "=": 187, ",": 188, "-": 189, ".": 190, "/": 191, "`": 192,
        "[": 219, "\\": 220, "]": 221, "'": 222,
    ]

    private static let editingCommands: [String: String] = [
        "a": "selectAll", "c": "copy", "v": "paste", "x": "cut", "z": "undo",
    ]

    /// Parses one key or chord: modifiers and a key joined by `+`.
    static func parse(_ text: String) throws -> KeyPress {
        var parts = text.components(separatedBy: "+")
        // A lone "+" key is written "+", which splits into two empty parts.
        if text == "+" { parts = ["+"] }
        else if text.hasSuffix("++") { parts = Array(text.dropLast(2).components(separatedBy: "+")) + ["+"] }

        guard let last = parts.last, !last.isEmpty else { throw ParseError.unknown(text) }
        var modifiers = 0
        for part in parts.dropLast() {
            guard let bit = modifierBits[part.lowercased()] else { throw ParseError.unknown(part) }
            modifiers |= bit
        }

        let name = aliases[last.lowercased()] ?? last
        if let entry = named[name] {
            return KeyPress(modifiers: modifiers, key: name, code: entry.code, keyCode: entry.keyCode,
                            text: modifiers & 6 == 0 ? entry.text : nil, commands: [])
        }

        guard last.count == 1, let scalar = last.unicodeScalars.first else { throw ParseError.unknown(last) }
        let character = String(last)
        let upper = character.uppercased()
        let isLetter = scalar.properties.isAlphabetic && scalar.isASCII
        let isDigit = ("0"..."9").contains(character)
        let code = isLetter ? "Key\(upper)" : isDigit ? "Digit\(character)" : ""
        // A letter or digit's key code is its capital's character code. Punctuation has its own
        // codes (the ASCII value of "." is the code of the Delete key), and a symbol that needs
        // Shift gets 0: the page is sent the character, which is what it types.
        let keyCode = (isLetter || isDigit) ? Int(upper.unicodeScalars.first!.value) : (punctuation[character] ?? 0)
        let shifted = modifiers & 8 != 0
        let typed = shifted && isLetter ? upper : character
        // Control and Meta chords type nothing; Meta chords may be a macOS editing command.
        let types = modifiers & 6 == 0
        var commands: [String] = []
        if modifiers == 4, let command = editingCommands[character.lowercased()] { commands = [command] }
        if modifiers == 12, character.lowercased() == "z" { commands = ["redo"] }
        return KeyPress(modifiers: modifiers, key: typed, code: code, keyCode: keyCode,
                        text: types ? typed : nil, commands: commands)
    }

    /// The `Input.dispatchKeyEvent` parameters for the press and the release.
    func events() -> [[String: Any]] {
        var down: [String: Any] = [
            "type": text == nil ? "rawKeyDown" : "keyDown",
            "modifiers": modifiers,
            "key": key,
            "windowsVirtualKeyCode": keyCode,
            "nativeVirtualKeyCode": keyCode,
        ]
        if !code.isEmpty { down["code"] = code }
        if let text { down["text"] = text; down["unmodifiedText"] = text }
        if !commands.isEmpty { down["commands"] = commands }

        var up: [String: Any] = [
            "type": "keyUp",
            "modifiers": modifiers,
            "key": key,
            "windowsVirtualKeyCode": keyCode,
            "nativeVirtualKeyCode": keyCode,
        ]
        if !code.isEmpty { up["code"] = code }
        return [down, up]
    }
}
