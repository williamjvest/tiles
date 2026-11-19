# Sony VENICE and VENICE 2: how Tiles could control them

Research of 2026-10-20, rewritten 2026-10-22: the protocol is public now. Sony never published it, but open-source
implementations exist. VENICE 1 and VENICE 2 serve their Web Remote over Sony's **Savona** API — a WebSocket at
`/linear` speaking MessagePack-RPC (`[0,id,method,params]` requests, `[1,id,error,result]` responses,
`[2,name,data]` notifications), with a login handshake, property read/write, notifications of every change, and
key-press commands. Capturing a session now confirms names and behaviors rather than decoding anything.

## The open-source Savona implementations (found 2026-10-22)

- **ckohen/savona** (MIT, npm `@ckohen/savona`, newest, tested on a PXW-Z190V) — the full protocol: connection,
  the nonce/digest login (`Alternate.Authentication.GetNonce` → HTTP-Digest GET `/cgi-bin/getsavonadigest.cgi?nonce=…`
  → `Alternate.Authentication.Digest` with the cnonce/response that CGI returned), `Notify.Subscribe`
  (`Notify.Properties`, `Notify.Process`, `Notify.Property`, `Notify.Capability`), `Property.GetValue` /
  `SetValue` (`[{Name: ["*"]}]`), `Capability.GetValue` (allowed values), `Clip.Recorder.Open/Start/Stop`,
  `Button.SendKeys` (`[["Rec"]]`), `System.GetProperties` (every property name the camera knows), and a
  keep-alive (`Property.GetValue` on `Network.Connection.KeepAlive`) plus a 5 s connection check. Notifications:
  `Notify.Property.Value.Changed` etc. carry `{name: value}` records. Its Companion module
  (ckohen/companion-module-sony-savona) shows **Button.Assign**: the camera reports each assignable slot's function
  *and its On/Off state*, can set a slot (`{Button.Assign: {Assignable.N: [function, On]}}`) — so user
  buttons are assignable, pressable and *state-reporting* — and "press" for something unassigned is done by
  temporarily reassigning a slot, pressing, restoring. Also `globalStatus` read/write/execute flags (is remote
  control allowed right now).
- **dlid/savona** (MIT, 2022, the predecessor) — the older login: `/cgi-bin/getsavonacred.cgi` returns separate
  Savona credentials used for `Alternate.Authentication.Basic`. So two firmware generations of login exist; a client
  should try digest, then basic.
- **bryanrandell/Sony_websocket** (2022, no license — facts only, no code) — a DIT's Wireshark captures from a
  VENICE: real frames for ND (`{Camera.NDFilter.Mode: Preset, Camera.NDFilter.Value: 2/4/…/256}`), EI
  (`Camera.Gain.ExposureIndex.Value: "1250EI"`), iris fraction, `Button.SendKeys` `Rec` / `InsideClips` /
  `Assignable.2`, one menu write (`P.System.Menu.Timecode`), and the keep-alive. It also lists the 352 property names
  a VENICE's web page uses, with example values: 229 `System.Menu.*` (markers/frame lines, monitor OSD info, output
  sizes, SxS de-squeeze, color bars…), `Clip.Mediabox.*` (22: clip name, playback mode/speed, duration,
  `AllClipPosition`/`AllTotalClips` — jog and gate check), `Camera.Shutter/Iris/WhiteBalance/Gain/Focus/Zoom`,
  `System.Battery.*`, `Storage.Media.*`, `Assignable.1–4`, `VFAssignable.A–C`. Looks like VENICE 1 (SxS, full-frame
  license key): names may differ on VENICE 2.

What this leaves open: VENICE 2's exact names (dump them from the camera), which login it uses, playback key names
beyond Rec/InsideClips/Assignable, on-camera WB/shutter presets (`Property.AddValue`/`DeleteValue`?), and the
reconnect/crash behavior. `scripts/venice/venice.py savona` drives all of it — both logins,
`--dump` reads every property the camera knows into `savona-dump.json`, `--keys` presses, `--listen` watches; its
MessagePack decoding is validated against Bryan's captured VENICE frames.

## The way in: the Web Remote's WebSocket

- **The Web Remote** is at `http://<camera IP>/rm.html` (Sony's guide) and uses the camera's login (Technical >
  Authentication). MultiVENICETool (github.com/sethdotfm/MultiVENICETool, Dec 2025) runs on three VENICE 2s.
  - It goes straight to `/rmt.html`, logs in with HTTP Digest, and finds REC as the element `BUTTON_REC_BUTTON`.
  - It doesn't speak the protocol: it drives the camera's own page in a headless Chrome and clicks that button.
  - Its earlier tries relayed the page through a plain HTTP proxy and didn't work, which fits a page that needs a
    WebSocket.
  - Reached over wired LAN, or Wi-Fi with the CBK-WA02 adapter.
  - VENICE 1 got it in firmware 2.0 (2018); its last firmware is 6.30 (2023). VENICE 2 has had it from launch.
  - Sony's CineAlta Remote Control Guide V2.0 (May 2025, 26 pages, read in full 2026-10-20; it covers VENICE 1 and 2
    together) lists the Web Remote's screens:
    - Camera: the sub display's Home items.
    - Lens: zoom, focus, iris.
    - Info: camera, media, battery.
    - Full Menu: the whole camera menu.
    - Playback, with HOME and CLIPS buttons.
  - Over the same network, VENICE 2 (firmware 3.0 on) takes LUTs, CDLs and ART files, and CDLs adjust through the web
    interface.
  - Verified browsers include Safari 17 on iOS and iPadOS, so the page's protocol works from Apple's networking stack.
  - The guide says nothing about how the page talks to the camera.
- **SkaarHoj `core-sony-websocket`** ships VENICE 2 as released and VENICE 1 as beta.
  - Its own description: "Core to control Sony cameras with a web interface over a websocket connection"
    (devices.skaarhoj.com/core/core-sony-websocket).
  - The same core drives the FS7, FX9, PXW-X400, PXW-Z280 and PXW-Z750, so it's one protocol family, and any of those
    cameras would do for decoding the transport.
  - Its public manual lists the 56 properties it uses, by name (cloud.skaarhoj.com/coremanual/core-sony-websocket/pre/7).
    These are presumably the camera's own:

| Tiles tile | SkaarHoj property (VENICE 2) | Values |
|---|---|---|
| ISO / base ISO | `Camera.Gain.ExposureIndex.Value`, `Camera.Gain.ISOValue` | dynamic options; 0 Normal, 1 High |
| Shutter | `Camera.Shutter.Value`, `Camera.Shutter.Mode` (Speed, Angle, ECS), `Camera.Shutter.Value.DisplayValue` | dynamic options |
| ND | `Camera.NDFilter.Value`, `Camera.NDFilter.Mode` | 1 Clear, 2 0.3, 4 0.6 … 256 2.4 |
| WB | `Camera.WhiteBalance.ColorTemperature.Value.Venice`, `…Tint.Value`, `Camera.WhiteBalance.AutoWhite` | 2000–15000 K; −99…99 |
| Iris | `Camera.Iris.Value`, `Camera.Iris.SettingMethod` | f/1.9 … Closed |
| S&Q | `Camera.SlowAndQuickMotion.Enabled`, `…FrameRate.Venice` | |
| REC | `Clip.Recorder` | binary, delayed feedback |
| Timecode | `Clip.Mediabox.TimeCode.Value`, `P.Clip.Mediabox.TimeCode.Type` | |
| Media | `P.System.Menu.WebInfo.Media.AXSA` / `AXSB` / `SDCard.RemainingPercent` | |
| Battery | `System.Battery.Active.Remain.Voltage` | volts |
| Camera ID | `System.CameraID`, `System.CameraID.Color` | |
| Audio meters | `Output.Audio.dBLevel` | 4 channels |
| Assignable buttons, menu and playback keys | `Assign` 1–7, A–C; Menu, Set, Cancel, Up, Down, Home, Clips; Play, Stop, Next, Prev, Forward, Rewind | one-shot |

These are SkaarHoj's labels. Its manual (core-sony-websocket v1.0.3-pre1, read 2026-10-29) gives each key's name on the
wire: `Menu` ("Open/Close camera menu"), `Set`, `Cancel` ("the Cancel/Back button"), `UpArrow`, `DownArrow`, `Home`,
`InsideClips`, `Play`, `Stop`, `Next`, `Prev`, `Forward`, `Rewind`. The camera's own page (KeyConverter.js) sends `Set`,
`UpArrow`, `DownArrow`, `Home` and `InsideClips` too; `Menu` and `Cancel` aren't on it. Its `Output.Audio.dBLevel` is
an integer 0–24 per channel.

- **Cyanview RCP** controls VENICE 1 and 2 in a "Sony Venice IP" mode. It needs only the camera's IP and its login,
  with RM/RCP Paint Control off (support.cyanview.com/docs/Integrations/Sony/SonyVenice), which points to the same
  interface.
- **SmallHD monitors** (a licensed feature) also take the camera's IP and login (guide.smallhd.com, "Sony Venice wired
  camera control").

## Not ways in

- **PTP-IP**, the FX3 and BURANO route: VENICE isn't on it. Sony's listing for PTP-IP network control includes BURANO (MPC-2610)
  and no MPC-3610 or MPC-3628 (checked 2026-10-20). Sony's Monitor & Control app doesn't support it either.
- **Firmware files**: 180–240 MB proprietary `.bin`s. The Web Remote's code isn't readable in them.
- **The 8-pin REMOTE connector** (RM/RCP paint control) and **Sony's CNS-Bridge LAN protocol for RCP panels** are Sony
  system protocols with no public documentation.
- **Sony's Camera and Display Plugin** (a free Unreal Engine plugin, v3.0.1, March 2026). Its Camera Control Panel
  (VENICE only) logs in with the camera's username and password and shows the camera's own web remote. Its Live
  Camera Sync and Save / Configure Camera read and write camera and lens settings over the network (user guide). So
  even Sony's own software reaches VENICE through the web remote's login. It's Windows-only, and Tiles doesn't use
  it.

## What it has to control

The controls a VENICE's operator reaches for, against Tiles' tiles. The properties are SkaarHoj's, from the table
above; a ? is what the capture has to find.

| Control (VENICE values) | Tiles tile | Property (VENICE 2, 2026-10-23) |
|---|---|---|
| REC, with status | REC | `Button.SendKeys [["Rec"]]`; `Storage.Media.Recording` |
| Timecode | Timecode (tap: the clip's duration) | `P.Clip.Mediabox.TimeCode.Value`; `P.System.Menu.TimecodeDispTc` |
| Clip name, current or last | Naming | `Clip.Mediabox.ClipName` |
| Media: SxS A/B, AXS A/B, time left, low-media warning | Battery / Media | `Storage.Media.AvailableTime` per slot |
| AXS slot change, A ↔ B | not in Tiles | the `AXSSlotChange` assignable function |
| Frame rate with imager mode and project fps; S&Q on/off and rate | Frame Rate, Resolution | `Camera.SlowAndQuickMotion.*`; `P.System.Menu.SystemFrequency`, `CamImagermode` |
| Resolution, opening the recording settings | Resolution, Codec | `P.System.Menu.CamImagermode`, `AxsRecformatSelect` |
| Camera letter | Naming (ID, reel, position) | `P.System.Menu.ClipnamingCameraid` / `ReelNum` / `Cameraposition` |
| Shutter: angle 5.6–360° (presets 360, 180, 172.8, 144, 90, 45, 22.5, 11.2, 5.6), speed 1/24–1/2000, fine steps of ±0.3°, custom presets synced to the camera | Shutter, Shutter Dial | `Camera.Shutter.*`, `P.System.Menu.ShutterMode`; the camera's own step list (presets edited on it) |
| EI; base ISO Normal / High | ISO / EI | `Camera.Gain.ExposureIndex.Value`, `Camera.Gain.ISOValue` |
| ND: Clear, 0.3 … 2.4, steps | ND (with its Step buttons) | `Camera.NDFilter.*` |
| WB: 2000–15000 K, tint −99…+99; presets 3200, 5600, 6500, 7500 and 4200 +8 tint | White Balance, Temp / Tint | `Camera.WhiteBalance.ColorTemperature.*`; the presets are the camera's own steps |
| AWB | not in Tiles | the `AutoWhiteBalance` assignable function; `Camera.AutoWhiteBalance` read Locked |
| On-camera WB presets: read on connect, save the current WB as one, delete; optionally push the app's list on connect | White Balance (read) | the steps' capability lists; saving and deleting not in Tiles |
| Shutter presets kept on the camera ("custom preset management with sync to the camera") | Shutter (read) | the camera's step list |
| Playback: play, pause, stop, FF, REW, previous / next clip, Clips (the camera's clip list), back to live | Playback | `Play`, `Stop`, `Forward`, `Rewind`, `Next`, `Prev`, `InsideClips`, `Home`. Review sends `InsideClips` and, once the camera says the clip can play (`Clip.Mediabox.PlaybackEnabled` `{"selectClip": true}`, about 5 s later in the 2026-10-23 capture, which also shows it opening on the last clip, 6 of 6), `Play` if the clip is still at speed 0 (it opens paused: a black picture). `Forward` and `Rewind` run at 4× and −4× until Play or Stop; `Play` during a scan pauses it (4 to 0 in the capture), so letting go of a held ▶▶ / ◀◀ sends `Play` twice to play on. The capture never pressed `Forward` twice running, and nothing in the master read takes a speed (`P.Clip.Mediabox.Speed` is a reading): no 2× that we know of. **Build 57, to check on a VENICE:** the Review auto-play, the let-go, and what a second `Forward` does |
| Gate check: play the last take | Playback | Review (above) |
| Pick a clip from the list | Clips | `Clip.Mediabox.AllClipPosition` of `AllTotalClips`, both `{"main": n}` and -1 on the live picture (the 10/23 capture: InsideClips opened 6 of 6 in 3.5 s, Prev went to 5 in 0.4 s, paused, Next back). Into playback (InsideClips), then `Next` / `Prev` a clip at a time to the one picked, then Play once it can play. The Playback tile read the position as a plain number before, so it never said which clip on a VENICE 2. Never from Tiles on a camera |
| Jog slider (VENICE has no scrubbing) | no | — |
| Sensor flip | Sensor Flip | `P.System.Menu.FlipImage` |
| Color bars | Color Bars | `P.System.Menu.ColorBar`, `Camera.ColorBar.Enabled`, or the `ColorBar` button |
| SDI info; monitor-out status info | Status Text, by output | `P.System.Menu.*OsdDisplayInfoOnoff` |
| Monitor-out frame lines | Frame Guides, by output | `P.System.Menu.Marker*Onoff` |
| User frame lines A and B | User Frame A, User Frame B | `P.System.Menu.MarkerAUserBoxOnoff`, `MarkerAUserBox2Onoff` (B likewise); the `LineA/BUserFrameDisplay` functions step through the same four states |
| Monitor-out false color | False Color, by output | the `FalseColorMonitor` / `FalseColorVF` buttons |
| De-squeeze on the outputs: on/off and ratio (1.3×, 2×) | De-squeeze | `P.System.Menu.RecOutDeanamoScaleSelect` |
| Web GUI, opening already logged in | not in Tiles (the tile went 2026-10-28: the page and Tiles together trip the camera up) | none |

- **The outputs' own names on VENICE 1's page** (bryanrandell/Sony_websocket's 352-name table), which Tiles tries
  first: frame lines `System.Menu.MarkerSdiOnoff` / `MarkerMonitorOnoff` / `MarkerVfOnoff`; the info overlay
  `System.Menu.SdiOsdDisplayInfoOnoff` / `VfOsdDisplayInfoOnoff` / `MonitorOsdDisplayInfoOnoff`; the VF zebra
  `System.Menu.EvfZebraOnoff`; LUTs `Output.Video.SDI.LUT.Value`, `Output.Video.ViewFinder.LUT.Value` and
  `New.LUT.Monitor`. The dump shows VENICE 2's.
- **The user buttons** (sensor flip down to AXS slot change) "share the same assignable slots as on the camera". So
  they probably work by assigning the function to one of the camera's assignable buttons and pressing it (SkaarHoj's
  `Assign` 1–7, A–C), and there are only so many slots. SkaarHoj reads each slot's name (`Assign_Name`), so which
  function sits where is readable. If the camera doesn't report their on/off state, those one-tap tiles can't light
  up. The capture has to show which.
- **Beyond this list**, Tiles has iris and battery tiles, which SkaarHoj reads, and the Web Remote's Lens screen
  also has zoom and focus.
- **App-side**, not camera controls: Rec Lock, page lock, macros and quick presets, Reconnect and Reconnect All.
  Tiles already has link groups. A Reconnect tile is worth adding with VENICE, since the camera can crash on reconnect
  loops (Rules, below): auto-connect off plus a Reconnect button.

## Plan

1. Get one session with a VENICE, a VENICE 2, or (same family, easier to borrow) an FX9 or PXW-Z280 on the network.
2. Save `rm.html` / `rmt.html` and every script it loads (the page's JavaScript names every command it can send),
   and record a session in the browser's developer tools: the WebSocket upgrade (path, port, headers, how the Digest
   login is passed) and every frame while touching each control in the list above, one at a time, noting which.
   Include a user button, to see whether the camera reports its state. The page exists only on a camera: firmware
   files are encrypted.
3. Map the frames against both tables and fill in the ?s. A backend then follows the Blackmagic REST one: connect,
   subscribe, a state stream from the frames, commands as property writes.

## Tiles' backend

`Packages/CameraKit/Sources/SonySavona`, built 2026-10-22 before any camera and reworked on 2026-10-23 against a real
VENICE 2 (the next section):

- `MessagePack.swift`: the codec, byte-exact against captured VENICE frames; `decodeAll` reads several messages from one
  frame and keeps a split tail for the next; padded strings ("B020C004\0") are trimmed; `unwrapped` takes a single
  value out of `{"cam"|"main"|"sdi1"|…: value}`.
- `SavonaClient.swift`: one request at a time (the reconnect-crash rule); the page's login first
  (`getsavonacred.cgi` → `Alternate.Authentication.Basic [{…}]`), the older nonce/digest one as a fallback;
  `Notify.Subscribe` in the page's shape; a fresh notification stream for every connection (a failed attempt used to
  finish the only one, leaving every reconnected session deaf).
- `VeniceCameraBackend.swift`: each control resolved from candidate property names (a `Property.GetValue` sweep of all
  of them and their `P.` twins, since VENICE 2 doesn't answer `System.GetProperties`), plus a word match. Linked
  settings go out together in one `Property.SetValue` as the page sends them (`writeAll`); menu switches as "0"/"1";
  menu values through `VeniceMenu` (the page's `WebMenu.js` tables: imager mode, project rate, recording format, flip,
  shutter mode); each output's LUT as a `base#key` slot of the two LUT maps; a 3 s write timeout, the page's own. The
  keep-alive goes every 3 s and its round trip is the latency tile. A refused connect (the camera still holding its
  last client) retries twice, 3 s apart. Imager mode, format, project rate and de-squeeze are `restartRequired`, so
  their tiles ask first. Tiles has no Web GUI tile (2026-10-28): the page and Tiles can't share the one
  connection, and handing it back and forth from a tile is a way to trip the camera up on set.
- The look (built 2026-10-23 evening from the session's capture): the LUT picker lists every look the camera has
  (`looks`: the presets as the page names them, R709(800%) for `R709_800%`; then "User N: file.cube" for each user 3D
  LUT slot and "ART N: …" for ART, a slot still on the factory `s709` left out). Picking one loads it (the selection
  alone in the same mode, as the page sends it; mode and selection together when the mode changes, as proven on the
  camera) and puts every output showing a LUT on Look, so they all show it. Each output's switch is Log or its last
  LUT. HDMI has a LUT of its own (`#hdmi`). The LUT tile's FC swap is off (`CameraState.offersFalseColorLUTSwap`):
  the look reaches SDI and a ProRes recording, and the camera has its own false color.
- False color presses the assignable button Exposure Assist (`FalseColorMonitor`, `FalseColorVF`) is on, only when
  `Button.Assign` says it's in the other state (the key toggles); color bars go through the menu while its item is
  unlocked, else `Camera.ColorBar.Enabled`, else a button `ColorBar` is on.
- Locks: `Property.GetStatus` on connect for what Tiles writes and the menu items behind them (`VeniceMenu.menuLocks`),
  then `Notify.Property.Status.Changed`; a locked one's tile grays. A write the camera answers and doesn't act on
  (a locked item) is re-read after 2.5 s (`settleLater`) rather than shown as pending for good.
- Outputs the camera links (`OutputFormat.Info.*`, below) show the other output's overlays, grayed, with a "Same as"
  note in the monitoring window, and are left out of writes to every output; their LUT stays their own.
- The model: `System.ModelName` says "PXW-X180", so the 8.6K imager modes it offers make it an MPC-3628 (VENICE 2);
  the base ISO pair comes from its own reading ("ISO 2500" is a 6K sensor's).
- Loading a LUT (Settings → the camera, or the LUT picker's "Load LUT onto camera…"): `upload.cgi` as the page posts it,
  into a user 3D LUT slot, the file named as the camera's page allows (characters it can't hold become "_").
- The timecode counts at the project rate (`timecodeRates`: 23.98 → 24 at 23.976, 25, 29.97 → 30; 47.95, 50 and 59.94
  in frame pairs until a frame number says otherwise). The camera reports it about ten times a second while it runs;
  the clock runs in Tiles between reports, and a report it already shows changes nothing, so the page isn't redrawn
  ten times a second. Only a changed state leaves the backend (the audio meters notify as often).
- Peaking (`P.System.Menu.PeakingOnoff`) is one switch for the viewfinder and the Monitor out, as Focus Assist on both.
- Option lists: the camera's own (`Capability.GetValue`, and its capability notifications) win; Sony's VENICE 2 manual
  tables (`VeniceTables`, `VeniceDesqueeze` in CameraCore, checked below) stand in where it lists none. The tables go by
  the mode's and the format's names, which VENICE 2 reads as menu values ("17", "3"): given "17", Select FPS found no
  row and offered up to 60, 48 in open gate included (reported 2026-10-27, a VENICE 2 in X-OCN ST at 23.98: "it
  won't let you get there in open gate 8k but it did on the tiles, which tripped the camera up").
- Lists that change with the mode are read again after the imager mode, the recording format, the project rate or the
  base ISO changes (`relistLater`): nothing says the camera announces them, and its own page asks for Select FPS's list
  each time it opens it (this capture). Select FPS takes Sony's table for the new mode at once, then the camera's list
  1.5 s later; the menu's allowed lists keep their old ones if the camera doesn't answer. With no list from the camera a
  Select FPS outside Sony's for the mode isn't sent either, and whatever isn't sent goes in the Activity Log.

Add Camera → Sony → Camera: VENICE · VENICE 2 (or let the address probe pick). Test Mode and the demo bodies use
`veniceSampleState`; the page is `LayoutTemplates.veniceCells`. `camctl venice HOST -p PASS
[--get/--set/--keys/--call/--send/--dump/--listen]` and `camctl probe HOST` drive the same code from the command line
(`--send lut=NAME`, `desqueeze=1.6x`, `falsecolor:Monitor=on`, `bars=on` go through the backend as a tile sends them).
`Tests/SonySavonaTests/FakeVeniceCamera.swift` is the real camera in-process (its reading from `master.json`, its
shapes, its silences), and `VeniceBackendTests` drive the backend against it.

## Multicam (2026-10-26)

A page of VENICEs, or a VENICE
beside other cameras, uses the same pages and link fan-out as two FX3s or an FX3 and a PYXIS
(`DashboardStore.linkedPeers`): a linked control set on one camera goes to every other camera on the page.

- **One connection each.** Every VENICE has its own `VeniceCameraBackend` and Savona client, with nothing shared
  between them (no static state in `SonySavona`). Two never turn each other away, and one dropping out leaves the
  rest working.
- **REC is absolute.** A VENICE's REC is a toggle key, so a linked REC presses it only on a camera in the other state.
  A VENICE already rolling isn't pressed, which would stop its take.
- **White balance, shutter and Select FPS follow**, written as the camera's own page writes them. EI isn't a linked
  control.
- **What a camera can't take now isn't sent to it** (`VeniceCameraBackend.refusal`). That covers a setting it has
  locked (most of them while it rolls) or one that's read-only. It also covers a value it doesn't list: a project rate
  its menu doesn't allow (another make's 59.94 when the imager mode allows 23.98 to 29.97), a Select FPS or shutter
  angle or speed outside its own list, or a Kelvin outside its range. Its own tiles never send those. A camera sent one
  anyway does nothing at best, and a write it doesn't answer would hold its one queue for up to 3 s, so a linked STOP
  behind it would be late. Before this, a project rate its menu didn't list went to the mediabox's frame rate
  (`P.Clip.Mediabox.Video.Format.FrameRate`), which takes no write.
- **A project rate restarts a VENICE.** On a page that links frame rate, the FPS tile's confirmation names every
  camera the rate restarts ("Switch to 25 (restarts cameras A and B)"), wherever it was picked. Before this it said
  "the camera" while the linked VENICE restarted too, and a camera that doesn't restart for it (a PYXIS) asked nothing.
- **Demos are named by their letter:** a demo VENICE B's clips are B005C…, as on a real B camera.
  `-CCDebugDemoBodies venice2,venice2` opens the app on working demos of those bodies, one page, held in memory
  (`DashboardStore.demoBodies`), for UI checks and screenshots.

Checked against two `FakeVeniceCamera`s and a demo FX3 (`VeniceMulticamTests`), and in the app on two demo VENICE 2s
(`MulticamTests`: linked REC rolls and stops both; the restart confirmation names both). Pages of two, three and four
VENICEs render clean (side by side, the 2-wide column, the phone's pager and its one-at-a-time landscape). Not yet
tried with two real VENICEs.

## Build 57: Camera Menu, user frame lines, audio meters (2026-10-29, not yet on a camera)

All three (Camera Menu, user frame lines, audio meters) need a real VENICE before they ship.

- **Camera Menu** (`cameraButtons`: MENU, Home, Back, up, down, Set → `Button.SendKeys` `Menu`, `Home`, `Cancel`,
  `UpArrow`, `DownArrow`, `Set`). The page sends `Set`, `UpArrow`, `DownArrow` and `Home` itself; `Menu` and `Cancel` are
  SkaarHoj's names (above). One key at a time, with the page's 3 s, not the client's 8: a key the camera doesn't answer
  holds every request behind it, REC included, until then. A tap while one is out is dropped, and a key the camera
  doesn't answer or turns down comes off the Camera Menu until the next connection (`unansweredKeys`), with a line in
  the Activity Log. To check: does MENU open the full menu on the VF and SDI, and does Cancel back out of it? `Home`
  is also Playback's "back to live": pressing it from the menu during playback is untried.
- **User frame lines.** VENICE 2 has two frame line sets, Line A and Line B (WebMenu.js: Frame Line Setup), and each
  output shows one of them (`Marker{Sdi12,Sdi34,Monitor,Vf,Hdmi}Select` "0" Line A, "1" Line B) while its frame lines
  are on. Within a set, User Frame Line 1 and 2 show or hide: `P.System.Menu.MarkerAUserBoxOnoff`,
  `MarkerAUserBox2Onoff` (B likewise), menu switches "0"/"1" like the outputs' frame lines, which were proven on the
  camera. Sony's "Line A: User Frame Disp." assignable function steps 1 + 2 → 1 → 2 → hidden (CineAlta workflow guide).
  The tile writes only the switches that change, in one `Property.SetValue` (an unchanged one isn't reported back and
  would read as unconfirmed). Read on connect in a `GetValue` of their own, apart from `extraProperties`. The 2026-10-23
  camera had all four off and one user frame line file loaded (`L1_5.8K_6x5_1.0_1.85.xml`). A camera without the
  second user frame line (VENICE before V6.0) gets Off / On. A tap on the tile steps on in the button's
  order, 1 + 2, 1, 2, Off (2026-10-29: a DIT cycles frame guides from a hot button on set), and a long press lists
  them; the options are in that order, so a deck's `cycle` steps the same way.
- **Audio meters.** `Output.Audio.dBLevel` {"ch.1"…"ch.4": 0–24}, always sent with its coarse twin `Output.Audio.Level`
  (0–3), all four channels, about six times a second (5,893 of them in the capture, never anything else alongside).
  The page draws 9 segments from it (AudioLevelMeterConverter.js: 1–24 → 0–9), gray, white, then red at 24; Tiles
  draws a bar to level/24 in the same three zones (dim to 13, bright, red at 24), no dB scale (none is known). Grayed
  while S&Q runs, unless at 1× (`P.System.Menu.SandQPseudoFixed` "1"), as the page grays them. The backend takes a
  meters-only notification on a fast path (no rebuild, no log line), and `CameraController` keeps the levels out of
  `state`, so only the Audio tile redraws with them.

## Output options: frame line set and audio meters (2026-11-12, not yet on a camera)

Each output's frame lines and audio meters in Monitoring Options. From the 2026-10-23 capture of a real VENICE 2:

- **Frame line set per output.** `P.System.Menu.Marker{Sdi12,Sdi34,Monitor,Vf,Hdmi}Select`, "0" Line A, "1" Line B
  (the camera had SDI 1/2 on Line B). Tiles: `MonitorOutput.frameLines`, a Frame Lines picker per output, written with
  `setFrameLineSet`. An output that follows another shows that one's set, grayed.
- **Audio meters per output.** The meters are an item of the overlay's two info sets,
  `P.System.Menu.DisplayInfo{A,B}AudioLevelMeterOnoff` "0"/"1" (A was on), and each output picks a set with
  `P.System.Menu.{Sdi,Monitor,Vf,Hdmi}OsdDisplayInfoSelect` ("0" Info A, "1" Info B, "2" REC indicator only; one for
  SDI 1/2 and 3/4). Tiles: an Audio Meters overlay on each output, the meter of the set it shows; switching it switches
  every output on that set. None on an output showing the REC indicator alone.
- Read once connected, in a GetValue of their own with the page's 3 s, like the user frame lines, so a VENICE without
  them costs nothing. To check on a camera: both writes, and that the meters show on SDI with its overlay on.

## The real VENICE 2 (2026-10-23: FW V4.00, savona-2.9.4, over HaLow)

An hour with an MPC-3628 settled the protocol. Tiles drove it end to end that morning (REC, EI, base, shutter, ND,
WB, S&Q, LUTs, overlays, playback); everything below is what the camera actually did.

- **One client.** `ws://HOST/linear` takes one WebSocket; a second is closed at once, and the page then retries every
  ~1.5 s (never leave two open: that loop can crash the camera). After a client quits, the camera
  refuses new ones for a few seconds. The camera's web page and Tiles can't be connected together, which is why Tiles
  has no Web GUI tile (2026-10-28).
- **Login** (the page's own): `GET /cgi-bin/getsavonacred.cgi` with HTTP Digest answers
  `sha256hex(user):sha256hex(password)`; those go back as `Alternate.Authentication.Basic [{username, password}]` (an
  array holding one map). `GetNonce`, `System.GetProperties` and any request in the wrong shape get **no answer at all**,
  not an error: a timeout means the shape is wrong. So every request mirrors the page's.
- **Frames** carry several MessagePack messages, and one can be split across two (`MessagePack.decodeAll`, `MpStream`).
- `Notify.Subscribe [["Notify.Properties", "Notify.Process", "Notify.Property"]]`. `Notify.Capability.Value.Changed`
  carries option lists, never values. Keep-alive: `Property.GetValue [{"Network.Connection.KeepAlive": ["cam"]}]`
  every 3 s.

| Control | What the page sends |
|---|---|
| EI | `{"Camera.Gain.ExposureIndex.Value": "800EI"}`, a whole number (the page's SET_EI; Tiles sent "1600.0EI" until 2026-10-23 evening) |
| Base ISO | `{"Camera.Gain.ISOValue": "ISO 800"}` / `"ISO 3200"` (the page asks first). The camera then puts the EI back where it last was on that base (Tiles' log, 12:16: 3200 brought back 1000EI and 800 brought back 2500EI; 800EI the first time on 3200) and relists the EIs; Tiles writes the EI to the base once the base and the list have come back (`moveEIToBase`) |
| Shutter angle | `{"Camera.Shutter.Mode": "Angle", "Camera.Shutter.Angle.DisplayValue": "180.0"}`; fine steps: `Select` "Continuous", then `Property.UpdateValue {"Camera.Shutter.Value": 1}` / `-1` |
| Shutter mode | `{"P.System.Menu.ShutterMode": "1"}` Angle / `"0"` Speed (Technical menu; the page's home has no switch) |
| ND | `{"Camera.NDFilter.Mode": "Preset", "Camera.NDFilter.Value": 4}`; Clear: `{"Mode": "PresetClear", "Value": 1}` |
| WB | `{"…ColorTemperature.Value": "5600", "…ColorTemperature.Tint.Value": "0", "…ColorTemperature.Type": "User"}` |
| S&Q | `{"Camera.SlowAndQuickMotion.Enabled": true, "…FrameRate": 24, "…FrameRate.Denominator": 1}` |
| LUTs | `{"Output.Video.SDI.LUT.Value": {"sdi1": "Log(Legal)"}}`, `{"Output.Video.ViewFinder.LUT.Value": {"vf": "Look"}}`; the names are `Log`, `Log(Legal)`, `s709`, `R709_800%`, `Look` (HDMI adds `HLG`) |
| Menu switches | `P.System.Menu.*` as `"0"` / `"1"`: `MarkerSdi12/Sdi34/Monitor/Vf/HdmiOnoff`, `SdiOsd/MonitorOsd/VfOsd/HdmiOsdDisplayInfoOnoff` (**one** SDI overlay for SDI 1/2 and 3/4), `EvfZebraOnoff`, `PeakingOnoff`. On the camera (Tiles' log, 2026-10-23) every output's frame lines and status text and the VF zebra switched, each change reported back; the HDMI's frame lines follow the Monitor's while it shows the Monitor's format (`OutputFormat.Info.Hdmi` "2"), so a Monitor write moves both |
| Imager, format, project rate | `P.System.Menu.CamImagermode` / `AxsRecformatSelect` / `SystemFrequency` as menu values ("17" = 8.6K 3:2); the allowed items in `P.System.Menu.L3_IMAGER_MODE` etc. (`VeniceMenu`, from the page's `WebMenu.js`) |
| Flip | `{"P.System.Menu.FlipImage": "3"}` H&V / `"0"` (also what the camera's own HAndVFlip assignable button sets) |
| Keys | `Button.SendKeys [["Rec"]]`; `Play` (play/pause), `Stop`, `Forward`, `Rewind`, `Next`, `Prev`; `InsideClips` into playback, `Home` back to live; `Assignable.1`–`7`, `VFAssignable.A`–`C` |
| Shutter speed | `{"Camera.Shutter.Mode": "Speed", "Camera.Shutter.Speed.DisplayValue": "1/50.00"}`: two decimals (ShutterConverter.js); the list is `Camera.Shutter.Speed`'s, nothing slower than 1/fps (1/50 at 59.94 is ignored) |
| Look | `{"LUT.Mode": {"cam": "PresetLook"}, "LUT.Preset": {"cam": "R709_800%"}}`, or `{"LUT.Mode": {"cam": "User3D"}, "LUT.User3DLUT.FileID": {"cam": 5}}` (1-based slot); lists: `LUT.Mode` (PresetLook, User3D, ART), `LUT.Preset`, `LUT.User3DLUT.LoadedList` (16 slots of file names), `LUT.ART.FileList` |
| LUT upload | `POST /cgi-bin/upload.cgi`, HTTP Digest, multipart: `csrf` (4 random uint32s, made by the page, comma-joined), `DestinationID` (the slot), `FileName` (the .cube); from an SD card instead: `LUT.User3DLUT.LoadFile.FileName/FileID` then `Process.Execute ["LUT.User3DLUT.LoadFile.Request"]` |
| De-squeeze | `{"P.System.Menu.RecOutDeanamoScaleSelect": "5"}`: Off 0, 1.25× 1, 1.3× 2, 1.5× 3, **1.6× 6, 1.8× 4, 2.0× 5**; allowed items in `P.System.Menu.SxsOutputDeSqueeze.HighLightList`; restarts the image |
| Zoom to Fit, Input Color Space | `P.System.Menu.ZoomToFitSelect`: Off 0, 2.39:1 3, 17:9 1, 16:9 2. `P.System.Menu.InputColorSpace`: S-Gamut3.Cine/SLog3 0, S-Gamut3/SLog3 1, ACEScct 6 |
| Clip naming | `P.System.Menu.ClipnamingCameraid` the letter's ASCII code ("66" = B), `ClipnamingReelNum` ("24"), `ClipnamingCameraposition` "0" C / "1" L / "2" R |
| Time display | `P.System.Menu.TimecodeDispTc` "3" Timecode / "2" Duration; `Clip.Mediabox.TimeCode.Type` then reads TCG / Duration |
| False color | no on/off property (`P.System.Menu.FalseColor` is something else): it's the assignable functions `FalseColorMonitor` / `FalseColorVF`, toggled with their key (`Assignable.2`, `VFAssignable.B` on this camera) and read from `Button.Assign {"Assignable.2": ["FalseColorMonitor", "On"]}`, which the camera reports one button at a time. The page reassigns a button with `{"Button.Assign": {"Assignable.5": ["FalseColorMonitor", "None"]}}` (AssignConverter.js); Tiles doesn't reassign |
| Color bars | `P.System.Menu.ColorBar` "1"/"0" (the page's menu write); `Camera.ColorBar.Enabled` reads; the menu item can be Locked (`P.System.Menu.ColorBar.MenuItem`), and then the write is ignored. `Camera.ColorBar.Enabled`'s own status read Unlocked while it was: Tiles writes that then (unproven) |
| Locks | `Property.GetStatus [{name: nil, …}]` → `{name: "Locked" \| "Unlocked"}`, for properties and for menu items as `….MenuItem` (named after the menu's item: `ProjectImagerMode`, `AxsrecformatSet`, `FrequencySet`, `SxsOutputDeSqueeze`, `ColorBar`, `BaseIso`, `FlipImage`, `ClipNaming`, `CameraPosition`); changes come as `Notify.Property.Status.Changed`. Each output's LUT lock is a value map, `Output.Video.SDI.LUT.Value.LockStatus` / `….ViewFinder.LUT.Value.LockStatus` |

Reads worth knowing: REC is `Storage.Media.Recording {"media.5": "Recording"}`, and stopping takes ~2 s while the clip
closes. Playback: `P.Clip.Mediabox.Status` "Playing" in playback, "Standby" live; `Speed` 0, 1, ±4. Battery:
`System.Battery.Active.Remain.Voltage` (Percentage reads -1 when the camera shows volts). `System.ModelName` says
"PXW-X180"; the firmware is `P.System.Menu.WebInfo.Firmware.CameraVersion`. The web page's 3.5 MB loaded over HaLow in
29 s; idle control traffic is ~25 kbit/s.

**Outputs that follow another.** On FW V4.00 that isn't a switch: the camera derives it from the output formats and
reports it, read-only, as `P.System.Menu.OutputFormat.Info.Sdi34` / `.Moni` / `.Hdmi`: "0" Same as SDI 1/2, "1" Same as
SDI 1/2/3/4, "2" Same as Monitor, "3" Same as VF, "4" (SDI 3/4, Monitor) or "5" (HDMI) an output of its own (Const.js
`OUTPUT_FORMAT_INFO_*`; OSDAppearanceView.js hides a following output's own settings). The real one read SDI 3/4 "4",
Monitor "4", HDMI "2". Unlinking means changing SDI 3/4's or HDMI's output format, whose menu items were Locked; Tiles
shows the link and doesn't change it. The LUTs link separately (`Output.Video.SDI.LUT.Joint.Value`, e.g.
`"monitor-hdmi"`), so Tiles keeps each output's LUT its own. `MonitorOutSource` "1" makes the Monitor show the
VF's picture. Separately, the overlay's content comes in two sets, Info A and Info B (`DisplayInfoA…/B…Onoff`), and
each output's `…OsdDisplayInfoSelect` picks one ("0" Info A, "1" Info B, "2" Rec Ind.).

**Notifications** besides values and lists: `Notify.Property.Status.Changed` (locks), `Notify.Properties.Changed` (a
values map, seen once), `Notify.Property.ErrorOccurred` (`[3003, "Property Not Found"]` for a name it doesn't have;
the page's polling makes thousands). A map-valued property is often reported one entry at a time (`Button.Assign`
`{"Assignable.2": […]}`, the LUT LockStatus maps), so an entry updates its map rather than replacing it.

**The session's files** are at `captures/venice/20261023-101844/` (gitignored; Sony's code stays
out of git): five recorded page sessions with every frame both ways (`events.jsonl`; `venice.py note` labels), the
page's own scripts (`runtime/`, `mirror/`; `WebMenu.js` is the whole menu, every item's name and value), and
`master.json` from `venice.py savona --master`: 545 values, 321 lock statuses and 45 option lists for the 1,109 names
the page's scripts and the session know. The put-back at the end compared the first page load (10:18) with a fresh
`--dump` and wrote the originals back (`putback-args.txt`); white balance refused 15000 K and stayed at 3200 K.
`last-tests.log` is the last proof of Tiles' writes.

## What Tiles preloads, checked against Sony (2026-10-22 night)

Every list Tiles falls back on when a camera doesn't send its own (and Test Mode's VENICE) was checked against Sony's
VENICE 2 manual (MPC-3628 / MPC-3626, FW 2.0; page numbers below) and Sony's V3.00 release notes. A camera's own lists
always win. `VeniceManualCheckTests` pins each one.

| Setting | Tiles | Sony | |
|---|---|---|---|
| EI by base ISO | 8.6K: 200–3200 at 800, 800–12800 at 3200; 6K: 125–2000 at 500, 640–10000 at 2500 (thirds) | p. 50 | matched |
| Shutter angle steps | 5.6 … 360 (9); continuous 4.2–360 | p. 72 | matched |
| Shutter speed steps | 1/24 … 1/2000 (12, with 1/48), from 1/fps up at each project rate | p. 72 and its footnote | **fixed**: the list didn't follow the project rate |
| ND | Clear, 0.3 … 2.4 (9) | p. 51 | matched |
| White balance | 3200K / 4300K / 5500K steps; 2000–15000 K; tint ±99 | p. 51, 129 | matched |
| LUT per output | SDI 1/2, SDI 3/4: Log / Look; Monitor, VF: Log / s709 / R709(800%) / Look | p. 51 | matched; **fixed**: FW 3.0's Log(Legal) counts as no LUT |
| Outputs | SDI 1/2, SDI 3/4, Monitor, VF, HDMI: frame lines and the info overlay on each; false color on Monitor and VF; zebra on VF | p. 44, 88–90 | **fixed**: HDMI was missing, and the overlay was on the Monitor only |
| Imager modes | 8.6K (11) and 6K (13), in Sony's order | p. 5–6 | **fixed**: the 6K's were missing |
| Project frame rates | per imager mode and sensor | p. 5–6 | **fixed**: the 6K's and Surround View modes were wrong |
| Select FPS | per mode and sensor; ProRes's own limits; nothing under 8 at the high base; 33.33 at 24 / 25 / 50 (FW 3.0) | p. 49–50, V3.00 | **fixed**: ProRes, the 6K, the base-ISO floor and 33.33 were missing |
| Recording formats | X-OCN XT / ST / LT, ProRes 4444 XQ / 4444 / 422 HQ in 4K and QFHD, only where the mode and rate allow | p. 58–59, 64–70 | **fixed**: every format was offered everywhere |
| De-squeeze | per aspect with X-OCN; ProRes's own table (8.6K 3:2 has no Off) | p. 59–60 | **fixed**: ProRes's table was missing |

VENICE 1 (MPC-3610) isn't in this manual: it gets the 6K's EI lists (the same sensor) and no imager-mode lists from Tiles,
only what the camera sends. Newer firmware can add modes and rates; the camera's own lists cover them.

## Capture day (2026-10-23, a VENICE 2 for about an hour)

**What the day taught, for the next camera** (VENICE or ARRI):

- The camera takes one client. Tiles, the camera's page, `watch` and `savona` take turns; close one, wait ~5 s, start
  the next. A second page left open loops reconnects at the camera.
- The `proxy` didn't survive a browser on macOS: local-network privacy turns a process started detached from an
  SSH session (`--detach`, `nohup … &`) away with errno 65, sooner or later. What works: the recording Chrome window
  opened in a desktop session (`open -a Terminal run-watch-headed.command`, which runs `watch --headed`), and
  `savona` runs in the SSH foreground.
- Start with `go`, then `savona --dump` (it writes into the session `go` made), then the recorder. Before the camera
  leaves: `savona --master`, the writes Tiles needs proven once each (`last-tests.log`), and the put-back.
- On macOS, `log` in zsh is a builtin: Tiles' own log is `/usr/bin/log show --predicate 'subsystem == "com.toldwell.twcc"'`.
- HaLow: Internet Sharing on the laptop (left on from the uplink tests) put it upstream of its node; turn it off for a
  camera session. The node on the laptop's USB-C is powered from it, so unplugging restarts the node; twice its cable link
  stopped passing traffic while the mesh stayed green, and a replug fixed it. A node's wired port can be switched over
  SSH (`uci set system.@system[0].target=eth|usb; uci commit system; echo low|high > /sys/class/gpio/gpio527/direction`).

The whole capture is scripted now: `scripts/venice/venice.py` (a fake camera to rehearse against is `mock_venice.py`).
Everything lands in `captures/venice/<stamp>-<host>/` (gitignored — the camera's own code is Sony's; only promoted
frames go to `fixtures/`). Tested end-to-end against the mock on both Macs on 2026-10-22.

- `find` — sweeps every network the Mac is on, scores what answers like a VENICE (Digest 401 on rm.html).
- `go HOST -p PASS` — mirrors rm.html/rmt.html and every file they load, opens both headless with the Digest login,
  records every WebSocket frame (and the handshake headers, which show how the login crosses to the socket), every
  request, a screenshot, the rendered DOM with every control, JS globals, and writes `report.md` — property names,
  element IDs, live values, and each Tiles control mapped to what looks like it. About 35 s.
- `watch HOST -p PASS --detach` — stays connected and logs. `ctl click/eval/send/shot/snap/reload` drives the page;
  `note "<action>"` prints what changed since the last note, with timecode-type noise hidden; `diff` is the
  put-back list. `stop` closes it. Safety: clicks whose id/text looks like format/delete/reset/update are refused
  without `--force`, and confirm() dialogs are always dismissed.
- `raw [WSURL] -p PASS --send TEXT …` — talks to the camera's WebSocket with no browser: answers the Digest challenge
  on the handshake, sends the page's Origin, cookies and subprotocol, one command at a time, and prints what changes.
  Run it before the camera leaves: it's the proof a native client (Tiles) can drive it.
- `proxy HOST --detach` — reverse proxy on :8080 so a browser (the laptop's own, a phone's over Tailscale) can drive
  the page with everything recorded: open `http://<this Mac>:8080/rm.html`. Caveat found in testing: once a client
  connects from *another* machine, macOS local-network privacy kills the proxy's outbound connections (errno 65), so
  the phone path is best-effort; the laptop's own browser is unaffected.

Order of the hour:

1. Over the HaLow mesh (2026-10-22), which also measures what the Web Remote costs on the link. The camera's
   RJ45 goes into one node with its wired port on RJ45 (two white pulses on a ~3 s button hold; nodes 1–4 show no
   pulses yet, so check over SSH: `/sys/class/gpio/gpio527/value` is 1 for USB-C, 0 for RJ45). The laptop goes into
   a *different* node by USB-C (two blue pulses), or
   joins the mesh's Wi-Fi with the phone tethered by USB, and keeps its own internet (the mesh
   advertises no router without an uplink, so nothing steals the default route). On the camera: Technical >
   Authentication, set a password if none is set (8+ chars, letters and numbers; there's no factory default, and
   Network Setting stays grayed out until one is set; the user name is `admin`; hold the sub display's ITEM key 1 to
   read it back). Technical > Network > Setting = LAN, LAN > DHCP Off, set a static address on the mesh subnet (e.g. 198.51.100.106), mask appropriately; no gateway field. **Set** (otherwise it's silently
   discarded). Faster: DHCP On + Set, and read the address off Info > System > IP Address (node N hands out addresses in its pool, and `find` sweeps those pools too) — no digits to dial in. Note what was there before. Write down
   Info > Firmware. If RM/RCP Paint Control is On (Technical >
   Special Configuration, VENICE 2 manual p. 102), set it Off and note it. Full menu: hold MENU 2 s. Direct cable to the laptop is the
   fallback: 192.168.2.50/24 on the camera, the laptop's adapter set to 192.168.2.10 (`networksetup`, no password needed
   over SSH, tested).
2. Mac side (over SSH): `find` (sweeps the mesh subnet as well as the laptop's own /24) → `go <camera-ip> -p …`.
   Timeouts are 60 s per page for HaLow. Report skim: WebSocket URL, how the Digest login reaches the socket, how many
   of SkaarHoj's names are live, which Tiles controls already have names, and the traffic line (kbit/s and frames/s
   the page pulls while idle). If big transfers stall, check the camera's node clamps the TCP MSS (wired gear
   sends 1500-byte frames the mesh can't carry).
   - Worth having on hand: an AXS card that can take a test clip (REC feedback needs media), a lens that reports
     (Cooke /i or LDS) for iris/focus/zoom, and the owner's OK to touch assignable buttons — user buttons
     ride the camera's own slots, so testing them means reassigning one; note the originals.
3. Before any clicking, and after `go` (`savona` writes into the current session, which `go` creates; run first, the
   dump lands in the last rehearsal's folder): `venice.py savona HOST -p … --dump` — the camera lists every property name it knows and
   their current values. Most of the 13-control list below may be settled by that dump plus a few `--set`/`--keys`
   probes (REC as `Button.SendKeys` and as `Clip.Recorder.Start`). Then:
4. Start `proxy` (same session; check the report's WebSocket URL first — a different port needs `--also-port`).
   Open **`http://localhost:8080/rm.html`** in the laptop's browser: the camera's own page through the recorder,
   so every click is saved with what it sent (rehearsed 2026-10-22: local browser → proxy → camera on the
   LAN, frames recorded). Not the camera's own address in another tab, which records nothing. Then the controls, REC
   first, then shutter / EI / ND / WB / presets / user buttons / playback keys, then the ?s in the table above — the
   ordered list is tracked separately. Frames name their property, so no waiting between controls: one at a
   time at operator speed, noting what you did only when it has no name (a key, a menu action). A user button and an
   ISO change on the *body* show whether the page is told — do those early. Label with `note`, and start
   `watch` only afterwards (it's the second-client test, and lets you click what was skipped via `ctl`). `watch` and
   `proxy` hold the Mac awake (`caffeinate`) while they run; the lid has to stay open.
4. The Full Menu screen of the web remote is the likely gold mine: if its tree arrives as data, every menu parameter
   is enumerable. Walk it once, slowly, with `note` labels. Also: open a second browser on the page while `watch` is
   connected (does the camera allow two clients?), and read the on-camera WB
   and shutter preset lists.
5. Before the camera goes: `raw` with two or three frames copied from the capture (REC, one property write), to prove
   control without a browser.
6. Close: `stop`, `diff`, restore, then copy the session to the build Mac (`tar | ssh`) — `captures/` isn't in git.

Rules: one command at a time, no reconnect loops (the camera can crash reconnecting on a bad
link), and expect white balance to reset at power-on — the last WB is worth writing down for the owner.

Sources: devices.skaarhoj.com/core/core-sony-websocket, cloud.skaarhoj.com/coremanual/core-sony-websocket/pre/7,
support.cyanview.com/docs/Integrations/Sony/SonyVenice, support.d-imaging.sony.co.jp/app/sdk/en/, Sony's CineAlta
Remote Control Guide V2.0, guide.smallhd.com/a/1345570-sony-venice-wired-camera-control, Sony's Camera and
Display Plugin (sony.com/electronics/support/software/00302480, user guide V2.0).
