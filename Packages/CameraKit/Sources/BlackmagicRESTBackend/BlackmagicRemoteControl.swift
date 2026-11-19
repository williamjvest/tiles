import CameraCore
import Foundation

/// Stopping live view's stream through Remote Control: an access session (`/access`) that a camera with Remote Control
/// turned on in its own setup ("control and monitor"; Camera 10.3) gives one device at a time, whichever way Tiles logs
/// in. Undocumented by Blackmagic: this is what its Camera app does, measured on a PYXIS 12K (docs/pyxis-controls.md,
/// Remote Control).
///
/// Outside a session the camera refuses a stop ("stream is active to a different destination"). Inside one it lets a
/// stop through if the session's own platform file streams to the device holding it, and then stops whatever stream is
/// going, a broadcast of the camera's own included: so a stop is only asked for once the stream is known to be this
/// device's (`finishStream`, `startLiveView`). The session is held only for the stop and never streams. Live view
/// doesn't stream through one: when a session ends its file goes, and a stream on a platform the camera has just lost
/// carries on to the camera's own platform, a broadcast. Live view's stream is on Tiles' platform, which no session
/// touches.
extension BlackmagicCameraBackend {
    /// One camera-side step of live view at a time (start, finish, restart): interleaving at their awaits, a finish
    /// could delete Tiles' platform under a start that had just picked it, and the camera would carry on streaming to
    /// its own. First come, first served. A step mustn't take another: it would wait for itself.
    func liveViewStep<T>(_ body: () async throws -> T) async rethrows -> T {
        if liveViewStepBusy {
            await withCheckedContinuation { liveViewStepWaiters.append($0) }
        } else {
            liveViewStepBusy = true
        }
        defer {
            if liveViewStepWaiters.isEmpty { liveViewStepBusy = false } else { liveViewStepWaiters.removeFirst().resume() }
        }
        return try await body()
    }

    /// Whether the camera has Remote Control on: its access API answers, with something on offer. Nil when there's no
    /// telling (no answer at all), so it's asked again rather than taken as off.
    func remoteControlOn() async -> Bool? {
        do {
            let data = try await restClient.get("access/status")
            return (try? JSONDecoder().decode(AccessAnswer.self, from: data))?.availability.map { $0 != "none" } ?? false
        } catch is BlackmagicError {
            return false
        } catch {
            return nil
        }
    }

    /// Stops the camera's stream from a session held for just that. False without Remote Control, with another device
    /// holding it, or if the camera won't: the caller stops it another way.
    func stopThroughRemoteControl() async -> Bool {
        guard stopsThroughRemoteControl, remoteControl != false, let address = await liveStreamAddress() else { return false }
        let request = AccessRequest(deviceName: "Tiles", deviceModel: Self.deviceModel,
                                    streamingXML: BlackmagicLiveStream.remoteControlFile)
        let answer: AccessAnswer
        do {
            answer = try JSONDecoder().decode(AccessAnswer.self, from: await restClient.post("access/request", body: request))
        } catch BlackmagicError.notImplemented, BlackmagicError.forbidden(_) {
            remoteControl = false
            return false
        } catch BlackmagicError.http(let code, _) where code == 404 {
            remoteControl = false
            return false
        } catch {
            return false
        }
        guard answer.status == "accepted", let token = answer.token else {
            if answer.availability == "none" {
                remoteControl = false
            } else {
                ActivityLog.shared.note(host, "live view: \(await remoteControlHolder()) has the camera's remote control")
            }
            return false
        }
        remoteControl = true
        var stopped = false
        do {
            // This device, as the camera wants of a session that stops the stream. Nothing streams to it.
            let xml = BlackmagicLiveStream.remoteControlPlatformXML(url: "rtmp://\(address):1935/live")
            try await restClient.putRaw("livestreams/customPlatforms/\(BlackmagicLiveStream.remoteControlFile)",
                                        body: Data(xml.utf8), contentType: "application/xml")
            // It counts once the camera has loaded it, which takes a moment: listed among its platforms.
            let deadline = ContinuousClock.now + .seconds(5)
            while await !platformListed(BlackmagicLiveStream.remoteControlPlatform) {
                guard ContinuousClock.now < deadline else { throw LiveViewError.streamRefused("its platform didn't load") }
                try await Task.sleep(for: .milliseconds(200))
            }
            // A session lapses some seconds after its last sign of life, and the loading may have taken a while.
            _ = try? await restClient.post("access/heartbeat", body: AccessToken(token: token))
            try await restClient.put("livestreams/0/stop", body: EmptyBody())
            stopped = true
            ActivityLog.shared.note(host, "live view: stream stopped through Remote Control")
        } catch {
            ActivityLog.shared.note(host, "live view: no stop through Remote Control: \(error.localizedDescription)")
        }
        // Given back either way: its platform file goes with it.
        _ = try? await restClient.post("access/disconnect", body: AccessToken(token: token))
        return stopped
    }

    private func platformListed(_ name: String) async -> Bool {
        guard let data = try? await restClient.get("livestreams/platforms"),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return false }
        return names.contains(name)
    }

    /// Who holds the camera's remote control, as the camera names them.
    private func remoteControlHolder() async -> String {
        guard let data = try? await restClient.get("access/status"),
              let device = (try? JSONDecoder().decode(AccessStatus.self, from: data))?.currentDevice,
              let name = device.deviceName, !name.isEmpty
        else { return "another device" }
        guard let model = device.deviceModel, !model.isEmpty, !name.localizedCaseInsensitiveContains(model) else { return name }
        return "\(name) (\(model))"
    }

    /// The kind of device, as the camera shows who holds its remote control.
    static var deviceModel: String {
        #if os(macOS)
        return "Mac"
        #else
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
            ?? String(decoding: machine.prefix { $0 != 0 }, as: UTF8.self)
        return identifier.hasPrefix("iPad") ? "iPad" : "iPhone"
        #endif
    }
}

extension BlackmagicLiveStream {
    /// The platform a stop's session names: one server, this device, named as Blackmagic's app names its own.
    static func remoteControlPlatformXML(url: String) -> String {
        "<streaming><service><name>\(remoteControlPlatform)</name><servers><server><name>Controller</name><url>\(url)</url>"
            + "</server></servers><profiles><profile><name>\(remoteControlPlatform) Low</name><low-latency>true</low-latency>"
            + "<config resolution=\"1080p\" fps=\"30\" codec=\"H264\"><bitrate>1500000</bitrate>"
            + "<keyframe-interval>1</keyframe-interval></config></profile></profiles></service></streaming>"
    }

    static let remoteControlPlatform = "Tiles Remote"
    static let remoteControlFile = "TilesRemote.xml"
}

private struct AccessRequest: Encodable {
    let deviceName: String
    let deviceModel: String
    let streamingXML: String
}

private struct AccessToken: Encodable { let token: String }

/// What `/access/status`, `/access/request` and the rest answer: a status ("accepted", "denied", "inactive",
/// "disconnected"), the camera's availability ("control-and-monitor"), and with an acceptance the session's token.
private struct AccessAnswer: Decodable {
    let status: String?
    let availability: String?
    let token: String?
}

private struct AccessStatus: Decodable {
    struct Device: Decodable {
        let deviceName: String?
        let deviceModel: String?
    }
    let currentDevice: Device?
}
