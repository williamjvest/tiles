# Adding a Camera Backend

Backends so far: Sony (PTP-IP, `SonyPTP`), Blackmagic (REST, `BlackmagicRESTBackend`, PYXIS 12K), Blackmagic over
Bluetooth LE (`BlackmagicBLE`: a `BluetoothLink` with CoreBluetooth behind it and a fake in the tests), and Sony VENICE /
VENICE 2 over its Web Remote's Savona API (`SonySavona`: MessagePack-RPC over a WebSocket; built 2026-10-22 from the
open-source clients and Sony's manual, first camera session 2026-10-23 — docs/venice.md). Add Camera picks Camera
Remote or the Web Remote itself (`SonyRemoteProbe`). ARRI (`ArriWebRemote`: the Web Remote's HTTP interface — all.cgi,
an update.cgi long poll, set.cgi and call.cgi — built 2026-10-22 before a camera; `ArriRemoteProbe` tells Add Camera
what answered). `ArriClient` is `ArriWebRemote`'s transport layer; a future network protocol backend would replace it.

## Steps

### 1. Implement `CameraBackend`

Create a new target or extend an existing one in `Packages/CameraKit`. Implement:

```swift
public protocol CameraBackend: AnyObject, Sendable {
    var updates: AsyncStream<CameraState> { get }
    func connect() async
    func disconnect() async
    func send(_ command: CameraCommand) async
}
```

Map the camera's controls to `CameraState` fields. Use `Choice<Value>` for enumerated controls and
`Level` for continuous ranges.

**Nil means the camera doesn't offer it.** If a control is absent on this body, leave the field `nil`
in every `CameraState` update. The dashboard disables tiles for nil controls. Never populate a field
with a dummy value as a placeholder.

### 2. Map controls to `CameraState`

Work through each `CameraState` field and decide whether this body exposes it:

| Field | Notes |
|-------|-------|
| `recording` | Use `RecordingControl`. Follow the REC rule: never optimistic, absolute semantics. |
| `shutterAngle` / `shutterSpeed` / `shutterMode` | Nil whichever the body doesn't offer |
| `iso` / `baseISO` | Nil if the body uses a different gain model |
| `whiteBalance` | Nil `tint` if the body doesn't expose tint separately |
| `nd` | Nil `variable` if the body has no electronic variable ND |
| `iris` | `Choice<Double>` of f-numbers |
| `frameRate` | `Choice<String>` with labels as the camera displays them |
| `fileFormat`, `recordingSetting`, `resolution`, `desqueeze` | Nil if not available |
| `lut`, `look` | Nil if not available |
| `focusMode` | Nil if not available |
| `batteryPercent`, `mediaRemainingMinutes` | Nil if not exposed |
| `latencyMilliseconds` | Rolling average of command RTTs; nil is fine |

### 3. Add a connection kind in `Credentials`

`Packages/CameraKit/Sources/CameraCore/Credentials.swift`:

```swift
public enum CameraConnection: Codable, Hashable, Sendable {
    case demo(MockBody)
    case sony(SonyConnection)
    case blackmagic(BlackmagicConnection)
    case blackmagicBluetooth(BlackmagicBluetoothConnection)
    case venice(VeniceConnection)
    case arri(ArriConnection)
}
```

Add your connection type (host, credentials, whatever the backend needs), with an accessor like `venice` / `arri`. An
older build reading a setup with the new case leaves that camera out rather than losing the setup (`Lenient`).

### 4. Register in the app factory

`App/CameraControl/CameraControlApp.swift` — add a case to `makeBackend`:

```swift
static func makeBackend(_ camera: SavedCamera, password: String?) -> any CameraBackend {
    switch camera.connection {
    case .demo(let body):        return MockCameraBackend(body: body, label: camera.slot.label)
    case .sony(let conn):        return SonyCameraBackend(…)
    case .blackmagic(let conn):  return BlackmagicCameraBackend(…)
    case .venice(let conn):      return VeniceCameraBackend(…)
    case .arri:                  return ArriCameraBackend(host: camera.slot.host, label: camera.slot.label)
    // …
    }
}
```

Add the package product to `App/project.yml` (and the target to `Packages/CameraKit/Package.swift`), then
`xcodegen generate`.

**Everywhere else a new kind of camera reaches** (the compiler finds the `switch`es; these it doesn't):
- `ProfileCameraType` (who made it: the maker's page, captions, profiles), and `CameraState.make` set by the backend.
- Add Camera (`DashboardUI/Settings.swift`): `CameraType`'s segment, the editor's `load` / `save` / `canSave` and
  footer, `connectionSummary`, the profile editor; a probe if the kind can be told by asking the address.
- `DashboardStore.saveAsProfile`, `demoOnlyBackend`.
- A demo: `MockBody` cases, a sample state the demo, Test Mode and edit mode show (`previewState`), and the mock's
  handling of anything it does differently (e.g. ARRI keeps shutter angle and time).
- `MeshDeviceList.cameraMaker`: the maker's IEEE OUI, so the HaLow list knows the camera.
- `camctl`: a subcommand that drives the backend, and a mock on the network (`scripts/<kind>/`).

### 5. Add a fake + fixtures + tests

Add a `FakeVeniceCamera` (or equivalent) in `Tests/` that lets the integration tests run without
hardware. Model whatever protocol behavior is camera-specific (equivalent to `FakePTPIPCamera`'s
REC Hold semantics).

Capture raw traffic from the real camera using whatever capture mechanism makes sense (`--record` in
camctl for PTP-IP; a proxy or tcpdump for HTTP). Commit the captures to `fixtures/`.

Write `BackendIntegrationTests`-style tests: connect, send each command, assert the state update
arrives.

### 6. Verify live and write a controls doc

Connect to a real camera body. For every `CameraState` field:

- Confirm the control reads correctly.
- Confirm the control sets correctly.
- Note any `dispOnly`, absent, or behavior-dependent cases.

Write a `docs/<body>-controls.md` in the style of `docs/fx3-controls.md`. One row per control,
verified set marked ✓/✗. This becomes the ground truth for future work on that body.

### 7. Layout template (optional)

If the body has a known-absent set of controls, add a body-specific layout template in
`LayoutTemplates` (as `fx3` excludes `resolution` and `desqueeze`). This prevents placeholder tiles
for controls that will always be nil on that body. A maker's own block goes by `CameraState.make` (`ProfileCameraType`), which the backend's
mapper sets and the profile remembers: a Blackmagic camera gets `blackmagic`, an ARRI one `arri`; a VENICE goes by its
model (`CameraProfile.isVenice`). A template set's new block is optional (`TemplateSet.arri`), so older sets still
recognize saved layouts, and it joins `tileMinimumsFitEveryTemplate`. Every template must keep each tile at or
above its `TileSpec` minimum (`tileMinimumsFitEveryTemplate`).

### 8. Live view (optional)

Conform to `LiveViewProvider`: `startLiveView(quality:)`, `stopLiveView()`, `liveViewAvailable`, and either
`liveViewFrame()` (a JPEG, as Sony sends) or `liveViewPicture()` (a `LiveViewFrame` with a `CGImage`, as the Blackmagic
stream decodes to). `liveViewConfig` sets the pace for the link: `.cabled`, the network default, or `.stream` for video
that comes at the camera's own rate (no frame-rate choice, no auto-stop). `LiveViewSession` does the rest: one stream per
camera however many tiles watch, stopped when none do, restarted after an error, and back as soon as a camera that went
away is offered again.
