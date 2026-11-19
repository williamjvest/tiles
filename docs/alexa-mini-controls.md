# ALEXA Mini controls: ARRI's documents, then the camera (2026-10-29)

The original ALEXA Mini, not the Mini LF. Its last firmware is SUP 6.1.2 (7 Feb 2022, fixes on SUP 6.1), and ARRI
lists it as a legacy camera; SUP 7.x is the Mini LF's. Page numbers are ARRI's SUP 6.1 user manual (18 Nov 2020).

**Met one on 2026-10-29**: SUP 6.1.2, at `http://mini-<serial>.local` on the venue's network,
no CFast card and no LDS lens. Its Web Remote is the same interface as the Mini LF's: `all.cgi`, `set.cgi`, `call.cgi`,
`update.cgi?id=` and `/js/all-dg.min.js`, with no login (`webremote.html`; `/` redirects there). 1,042 variables and 236
commands. lighttpd 1.4.48 serves both uncompressed: `all.cgi` 262 KB, the page script 1.2 MB, about 33 s and 150 s at
HaLow's 64 kbit/s. `update.cgi` answers `{id, variables: {Name: {value, type, min, max, readonly}}}`, ranges
included, at once and often: the level sensor (`LevelRoll`, `LevelTilt`), sensor temperature and the timecode's
seconds all move (the first answer: `LevelRoll`, `LevelTilt`, `SensorTemperatureCelsius`, `SystemDateSeconds`, `TimecodeSeconds`). Enums carry a `textid` per choice beside `properties`. The capture is on the build Mac
(`captures/arri/<stamp>-<address>/`, gitignored); what Tiles reads from it: `camctl arri --from` that folder.

**The protocol, as the camera's own page speaks it** (`all-dg.min.js`, and its calls recorded through `arri.py proxy`):
`all.cgi` opens a client session, and its `id` (0, 1, 2, 3, 6 seen) is that session, not a change counter. The page
asks `update.cgi?id=<session>` again as soon as each answer lands (3 s timeout); the camera answers only what changed
for that session, ranges and read-only flags included, every 0.2–1 s here. `{"ERROR": "…Invalid id…"}` or a failed read
(after 3 s) means `all.cgi` again. One parameter at a time: `set.cgi {Name: value}` → `{"result": 1}`, back on the
session in 0.3–0.7 s; a refusal is `{"result": 0, "error": "Could not set FPSNominal to 150"}`. `call.cgi` answers
`{"result": N, "commandId", "commandName", "error": "Unknown error"}`: N ≥ 0 is a running ticket (1, 2, 3…), not a
status, and the error text comes with successes; `wait.cgi` gives the command's result. So `all.cgi` is a cost once per
connection, never per change.

**The capture** (`captures/arri/20261029-*`; gitignored, since it holds ARRI's page and the
venue's Wi-Fi names): every variable and command with ranges and enums, ARRI's page and script (first session, no
card); REC, playback, every control written and put back (`exercise.jsonl`) and the page driven by hand through the
proxy, format changes included (12:40); Tiles' own backend through REC, playback and every control (13:24, 13:35);
full reads in every state and in each format and codec below (`sessions/`, `20261029-modes/`), and the update stream
whole from 13:35. `camctl arri --from <dir>` reads a capture as the app would.

Twice the camera's `.cgi` side stopped answering (ping and `webremote.html` still fine) until a power cycle: 12:05,
and 13:29, shortly after an `update.cgi?id=5` for a session it hadn't handed out yet. The guess, not proven: requests
it never finishes (an id it didn't issue; a client macOS cut off mid-request) tie up its web server. Never ask for an
id the camera didn't give; run capture tools in the foreground over ssh.

| Control | The Mini's variables (verified) | What it allows (camera, and ARRI) | Tiles |
|---|---|---|---|
| Model, firmware | `SystemCameraType` int (the page script: 1 AMIRA, 2 ALEXA Mini); `SystemSWMajor` / `Minor` / `Patch` | | "ALEXA Mini", "SUP 6.1.2" (the page script's cache key) |
| REC | `MajorState` {DELETE, ERASE, IDLE, PLAY, PREREC, REC, SHUTDOWN, STBY, UPDATE}: IDLE with no card, STBY with one; `RecordingIsPossible` (false even when ready) | `RecordingStart` / `RecordingStop`, empty `set`: a 6 s clip, A001C051_261029_R2QB.mov | as built. The STBY → REC transition itself wasn't seen live (the watch was down for that take) |
| EI | `ExposureIndex` (enum), `ExposureIndexSwitchPos1–3` | 160 … 1280 … 2560, 3200, 14 steps, base 800 (p. 40) | as built |
| ND | `NDFilterPosition`, `…Effective` | "ND  -", "ND 0.6", "ND 1.2", "ND 2.1" (p. 31) | as built |
| Shutter | `ShutterNominal` 5…356, `ShutterNominalMin/Max`, `ShutterTable`; `ExposureTimeNominal` 24…8000 (1/x s), `ExposureTimeTable`; `ExposurePreferenceIsAngle` | locked in REC (p. 37) | the angle list is the camera's `ShutterTable` |
| White balance | `WBCurrentKelvin` 2000…11000, `WBCurrentColorComp` −16…16; `WBTable` (its presets, "Auto WB" first); `WBTrackingIsEnabled`; command `AutoWB` | 10 K steps (p. 40) | as built; AWB is the WB preset tile's "AWB", running the page's `_4da_Ua3pEeSjhp9JjGKhGQ` (build 70, never on the camera) |
| Sensor fps | `FPSNominal` 0.75…50 in 4:3 2.8K, `FPSEffective`, `FPSMin`, `FPSMaxSensor`, `FPSMaxCodec`, `CardAMaxFPS`, `FPSLimitedDueToDenoise`, `FPSTable` | the table below; locked in REC | the rate list is the camera's `FPSTable` |
| Project rate | `ProjectRate` {23.976p … 60p}, `ProjectRateFloat` | | as built |
| Sensor format, codec | `SensorFormat` (+`SensorFormatPrepare`), `RecCodecType` (+`RecCodecTypePrepare`) | the page: `call.cgi` `SensorFormatPrep` `_GnbMUFfSEeWK7Pu_oST6Ew` `{SensorFormatPrepare: n}` (codec: `MediaCodecPrep` `_CAhSoFfSEeWK7Pu_oST6Ew` `{RecCodecTypePrepare: n}`); the camera answers in `PrepareCommandFWWillReload`, `…SensorFPSMax` (30 for ARRIRAW Open Gate, 50 for 4:3 2.8K ProRes), `…TargetValueCodec/Resolution`; ~2 s later `set.cgi {SensorFormat: n}` → `SystemSoftwareIsRestarting`, back in 10–17 s on a new session. All five changes tried reloaded | the same two steps, behind the restart confirmation a VENICE's choices have |
| Look | `LookActiveSlot` and `Look1_Filename` … `Look3_Filename`; `LooksInstalledTable`; commands `LookLoad`, `LookLoadByName` | | the active slot's file name; switching not wired |
| Look per output | `SDI1PathProcessing`, `SDI2PathProcessing`, `EVFMonitorPathProcessing` {Log C, Look, ALEXA Classic 709}; `SDI1Processing` {Clean, Processed}; `SDI2IsSDI1Clone` | SDI 2 (Clean here) offers only Look | the LUT switch per output. `SDI1Processing` / `SDI2Processing` (the menu's SDI 1 / SDI 2 image: Clean "identical to the images that the camera records internally… no overlays… no surround view", Processed; SUP 6.1 manual p. 91, MENU > Monitoring > SDI) are each SDI's Clean Feed switch. Only one SDI can be Processed unless SDI 2 clones SDI 1; SDI 2's Processed choice is then unselectable, so its switch grays. While `SDI2IsSDI1Clone` is on, Monitoring Options shows SDI 2 following SDI 1 with its overlays grayed; a "Same as SDI 1" switch at the top of SDI 2's section turns the clone off so SDI 2's clean feed can be set on its own. |
| Overlays | `SDIFramelinesAreOn`, `SDIExposureToolIsOn` + `SDIExposureTool` {Zebra, False Color}, `SDIPeakingIsOn`, `SDIStatusInfo1IsOn` / `2IsOn` (one set for both SDIs); the same for `EVF…` and `Monitor…` (`MonitorFramelineIsOn`) | | outputs SDI 1, SDI 2, EVF, MON. False color and zebra both switch the exposure tool, whichever it is set to |
| De-squeeze | `LensSqueezeFactor` {1.0, 1.3, 2.0}; `EVFMonitorAnamorphicDesqueezeIsActive`, `SDIAnamorphicDesqueezeIsActive` | (p. 84) | the factor |
| Test image | per output: `EVF…`, `Monitor…`, `SDI1…`, `SDI2TestImageIsActive` | STBY only; the menu's Color bars and the COLOR_BAR user button switch `SDI1TestImageIsActive` alone (SMPTE bars on the SDI outputs, REC turns them off: p. 93) | Color Bars is `SDI1TestImageIsActive`, grayed while rolling |
| Image flip | `SensorImageFlip` {Off, V, H, V+H} (tokens OFF, V_FLIP, H_FLOP, VH_FLIPFLOP) | reaches the recording (p. 101) | Sensor Flip: on writes V+H, any flip reads on |
| Timecode | `TimecodeHours`, `TimecodeMinutes`, `TimecodeSeconds`: no frames; `TCMode`, `TCIsFreeRun(_Effective)`, `TCOffset` −20…20; command `TCSet` | | whole seconds, frames counted locally in free run |
| Reel, clip | `CameraIndex` A–Z, `CameraID` "2QB" with `CameraIDPrefix` R, `ReelCountCardA/B`, `ReelCountNext` 1…999, `ClipNextCardA/B` | no clip-name variable | letter and reel |
| Lens | `LDSIrisFullStops` {-, T 0.7 … T 256, near close, closed} + `LDSIrisSubStops` / `LDSIrisSubStopsScaleInt` (10, 3 or 4); `LDSIrisValue` (the page divides by 1000; unit unconfirmed), `LDSFocusValueMetric` (mm), `LDSZoomValue` (mm × 1000), `LensName` | | iris from the full stop and its fraction. Untested: no lens |
| Battery | `Bat2LevelVolt` is the Mini's supply (14.8 V; the page shows Bat1 only on an AMIRA, or when it's ≥ 1 V higher); `Bat1LevelPercent` with `Bat1CapacityState` {NotPresent, NoCapacity, CapacityValid} | | percent only when CapacityValid; volts always, as the display shows them: Bat2, or Bat1 when it's ≥ 1 V higher (the page script's `_Bat1_2BDisplayed`). The tile requires CapacityValid to show percent; without it, the tile previously showed no data at all. |
| Media | `CardAStatus` / `CardBStatus` {---, …, Ready, FULL, …}, `CardBIsSelected`, `CardA/BCapacityRemain_Raw`, `…RemainPercent`, `…CapacityTotalGB`, `…ModelInfo`, `…MaxFPS`; `MediumErase` exists | the CFast slot is **card B**. Remaining is seconds: 777 with 50 clips on a 256 GB card in 4:3 2.8K XQ | minutes from the seconds. Tiles has no formatting, by design |
| Playback | `PlaybackMediumActive` {None, Card A, Card B}, `PlaybackClipIndex`, `PlaybackPositionPercent`, `PlaybackSpeed`, `PlaybackSpeedEnum` (10 pause, 11 play, ±2…512×), `PlaybackEndMode`; `ClipTableCardB` rows [frames, s, fps, …, TC h m s f, flags, name] | `PlayBackPrepare` `_EeUkIwIBEeSgptigTra4vQ` `{_TableVersion_Local: ClipTableCardBVersion}` (card A: `_EeUkLAIBEeSgptigTra4vQ`) → PLAY on the last clip; the page's PLAY uses `_KJiR85NJEeOyJ4INPpj7sw` go, `_b08l0Y2NEeOwGJFKci4VTg` stop, `_uRbmACN8EeS4a_A1Spnarw` / `_gv0bISN8EeS4a_A1Spnarw` skip, `_cCCFscHSEeStK8NH8ZPGbQ` end; a clip from the list: `_oNwwcpohEeOTzZd1L8eqnw` `{_BooleanTempVariable_Local: true, _TableVersion_Local: v, _ListIndex_Local: n}`. Skip back first goes to the clip's start | as built; tested through the API and the page. Live is PlayBackEnd, the page's `_cCCF…` (the Mini also lists its LOCK button's `_1cxyMfk0EeaWP7LWENrtWw`, which sorts first), then `GuiMode` NORMAL, as the page's exit: see below |
| Clips (a clip picked from a list) | `PlaybackClipIndex` + 1 of `ClipCountCardA` + `ClipCountCardB` | cued first (`PlayBackPrepare`), then `PlayBackSkipClip` a clip at a time to the one picked, then `PlayBackGo`; a skip that goes the wrong way turns the skips round, since which way the Mini numbers its clips isn't known. The page's own way, a clip from its list (`_oNwwcpohEeOTzZd1L8eqnw` with `_ListIndex_Local`) and the names in `ClipTableCardB`, needs the table's shape from a camera | built, never on one |


**The camera's own screen has a playback mode of its own.** After Live, the Mini's screen can show "No clip selected"
and won't leave until REC, which then rolls. `GuiMode` {NORMAL, OVERLAY_MENU, PLAYBACK, ERASE},
writable, is what the camera's screen shows. A PlayBackPrepare from the API sets it to PLAYBACK along with `MajorState`;
PlayBackEnd puts `MajorState` back to STBY and leaves `GuiMode` at PLAYBACK, so the screen stays on its playback page
("No clip selected", "Hold to exit playback") until PLAY is held on the camera or REC is pressed (its own reaction to
REC sets NORMAL). The page writes `GuiMode` NORMAL itself right after its PlayBackEnd (the proxy, 12:50). In the
capture every API-only end left it there: snapshots 012 and 015, and the 13:24 session, where a REC
cleared it 0.9 s later. Tiles' Live does what the page does, leaves OVERLAY_MENU and ERASE alone, and reads `GuiMode`
PLAYBACK as review, so Live clears a screen an earlier build left. The page script also keys dependency lists by
variable name in the split spelling (`GuiMode:"_aiYR0… …".split(" ")`, and for ten other enums), ahead of the enum's
own list: the catalog passes over lists of page-model ids.

Rolling: `MajorState` 7 → 5 about 0.7 s after `RecordingStart`, with `ClipCountCardB` up by one and the take in the
clip table at once; `ClipActDurationCardB` counts the take's seconds, `CardBCapacityRemain_Raw` counts down. Shutter
and sensor-rate writes mid-take answer `{"result": 1}` and are ignored, with nothing marked read-only; EI, ND, white
balance and angle-or-time change. `all.cgi`'s timecode ran 3 s behind the update stream. Through Tiles' backend
(`camctl arri HOST --rec/--play/--selftest/--resolution`): REC shown in 0.76–1.34 s, stopped in 1.0–1.3 s; each control
confirmed in 0.23–0.5 s; a format change shows the camera stale for 16–17 s, then connected with the new ranges.

Still open: the iris (no LDS lens was there).

## Measured per format and codec (2026-10-29, SanDisk 256 GB CFast in card B)

Every sensor-format change reloaded the camera's software; a codec change within ProRes didn't; ProRes ↔ ARRIRAW
did, and moved the format too (ARRIRAW to Open Gate 3.4K, back to ProRes 4444 XQ to 4K UHD). Shutter 5–356° and
1/24–1/8000 s at 24 fps in all. The card's own limit (`CardBMaxFPS`) is the third cap on the rate.

| Format | Codec | Max fps (camera) | Card's max |
|---|---|---|---|
| 4:3 2.8K | ProRes 4444 XQ / 4444 / 422 HQ / 422 / 422 LT | 50 | 52 / 78 / 118 / 177 / 200 |
| HD | 4444 XQ / 422 HQ | 120 / 200 | 161 |
| S16 HD, 2K, HD Ana., 2.39:1 2K Ana. | 4444 XQ | 120 | 161, 141, 161, 190 |
| 3.2K | 4444 XQ / 422 HQ | 30 / 60 | 57 / 130 |
| 4K UHD | 4444 XQ / 422 HQ | 30 / 60 | 40 / 90 |
| Open Gate 3.4K | ARRIRAW | 30 | 30 (the card then reads FULL, 0 s left) | Writes the camera took but didn't apply: `ExposureTimeNominal` while
the shutter is in angles, and the de-squeeze switches at a 1.0× squeeze. `AutoWB` raises `MessageEventAWB`.

## Maximum sensor frame rate (p. 136)

| Resolution | ProRes 422 LT, 422, 422 HQ, 4444 | ProRes 4444 XQ | ARRIRAW |
|---|---|---|---|
| S16 HD, HD, 2K | 200 | 120 | |
| HD Ana., 2.39:1 2K Ana. (4:3 license) | 120 | 120 | |
| 3.2K, 4K UHD | 60 | 30 | |
| 4:3 2.8K (4:3 license) | 50 | 50 | |
| 16:9 2.8K (ARRIRAW license) | | | 48 |
| Open Gate 3.4K (both licenses) | | | 30 |

Tiles' frame-rate tile offers its usual rates inside the camera's `min`…`max`, so these show as the tile's longest list
per mode.

## Network (pp. 108–110, 127–129)

- The Web Remote has no login: `http://mini-<5-digit serial>.local` or the IP; ARRI supports Chrome and Firefox.
  INFO > Network info shows the Wi-Fi IP, the LAN IP and the URL.
- Wi-Fi is on by default, as an access point: the camera is 192.168.153.1, password `arriarri`. The SSID and the band
  aren't documented (2.4 GHz is likely).
- Wi-Fi client mode joins WPA2 or open networks (MENU > System > Network / WiFi > WiFi mode, then WiFi network), or
  scans a QR code of `WIFI:S:<ssid>;T:WPA2;P:<password>;;` held in front of the lens.
- Ethernet: the 10-pin LEMO ETH socket and ARRI's KC 153-S cable (K2.72021.0). LAN IP mode DHCP (the default) or
  Static (192.168.0.100/24 by default).

## On the day

1. Network. The quickest is a laptop on the camera's Wi-Fi (192.168.153.1, `arriarri`). That network has no internet,
   so keep the laptop online through iPhone USB or Ethernet, above Wi-Fi in the service order; otherwise SSH from the build Mac
   drops for as long as it's joined. If not: the camera in Wi-Fi client mode on the phone's hotspot (Maximize
   Compatibility, for 2.4 GHz), laptop on the same hotspot.
2. `scripts/arri/arri.py go 192.168.153.1`. Read-only, seconds: every variable with its
   range and choices, the enum labels, the size of `all.cgi` on the wire, the long poll's answer, and what Tiles reads
   from it.
3. `arri.py watch 192.168.153.1 --detach`, then `arri.py proxy 192.168.153.1 --detach` and Chrome on
   http://localhost:8081/. MAIN mirrors the camera's screen and menus: walk the menu once, slowly. Then PLAY, REC
   INFO's REC, and each USER button.
4. Ranges per mode, one change at a time on the camera, each followed by `arri.py note "<what changed>"`, which now
   also saves `all.cgi` and prints any range, choice or read-only change:
   as found; ProRes 4444 XQ; 3.2K; 4K UHD; 4:3 2.8K and ARRIRAW, if licensed; Noise Reduction on in HD; shutter in
   time; 60 fps and its shutter range; mid-take (recording); playback. `arri.py ranges` then writes the table
   (`ranges.md`). Wait out any software reload before the note.
5. Tiles (TestFlight build or the iPhone) → Add Camera → ARRI → the address. Every tile. Check the lens iris
   and the media time against the camera's own display.
6. Before the camera goes: `arri.py diff` (what to put back), `arri.py stop`, and the capture copied to the build Mac.
