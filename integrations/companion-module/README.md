# Tiles — Bitfocus Companion Module

Controls cinema cameras through the Control API of **Tiles** on iPhone, iPad or Mac (WebSocket, API 1).

Stream Deck on Mac/RPi → Companion → Tiles on iPad → camera.

## SDK versions used

| Package | Version | Source |
|---|---|---|
| `@companion-module/base` | `2.2.1` | [github.com/bitfocus/companion-module-base](https://github.com/bitfocus/companion-module-base) `packages/base/package.json` |
| `@companion-module/tools` | `^3.1.1` | [companion-module-template-ts package.json](https://github.com/bitfocus/companion-module-template-ts/blob/main/package.json) |
| Manifest runtime | `node26`, `api: nodejs-ipc` | [companion.free manifest docs](https://companion.free/for-developers/module-development/module-setup/manifest.json) — requires Companion ≥ 4.1 (API 2.1) |
| Build/package | `companion-module-build` | `@companion-module/tools` |

## Installing as a developer/local module

1. Download Companion ≥ 4.1 from [bitfocus.io/companion](https://bitfocus.io/companion).
2. Create a dev modules folder and point Companion Launcher → cog → **Developer modules path** at it.
3. Build:
   ```sh
   cd integrations/companion-module
   npm install
   npm run build
   ```
4. Symlink into your dev folder:
   ```sh
   ln -s $(pwd) ~/companion-modules/companion-module-toldwell-twcc
   ```
5. Restart Companion. **Tiles** appears in Connections (not the store).

To build a distributable `.tgz`:
```sh
npm run package   # produces toldwell-twcc-<version>.tgz
```

## Setting host and token in Tiles

Tiles → **Settings → Control API** → enable → copy token → paste into the Companion connection config.

The server runs only while Tiles is in the foreground.

## Cameras and pages are addressed by ID — not label

The spec requires clients store UUIDs: a label can be renamed, and a key saved as "C" would silently drive a different camera. Every action and feedback option stores the camera's UUID. The dropdown shows `C · FX3` for readability, but the UUID is what's saved.

**On rename:** buttons keep driving the same camera (UUID unchanged). Variable ids (`C_iso`) update to the new label at the next snapshot/cameras message; button text using the old variable name goes blank until Companion refreshes subscriptions.

## Actions

| Action | Wire format |
|---|---|
| REC Start / Stop | `{set: "record", value: "recording"/"idle"}`, target `{cameraID}` |
| REC Toggle | `{toggle: "record"}` — server resolves from confirmed state; `unknown` → `rejected` (logged, not retried) |
| Field Set | `{set: field, value}`, `cameraID` target |
| Field Step | `{step: field, by: N}` — level fields: `by` × `field.step` |
| Field Cycle | `{cycle: field}` |
| Field Toggle On/Off | `{toggle: field}` for look, falseColor, colorBars, imageFlip, frameRateVariable; Blackmagic's zebra, focusAssist, frameGuides, frameGrids, safeArea, cleanFeed, statusText; Sony's hdmiInfo, gridLines; BURANO's call; VENICE's timecodeDuration; playback's playing |
| Show Page | `{type:"app", action:"showPage", pageID}` |
| Set Page Linking | `{type:"app", action:"setLinking", pageID, enabled}` — toggle resolved from latest pages state |
| Set Link Group | `{type:"app", action:"setLink", pageID, group, enabled}` |
| Playback — Transport Command | `{playback: cmd}` or `{playback: "skip", by: N}` — togglePlay, play, pause, stop, next, previous, fastForward, rewind, scanForward, scanBackward, endScan, skip, recReview, review, live |
| App — Lock / Unlock Controls | `{type:"app", action:"setLocked", enabled}` — lock, unlock, or toggle from last known state |

## Feedbacks

| Feedback | Condition |
|---|---|
| Recording | `connection=connected` AND `record.value=recording` |
| REC Unknown | `record.value=unknown` (offline / transitioning) |
| REC Request Pending | `record.request` set |
| Camera Connected | `connection=connected` |
| Camera Not Connected | `connection≠connected` |
| Field Equals Value | Confirmed field value matches |
| Field Writable | Field present and writable |
| Radio Bars Below | `radio.bars < threshold` |
| Playback — Playing | `playing` field is `true` |
| Playback — In Review | `playbackMode` field is `"review"` |
| App — Controls Locked | App has locked controls via `setLocked` / Lock tile |

## Variables

Per camera (label prefix, e.g. `C`): every field in `ALL_FIELD_NAMES` (45), `rec_state`, `rec_time` (local 1s tick), `battery`, `media_minutes`, `latency`, `model`, `connection`, `id`; playback: `pb_clip`, `pb_clip_number`, `pb_clip_count`, `pb_position` (m:ss), `pb_duration` (m:ss), `pb_mode`.

Global: `current_page`, `radio_bars`, `halow_signal_dbm`, `locked`.

## What's unverified

- Never run inside a real Companion instance (no GUI on build host).
- `step` on level fields multiplies `by` × `field.step` (e.g. `by: -1` on kelvin = −100 K) — not confirmed against a running server.
- `node26` runtime requires Companion ≥ 4.1; change to `"node22"` for older.
