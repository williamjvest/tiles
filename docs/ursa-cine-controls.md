# URSA Cine 12K LF (and 17K 65, Immersive): what to expect before the first test

Blackmagic lists the URSA Cine 12K LF, 17K 65 and Immersive for the same Camera Control REST API the PYXIS speaks
(Blackmagic's "REST API for Blackmagic Cameras" document). Tiles connects to them as it does to a PYXIS: HTTPS,
with the camera's login if one is set. Turn on the web media manager in the camera's network access settings, as
for the PYXIS. Nothing here has been on a real URSA Cine.

What should work as on the PYXIS: REC, ISO, shutter, white balance and tint, iris (with an electronic lens), frame
rate and off-speed, codec and resolution, dynamic range, the monitoring overlays per output (whatever outputs the
camera reports), playback, slate, battery, media, and live view through the camera's livestream if the API offers one there (Tiles
asks; the document doesn't say which cameras have it).

Different:

- **ND.** Clear, 2, 4 and 6 stops on the 12K LF; the Immersive adds 8 (Blackmagic's tech specs). The tile lists the
  camera's own stops as ND numbers, 0.3 a stop (Clear, 0.6, 1.2, 1.8), and sends stops. Fixed 2026-10-15: the stops
  list was read from a key the API doesn't send (`supportedNDFilters`; it's `supportedStops`), so the tile would have
  offered a made-up ND 8–64 that the camera refuses.
- **Status text, Status Text For, De-squeeze, LUT picker.** These go through presets, and Tiles only does that on the
  model whose presets were taken apart, a PYXIS (`isPYXIS` and `presetsKnown` in BlackmagicCameraBackend). On an URSA
  Cine those tiles stay off until the check below.
- **Native ISO.** Not marked: Blackmagic's spec page for the URSA Cine doesn't give one (checked 2026-10-15).

## On the day

1. Connect from Tiles; note the model string and software version (`camctl bm <ip> --https state`).
2. ND: each stop from the tile, and from the camera's own button (the tile should follow).
3. Outputs: which displays the API reports, and the overlays on each.
4. Presets: run `scripts/cset/csetprobe.py <ip>` (it has no login option yet: turn the camera's login off for it, or
   add one). If every check passes, let the model through `isPYXIS`'s check (and its version into `checkedSoftware`),
   and the preset tiles open up.
5. Write `docs/ursa-cine-controls.md` up as the verified controls doc, in the style of `docs/fx3-controls.md`.
