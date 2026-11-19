// What a sweep of the Sony bodies found on their power and media, each against a capture where there's one: what's
// powering the camera (an FX5 on USB-C read 0%), the card in slot B alone, a card in trouble, and the camera's own
// overheating warning, which reached nothing the operator sees.

import Testing
import Foundation
@testable import SonyPTP
import CameraCore

@Suite("Sony power and media")
struct PowerAndMediaTests {
    /// One property as the camera lists it.
    private func prop(_ code: SDIPropCode, _ type: SDIDataType, _ value: Data,
                      enabled: SDIIsEnabled = .enabled) -> SDIDevicePropInfo {
        SDIDevicePropInfo(code: code.rawValue, dataType: type, getSet: .getOnly, isEnabled: enabled,
                          defaultValue: value, currentValue: value, defaultStringValue: "", stringValue: "",
                          defaultArrayValues: [], arrayValues: [], formFlag: .none, rangeMin: Data(), rangeMax: Data(),
                          rangeStep: Data(), enumValues: [], enumValuesAll: [])
    }
    private func u32(_ v: UInt32) -> Data { var d = Data(); d.appendLE(v); return d }
    private func state(_ props: [SDIDevicePropInfo]) -> CameraState {
        var state = CameraState()
        StateMapper(props: props).map(into: &state)
        return state
    }

    @Test("Power: an FX5 on USB-C (its morning capture), an FX6 on DC, an FX3 and a BURANO on their batteries")
    func powerSource() throws {
        #expect(try FX5MappingTests.state(FX5MappingTests.asFound).powerSource == "USB")  // 0xD20E 0x0C
        #expect(try FX6MappingTests.state(FX6MappingTests.lens).powerSource == "DC")       // 0xD03A 0x01
        #expect(try BURANOMappingTests.state("burano-propinfo-2026-10-27").powerSource == nil)
        let flat = state([prop(.batteryLevelIndicator, .uint8, Data([0x0B])), prop(.batteryRemaining, .int8, Data([0]))])
        #expect(flat.powerSource == "USB" && flat.batteryPercent == 0, "a flat battery on USB-C: 0% and why it runs")
        #expect(state([prop(.batteryLevelIndicator, .uint8, Data([0x01]))]).powerSource == "Ext", "a dummy battery")
        #expect(state([prop(.batteryLevelIndicator, .uint8, Data([0x07]))]).powerSource == nil, "a battery at 4/4")
        #expect(state([prop(.powerSource, .uint8, Data([0x03]))]).powerSource == "PoE")
    }

    @Test("Battery in minutes where the camera is set to show them; not at its other units, nor untaken")
    func batteryMinutes() throws {
        func minutes(_ unit: UInt8, _ value: UInt32, enabled: SDIIsEnabled = .dispOnly) -> Int? {
            state([prop(.batteryRemainDisplayUnit, .uint8, Data([unit])),
                   prop(.batteryRemainingMinutes, .uint32, u32(value), enabled: enabled)]).batteryMinutes
        }
        #expect(minutes(0x01, 95) == 95)
        #expect(minutes(0x03, 95) == nil, "set to volts")
        #expect(minutes(0x01, 0xFFFF_FFFF) == nil, "untaken")
        #expect(minutes(0x01, 95, enabled: .disabled) == nil)
        #expect(try BURANOMappingTests.state("burano-propinfo-2026-10-27").batteryMinutes == nil, "its display was at volts")
    }

    @Test("Media: slot A's time, else slot B's when A has no card; a full card reads 0, no card nothing")
    func mediaSlots() throws {
        #expect(try FX5MappingTests.state(FX5MappingTests.asFound).mediaRemainingMinutes == 1133)
        let bOnly = state([prop(.mediaSlot1Status, .uint8, Data([0x02])), prop(.mediaSlot1Remaining, .uint32, u32(0), enabled: .disabled),
                           prop(.mediaSlot2Status, .uint8, Data([0x01])), prop(.mediaSlot2Remaining, .uint32, u32(3600), enabled: .dispOnly)])
        #expect(bOnly.mediaRemainingMinutes == 60, "it showed nothing")
        let full = state([prop(.mediaSlot1Status, .uint8, Data([0x01])), prop(.mediaSlot1Remaining, .uint32, u32(0), enabled: .dispOnly),
                          prop(.mediaSlot2Status, .uint8, Data([0x02]))])
        #expect(full.mediaRemainingMinutes == 0)
        let none = state([prop(.mediaSlot1Status, .uint8, Data([0x02])), prop(.mediaSlot2Status, .uint8, Data([0x02]))])
        #expect(none.mediaRemainingMinutes == nil)
    }

    @Test("Alerts: the camera's overheating and a card in trouble, none in the captures; an FX3's 0x04 slot isn't one")
    func alerts() throws {
        for fixture in [FX5MappingTests.asFound] { #expect(try FX5MappingTests.state(fixture).alerts.isEmpty) }
        #expect(try FX6MappingTests.state(FX6MappingTests.lens).alerts.isEmpty)
        let hot = state([prop(.overheatingState, .uint8, Data([0x02])), prop(.mediaSlot2Status, .uint8, Data([0x08]))])
        #expect(hot.alerts == ["Overheating", "Card B: needs formatting"])
        #expect(state([prop(.overheatingState, .uint8, Data([0x01]))]).alerts == ["Getting hot"])
        #expect(state([prop(.mediaSlot2Status, .uint8, Data([0x04])), prop(.mediaSlot1Status, .uint8, Data([0x09]))]).alerts
                == ["Card A: read-only"])
    }
}
