// The Clips window's list (`PlaybackState.clipListing`) and the stepping that takes an FX5, a VENICE or an ALEXA to a
// clip picked from it (`ClipStepper`).

import Testing
import Foundation
@testable import CameraCore

@Suite("Clip list")
struct ClipListTests {
    @Test("The camera's own list where it gives one; else one per clip it numbers, the open one named; else none")
    func listing() {
        var pb = PlaybackState(clipName: "A001C003", clipNumber: 3, clipCount: 4,
                               capabilities: PlaybackCapabilities(playPause: true, stop: true, nextPrevious: true, seek: false,
                                                                  fastForwardRewind: false, recReview: false, review: true,
                                                                  goToClip: true))
        #expect(pb.clipListing?.map(\.id) == [0, 1, 2, 3])
        #expect(pb.clipListing?.map(\.name) == [nil, nil, "A001C003", nil])
        pb.clips = [PlaybackClip(id: 0, name: "A001_C001", seconds: 10), PlaybackClip(id: 1, name: "A001_C002")]
        #expect(pb.clipListing == pb.clips, "a Blackmagic camera's, named from its files")
        pb.clips = nil
        pb.clipCount = nil
        #expect(pb.clipListing == nil, "an FX5 on the live picture: it numbers its takes only in Playback")
        pb.clipCount = 4
        pb.capabilities.goToClip = false
        #expect(pb.clipListing == nil, "a camera that can't be sent to a clip has no list to pick from")
    }

    @Test("Offered as a tile where the camera plays a picked clip")
    func offered() {
        var state = CameraState()
        state.playback = PlaybackState(capabilities: PlaybackCapabilities())
        #expect(!state.offers(.clips))
        state.playback?.capabilities.goToClip = true
        #expect(state.offers(.clips))
    }

    /// A camera's clips as the stepper sees them: the one open, how many, and which way a press goes.
    actor Clips {
        var at: Int
        let total: Int
        /// Next goes to the clip numbered lower, as a camera numbering its newest first might.
        let reversed: Bool
        /// Presses it ignores before it moves (a Prev mid-clip going to the clip's start).
        var ignored: Int
        /// How far the first press that moves goes: a camera that skips past.
        var firstJump = 1
        var presses: [Bool] = []
        var live = false

        init(at: Int, of total: Int, reversed: Bool = false, ignoring ignored: Int = 0) {
            self.at = at
            self.total = total
            self.reversed = reversed
            self.ignored = ignored
        }

        func press(_ forward: Bool) {
            presses.append(forward)
            if ignored > 0 { ignored -= 1; return }
            at = min(max(at + (forward != reversed ? firstJump : -firstJump), 1), total)
            firstJump = 1
        }

        func jumping(_ clips: Int) { firstJump = clips }

        func read() -> (number: Int, total: Int)? { live ? nil : (at, total) }
        func leave() { live = true }
    }

    func step(_ clips: Clips, to target: @escaping (Int) -> Int, keepGoing: @escaping () -> Bool = { true })
        async -> (number: Int, total: Int)? {
        await ClipStepper.step(to: target, read: { await clips.read() }, press: { await clips.press($0) },
                               keepGoing: keepGoing, settle: .milliseconds(40), poll: .milliseconds(2))
    }

    @Test("Back and on, one press a clip, and not at all when it's there")
    func steps() async {
        let back = Clips(at: 8, of: 8)
        #expect(await step(back) { _ in 3 }?.number == 3)
        #expect(await back.presses == [false, false, false, false, false])
        let on = Clips(at: 2, of: 8)
        #expect(await step(on) { $0 }?.number == 8, "Review: the last")
        let pressed = await on.presses
        #expect(pressed == Array(repeating: true, count: 6))
        let there = Clips(at: 5, of: 8)
        #expect(await step(there) { _ in 5 }?.number == 5)
        #expect(await there.presses.isEmpty)
    }

    @Test("A press that goes the wrong way turns the presses round: a camera numbering its newest first")
    func reversedNumbering() async {
        let clips = Clips(at: 4, of: 8, reversed: true)
        #expect(await step(clips) { _ in 6 }?.number == 6)
        #expect(await clips.presses == [true, false, false, false], "one the wrong way, then three the other")
    }

    @Test("A press that goes past the target, the right way, isn't taken for a camera numbering the other way")
    func overshoot() async {
        let clips = Clips(at: 4, of: 8)
        await clips.jumping(3)
        #expect(await step(clips) { _ in 5 }?.number == 5)
        #expect(await clips.presses == [true, false, false], "on to 7, then back a clip at a time")
    }

    @Test("A press it ignores is pressed again; two in a row and it stops")
    func ignoredPresses() async {
        let once = Clips(at: 6, of: 6, ignoring: 1)
        #expect(await step(once) { _ in 4 }?.number == 4)
        #expect(await once.presses.count == 3)
        let stuck = Clips(at: 6, of: 6, ignoring: 10)
        #expect(await step(stuck) { _ in 4 }?.number == 6)
        #expect(await stuck.presses.count == 2)
    }

    @Test("A newer pick changes where it heads; leaving playback or a take stops it")
    func newerPickAndStops() async {
        let clips = Clips(at: 10, of: 10)
        var target = 2
        let end = await ClipStepper.step(to: { _ in target }, read: { await clips.read() },
                                         press: { forward in
                                             await clips.press(forward)
                                             if await clips.presses.count == 3 { target = 9 }   // picked again
                                         },
                                         settle: .milliseconds(40), poll: .milliseconds(2))
        #expect(end?.number == 9)
        let left = Clips(at: 10, of: 10)
        let gone = await ClipStepper.step(to: { _ in 2 }, read: { await left.read() },
                                          press: { _ in await left.leave() },
                                          settle: .milliseconds(40), poll: .milliseconds(2))
        #expect(gone == nil, "the camera left playback: nothing more pressed, and no Play after")
        let rolling = Clips(at: 10, of: 10)
        #expect(await step(rolling, to: { _ in 2 }, keepGoing: { false })?.number == 10)
        #expect(await rolling.presses.isEmpty)
    }
}
