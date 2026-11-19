@testable import BlackmagicBLE
import CameraCore
import CameraKitTestSupport
import Foundation
import Testing

private func bytes(_ data: Data) -> [UInt8] { [UInt8](data) }

// MARK: - The protocol, against Blackmagic's own example packets

@Suite("Blackmagic camera control protocol")
struct CameraControlProtocolTests {
    // The "Example Protocol Packets" in Blackmagic's Camera Control document.

    @Test("Blackmagic's example packets, byte for byte")
    func examplePackets() {
        var af = BMMessage.trigger(.instantaneousAutofocus)
        af.destination = 4
        #expect(bytes(af.encoded) == [4, 4, 0, 0, 0, 1, 0, 0])

        let ois = BMMessage.assign(BMParameter(0, 6), bool: true)
        #expect(bytes(ois.encoded) == [255, 5, 0, 0, 0, 6, 0, 0, 1, 0, 0, 0])

        var exposure = BMMessage.assign(BMParameter(1, 5), int32: [10_000])
        exposure.destination = 4
        #expect(bytes(exposure.encoded) == [4, 8, 0, 0, 1, 5, 3, 0, 0x10, 0x27, 0x00, 0x00])

        var zebra = BMMessage.assign(.zebraLevel, fixed16: [0.15])
        zebra.destination = 4
        zebra.operation = .offset
        #expect(bytes(zebra.encoded) == [4, 6, 0, 0, 4, 2, 128, 1, 0x33, 0x01, 0, 0])

        let mode = BMMessage.assign(.videoMode, int8: [24, 1, 3, 0, 0])
        #expect(bytes(mode.encoded) == [255, 9, 0, 0, 1, 0, 1, 0, 24, 1, 3, 0, 0, 0, 0, 0])

        var gamma = BMMessage.assign(BMParameter(8, 1), fixed16: [0, -0.3, -0.3, 0])
        gamma.destination = 4
        gamma.operation = .offset
        #expect(bytes(gamma.encoded) == [4, 12, 0, 0, 8, 1, 128, 1, 0, 0, 0x9a, 0xfd, 0x9a, 0xfd, 0, 0])
    }

    @Test("Messages back to back decode one by one, skipping the padding")
    func decodesAGroup() {
        let group: [UInt8] = [4, 4, 0, 0, 0, 1, 0, 0,
                              255, 5, 0, 0, 0, 6, 0, 0, 1, 0, 0, 0,
                              4, 8, 0, 0, 1, 5, 3, 0, 0x10, 0x27, 0x00, 0x00,
                              4, 6, 0, 0, 4, 2, 128, 1, 0x33, 0x01, 0, 0,
                              255, 9, 0, 0, 1, 0, 1, 0, 24, 1, 3, 0, 0, 0, 0, 0,
                              4, 12, 0, 0, 8, 1, 128, 1, 0, 0, 0x9a, 0xfd, 0x9a, 0xfd, 0, 0]
        let messages = BMMessage.decode(Data(group))
        #expect(messages.map(\.parameter) == [.instantaneousAutofocus, BMParameter(0, 6), BMParameter(1, 5), .zebraLevel,
                                              .videoMode, BMParameter(8, 1)])
        #expect(messages[2].int32s == [10_000])
        #expect(messages[3].fixed16s.first.map { abs($0 - 0.15) < 0.001 } == true)
        #expect(messages[4].int8s == [24, 1, 3, 0, 0])
        #expect(messages[5].fixed16s.map { ($0 * 100).rounded() / 100 } == [0, -0.3, -0.3, 0])
    }

    @Test("A command that isn't 0 is skipped by its length, and a short tail is ignored")
    func skipsOtherCommands() {
        let other: [UInt8] = [255, 2, 7, 0, 0xAA, 0xBB, 0, 0]
        let iso = BMMessage.assign(.iso, int32: [1600]).encoded
        let messages = BMMessage.decode(Data(other) + iso + Data([255, 9]))
        #expect(messages.count == 1 && messages.first?.int32s == [1600])
    }

    @Test("Timecode notifications are BCD: 0x09125310 is 09:12:53:10")
    func bcdTimecode() {
        let t = BlackmagicBluetooth.timecode(bcd: 0x0912_5310)
        #expect(t.hours == 9 && t.minutes == 12 && t.seconds == 53 && t.frames == 10)
    }
}

// MARK: - What the dashboard shows

@Suite("Blackmagic Bluetooth state")
struct CameraControlStateTests {
    @Test("An URSA Mini Pro's report, as tiles")
    func mapsASetOfSettings() {
        var control = CameraControlState()
        for message in FakeBluetoothCamera.ursaMiniPro12K { control.apply(message) }
        var state = CameraState()
        control.map(into: &state)
        #expect(state.recording.state == .idle)
        #expect(state.iso?.value == 800)
        #expect(state.shutterAngle?.value == 180)
        #expect(state.shutterMode?.value == .angle && state.shutterMode?.isWritable == false)
        #expect(state.whiteBalance?.kelvin.value == 5600 && state.whiteBalance?.tint?.value == 0)
        #expect(state.iris?.value == 4.0)
        #expect(state.nd?.preset.value == "0.6")
        #expect(state.nd?.preset.options == ["Clear", "0.6", "1.2", "1.8"])
        #expect(state.frameRate?.project.value == "23.98")
        #expect(state.frameRate?.variable?.value == false)
        #expect(state.resolution?.value == "4096x2160")
        #expect(state.fileFormat?.value == "BRAW 5:1")
        #expect(state.recordingFormat == "4096x2160 · BRAW 5:1")
        #expect(state.dynamicRange?.value == "Film")
        #expect(state.look?.value == true)
        #expect(state.lut?.value == "Film to Video")
        let all = state.monitoring?.outputs.first
        #expect(all?.overlays[.zebra]?.value == true && all?.overlays[.falseColor]?.value == false)
        #expect(all?.overlays[.statusText]?.value == true && all?.overlays[.cleanFeed]?.value == false)
        #expect(state.monitoring?.zebraLevel?.value == 75)
        #expect(state.batteryPercent == nil && state.hasLiveView == false)  // not in the protocol
    }

    @Test("Nothing the camera hasn't reported: a PYXIS sends no ND, so no ND tile")
    func onlyWhatWasReported() {
        var control = CameraControlState()
        control.apply(.assign(.iso, int32: [400]))
        var state = CameraState()
        control.map(into: &state)
        #expect(state.iso?.value == 400 && state.nd == nil && state.whiteBalance == nil && state.recording.state == .unknown)
    }

    @Test("Apertures are third stops from AV, exactly: f/5.6 is AV 5")
    func apertures() {
        #expect(CameraControlState.fNumber(av: 5) == 5.6)
        #expect(CameraControlState.av(fNumber: 5.6) == 5)
        #expect(CameraControlState.av(fNumber: 2.8) == 3)
        #expect(CameraControlState.fNumber(av: 9) == 22)
        for f in CameraControlState.fNumbers { #expect(CameraControlState.fNumber(av: CameraControlState.av(fNumber: f)) == f) }
    }

    @Test("Frame rates: an M-rate 24 is 23.98, and back")
    func frameRates() {
        #expect(CameraControlState.frameRateLabel(fps: 24, mRate: true) == "23.98")
        #expect(CameraControlState.frameRateLabel(fps: 25, mRate: false) == "25")
        let ntsc = CameraControlState.frameRateValue("59.94"), pal = CameraControlState.frameRateValue("50")
        #expect(ntsc?.fps == 60 && ntsc?.mRate == true)
        #expect(pal?.fps == 50 && pal?.mRate == false)
    }
}

// MARK: - The backend, against a fake camera

@Suite("Blackmagic over Bluetooth")
struct BlackmagicBluetoothBackendTests {
    private func connected(_ config: FakeBluetoothCamera.Config = .init(), timeout: Duration = .seconds(3))
        async -> (FakeBluetoothCamera, BlackmagicBluetoothBackend, CameraState?) {
        let camera = FakeBluetoothCamera(config)
        let backend = BlackmagicBluetoothBackend(link: camera, recConfirmTimeout: timeout)
        await backend.connect()
        let state = await collectUntil(stream: backend.updates, timeout: 5) { $0.connection == .connected && $0.iso != nil }
        return (camera, backend, state)
    }

    private func until(_ backend: BlackmagicBluetoothBackend, _ predicate: @escaping @Sendable (CameraState) -> Bool) async -> CameraState? {
        await collectUntil(stream: backend.updates, timeout: 5, predicate: predicate)
    }

    @Test("Bonding shows as waiting for approval, then the camera connects with its model and settings", .timeLimit(.minutes(1)))
    func bondsAndConnects() async {
        var config = FakeBluetoothCamera.Config()
        config.needsPairing = true
        let camera = FakeBluetoothCamera(config)
        let backend = BlackmagicBluetoothBackend(link: camera)
        let asking = Task { await collectUntil(stream: backend.updates, timeout: 5) { $0.connection == .awaitingApproval } }
        await backend.connect()
        #expect(await asking.value != nil)
        let state = await until(backend) { $0.connection == .connected && $0.iso != nil }
        #expect(state?.model == "URSA Mini Pro 12K" && state?.make == .blackmagic)
        #expect(state?.recording.state == .idle)
    }

    @Test("REC: transport mode Record, then wait for the camera to say it's recording; stop is Preview", .timeLimit(.minutes(1)))
    func recordStartsAndStops() async {
        let (camera, backend, _) = await connected()
        await backend.send(.record(true))
        let rolling = await until(backend) { $0.recording.state == .recording && $0.recording.request == nil }
        #expect(rolling?.takeStartedAt != nil && rolling?.recording.failure == nil)
        // Mode 2, speed 0, and the camera's own flags and media (0x20, 2, 2) as it last reported them.
        #expect(camera.sent.map(bytes).last == [255, 9, 0, 0, 10, 1, 1, 0, 2, 0, 0x20, 2, 2, 0, 0, 0])
        await backend.send(.record(false))
        let stopped = await until(backend) { $0.recording.state == .idle && $0.recording.request == nil }
        #expect(stopped?.takeStartedAt == nil)
        #expect(camera.sent.map(bytes).last == [255, 9, 0, 0, 10, 1, 1, 0, 0, 0, 0x20, 2, 2, 0, 0, 0])
    }

    @Test("REC is absolute and never optimistic: nothing sent when already there; a camera that doesn't confirm times out", .timeLimit(.minutes(1)))
    func recordIsAbsoluteAndConfirmed() async {
        var config = FakeBluetoothCamera.Config()
        config.recordsWhenAsked = false
        let (camera, backend, _) = await connected(config, timeout: .milliseconds(400))
        await backend.send(.record(false))  // idle already
        #expect(camera.sent.isEmpty)
        await backend.send(.record(true))
        let failed = await until(backend) { $0.recording.failure != nil }
        #expect(failed?.recording.failure == RecordingControl.Failure.notConfirmed(start: true))
        #expect(failed?.recording.state == .idle && failed?.recording.request == nil)
        #expect(camera.sent.count == 1)  // not resent
    }

    @Test("A take started at the camera shows, with its start; a full card stopping it clears it", .timeLimit(.minutes(1)))
    func recordFromTheCamera() async {
        let (camera, backend, _) = await connected()
        camera.report(.assign(.transportMode, int8: [2, 0, 0x20, 2, 2]))
        let rolling = await until(backend) { $0.recording.state == .recording }
        #expect(rolling?.takeStartedAt != nil)
        camera.report(.assign(.transportMode, int8: [0, 0, 0x20, 2, 2]))
        let stopped = await until(backend) { $0.recording.state == .idle }
        #expect(stopped?.takeStartedAt == nil)
    }

    @Test("Settings go out as the protocol's messages and show, echoed or not", .timeLimit(.minutes(1)))
    func settings() async {
        var config = FakeBluetoothCamera.Config()
        config.echoes = false
        let (camera, backend, _) = await connected(config)
        await backend.send(.setISO(1600))
        #expect(camera.sent.map(bytes).last == [255, 8, 0, 0, 1, 14, 3, 0, 0x40, 0x06, 0, 0])
        #expect(await until(backend) { $0.iso?.value == 1600 } != nil)

        await backend.send(.setShutterAngle(172.8))
        #expect(camera.sent.map(bytes).last == [255, 8, 0, 0, 1, 11, 3, 0, 0x80, 0x43, 0, 0])  // 17280

        await backend.send(.setKelvin(3200))
        #expect(camera.sent.map(bytes).last == [255, 8, 0, 0, 1, 2, 2, 0, 0x80, 0x0C, 0, 0])  // [3200, tint 0]

        await backend.send(.setNDPreset("1.2"))  // 4 stops, in the display mode it came with (1, density)
        #expect(camera.sent.map(bytes).last == [255, 8, 0, 0, 1, 16, 128, 0, 0x00, 0x20, 0x00, 0x08])
        #expect(await until(backend) { $0.nd?.preset.value == "1.2" } != nil)

        await backend.send(.setIris(5.6))  // AV 5 = 0x2800
        #expect(camera.sent.map(bytes).last == [255, 6, 0, 0, 0, 2, 128, 0, 0x00, 0x28, 0, 0])

        await backend.send(.setFrameRate("25"))  // the format whole, M-rate cleared
        #expect(camera.sent.map(bytes).last == [255, 14, 0, 0, 1, 9, 2, 0, 25, 0, 0, 0, 0x00, 0x10, 0x70, 0x08, 0, 0, 0, 0])
        #expect(await until(backend) { $0.frameRate?.project.value == "25" } != nil)
    }

    @Test("Auto white balance triggers a measurement; the camera's answer is the value", .timeLimit(.minutes(1)))
    func autoWhiteBalance() async {
        let (camera, backend, _) = await connected()
        await backend.send(.setWhiteBalancePreset("Auto"))
        #expect(camera.sent.map(bytes).last == [255, 4, 0, 0, 1, 3, 0, 0])
        let measured = await until(backend) { $0.whiteBalance?.kelvin.value == 4950 }
        #expect(measured?.whiteBalance?.tint?.value == 3)
    }

    @Test("Overlays switch on every display: zebra on keeps the other tools as they were", .timeLimit(.minutes(1)))
    func overlays() async {
        let (camera, backend, _) = await connected()
        await backend.send(.setMonitorOverlay(.falseColor, true, output: nil))
        #expect(camera.sent.map(bytes).last == [255, 8, 0, 0, 4, 1, 2, 0, 0x05, 0x00, 0x1F, 0x00])  // zebra + false color
        let on = await until(backend) { $0.falseColor?.value == true }
        #expect(on?.monitoring?.outputs.first?.overlays[.zebra]?.value == true)
    }

    @Test("A camera that's switched off says so, and connects when it's switched on", .timeLimit(.minutes(1)))
    func cameraOff() async {
        var config = FakeBluetoothCamera.Config()
        config.status = [.connected, .paired]
        let camera = FakeBluetoothCamera(config)
        let backend = BlackmagicBluetoothBackend(link: camera)
        await backend.connect()
        let off = await until(backend) { if case .failed = $0.connection { return true } else { return false } }
        #expect(off?.connection == .failed("The camera is off. Switch it on, and it reconnects."))
        camera.status([.powerOn, .connected, .paired, .cameraReady])
        #expect(await until(backend) { $0.connection == .connected } != nil)
    }

    @Test("Timecode runs while it moves and stops when the notifications do", .timeLimit(.minutes(1)))
    func timecodeRunsAndStops() async {
        let (camera, backend, _) = await connected()
        camera.timecode(0x0100_0000)
        camera.timecode(0x0100_0001)
        let running = await until(backend) { $0.timecode?.isRunning == true }
        #expect(running?.timecode?.rate == 24)
        #expect(running.map { $0.timecode!.string(at: $0.timecode!.anchor) }?.hasPrefix("01:00:00") == true)
        let stopped = await until(backend) { $0.timecode?.isRunning == false }  // 1.5 s without one
        #expect(stopped?.timecode?.frames(at: Date().addingTimeInterval(5)) == stopped?.timecode?.frames(at: Date()))
    }

    @Test("A dropped link fails the connection and drops a waiting REC request", .timeLimit(.minutes(1)))
    func dropped() async {
        var config = FakeBluetoothCamera.Config()
        config.recordsWhenAsked = false
        let (camera, backend, _) = await connected(config, timeout: .seconds(10))
        await backend.send(.record(true))
        camera.drop("The camera's Bluetooth link dropped.")
        let gone = await until(backend) { if case .failed = $0.connection { return true } else { return false } }
        #expect(gone?.recording.request == nil)
        await backend.send(.setISO(400))  // not connected: nothing goes out
        #expect(camera.sent.count == 1)
    }
}
