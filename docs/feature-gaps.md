# Feature gaps, camera by camera

What each camera lets a remote do that Tiles doesn't yet, what the camera itself won't allow, and what's built but
has never been on a real camera. Update it when a gap
closes or a camera session proves something. The details live in each camera's own doc (`*-controls.md`,
`venice.md`, `arri.md`).

## ALEXA Mini (`alexa-mini-controls.md`)

The camera offers it, Tiles doesn't:

- **Switching looks.** The camera holds 3 loaded looks (`LookActiveSlot`, `Look1_Filename` to `Look3_Filename`, and
  the commands `LookLoad` / `LookLoadByName`). Tiles shows the active one but can't switch.
- **Timecode settings.**
  - Free Run or Rec Run (`TCIsFreeRun`).
  - The mode (`TCMode`: Regen, Preset, Jam Sync), with `TCRegenSource` and `TCConnectorMode`.
  - Drop-frame (`TCCountModeIsDrop`).
  - An offset of ±20 frames (`TCOffset`).
- **Setting a timecode value.** `TCSet` exists under two ids, but nothing the 10/29 capture shows used it, so the
  value it takes is unknown. It needs one camera session.
  - The idea: a Timecode tile that sets every camera to time of day, free run, from one tap. Over the network that's
    within a few frames: fine for matching and logging, not for sync sound.
- **Test image per output.** The EVF, Monitor and SDI 2 have their own. The camera's own Color bars, and Tiles', use
  SDI 1's.

Built, never on a camera:

- The iris read from an LDS lens.
- Live (writes `GuiMode` NORMAL).
- Clean Feed.
- Color Bars and Sensor Flip.
- The Clips window: clips by number, stepped to with `PlayBackSkipClip` by `PlaybackClipIndex`. Its names
  (`ClipTableCardB`) and the page's straight-to-a-clip command need the table's shape from a camera.
- Auto white balance: "AWB" in the WB preset tile runs the page's own AWB button's command
  (`_4da_Ua3pEeSjhp9JjGKhGQ`, `AutoWB`, captured 2026-10-29); the Kelvin it measures follows.

Untried: a Mini LF or ALEXA 35. The page script names only AMIRA (1) and ALEXA Mini (2) for
`SystemCameraType`, so either would read as "ALEXA" with the Mini's EI, ND and output tables.

## VENICE (`venice.md`)

The camera offers it, Tiles doesn't:

- **AXS card slot change.** It's only an assignable function (`AXSSlotChange`). From Tiles it would mean borrowing one
  of the camera's assignable buttons: assign, press, then put the button back.
- **Both cards on the Media tile.** Today Tiles reads both AXS cards' remaining time (`WebInfo.Media.AXSA` / `AXSB`)
  and shows only the larger. It doesn't know which card is recording.
- **Auto white balance.** It's only an assignable function, and `Camera.AutoWhiteBalance` reads Locked.
- **Saving or deleting the camera's white balance presets.** Tiles can only read them.

Untried (the 11/14 sweep): in ECS the shutter mode isn't Speed, so the tile reads it as an angle; a VENICE on DC with no
battery may show no battery reading at all.

Built, never on a camera:

- The Camera Menu keys, user frame lines and audio meters tile.
- Frame Lines (Line A | B) and Audio Meters per output.
- The Clips window (`Next` / `Prev` a clip at a time by `AllClipPosition`, as a VENICE 2 did driven by its
  own page), and the Playback tile's clip number, which a VENICE 2 sends as `{"main": 6}` and Tiles read as nothing.

## FX6 (`fx6-controls.md`)

The camera offers it, Tiles doesn't:

- Slow shutter (`0xD014` / `0xD015`).
- Push autofocus: it doesn't list Push Auto Focus (`0xD05E`). An assignable button set to Push AF would do it.
- Touch focus (`0xD2E4`, though there's no picture to touch).
- Scene files.

The camera won't allow it remotely:

- Its output display (not in its 192 properties), so a clean SDI or HDMI is set in the camera menu.
- Live view.
- Tally, CALL and the camera buttons.
- A clip list: it gives no take number (no `0xD09E`/`0xD09F`, unlike an FX5), so there's no Clips window; Prev and
  Next only. A BURANO and an FX3 the same.

Built, never on a camera:

- Setting AF / MF (`0xD007`). With the 24 mm AF lens it read MF and display-only (the lens's own switch, most
  likely), so the AF / MF tile shows it grayed.
- The AF Settings window (`0xD060`–`0xD062`, `0xE084`, area `0xD22C` display-only with that lens).
- Power zoom.
- The Gain tile's base sensitivity write on an FX6. The same write, from the ISO tile, ran on an FX5 (2026-11-14).

Suspected, not seen on one:

- Review opening an older take. An FX5's Prev opens the take before the one Playback was last on, and Tiles steps on
  with Next by the take number it gives (`fx5-controls.md`). An FX6 gives no take number; its Review was only tried
  with Playback on the last take.

## FX5 (`fx5-controls.md`)

First session 2026-11-14, over Wi-Fi. It lists the FX6's own codes and Tiles reads it as one.

The camera offers it, Tiles doesn't:

- File transfer: Network → File Transfer → Server Settings 1–3, FTP or FTPES servers clips upload to (the VENICE has
  its own).
- Its clips by name: Monitor & Control browses the FX5's clips. Tiles' Clips window lists them by
  number in Playback only, the open take named. `scripts/sony-recorder.py` stands in for the camera and records what
  the app sends, to see how. Which of its ~70 unnamed codes hold it isn't known.
- The Dual Gain bases (Low (Dual Gain), ISO 800 (Dual Gain)) in Sony's guide. This camera didn't list them.
- Pressing assignable buttons other than Base ISO/Sens. and False Color: the FX5 numbers the functions differently,
  so the FX6's checked S&Q Motion and Rec Review aren't pressable on it until checked on an FX5 that has them
  assigned.
- The Flexible Spot's position (`0xE079`; without a picture there's nothing to aim it by) and Auto Focus Hold
  (`0xD091`).
- Slow shutter, touch focus and scene files, as on the FX6.
- About 70 codes not yet named (`fixtures/fx5-dump-2026-11-14.txt`).

The camera won't allow it remotely:

- The project frame rate: it lists only the rate it's on and ignores a write of another (answers OK, stays on 23.98).
  Sony's Monitor & Control can't change it either, only S&Q. Set it on the body ([Project] → [Rec
  Format] → [Project Frame Rate], which may reboot it).
- Live view over Camera Remote (no Live View Status), as on the FX6. Tiles takes it from the camera's stream instead
  (below).
- Auto iris, display-only with this lens while S&Q is on (enabled with S&Q off).
- USB control while the network's Camera Remote Control is on, and the other way round: one remote at a time.

Built, never on a camera:

- Review's second Prev, for a camera that ignores the first just after a cut (seen once, before the fix).
- The Clips window: a take picked by its number, stepped to with Prev and Next as Review steps to the last.
- Live view through its own stream: an RTMP destination set to Tiles, started and stopped over the session
  (`fx5-controls.md`). Needs Network → Stream → Setting → On (not available in all shooting modes); off in the app
  (`SonyBackendConfig.streamLiveView`) until it's worked on a camera that can enable it.
- USB: after one session, every command failed with `0xe0004051`, through a replug and a power cycle.

## BURANO (`burano-controls.md`)

The camera offers it, Tiles doesn't:

- The assignable buttons.
- ECS.
- Slow shutter frames.
- Stabiliser settings.
- Touch operation.
- Autofocus: AF / MF (`0xD007`) read MF and display-only with the lens it had, and it lists no push. Untried with an
  autofocus lens.
- FTP upload settings.

The camera won't allow it remotely:

- Its output display.
- Live view.
- Writing OSD Image Mode. Never do it: it kills the session until the camera is power-cycled.

Built, never on a camera: the battery in minutes when Battery Remain Display Unit `0xD037` is set to minutes
(Battery Remaining in Minutes `0xD038`; a BURANO and an FX6 list it, an FX5 doesn't).

## FX3 (`fx3-controls.md`)

Nothing it allows remotely is missing. Zebra, peaking and frame markers are the camera's limit. Clean HDMI is the
HDMI Info tile.

Built, never on a camera:

- The AF Settings window: Face/Eye Priority AF on or off, seven focus areas, transition speed, shift
  sensitivity, AF Assist. Its codes were in the 10/09 capture all along.

## PYXIS and other Blackmagic cameras (`pyxis-controls.md`, `ursa-cine-controls.md`, `blackmagic-bluetooth.md`)

Nothing is missing on the PYXIS.

Built, needing a camera to prove:

- **The Clips window**: the playback list named from `/clips`, a pick seeking to the clip's start.
- **The iPhone on USB-C**, through Personal Hotspot.
- **An electronic lens's** iris and one-shot autofocus.
- **The URSA Cine** (12K LF, 17K 65, Immersive): built from Blackmagic's REST document, never on one.
- **Blackmagic over Bluetooth**: built from the published Camera Control protocol, never run against a camera.

## Across every camera

- **The camera's own warnings** (`CameraState.alerts`, red on the Label tile): a Sony's overheating
  (`0xD251`) and cards in trouble. Not yet fed by the other makes: an ALEXA's `MessageEvent…` variables, a
  Blackmagic's battery `statusFlags` ("Battery Is Critically Low"), a VENICE's.
- **What powers the camera** (`CameraState.powerSource` on the Battery tile): a Sony's USB, dummy battery, DC and PoE;
  a Blackmagic's DC input, USB, PoE and fiber. A VENICE on DC isn't known (its percentage reads -1 when it shows volts;
  with no battery, untried); an ALEXA's DC reads as its volts.
- **Media from both cards**: a Sony now reads slot B when A has none; a VENICE still shows the larger AXS card, an
  ALEXA the selected one.

- **Autofocus** (push AF and switching autofocus on, on every camera that has autofocus). Push where
  the camera has one: a Blackmagic camera's one-shot (its REST API has no continuous autofocus, only `doAutoFocus`) and
  the FX5's Push AF. AF / MF where it reads: the FX3 (AF-C \| MF), and the FX5, FX6 and BURANO (Focus Mode Setting,
  display-only on the last two as found). The Autofocus tile has both where both exist, and the AF Settings window the
  rest of a Sony's autofocus menu; all of it checked on the FX5 (11/14). ALEXA and VENICE have none.

- **Finding cameras on the network** (one list across makers). Add Camera's On This Network lists the
  Sony cameras with Camera Remote Control on (SSDP, and each address asked for its description on 64321; checked on the
  FX5) and the Blackmagic cameras by their Bonjour adverts (never yet on a camera on Wi-Fi), on any network this device
  is on (`NetworkCameras`, `camctl find`). Cameras on a cable and over Bluetooth have their own lists, and on the HaLow
  mesh every device the nodes leased an address to. ARRI and VENICE cameras announce nothing to find (an ALEXA's
  `mini-<serial>.local` is a name, not an advert), so their addresses are typed.
- **White balance presets.** They're the same six everywhere (`WhiteBalancePresets`). Change the list
  there, and only there.
- **Timecode.** A tile that sets every camera to time of day at once (see ALEXA Mini).
- **Media.** One tile showing both cards, and which is recording, on every camera with two slots.
