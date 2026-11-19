import CoreGraphics
import Testing
@testable import DashboardUI

/// A tile's one line gives way in priority order: the value wins over the caption. Widths are caption, content, switches.
@Suite("One-line row")
struct OneLineRowTests {
    private func split(room: CGFloat, caption: CGFloat = 60, content: CGFloat = 40, flexible: Bool = true,
                       switches: CGFloat = 64, least: CGFloat = 30) -> [CGFloat] {
        OneLineRow.split(room: room, caption: caption, content: content,
                         contentMost: flexible ? room : content, switches: switches, switchesLeast: least)
    }

    @Test("Everything at its own width where it fits, the content taking the rest as an HStack gave it")
    func allFit() {
        #expect(split(room: 200) == [60, 76, 64])
        #expect(split(room: 200, flexible: false) == [60, 40, 64], "content that doesn't stretch keeps its width")
    }

    @Test("Then the value's type gives a little, the caption still whole")
    func valueGivesALittle() {
        // 60 + 34 (85 % of 40) + 64 = 158
        #expect(split(room: 160) == [60, 36, 64])
    }

    @Test("Then the switches give way, to a chip, the caption whole and the value as whole as it can be")
    func switchesGiveWay() {
        #expect(split(room: 150) == [60, 40, 50])
        #expect(split(room: 130) == [60, 40, 30])
        #expect(split(room: 124) == [60, 34, 30])
    }

    @Test("Then the caption gives way whole, never cut to a few letters; the switches stay a chip")
    func captionGivesWay() {
        // 60 + 34 + 30 = 124 doesn't fit in 110: the caption goes, the value takes its room.
        #expect(split(room: 110) == [0, 80, 30])
        #expect(split(room: 98) == [0, 68, 30])
        #expect(split(room: 110, flexible: false) == [0, 80, 30], "a value that doesn't stretch leaves the room unused")
    }

    @Test("And only then does the value shrink further")
    func valueShrinksLast() {
        #expect(split(room: 60) == [0, 30, 30])
        #expect(split(room: 20) == [0, 0, 30], "never below nothing")
    }

    @Test("A line without switches gives none, and a short caption goes whole too rather than squeezing the value")
    func shortCaptionNoSwitches() {
        #expect(split(room: 70, caption: 20, switches: 0, least: 0) == [20, 50, 0])
        #expect(split(room: 50, caption: 20, content: 60, switches: 0, least: 0) == [0, 50, 0])
    }
}
