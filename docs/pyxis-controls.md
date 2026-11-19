# PYXIS 12K Control Map — verified 2026-10-12

Live camera: Blackmagic PYXIS 12K, Camera 10.1, over HaLow and over USB-C, HTTPS. Read and set
through the app's backend with `camctl bm <host> --https state|watch|set|play` (docs/testing.md). The fake camera in
`Tests/BlackmagicRESTTests` answers in the shapes recorded here.

**Camera 10.3.1 (updated 2026-10-15):** the API documentation the camera serves (`/control/documentation.html`, 19
YAML files) is byte-identical to 10.1's. Rechecked over USB-C with camctl:
connect in 0.07 s, all four outputs and the zebra level and guide ratios a few hundredths later, 1 ms latency, and
clean feed on SDI set and cleared output by output, each pushed back at once. The update left every output's
overlays off. Over USB-C from an ssh session, give camctl `usb:<serial>` (`camctl usb` lists it) or the camera's
address (172.27.250.13): with `PYXIS-12K.local` it failed at once, "The Internet connection appears to be offline",
while curl reached it.

## Before connecting

In Blackmagic Camera Setup → Network Access, turn on **Web Media Manager** (and **Generate Certificate** for HTTPS),
then **Save**. Nothing applies until Save: until then every `/control/api/v1` path answers 307 to a trailing slash,
then 404.

- The REST API has no authentication.
- On the camera itself, Setup, page 13: **Remote Control** on ("control and monitor") lets Tiles stop live view's
  stream without playback showing on the camera's outputs, and with a remote password it's a second way in: Tiles'
  Connect With → Remote Control, on port 444, with Web Media Manager on or off (Remote Control, below).
- The camera advertises `PYXIS 12K._http._tcp` with `capabilities=cameraControl` and `release version=10.1`.
- Over USB-C, a Mac gets a network interface ("PYXIS 12K" in Network settings) and the camera answers at
  `PYXIS-12K.local`: the same API, about 2 ms a request. Measured 2026-11-01 (Camera 10.3.1):
  - USB: vendor 0x1EDB (Blackmagic Design), product 0xBEFB ("PYXIS 12K"), serial number
    (32 hex digits), which is the `unique id` in its Bonjour TXT (there in capitals). macOS's
    CDC-NCM driver puts the network interface (en14 here) under the USB device in the IORegistry.
  - The link: a /30, 172.27.250.12/30, the camera at .13 and the Mac given .14 by the camera's DHCP server, with no
    router and no IPv6 on the camera (no AAAA over mDNS, nothing but the Mac answers ff02::1). Two cameras on one
    Mac's USB would hand out the same pair, so Tiles reaches one Blackmagic camera by cable at a time and says so.
  - Bonjour over the cable: `PYXIS 12K._http._tcp` on that interface, wired, TXT `camera name=A`,
    `capabilities=cameraControl`, `device name`, `product id=BEFB`, `release version=10.3.1`, `unique id`. Ports 80,
    443 and 444 answer over the cable, port 80 without a login while Web Media Manager is on.
  - The REST API doesn't say which camera it is: `/system/product` has only `deviceName`, `productName` and
    `softwareVersion`. Tiles knows the camera on a cable from its USB device.
  - Over the cable the camera advertises `_http._tcp`, `_ftp._tcp` and `_smb._tcp`. Blackmagic's Android app finds
    cameras by the `_http._tcp` advert alone: `unique id` (a UUID without dashes), `device name`, `camera name`,
    `capabilities` split on commas for `cameraControl`, and `connected device`, JSON with the `deviceName` and
    `deviceModel` holding its remote control.
  - Unplugged and plugged back in: macOS sees the USB device at once and the link has its address 4.5 s later.
  - How Tiles uses it: Add Camera's On USB lists the camera from the IORegistry on a Mac, and from its advert on a
    cable's link on an iPhone or iPad; it's saved as `usb:<serial>` either way. At each connect Tiles takes the cable's
    interface (under that USB device, or the advert's), its own address there and the other of the pair, waiting up
    to 10 s for the link. A camera plugged back in reconnects at once.
  - An iPhone on the camera's USB-C: never listed. The camera's rear USB-C takes a phone for its
    mobile data, with the phone's Personal Hotspot on ("allow others to join", and Trust on the phone: the PYXIS
    manual): the camera is then the USB host and one of the hotspot's clients, on iOS's fixed 172.20.10.0/28 with the
    phone at .1, not on a two-address pair. Blackmagic's Android app finds hardware cameras by resolving the
    `_http._tcp` advert's address (JmDNS), whatever the network. So on an iPhone Tiles also lists a camera whose
    advert comes on the hotspot's interface (this device 172.20.10.1/28 there) and connects to the address its advert
    resolves to (an NWConnection to the service, IPv4; `camctl usb bonjour --resolve` checks the asking on a Mac).
    Untried with the camera: whether it comes up with the hotspot off or the phone on Wi-Fi (Blackmagic's staff on
    their forum: iOS won't tether while the phone is on Wi-Fi), and which interface iOS reports it on. The Activity
    Log says what the phone saw.
- Remote Control switched off (page 13): port 444 closed for a moment and answered again, a 401 without a password,
  so Add Camera's check can't tell it's off. Tiles' refusal through Remote Control says to check both.
- **The camera sometimes waits about 10.5 s before connecting a start** (2026-11-07, over USB-C, Camera 10.3.1, ~60 starts):
  the camera's TCP connection to Tiles' receiver normally opens 0.15–0.3 s after `PUT livestreams/0/start` (first picture
  ~0.3 s; the camera then drops that connection at ~1.4 s with FCUnpublish/deleteStream and reconnects at ~1.6 s,
  streaming from then on). Sometimes (1 in 14 to 5 in 6 per batch) the camera opens no connection at all for ~10.5 s —
  the kernel and Tiles' receiver both see it only then — and streams normally on that one connection. It happens however
  the last stream stopped (Review, Remote Control, cold start, 25–35 s after a stop) and with off-speed on or off; a
  start straight after a stop through Remote Control was instant. `camctl rtmp-listen <s> --trace` shows each
  connection's handshake, commands and first video messages, timed. Not yet tried: a kick (start again when nothing has
  connected after ~1.5 s).
- HTTP/1.1 only (no HTTP/2), server `BlackmagicDesign`.

## Controls

| Control | Endpoint | Live value | R/W | Options | Set on the camera | Notes |
|---|---|---|---|---|---|---|
| Model | `GET /system/product` | PYXIS 12K, 10.1 | r | — | — | |
| REC | `POST /transports/0/record`, `POST /transports/0/stop` | idle | w | — | ✓ (2026-11-07, over USB-C through Remote Control; a take written as A001_11071246_C007) | The PUT forms are deprecated ("will be removed"). |
| Timecode | `GET /transports/0/timecode` | `15:08:53:05` | r | — | — | Time of day here. See **Timecode**. |
| ISO | `/video/iso` | 800 | r/w | 125–3200, 15 values | ✓ 1600, 800 | The API has no base ISO. Tiles marks 800, "800 (base)" in the menu and BASE on the tile, from Blackmagic's spec ("Native ISO: 800"); a PYXIS 6K gets 400 and 3200 (the manual's dual native ISO). |
| Shutter angle | `/video/shutter` | 180° | r/w | 11.25°–360°, 20 values | ✓ 90°, 180° | ×100 on the wire: `18000`. |
| Shutter speed | `/video/shutter` | 1/48 | r/w | 1/24–1/2000, 12 values | ✓ 1/50 | Fewer at higher frame rates (1/50 up at 45 fps off-speed). |
| Shutter mode | `/video/shutter/measurement` | ShutterAngle | r/w | ShutterAngle, ShutterSpeed | ✓ | The key is `measurement`. Switching carries the exposure over: 180° at 24 fps is 1/48, 1/50 back is 172.8°. |
| Frame rate | `/system/format` | 24 | r/w | per recording area, 23.98–30 up to 23.98–60 | ✓ 25, 24 | See **Format**. |
| Off-speed | `/system/format` `offSpeedEnabled` | off, 45 fps | r/w | on, off | ✓ | |
| Off-speed rate | `/system/format` `offSpeedFrameRate` | 45 | r/w | the usual rates within the area's range: 14 in 9K 16:9 (12–65) | ✓ 60, 45 | With off-speed on, the FPS tile shows it: "60 → 24". |
| Dynamic range | `/system/dynamicRange`, `/system/supportedDynamicRanges` | Film | r/w | Film, Extended Video, Video | ✓ Video, Film | Takes a subscription but never pushes a change: read back after a write and once a minute. |
| Resolution | `/system/format`, `/system/supportedFormats` | 9K 16:9 | r/w | 20 recording areas, 12K 3:2 to 4K 6:5 | ✓ 4K 16:9, 9K 16:9 | Labeled from `resolutionDescriptor`. A change takes about 1.4 s. |
| Codec | `/system/format` `codec` | `BRaw:8_1`, shown BRAW 8:1 | r/w | 8 per area | ✓ 12:1, 8:1 | Q0 Q1 Q3 Q5 with 3:1 8:1 12:1 18:1 (12K, 9K), 3:1 5:1 8:1 12:1 (8K), 3:1 4:1 5:1 6:1 (4K). `/system/codecFormat` answers 501. |
| Kelvin | `/video/whiteBalance` | 5600 | r/w | 2500–10000 | ✓ 4300 | |
| Tint | `/video/whiteBalanceTint` | 10 | r/w | −50–50 | ✓ 0 | |
| Auto WB | `PUT /video/whiteBalance/doAuto` | — | w | — | ✓ | One shot from the middle of the picture; the camera pushes the new Kelvin and tint (≈ 90 ms). Auto in the WB menu. |
| WB presets | `/video/whiteBalance` | — | w | 3200, 4000, 4500, 5600, 6500K | ✓ 3200, 5600 | The camera's own presets as the manual lists them (Bright sunlight, Incandescent, Fluorescent, Mixed light, Cloud), as Kelvin: the API has no preset, and the manual says the presets carry "some tint" without saying how much, so a preset here sets the Kelvin only. The menu ticks the one the Kelvin matches. |
| Iris | `/lens/iris` | — | r/w | thirds across the lens's range | — | Only for a lens the camera can drive (`/lens/iris/description` `controllable`); read-only while auto exposure drives the aperture (`continuousApertureAutoExposure`; a set is 403 then). A lens fitted while connected gets the tile, and its aperture is read then (it can be pushed before the description). Built from the camera's API documentation: manual lenses don't have an iris tile. |
| ND | `/video/ndFilter` | 501 | — | — | — | No ND in this body. |
| Look (LUT on) | `/monitoring/{display}/displayLUT` | off | r/w | on, off | ✓ | On every output: on only when all of them show it. |
| False color | `/monitoring/{display}/falseColor` | off | r/w | on, off | ✓ | Same. |
| Monitoring | `/monitoring/{display}/{zebra, focusAssist, frameGuide, frameGrids, safeArea, cleanFeed}` | all off but clean feed on SDI | r/w | on, off, output by output | ✓ zebra everywhere, guides on the LCD, clean feed on SDI | Monitoring Options and its window; LUT, False Color, Zebra, Focus Assist, Frame Guides and Clean Feed tiles set every output or one, picked in edit mode (Clean Feed starts on SDI). |
| Zebra level, guide ratio | `/monitoring/zebra`, `/monitoring/frameGuideRatio` (+ `/presets`) | 95 %, 16:9 | r/w | 75–100 %; 11 presets, 2.4:1 to 9:16 | ✓ 85 %, 2.39:1 | In the Monitoring sheet. |
| Color bars | `/camera/colorBars` | off | r/w | on, off | ✓ | |
| Battery | `/camera/power` | 100%, on AC | r | — | — | |
| Media remaining | `/media/workingset` | 51 min | r | — | — | The slots are padded with nulls; the active disk's `remainingRecordTime`. |
| Playback | `/transports/0`, `/transports/0/play`, `/transports/0/playback`, `/timelines/0` | live | r/w | — | ✓ | See **Playback**. |
| Naming (slate) | `/slates/nextClip` | camera A, reel 1 | r/w camera, r reel | camera A–Z | ✓ camera B, A | Partial PUTs. The reel stays with the card: a change is a 409, "Reel number is not editable." The next clip's `clipName` is only "Next Clip", so Tiles shows the letter and reel, not a name: a file name (`A001_07171155_C063.braw`) also has the time the take starts and its number on the card. A new camera letter names the next take (A → B gave `B002_11071424_C001.braw`) and starts a new reel: reel 1 → 2, with clips from C001; going back to A kept reel 2. The API can't set the reel (409). |
| Latency | WebSocket ping | 1–2 ms (USB-C), 153 ms (150 ms proxy) | — | — | — | Every 10 s, the last four averaged. No pong in 5 s fails the connection. |
| Tally | `/camera/tallyStatus` | None | r/w | None, Preview, Program | ✓ Preview, Program, None (2026-11-01, over USB-C) | Build 57, from the API's documentation (CameraControl). Shown as Off, Green, Red, as the BURANO's lamps (and the Control API's `tally`). Subscribed after connect, never with connect's burst (a subscription the camera never answered would fail the connection there); read over REST if the subscription brings nothing, then once a minute; read back after every set. A switcher's tally over SDI may set it too. |
| Autofocus | `PUT /lens/focus/doAutoFocus`, `/lens/focus/description` | not controllable | w | — | not yet | Build 57, from LensControl: one shot, sent with the middle of the picture (0.5, 0.5) rather than an empty body. Offered while the description says `controllable` (a 403 otherwise); manual lenses aren't controllable. With one on, the description reads `{"controllable": false, "focusDistance": {"adjustable": true, "min": 0, "max": 0}}` and Tiles offers no Autofocus. |
| Audio | `/audio/channels`, `/audio/channel/{i}/{input, level, phantomPower, padding, lowCutFilter, available}`, `…/input/description`, `…/supportedInputs` | 4 channels: Camera - Left, Camera - Right, None, None; 0 dB | r/w | 14 inputs: None, Camera - Left / Right / Mono, XLR1 - Mic / Line, 3.5mm Left / Right / Mono - Line / Mic, USB - Left / Right; gain −6…6 dB on the camera's mics, 0…60 on XLR1 - Mic | ✓ gain 3 dB and back, input XLR1 - Mic and back (2026-11-01, over USB-C) | On the camera's mics no switches; XLR1 - Mic has 48 V and a −20 dB pad, no low cut; XLR1 - Line has the pad forced. **The pad on XLR1 - Mic stays on**: a PUT `{"enabled": false}` gets 204 and the camera keeps it on, at 0 or 30 dB, nothing plugged in; Tiles shows what it reads back and the Activity Log says the camera kept it. 48 V not switched (unknown what's on XLR1). Build 57, from AudioControl. Subscribed after connect in the same burst as the monitoring (an answer goes to whichever burst is owed one); anything that comes without a value is read over REST, and the description and input list (never pushed) are read after connect and whenever the input changes. Phantom power, low cut and pad only where the description says the input has them; a forced pad is on and fixed. No meters in the API. |

Not in the API: base ISO, focus mode, live view. Which LUT is in use, status text, what it shows and the de-squeeze
aren't either, but the camera's presets carry them, and Tiles sets them through one (**Presets**).

Displays: LCD, FrontUSBC, RearUSBC, MainSDI, Stream, shown as LCD, Front USB-C, Rear USB-C, SDI. Stream's monitoring
can be set over REST but not subscribed to, so Tiles neither shows nor writes it (no false color on a livestream).

## Monitoring

Every overlay is per output, and so is Tiles' model of it: clean feed only means something on one output, and the
operator's LCD and the client's SDI often want different overlays. Connect subscribes to the first output's LUT and
false color; every output's overlays, the zebra level and the guide ratio are subscribed right after, in one burst,
and nothing there can fail the connection. An output's overlays are the ones its subscriptions answered. Look, false
color, and the Zebra, Focus Assist and Frame Guides tiles cover every output: lit only when all of them show it, so
a tap turns it on where it's still off.

Clean feed hides every overlay on its output but the LUT: with SDI on clean feed, LUT changes showed there and false
color, guides and zebra didn't (2026-10-13; the manual: "all status text and overlays for an output, except the
record tally"). So Tiles grays that output's other overlays in Monitoring Options (`MonitorOutput.setting`), and the
every-output switches leave it out: it doesn't count towards lit and isn't written to, so its own settings are as they
were when clean feed goes off. With every output on clean feed those tiles are grayed. Status text, including the
Director or Cinematographer info display, isn't in the API: not in Camera 10.1's or 10.3.1's (the camera's own
documentation is 10.1's, byte for byte, its event list hasn't got it, and `/monitoring/{display}/statusText` and its
likely siblings answer 404), nor in Blackmagic's newest published API document (August 2025). Blackmagic's SDI Camera
Control Protocol only turns status on and off per output. The camera's presets have it: **Presets**.

Each of those one-tap tiles, and Clean Feed, can instead be set to one output in edit mode (2026-10-14: "just
for SDI or global"), so in use a tap only turns it on and off (`PageWidget.output`, `CameraState.monitorSwitch`). A
tile set to one output names it under its title, lights from that output alone and writes only to it; one whose
overlay that output's clean feed hides is grayed, as in Monitoring Options. Clean Feed starts on SDI: on the LCD it
would hide the operator's own status. Until the outputs have been read after connect, a tile set to one output is
grayed rather than taking the first output's LUT and false color (`look`, `falseColor`) for its own, so it never
writes to every output.

## Presets

What the API hasn't got but a preset has, set through
one (`BlackmagicPreset.swift`). The API saves the camera's state as a preset (`PUT /presets/{name}.cset`, no body),
sends it (`GET`), takes one (`POST /presets`, the file as `application/octet-stream` with its name in
`Content-Disposition`; answered `{"presetAdded": name}`, with a number added if the name is taken) and loads one
(`PUT /presets/active {"preset": "name.cset"}`). There's no partial load in the API, but the camera only loads the
sections a preset has, so Tiles sends just the one section a change is in, whole (2026-10-15: "any way we can
target those setting changes instead of loading the whole preset?").

What a PYXIS does with a preset (Camera 10.3.1, 2026-10-15, each checked by comparing the camera's whole state before
and after: `scripts/cset/csetprobe.py`):

- **A section the preset hasn't got is left alone.** A preset of `transport` alone (96 bytes) changes the de-squeeze
  and nothing else; one of `metering` alone (200 bytes) changes the status text and nothing else.
- **A section it has is loaded as a whole.** One with a single setting in it (`transport {92}`) was ignored.
- **An empty section is not "nothing"**: a preset of empty sections turned on SDI's zebra and frame guides, put the rear
  USB-C output on clean feed, changed lens values, and put a placeholder (0xDEAD1212) in the exposure settings. Loading
  the whole state back cleared all of it. Tiles never sends an empty section.
- Loading a whole preset sets lens field 7 (100160) if the camera hasn't got it, which it hasn't after starting up.
  Nothing showed it; a one-section load doesn't touch the lens.
- A one-section load doesn't blink the picture: through three status text changes and two de-squeeze changes
  (2026-10-15) the LCD showed only the change itself.

A preset (`.cset`) is a protobuf message with no published schema: field 1, then field 10 once per section,
`{1: name, 2: settings}` (exposure, metadata, transport, audioMeter, metering, audio2, power, usbDevice, imageSensor,
imageProc, CCU, lens, ui). Found by changing one setting on the camera at a time and diffing the presets it saved:

| Setting | Where | Values |
|---|---|---|
| Each output's overlays | `metering` 32, once per output in `/monitoring/display`'s order without Stream (LCD, front USB-C, rear USB-C, SDI) | 1 LUT, 2 frame guide, 4 false color, 5 zebra, 9 clean feed (0/1); 15 is 1, and 0 with focus assist on (2026-11-04) |
| Status text | `metering` 32[output] 8 | 0 off, 1 on |
| What status text shows | `metering` 32[output] 14 | SDI: 3 cinematographer, 4 director; LCD and USB-C: 1 meters, 2 codec and resolution (both checked on the menu) |
| The LUT in use | `metering` 100 | its file name ("Blackmagic Gen 5 Film to Extended Video.cube", "P6K Gen5 FilmUnlimited 500T -1EV.cube"); one for the whole camera (each output's LUT on/off is in the API). A name the camera hasn't got is ignored. |
| Anamorphic de-squeeze | `transport` 92 | 0–6: None, 1.33x, 1.5x, 1.6x, 1.66x, 1.8x, 2.0x (the URSA Cine manual's list; the PYXIS manual lists none). Each checked 2026-11-04 by live view's picture, which the camera de-squeezes: at 4K 3:2 (12288 × 8040's 1.528:1) the picture is 1920 wide and 942, 838, 785, 757, 698 and 628 rows high for steps 1–6 (1920 / (1.528 × 1.33, 1.5, 1.6, 1.66, 1.8, 2.0): 942, 838, 785, 757, 698, 628), and pillarboxed 1649 × 1080 at None. 1.3x would be 966 rows, 1.65x 761. |

How Tiles uses them:

- **LUTs are learned**: a preset names only the LUT in use, and nothing on the network lists the camera's LUTs (the
  API, its web file manager at `/mounts/`, FTP and SMB serve media only; checked 2026-10-15). So every LUT Tiles sees
  in use joins that camera's list, which is kept with the camera (`CameraProfile.luts`) and handed back to the backend
  at connect. A LUT picked on the camera shows within a minute (checked with a custom 500T LUT). Picking one the camera
  has since lost: the camera ignores it, and it comes off the list.
- **Read** after connect, once a minute (a change made on the camera shows within a minute), after a change, after
  each take (a camera that was rolling when Tiles connected hasn't been read) and on leaving playback, never during
  playback (a save there hasn't been tried, with no card in our camera to try it): the
  state saved as `TilesRead.cset`, read and deleted. The camera answers a save before it has written the file, and
  more slowly just after loading a preset: a read straight after got the file it replaced, and a deleted file came back
  a moment later. So a save starts by deleting any file of that name, and the read waits for the new one (404 until
  then).
- **Change**: the state read, the value changed (everything else passed through byte for byte), and only the section
  it's in uploaded (`TilesChange.cset`: `metering` for status text, `transport` for the de-squeeze) and loaded; then
  the state read until the change shows (the camera loads it a moment after answering), as REC waits for the camera,
  and the preset deleted. About 1.2 s over USB-C. The tile shows the change at once, as pending. Asked for what it
  already is, nothing is loaded. One change at a time: one saved before another landed would load the section without it.
- **Never an out-of-date or part-written section**: a section is loaded whole, so what's sent must be whole and
  current. A read the camera hadn't finished writing is refused: cut inside a field it doesn't parse, cut between
  sections it lacks sections the fullest read since connecting had (the change tries three reads). If the camera
  pushes a monitoring change between the read and the load (someone on the camera's menu), the `metering` copy is out
  of date and isn't loaded. Only the name the camera gave the upload (`presetAdded`) is loaded, never a guessed one
  that could be an old state left on the camera.
- **Not during a take**: loading a preset mid-take hasn't been tried, so these settings are grayed while the camera
  records, and a take that starts while a change is on its way (REC on the camera, or in Tiles) stops it before the
  load.
- **The outputs must tally**: the preset's `metering` 32 count must equal the outputs the API reports, or Tiles leaves
  all of it alone. Only on a PYXIS: another model could keep something else in these fields.
- **Other software** (`/system/product`'s `softwareVersion`; checked field by field: 10.3.1,
  `BlackmagicCameraBackend.checkedSoftware`). Blackmagic puts out camera software every few weeks, mostly for other
  models (10.3.2 and 10.3.3 within two weeks of 10.3.1), and a version list alone turns these settings off on every
  PYXIS that updates. So on other software a preset is read as usual and used only when it's laid out as
  10.3.1's (`PresetFile.layoutMismatch`): every field `transport`, `metering` and each output's entry have on
  10.3.1, by number and wire type (the camera saves every field, zero ones too: the de-squeeze at None is a 0, and
  two presets saved weeks apart with different settings have the same fields); an entry for each output the API
  reports, whose LUT, frame guides, false color, zebra and clean feed are what the API reports for that output (the
  entries are matched to outputs by order alone, and this is what says the order still holds; the LUT, on or off by
  output, is the one most likely to tell outputs apart); the LUT in use a .cube file name; and the values Tiles reads
  in range. Otherwise nothing is loaded, and the check runs again at the next read. The Activity Log names the
  camera's software at each connect and says which way the check went, and why when it fails. Checked on the camera
  (2026-11-04, 10.3.1 taken as unchecked: `camctl bm <host> --layout-check`): it passes with the overlays as they
  were (LUT on every output, nothing else), with frame guides on the LCD, clean feed on rear USB-C and zebra on SDI,
  and with the LUT off on SDI and false color on rear USB-C; the de-squeeze set through it lands. Left
  open: a firmware that kept these fields but reordered the entries would pass on a camera whose outputs all look the
  same, and a status text change could go to another output. The full check after an update is still
  `scripts/cset/csetprobe.py <camera>` and the field map with `csetwatch.sh`, then the version added.
- The active preset is left naming Tiles' deleted file (`GET /presets/active`); nothing on the camera showed it.

`camctl bm <host> --https set status@MainSDI on|off`, `set textfor@MainSDI director|cinematographer`, `set desqueeze
1.5x` run it from a Mac. Over USB-C from an ssh session, give the camera's USB-C address (e.g. 172.27.250.13).

To map another setting: `scripts/cset/csetwatch.sh <camera>` saves the state as a preset every few seconds and keeps
each one that changed. Change one thing on the camera at a time, then `scripts/cset/csetdiff.py` the snapshots either
side of it. `cset.py` dumps a section; `csetpatch.py` sets one value (`metering '32[3].14' 4`: SDI for the director)
to load by hand.

## WebSocket

`wss://<host>/control/api/v1/event/websocket`. The camera sends `websocketOpened` first.

- **One property per subscribe request.** A request naming any property the camera hasn't got is refused whole
  (`Property "/video/ndFilter" not found`, success false) and nothing in it is pushed.
- Each subscribe answer carries the property's current value, except `/camera/power`'s (it's pushed when the voltage
  moves).
- `/transports/0/play` is a bare boolean, not an object.
- A change arrives about 20 ms after the PUT (USB-C).
- The camera answers pings.
- Not subscribed: `/transports/0/timecode`, pushed every other frame, and `/transports/0/playback`, pushed every frame
  while playing (20–30 kbit/s each).

## Timecode

The app runs its own clock. On connect it reads the timecode at the start and the end of the reads; if it moved, the
clock runs. Two reads under a quarter second apart (a USB-C connect takes 50 ms) can't tell, so it reads twice more,
half a second apart. It reads again once a minute, and when REC starts or stops (record run).

## Format

- `PUT /system/format` takes only a whole, valid format, `sensorResolution` included. One field alone, or no sensor
  window, is `Invalid format` (400).
- After playback the camera pushes its format without `sensorResolution`; the backend fills it in from the supported
  list.
- In playback, `/system/format` is the clip's format (`BRaw:12_1` for a 12:1 clip).
- A new recording area keeps the frame rate and codec where it allows them. Otherwise it takes the nearest: 8:1 in
  4K becomes 6:1 (not Q0, the heaviest), and 60 fps in a 12K area becomes 30.

## Playback

- `PUT /transports/0 {"mode": "Output"}` takes about 0.8 s, and play or a seek before it lands is `Invalid state`
  (400). The backend waits for the pushed mode.
- Entering playback goes to the last clip.
- Positions are timeline frames. `PUT /transports/0/playback {"position": n}` alone seeks and keeps the speed.
- `POST /transports/0/stop` pauses and stays in playback; `{"mode": "InputPreview"}` goes back to live.
- Previous: more than a second into a clip goes to its start, within the first second to the clip before.
- Tiles has the FX3's Live | Review switch for it: Review is `{"mode": "Output"}` (pushed back in 0.9 s over USB-C),
  Live `{"mode": "InputPreview"}` (1.7 s). The transport buttons work in Review; no Review during a take.
- The camera keeps its own playback timeline (`/timelines/0`). On 2026-11-07 it held only the two 12K clips recorded
  first on that card (C001, C002, 12288×6912 BRAW 8:1) while the card had nine (the rest 4096×2680 BRAW 4:1, two of
  them shot that day), so Review played C002, not the last take. `POST /timelines/0/clear` and `POST /timelines/0`
  answer 501 "Not implemented for this device", so Tiles can't put a take on it. In playback the camera reports the
  playing clip's white balance (5600 K) instead of the live setting (3200 K). A de-squeeze change sent from a
  connection made during playback didn't apply; presets aren't read during playback. The camera's own Play button did
  show that day's takes, so playback entered on the camera rebuilds the list it plays; whether `/timelines/0` then holds
  them, and keeps new takes, is the next check. Tiles' Review reads `/clips` (every clip on the card) once it's in
  playback and, if the highest `clipUniqueId` isn't on `/timelines/0`, the Playback tile says "not the latest take" and
  the Activity Log says why (`checkLatestTakeListed`); Live clears it.
- **Review played the clip last pulled up, not the latest take** (a PYXIS 12K over HaLow: "if I've triggered playback
  several clips back it will bring that up"). So the camera went back
  to where it last played, over Tiles' seek or instead of it. Not seen on the bench, where a seek right after the
  pushed mode held. Review now reads `/timelines/0` afresh, seeks to its last clip, checks the position 0.35 s later
  and seeks again if the camera moved (three tries). It checks again 0.5 s into playing and sends the seek once more
  if it moved, and the Activity Log says each time it had to. To confirm on a camera: the log lines, after Review
  from a clip several back.
- **The Clips window** (a clip list viewer and selector in all compatible cameras): the camera's
  playback list in its order (`/timelines/0`), each clip named by its file from `/clips` (`filePath` without the folder
  and extension, matched by `clipUniqueId`) and timed from its `frameCount` at the project rate. A tap seeks to that
  clip's start, found again by id in a fresh read of the list, and plays, with Review's checks (three tries, then one
  more 0.5 s in). `/clips` is read once connected and again when the list has a clip it hasn't named. The Playback tile
  names the open clip from the same list. Only what's on the playback list can be played: where the latest take
  isn't (above), the window says so. Never on a camera.

## LUTs

The API has the display LUT on and off, output by output (`/monitoring/{display}/displayLUT`), and nothing else:
no list of the camera's LUTs, no way to pick one, no upload. Checked on Camera 10.1 (the PYXIS's
software in April 2026; 10.3.1 by October): the camera's own API documentation, Blackmagic's REST API manual (it mentions only "the display
LUT enable state"), the paths the camera answers, and its web UI (Web Media Manager only). A camera preset (`.cset`)
does carry the chosen LUT by name ("Blackmagic Gen 5 Film to Extended Video.cube"), but applying one sets the whole
camera, and nothing lists the LUTs to choose from. So Tiles has LUT and False Color on every output, and each output's
LUT in Monitoring Options; picking and loading LUTs stays in the camera's LUTs menu (from a card or USB-C disk).

The camera's FTP server (anonymous and writable, `ftp://<camera>/nvme1/3DLUTs/`) does take a `.cube`; importing it
into a LUT slot is still the camera's LUTs → Manage → Import LUT. Tiles doesn't upload yet.

## Live view

The API has no picture. The only video the camera sends over the network is its livestream (RTMP, H.264), so live view
goes through it, with Tiles as the RTMP server (`BlackmagicLiveView.swift`, `RTMPReceiver`, `AVCDecoder`).

- **Start.** Tiles puts its platform file, `Tiles.xml`, into `/livestreams/customPlatforms`: one server,
  `rtmp://<this device>:1935/live`, and two profiles, Low (1.5 Mbps at 1080p) and High (4 Mbps), with low latency and
  a key frame every second. The camera takes a moment to load a file (picked straight away it's "Invalid server", 400),
  so Tiles waits for `/livestreams/platforms/Tiles`, picks it in `/livestreams/0/activePlatform` and starts the stream.
  On the PYXIS over HaLow: 3.4 s to start, the first picture a second later, then 24 a second at about 1.6 Mbps.
- **The camera's own.** Its platform (and key) is remembered and put back at the end. A stream of its own, a broadcast,
  is never taken over: live view says the camera is streaming instead.
- **Stop.** The camera refuses `PUT /livestreams/0/stop` outside a Remote Control session ("stream is active to a
  different destination", 403), and a platform change while a stream runs. With Remote Control on (below), Tiles stops
  it from a session held for just that, and nothing shows on the camera: over HaLow, 1.7 s from the stop
  to the camera's own platform back. Without it, playback can't stream, so Tiles flips to Review and back, as soon as
  the stream is ending: playback shows on the camera's outputs for 1–4 s. Neither during a take: the stop waits for
  the take to end. `Tiles.xml` goes only once the stream is idle: deleted while it streams, the camera carries on
  streaming to its own platform (YouTube).
- **The stream outlives live view**, by a minute when a stop shows (Review) and by 15 s when it doesn't (Remote
  Control): a page change, the app in the background or a dropout picks it up again (the receiver listens again on the
  same port, and the camera reconnects to it within a second or two). After a dropout the stop waits for the
  connection. A stream an earlier run left going to this device stops after the linger once Tiles connects, unless
  live view opens first; another device's live view is left alone.
- **Playback.** Review stops the stream; back in live, from Tiles or the camera, Tiles starts it again: about 3 s after
  the camera reports live, which the PYXIS takes about 3 s to do.

`camctl bm <host> --https [--stream-to <relay>] [--again <s>] liveview <s> [low|high] [png]` runs all of it from a
Mac: `--stream-to` for a relay (tested through a port proxy), `--again` to close live view and open
it within the linger.

## Remote Control

Measured on the PYXIS (Camera 10.3.1) on 2026-11-01, from what the Blackmagic Camera app does; Blackmagic doesn't
document it. Turned on on the camera itself: Setup, page 13, **Remote Control** on, "control and monitor", and if
wanted a **remote password**. No computer needed. Tiles uses it for one thing: stopping live view's stream.

- **Any login.** The session opens whichever way a device is let in: plain HTTP with no login, HTTPS with the Camera
  Setup login, or HTTP Basic with the user name `BMD_RESTCONTROL_USERNAME` and the remote password (which opens the
  whole REST API, on 443 and on 444, the port the app uses).
- **Port 444 without Network Access.** With Web Media Manager off in Blackmagic Camera Setup, 80 and 443 answer every
  API path with a 307 (the API is off there), and 444 still serves all of it, WebSocket included, to the remote
  password (401 without). Checked through Tiles' own code: state and events, a setting changed, live view at 24.6
  pictures a second, and the stop through Remote Control. Tiles offers it as Connect With → Remote Control: only the
  password, the port and the user name filled in. A new camera starts on it, and Add Camera checks the address: port
  444 answering (401 to no password) means Remote Control; else the API answering on port 80 means Network Access. 444 has the same certificate as 443, issued by Blackmagic's own CA
  to `PYXIS-12K.local` and dated the day Generate Certificate was clicked in Camera Setup; whether a camera that never
  had one serves 444 is open. Over USB-C to a Mac it's the same (the camera at `pyxis-12k.local`, here 172.27.250.13):
  444 asks for the remote password and takes it, and through Tiles' code the connection came up in 0.07 s, live view's
  first picture 1.3 s after the start, 23.6 a second, and the stop through Remote Control.
- **A session, one device at a time.** `POST /access/request` `{"deviceName", "deviceModel", "streamingXML":
  "<file>.xml"}` answers `{"status": "accepted", "availability": "control-and-monitor", "token"}`, or `{"status":
  "denied"}` while another device holds it (`GET /access/status` names it, `currentDevice`). `POST /access/heartbeat
  {"token"}` keeps it; without one it lapses after 8–10 s. `POST /access/disconnect {"token"}` ends it. Another
  device's session doesn't stop anyone's REST reads and writes.
- **The session's platform.** `PUT /livestreams/customPlatforms/<file>.xml`, listed in `/livestreams/platforms`
  0.1–2.4 s later. `PUT /livestreams/0/start` inside the session streams to it, and the camera's own platform
  (`/livestreams/0/activePlatform`) is never changed. The camera deletes the file when the session ends. The app's own
  file: one server, `srt://<device>:7001`, one low-latency profile; the camera, an SRT caller, sends MPEG-TS (H.264
  Main 1080p, AAC 48 kHz stereo, unencrypted, stream ID `#!::bmd_uuid=<uuid>,bmd_name=<camera letter>`). RTMP works
  the same way.
- **Live view through a session turns into a broadcast when the session lapses — three ways around it tried, none
  works.** A device gone for 8–10 s (a crash, a dropout, a phone put away) loses its session, and the stream carries on
  to the camera's default platform with the camera's own key: 4.5 Mbps "Connecting" to YouTube RTMP here, the mesh
  having no internet. What happens under that: a session's start SETS `/livestreams/0/activePlatform` to the session's
  platform, and when the session ends the camera deletes the file the session named — one put before the session asked
  for it goes too — and resets the active platform to its default, the first built-in, not what was active before (a
  receiver's platform picked as active beforehand was passed over), the running stream following it. Blackmagic's own
  app is built the same way: "monitor" availability only hides its control buttons, and its stop does nothing about a
  lapse, so it has the hole too. A start in a session whose file isn't there goes to the camera's own platform as
  well. (One curiosity the other way: a new session's platform file pulls a stream that's going to it — the receiver
  got pictures the moment one was put.) So Tiles' live view doesn't stream through a session: it stays on Tiles'
  platform, which no session touches, and no lapse can move.
- **Stop.** Inside a session whose platform file streams to the device holding it (the file's URL has the requester's
  address), `PUT /livestreams/0/stop` is let through and stops whatever stream is going: a lapsed session's, or the
  camera's own broadcast. A file pointing anywhere else (another device on the mesh, the camera's own loopback), or no
  file: 403, as outside a session. Disconnecting a session ends a stream started in it too.
- **Tiles' stop** (`BlackmagicRemoteControl.swift`): only once the stream is known to be this device's (the camera on
  Tiles' platform, its URL this device's). A session, a file of its own pointing at this device (`TilesRemote.xml`,
  never streamed to), the stop, the disconnect, which deletes the file. A session that lapses midway deletes nothing
  anything streams to. Another device holding the session, or no Remote Control: Review, as before.
- **Bandwidth.** 5 Mbps (the app's default) was more than a two-hop HaLow mesh carries; 1.5 Mbps streamed cleanly.

Not yet checked: during a take (Tiles' stop waits for the take's end anyway); a camera with no certificate (one never
through Camera Setup's Generate Certificate) on port 444; the camera's own Setup page 13 set to "monitor" rather than
"control and monitor" (from the app's code it only changes the availability its UI reads, not the streaming path); what
the access API answers with Remote Control off.

## Connect

Over REST: `/system/product`, `/system/supportedFormats`, `/monitoring/display` and the timecode, which can't be
subscribed to. Everything else comes in the subscribe answers, sent in one burst on the WebSocket, and a read fills in
an answer without a value. On a link with a 150 ms round trip (a bad day on a two-hop HaLow mesh, simulated with a
delay proxy) that's 1.6 s, where reading each property took 4.5 s; over USB-C, 80–100 ms.

If the WebSocket doesn't open, or doesn't answer every request, within 10 s, the connect fails; if it closes later,
the connection fails then. Either way the app reconnects (after 1, 2, 4, 8 s, then every 10 s): without the WebSocket
the camera's changes wouldn't reach it.

**A login** (the camera's network access user and password): with one set, the PYXIS (Camera 10.3.1) answers HTTPS
only with it, as HTTP Basic (`401`, `WWW-Authenticate: Basic realm="'PYXIS 12K'"`, the WebSocket's opening request
too), and plain HTTP without it. Tiles sends the login, when one is set for the camera, with every request and on the
WebSocket's opening one, and a camera without a login ignores it. Checked on the camera, 2026-10-15, with its login on
and off: with it, without it ("The camera wants a login…"), a wrong one ("…turned down the login…"), HTTP, and a
change through a preset. The REST API document doesn't mention it.

## Not yet verified

- A second Generate Certificate raising the fingerprint-changed alert.
- An electronic lens's iris.
