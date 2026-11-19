# Testing

## Running `swift test`

**On a build Mac (Command Line Tools for tests; Xcode since 2026-10-15, for app builds only).** The Command Line Tools ship Swift Testing but don't put it on the search paths. The flags below fix that; the whole suite runs in one go:

```sh
cd Packages/CameraKit
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L
```

A run that stops making progress (tests "started" and never "passed", from fonts to REC) is usually a
`swiftpm-testing-helper` left from an earlier run, even one in a checkout that's since been deleted: on 2026-10-13 a
14-hour-old one hung the suite for 30 minutes, and the next run passed in 28 s. `pgrep -fl swiftpm-testing-helper`,
kill it, run again.

**On a Mac with Xcode.** Plain `swift test`. Run it in the background with a log rather than piping it back over ssh;
killed ssh sessions leave hung test processes behind:

```sh
ssh <build-mac> 'cd /tmp && rm -rf tw-cc-test && git clone -q -b <branch> <repo-url> tw-cc-test &&
  (nohup sh -c "cd /tmp/tw-cc-test/Packages/CameraKit && swift test > /tmp/tw-cc-test.log 2>&1; echo EXIT \$? >> /tmp/tw-cc-test.log" > /dev/null 2>&1 < /dev/null &)'
```

Done means a "Test run with N tests … passed" line for every run and `EXIT 0`. Xcode's `swift test` reports SonyPTP,
CameraCore and Blackmagic as separate runs, so one "passed" line can be one suite while another still hangs.

App builds (iOS, macOS) run on the build Mac since 2026-10-15 with Xcode via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
(xcode-select stays on the Command Line Tools for these package tests).

**Loopback connects fail with EADDRINUSE now and then** (2026-10-15; cause found and fixed the same night). Network.framework
reports it as `.waiting`, not `.failed`, so anything that waited for `.ready` or `.failed` waited for good. That hung
whole runs until 39a41fe. The cause, from netstat at the moment of failure: the local port the system picked already
had a TIME_WAIT with the same 4-tuple. A server listening on that port had closed a connection from the port the new
server now listens on: listeners on port 0 get recycled ephemeral ports well inside TIME_WAIT's 30 s. And the system
picks that same port for every new connection to the server (30 retries, one port), so retrying on a new connection
never helped. A retry now names its own local port: `LoopbackTCP` in the tests (40000–48999; the two test relays always
do), `PTPIPTransport.withOwnLocalPort` in the app (a random ephemeral port). Measured with `scripts/test-flake-hunt.sh`:
before, 3 of 20 and 3 of 30 full runs failed, every one on this; after, 29 of 30 clean, the 7 collisions all retried
through, and the one failure a preset test's timing under load (PresetTests "Status text on one output").
Don't measure on a heavily loaded machine: right after the Xcode install (load 17–24) a run failed 112 times.

**A test reached another app on its port.** A login test failed once under load with "HTTP 404: not found\n" and a
TLS test never connected. The fakes listened on every address, on a port the system picked; another app on 127.0.0.1
answered the test's connections with that 404 instead. Test servers now listen through `LoopbackListener` (127.0.0.1,
a port free there), and the Control API tests reach the app's own server, which listens on every address, over `::1`.
Before blaming a flake on timing, `lsof -nP -iTCP -sTCP:LISTEN` for what else listens on 127.0.0.1.

**The preset tests' flake was the fake dropping uploads.** Under load a change through a preset now and
then never landed ("The network connection was lost" in the backend's warnings): the fake PYXIS took a request's first
read as text, and on a busy machine a preset's upload, which is binary, came in the same read as its headers. It reads
to the end of the headers and takes only them as text now. To reproduce a flake that needs load, load the machine
(`yes > /dev/null` ten times) and loop the suspect tests (`swift test --skip-build --filter …`): 4 of 20 failed before
this fix, none after.

**Suites that listen on RTMP's port 1935 run one at a time.** "Live view back within the linger picks the
stream up" failed in two of seven full runs and never alone, even with the machine loaded (0 of 8): it closes its
receiver and listens again on the port the camera's platform names, and in a full run another suite's receiver
(Blackmagic's `LiveStreamTests`, Sony's `StreamLiveViewTests`) could take 1935 in that moment, so it listened
elsewhere and the stream started over. Each such suite carries `.rtmpPort` (`CameraKitTestSupport/RTMPPort.swift`), a
lock across every test target; a new suite with an RTMP receiver needs it too. Four full runs after: clean.

**Waiting on a backend's `updates`** (`collectUntil`). It's an AsyncStream keeping the newest 16:
a wait gets every state queued since the last wait ended, so it can match one from before (two overlapping connects
matched the first session's, and the REC sent then went nowhere). A wait that times out cancels its consumer, and that
ends the stream for good: every later wait on that backend returns nil at once, and a check like
`rolling?.recording.failure == nil` then passes on the nil (that test hid a REC that never ran). For what the backend
is now, read `backend.state` (`stateWhen`); check a wait's result isn't nil before checking what's nil in it.

**WebSocket tests use URLSession's client.** Apple's NWConnection WebSocket client aborts with ECONNABORTED on the build Mac,
even against a minimal Network.framework server, so ControlServerTests use `URLSessionWebSocketTask`.

**Control API end to end.** `swift run twcc-api-demo` hosts the real server with the demo lineup on 51800/51801
(token `demo-token`); docs/control-api.md has curl and websocat examples to drive it, and `scripts/api-e2e.mjs` checks
it against the contract. To wait for it in a script use `nc -z 127.0.0.1 51800`: the WebSocket port takes a TCP
connection and never answers a plain HTTP request, so a bare `curl` there waits for good.

**UI tests (iOS Simulator, Mac with Xcode).** `App/uitest.yml` adds a `TilesUITests` target (`App/TilesUITests`) to the app
project; the shipping spec, `project.yml`, doesn't have it. They run against the demo FX3: a picker staying open through
state updates, edit mode leaving every tile where it was, Add Tile bringing the new tile into view, and Naming setting
the title, and the Lock tile locking the page (the frame rate's menu won't open) and unlocking it, in step with the
padlock in the top bar (`testTheLockTileLocksAndUnlocksThePage`); and against the offline PYXIS, a monitoring tile's
outputs checklist staying open while outputs are ticked (`testOutputsChecklistStaysOpen`). `MulticamTests` opens the app on two working demo
VENICE 2s (`-CCDebugDemoBodies venice2,venice2`, held in memory): linked REC rolls and stops both, and a linked project
rate's confirmation names both cameras. Tests that add a tile take it off again by its × (`removeTiles`): on a phone
Reset only puts the phone's own arrangement back, and the tile stays on the page. `AppearanceTests` (iPad only: on a phone the sheet covers the page) switches Settings → Appearance's custom colors on and reads the top bar's color, behind the sheet and after a relaunch, then switches them off again. `CustomColourTests` taps Edit Camera's eyedropper swatch where a finger would and checks Tiles' color picker opens with its grid drawn; `AppearancePickerTests` does the same for each of Appearance's colors, closes each with its ×, then picks black from the grid and checks the setting and the page take it and Reset puts white back (Tiles' own picker since 2026-10-28: the system's came up empty on a tester's iPad in builds 51 and 52). `NDStepTests` checks the ND tile's step buttons are off until switched, then switches them on and off from its edit-mode chip on a demo VENICE 2. `DynamicTextTests` (a 13-inch iPad) taps a picker, a switch and a toggle tile at Dynamic Text Size, and switches Text Size in Settings and measures a caption grow and come back; `TEST_RUNNER_TILES_UITEST_SHOTS=<dir>` saves both looks to check the bigger text is sharp. The color picker's hex field following a pick while it has the focus only shows on a Mac (an iPhone or iPad moves the focus off the field on a tap), so it's a package test, `ColourPickerHexTests`: the picker in a real macOS window, the field first responder, then a pick; it fails with the fix taken out. `PagerTests` (an iPhone, upright and on its side) checks Done in edit mode leaves the pager on the camera it was on; with the fix taken out both fail. `TextScaleTests` (any device) moves Text Size's slider to 150 % and measures a caption grow, then back to 100 %. A tap into a menu or popover is sometimes dropped on the simulator, so those tests tap again once if nothing happened (`tap(until:)`); a tap that never lands still fails. Run them in their own clone, not the deploy clone an upload may be using:

```sh
ssh <build-mac> 'rm -rf /tmp/tiles-ui && git clone -q -b <branch> <repo-url> /tmp/tiles-ui && cd /tmp/tiles-ui/App &&
  xcodegen generate --spec uitest.yml --quiet &&
  xcodebuild test -project CameraControl.xcodeproj -scheme TilesUITests -destination "platform=iOS Simulator,name=iPad mini (A17 Pro)"'
```

They also run on the build Mac (2026-10-27, Xcode 26.6, the whole suite; the color picker tests also on an iOS 17.2 iPad Pro 12.9;
2026-10-28, the whole suite on an iPad mini, `DynamicTextTests` on an iPad Pro 13-inch, `PagerTests` on an iPhone 17 Pro):
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test … -only-testing:TilesUITests/AppearanceTests`
from a clone's `App/` after `xcodegen generate --spec uitest.yml`.

## Simulator QA

`scripts/qa-screens.sh` captures screenshots across the full device matrix and builds labeled contact sheets. Run from the repo root (requires Xcode, xcodegen, and uv):

```sh
bash scripts/qa-screens.sh
# or a subset:
bash scripts/qa-screens.sh "iPhone 17 Pro" "iPhone SE (3rd generation)"
```

Output goes to `qa-out/<timestamp>/` (gitignored). Each device gets a subdirectory with `portrait-normal.png`, `portrait-edit.png`, `portrait-settings.png`, `landscape-normal.png`, and `landscape-edit.png` (the demo FX3), and `portrait-pyxis-test.png`, `portrait-pyxis-edit.png`, `landscape-pyxis-test.png`, `landscape-pyxis-edit.png`: a PYXIS that isn't connected, in Test Mode, the page a Blackmagic camera gets (`-CCDebugOfflinePYXIS YES` launches the app on a store of its own, emptied each launch). Then `*-lineup.png`, `*-lineup-b.png` and `*-lineup-edit.png`: the four demo cameras' A+B page (`-CCDebugDemoLineup YES`, held in memory), with camera B picked from its chip where a phone on its side shows one camera at a time. `scripts/qa-sheets.py` then builds `phones-portrait.png`, `phones-landscape.png`, `pads-portrait.png` and `pads-landscape.png`: a row per device, a column per capture, every capture upright and at one height. XCUIScreen hands over a landscape capture in the screen's own portrait orientation; the sheets turn it a quarter left.

Default device list: iPhone 17 Pro, iPhone 17 Pro Max, iPhone 17e, iPhone SE (3rd generation) on iOS 17.2, iPad mini (A17 Pro), iPad Air 11-inch (M4), iPad Pro 13-inch (M5). The whole run takes about 20 minutes on the build Mac. First run, 2026-10-16: the edit bar wrapped every label on every iPhone held upright ("Editi ng All", "D one"), and on an iPhone on its side the half-row tiles' corner controls hung over the tile below. 2026-10-19: on a notched
iPhone on its side, the one-camera-at-a-time pager showed a strip of the next camera in the right-hand safe area.

**libssh2.** `CSSH` is a binary target. The local copy in `Packages/CameraKit/CSSH.xcframework` is built
by `scripts/build-cssh.sh` (libssh2 1.11.1 with OpenSSL 3.5.9). The public package fetches the same xcframework
zip by URL and checksum the first time it resolves, so a public build needs the network once.

## FakePTPIPCamera

`Packages/CameraKit/Tests/SonyPTPTests/FakePTPIPCamera.swift`

An in-process `NWListener` fake camera. Runs the full PTP-IP connect sequence and serves a small
property set. All `SonyPTPTests` backend integration tests use it.

What it models (from the real FX3):
- Full Init_Command_Request / Init_Command_Ack handshake with GUID tracking.
- `SDIO_Connect` phases 1, 2, 3.
- `SDIO_GetExtDeviceInfo` returning a real-FX3 control-code list: Hold `0xD2C8` present, Toggle
  `0xF001` absent.
- `SDIO_OpenSession` returning `Session_Already_Open` (0x201E) on the FX3 (also supports
  `Parameter_Not_Supported` for FX6/BURANO-style).
- REC Hold semantics: Down starts, Up stops, both absolute (Down while recording and Up while stopped
  are no-ops). Configurable: `rejectRec` (SDIE_MovieRecOperationResults NG), `neverConfirmRec`
  (timeout test), `recConfirmDelay`.
- Dead-link simulation: `killAfterTransactions`.
- Pairing flow: `approvalDelay`, `rejectInit`.

## FakeBlackmagicCamera

`Packages/CameraKit/Tests/BlackmagicRESTTests/FakeBlackmagicCamera.swift`

An in-process fake (plain HTTP) of a PYXIS 12K on Camera 10.1, as the real one answered: the REST paths
the backend reads, the WebSocket's subscribe answers in one burst and its pushes, playback (a mode change lands 0.3 s
later), every output's monitoring overlays, and a lens the camera drives or not (`irisControllable`, `irisAuto`,
`fitLens`). Its livestream is opt-in (`config.livestream`): the active platform, custom platform files that take a
moment to load, a stop and a platform change refused while streaming (403, as Camera 10.1 does), playback stopping
the stream, and the active platform's file deleted falling back to YouTube RTMP. `LiveViewLifecycleTests` runs live
view's stream through it.

## The VENICE fakes

No VENICE is on hand between sessions, so the Savona backend (`SonySavona`) is rehearsed against two fakes:

- **`FakeVeniceCamera`** (`Tests/SonySavonaTests`, NWListener: the login CGI, the WebSocket at `/linear` framed by
  hand, and `upload.cgi`, on one port): the real VENICE 2 in-process. Its reading is the session's `master.json`
  (`VeniceFixture`); it answers in the camera's shapes and silences (menu switches "0"/"1", a bool to one gets nothing;
  a locked item takes the write and changes nothing; maps reported one entry at a time; `Button.Assign` toggled by
  the buttons' keys; a second client closed at once; `System.GetProperties` an error, or no answer with
  `silentPropertyList`). **`VeniceBackendTests`** drive the app's backend against it: what Tiles reads (model, looks,
  de-squeeze, outputs and their links, false color, color bars, naming, volts), and what each tile sends (a look
  and the outputs going to it, the de-squeeze menu value, false color's button, color bars' open way, an ignored
  write settling, a chain of linked outputs, a LUT upload, the timecode at the project rate, reconnecting).
- **`scripts/venice/mock_venice.py`** (uv script, aiohttp), for driving the app or camctl by hand: by default the real
  VENICE 2 as met on 2026-10-23 (`--savona-auth venice2`): one client at a time (and a few seconds' refusal after one
  leaves), the page's SHA-256 login, no answer to `GetNonce`, `System.GetProperties` or a request in the wrong shape,
  several messages per frame and now and then one split across two, the real property names and value shapes (menu
  switches "0"/"1", menu values, LUT maps, `{"cam": …}`), the look and its lists, the assignable buttons as the real
  one had them, locks (`/_mock/lock?name=P.System.Menu.ColorBar.MenuItem&state=Unlocked`), a change on the body
  (`/_mock/body?name=P.System.Menu.OutputFormat.Info.Sdi34&value="2"`), the LUT upload CGI, and the keys (REC with its
  2 s stop, playback). The older guesses stay behind `--savona-auth digest|basic|open`.
  `scripts/venice/mock_venice.py --port 18080`, then `camctl venice 127.0.0.1:18080 -p test1234`.
- **`SonySavonaTests`** besides: the MessagePack codec against bytes captured from a real VENICE
  (github.com/bryanrandell/Sony_websocket: ND, key presses, keep-alive — decoded and re-encoded byte for byte), the
  VENICE demo's tile flow, its page template (and how it closes up without a lens or HaLow), and every preloaded list
  checked against Sony's VENICE 2 manual and the V3.00 notes (`VeniceManualCheckTests`; `VeniceDemoListsTests`: Test
  Mode's lists follow imager mode, format and base ISO), and what the real camera showed (`VeniceSessionTests`:
  batched and split frames, padded strings, the menu tables, S&Q's denominator, shutter speeds' decimals, LUT slots,
  white balance labels; `VeniceNamesTests`: LUT file names, timecode rates, base ISO pairs, follow codes).
- **`VeniceMulticamTests`**: two `FakeVeniceCamera`s, and one beside a demo FX3, on a linked page through the real
  `DashboardStore` fan-out. REC rolls and stops both and leaves a rolling one rolling (the fake's REC key toggles its
  take); white balance, shutter and Select FPS follow and EI doesn't; a VENICE skips what it can't take, and a linked
  REC behind it isn't late; one dropping out leaves the other working.

`CAMCTL_VENICE_PASSWORD=… camctl venice HOST [--get NAME] [--set NAME=value] [--keys Rec] [--call METHOD JSON]
[--send lut=NAME] [--dump] [--listen s]` (or `-p PASS`, which `ps` shows) drives a camera (or the mock) through the app's own backend and prints what Tiles reads;
`--send` goes through the backend as a tile does (`lut=`, `look=on`, `desqueeze=1.6x`, `falsecolor=on`,
`falsecolor:Monitor=on`, `framelines=off`, `bars=on`, `iso=1600`, `flip=on`, `duration=on`) and prints what Tiles reads
after. `camctl probe HOST` says whether an address answers as a VENICE or a Camera Remote body, as Add Camera does.
`scripts/venice/venice.py` is the capture kit for a session with a real camera (docs/venice.md, "Capture day");
`venice.py savona HOST -p PASS --master` reads the whole interface into the session's `master.json`.

## The ARRI fakes

The Web Remote backend (`ArriWebRemote`) is rehearsed the same way, against a fake in the tests and one on the network:

- **`FakeArriCamera`** (`Tests/ArriWebRemoteTests`, NWListener, plain HTTP): `all.cgi`, the page script with an ETag
  (a second connection gets a 304), `update.cgi?id=` held open until a change (or missing, or answering in the flat
  shape), `set.cgi` checked against each variable's range, enum flags and read-only bit, and `call.cgi` acting like a
  camera (REC lands after a delay; playback cues, plays, skips). `ArriFixture` is the ALEXA Mini Tiles expects: the
  verified names plus the backend's guesses. `ArriWebRemoteTests` covers the page-script parser's spellings, the three
  update shapes (and one that only moves the counter), word-matching names, per-output switches, the state an ALEXA
  Mini reads as, writes in the camera's terms, REC confirmed by the camera (one at a time; trusted on acceptance when
  its state can't be read; locking the frame rate while rolling), playback, the polling fallback, the script cache,
  and a link that goes away.
- **`scripts/arri/mock_alexa.py`** (uv script, aiohttp): the same interface on any port, as an ALEXA Mini, Mini LF or
  ALEXA 35 (`--model`), with `--update flat|missing` and `--no-script`, timecode running while it records, and
  `/_mock/body?name=…&value=…` for a change made on the body. `scripts/arri/mock_alexa.py --port 18081`, then
  `camctl arri 127.0.0.1:18081`.

`camctl arri HOST [--dump] [--get N] [--set N=V] [--call COMMAND [JSON]] [--listen s]` drives a camera (or the mock)
through the app's own backend and prints what Tiles reads; `camctl arri --from DIR` reads a capture directory instead
(what `scripts/arri/arri.py go` saves), with which variable each control came from. `camctl probe HOST` names an ARRI
Web Remote and its model. `scripts/arri/arri.py` is the capture kit for a session with a real camera (docs/arri.md,
"Capture day").

## Slow and broken links

`Tests/SonyPTPTests/ShapedLinkTests.swift` puts `ShapedLink`, a TCP proxy, between the backend and the fake
camera. It paces each direction to a bit rate, delays every chunk by a one-way latency, and `cut()` drops every
connection at once.

- At 64 kbit/s with 150 ms each way (a bad day on a two-hop HaLow mesh), the backend connects in about 3.3 s and
  REC is confirmed in about 1.5 s. The fake camera's dataset is small. The real FX3's connect phase is about
  14 KB, which adds roughly 1.7 s at that rate.
- After a cut, `CameraController` brings the camera back by itself.

## Fixtures

Raw PTP-IP traffic captures from an FX3 on the LAN, captured with `camctl --record`.

| File | What it captured |
|------|-----------------|
| `fx3-connect-2026-10-08.jsonl` | Initial connect + session open |
| `fx3-dump-2026-10-08.jsonl` | Full property dump (raw traffic) |
| `fx3-dump-2026-10-08.txt` | Human-readable dump output |
| `fx3-idle-75s-ssh-2026-10-09.jsonl` | 75 s idle capture, high-frequency polling (network budget baseline) |
| `fx3-idle-75s-ssh-events-2026-10-09.jsonl` | 75 s idle capture, event-driven (~60 B/s) |
| `fx3-propinfo-changed.bin` | Raw `SDIO_GetAllExtDevicePropInfo` changed-only response |
| `fx3-propinfo-full.bin` | Raw `SDIO_GetAllExtDevicePropInfo` full response |
| `fx3-rec-hold-start-2026-10-09.jsonl` | REC start via Hold 0xD2C8 Down |
| `fx3-rec-hold-stop-2026-10-09.jsonl` | REC stop via Hold 0xD2C8 Up |
| `fx3-rec-start-2026-10-08.jsonl` | Earlier REC start (reference capture) |
| `fx3-rec-stop-2026-10-08.jsonl` | Earlier REC stop (reference capture) |
| `fx3-displaystringlist-baselook-2026-10-09.bin` | Raw display string list for look/LUT names |

## Snapshot renderer

**The VENICE gate.** `scripts/verify/venice-gate.sh <base-commit>` renders 13 VENICE pages (phone, iPad, edit mode, the
camera editor, Settings, locked, Test Mode, mixed lineups) at the base commit and at the working tree, and compares them
pixel by pixel (`scripts/verify/pixdiff.py`): any difference fails it. Run it before a build whenever a change could
reach a VENICE's pages, and expect only the differences the change means to make. Output in `qa-out/venice-gate`.

**The render audit.** `scripts/verify/audit.sh` renders the tile gallery at every Text Size (Standardized and Dynamic)
and real pages of each lineup (VENICE, FX3, FX6, BURANO, ALEXA, PYXIS and mixed) at phone and iPad sizes, Text Sizes
and appearances, about 1,500 renders, each with the alignment audit. Any render not clean fails it.
`AUDIT_LIMIT=20` runs the first 20 only. Output in `qa-out/audit`.

`DashboardSnapshot` renders the dashboard to a PNG on any Mac (no Xcode needed, no camera needed):

```sh
cd Packages/CameraKit
swift run dashboard-snapshot out.png W H "<page>" [mode]
```

`CC_SNAPSHOT_BLACKMAGIC=<host>` connects to a real Blackmagic camera over HTTPS through the app's backend and renders
page "A" with what it read, so a body's tile set can be checked against the camera (`window` mode).

| Variable | What it does |
|---|---|
| `CC_SNAPSHOT_SCALE=2` | Retina-density render, for checking alignment |
| `CC_SNAPSHOT_AUDIT=1` | Runs the alignment audit (always on for `gallery`); exits 2 on a misaligned tile |
| `CC_SNAPSHOT_STATE=<json>` | A device's saved setup (`dashboard.v1`) instead of the demo lineup |
| `CC_SNAPSHOT_PYXIS=1` | A PYXIS 12K as one read on 2026-10-12 (off-speed and overlays on), without the camera |
| `CC_SNAPSHOT_PYXIS_OFFLINE=1` | That PYXIS saved with what it last reported but not connected: grayed in use, a demo of itself in `edit` mode |
| `CC_SNAPSHOT_BLACKMAGIC=<host>` | A real Blackmagic camera's state, read through the app's backend |
| `CC_SNAPSHOT_BLACKMAGIC_LIVE=<host>` | The app's own store connected to a real Blackmagic camera, live view and all; its stream is ended before exit. With `CC_SNAPSHOT_STREAM_TO=<relay>` (where the camera streams to) and `CC_SNAPSHOT_WAIT=<s>` (time for pictures before the capture; default 0.8) |
| `CC_SNAPSHOT_ADD=liveView,zebra` | Those tiles added to the page for its first camera, as Add Tile places them; `kind@output` sets a monitoring tile to one output (`falseColor@MainSDI`) |
| `CC_SNAPSHOT_LOCKED=1` | The controls locked (`window` mode): controls gray, read-outs and the Lock tile don't. The app takes `-CCDebugLocked YES` |
| `CC_SNAPSHOT_APPEARANCE=custom` | Settings → Appearance's custom colors on, at their start (white tiles, black text on black). With `appearance` as the screen, the Appearance page itself. The app, on a setup held in memory (`-CCDebugDemoLineup YES` and the like, which otherwise ignore a saved appearance), takes `-CCDebugAppearance custom`, and `-CCDebugScreen appearance` opens the page |
| `CC_SNAPSHOT_CORNER=<pt>` | The tiles' corner radius (0 is square) |
| `CC_SNAPSHOT_TEXT_SIZE=dynamic` | Settings → Appearance's Text Size at Dynamic: each tile's type and controls at its scale (`tileScale`). Run the gallery with it as well as without. The app, on a setup held in memory, takes `-CCDebugTextSize dynamic` |
| `CC_SNAPSHOT_TEXT_SCALE=1.5` | Text Size's slider (1 to 1.5): every tile's small type bigger. Run the gallery and the real-page audit at 1.1 to 1.5, Standardized and Dynamic. The app takes `-CCDebugTextScale 1.5` |
| `CC_SNAPSHOT_PICKER_MODE=<tab>` | With `color-picker` as the screen, Tiles' color picker as its popover shows it, on `grid`, `spectrum` or `sliders` |
| (screens `terms`, `about`) | The Terms of Use sheet, and Settings → About Tiles. The renderer lays these out wider than a phone and in the light scheme; check them on a simulator (`TermsTests` attaches both). The app takes `-CCDebugShowTerms YES`: the sheet over a setup held in memory, nothing saved |
| `CC_SNAPSHOT_TALL=<n>` | n more tiles below the page's own; `CC_SNAPSHOT_SCROLLS=1` turns Fit to Screen off |
| `CC_SNAPSHOT_HALOW=1` | HaLow nodes found (three, plus one added by hand that doesn't answer) |
| `CC_SNAPSHOT_MESH=1` | Add Camera's mesh list with sample devices |
| `CC_SNAPSHOT_BODIES=venice2,alexaMini` | Those demo bodies (MockBody's case names), A, B… on one automatic page, as a new page lays them out |

Arguments:
- `W H`: width and height in points (e.g. `1920 1180`)
- `<page>`: page name to render, e.g. `"All"`, `"A+B"`, `"C"`. Omit for the default page.
- `mode`: one of `window`, `edit`, `settings`, `camera-editor`, `page-editor`. Omit for the default
  dashboard view. `window` and `edit` render through a real offscreen NSWindow. The settings screens
  require `window`-backed rendering. **The plain render leaves a page's grid blank**: render pages with `window`.

**Before a build goes to someone on set: nothing changed for their camera** (2026-10-27, a VENICE 2 shooting the next
day). Renders are deterministic, byte for byte between runs, so the last shipped build can be compared pixel for pixel:
check out its commit in a worktree (`git worktree add --detach <dir> <commit>`), `swift build --product
dashboard-snapshot` in both, render the same screens from each (`CC_SNAPSHOT_BODIES=venice2` in `window` mode at iPad
and phone sizes, two VENICEs, a VENICE beside an FX3, locked, Test Mode, `edit`, `settings`, `camera-editor`) and `cmp`
the PNGs; a tool that boxes the differing pixels tells an intended change (a new Settings row) from a regression.
That night every VENICE page matched build 48 exactly. `SavedSetupTests` covers what the renders can't: a setup saved
by build 48 (`fixtures/venice2-dashboard-build48-*`) has to read back with every camera and save unchanged.

**Before a camera goes on a shoot: a shakedown rigged as it will be on the day.** Every camera was built from captures of it in one setup, and the tests replay those captures,
so they can't see the setup the shoot uses. On set the ALEXA Mini's battery tile was grayed on the set's power, its
Clean Feed wasn't the clean picture an operator means, and its SDI 2 was cloning SDI 1; on the bench the FX5's focus
drive did nothing on AF with AF Assist off, its False Color turned out to be a button function, and its battery read
0% on USB power. So, with the camera on its day's power, lens, monitors and network:

1. Read every tile against the camera's own screen and menus, not against a capture (`camctl shakedown`, below,
   prints them side by side with what to look at).
2. Change every control the app offers and put it back, through the app's path, each read back.
3. Note, before the shoot, what's still listed for that camera under "Built, never on a camera" in
   `docs/feature-gaps.md`.

Anything found on set anyway gets that camera's state captured (`props:` or the make's `--dump`) as a fixture and a
test from it, so the fix is held to the real state.

## Live tools

### `camctl`

Connect to a real camera from any Mac.

**The pre-shoot shakedown** (above): `camctl shakedown sony|bm|venice|arri <host> [--write] [--https]`. It prints every
tile as the app reads it (battery and what powers it, media, the camera's own warnings, REC, the focus drive and push
AF, the assignable buttons, then every API field with its options) to check against the camera's screen. `--write`
changes each control the app can change now, through the API's field table as the app and a deck do, to the option
beside it and back, each read back, and lists anything it couldn't put back. It leaves REC, playback, frame rate, S&Q,
format, imager and shooting mode, flip, bars and clip flags, and anything the app asks before (a restart). Credentials:
`CAMCTL_SSH_USER` / `CAMCTL_SSH_PASSWORD` (a Sony with Access Authentication), `CAMCTL_VENICE_PASSWORD`,
`CAMCTL_BM_PASSWORD`. Its first run, against the mock ALEXA (`scripts/arri/mock_alexa.py`), found zebra left on: off
straight after on was ignored, the camera's reading not having the on yet (fixed, `zebraOffJustAfterOnIsSent`). The
mock VENICE (`scripts/venice/mock_venice.py`, password test1234) round-trips clean. Not yet run against a Sony or a
Blackmagic camera.

```sh
cd Packages/CameraKit

# Connect and show camera info:
swift run camctl connect <camera-ip>

# Dump all properties (decoded + raw hex):
swift run camctl dump <camera-ip>

# Set a property:
swift run camctl set <camera-ip> shutterangle 180.0
swift run camctl set <camera-ip> kelvin 5600
swift run camctl set <camera-ip> 0xD21E 800   # hex code + value

# Control recording:
swift run camctl rec <camera-ip> start
swift run camctl rec <camera-ip> stop

# Stay connected for bandwidth measurement:
swift run camctl watch <camera-ip> 60

# Capture raw PTP-IP traffic:
swift run camctl --record capture.jsonl dump <camera-ip>
```

**Access Authentication** (SSH tunnel): set env vars before running:

```sh
export CAMCTL_SSH_USER=<camera-ssh-user>
export CAMCTL_SSH_PASSWORD=<camera-ssh-password>
export CAMCTL_SSH_FINGERPRINT=<camera-ssh-fingerprint>
```

Without those vars, `camctl` speaks PTP-IP directly to port 15740 (pairing mode, or external tunnel on
127.0.0.1).

**On USB** (a Mac, the camera in USB Connection Mode → Remote Shooting): `swift run camctl usb` lists Sony cameras on
USB; any command takes `usb:<serial>` as its host, e.g. `swift run camctl liveview usb:0123456789AB 72`.
`scripts/fx3-usb-probe.c` is the same check in C with libusb, without the app's code. `camctl usb` lists Blackmagic
cameras on USB too, with the interface their cable makes and where it reaches them; `camctl bm usb:<serial> …` finds
the camera there as the app does. `camctl usb watch <seconds>` prints each camera plugged in meanwhile, as the app's
reconnect hears of it, and `camctl usb bonjour <seconds>` finds Blackmagic cameras the way an iPhone or iPad does,
through their Bonjour adverts over the cable.

**Run camctl against a camera in a live ssh session.** macOS lets a command run from ssh reach the local network
while its session lasts. One left running after the session ends (`nohup … &`) loses that: every request fails at
once with "The Internet connection appears to be offline" while curl still reaches the camera. For a long check, keep
the ssh session open (a pty on the machine you're working from).

**Blackmagic**: `swift run camctl bm <host> [--https] state` prints what each tile would show, through the app's
backend; `watch <seconds>` stays connected and prints what changes. `set <name> <value>` sends one control after the
WebSocket has subscribed and prints the camera's answer with its delay; names are `iso`, `angle`, `speed`, `mode`,
`kelvin`, `tint`, `wb`, `iris`, `nd`, `fps`, `offspeed`, `res`, `format`, `look`, `falsecolor`, `bars`, `desqueeze`;
an overlay on every output or one (`zebra`, `clean@MainSDI`, `status@MainSDI`), and `textfor@MainSDI director`. `play
toggle|next|prev|live` and `rec start|stop` drive playback and REC. `liveview <seconds> [low|high] [last.png]` runs
live view through the camera's livestream and ends its stream; `--stream-to <relay>` for a camera that streams through
a relay, `--again <s>` to close live view and reopen it within the linger, `--review-stop` to stop its stream the
documented way instead of through Remote Control, `--restart` to stop it after the first look and start again straight
`--rc-linger <s>` for another linger with Remote Control on. A start that hasn't reached the Mac after 8 s
prints an Activity Log line with the camera's status and the platform it's on. `camctl rtmp-listen <s> --trace` is the
receiver alone and shows each connection's handshake, commands and first video messages, timed. `set tally <Off|Green|Red>`,
`set audiogain@<channel> <dB>` (and `audioinput`, `audiolowcut`, `audiopad`, `audiophantom`) and `af` drive Tally, the
Audio tile and one-shot Autofocus. `stay <seconds>` runs the app's own store with the camera and prints each change of
its connection, reconnecting as the app does. `--remote-password <password>` (or `CAMCTL_BM_REMOTE`) connects through
Remote Control. `camctl rtmp-listen <seconds>` is the
receiver alone, for any RTMP publisher (`ffmpeg -re -i Tests/BlackmagicRESTTests/Fixtures/pyxis-stream.flv -c copy -f
flv rtmp://<mac>:1935/live/x`).

**HaLow nodes**: `camctl halow` finds the nodes the way the app does, polls each once and lists the mesh's devices
(docs/halow-monitoring.md). It needs the nodes' password:

```sh
export CAMCTL_NODE_PASSWORD=<node-admin-password>
swift run camctl halow                # nothing else configured
swift run camctl halow 192.0.2.1      # plus a node added by hand
```

Property names accepted by `set`: `shutterangle`, `iso`, `ei`, `kelvin`, `tint`, `nd`, `ndvalue`,
`framerate` — or any hex code (`0xD00E`).

### `sshtunnel-probe`

Smoke-tests the SSH tunnel end-to-end against a live camera.

```sh
export SSHTUNNEL_PASSWORD=<camera-ssh-password>
swift run sshtunnel-probe <camera-ip> <user>
```

`SSHTUNNEL_PORT` points it at another port: an sshd of your own, set to a camera's algorithms (aes128-ctr, hmac-sha1,
an ECDSA host key; the FX6 runs OpenSSH 7.9), where any login is refused when it isn't run as root, which still shows
the key exchange went through.

**Without a camera, the whole path.** The SSH servers Sony cameras run, as root in containers: OpenSSH 7.9p1 in
`debian:buster` (the FX6 and BURANO; apt sources `archive.debian.org` buster main and debian-security buster/updates)
and 8.2p1 in `ubuntu:20.04` (the FX5). Each gets a user and password, `pam_loginuid` made optional in
`/etc/pam.d/sshd`, and an `sshd_config` as a camera's: `HostKey` the ECDSA key only, `UsePAM yes`,
`PasswordAuthentication no`, `ChallengeResponseAuthentication yes` (keyboard-interactive only), `Ciphers aes128-ctr`,
`MACs hmac-sha1`, `AllowTcpForwarding yes`. A few lines of Python on 15740 in the container answer an
Init_Command_Request with an Init_Command_Ack. All five steps then run for real. On 2026-11-18 libssh2 1.11.1 with
OpenSSL 3.5.9 passed every step against both, as 1.11.0 with OpenSSL 1.1.1w did, each negotiating curve25519-sha256,
ecdsa-sha2-nistp256, aes128-ctr and hmac-sha1 and logging in with keyboard-interactive/pam. Run the probe on a pty
(`script -q /dev/null …`) when its output goes to a pipe: the 1.11.0 build sometimes crashed as it exited (OpenSSL
1.1.1's exit-time cleanup under the tunnel thread's last disconnect), which threw away its buffered output.

Runs five steps: TCP connect, handshake + fingerprint (first-connect), wrong-fingerprint rejection,
correct-password auth + PTP-IP Init through the tunnel, wrong-password rejection. Set `CAMCTL_SSH_FINGERPRINT` to the
camera's `SHA256:…` fingerprint to check it against that; without it, the later steps hold the camera to the one it
presented on the first connect.

**Never put real credentials in docs or code.**
