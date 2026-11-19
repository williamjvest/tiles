import Foundation
import Testing
@testable import CameraCore

/// Tiles never formats, erases or initializes a camera's media, and there's no code for it anywhere in the repository:
/// not the app, its Control API, a camera backend, the Stream Deck plugin, the Companion module, nor the tools in
/// scripts/. This test reads every source file and fails on anything that reads like such a command, so the claim stays
/// true as the code changes. The tools' raw paths turn such names away (`MediaSafety`, and NEVER in the scripts).
@Suite("No media formatting")
struct NoMediaFormattingTests {
    /// What a format, erase or initialize command for media looks like in code or a comment.
    static let forbidden = [
        #"(?i)\bformat(ting|s)?\s+(the\s+|a\s+)?(media|card|cards|slot|slots|disk|disks|drive|drives|storage|sd|ssd|axs|cfexpress)\b"#,
        #"(?i)\b(media|card|slot|disk|drive|storage)\s+format(ting)?\b"#,
        #"(?i)do_?format|format_?media|media_?format|format_?card|format_?slot"#,
        #"(?i)(erase|initiali[sz]e)_?(the_?)?(media|card|slot|disk|drive|storage)"#,
        #"(?i)storage\.(drive|media)\.format|format\.request"#,
    ]

    /// A line that reads like one. This test's own name, which the code points to, doesn't count.
    static func caught(_ line: String) -> Bool {
        let line = line.replacingOccurrences(of: "NoMediaFormatting", with: "")
        let lower = line.lowercased()
        guard lower.contains("format") || lower.contains("erase") || lower.contains("initiali") else { return false }
        return forbidden.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // Packages/CameraKit
        .deletingLastPathComponent().deletingLastPathComponent()                              // the repository

    /// Every source file: Swift, TypeScript and JavaScript, Python, shell and C, outside build output and dependencies.
    static func sourceFiles() -> [URL] {
        let places = ["Packages/CameraKit/Sources", "Packages/CameraKit/Tests", "App", "integrations/streamdeck/src",
                      "integrations/companion-module/src", "integrations/companion-module/tests", "scripts"]
        let kinds: Set<String> = ["swift", "ts", "js", "mjs", "py", "sh", "c", "command"]
        let skipped: Set<String> = ["node_modules", ".build", "dist", "__pycache__", "bin"]
        var files: [URL] = []
        for place in places {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(place),
                                                              includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for case let url as URL in walker {
                if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                if kinds.contains(url.pathExtension) { files.append(url) }
            }
        }
        return files
    }

    @Test("Nothing in the repository formats, erases or initialises media")
    func noneInTheCode() throws {
        let files = Self.sourceFiles()
        #expect(files.count > 200, "found only \(files.count) source files: the walk is wrong")
        var hits: [String] = []
        for file in files where file.lastPathComponent != "NoMediaFormattingTests.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated()
            where Self.caught(line) {
                hits.append("\(file.path.replacingOccurrences(of: Self.root.path + "/", with: "")):\(number + 1): "
                            + line.trimmingCharacters(in: .whitespaces).prefix(120))
            }
        }
        #expect(hits.isEmpty, "media formatting in the code:\n\(hits.joined(separator: "\n"))")
    }

    @Test("The patterns catch what they're for, and leave recording formats alone")
    func patterns() {
        func caught(_ line: String) -> Bool { Self.caught(line) }
        for bad in ["formatMedia(slot: 1)", "PUT /media/devices/A001/doformat", "format the card", "eraseMedia()",
                    "Storage.Drive.Format", "case mediaFormat = 0xD2C9", "// Format media in slot A"] {
            #expect(caught(bad), "\(bad)")
        }
        for fine in ["setFileFormat(\"XAVC\")", "P.Clip.Mediabox.Video.Format.FrameRate", "recordingFormat",
                     "Clip Name Format", "String(format: \"%02d\", n)", "/system/format", "AxsRecformatSelect",
                     "OutputFormat.Info.Sdi34", "Type-erased Codable"] {
            #expect(!caught(fine), "\(fine)")
        }
    }

    @Test("The tools' raw paths turn away anything named like format, erase or initialise")
    func rawPathsRefuse() {
        for name in ["Storage.Drive.Format", "Process.Execute [\"Storage.Media.Format.Request\"]", "EraseAll",
                     "InitializeMedia", "media.initialise"] {
            #expect(MediaSafety.refuses(name), "\(name)")
        }
        for name in ["Camera.Gain.ExposureIndex.Value=800EI", "Rec", "P.System.Menu.MarkerAUserBoxOnoff=\"1\""] {
            #expect(!MediaSafety.refuses(name), "\(name)")
        }
    }
}
