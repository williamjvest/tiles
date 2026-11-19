# FX6 and BURANO: getting them onto the network

Both bodies have been measured: `docs/burano-controls.md` (2026-10-27, over HaLow) and `docs/fx6-controls.md`
(2026-10-29, on the LAN). Those pages say what each control does and what Tiles does with it; this one keeps what it took
to get each camera talking, and the order to check a new Sony cinema body in.

The FX6 was already on the LAN with Access Authentication on when its session started; Add Camera → Sony with its
login was all it took. The FX3's login was refused: each camera has its own, set on the camera.

## BURANO's network control (2026-10-20)

- **No web remote.** Unlike VENICE, BURANO has no browser page. Sony's CineAlta Remote Control Guide V2.0 lists
  BURANO's network control as PTP-IP (Tiles' route, and Sony's Monitor & Control app's) and Sony RCP
  panels over wired LAN (CNS-Bridge, from firmware 1.1).
- **One control protocol at a time** (support.cyanview.com, Sony Burano). With Technical > RCP > CNS Mode set to
  Bridge, for an RCP, the camera turns its SDK functions off, so Tiles won't connect. Set it back for Tiles.
- **Firmware 3.0** (May 2026) adds "Import LUTs from Monitor & Control/SDK", a route for Tiles' LUT import as on the
  FX3. Firmware 2.0 (June 2025) added tally from wired-LAN devices and variable ND from the RCP.

## On the day

1. Camera: Network > SSH on (or pairing); wired LAN for BURANO, with CNS Mode not on Bridge. Connect from Tiles and
   approve.
   - **BURANO: bring its LCD.** The first try (2026-10-27, no LCD) never got past this step. Wired LAN is Network >
     Network Setup > LAN Type Select > Wired LAN (the RJ45 and Wi-Fi share that one setting), then Network > Wired LAN >
     Camera Remote Control > Enable. The HaLow node's RJ45 saw no link for 20+ min with the camera cabled, setting unknown.
   - The full menu renders only on the LCD and HDMI (manual pp. 21, 33, 105). SDI carries the status overlay, and only
     in X-OCN; holding MENU just blanks that overlay while the menu opens on the missing LCD.
   - Its HDMI gave no signal at 23.98 on a SmallHD Cine 7 or a TV until the HDMI output was changed in the menu,
     blind. Even then the menu didn't show on HDMI: it only mirrors there in video monitoring mode, and the way out of
     information display mode is HOME, on the LCD. No assignable-button function does it (manual pp. 8, 21, 33, 100).
   - The menu can be driven blind: proved each move by switching the outputs. A count-the-clicks map
     with color bars as the beacon didn't land, so prove every move with a visible effect.
   - The shooting screen's network icon shows the LAN mode (AP, ST, USB tethering or wired, each connected,
     disconnected or error; manual pp. 22, 24), so the SDI overlay can confirm a blind network change.
   - Once Wired LAN took, the node linked at 100 Mb, but the camera had DHCP off and a
     a static address (found from its SSDP NOTIFYs via an nft bridge log rule on the node; nodes have no tcpdump).
     Its DigitalImagingDesc.xml: MPC-2610, firmware 2.02, "Pro Camera Remote Control", X_SSH_Support Enable. Port 22
     is OpenSSH 7.9, keyboard-interactive only (no-password logins as admin and root refused); 15740 closed, as in SSH
     mode. No documented default login (manual p.72): the user name and password live in Network
     Setup > Show Authentication. Once credentials were set and DHCP turned on, it leased an address from the node and an SSH login over HaLow worked (ping ~30 ms).
     The host key changed when the login was set, so expect Tiles to see a new key after any login change.
   - USB-C: with USB Tethering on, the BURANO is the USB host (it wants a phone), so a Mac sees it only at the port
     (USB-PD partner SONY 054c:0d68, role Host) and nothing enumerates. Mass storage needs Network > USB Tethering >
     Setting Off, a card in A or B, and Execute on an LCD prompt at power-on (manual p.107). Media only, no control.
2. `camctl dump <ip> --record fixtures/<body>-connect-<date>.jsonl`: the camera's own list of properties and
   controls. Compare it with the camera's column in `docs/protocol.md` § 6 and with the code, and fix them where they
   differ.
3. REC from Tiles, start and stop, and from the camera's own button. Watch 0xE010 through a take
   (`camctl watch <ip>`): which of Ready / Preparing / Standby / Stopping it passes through.
4. Shutter: speed and angle modes, and shutter Off. ND: preset and the variable fader end to end. WB: Kelvin, and the
   tint's direction (which sign is magenta). Frame rate and S&Q.
5. Write `docs/fx6-controls.md` / `docs/burano-controls.md` in the style of `docs/fx3-controls.md`, one row per
   control, verified ✓/✗, and turn this page into a pointer to them.
