# Blackmagic cameras over Bluetooth

For the cameras Blackmagic's REST API doesn't reach: the URSA Mini Pro 12K (and G2), and the Pocket Cinema Cameras.
The PYXIS and URSA Cine take it too ("Bluetooth control" in Blackmagic's tech specs), which makes the PYXIS the first
camera to test it on. Module `BlackmagicBLE`; built from Blackmagic's published Camera Control document. Not yet run
against a camera.

## How it connects

- **Add Camera → Over Bluetooth → Look for Blackmagic Cameras.** The list is the cameras advertising Blackmagic's camera
  service (`291D567A-…`). The camera needs Bluetooth on in its setup menu. Picking one saves the camera as
  `bt:<identifier>`: CoreBluetooth's identifier for it on this device, so each phone, iPad or Mac adds it separately.
- **Bonding:** the first subscription to an encrypted characteristic makes the camera show a 6-digit code and the
  system ask for it. Until it's typed the camera shows "Type the camera's code". After that the system remembers the bond.
- **Range** is Bluetooth's: the same room, not HaLow distances.
- **Status:** a camera that reports itself off (status bit 0x01 clear) fails with "The camera is off" and reconnects
  when it's switched on. The link has no timeout: a camera out of range is joined when it comes back.

## What's mapped

The camera reports values, never menus, so option lists are the usual ones with the camera's value always among them,
and the camera clamps what it can't take. Nothing shows until the camera has reported it.

| Tile | Parameter | Notes |
|---|---|---|
| REC | 10.1 transport mode | 2 records, 0 is preview. Never optimistic: waits for the camera's report, 3 s timeout, no resend |
| ISO | 1.14 | |
| Shutter | 1.11 angle ×100, 1.12 speed 1/x | whichever the camera last reported; no measurement switch in the protocol |
| White balance | 1.2 Kelvin + tint, 1.3 auto | Auto measures; the camera's report is the value |
| Iris | 0.2 aperture value | third stops, exact (f/5.6 is AV 5) |
| ND | 1.16 stops + display mode | Clear / 0.6 / 1.2 / 1.8, sent as stops in the camera's own display mode |
| Frame rate, off-speed | 1.9 recording format | sent whole; 23.98 is 24 with the M-rate flag |
| Resolution | 1.9 width × height | read-only |
| Codec | 10.0 | BRAW Q0–12:1, ProRes, CinemaDNG |
| Dynamic range | 1.7 | Film, Video, Extended Video |
| LUT | 1.15 selected + enabled | None, Custom, Film to Video, Film to Extended Video |
| Overlays | 4.1 zebra / focus assist / false color, 3.0 status / guides / clean feed | as one output, "All outputs": the protocol switches them for a set of displays at once |
| Zebra level, frame guides | 4.2, 3.3 | |
| Timecode | the Timecode characteristic, BCD | |

Not in the protocol: battery, media remaining, clip names, base ISO, shutter measurement, playback state, live view.

## To check on the first camera

1. Pairing on iPhone/iPad and on the Mac: the prompt appears, the code works, a second connection needs no code.
2. **Does the camera send its settings when the link opens?** Tiles waits for the first message (or "camera ready")
   before it calls the camera connected, and REC stays disabled until a transport mode (10.1) has come in. If one
   never comes unasked, try asking with an offset of 0 (operation 1, zero data): it changes nothing and may make the
   camera report the value.
3. **Does it echo a change made over Bluetooth?** Tiles shows a sent value at once and lets the camera's report
   overwrite it; with no echo, a value the camera clamped would show wrong until something else reports it.
4. Timecode's byte order (read little-endian).
5. Which shutter parameter it reports, and what 3.0 / 4.1 reports look like (flags, then displays?).
6. REC from Tiles and from the camera's button; a take started at the camera shows its runtime.
7. On the PYXIS, the same values over Bluetooth as over REST (camctl shows the REST side).
