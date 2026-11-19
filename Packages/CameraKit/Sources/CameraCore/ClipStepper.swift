import Foundation

/// Going to a clip a clip at a time, on a camera that numbers its clips in playback but can't be sent straight to one:
/// an FX5, a VENICE, an ALEXA (`PlaybackCommand.goToClip`; a Blackmagic camera seeks instead). An FX5's Review steps
/// on to the last take with it too.
public enum ClipStepper {
    /// From the clip the camera has open to `target(total)`: one press at a time toward it, each once the camera has said
    /// which clip it's on (`read`: its number from 1, and how many there are), so never past either end. The target is
    /// asked again each step, so a newer pick changes where it heads. A press that moves the number the other way from
    /// the one meant turns the presses round for good: which way a camera numbers its clips, newest first or last, isn't
    /// known for every camera (one that jumps past the target, the right way, isn't that). It stops on the target; when
    /// a read fails (the camera left playback); when two presses in a row don't move it (a Prev mid-clip goes to the
    /// clip's start first, so one may not); when `keepGoing` says so (a take started); or after 30 s and a second for
    /// each clip it had to go. Returns where it ended, nil if a read failed.
    public static func step(
        isolation: isolated (any Actor)? = #isolation,
        to target: (_ total: Int) -> Int,
        read: () async -> (number: Int, total: Int)?,
        press: (_ forward: Bool) async -> Void,
        keepGoing: () -> Bool = { true },
        settle: Duration = .seconds(2),
        poll: Duration = .milliseconds(150)
    ) async -> (number: Int, total: Int)? {
        guard var at = await read() else { return nil }
        let deadline = ContinuousClock.now + .seconds(30 + abs(target(at.total) - at.number))
        var stuck = 0
        var flipped = false
        while at.number != target(at.total), keepGoing(), stuck < 2, ContinuousClock.now < deadline {
            let forward = at.number < target(at.total)
            await press(forward != flipped)
            let pressed = ContinuousClock.now
            var now = at
            while now.number == at.number, ContinuousClock.now - pressed < settle {
                try? await Task.sleep(for: poll)
                guard let fresh = await read() else { return nil }
                now = fresh
            }
            stuck = now.number == at.number ? stuck + 1 : 0
            if now.number != at.number, (now.number > at.number) != forward { flipped.toggle() }
            at = now
        }
        return at
    }
}
