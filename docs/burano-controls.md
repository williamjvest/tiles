# BURANO Control Map — measured 2026-10-27

Live camera: MPC-2610 BURANO, firmware 2.02, over HaLow (wired RJ45 node, DHCP), Access Authentication
(SSH mode: `X_SSH_Support` Enable, OpenSSH 7.9, keyboard-interactive login). One night with the camera, so what's
not ticked wasn't tried. Captures: `fixtures/burano-*-2026-10-27.*`; the mapping is pinned by
`Tests/SonyPTPTests/BURANOMappingTests.swift`. Getting the camera onto the network at all is in
`docs/fx6-burano-controls.md` ("On the day").

195 property codes, 12 control codes (`fixtures/burano-dump-2026-10-27.txt`).

| Control | Codes | Live | Tiles | Notes |
|---|---|---|---|---|
| Shutter mode | `0xD010` | Angle | ✓ | 0x01 Speed, 0x02 Angle. |
| Shutter on/off (speed mode) | `0xD00F` | Off | ✓ fixed | Shutter Setting, 0x01 OFF / 0x02 ON. Settable only in speed mode, display-only in angle. **Left off, speed mode shows "Off" on the camera, exposes for 1/24 at 23.98, and 0xD016 is display-only**: what the first Tiles test hit. Switching to speed now turns it on; the speed tile offers Off with the speeds. Shutter Mode Status `0xD011` follows (0x01 OFF, 0x02 Speed, 0x03 Angle, 0x04 ECS). |
| Shutter angle | `0xD00E` | 180° | ✓ | UINT32 × 1000; 19 values 5.6°–360°. Display-only in speed mode. |
| Shutter speed | `0xD016` value, `0xD017` current | 1/60, 1/48 | ✓ | UINT64 num/den. 15 values 1/24–1/8000. `0xD016` is the speed-mode value (kept while in angle); `0xD017` is the exposure now. |
| ECS | `0xE006` on/off, `0xE007` number, `0xE008` frequency | Off | — | On: Shutter Mode Status `0xD011` goes 0x04 ECS, angle and slow shutter go display-only, `0xD017` reads 60 Hz (set and put back). Not in Tiles. |
| ND on/off | `0xD018` | On | ✓ | 0x01 OFF (Clear), 0x02 ON. |
| ND density | `0xD14F` | 0.6 | ✓ fixed | OD × 100. STEP: 0.6, 0.9, 1.2, 1.5, 1.8, 2.1. VARIABLE: 0.60–2.10 every 0.05. Was On/Off only: the transmittance value `0xD01B` is never enabled (ND Filter Unit `0xD14E` = optical density). `0xE0E5` ND Filter Position is the same setting as a transmittance code (2^((v − 0x7FFF)/0x1000)). |
| ND STEP/VARIABLE | `0xD073` | STEP | ✓ new | 0x02 VARIABLE, 0x03 STEP, settable remotely despite the body switch. ND Mode tile (Add Tile); the app's path set Variable and back, read back. ND mode `0xD019` reads 0x06 Step / 0x07 StepClear / 0x04 Variable. |
| Codec | `0xD241` | X-OCN LT (0x1A) | ✓ fixed | One-entry list: read-only. Showed "0x1A" until the name table ran past 0x14. |
| Project frame rate | `0xD286` | 23.98p | ✓ fixed | One-entry list: read-only. |
| S&Q | `0xD051` on/off, `0xD052` rate | Off, 30 | ✓ fixed | Rates 1–60 at this format; higher rates (100–240) may appear at smaller imager modes. Tiles had no S&Q rate. |
| EI / base ISO | `0xD022`, `0xD020` | 3200, High | ✓ | EI 800–12800; base 800/3200. |
| White balance | `0xD20F` kelvin, `0xD00D` tint | 5600, 0 | ✓ | Kelvin 2000–15000. **One-push AWB works**: `0xD03B` written Down (0x0002) then Up (0x0001) measured the room, 5600 → 3276 K, tint 0 → 36 (put back after). In Tiles as AWB in the WB preset list; the app's path measured 3265 K (put back). |
| LUT | `0xD03C` + display strings | s709 | ✓ fixed | 7 presets + 16 user slots; empty slots are named "(No LUT)" and the picker leaves them out. |
| Battery | `0xD037` unit, `0xD039` volts, `0xD03E` DC volts, `0xD218` % | voltage, 14.2 V, —, 0xFF | ✓ fixed | Display unit voltage, so 0xD218 is untaken; volts × 1000. Power Source `0xD03A` = Battery. |
| Media | `0xD24A`/`0xD258` remaining s, `0xD248`/`0xD256` status | 301 min | ✓ | |
| Next clip name | `0xE00B` | D003C005 | ✓ | Read-only. **No camera ID / reel** (`0xD1D0`/`0xD1D1` aren't listed): set them on the camera, TC/Media > Clip Name Format. |
| REC | `0xF001` toggle, `0xE010` status | Standby | ✓ | Status 0x00 Idle, 0x01 Ready, 0x02 Preparing, 0x03 Standby, 0x04 Recording, 0x05 Stopping. The app's REC path took a 5 s and a 25 s take (Standby → Recording → Standby; Preparing and Stopping too quick to catch at this sampling), and the next clip name moved on. While recording, codec, frame rate, S&Q, LUT, desqueeze, shooting mode and gamut go display-only. |
| Playback | `0xE021`–`0xE028`, `0xD02F` state, `0xD030` speed | Not playing | ✓ Live / Review | Play Pause (`0xE022`) from live goes into playback (`0xD0BC` 0x02) and plays; Stop returns to live. **`0xD02F` stays 0x01 through a pause**; Movie Playing Speed `0xD030` (int32/uint32) is 1/1 playing, 0 paused. Tiles took `0xD02F`, so the button stuck on pause. Checked live through the change events. A short clip plays out and drops back to live by itself. **Live / Review** like every other camera (2026-10-27): in review while `0xD0BC` is 0x02; Review is Play Pause, Live is Stop, a held ▶▶ is FF and letting go is Play; Rec Review (`0xE028`, display-only while rolling) plays the last take and stayed in playback 10 s on. All through the app's path (camctl `cmd:`), back to live after. After a Rec Review `0xD030` can still read 1/1 in Record mode, so playing is false out of review. |
| Tally | `0xE0D2` red, `0xE0D3` green | Off | ✓ new | 0x01 OFF, 0x02 ON. Tally tile (Add Tile): Off / Green / Red, one lamp at a time; Red, Green, Off each set and read back through the app's path. Lamps not watched. |
| Call | `0xE0E1` | Off | ✓ new | Shows CALL on the camera. Call tile (Add Tile); on and off read back through the app's path. |
| Camera buttons | `0xD309` (`0xD208` list), `0xD30A` (`0xD209` list) | — | — | ENTER, multi-selector (8 ways + Enter), Home, Clips, Slot-Select, Display, Cancel/Back; MENU through the Multi control. Home switches the LCD between video monitoring and information display, which decides whether HDMI carries the menu. Camera Menu tile (Add Tile) opens MENU (held 1.5 s), Home, Back, Display, Clips and the multi-selector; offered only where Home is pressable, so not the FX3, whose arrows are shooting shortcuts. Home and held MENU answer OK. Confirmed the menu appeared on the HDMI monitor (not watched as it was pressed). |
| Assignable buttons | `0xE029`–`0xE033`, `0xE08E` press; `0xE014`–`0xE01E`, `0xE08D` assignment | — | — | Not in Tiles. |
| Color gamut | `0xE001` | S-Gamut3.Cine | ✓ new | Movie Shooting Mode Color Gamut: 0x01 S-Gamut3.Cine, 0x02 S-Gamut3. Color Gamut tile (Add Tile); both ways read back, put back on Cine. The FX3 lists it settable too, so it gets the tile (not tried on an FX3). Shooting mode `0xE000` has one (Cine EI). |
| AF / MF | `0xD007` Focus Mode Setting | MF, display-only | ✓ read | 0x01 Automatic, 0x02 Manual. Display-only with the lens it had; the AF / MF tile shows it grayed (since 2026-11-14). Untried with an autofocus lens. No Push Auto Focus. |
| OSD image | `0xD207` | — | ✗ **don't** | Not listed. Writing it is accepted, then SDIO_GetOSDImage never answers: the session dies and the camera refuses new ones until it's power-cycled. `osdImage()` now refuses a camera that doesn't list `0xD207`. |
| Live view | — | — | — | None for BURANO over the SDK. |

**Still not in Tiles** (the BURANO offers them): assignable buttons (press `0xE029`–`0xE033`/`0xE08E`; what each does is
set on the camera, `0xE014`–`0xE01E`), ECS on/number/frequency, slow shutter frames (`0xD015`), stabiliser settings
(`0xE080`, `0xD192`/`0xD193`), touch operation (`0xD2E4`), FTP upload settings, and the HTTP MediaProfile on :8080.
Focus, iris and zoom need a servo lens. No live view over the network (Sony).
