# FX6 Control Map — measured 2026-10-29

Live camera: ILME-FX6V, firmware 6.00, on the LAN with a DHCP lease (ping 100–190 ms, as a Wi-Fi link answers),
Access Authentication (SSH mode: `X_SSH_Support` Enable, OpenSSH 7.9). The FX3's login was refused; the BURANO's
worked, which is what the camera had been set to. The host key is ECDSA. Its `DigitalImagingDesc.xml` on :64321 names it "Pro Camera Remote Control", PTP 3.00.

Captures: `fixtures/fx6-*-2026-10-29.*`. The mapping is pinned by `Tests/SonyPTPTests/FX6MappingTests.swift`, and the
playback buttons by the FX6 cases in `PlaybackTests.swift`.

192 property codes, 12 control codes (`fixtures/fx6-dump-2026-10-29.txt`).

Every control below went through the app's own path (`camctl keys` with `app:`, `iso:`, `angle:`, `speed:`, `rec:`
and `cmd:` steps), was read back, then put back. A full property read at the end matched the one at the start except
for the next clip's name and the media remaining, after one 6 s test take.

| Control | Codes | Live | Tiles | Notes |
|---|---|---|---|---|
| REC | `0xD2C8` hold, `0xE010` status | Standby | ✓ | Also lists `0xF001` toggle and `0xD2FE` (second rec button). Through the app's path: Standby → Preparing → Recording in about 1.2 s, the tile showed REC at 1.4 s; stop to Standby within 0.6 s; next clip FX6_26_1476 → 1477. During a take the LUT, S&Q, desqueeze and gamut go display-only. |
| ISO | `0xD21E` | 800 | ✓ | 800–10000 on the low base. EI `0xD022` disabled: Movie Shooting Mode `0xE000` is 0x0501, Flexible ISO (the bytes are `01 05`). |
| Shooting mode | `0xE000` | Flexible ISO | ✓ new | UINT16: 0x0401 Custom, 0x0301 Cine EI, 0x0302 Cine EI Quick, 0x0501 Flexible ISO; settable, each mode with its own white balance, look and exposure (Custom here: 5000 K, s709, gain in dB). Shooting Mode tile (Add Tile): confirmed first, never during a take. Custom, Cine EI and back through the app's path; a full read afterwards matched. |
| Gain (dB) | `0xD01E` value, `0xD01D` unit | 11 dB in Custom | ✓ new | INT8 −3 to 30. In Custom this camera works in dB: ISO `0xD21E` and base ISO go disabled, so Tiles had no ISO tile there. The ISO tile now shows Gain in dB; 6 dB and back. The unit itself is display-only over the network. |
| Base ISO | `0xD020` | Low | ✓ | Low 800, High 12800 (display strings); High moves the ISO to 12800. |
| Shutter mode | `0xD010` | Angle | ✓ | |
| Shutter angle | `0xD00E` | 180° | ✓ | 19 values 5.6°–360°. Display-only in speed mode. |
| Shutter on/off (speed mode) | `0xD00F` | Off | ✓ fixed | As the BURANO, except that while it's off the FX6 empties `0xD016`'s Set list and keeps the 15 speeds only in its Get/Set list. So the tile offered only Off, and a picked speed was refused as unknown. The speeds now come from the Get/Set list while it's off; picking 1/50 turned it on at 1/50. Left Off, as found. |
| Shutter speed | `0xD016` value, `0xD017` exposure | 1/250, 1/48 | ✓ | 15 values 1/24–1/8000. `0xD016` is the speed mode's, kept in angle mode. |
| ND on/off | `0xD018` | On | ✓ | Clear turns it off. |
| ND density | `0xD14F` | 0.6 | ✓ | ND Filter Unit `0xD14E` is optical density, as the camera shows it. VARIABLE: Clear and 0.60–2.10 every 0.05, settable (0.6 → 0.9 → Clear → 0.6). PRESET: display-only. The transmittance `0xD01B` is enabled too, unlike the BURANO's. |
| ND PRESET/VARIABLE | `0xD073` | VARIABLE | ✓ | 0x01 PRESET, 0x02 VARIABLE; no STEP. Settable over the network whatever the body switch says; PRESET and back. |
| Auto ND | `0xD01A` | Manual | ✓ new | ND Filter Mode Setting: 0x01 Automatic, 0x02 Manual. Automatic makes the density display-only. Auto in the ND tile. |
| Auto gain (AGC) | `0xD01C` | Manual | ✓ new | Gain Control Setting: 0x01 Automatic, 0x02 Manual. Automatic makes the ISO display-only; ISO Current Sensitivity `0xD023` is what it picked (5000), which the ISO tile shows. In Custom (dB) Gain dB Value `0xD01E` goes display-only and keeps the manual 12 dB, Gain dB Current Value `0xD01F` has what AGC picked (15), and `0xD023`, disabled, carries the same 15: the Gain tile shows `0xD01F`. Auto in the ISO and Gain tiles. |
| ISO/gain switch (L/M/H) | — | — | ✓ follows | The body's switch picks one of three preset ISOs set in its menu (this camera: 800 and 1250 among them); its position isn't reported, the ISO it picks is, and the ISO tile follows. |
| White balance | `0xD20F` Kelvin, `0xD00C` mode | 4500 K, Manual | ✓ new | Kelvin 2000–15000, settable in Manual. No `0x5005`: its mode is White Balance Mode Setting `0xD00C`, Automatic or Manual, settable. Automatic makes the Kelvin display-only (it read 5600 for the 6 s watched) and enables `0xD03B`; Manual brings back the Kelvin set before. Now the preset tile's Auto. It used to say "WB" whenever the Kelvin was display-only (Automatic, playback); now Auto, or the Kelvin. |
| Tint | `0xD00D` | 0, −20 | ✓ on A/B | Display-only while the body's **B/A/PRESET** white balance switch is on PRESET, whatever `0xD00C` says; on A or B (a memory) settable, −99…99, along with the Kelvin, and one-push AWB (`0xD03B`) enabled. −20 → −10 → −20 through the app's path. Tint Step `0xD2ED` answers OK and changes nothing on PRESET. The switch's position isn't reported. Which sign is green isn't documented and can't be seen over the network (no live view or OSD image); taken as + = magenta, as on the BURANO. |
| One-push AWB | `0xD03B` | — | — | Display-only in Manual, enabled in Automatic; not pressed, so what it does there is unknown. |
| Project frame rate | `0xD286` | 23.98 | ✓ | Display-only: six rates listed, none settable over the network. |
| S&Q | `0xD051` on/off, `0xD052` rate | Off, 60 | ✓ | Rates 1–60, 100, 120. On and off, 30 and back. |
| Codec, resolution | `0xD241`, `0xD024` | XAVC I, 3840x2160 | ✓ | Display-only. No bitrate property. |
| Desqueeze | `0xE0A4` | 1.5x | ✓ | Off, 1.3x, 1.5x, 2.0x. 2.0x and back. |
| Color gamut | `0xE001` | S-Gamut3.Cine | ✓ | Both ways and back. |
| LUT | `0xD03C` + display strings | User 4 | ✓ | s709, 709(800%), S-Log3 and the loaded user LUTs (User 4 "Neutral Fx6_33x", "Sony FilmUnlimited 500T"). s709 and back. |
| Iris | `0x5007` | f/2.8 | ✓ | Disabled with the first lens; with an autofocus E-mount lens (24 mm) 19 stops f/2.8–22, f/4 and back. |
| Auto iris | `0xD001` | Manual | ✓ new | 0x01 Automatic, 0x02 Manual. Automatic makes `0x5007` display-only. Auto in the Iris tile. |
| Focal length | `0xD00B` | 24 mm | ✓ new | Thousandths of a millimetre. Shown on the Zoom tile. |
| Focus | `0xD2EF` Focus Operation, `0xE089` position, `0xD004` distance | — | ✓ new | INT8, −8…8 (Focus Speed Range `0xD008`), 0 stops; + focuses farther. It drives **until told 0**: one +1 ran 6 s, 10217 → 7065. Moves although Sony says it needs `0xD004` enabled (display-only here). Position `0xE089` 0–65535 falls as focus goes farther; distance `0xD004` in thousandths of a meter once the lens has moved (73 m, 5.8 m), else 0xFFFFFFFF. Focus tile (Add Tile): Near and Far held, renewed every 200 ms; the backend stops a drive nothing renewed for 600 ms (one unrenewed +1 moved 421, against 3150 in 6 s), and before disconnecting. Mode `0xD007` display-only (body switch). |
| AF / MF | `0xD007` Focus Mode Setting | MF, display-only | ✓ read | 0x01 Automatic, 0x02 Manual. Display-only with the 24 mm AF lens as found (its own AF/MF switch, most likely): the AF / MF tile shows it grayed (since 2026-11-14). Setting it is built, untried. No Push Auto Focus (`0xD05E`) in its list. |
| AF settings | `0xD060` subject recognition, `0xD22C` area, `0xD061` transition speed, `0xD062` shift sensitivity, `0xE084` AF Assist | Face/Eye Priority AF, Wide, 4, 5, On | built, untried | The AF Settings window (Add Tile, since 2026-11-14). Face/Eye Only AF, Face/Eye Priority AF, Off; the area display-only with the 24 mm lens (Wide, Zone, Flexible Spot); speeds 1–7 and 1–5. |
| Zoom | `0xD2DD` Zoom Operation, `0xD25B` enable | — | built, untried | Same shape as focus; enabled only with a power zoom (`0xD25B` 0 with this lens). Zoom tile, offered when it says 1. |
| Battery | `0xD03E` DC volts, `0xD03A` source | 19.8 V | ✓ | On DC the battery codes are disabled and the tile shows the DC volts. |
| Media | `0xD24A` remaining s, `0xD248`/`0xD256` status | 517 min | ✓ | Slot B empty. |
| Next clip name | `0xE00B` | FX6_26_1476 | ✓ | Read-only. No camera ID or reel (`0xD1D0`/`0xD1D1` aren't listed). |
| Playback | `0xE021`–`0xE028`, `0xD0BC` mode, `0xD030` speed | Live | ✓ fixed | Below. |
| Tally, CALL, camera buttons | — | — | — | Not listed: no `0xE0D2`/`0xE0D3`, `0xE0E1`, `0xD309`/`0xD30A`. |
| Live view | — | — | — | Not over the network. |
| LUT per output | `0xD2AA`–`0xD2AC`, `0xD2A9` | On, On, Off | ✓ new | Monitor LUT Settings 1–3 (0x01 OFF, 0x02 ON); `0xD2A9`'s list says where each goes: 1 SDI and HDMI, 2 VF, proxy and live view, 3 **internal recording**. 1 and 2 are monitoring outputs ("SDI/HDMI", "VF"): the LUT tile's Outputs switch sets both, the Monitoring window each. 3 is its own tile, LUT in Rec, never reached by an outputs switch and not settable during a take; while it's on the LUT picker says "in rec". Disabled in Custom. Each off and on through the app's path. |
| Proxy recording | `0xE00D`, `0xE011` status | Off | ✓ new | 0x00 Rec Disable, 0x01 Rec Enable; on, the proxy recorder reads Standby (`0xE011`) and the proxy format shows (1920x1080). Proxy tile, with the status under it. Not during a take. |
| ECS | `0xE006`, `0xE008` frequency, `0xF000` step | Off | ✓ new | 0x01 OFF, 0x02 ON. On: `0xD011` goes 0x04, the angle display-only, frequency `0xE008` in thousandths of a hertz (240.00 Hz; 23.99–6000 Hz), stepped by the Shutter ECS Number Step control (INT16; +1 → 242.00 Hz). ECS tile; the Shutter tile shows "ECS 240.00 Hz" while it's on. |
| Assignable buttons | `0xE029`–`0xE031`, `0xE033` press; `0xE014`–`0xE01C`, `0xE01E` assignment; `0xE035`–`0xE03D`, `0xE03F` light | — | ✓ new | Press: UINT16 Down then Up. Names: display list 0x0B (short). This camera: 1 S&Q Motion, 2 and 4 Base ISO/Sens., 3 Volume, 5 Menu, 6 Display, 7 VFx3/x6, 8 Rec Review, 9 Home, lens Focus Hold. Pressed and read back: S&Q Motion (S&Q on, the button lit, and off), Base ISO/Sens. (800 ↔ 12800), Rec Review (the last take, then live). Only those, by index *and* English name, are pressable in the Assignable window; the rest list grayed. Function 0x43 is "Last Clip Del.": never pressed, and no raw write reaches an assignment or a press. |
| Delete UserBaseLook | `0xD0C7` | — | ✗ never | Listed and settable: it deletes a user LUT. camctl's raw write refuses it, the assignable buttons and scene files, and anything the camera didn't list as a property: every control, the card-wiping `0xD2E2` among them on the bodies that list it. |

**Playback** (`fixtures/fx6-playback-*-2026-10-29.jsonl`). The FX6 takes different buttons from the BURANO's, with the
same list:

- On the live picture, Play Pause does nothing. Play only sometimes picks up where playback last stopped: it worked
  twice and did nothing twice. Prev opens the last take, paused at its start, every time (5 of 5). REW rewinds from
  the end at −4×.
- In playback, Play plays at 1×. Play Pause pauses but never resumes. FF goes 4× then 15×, REW −4× then −15×, and Play
  goes back to 1×. Next, on the last take, paused it. Stop returns to the live picture, and so does a clip that plays to
  its end. Movie Playing Speed `0xD030` lists −24, −15, −4, −1, 0, 1, 4, 15 and 24.
- Tiles on an FX6: Review is Prev, then Play once `0xD0BC` says Playback (playing in review 0.7 s after the tap). The
  play/pause button pauses with Play Pause and resumes with Play. Live is Stop. Checked through the app's path:
  Review, pause, resume, Live. The BURANO keeps Play Pause for both.

The playing speed `0xD030` is under ◀◀ ▶▶ while it scans (4×, 15×, 24×).

Base sensitivity in dB, Gain Base Sensitivity `0xD021` (0x01 High, 0x02 Low): enabled and settable in Custom (Low as
found), disabled in the ISO modes, where Gain Base ISO Sensitivity `0xD020` is the base. The Gain tile's Base switch
(Low | High); read from the camera's Custom fixtures, the write not yet tried on the camera.

**Still not in Tiles** (the FX6 offers them): slow shutter (`0xD014`/`0xD015`), touch focus (`0xD2E4`, no picture to touch), and scene files
(`0xE0E6`, `0xE101`/`0xE102`, refused by the tools). The FX6's own tiles are read only for an FX6: a BURANO lists
several of the same codes, unchecked.
