# Tiles — Architecture

## Modules

| Module | Kind | Purpose |
|--------|------|---------|
| `CameraCore` | Library | Vendor-neutral model (`CameraState`, `CameraBackend`, `CameraCommand`), page layout engine, mock backend, credentials, `LiveViewSession`, `HaLowMonitor`, `ControlServer` |
| `DashboardUI` | Library | SwiftUI tiles, pages, settings sheets. Depends only on `CameraCore`; knows nothing about PTP |
| `SonyPTP` | Library | Sony PTP session over PTP-IP (with the SSH tunnel) or, on a Mac, PTP over USB; state mapper. Implements `CameraBackend` |
| `SSHTunnel` | Library | libssh2-backed SSH port forwarder (`SSHPortForwarder`). Wrapped by SonyPTP |
| `BlackmagicRESTBackend` | Library | Blackmagic cameras over the Camera Control REST API and its WebSocket (HTTPS, certificate pinned on first use); state mapper; live view through the camera's livestream (`RTMPReceiver`, `AVCDecoder`). Implements `CameraBackend` and `LiveViewProvider` |
| `BlackmagicBLE` | Library | Blackmagic cameras over Bluetooth LE: the camera control protocol over a `BluetoothLink` (CoreBluetooth in the app, a fake in the tests). Implements `CameraBackend` |
| `SonySavona` | Library | Sony VENICE / VENICE 2 over the Web Remote's Savona API: MessagePack-RPC on a WebSocket (`SavonaClient`), `VeniceCameraBackend` (docs/venice.md) |
| `ArriWebRemote` | Library | ARRI cameras (ALEXA Mini, Mini LF, ALEXA 35, AMIRA) over the Web Remote's HTTP interface: `ArriClient`, the variables-to-controls mapping, `ArriCameraBackend` (docs/arri.md) |
| `camctl` | Executable | CLI against a real camera, or a fake one: Sony connect / dump / set / rec / watch; `bm` (Blackmagic), `venice`, `arri` (live, or `--from` a capture), `probe` |
| `sshtunnel-probe` | Executable | SSH tunnel smoke-test |
| `DashboardSnapshot` | Executable | Headless PNG renderer: `swift run dashboard-snapshot out.png W H [page] [mode]` |
| `App` | Xcode target | SwiftUI app entry point (`CameraControlApp.swift`). Wires `CameraCore` to every backend (`SonyPTP`, `BlackmagicRESTBackend`, `BlackmagicBLE`, `SonySavona`, `ArriWebRemote`) via `makeBackend` |

## The `CameraBackend` contract

Defined in `Packages/CameraKit/Sources/CameraCore/Backend.swift`.

```swift
public protocol CameraBackend: AnyObject, Sendable {
    var updates: AsyncStream<CameraState> { get }
    func connect() async
    func disconnect() async
    func send(_ command: CameraCommand) async
}
```

`updates` carries whole-state snapshots (`CameraState`). The `CameraController` that owns the backend
is the single consumer.

**Commands** (`CameraCommand`): `record(Bool)`, `setISO`, `setShutterAngle`, `setShutterMode`,
`setShutterSpeed`, `setKelvin`, `setTint`, `setWhiteBalancePreset`, `setFrameRate`,
`setFrameRateVariable`, `setIris`, `setNDPreset`, `setVariableND`, `setFileFormat`,
`setRecordingSetting`, `setResolution`, `setDesqueeze`, `setLUT`, `setLook`, `setFalseColor`,
`setColorBars`, `setImageFlip`, `setClipFlag`, `setFocusMode`, and more since (the full list is `Backend.swift`): among
them the BURANO's `setNDMode`, `setTally`, `setCall`, `setColorGamut` and `pressCameraButton(CameraBodyButton)`, and
`playback(PlaybackCommand)`, whose `.review` / `.live` are the Playback tile's Live | Review switch on every camera.

Backends ignore commands the body doesn't support. A backend whose `send` switches exhaustively (Blackmagic REST) has to
list a new command to compile; the others end in `default:`.

## `CameraState`

`Packages/CameraKit/Sources/CameraCore/Model.swift`.

Every field is optional, and everything comes from the camera's own property table (`StateMapper.map`):
- **No tile** when the camera doesn't have the property, or reports it IsEnabled = False (switched off in the
  current mode). `CameraState.offers(_:)` maps each tile kind to its field. Automatic pages leave those
  tiles out; customized pages hide them too, except in edit mode where they show grayed so they can be removed.
  A camera's last report is kept (`CameraProfile`), so its pages keep their shape while it's offline.
- **Grayed, read-only** when the camera reports DispOnly (`isSettable` is false), e.g. the FX3's bitrate under
  XAVC S-I.
- **Picker options** are the camera's "Enum value (Set)" list: what it will take in its current mode.
  So at XAVC S-I 4K the FX3 offers 59.94/29.97/23.98 and no 119.88. Sub-controls follow the same rule: no
  Fixed/Variable switch without S&Q on/off, no LUT On without the monitor LUT switch, no tint slider without tint.
- **Changing a property that other options depend on** (codec, frame rate, bitrate, base ISO, shutter mode, WB
  mode) triggers a full re-read, so dependent lists refresh even if their values didn't change.
- `fixtures/fx3-propinfo-full.bin` + `FX3CapabilityTests` pin what the FX3 offers; `camctl decode <dump>`
  prints what the app makes of any saved dump.

Two value types:

- `Choice<Value>` — a value picked from a list the camera offers (ISO, frame rate, …). Has `value`
  (camera-confirmed), `pending` (sent but not yet confirmed), `options`, `isWritable`, `restartRequired`.
- `Level` — a continuous value in a range (Kelvin, tint, iris). Has `value`, `pending`, `range`, `step`,
  `isWritable`.

Both expose `shown = pending ?? value` for display.

## REC rule

REC is **never optimistic**.

`RecordingControl` holds `state` (`unknown` / `idle` / `recording`), `request` (`start` / `stop`), and
`failure`. The backend sets `request` when a REC command is sent, then waits for the camera to report
the new state via `0xD21D` before clearing it.

`record(Bool)` is **absolute**: `record(true)` means "make sure it's recording". A camera already in that
state must ignore the command. This matters for linked REC across cameras, and because Sony's REC
mechanism on the wire is Hold-down/Hold-up, not a toggle — sending it to a camera that's already rolling
would stop the take.

On a timeout the backend re-reads recording state rather than retrying the command, with one exception: a stop
(Sony). A stop the camera didn't take, or still says it's recording through once the wait runs out, is sent once more:
Movie Rec (Hold) Up is absolute and the toggle is only pressed while the camera says it's recording, so neither can
start a take (an FX5 kept rolling after a linked stop until REC was pressed again). A start is never
sent again. A stop asked for while a start is still being confirmed replaces it rather than being dropped; a start
asked for while a stop is still being confirmed goes once the camera has stopped; and the wait runs on while a
recorder says the change is under way (Preparing, Stopping), 30 s at most.

Linked controls go out through `DashboardStore.fanOut` to `linkedPeers`: the other cameras on the current page while it
links that control. The value goes as it is; the frame rate tile asks first when the rate restarts this camera or any
linked one, and names them.

## Bandwidth rules (measured on FX3, 2026-10-09)

1. **One full read on connect**: `SDIO_GetAllExtDevicePropInfo` with `Param1=0x00000000` fetches everything (~9.5 KB on FX3).
2. **Events drive changed-only fetches**: a reader on the PTP-IP event channel runs continuously. On
   `SDIE_DevicePropChanged` (0xC203), wait 100 ms for more, then one changed-only fetch
   (`Param1=0x00000001`). A change announced while a fetch is in flight gets its own fetch afterwards.
3. **30 s safety poll**: a changed-only fetch every 30 s as a fallback for cameras that drop events.
   The camera's own 10 s keepalive probes keep the link alive; the poll is only a catch-all for missed events.
4. **REC time tile, not a timecode clock**: Sony PTP 3 on the FX3 carries no running timecode (0xD0D3 is the preset and never increments during a take). The tile counts from the take's start, runs locally in `CameraCore`, and shows the last take's length after stop. `CameraController.timeTake` gives every take its start, whoever started it: a backend's own (Tiles' REC, confirmed by the camera), else the moment Tiles saw the camera start (REC pressed on the body). A take still rolling after a dropped link keeps its start; one already rolling when Tiles first saw the camera has none (--:--:--), rather than a length made up.
5. **Commands sent once on release**: slider sends one command when the gesture ends, not on every frame.

Idle cost at these settings: ~60 B/s PTP payload (connect overhead aside), ~0.9 packets/s steady-state.
See `docs/network-budget.md` for full measurements.

**One PTP transaction in flight at a time.** The session serializes all operations over one TCP command
channel. A second command waits until the first response arrives.

## Reconnects and the background

`CameraController` reconnects after the link drops (`.failed` or `.disconnected`). It retries after 1, 2, 4, 8 s, then
every 10 s, and resets the delay once connected. The top bar's link meter lists a camera that's down as "Reconnect …":
a tap tries it at once (`reconnectNow`). A camera on USB doesn't wait for its retry: `USBCameraArrivals` (IOKit's
first-match notice on a Mac, an `ICDeviceBrowser` on iPhone and iPad) tells the store when one is plugged in, and its
controller reconnects then (`reconnectNow`). It doesn't retry after a changed fingerprint, which needs the user, or while
the camera is asking for pairing approval. On iOS, `scenePhase` → background calls `DashboardStore.suspendAll()`,
which closes every camera cleanly. The sockets would die in suspension anyway, and a clean close frees the FX3,
which serves one controller at a time. Returning to the foreground calls `resumeAll()`. A take in progress keeps
rolling: a closed or dropped session doesn't stop REC on the FX3.

## Sony links

`SonyCameraBackend` runs one Sony session over a `PTPTransport`: transactions one at a time, events, link state.
`PTPIPTransport` carries it over TCP (the camera's address, through `SSHPortForwarder` with Access Authentication, or
pairing without). `PTPUSBTransport` carries it over a USB-C cable on a Mac (IOKit's USB plug-in, IOUSBInterfaceInterface, which the
sandbox's `com.apple.security.device.usb` opens; the IOUSBHost framework's user client is refused inside the sandbox):
bulk containers out and in, events on the interrupt pipe. On iPhone and iPad,
`PTPICATransport` carries it through ImageCaptureCore (`requestSendPTPCommand`, events from `ptpEventHandler`), the way
Sony's Monitor & Control does; ImageCaptureCore opens the PTP session itself, so the Sony session runs inside it, and
it names the camera rather than giving its serial (`usb:ILME-FX3`). `SonyBackendConfig.usbLink` picks. A camera on USB is saved
with the host `usb:<serial>` (`USBCameraAddress`), and `connect()` branches on that first: no identity, tunnel or
pairing, just the interface opened by serial and the same `PTPIPSession`. Any failed transfer fails the whole link,
and the controller's reconnect starts it clean. On a Mac, IOKit's termination notice for the interface fails it the
moment the cable comes out, idle or not (`IOKitNotification.removal`); ImageCaptureCore's removal does the same on
iPhone and iPad. `LiveViewProvider.liveViewConfig` lets the link set the live view: 1 fps at Low over a network,
24 fps at High on a cable (`LiveViewConfig.cabled`). The viewer can choose otherwise per camera (`LiveViewSettings`,
saved with it), and a running stream restarts with the choice. Frames are decoded off the main actor.

## Blackmagic links

`BlackmagicCameraBackend` reads a few things over REST (product, formats, outputs, timecode), then subscribes to
everything else on the camera's WebSocket in one burst: the answers are the state, and pushes keep it current. A
ping times the round trip (the latency tile) and fails a stalled link. The API documentation the camera
serves (`/control/documentation.html`) is the reference; docs/pyxis-controls.md maps every control as the PYXIS
answers. Live view comes through the camera's livestream: `LiveViewConfig.stream`, Tiles' platform file pointing at
this device, `RTMPReceiver` and `AVCDecoder` turning it into `CGImage`s (`LiveViewFrame.image`, which
`LiveViewSession` asks for with `liveViewPicture()`). The camera won't stop a stream it's told to, so the stream
outlives live view by a minute and is stopped through Review (docs/pyxis-controls.md, Live view). What the API hasn't
got but the camera's presets have (status text by output, what it shows, the de-squeeze) is set through a preset of the
camera's own state with that one value changed (`BlackmagicPreset.swift`, docs/pyxis-controls.md, Presets).

## VENICE and ARRI links

Both drive the camera's own Web Remote, so both resolve every control by name from what the camera lists rather than
from a fixed table: candidate names first (from public code and Sony's or ARRI's documents), then a word match, and
whatever the camera lacks stays nil. `VeniceCameraBackend` speaks Savona (one request at a time; the page's login,
subscription and request shapes, since a VENICE 2 says nothing at all to a request in the wrong shape; a keep-alive
read every 3 s, which is also the latency; linked settings in one write; menu values through `VeniceMenu`). A VENICE
takes one client at a time, and its own web page and Tiles connected together trip it up, so Tiles has no Web GUI
tile (2026-10-28; until then one handed the connection over and took it back). What the camera
locks (`Property.GetStatus`) grays its tile through `isWritable`, and a command it can't take now isn't written at all
(`refusal`: a locked or read-only setting, or a value the camera doesn't list, which a linked page or the Control API
can send where its own tiles can't; docs/venice.md, Multicam). A function that lives on an assignable button (false
color) is pressed only when the camera says it's in the other state. Two shared fields came with it:
`MonitorOutput.follows` (an output the camera shows the same as another's; its overlays are that one's, grayed) and
`CameraState.offersFalseColorLUTSwap` (off where the LUT reaches every output and a recording, VENICE and ARRI, so the
LUT tile's FX3-style False Color swap doesn't). `ArriCameraBackend` reads `all.cgi` once, holds `update.cgi?id=` open
for changes (paced to `trafficBudget`, falling back to `all.cgi` polling), writes with `set.cgi` in order, and runs REC
and playback with `call.cgi`. Add Camera tells them apart by asking the address (`SonyRemoteProbe`, `ArriRemoteProbe`).
The VENICE backend was reworked against a real VENICE 2 on 2026-10-23 and is tested against an in-process copy of it
(`FakeVeniceCamera`); the ARRI one hasn't met a camera yet (docs/venice.md, docs/arri.md).

## HaLow nodes

`HaLowMonitor` (an actor; docs/halow-monitoring.md) finds and polls the mesh's nodes with nothing configured but their
password. A short Bonjour browse (`BonjourNodeBrowser`, `_http._tcp`) and the default gateway give candidates; each
gets a password-free OpenMANET check before it's sent the password; any answering node's OpenMANET API lists the rest
of the mesh. Nodes come out as one ordered `[HaLowNode]`, this device's node first, which the tile, the link meter and
Settings all read from `DashboardStore.haLowNodes`. Passes are serialized, a node gets one login at a time, and a reply
to a request sent before a settings change is dropped. Everything it reads is in OpenWrt's stock LuCI ACLs.

## Pages and layouts

`Packages/CameraKit/Sources/CameraCore/PageLayout.swift`.

A `PageLayout` is a list of `PageWidget` placements on a column grid. Heights are in *half-rows*, so
two half-height tiles can stack in one standard tile's space. A monitoring toggle (`WidgetKind.monitorOverlay`) also
carries the outputs it switches, `PageWidget.targets` (empty: every output): `output` for one, `outputs` for several
(saved only with two or more; `output` keeps the first, so an older build switches that one). Set in edit mode, the
same tile in the page's layout and the iPhone's (`DashboardStore.setWidgetOutputs`, `LayoutTemplates.phone`), saved
only when set, and part of `sameArrangement`, so it keeps a page customized. `CameraState.monitorSwitch(_:outputs:)`
turns it into what the tile shows (lit only when every chosen output shows it) and sends (`MonitorSwitch.commands`:
one command per output).

**Editing with a camera offline** (`PreviewState.swift`): edit mode draws a camera that isn't connected through a
stand-in, `DashboardStore.previewController(for:)`: a `CameraController` with the camera's own slot (id, letter,
color), sample values for its model (`MockCameraBackend.pyxisSampleState` for a Blackmagic camera, the Sony body it
reported otherwise) and the outputs it reported last (`CameraProfile.outputs`), marked demo, with a backend that is
never started. Only `GridPageView` in edit mode, Add Tile (`tileKinds(for:)`) and a new tile's starting output use it;
the camera's own controller, its saved profile and the Control API never see it, so nothing can be sent to a demo by
mistake. `moveTiles(_:from:to:)` gives every tile of one camera on a page to another (the camera chip's menu).

**Test Mode** (`DashboardStore.testMode`, saved as `testMode.v1`; Settings, the signal bars' menu, and the TEST
badge in the top bar while it's on): the
stand-in becomes a working demo on every page, a started `MockCameraBackend(state:)` from the same values, so the
page can be used as well as laid out with the camera off. The mock plays a Blackmagic camera's demo too: overlays per
output (LUT and False Color on every output), status text, zebra level, frame guides, dynamic range, off-speed rate.
`shownController(for:editing:)` picks what a tile draws and works (the camera, or its demo while it isn't connected:
in edit mode, or anywhere in Test Mode), and `shownCamera(_:)` does the same for the sheets a tile opens. The camera
takes over as soon as it connects; switching Test Mode stops the working demos and makes still ones again.
`noteConnectionChange` (from each camera's state updates) drops a camera's stand-in once it connects (in or out of
Test Mode), and in Test Mode sets `testModeNotice`, which the dashboard shows for 3 s with a success or warning tap.
A camera's first report isn't a change, so launching doesn't announce anything.

**Moving tiles** (`TileMove.swift`, 2026-10-16): `PageLayout.dropSpot` decides where a dragged tile lands from
its center, on the layout as it was when the drag began: over another tile, that tile's top-left (so the two swap
however roughly aimed); over empty cells, where it snapped; still over its own place, it stays unless only nudged
into free cells. `PageLayout.moving(_:to:)` then moves it there, never changing a size: the tiles in its way take
the place it left, together and as arranged, when they fit (a swap, or the strip it uncovered when it only slid part
way); otherwise they, and whatever they then land on, move down just clear of it. `GridPageView` draws that while
the tile is held, once the finger has rested on a spot for 200 ms, and `DashboardStore.moveWidget` saves it on the
drop. Resizing (the corner) still refuses an overlap.

A tile held at the top or bottom edge scrolls the page a half-row at a time (`GridPageView.scrollAtEdge`, 2026-10-18).
The finger finds the edge, not the tile: a tall tile held near its own bottom would never reach it. `DragState` keeps
how far the page had scrolled when the tile was picked up, so the tile and its drop spot follow the page
(`moved(_:)`). The scroll view is disabled while a tile is held, and a disabled `ScrollView` takes no `scrollTo`
either, so it's enabled while the edge scrolls. Each half-row's anchor has its own id type (`RowAnchor`). With plain
`Int` ids, `scrollTo(1)` found the edit grid's numbered backdrop cells first and scrolled to the second cell of the
top row, so the page never moved past its first rows. Edit mode defers the system's top and bottom edge gestures, so
holding a tile there doesn't pull down Notification Center.

**Undo** (`DashboardStore.editUndo`): every edit that changes the page (move, resize, add, remove, output, camera,
Fit to Screen) saves the whole `CameraPage` first, up to 50. `undoEdit()` puts the last one back, and the list is
emptied when editing begins (`beginEditing`) and ends (`finishEditing`). A refused edit (an overlapping resize, a
move to where the tile already is) saves nothing. Making an automatic page explicit to edit it isn't an edit.
Haptics (`EditHaptics`): a light tap on pickup, a selection tick each time the page makes room somewhere new, and a
medium tap on a drop that moved something.

**Every page draws through one grid** (`GridPageView`). Automatic pages (no saved layout) pick a block per camera
from the width available: a column of 480 pt or more gets the 4-wide block from `LayoutTemplates.block` (an FX3,
FX3A or FX30 gets `fx3`, a Blackmagic camera `blackmagic`, picked by `CameraProfile.make`, others `wide`); narrower columns (three or four on an iPad, or an iPhone) get the 2-wide
`narrow` block, REC full width at the bottom; with several columns, each REC that ends its column is stretched to
the page's bottom row so they line up. Tiles for controls the camera doesn't offer drop out.
`LayoutTemplates.closingGaps` closes the holes they leave and touches nothing else: a strip that keeps all its
tiles stays exactly as arranged; in one that lost tiles, stacks move left into freed columns and the last takes the
spare; an emptied strip goes and the strips below move up.

**A phone on its side** (`DashboardView.shortPager`, 2026-10-18): below 480 pt of height, a page of several
cameras shows one at a time, as wide as the screen. Side by side, four 2-wide columns left every tile a sliver a few
points tall. `LayoutTemplates.shortScreen` picks what each camera shows:
- Its part of the page (`PageLayout.cropped(to:)`: its tiles on a grid of their own, and their `origin` on the page),
  when that's a 4-wide block. A page of one or two cameras, customized or not, has them side by side four columns each.
- Otherwise (three or more cameras, two columns each) its 4-wide block, changed where the page was
  (`LayoutTemplates.phone(camera:profile:page:wide:)`, the iPhone column's rules on the wide block).

Cameras are swiped between, or picked from `CameraChips` in the top bar, where the camera strip would cost rows.
The pager is `.clipped()`. A scroll view reaches into the safe areas on its sides and starts its content inside them,
so on an iPhone with a notch or Dynamic Island the next camera showed a strip in the right-hand one.
Editing works on the shown camera without the pager. `GridPageView.origin` takes moves and resizes back to the page,
and everything else goes by tile id. A 4-wide part is edited as shown, so nothing moves on the way in. A 2-wide part
(three or more cameras) is edited as it is on the page, rows floored at 17 pt and scrolled (`floorRow`). The 4-wide
block shown in use isn't the page's arrangement, so edits can't go through it.

On any page, Add Tile places a tile in its camera's own columns where it fits (`firstFreeSpot(w:h:in:)`), so on a
page of two cameras a tile for A never lands in a gap among B's. On a phone on its side, Add Tile starts on the camera
shown.

Row height (`GridMetrics`): the rows of the page's automatic layout always fit the screen, so REC is never below the
fold. Tiles added past them shrink the page down to a 17 pt half-row, and then it scrolls; with Fit to Screen off
(`CameraPage.scrolls`) the rows keep the automatic layout's height and added tiles scroll from the start. Edit mode
uses the same metrics, and the edit bar replaces the top bar at the same height, so editing never moves or resizes a
tile; its spare rows sit below, reached by scrolling. While editing, rows keep the height edit mode opened with
(`GridPageView.keptRows`, measured again when the space or Fit to Screen changes): a page that grows as tiles move
scrolls instead of shrinking every tile, and fits again on Done. Add Tile scrolls the page to the new tile and
outlines it. The edit bar is the most of title, hint and controls that fits on one line (`ViewThatFits`); on an
upright iPhone it's Add Tile and Done, with Fit to Screen and Reset under ⋯.

Pages the app builds (the demo pages, the page an FX3 gets once it isn't the only camera) are automatic, so they always
follow the current templates. Only a user's edit saves a layout: entering edit mode starts from
`LayoutTemplates.materialize(cameraIDs:wide:profile:)`, the same blocks. A saved (customized) page is shown
through `closingGaps(in:keeping:)`, per camera within its own columns, so a hidden tile never leaves a hole.
Edit mode shows the arrangement as saved, with missing controls grayed out.

The templates hold only what the cameras carry. Color bars and sensor flip are VENICE web-control features:
a VENICE's own block (`veniceCells`, picked by `CameraProfile.isVenice`) has them, with the LUT, de-squeeze, imager
mode, the outputs' frame lines, false color and status info, and playback. An ARRI camera's block (`arriCells`, picked
by `make == .arri`) adds zebra and peaking to the outputs' switches. A Blackmagic camera's block is the PYXIS page (`blackmagicCells`):
its HaLow tile shows only once this device has found a HaLow node (`DashboardStore.haLowSeen`, remembered, so the page
keeps its shape at launch; `CameraController.templateProfile`). False Color, the outputs' LUT (View Assist's kind),
Monitoring Options and Dynamic Range are in the narrow template too; no Sony body has them, so a Sony page closes up
exactly as before (`LayoutTemplates.shows`).

**iPhone arrangements**: a phone shows one camera at a time in two columns, so editing there writes that camera's
own layout (`CameraPage.phoneLayouts[camera]`, `LayoutTarget.phone`), not the page's. It starts from what the phone
was showing. Without one, a camera shows `LayoutTemplates.phone(camera:profile:page:)`: its own 2-wide column,
changed only where the page was. Tiles taken off the camera's automatic block come off the column, and tiles added
to the page follow the column's own, at phone size (`phoneSize`: at most two wide, never a lone half row), under the
same ids. So a page customized on an iPad keeps the phone's design, and customizing one camera never rearranges
another. `compact(_:camera:)`, the reflow builds before 8 showed, survives only so the v8 migration can recognize
saved copies of it and drop them.

`CC_SNAPSHOT_STATE=<dashboard.v1 JSON> swift run dashboard-snapshot …` renders a device's saved setup.

**A saved setup from a newer build** loads with what this build can read: a camera or profile of a kind it doesn't know
(a connection case added later, as VENICE and ARRI were added after launch) is left out (`Lenient`), rather than the whole
setup failing to decode and the app starting empty. Tiles a build doesn't know are dropped the same way
(`PageLayout`).

## Link groups

Link groups are per-page and **off by default**. Four kinds:

| Kind | Linked controls |
|------|----------------|
| `whiteBalance` | WB preset, Kelvin, tint |
| `frameRate` | frame rate, variable frame rate toggle |
| `shutter` | shutter angle, shutter speed, shutter mode |
| `record` | REC |

When a page has linking enabled and a command is sent to one camera, it fans out to all cameras on the
page that have the same `LinkKind`. Fan-out is **absolute**: each camera receives the same command
value, not a toggle.

Linked tiles show a chain badge. Tapping the chain button on a page opens the link menu where the user picks which link kinds are active.

## Credentials

**Camera passwords** live in Keychain via `KeychainCredentialStore` (service
`com.toldwell.cameracontrol.camera`, keyed by camera UUID). Never in `UserDefaults`. The HaLow nodes' one password is
in the same store under `haLowPasswordID`.

**Initiator GUIDs** (one per camera host) live in Keychain via `KeychainInitiatorIdentityStore`
(service `com.toldwell.cameracontrol.guid`, keyed by host string). The app sends the friendly name
`"Tiles"` to cameras during pairing.

**SSH host-key fingerprint** (TOFU): on first Access Authentication connect, the observed fingerprint is
stored in `SonyConnection.trustedFingerprint` (persisted with the camera config). A subsequent connect
with a different fingerprint sets `ConnectionState.fingerprintChanged(observed)` and halts — the user
must confirm before the session proceeds.

Fingerprints are in OpenSSH form: `SHA256:<unpadded base64>` (no trailing `=`). Comparison ignores
`=` padding.
