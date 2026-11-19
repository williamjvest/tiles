# FX3 Control Map — verified 2026-10-09

Live camera: ILME-FX3 (Access Authentication, PTP-IP via SSH tunnel).
All values read from a real camera via `camctl dump`. Set tests marked ✓/✗.

| Property | Code | Live value | R/W | Options (camera labels) | Restart needed | Verified set | Notes |
|---|---|---|---|---|---|---|---|
| Model string | `GetDeviceInfo 0x1001` | ILME-FX3 | r | — | — | — | In Init_Command_Ack FriendlyName and GetDeviceInfo Model field. `camctl dump` shows "unknown model" because the CLI exits before async `fetchDeviceModel` finishes; the app gets it correctly. |
| Recording state | `0xD21D` | idle | r | idle, recording | — | — | `isEnabled=dispOnly`: REC is a control, not a property write. See **REC** below. |
| Timecode | `0xD0D3` | 23:00:00:23 | r | — | — | — | UINT32: bits 24-31=h, 16-23=m, 8-15=s, **0-7=frames** (not ms). Low byte 0x17=23 at 59.94fps is a valid frame count. **Sony PTP 3 has no running timecode on the FX3.** The value was the preset and never moved during a live Free Run take (`fixtures/fx3-tc-battery-2026-10-09.txt`). The tile shows the **REC time** from the camera-confirmed REC start: red while rolling, last take's length in gray after. |
| Shutter angle | `0xD00E` | 180.0° | r/w | enum from camera | No | ✓ | UINT32 × 1000. Set 172.8° confirmed. |
| Shutter mode | `0xD010` | Angle (0x02) | r/w | Speed(0x01), Angle(0x02) | No | — | FX3 currently in Angle mode. |
| ISO / EI | `0xD022` (EI) / `0xD21E` (ISO) | 800 | r/w | [EI enum from camera] | No | ✓ | `0xD022` (EI, UINT16) active when enabled; `0xD21E` (ISO, UINT32) used when not in EI mode. Set ISO 1600→800 confirmed. |
| Base ISO | `0xD020` | Low (0x02) | r/w | High(0x01), Low(0x02) | No | ✓ | UINT8. Display numbers come from display list 8 (e.g. 800/12800). **Tapping the current base ISO returns EI to that native base**, even when EI is already on the same base (live: EI 25600 → 12800, then 12800 → 800). |
| White Balance mode | `0x5005` | 0x1280 | r/w | Auto(0x0002), Daylight(0x0004), … | No | — | PTP standard WB; FX3 uses standard codes. |
| Kelvin | `0xD20F` | 5600K | r/w | range 2500–9900 step 100 | No | ✓ | UINT16 direct Kelvin. Set 4500K confirmed. |
| Tint (G-M) | `0xD210` | 0.0 | r/w | range min 0x9C = M9.00 → max 0xE4 = G9.00 | No | ✓ | Biaxial Fine-Tuning G-M. UINT8, mid=0xC0=0. **FX3 uses 0xD210, not 0xD00D.** App convention: negative = green, positive = magenta; shown as G/M prefix. Set tint +2.0 → 0xC8 confirmed. Checked on the FX3 against its own screen: +2 shows M2, −2 shows G2. |
| Iris (F-number) | `0x5007` | f/2.8 | r/w | range from camera | No | — | UINT16 × 100. **FX3 uses 0x5007 (F-Number), not 0xD000 (T-Number); T-Number absent.** |
| ND filter | `0xD018` | — | — | — | — | — | Absent on FX3 (FX6/BURANO only). |
| Frame rate | `0xD286` | 59.94 | r/w | 59.94, 29.97, 23.98 | Not for these options | — | UINT8 enum. Set 23.98 and back to 59.94 with readback (no restart needed). Options depend on the format. |
| File format | `0xD241` | XAVC S-I 4K | r/w | XAVC HS 4K, XAVC S 4K, XAVC S HD, XAVC S-I 4K, XAVC S-I HD | Likely | — | UINT8. Set 0x0B and back to 0x0E (XAVC S-I 4K) with readback. |
| Recording setting | `0xD242` | 600M 422 10bit | r(disp) | — | — | — | UINT16. Display-only under XAVC S-I (bitrate follows frame rate). Turns settable under other codecs (e.g. 0x0B), with a list of options. |
| Resolution | `0xD024` | **absent** | — | — | — | — | Not in FX3 property table. Resolution is implicit in fileFormat choice (e.g. XAVC S-I 4K = 3840×2160). |
| De-squeeze | `0xE0A4` | **absent** | — | — | — | — | Not in FX3 property table. |
| Monitor LUT (`look`, the LUT On toggle) | `0xD04D` | ON | r/w | OFF(0x01), ON(0x02) | No | ✓ | Monitor LUT Setting (All Line). Set OFF and back ON with readback. |
| Gamma Display Assist | `0xD1FE` | OFF | r(disp) | OFF(0x01), ON(0x02) | No | ✗ | `isEnabled=dispOnly` on this FX3; reason unknown. `look` only falls back to it on bodies without 0xD04D. |
| Battery | `0xD218` | 13% | r | — | — | — | **INT8** 0–100% on the FX3 (not UINT8). Live: 29% at start of session, draining to 13%. |
| Media remaining | `0xD24A` | 218 min | r | — | — | — | UINT32 seconds. |
| Next clip name | `0xE00B` | mm0581 | r | — | — | — | Recorder Clip Name: the name the next take gets, following the naming below. (`0xD1CA` "Recording Setting File Name" is the stills prefix, "DSC".) |
| Title | `0xD1DC` | mm | r/w | 1–37 characters | No | ✓ | STR, sent as a PTP string. 38 and up, or empty, come back as SDIE_OperationResults Character Size Error (0x11); non-ASCII ("é") as Invalid Parameter (0x03). The camera also takes space, `.`, `*`, `#`, `+` and `/`, but `/` splits the file name ("a/b" names clips "b0581"), so Tiles only types letters, digits, `_` and `-`. Live 2026-10-11. |
| Camera ID | `0xD1D0` | M (0x0D) | r/w | A–Z (0x01–0x1A) | No | ✓ | UINT8. **Setting it resets the reel to 1.** |
| Reel | `0xD1D1` | 1 | r/w | range 1–999 | No | ✓ | UINT16. 0 and 1000 are ignored. Which of title / camera ID + reel the clip name uses is the menu's file name format: not in PTP 3. |
| Color gamut | `0xE001` | S-Gamut3.Cine (0x01) | r/w | S-Gamut3.Cine (0x01), S-Gamut3 (0x02) | — | — | Movie Shooting Mode Color Gamut, settable in the property dump (`fixtures/fx3-propinfo-full.bin`). The Color Gamut tile (Add Tile, 2026-10-27) offers it; set and read back on a BURANO, **not yet tried on an FX3**. |
| Color bars | — | nil | — | — | — | — | Not exposed in PTP 3 on FX3. |
| False color | — | nil | — | — | — | — | Not exposed in PTP 3 on FX3. |
| Image flip | — | nil | — | — | — | — | Not exposed in PTP 3 on FX3. |
| Latency | measured | ~15–30ms | — | — | — | — | Rolling average of 8 transaction RTTs via SSH tunnel. |

## REC (verified 2026-10-09)

REC is **Movie Rec Button (Hold) `0xD2C8`** via `SDIO_ControlDevice 0x9207`, UINT16 data:
`0x0002` Down **starts**, `0x0001` Up **stops**. One command per request. Captures: `fixtures/fx3-rec-hold-start-2026-10-09.jsonl`, `…-stop-…`.

| Probe | Result |
|---|---|
| Down | `0x2001`, then `SDIE_MovieRecOperationResults 0xC224` param `1` (OK) in ~0.5 s; `0xD21D` → `01`. The backend confirms in ~0.7 s. |
| Up | `0x2001`, `0xC224` OK, then `0xC234 [1,1]`; `0xD21D` → `00`. |
| Down while recording / Up while stopped | `0x2001`, no `0xC224`, state unchanged. Both are absolute. |
| Close the session mid-take without Up | **Keeps recording.** A new session reads `01`. A dropped link never cuts a take. |
| Up from a session that never sent Down | Stops the take. |
| Toggle `0xF001` | Not in the FX3's SDIControlCode list (56 codes from `SDIO_GetExtDeviceInfo`). Answered `0x2001` and ignored. |

The backend chooses REC from the camera's own control-code list: Hold if listed; toggle only as a fallback, and only pressed when the state must change.

## Options follow the codec (verified 2026-10-09)

The FX3's own Set lists change with the codec, and a changed-only fetch carries a list change even when the value
didn't move. The app also re-reads everything after a codec/frame-rate/bitrate change (a safety net for other bodies).

| Codec (0xD241) | Frame rates (0xD286 Set list) | Bitrate (0xD242) |
|---|---|---|
| XAVC S-I 4K (0x0E) | 59.94, 29.97, 23.98 | display-only (600M at 59.94, 240M at 23.98) |
| XAVC S HD (0x09) | 59.94, 29.97, 23.98, **119.88** | settable: 50M 422 10bit, 50M 420 8bit |
| XAVC HS 4K (0x0B) | 59.94, 23.98, **119.88** (no 29.97) | settable: 100M 422 10bit, 100M 420 10bit, 50M 422 10bit, 50M 420 10bit, 30M 420 10bit |

Switching codec moved the frame rate itself (S-I 4K 59.94 → S HD 23.98), and switching back restored 59.94.
Shutter speed in speed mode lists 1/4, 1/5, 1/6, 1/8, 1/10, 1/13, 1/15, 1/20, 1/25, 1/30, 1/40, 1/50 … (first twelve).

## Over the network (verified 2026-10-09)

| Check | Result |
|---|---|
| Built-in SSH tunnel (libssh2) → PTP-IP → full dump, REC start/stop | Works. Connect + auth + session ≈ 1.2 s; REC confirmed 0.5–0.7 s after the command. The direct-tcpip channel must target `localhost` (Sony's `-L 15740:localhost:15740`); `127.0.0.1` was refused and every PTP-IP connection was reset. |
| Host-key pin | OpenSSH form, unpadded base64 (`SHA256:kexL…oqM`). Compared with padding ignored. |
| Second controller while one is connected | SSH logs in, then `Session setup failed: disconnected`. The FX3 serves one PTP-IP initiator at a time; the first session is unaffected. |
| Idle cost, connected, not recording | **60 B/s** PTP-IP payload, 0.8 pkt/s (`fixtures/fx3-idle-75s-ssh-events-2026-10-09.jsonl`): a changed-only fetch every 30 s plus keepalive probe exchanges. |
| Changed-only fetch when nothing changed | 426 B, never empty: the FX3 always reports 0xD057, 0xD059, 0xD05A, 0xD0BF, 0xD0C1, 0xD1C0, 0xD1D3, 0xD215, 0xD26A, 0xD278. The first changed-only fetch of a session returns everything (9.5 KB). |
| Events when idle | One `0xC203` in 18 s with nothing changing. |

## Timecode verdict

0xD0D3 low byte is **frames**, not milliseconds. At 59.94fps, the camera returned 0x17=23 — a valid frame count (0–59 range). The value was stable across reads with the camera idle/stopped, consistent with a stopped TC counter showing a fixed frame.

**Sony PTP 3 has no running timecode.** In a live Free Run take, 0xD0D3 remained the preset and never incremented (`fixtures/fx3-tc-battery-2026-10-09.txt`). The tile therefore shows **REC time**, not a timecode clock: it counts from the camera-confirmed REC start (red while rolling) and shows the last take's length in gray after.

## LUT import (verified 2026-10-09)

Sony **BaseLookImport** uses two operations:
- `SDIO_UploadData 0x921A` — stream the cube file
- `SDIO_ControlUploadData 0x921B` — commit it to a slot
- Camera fires result event `0xC214` when done.

**In-app import** (Settings → camera → "Load LUT onto camera…", or LUT tile picker → last item).
Uses `LUTImportCapable` protocol in CameraCore; `SonyCameraBackend` wraps `importLUT(_:fileName:slot:)`.

**From the command line** (alternative / scripting):

```sh
swift run camctl lut list <camera-ip>        # show current LUT names and slot numbers
swift run camctl lut import <camera-ip> <file.cube> --slot N --name "My LUT"
```

`camctl send <camera-ip> iso|baseiso|kelvin|tint <value>` runs through the app's own command path.

**Bundled false color.** A camera that connects without a false color LUT gets the app's built-in false color LUT in its
first empty User slot (`CameraController.addFalseColorLUTIfMissing`; never over a slot in use, once per connection,
off under Settings → LUTs). The cube is CameraCore's resource, generated by `scripts/make-false-color-lut.py`.

**FALSE COLOR switch** appears when a LUT name contains "false" (case-insensitive) or "FC" as its own word
(e.g. "GK_SLOG3_Log_FC"). Tap it to switch to False Color, tap again to restore the previous LUT. The LUT is
a monitor overlay only — it does not reach the recording signal.

## `look`: Monitor LUT Setting

`look` (the LUT tile's LUT On toggle) maps to Monitor LUT Setting `0xD04D`, which the FX3 lets us set.
Gamma Display Assist `0xD1FE` is display-only on this FX3; `look` falls back to it only on bodies without `0xD04D`.

## Live View (verified 2026-10-09)

Mechanism: `GetObject(0xFFFFC002)` over the existing PTP command channel. Not HTTP.

| Property | Code | Live value | Notes |
|---|---|---|---|
| Live View Status | `0xD221` | `0x01` (Enabled) | UINT8, read-only. 0x00=Disabled, 0x01=Enabled. FX3 reports Enabled in shooting mode. |
| Live View Image Quality | `0xD26A` | `0x02` (High) | UINT8, r/w. 0x01=Low (640×360), 0x02=High. Set to Low before streaming; restore on stop. |
| LiveViewURL | `0xD278` | `http://192.0.2.1:60152/liveviewstream?…` | Pan/tilt cameras only (BRC-AM7, FR7). Present on FX3 but HTTP endpoint returns 503 — do not use. |

**Measured (FX3, Low quality, SSH tunnel, 2026-10-09):**
- 640×360 JPEG, ~6835 B avg JPEG, ~7249 B avg on-wire, ~194 ms avg fetch, ~58 kbit/s at 1 fps.
- Fixture: `fixtures/fx3-liveview-frame.jpg`.
- Protocol details: `docs/protocol.md` §8 gotcha 5; data costs: `docs/network-budget.md`.

## Playback: through the camera's own buttons

The FX3 has none of Sony's playback buttons (`0xE021`–`0xE028`). It is played back by pressing its physical buttons over the network.

- **Pressing a button.** Camera Button Function `0xD309` (SDIO_ControlDevice, UINT32 `id << 16 | 0x0002`, then `| 0x0001` to release). The FX3 lists the ids it accepts in `0xD208`: Up/Down/Left/Right, ENTER, MENU, the multi-selector, Fn, Playback `0x11`, Mode, C1–C6 and MOVIE. Its dials (`0xD20A`: `0x4001`–`0x4003`) turn through `0xD30B`.
- **What it reports.** Only Camera Operating Mode `0xD0BC` (`0x01` Record, `0x02` Playback), which flips within 0.3 s of the press.
- **What the buttons do in Playback.** ENTER plays and pauses. Left/Right change clip when stopped, and scan backward or forward while playing: roughly 2–5×, to the end of the clip, and ENTER during a scan plays on from there. The camera reports neither position nor speed; this was measured on a clip recorded with the shutter stepped every 3 s, so brightness gave the position. Tiles turns a tapped arrow into a 1.5 s scan and ENTER (a skip of a few seconds; `SonyBackendConfig.skipScanTime`) and a held one into a scan until release. ⏮ ⏭ press Playback first when a clip is open (playing or paused), which goes back to the clip, then an arrow, then ENTER if it was playing, so the neighbor plays on. A clip that has played to its end is back on its own screen without a word, so that Playback press leaves Playback; Tiles then presses it again to go back in before the arrow. Checked on the FX3 (2026-10-11): three ⏭ then three ⏮ retrace the same clips, and from a playing clip both land on the neighbor, stopped, still in Playback.
- **The operation panel, and why Tiles doesn't drive it.** While a clip plays, Down opens Sony's panel on the OSD layer (`SDIO_GetOSDImage` shows it): ⏮ ◀◀ ⏸ ▶▶ ⏭, photo capture, volume, close, with the cursor on ⏸. Sony's Help Guide puts frame step and slow motion in it while paused. But what Down does depends on the playback display mode, which Up (DISP) cycles between minimal and clip info (date, time, file name such as `mm0561`): with info showing, Down opens the volume dialog instead. Frame stepping remotely would mean driving that menu blind, where a wrong guess changes the volume, so Tiles offers skip, scan and ⏮ ⏭ and leaves frame step to the body. Playback steps back one level: a playing clip to the clip, then the clip to the live picture.
- **Live view shows it.** In Playback the live view stream carries the playback screen, so the Live View tile is the review monitor.
- **A new connection ends it.** Opening a PC Remote session puts the camera back in Record mode.
- **The trap.** In Record mode the arrows and ENTER are the camera's shooting shortcuts (peaking, zebras), so Tiles presses them only when `0xD0BC = 0x02` (`SonyCameraBackend.operatingModeNow`), pinned by `SonyButtonPlaybackTests`.
- **OSD capture.** SDIO_GetOSDImage `0x9238` returns the FX3's on-screen display as a PNG once OSD Image Mode `0xD207` is on. `camctl keys … osd:<name>` saves one.
