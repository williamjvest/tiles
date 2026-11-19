# ARRI ALEXA Mini, Mini LF and ALEXA 35: how Tiles controls them

Tiles drives ARRI cameras through the HTTP and JSON calls their own Web Remote page makes (`all.cgi`, `set.cgi`,
`call.cgi`, `update.cgi`), as seen from the page and the camera. No ARRI SDK or specification document is used.

## The Web Remote

Every ALEXA since the Classic serves a Web Remote, a browser page for controlling the camera. ARRI documents the page
but not the calls behind it.
- **ALEXA Mini** (ARRI's quick guide and SUP 4.1 manual): `http://mini-<5-digit serial>.local`, or the camera's IP.
  - Over Wi-Fi the camera is fixed at 192.168.153.1, and the Wi-Fi password defaults to `arriarri`.
  - The page has four sections: MAIN (the monitor's UI, no picture), PLAY, REC INFO with a REC button, and USER (user
    buttons).
  - A rental house's note for the Mini and Mini LF lists what it controls: run/stop, playback, fps, user buttons, EI,
    shutter, ND, look, WB, reel and timecode (chatercamera.com, "Arri Mini/ Mini LF- Web Remote Control via Ethernet
    Cable").
- **The HTTP interface behind it**, as the page and the camera use it:
  - `GET /all.cgi` returns JSON: `variables`, each with `value`, `type` (float, int, bool, enumint), `min`, `max`,
    `readonly` and, for enums, `properties` flags per index (`& 3 == 3` means selectable); and `commands`, opaque IDs
    mapped to names.
  - `GET /js/all-dg.min.js` is the page's own script. It holds each enum's order and English labels
    (`ENUM_<type>_<token>`). Enums travel as indexes, and the labels must come from the camera: the Mini LF's
    `TWO_POINT_ONE` ND token reads ND 1.8.
  - `POST /set.cgi` with `{"<variable>": value}` answers `{"result": 1}`. Some values settle after the reply, so read
    back.
  - `POST /call.cgi` with `{"command": "<id>", "set": {…}}` runs a command; a result of 0 or more means accepted.
    Named commands include `PlayBackPrepare`, `PlayBackGo`, `PlayBackStop`, `PlayBackEnd`, `PlayBackSkipClip`,
    `RecordingStart` and `RecordingStop`.
  - `update.cgi?id=<n>` is a long poll for changes, `n` being `all.cgi`'s `id`, the camera's change counter, and
    `wait.cgi` waits on a command's result. What `update.cgi` answers is still unseen; Tiles reads three likely shapes
    (below).
  - The page's requests carry no login.
  - The variables Tiles reads first: `WBCurrentKelvin` (2000–11000), `WBCurrentColorComp` (−16…+16),
    `ShutterNominal` (5–356°), `ExposurePreferenceIsAngle`, `ExposureIndex`, `ActExposureIndexIso`,
    `NDFilterPosition` / `…Effective`, `FPSNominal` / `FPSEffective`, `PlaybackSpeedEnum`, `PlaybackClipIndex`,
    `ClipCountCardA` / `B`, `SystemCameraIndex`, `RecCameraIndex`, `ClipNameCameraIndex`, `LensModelName`,
    `LdsLensModel` and `LensSerialNumber`.
  - A full `all.cgi` can run to a few hundred KB, about half a minute a read over HaLow's 64 kbit/s unless the camera
    compresses it (`arri.py go` measures the bytes on the wire).
- **One backend for the family.** The ALEXA 35's manual gives it a Web Remote like the Mini's (below). Tiles expects
  the same calls on every body it lists, and has checked them on an ALEXA Mini.
- **Each body's address.** Every one shows its LAN IP and its Web Remote's URL under INFO > Network info (MENU >
  Info > Network Info on an ALEXA 35); the IP always works. The Bonjour names, from ARRI: `mini-<serial>.local`
  (ALEXA Mini quick guide), `alexa35-<serial>.local` (ALEXA 35 SUP 1.0.3 release notes; the SUP 6.2 manual, 23.1,
  writes `localALEXA35-<serial>.local`). The serial is the last five digits of the product number. Wi-Fi is on by
  default on both, the camera at 192.168.153.1; the ALEXA 35 takes the same KC 153-S Ethernet cable as the Mini.
- **The ALEXA 35's Web Remote** (SUP 6.2 manual, 23.1) has HOME (the main parameters), MENU (the camera's menu, which
  the Mini's page doesn't have), PLAY, REC / INFO and USER. ARRI's notes: "Rec status and timecode may respond slightly
  delayed depending on the network's speed", and after a camera update the page "may not be fully functional until the
  browser cache … has been cleared" (Tiles keeps its copy of the page script per serial and firmware, so an update
  never reuses the old one). Rolling locks sensor fps, timecode, AWB and most menu settings (12.4); Tiles reads the
  read-only flags again whenever REC or playback starts or stops.
- **Bandwidth.** The web UI is a heavy page to keep live. On HaLow, Tiles should use the `update.cgi` long poll, not repeated `all.cgi` snapshots. The size of either
  is unknown until a camera is on the network.

## Not ways in

- **Tally only:** bitfocus/companion-module-arri-tally (MIT) and jasday/arritally (Go) send `tallyengage <0|1|2>` over a
  plain TCP connection to port 40000, from ARRI's Multicam white paper. Tally is all it does.
- **SSCP:** in Multicam mode an AMIRA or ALEXA Mini connects out to a Sony CNA-1 (TCP 7800) and speaks Sony's Simple
  Camera Protocol, for broadcast RCP paint controls. It's Sony's, and it isn't for Tiles.

## Roadmap

- Test on an ALEXA Mini LF or ALEXA 35 (a rental or a shoot): "Capture day" below. Check that the original Mini
  answers the same calls as the Mini LF, and measure `all.cgi` and `update.cgi` over HaLow.

## Tiles' backend

`Packages/CameraKit/Sources/ArriWebRemote`:
- `ArriProtocol.swift`: `all.cgi` read into variables (value, type, range, read-only, enum flags) and commands; an
  `update.cgi` answer merged whether it nests `{id, variables: {name: {value, type, min, max, readonly}}}`, nests
  bare values, or puts the changes beside `id`; the page script read for each enum's tokens and English labels, in the
  spellings it may use. The merge tracks both value and field-metadata changes (min, max, readonly, properties) so a
  range narrowing or a read-only lock that arrives without a value change still triggers a rebuild.
- `ArriClient.swift`: the calls, with the page script kept per camera serial and firmware and asked for again with
  its ETag / Last-Modified (a reconnect costs a 304; a new SUP never reuses the old script), and the link's latency from
  the short requests.
- `ArriMapping.swift`: each Tiles control is a field with candidate names, the verified ones first (WBCurrentKelvin,
  WBCurrentColorComp, ShutterNominal, ExposurePreferenceIsAngle, ExposureIndex, ActExposureIndexIso, NDFilterPosition,
  FPSNominal, SystemCameraType / Serial / Index, LensModelName, the playback variables), then guesses in the same style
  (CameraState, Timecode, ClipName, LookFile, RemainingRecTime…), then a word match. Outputs come from the names: a
  variable naming an output (Evf, Sdi1, Sdi2, Mon…) and an overlay (Look, Frameline, FalseColor, Zebra, Peaking,
  ExposureTool, FocusTool, Overlay) is that output's switch, if the camera can read it as on or off (a bool, a 0–1
  number, or an enum with an Off and a choice that names the overlay). The reel comes from the card in use
  (ReelCountCardB on the Mini when card B is present/selected), like media seconds already pick the card.
- `ArriState.swift`: the CameraState: EI and ND from the camera's own labels ("ND 0.6"; "ND  -" is Clear), WB in
  its range, shutter as an angle and the time it makes at this frame rate, sensor fps with the usual rates inside the
  format's range, sensor mode, codec, look, de-squeeze, color bars, the lens's iris (thousandths of a stop or a
  T-number), letter and reel, media, playback.
- `ArriCameraBackend.swift`: connects with `all.cgi` and the script (Tiles' own EI / ND / playback-speed tables only
  if the script can't be read, and only where the camera's list is the same length), then polls `update.cgi?id=S`
  continuously, passing the same session id `S` from `all.cgi` every time. The camera echoes `S` in each answer and
  reports only what changed since the session's last poll, including updated min/max/readonly. On
  `{"ERROR": "…Invalid id…"}` the session is gone: `all.cgi` opens a new one (no wait). On network errors the page's
  behavior is matched: wait ~3 s, then `all.cgi` again. When the update answer carries field metadata (type/min/max/
  readonly), read-only flag changes from REC and range changes from format switches arrive automatically — no extra
  `all.cgi` needed. When it doesn't (a counter-only camera), a one-off `all.cgi` fetches what changed. If the long
  poll isn't there (404), it reads `all.cgi` at the budget's pace instead. Two failed reads drop the link. Answers
  paced to stay near 64 kbit/s only when large; normal small answers go immediately. Writes are checked against what
  the camera allows now and shown pending until it reports them. REC is `call.cgi` RecordingStart / RecordingStop,
  never optimistic, one at a time. Playback: PlayBackPrepare sends the Mini's page payload `{"_TableVersion_Local":
  <version>}` with the card-specific command id (`_EeUkIwIBEeSgptigTra4vQ` for B, `_EeUkLAIBEeSgptigTra4vQ` for A),
  chosen by `PlaybackMediumActive` when present; PlayBackGo / Stop / End, PlayBackSkipClip by the two known IDs,
  shuttle as PlaybackSpeedEnum.

Add Camera → **ARRI**, no login; `ArriRemoteProbe` says what answered ("an ALEXA Mini"). Demos: ALEXA Mini, Mini LF,
ALEXA 35 (`arriSampleState`, `ArriTables` from ARRI's published specs). The page is `LayoutTemplates.arriCells`.
`camctl arri` and `camctl probe` run the same code from the command line; `camctl arri --from DIR` reads a capture.

The first camera, an original ALEXA Mini on SUP 6.1.2 (2026-10-29), answered every call above and settled most
guesses: REC state `MajorState`, timecode `TimecodeHours` / `Minutes` / `Seconds`, the look by `LookActiveSlot`,
media `CardA/BCapacityRemain_Raw` in seconds, the outputs' `…PathProcessing` and `SDI…` / `EVF…` / `Monitor…`
switches, and the update answer `{id, variables: {Name: {value, type, min, max, readonly}}}`. Every name, and what is
still open (REC, playback and the iris need a card and a lens), is in docs/alexa-mini-controls.md. Tiles skips a
clip with `_BJbzscJjEeSbpa7lQ8OAJw` back and `_H_V7l8JjEeSbpa7lQ8OAJw` forward.

## Capture day (whenever an ALEXA Mini is on the network)

Kit: `scripts/arri/arri.py` (and `mock_alexa.py` to rehearse against; rehearsed 2026-10-22). Captures go to
`captures/arri/<stamp>-<host>/` (gitignored: the page's code is ARRI's).

Bring: ARRI's Ethernet cable KC 153-S (K2.72021.0): the Mini's ETH socket is a 10-pin LEMO, not RJ-45 (Mini, Mini LF,
SXT, LF all take this cable). Without it, the Mini's Wi-Fi: on by default, the camera at 192.168.153.1 (password
`arriarri` unless changed), or Wi-Fi client mode to join a network. A card with room for a test clip, and a lens that
reports (LDS or /i) for the iris.

1. Network, over the HaLow mesh: the camera's Ethernet (KC 153-S) into a node in RJ45 mode; on the camera System >
   Network/WiFi > LAN IP Mode = DHCP (node N hands out addresses in its pool), and read the LAN IP and the Web Remote URL off
   INFO > Network info. Note what was there before. The laptop on another node, keeping its own internet.
2. Mac side (over SSH): `arri.py find` → `arri.py go HOST`. Seconds, read-only: every variable with its enum
   labels, the commands, the update call's answer, and what Tiles reads with which guesses missed (`camctl arri --from`).
   Fix the names in `ArriField` and rebuild the test app before the camera goes, if there's time.
3. Tiles VENICE.app (the test app, which has ARRI too since 2026-10-22) → Add Camera →
   ARRI → the address. Every tile against the camera.
4. `arri.py proxy HOST --detach` → open **http://localhost:8081/** in Chrome (ARRI supports Chrome and Firefox):
   the camera's own page through the recorder. MAIN mirrors the camera's screens and menus (walk the menu once,
   slowly: it may be every setting), REC INFO has REC, PLAY the playback keys, USER the user buttons. One control at a
   time; a change made on the camera body early, to see that the long poll carries it.
5. `arri.py watch HOST --detach`, and `arri.py note "…"` after each step; `camctl arri HOST --listen 30` shows the raw
   update answers. Each note also saves `all.cgi` (`snaps/`) and prints what the camera now allows that it didn't:
   ranges, selectable choices, read-only flags. The long poll may carry only values, so this is how ranges per sensor
   mode, codec and REC state get read; `arri.py snap LABEL` does it alone, `arri.py ranges` tabulates every snap.
6. Before the camera goes: `camctl arri HOST --set … --call RecordingStart` (Tiles' own code doing it), `arri.py diff`
   for what to put back, `arri.py stop`, and the session copied to the build Mac.

The Web Remote can't format media; nothing in the kit tries.
