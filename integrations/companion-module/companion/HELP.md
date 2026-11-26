# Tiles — Companion Module

Controls cinema cameras through the Control API of **Tiles** on iPhone, iPad or Mac (WebSocket, API 1).

## Setup

1. Open Tiles → **Settings → Control API** → enable it and copy the pairing token.
2. In Companion, add a connection, choose **Tiles**, and enter:
   - **Host / IP Address**: the device's LAN IP (e.g. `192.168.1.50`)
   - **Port**: `51800` (default; leaving it blank auto-fills `51800`)
   - **Token**: the pairing token from Tiles → Settings → Control API

## Important: cameras and pages are addressed by ID

Buttons store the camera's UUID, not its label. The dropdown shows `C · FX3` but what's saved is the UUID. If you rename a camera in the app, existing buttons keep driving the same camera — nothing breaks silently. Variable names (`$(twcc:C_iso)`) do update to the new label after the next snapshot.

## Actions

| Action | Notes |
|---|---|
| REC — Start/Stop | `set record=recording/idle` |
| REC — Toggle | Server resolves from confirmed state; `unknown` → `rejected` (logged, not retried) |
| Field — Set Value | Absolute set; value must be in options or within range |
| Field — Step +/− | Steps through options (choice) or by N×step units (level) |
| Field — Cycle | Next option, wrapping |
| Field — Toggle Bool | False Color, LUT on/off, color bars, flip |
| App — Show Page | Switches the iPad's current page (by page ID) |
| App — Set Page Linking | On / Off / Toggle — resolves from current pages state |
| App — Set Link Group | Enable/disable a link group (whiteBalance, frameRate, shutter, record) |
| Focus — Drive | Start driving focus (Near/Far, speed 1–8). Renews every 250 ms via module timer. Assign to button **down** action. |
| Focus — Stop | Stop focus motor (speed 0). Clear the renewal timer. Assign to button **up** action. |
| Zoom — Drive | Start driving zoom (Wide/Tele, speed 1–8). Renews every 250 ms via module timer. |
| Zoom — Stop | Stop zoom motor. |
| Assignable Button — Press | Press an assignable body button (1–10). Rejected if the button's function is not supported by Tiles. |
| Autofocus — Push | Push autofocus, as the app's Autofocus tile: a Blackmagic camera's one-shot, an FX5's Push AF. Rejected while the camera's focus is on AF, or on a camera with no push. Switch AF / MF with the Focus Mode field. |
| Grab Still | Write a still to the camera's own card, as the app's Grab Still tile (Blackmagic cameras). Rejected on cameras without still capture over the network. |

Every camera action has a camera dropdown showing `Label · Model`.

### Focus and Zoom: hold-to-drive

Pair **Drive** on a button's **Pressed** (down) action with **Stop** on its **Released** (up) action. The module timer re-sends the drive command every 250 ms while held, so the motor keeps running. On release, Stop sends speed 0 and clears the timer. Timers are also cleared on connection loss and module destroy.

## Feedbacks

| Feedback | Condition |
|---|---|
| **Recording** | `connection=connected` AND `record.value=recording` — never optimistic |
| **REC Unknown** | `record.value=unknown` (camera offline or transitioning) |
| **REC Request Pending** | `record.request` is set |
| **Camera Connected** | `connection=connected` |
| **Camera Not Connected** | `connection≠connected` |
| **Field Equals Value** | Confirmed field value matches string |
| **Field Writable** | Field present and `writable=true` |
| **Radio Bars Below** | `radio.bars < threshold` |
| **Camera — Last Still Saved** | `lastStill.saved=true` — the last Grab Still saved to the card |

## Variables

Variables use the camera's current label as prefix (e.g. `C` for camera labeled "C"):

| Variable | Meaning |
|---|---|
| `$(twcc:C_rec_state)` | `idle` / `recording` / `unknown` |
| `$(twcc:C_rec_time)` | `HH:MM:SS` elapsed, ticked locally once/sec — a take started on the camera counts too (Tiles 72) |
| `$(twcc:C_iso)` | ISO, and so on for all 25 fields |
| `$(twcc:C_falseColor)` | An on/off field reads `ON` or `OFF` (it read `true` / `false` before 0.5) |
| `$(twcc:C_battery)` | Battery % |
| `$(twcc:C_media_minutes)` | Media minutes remaining |
| `$(twcc:C_latency)` | Latency ms |
| `$(twcc:C_model)` | Model string |
| `$(twcc:C_connection)` | Connection state |
| `$(twcc:C_id)` | Camera UUID |
| `$(twcc:current_page)` | Current page name |
| `$(twcc:radio_bars)` | HaLow bars 0.0–1.0 |
| `$(twcc:halow_signal_dbm)` | HaLow first-node dBm |

**On rename:** variable IDs update to the new label at the next snapshot. Button text referencing the old label will go blank until Companion refreshes its variable subscriptions. The camera action/feedback options (stored as UUIDs) are unaffected.
