import CameraCore
import Foundation
import os

extension VeniceCameraBackend {
    // MARK: - Change notifications

    func listenForChanges() {
        listening?.cancel()
        listening = Task { [weak self] in
            guard let self else { return }
            let stream = await self.client.updates
            for await note in stream {
                await self.change(note)
            }
        }
    }

    func change(_ note: SavonaClient.Notification) async {
        guard note.name.hasPrefix("Notify.") else { return }
        quietKeepAlives = 0
        // Notify.Property.Value.Changed: [ {name: value, …} ]
        // Notify.Capability.Value.Changed carries option lists, {name: [true, "", [values]]}: never a value
        // (taking it for one broke white balance and EI after a base switch, VENICE 2).
        if note.name.contains("Capability"), let map = note.data.array?.first?.map {
            for (name, entry) in map {
                if let list = entry.array, list.count >= 3, let values = list[2].array { options[name] = values }
            }
            rebuild()
            yield()
            return
        }
        // Notify.Property.Status.Changed: [{name: "Locked" | "Unlocked"}], a menu item's as `….MenuItem`.
        if note.name.contains("Status.Changed"), let map = note.data.array?.first?.map {
            var changed = false
            for (name, value) in map {
                guard let text = value.string ?? value.unwrapped.string, statuses[name] != text else { continue }
                statuses[name] = text
                changed = true
            }
            if changed {
                rebuild()
                yield()
            }
            return
        }
        // The audio meters, several times a second and always on their own (VENICE 2: 5,893 per session, each
        // Output.Audio.Level and Output.Audio.dBLevel with all four channels): the meters and nothing else, no rebuild.
        if note.name.hasSuffix("Value.Changed"), let map = note.data.array?.first?.map, !map.isEmpty,
           map.keys.allSatisfy({ $0 == Self.audioMeters || $0 == Self.audioLevels }) {
            for (name, value) in map {
                var merged = values[name]?.map ?? [:]
                merged.merge(value.map ?? [:]) { _, new in new }
                values[name] = .map(merged)
            }
            applyMeters()
            yield()
            return
        }
        if note.name.hasSuffix("Value.Changed") || note.name == "Notify.Properties" || note.name == "Notify.Properties.Changed",
           let body = note.data.array?.first, let map = body.map {
            var modeChanged = false
            for (name, value) in map {
                if Self.lutBases.contains(name), let entries = value.map {
                    // One output's LUT changes at a time: keep the others' entries, settle that output's slot.
                    var merged = values[name]?.map ?? [:]
                    for (key, entry) in entries {
                        merged[key] = entry
                        let slotName = name + "#" + key
                        if let text = entry.string, !VeniceTables.isLog(text) { lastLUT[slotName] = text }
                        pending[slotName] = nil
                        pendingSince[slotName] = nil
                    }
                    log.notice("← \(name, privacy: .public) = \(value.description.prefix(60), privacy: .public)")
                    values[name] = .map(merged)
                    continue
                }
                if let entries = value.map, entries.count < (values[name]?.map?.count ?? 0) {
                    // VENICE 2 reports a map one entry at a time (Button.Assign {"Assignable.2": [...]}, the LUT
                    // LockStatus maps): the rest stand. Taking one entry for the whole map lost every other button.
                    var merged = values[name]?.map ?? [:]
                    merged.merge(entries) { _, new in new }
                    if name == property[.assign] { entries.keys.forEach { pendingKeys[$0] = nil } }
                    log.notice("← \(name, privacy: .public) += \(value.description.prefix(60), privacy: .public)")
                    values[name] = .map(merged)
                    pending[name] = nil
                    pendingSince[name] = nil
                    continue
                }
                if name == property[.assign], let entries = value.map { entries.keys.forEach { pendingKeys[$0] = nil } }
                if let text = value.string, !VeniceTables.isLog(text),
                   [Field.lutSdi12, .lutSdi34, .lutMonitor, .lutVf].compactMap({ property[$0] }).contains(name) {
                    lastLUT[name] = text
                }
                if values[name] != value || pending[name] != nil, name != Self.audioMeters, name != Self.audioLevels {
                    log.notice("← \(name, privacy: .public) = \(value.description.prefix(60), privacy: .public)")
                }
                if values[name] != value, listsFollow.contains(name) { modeChanged = true }
                values[name] = value
                pending[name] = nil
                pendingSince[name] = nil
            }
            if modeChanged { relistLater() }
            rebuild()
            yield()
        } else if note.name.contains("Capability") {
            await loadOptions()
            rebuild()
            yield()
        }
    }

    // MARK: - Keep-alive

    /// The page holds its connection with a read every 3 s, and so does Tiles; its round trip is the latency. Two quiet
    /// passes in a row drop the link (the controller reconnects on its own backoff, never rapidly).
    func scheduleKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                let stillAlive = await self.keepAliveTick()
                if !stillAlive { return }
            }
        }
    }

    /// One keep-alive pass. False means the link is gone and this connection is finished.
    func keepAliveTick() async -> Bool {
        guard state.connection == .connected else { return false }
        // The page reads this every 3 s whatever else is going on (VENICE 2, rm.html), with ["cam"].
        let name = property[.keepAlive] ?? SavonaClient.keepAliveProperty
        let sent = Date()
        if (try? await client.request("Property.GetValue", .array([.map([name: .array([.string("cam")])])]), timeout: 6)) != nil {
            // Its round trip is the link's latency, measured all the time rather than only after a change.
            recentLatencies.append(Date().timeIntervalSince(sent))
            if recentLatencies.count > 8 { recentLatencies.removeFirst(recentLatencies.count - 8) }
            rebuild()  // also what time alone changes: a timecode that stopped, a pending value gone stale
            yield()
        }
        let sinceAnswer = Date().timeIntervalSince(await client.lastInbound)
        if sinceAnswer < 3 {
            quietKeepAlives = 0
            return true
        }
        quietKeepAlives += 1
        let missed = quietKeepAlives
        log.notice("keep-alive unanswered (\(missed, privacy: .public))")
        if quietKeepAlives >= 2 {
            state.connection = .failed("VENICE: link went quiet")
            yield()
            await client.close()
            return false
        }
        return true
    }

    // MARK: - Reading back

    func refresh(_ fields: [Field]) async {
        let names = fields.compactMap { property[$0] }
        guard !names.isEmpty else { return }
        if let answered = try? await client.get(names, timeout: 8) {
            values.merge(answered) { _, new in new }
        }
        rebuild()
    }
}
