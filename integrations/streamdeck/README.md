# Tiles — Stream Deck Plugin

Control Sony and Blackmagic cameras through **Tiles** on your local network, directly from a Stream Deck or Stream Deck +.

> **⚠ Unverified on real hardware.** This plugin has never run against a real Stream Deck app or physical device. It has been tested against a fake Tiles server built from the API contract. Treat it as a first-draft implementation pending hardware verification.

---

## Installation

### Quick install (double-click)

1. Build the `.streamDeckPlugin` bundle:
   ```
   npx streamdeck pack com.toldwell.twcc.sdPlugin
   ```
   This produces `com.toldwell.twcc.streamDeckPlugin` in the current directory.

2. Double-click the `.streamDeckPlugin` file. Stream Deck will install it automatically.

### Developer link (live reload)

```sh
cd integrations/streamdeck
npm install
npm run build       # compiles src/ → com.toldwell.twcc.sdPlugin/bin/plugin.js (not committed)
npx streamdeck link com.toldwell.twcc.sdPlugin
```

The plugin is then active. Re-run `npm run build` (or `npm run watch`) after changes.

> `com.toldwell.twcc.sdPlugin/bin/` is gitignored. Always run `npm run build` before packaging or installing.

---

## Setup

1. Open **Tiles** on your iPhone/iPad and go to **Settings → Control API**. Enable the server and copy the **Pairing Token**.

2. Open the Stream Deck app and add any Tiles action to your layout.

3. In the **Property Inspector** (right panel):
   - Enter the **Host** (your iPhone's LAN IP or Bonjour hostname).
   - Leave **Port** at `51800` unless you changed it.
   - Paste the **Pairing Token**.
   - Click **Test connection** — it should say "✓ Connected — N camera(s)" and populate the camera dropdown.

4. Pick a **Camera** from the dropdown, or leave blank to follow the app's current page.

> Connection settings are **shared across all keys** via global plugin settings — you only need to enter them once.

---

## Keys

| Action | What it does |
|--------|-------------|
| **REC Toggle** | Start/stop recording. **Red** = camera confirms recording. **Amber** = request pending. **Gray** = idle, unknown, or offline. Never shows red until the camera confirms. |
| **ISO +** / **ISO −** | Step ISO up/down through the camera's option list. Title shows live value. |
| **Shutter +** / **Shutter −** | Step shutter angle or speed (follows current shutter mode). |
| **Iris +** / **Iris −** | Step iris open/closed. |
| **Kelvin +** / **Kelvin −** | Step color temperature up/down. |
| **ND +** / **ND −** | Step ND preset up/down (Cinema-line only; alerts on cameras without `ndPreset`). Title shows live value. |
| **Tint +** / **Tint −** | Step tint +1 / −1 (level field; alerts on cameras without `tint`). Title shows live value. |
| **WB Preset Cycle** | Cycle through the camera's white balance presets. |
| **LUT On/Off** | Toggle the monitor LUT. Lit = LUT active. |
| **False Color** | Toggle false color exposure assist. |
| **Clean Feed**, **Status Text**, **Zebra**, **Focus Assist**, **Frame Guides** | Blackmagic (2.1.0): toggle on every output that has it; lit = on everywhere. In Tiles itself a tile can set one output. |
| **HDMI Info**, **Grid Lines** | Sony (2.1.0): the camera's info on its HDMI output (off = clean HDMI), and its grid lines. A camera without the setting flashes the alert instead of sending. |
| **FPS Cycle** | Cycle through project frame rates. |
| **Any Control** | Send any field command. Inspector: pick any field from the full API list and an operation (set / step / toggle / cycle). Title shows the field's live value; lit when a bool field is true. Alerts if the camera lacks the field. |
| **Playback** | Send a transport command. Inspector: choose command (togglePlay, play, pause, stop, next, previous, fastForward, rewind, recReview, review, live, Live/Review, skip ± seconds). Alerts unless the camera takes that command now (its `playback.commands`; Live/Review needs a writable `playbackMode`, so not while recording). Live/Review cycles `playbackMode` and lights in review; play/pause/togglePlay keys light while playing. The title says which command (PREV, FF, +5s…). |
| **Lock** | Lock or unlock the app's controls (as the app's padlock tile does). Lit while locked. API commands still work while locked. |
| **TC / Duration** | Toggle the VENICE timecode display between timecode and take duration. Lit while showing duration. Alerts on cameras without `timecodeDuration`. |
| **Show Page** | Switch the app's active page. Set the Page ID in the inspector. |
| **Link Toggle** | Toggle the link group on a page. Set the Page ID in the inspector. |

On `confirmed`: shows ✓. On `failed`, `rejected`, or `timeout`: shows ⚠.

---

## Stream Deck + Dials (Encoders)

Requires a **Stream Deck +**. The touch strip shows the field label and current value.

| Dial | Rotate | Press |
|------|--------|-------|
| **ISO Dial** | Adjust ISO | Toggle base ISO (if camera supports it) |
| **Shutter Dial** | Adjust shutter angle/speed (follows current mode) | Cycle shutter mode angle↔speed |
| **Kelvin Dial** | Adjust color temperature | Cycle WB preset |
| **Tint Dial** | Adjust tint | Step tint one increment toward 0 |
| **Iris Dial** | Adjust iris | Open iris one stop |
| **Variable ND Dial** | Adjust variable ND | Decrease ND by one step |

Every rotation tick is sent individually — the server coalesces them, so fast spins don't flood a HaLow link.

---

## What's unverified

- Never run against a real Stream Deck app or physical device (key or dial).
- Never run against a real Tiles server or camera — all testing was against a fake server built from the API contract.
- The `.streamDeckPlugin` bundle has not been installed and smoke-tested.
- Image assets for new actions are placeholder copies of existing icons — visual design is TBD.
- REC timer displayed as key title (e.g. `REC\n02:14`) — not validated in the SD app's UI.
- Global settings propagation to the property inspector's camera dropdown — requires the SD app to test.
