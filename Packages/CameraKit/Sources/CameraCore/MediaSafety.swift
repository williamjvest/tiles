import Foundation

/// Tiles never formats, erases or initializes a camera's media. The app has no command for it, nor does its Control
/// API, nor any camera backend. The command-line tools' raw paths, which take a property, method or key by name, turn
/// away any name that says it: this is that check. `NoMediaFormattingTests` keeps the rest of the code base free of it.
public enum MediaSafety {
    /// Whether a raw name (a property, a method, a key, a command and its arguments) reads like formatting, erasing or
    /// initializing. Deliberately broad: a recording-format property is turned away too, and goes through the named
    /// commands instead.
    public static func refuses(_ text: String) -> Bool {
        text.range(of: #"format|erase|initiali[sz]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What a tool prints when it turns one away.
    public static func refusal(_ text: String) -> String {
        "refused: \(text) — Tiles' tools send nothing named like format, erase or initialise"
    }
}
