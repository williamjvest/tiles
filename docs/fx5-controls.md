# FX5 Control Map

Live camera: ILME-FX5, firmware 1.00 ("Pro Camera Remote Control" 1.00, PTP 3.00), on Wi-Fi at an example address
(192.0.2.254 in the fixtures) in Station Mode, Access Authentication (SSH: OpenSSH 8.2p1, `X_SSH_Support` Enable,
`X_SSH_QRSetupSupport` Enable). A 24 mm autofocus E-mount lens. Sony's help guide:
https://helpguide.sony.net/ilc/2630/v1/en/

Captures: `fixtures/fx5-*-2026-11-14.*`. The mapping is pinned by `Tests/SonyPTPTests/FX5MappingTests.swift` (as
found in Custom, and in Flexible ISO), and Review by the FX5 cases in `PlaybackTests.swift` (the fake camera's `takes`).

It lists the FX6's own codes, so Tiles reads it as one (`SonyProBody`: shooting mode, gain and base sensitivity, the
LUT outputs, proxy, AGC, auto iris, the lens drives, assignable buttons), and the FX6's playback buttons.

## Getting it to answer

- **USB first (USB-C, USB Cnct Mode = USB Remote, PID 0x0FD1):** one session opened and read the camera,
  then camctl exited without closing it (fixed: camctl's connect, dump and set now close their session). After that
  every command timed out on the bulk-out pipe (`0xe0004051`): through the PTP device reset, a replug and a power
  cycle. Ardia held an `AppleUSBHostDeviceUserClient` on the camera at the time, a possible cause. Not understood
  yet; the network worked, so USB waits for another session.
- **Network:** Camera Remote Control under Network → Wireless LAN was **grayed out while USB Cnct Mode was USB
  Remote**. With USB Cnct Mode (PORT1) Off it enabled, and the camera answered on 22 (SSH) and 64321
  (`DigitalImagingDesc.xml`). Sony's menu: Network → Wireless LAN → Setting (Access Point 2.4/5 GHz, Station Mode,
  Off), Camera Remote Control (station mode only), Wired LAN → Camera Remote Control, USB Tethering → Camera Remote
  Control; Technical → USB → USB Cnct Mode (PORT1) {Off, USB Remote, USB Tethering}, (PORT2) {Off, USB Timecode, USB
  Remote}. Help guide: https://helpguide.sony.net/ilc/2630/v1/en/contents/network.html
- About 50 minutes in, on 9% battery, it went off the network (22 and 64321 closed). With a charged battery it was
  back half an hour later, and REC, Review, the LUT outputs and the assignable press were tried then.
- **Bit rate (2026-11-16):** not reported: no Recording Setting (Movie) `0xD242`, no Video Rec Format Bitrate
  `0xE067`, no [Quality] (`0xE0B5`). Tiles works it out from the project rate, codec and video format by the Help
  Guide's table ([Video Format] / [Quality] / [Bit Rate] Settings), read only, as a range where Quality changes it
  (`FX5BitRate`). As found: 100 Mbps.
- **Found on the network (2026-11-15):** it answers an SSDP M-SEARCH for `urn:schemas-sony-com:service:DigitalImaging:1`
  sent to 239.255.255.250:1900 with `LOCATION: http://192.0.2.254:64321/dd.xml`, but not reliably: 0.8 s to 2.2 s
  later whatever the MX, and of three searches a few seconds apart it answered the first only. It doesn't answer one
  sent to its own address. The sweep of the network on 64321 is what finds it every time. Its `dd.xml` has no friendlyName (modelName "SonyImagingDevice"; the
  UDN ends in its MAC); `DigitalImagingDesc.xml` names it: `X_ModelName` ILME-FX5, `X_SSH_Support` Enable. Add Camera
  and `camctl find` list it as "FX5 · 192.0.2.254 · ILME-FX5 · Access Authentication" (`SonyDiscovery`).

## What it lists

251 property codes and 23 control codes (the FX6: 192 and 12).

- **Not on the FX5:** ND, which has no filter (`0xD018`–`0xD01B`, `0xD073`, `0xD14E`/`0xD14F`), ECS
  (`0xE006`–`0xE00A`), DC volts `0xD03E`.
- **New against the FX6:**
  - HDMI info display `0xD079`, as the FX3's.
  - Tally lamps `0xE0D2`/`0xE0D3` and CALL `0xE0E1`, as the BURANO's.
  - Camera buttons `0xD208`/`0xD209`/`0xD20C` with controls `0xD309`/`0xD30A`. They offer ENTER, the multi-selector,
    0x0C–0x0F, Home, Clips and Cancel/Back.
  - OSD image mode `0xD207`. **Don't write it** without the session to lose: it killed a BURANO's.
  - Playback clip name, number and total `0xD09D`–`0xD09F`. Disabled on the live picture, with an empty name and 0
    of 0, which the Playback tile showed as " · 0 of 0" until the mapper read them only while enabled.
  - Battery level indicator `0xD20E` and overheating `0xD251`.
  - Control `0xD2E2`, which on Sony's list formats a card: camctl's raw write refuses it, as on the FX6.
  - About 70 more not yet named (`fixtures/fx5-dump-2026-11-14.txt`).

## Controls

Every ✓ went through the app's own path (`camctl keys` with `app:`, `iso:`, `angle:`, `speed:` and `cmd:` steps),
was read back, then put back. The camera was left as found: Custom, ISO 5000 on High, 180°, S&Q on at 24, XAVC S-L
422, proxy off.

| Control | Codes | As found | Tiles | Notes |
|---|---|---|---|---|
| REC | `0xD2C8` hold | Idle | ✓ | Through the app's path: recording within about a second, the settings read-only while it rolls, idle again on stop and the next clip name a step on. Four 3 s test takes were recorded (A001C001–C004) for Review. |
| Shooting mode | `0xE000` | Custom | ✓ | Custom, Flexible ISO, Cine EI Quick, Cine EI, as the FX6. Each and back. Cine EI: EI 800 on the 800 base, EI 1600 and back, base 12800 (EI 12800) and back, the LUT outputs off as found, on and off. Cine EI Quick: the base read-only. |
| ISO | `0xD21E` | 5000 | ✓ | Custom works in ISO on this camera (Gain Unit `0xD01D` 0x02, display-only), so no Gain tile: 5000–409600 on High. 6400 and back. Flexible ISO: 800–25600 on the 800 base. |
| Base sensitivity (Custom) | `0xD021` | High | ✓ | **Three**, as the menu names them: Low 0x02 (ISO 320), Mid 0x03 (1600), High 0x01 (5000), each read back with the ISO it gave. The help guide also has Low (Dual Gain), which this camera didn't list. In the ISO tile, where an FX6's is in the Gain tile. |
| Base ISO (Flexible ISO) | `0xD020` + display list 0x08 | 800 | ✓ | **Three**: ISO 800 (0x02), 4000 (0x03), 12800 (0x01). Each set and read back. The guide also has ISO 800 (Dual Gain). |
| AGC | `0xD01C` | Manual | ✓ | On makes the ISO read-only; off again. |
| Shutter | `0xD010`, `0xD00E`, `0xD016` | Angle 180° | ✓ | 90° and back; speed mode, 1/50, back to angle. Speed read-only in angle mode. |
| White balance | `0xD20F`, `0xD210`, presets | 3200 K, tint 0 | ✓ | Kelvin 5600 and back, tint 10 and back, the 5600K preset and back. Tiles' six presets, Auto and AWB. |
| Iris | `0x5007` | f/2.8 | ✓ | 19 stops f/2.8–22; f/4 and back. Auto iris `0xD001` display-only here. |
| LUT (base look) | `0xD03C` + display list 0x03 | S-Cinetone | ✓ | S-Cinetone, ITU709, 709tone; user slots empty. ITU709 and back. |
| LUT per output | `0xD2AA`–`0xD2AC`, `0xD2A9` | — in Custom | ✓ | Three settings, all disabled in Custom. In Flexible ISO all three off: 1 HDMI, 2 proxy and live view, 3 LCD and VF. Tiles names them HDMI, Proxy/Live View and LCD/VF (the menu's LUT On/Off: HDMI, Proxy/Remote Live View, LCD Monitor/VF). None reaches the recording, so no LUT-in-recording tile. The LUT tile's Outputs on and off, and Proxy/Live View alone off, each read back. **While Proxy/Live View's LUT is on, LCD/VF's is on and display-only** (`0xD2AC` enabled 0x02): Tiles shows it grayed, and turns Proxy/Live View off first. |
| Codec, resolution | `0xD241`, `0xD024` | XAVC S-L 422, 3840x2160 | ✓ | Settable, unlike the FX6's: five codecs; S-I 422 and back. **Changing the codec turned S&Q off**, and it stayed off on the way back: S&Q on again by hand. |
| Project frame rate | `0xD286` | 23.98 | ✗ camera | Settable by its flags, but both its lists hold only the rate it's on, with S&Q on or off, in Custom and Flexible ISO. Written 29.97 anyway through the app's path: the camera answered OK and stayed on 23.98. The BURANO lists only its rate too; the FX6 lists six and takes none. Sony's guide: [Project] → [Rec Format] → [Project Frame Rate] (119.88 … 23.98), and "the unit may reboot automatically after switching". Set it on the body; S&Q (off-speed, up to 120) works from Tiles. Sony's own Monitor & Control can't either: connected to an FX5, it changes only the variable (S&Q) rate, though its function table marks [Frame rate] changeable on an FX5. |
| S&Q | `0xD051`, `0xD052` | On, 24 | ✓ | Off and on. Rates up to 120. |
| Desqueeze | `0xE0A4` | Off | ✓ | 1.3x and back. |
| Color gamut | `0xE001` | S-Gamut3.Cine | ✓ | Read-only in Custom, settable in Flexible ISO (S-Gamut3.Cine, S-Gamut3). |
| Tally | `0xE0D2`/`0xE0D3` | Off | ✓ | Red and back. |
| CALL | `0xE0E1` | Off | ✓ | On and off. |
| HDMI info | `0xD079` | On | ✓ | Off and on (raw write of the HDMI Info tile's code). |
| Proxy recording | `0xE00D`, `0xE011` | Off | ✓ | On: Standby; off again. |
| Focus | `0xD2EF`, `0xE089`, `0xD004` | — | ✓ | ±1 drove it and the position moved; max speed 8. No power zoom. On AF it drives only with AF Assist on (it holds the drive until AF Assist goes off); with it off Focus Speed Range `0xD008` goes display-only and a drive does nothing, so the Focus tile grays (11/14). |
| AF / MF | `0xD007`, status `0xE044` | AF (AF Operation) | ✓ | No Focus Mode `0x500A` on this body: Focus Mode Setting, 0x01 Automatic, 0x02 Manual, settable; "AF" \| "MF" on the AF / MF tile and beside the Autofocus tile's push. Focus Mode status says what focus is doing: 0x01 Focus Hold, 0x02 MF, 0x03 AF, and a 0x04 the guide doesn't name. Checked 11/14 through the app's path: MF and back to AF, Focus Mode status following (MF Operation, AF Operation) and Auto Focus Hold `0xD091` display-only in MF. |
| Push AF | `0xD05E` | Up | ✓ | UINT16 Down 0x02, Up 0x01, as an assignable press: the Autofocus tile holds it 1.2 s and lets go, an Up it doesn't answer sent again and on the next session. Only while focus is manual (status MF): with AF on, a cinema body's push holds focus instead. Allowed during a take. Checked 11/14: in MF with the lens driven to infinity (0.976), one push brought it back to the subject at 0.6 m (0.752) in 1.4 s; with AF on, refused. |
| SteadyShot | `0xD0DA` | Standard | ✓ | Off, Standard, Active, and 0x04 (the guide's Hybrid), which the FX5's menu calls Dynamic Active. Active, Off and back to Standard, each read back (Off makes `0xD192` display-only). |
| Imager Mode | `0xE131` | FF 5K 16:9 | ✓ | UINT64: size in bits 0–7 (FF, FFc, S35, S35c), resolution ×100 in 8–23, aspect in 24–31 (0x05 is 17:9, newer than the guide). Five offered: FF 5K 17:9 and 16:9, FFc 4.5K 17:9 and 16:9, S35 3.2K 16:9. Not during a take: it can change the resolution. FFc 4.5K 17:9 to FF 5K 17:9 and back, read back; with the 4096x2160 format only the two 17:9 modes were listed. |
| AF settings | `0xD060`, `0xD22C`, `0xD061`, `0xD062`, `0xE084` | Human Priority AF, Wide, 5, 5, On | ✓ | The AF Settings window (Add Tile). Subject Recognition AF lists six: the reference's 0x01 Off, 0x02 Only AF, 0x03 Priority AF (Human Only AF, Human Priority AF in its menu) and 0x04–0x06, named in its menu's order (Animal/Bird Prio. AF, Animal Priority AF, Bird Priority AF): check them on the camera. Focus Area Wide, Zone, Flexible Spot (`0x0105`); Transition Speed 1–7, Subj. Shift Sens. 1–5; AF Assist on or off. Not the spot's position (`0xE079`) or Auto Focus Hold (`0xD091`). Each set and put back on 11/14: Human Only AF, Bird Priority AF; Zone, Flexible Spot; transition 3; shift 2; AF Assist off. Its display list 0x15 names the six values exactly as above, and Tiles now takes its names from it. |
| Camera buttons | `0xD309`/`0xD30A` | — | ✓ pressed | MENU and Back answered OK; what the camera showed wasn't seen. |
| Assignable buttons | `0xE014`… | 1 Iris, 2 White Balance, 3 Base ISO/Sens., 4 False Color, 5 LCD/VF Mode, 6 Rec, lens Focus Hold | ✓ | The FX5 numbers the functions differently from the FX6 (display list 0x0B: S&Q Motion 0x39, Rec Review 0x4F, Last Clip 0x50, against 0x31, 0x42, 0x43). Pressable only where the number and name both match a checked one: Base ISO/Sens. (0x03 on both), pressed three times in Custom: High → Low → Mid → High (ISO 5000, 320, 1600, 5000); and False Color (0x6B), below. Last Clip is refused by name too. |
| False Color | button 4 (`0xE017` = 0x6B "False Colo"), press `0xE02C`, light `0xE038` | Off | ✓ | Only a button function on this body. The False Color tile presses the button set to it, only to change it, and reads its light: on, the three LUT outputs go display-only (the LCD/VF LUT shows off); off, back as they were. Whichever button has it, the lens's too: it reads the buttons again before each press, so one moved at the camera is found, and the button it left is never pressed for it. With no button set to it the tile grays and says "Assign a button"; in another language (the name is matched in English) there's no False Color tile. |
| Battery | `0xD20E`… | 10% | ✓ | Percent. |
| Media, clip | `0xD24A`, `0xE00B` | 1133 min, A001C001 | ✓ | |
| Playback | `0xE021`–`0xE028`, `0xD0BC`, `0xD09E`/`0xD09F` | Live | ✓ fixed | Below. |
| Live view | `0xD0AC`–`0xD2C0`, `0x9241`/`0x9242`, `0xD307` | — | built, off in the app, never on the camera | No Live View Status (`0xD221`) or LiveViewURL at all, as on the FX6: no picture over Camera Remote. Through its stream instead: below. |
| File transfer | menu only | — | — | Network → File Transfer → Server Settings 1–3: FTP or FTPES servers for uploading clips (Sony's guide, `transfer_prep.html`). None of the codes named so far; possibly among the unnamed ones, as the VENICE has its own. |

**Live view through its stream** (2026-11-15, from the reference and Sony's help guide, never on the camera; off in the
app, `SonyBackendConfig.streamLiveView`; on by default for camctl). The FX5
streams RTMP/RTMPS and SRT (Network → Stream: Setting On/Off, Destination Select, RTMP/RTMPS 1–3 and SRT-Caller 1–3,
each with its resolution and bit rate; H.264 only on RTMP), and the session can set all of it: the destinations with
SDIO_GetStreamSettingList `0x9241` / SetStreamSettingList `0x9242` (param 1 the Video Stream number, 1–6; the list's
URL, key and their lengths with their nulls), the per-destination settings for the one Video Stream Select `0xD0AC`
picks (resolution `0xD0AE` UINT32 width << 16 | height, max bit rate `0xD2C0` UINT64 kbps, name `0xD2BF`), which one
streams (Target Streaming Destination Select `0xD2BE`), and Start / Stop (the Stream button control `0xD307`: Down
starts, Up stops, absolute). Its 11/14 list: Stream Status `0xD119` Inactive (Setting off), StreamSettingList
Operation Enable Status `0xD1CC` on, Video Stream Movie Rec Permission `0xD11A` Permitted (it records while it
streams). So Tiles' live view on an FX5 sets RTMP 3 (or 2, or 1: the first that's empty or Tiles') to
`rtmp://<this device>:<port>/live`, key `tiles`, named "Tiles", 720p at the lowest rate the camera allows (1.5 Mbps at
23.98; 1080p and 4 Mbps for High), picks it, starts the stream and receives it as it does a PYXIS's
(`RTMPLiveStream`); stopping it presses Stop and picks the camera's own destination again. Streaming must be on:
MENU → Network → Stream → Setting → On (Tiles says so when it reads Inactive). To check on the camera: that a set of
one destination is what it wants (else Tiles sends the whole list), the latency, and that it records as it streams.
`camctl liveview <host> 10 frame.jpg` runs it from a Mac.

**Playback** (`fixtures/fx5-review-2026-11-14.jsonl`: Review from 1 of 3; `fx5-rec-review-2026-11-14.jsonl`: a take,
then Review 1.5 s after the cut). The FX6's buttons, all enabled
on the live picture, and the FX6's way in: Prev opens Playback paused (within 0.4 s), Play plays, Play Pause pauses,
Stop goes back to the live picture (0.5 s). Play on the live picture opened it once and did nothing another time, as
the FX6's "only sometimes".

What Prev opens depends on where Playback last was, and it was never the last take straight after a cut:

| Before Review | Prev opened |
|---|---|
| A new take (C003, 1.5 s after the cut) | 2 of 3 (C002) |
| C002 played to its end, then Live | 2 of 3 (C002, its start) |
| C002 at its start, then Live | 1 of 3 (C001) |
| A new take (C004, 1.5 s after the cut) | 3 of 4 (C003) |

So it steps back from the last take, or from where Playback was. Unlike the FX6, the FX5 says which take is open and
how many there are: Playback Contents Number `0xD09E` and Total `0xD09F`, enabled only in Playback (name `0xD09D`
follows a moment later). Review now opens with Prev, presses Next until the number is the total (each Next once the
number has moved), then Play: 1 of 3 → 3 of 3 in 1.7 s, and 1.5 s after a cut 3 of 4 → 4 of 4, the new take,
playing in 1.4 s.

Left far back, after the fixes (six takes on the card): Playback left on take 3, then Live; Review's
Prev opened 2 of 6, four Nexts to 6 of 6, playing in 2.4 s.

Just after the cut, before that fix, one Prev 3.7 s after stopping did nothing and the camera stayed live. Review
now presses Prev again after 3 s still live, twice at most: never sooner, as a Prev in Playback steps to the take
before. Not seen again, so the second press hasn't been needed on the camera yet.

**The Clips window** (2026-11-14) lists the takes by number once the camera is in Playback (it gives the number and
total only there, and no names but the open take's), and goes to the one tapped the way Review goes to the last: Prev
in from the live picture, then Next or Prev a take at a time by the number it gives, then Play (`ClipStepper`; one
press the camera ignores is allowed, as a Prev mid-take may go to the take's start first). Built on Review's measured
presses, never run on the camera: a pick far from the open take should take about 0.4 s a take.

