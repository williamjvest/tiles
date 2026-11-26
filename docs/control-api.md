# Tiles — Control API

A local WebSocket + HTTP server that lets Stream Deck, Bitfocus Companion, and other tools
control cameras through the app.

**Off by default.** Enable in Settings → Control API. On iPhone and iPad the server only runs
while the app is in the foreground.

**Bonjour service**: `_twcc._tcp` — advertised when the server is running so LAN tools can
discover it automatically.

**Fixed ports** — survive app restarts:

| Port | Protocol | Purpose |
|------|----------|---------|
| **51800** | WebSocket (`ws://`) | Main channel — state subscriptions and commands |
| **51801** | HTTP (`http://`) | `GET /state`, `POST /command`, `POST /app` |

---

## Authentication

The pairing token is generated once and stored in the Keychain (Settings → Control API → Copy / Regenerate).  
Regenerating the token closes every open WebSocket connection.

The API is plain HTTP and WebSocket, for a local network you trust: the token crosses it unencrypted, so anyone on
that network who can see the traffic can see it and use it, REC included. Turn the API on only where that's so (a
camera network, not a public Wi-Fi), and regenerate the token if it may have been seen. It's off until turned on.

**HTTP**: `X-TWCC-Token: <token>` header. Missing or wrong → 401.

**WebSocket (subscribe path)**: send `auth` immediately after connecting; bad token closes the socket.

**WebSocket (inline token)**: send `token` inline on any `command` message. The socket stays open on failure.

---

## Cameras and fields

Every camera carries a full `fields` dict, one entry per control.

### Field shapes

**Choice** (discrete options list):

```json
{ "value": 1600, "options": [800,1000,1250,1600,2000,2500,3200], "writable": true, "pending": null }
```

**Level** (continuous range):

```json
{ "value": 5600, "min": 2500, "max": 9900, "step": 100, "writable": true, "pending": null }
```

**Record** (recording control):

```json
{ "value": "idle", "writable": true, "startedAt": null, "request": null, "failure": null }
```

`value` is `"idle"` | `"recording"` | `"unknown"`. When the camera is not connected, `writable` is `false` and `value` is `"unknown"`.

### All fields

| Field | Shape | Notes |
|-------|-------|-------|
| `record` | record | Always present |
| `iso` | choice Int | |
| `baseISO` | choice Int | |
| `shutterMode` | choice `"angle"`/`"speed"` | |
| `shutterAngle` | choice Double | |
| `shutterSpeed` | choice String | e.g. `"1/50"` |
| `wbPreset` | choice String | |
| `kelvin` | level | 2500–9900 K, step 100 |
| `tint` | level | |
| `iris` | choice Double | f-number |
| `ndPreset` | choice String | Cinema-line only |
| `variableND` | level | Cinema-line only |
| `frameRate` | choice String | e.g. `"23.98"` |
| `frameRateVariable` | choice Bool | S&Q (Sony) or off-speed (Blackmagic) on/off |
| `offSpeedRate` | choice Double | The sensor's frame rate while `frameRateVariable` is on (Blackmagic) |
| `dynamicRange` | choice String | e.g. `"Film"`, `"Video"` (Blackmagic) |
| `resolution` | choice String | |
| `codec` | choice String | |
| `bitrate` | choice String | |
| `desqueeze` | choice String | Blackmagic: `"None"`, `"1.33x"` … `"2.0x"`, set through a preset (below) |
| `lut` | choice String | Blackmagic: the LUT's file name, out of the ones the app has seen the camera use. VENICE: what the Monitor out and VF show (`s709`, `R709(800%)`, `Look`). ARRI: the look file |
| `look` | choice Bool | Monitor LUT on/off. Blackmagic, VENICE and ARRI: on every output (see below) |
| `falseColor` | choice Bool | Blackmagic: on every output (see below) |
| `zebra`, `focusAssist`, `frameGuides`, `frameGrids`, `safeArea`, `cleanFeed`, `statusText` | choice Bool | Blackmagic, on every output (see below) |
| `zebraLevel` | choice Int | Highlight zebra level, percent (Blackmagic) |
| `frameGuideRatio` | choice String | e.g. `"2.39:1"` (Blackmagic) |
| `focusMode` | choice String | The camera's AF / MF: `"AF-C"` or `"MF"` on an FX3; `"AF"` or `"MF"` on an FX5, FX6 or BURANO (read-only where the lens decides) |
| `colorBars` | choice Bool | |
| `hdmiInfo` | choice Bool | The camera's info on its HDMI output; `false` is clean HDMI (Sony) |
| `gridLines` | choice Bool | Grid lines on the camera's display (Sony) |
| `ndMode` | choice String | `"Step"` or `"Variable"`: how the ND moves (BURANO) |
| `tally` | choice String | `"Off"`, `"Green"` or `"Red"`: the camera's tally lamps, one at a time (BURANO); a Blackmagic camera's None, Preview and Program |
| `call` | choice Bool | CALL on the camera's display (BURANO) |
| `colorGamut` | choice String | `"S-Gamut3.Cine"` or `"S-Gamut3"` (BURANO, FX3) |
| `userFrameA`, `userFrameB` | choice String | What frame line set A or B shows of the user frame lines: `"Off"`, `"1"`, `"2"` or `"1 + 2"`; `"Off"` or `"On"` on a camera with one (VENICE) |
| `shootingMode` | choice String | `"Custom"`, `"Flexible ISO"`, `"Cine EI Quick"`, `"Cine EI"`: each brings its own white balance, look and exposure; refused during a take (FX6) |
| `gain` | choice Int | Gain in dB, where the camera works in dB rather than ISO: an FX6 in Custom, −3 to 30. `iso` is absent then |
| `baseSensitivity` | choice String | `"Low"`, `"Mid"` (an FX5) or `"High"`: the base where the camera works in dB (an FX6 in Custom), or in ISO (an FX5 in Custom), as `baseISO` is in ISO |
| `steadyShot` | choice String | `"Off"`, `"Standard"`, `"Active"`, `"Dynamic Active"`: the camera's image stabilisation (an FX5) |
| `imagerMode` | choice String | The camera's own list, e.g. `"FF 5K 16:9"`, `"FFc 4.5K 17:9"`, `"S35 3.2K 16:9"`: the part of the sensor that records (an FX5); refused during a take, and it can change the resolution |
| `subjectRecognition` | choice String | What autofocus looks for, the camera's names: `"Face/Eye Priority AF"`, `"Face/Eye Only AF"`, `"Off"` (an FX3, FX6, BURANO); `"Human Priority AF"`, `"Human Only AF"`, `"Animal/Bird Prio. AF"`, `"Animal Priority AF"`, `"Bird Priority AF"`, `"Off"` (an FX5) |
| `focusArea` | choice String | Where autofocus looks: `"Wide"`, `"Zone"`, `"Flexible Spot"` (an FX5, FX6), and an FX3's `"Center"`, `"Flexible Spot S"` … |
| `afTransitionSpeed` | choice Int | How quickly autofocus moves to a new subject, 1 (slow) to 7 (fast) |
| `afSubjectShift` | choice Int | How readily autofocus leaves its subject for another, 1 (locked on) to 5 (responsive) |
| `afAssist` | choice Bool | The focus ring taking over from autofocus while it's turned |
| `recordedLUT` | choice Bool | The LUT baked into the recording (an FX6's LUT for internal rec); not settable during a take. `look` never reaches it |
| `proxy` | choice Bool | Proxy recording (FX6); not settable during a take |
| `ecs` | choice Bool | Extended Clear Scan on/off (FX6). `{"step": "ecsFrequency", "by": 1}` steps its frequency up a notch, `-1` down, while it's on (the camera's own steps: there's no frequency to set) |
| `irisAuto` | choice Bool | The camera sets the iris itself; `iris` is read-only meanwhile (FX6) |
| `ndAuto` | choice Bool | The camera sets the ND density itself, which is read-only meanwhile (FX6) |
| `isoAuto` | choice Bool | The camera sets the gain itself (AGC): `iso`, or `gain` in Custom, shows what it picked and is read-only meanwhile (FX6) |
| `imageFlip` | choice Bool | |
| `clipFlag` | choice String | `"none"` | `"ok"` | `"ng"` | `"keep"` |
| `timecodeDuration` | choice Bool | `true` while the camera's timecode display shows the take's duration, `false` for timecode (VENICE) |
| `playbackMode` | choice String | `"live"` or `"review"`: the live picture or recorded clips, on a camera that has to be put into playback first (its Live \| Review switch). `review` plays the last take straight away. Not into `review` while recording |
| `playing` | choice Bool | Playing a clip. `set` plays or pauses, `toggle` flips. Only on a camera that says whether it's playing (not the FX3); writable where it takes the clip commands (on a camera with `playbackMode`, in review) |

A field absent from `fields` means the camera doesn't have that control. Clients must never invent values. The app's
Camera Menu presses (a BURANO's MENU, Home and multi-selector) aren't settings, so they aren't fields.

An FX6's lens motors and assignable buttons, and push autofocus, are commands, not fields:

```json
{"type": "command", "id": "9", "target": {"camera": "B"}, "command": {"drive": "focus", "speed": 2, "seconds": 0.4}}
{"type": "command", "id": "10", "target": {"camera": "B"}, "command": {"press": "assignable", "button": 1}}
{"type": "command", "id": "11", "target": {"camera": "F"}, "command": {"press": "autofocus"}}
```

`drive` is `"focus"` (+ farther) or `"zoom"` (+ tele) at a speed up to the camera's (8 on an FX6), for `seconds`, half a
second if left out and a second at most: the app stops the motor at the end, so no drive runs on without a stop. Hold
a deck button by sending it again before the last one ends (every 250 ms with `"seconds": 0.5` is plenty): a newer drive
of the same motor takes over with no stop between. Speed 0 stops it at once: send it when the button is let go. `press` presses an assignable button by its number on the
body (10 is the lens's), only where it's set to a function the app has checked on a camera (S&Q Motion, Base ISO/Sens.,
Rec Review), never one set to Last Clip Del.; otherwise `rejected` with what it's set to. `"press": "autofocus"` is
the Autofocus tile's push: a Blackmagic camera's one-shot, an FX5's Push AF, held a moment and let go. Only while focus
is manual: with `focusMode` on AF it's `rejected` ("autofocus is on"), as on a camera with no push. All three answer
`accepted`. `{"press": "still"}` is the Grab Still tile: a still to the camera's own card, on a camera that takes one
over the network (a Blackmagic camera); `rejected` ("no still capture on this camera") elsewhere. `accepted` says it
was sent; whether the camera saved it shows in the camera's state as `canGrabStill` and `lastStill`.

`canGrabStill` is `true` on a camera that supports still capture while connected; absent when it doesn't. `lastStill`
is `{"saved": true}` when the camera saved the still, or `{"saved": false, "message": "…"}` with the camera's own
reason when it didn't. Both appear beside `fields` in `hello`, `snapshot`, `cameras` and `changes`.

A camera that plays back also has `playback` beside `fields` (see Playback, below): the clip, where it is, and the
transport commands the camera takes now.

A Blackmagic camera sets its overlays output by output (LCD, USB-C monitors, SDI). Over the API, `look`,
`falseColor` and the overlay fields cover every output that reports them: `true` only when all of them show it, so
setting `true` turns it on where it's still off. An output on clean feed shows no overlay but its LUT, so it's left
out of `falseColor` and the overlay fields (not counted, not written); with every output on clean feed they're
`writable: false`. The app's Monitoring Options, and its tiles set to one output, set them one output at a time.

A PYXIS's `statusText` and `desqueeze` aren't in its own API: the app sets them through a preset of the camera's state
(docs/pyxis-controls.md, Presets). A change takes a second or two, and they're `writable: false` during a take.

---

## WebSocket protocol

### 1. Connect and authenticate

```
ws://host:51800/
```

Immediately send:

```json
{"type":"auth","id":"1","token":"demo-token"}
```

Response on success:

```json
{
  "type": "hello",
  "id": "1",
  "api": 1,
  "app": "Tiles",
  "appVersion": "1.0",
  "cameras": [
    {
      "id": "4F47C6FD-37C1-41AA-AEDB-55BFD411D21E",
      "label": "C",
      "model": "ILME-FX3",
      "color": "yellow",
      "demo": true,
      "connection": "connected",
      "latencyMs": 38,
      "battery": 76,
      "mediaMinutes": 142,
      "fields": {
        "record": {"value":"idle","writable":true,"startedAt":null,"request":null,"failure":null},
        "iso": {"value":800,"options":[200,250,320,400,500,640,800,1000,1250,1600,2000,2500,3200],"writable":true,"pending":null},
        "shutterAngle": {"value":180.0,"options":[360,300,270,240,216,210,180,172.8,150,144,120,90,86.4,72,45,30,22.5,11.25,5.6],"writable":true,"pending":null},
        "playbackMode": {"value":"live","options":["live","review"],"writable":true,"pending":null}
      },
      "playback": {"commands":["review"]}
    }
  ],
  "pages": [
    {"id":"FAD29216-0143-4CE2-9B5C-B58F25C30A59","name":"All","cameras":["4F47C6FD-37C1-41AA-AEDB-55BFD411D21E"],"linking":false,"links":["frameRate","shutter","whiteBalance","record"],"current":true}
  ],
  "currentPageID": "FAD29216-0143-4CE2-9B5C-B58F25C30A59",
  "locked": false
}
```

Bad token → error + socket closed:

```json
{"type":"error","id":"1","code":"auth","message":"bad token"}
```

### 2. Subscribe

```json
{"type":"subscribe","id":"2"}
```

Response — current snapshot then diffs:

```json
{
  "type": "snapshot",
  "cameras": [ /* full camera list */ ],
  "pages": [ /* full page list */ ],
  "currentPageID": "..."
}
```

Subsequent changes:

```json
{
  "type": "changes",
  "camera": "C",
  "cameraID": "4F47C6FD-37C1-41AA-AEDB-55BFD411D21E",
  "update": {
    "latencyMs": 41
  }
}
```

Only changed keys appear in `update`. A `null` value clears `pending`.

Page changes: `{"type":"pages","pages":[...],"currentPageID":"..."}` — full list.

Camera list changes (a camera added, removed, renamed, recolored or reconnected): `{"type":"cameras","cameras":[...]}` — full list.

The app's padlock: `"locked"` in `hello` and `snapshot`, and on a change (the app's padlock, its Lock tile, or a
client's `setLocked`) `{"type":"lock","locked":true}`.

A camera's `playback` goes in `update` whole when any part of it changes, or `null` when it goes (see Playback).

`radio` in `hello` and `snapshot` is always `null` for now, and no `radio` message is sent.

### 3. Commands

#### set — absolute value

```json
{
  "type": "command",
  "id": "3",
  "target": {"cameraID": "4F47C6FD-37C1-41AA-AEDB-55BFD411D21E"},
  "command": {"set": "iso", "value": 1600}
}
```

#### step — relative move

```json
{
  "type": "command",
  "id": "4",
  "target": {"camera": "C"},
  "command": {"step": "iso", "by": 1}
}
```

`by` is +/- integer steps through `options` (choice) or `step` units (level). Clamps at the ends.

#### toggle — flip a boolean field

```json
{
  "type": "command",
  "id": "5",
  "target": {"camera": "C"},
  "command": {"toggle": "falseColor"}
}
```

REC toggle on a page/all target with mixed states → `rejected` ("mixed REC states"). Always use `set` for cross-camera REC.

#### cycle — next option (wraps)

```json
{
  "type": "command",
  "id": "6",
  "target": {"pageID": "FAD29216-0143-4CE2-9B5C-B58F25C30A59"},
  "command": {"cycle": "wbPreset"}
}
```

#### Targets

| Target | Meaning |
|--------|---------|
| `{"cameraID":"UUID"}` | One camera by UUID |
| `{"camera":"C"}` | One camera by label (resolved at command time) |
| `{"pageID":"UUID"}` | Every camera on that page |
| `{"currentPage":true}` | Every camera on the current page |
| `{"all":true}` | Every camera |

Unknown target → `error` with `code: "unknownTarget"`.

#### Link mode

`"link": "app"` (default) — command follows the page's link settings, same as a tap in the app.  
`"link": false` — this camera only, even if link is on.

Step/cycle/toggle is resolved once on the addressed camera; linked peers receive the absolute result.

#### Result message

```json
{
  "type": "result",
  "id": "3",
  "results": [
    {"camera": "C", "status": "confirmed", "field": "iso", "value": 1600}
  ]
}
```

One entry per camera touched (including linked peers). `status`:

| Status | Meaning |
|--------|---------|
| `confirmed` | Camera reports the requested value |
| `failed` | Camera refused or backend error (`error` has the message) |
| `timeout` | No confirmation in 5 s |
| `rejected` | Not sent — field absent, not writable, value out of range, camera disconnected, REC already in progress |
| `superseded` | A newer command replaced this one; camera didn't end at this value |
| `accepted` | HTTP `"wait": false` — sent, not yet confirmed; and every `playback` command that was sent (a press has nothing to confirm) |

### 4. App actions

```json
{"type":"app","id":"7","action":"showPage","pageID":"UUID"}
```

```json
{"type":"app","action":"setLinking","pageID":"UUID","enabled":true}
```

```json
{"type":"app","action":"setLink","pageID":"UUID","group":"whiteBalance","enabled":false}
```

Groups: `whiteBalance`, `frameRate`, `shutter`, `record`.

```json
{"type":"app","id":"8","action":"setLocked","enabled":true}
```

Locks or unlocks the app's controls, as the padlock and the Lock tile do: locked, the app's tiles don't take a touch.
The API's own commands still work (a deck is a deliberate controller). `hello` and `snapshot` carry `"locked"`, and a
change is broadcast as `{"type":"lock","locked":true}`.

### 5. Ping / pong

```json
{"type":"ping","id":"9"}
```

```json
{"type":"pong","id":"9"}
```

Answered before `auth` too. A link that dies quietly (out of radio range, the device asleep) can keep a socket open
for minutes before TCP notices, so a client should ping every few seconds and treat a silent socket as closed: the
Stream Deck plugin pings every 5 s and drops the socket after 12 s with nothing from the app. The app drops a client
it can no longer reach within about 30 s (TCP keepalive and a limit on unacknowledged sends).

### 6. Inline token (Companion Generic WebSocket)

Send the token on any `command` message without a prior `auth`:

```json
{
  "type": "command",
  "token": "demo-token",
  "target": {"camera": "C"},
  "command": {"toggle": "record"}
}
```

Bad inline token → error frame, socket stays open.

---

## HTTP endpoints

### GET /state

Returns the current snapshot. Equivalent to the WS `snapshot` message.

```bash
curl -H "X-TWCC-Token: demo-token" http://192.168.1.100:51801/state
```

Response: same shape as WS `snapshot`.

### POST /command

Wait for result (default, up to 6 s):

```bash
curl -X POST \
  -H "X-TWCC-Token: demo-token" \
  -H "Content-Type: application/json" \
  -d '{"target":{"camera":"C"},"command":{"set":"iso","value":1600}}' \
  http://192.168.1.100:51801/command
```

Response:

```json
{"type":"result","results":[{"camera":"C","status":"confirmed","field":"iso","value":1600}]}
```

Fire-and-forget (`"wait": false`):

```bash
curl -X POST \
  -H "X-TWCC-Token: demo-token" \
  -H "Content-Type: application/json" \
  -d '{"target":{"camera":"C"},"command":{"toggle":"record"},"wait":false}' \
  http://192.168.1.100:51801/command
```

Response: `{"type":"result","results":[{"camera":"","status":"accepted"}]}`

### POST /app

```bash
curl -X POST \
  -H "X-TWCC-Token: demo-token" \
  -H "Content-Type: application/json" \
  -d '{"action":"showPage","pageID":"FAD29216-0143-4CE2-9B5C-B58F25C30A59"}' \
  http://192.168.1.100:51801/app
```

Response: the action's result, as the WebSocket gets it (`{"type":"result","results":[{"camera":"","status":"confirmed","field":"page"}]}`),
or `400` with the `error` when it's refused (a missing `enabled`, a page that isn't there).

---

## End-to-end example (websocat)

Run the dev harness first:

```bash
cd Packages/CameraKit
TWCC_API_TOKEN=demo-token swift run twcc-api-demo
```

Then in another terminal:

```bash
websocat ws://127.0.0.1:51800/
```

Exchange (→ = sent, ← = received):

```
→ {"type":"auth","id":"1","token":"demo-token"}
← {"type":"hello","id":"1","api":1,"app":"Tiles","appVersion":"1.0",
   "cameras":[{"id":"...","label":"C","model":"ILME-FX3","color":"yellow","demo":true,
               "connection":"connected","latencyMs":38,"battery":76,"mediaMinutes":142,
               "fields":{"record":{"value":"idle","writable":true},"iso":{"value":800,...},...}},...],
   "pages":[{"id":"...","name":"All","cameras":["...","..."],"linking":false,"links":[...],"current":true},...]}

→ {"type":"subscribe","id":"2"}
← {"type":"snapshot","cameras":[...],"pages":[...],"currentPageID":"..."}

→ {"type":"command","id":"3","target":{"camera":"C"},"command":{"set":"iso","value":1600}}
← {"type":"result","id":"3","results":[{"camera":"C","status":"confirmed","field":"iso","value":1600}]}
  (after ~150ms, mock camera confirms)
← {"type":"changes","camera":"C","cameraID":"...","update":{"latencyMs":41}}

→ {"type":"command","id":"4","target":{"camera":"C"},"command":{"step":"shutterAngle","by":1}}
← {"type":"result","id":"4","results":[{"camera":"C","status":"confirmed","field":"shutterAngle","value":172.8}]}

→ {"type":"command","id":"5","target":{"camera":"C"},"command":{"toggle":"record"}}
← {"type":"result","id":"5","results":[{"camera":"C","status":"confirmed","field":"record","value":"recording"}]}
  (after ~300ms, mock camera confirms recording start)

→ {"type":"app","id":"6","action":"showPage","pageID":"FAD29216-..."}
← {"type":"result","id":"6","results":[{"camera":"","status":"confirmed","field":"page"}]}

→ {"type":"ping","id":"7"}
← {"type":"pong","id":"7"}
```

---

## Behavior rules

- **Never optimistic.** `confirmed` only when the camera's own state matches.
- **REC is absolute.** `record(true)` = "make sure it's recording". Already recording → no-op.
- **REC is never coalesced.** A second REC command while one is in flight is `rejected` ("REC change in progress").
- **Changes only.** No periodic re-sends. `changes` messages are ~100 bytes typical.
- **Latency.** The app refreshes `latencyMs` with a real change, or on its own at most every 5 s. A snapshot carries it
  only while the camera is connected (and, after a reconnect, once the first new round trip is in). A `changes` message
  never announces a field going away, so a client drops `latencyMs` itself when `connection` isn't `connected`. The
  Companion module doesn't yet: its latency variable keeps the last value.
- **Offline.** Disconnected camera: all fields `writable: false`, `record.value = "unknown"`, in-flight commands fail with `"disconnected"`.
- **iOS foreground.** The server stops when the app backgrounds. Clients reconnect to the same fixed ports on resume.
- **Token rotation.** Regenerating the token in Settings closes every WebSocket; clients must re-authenticate.

---

## Error codes

| Code | Meaning |
|------|---------|
| `auth` | Token missing or wrong |
| `badRequest` | Malformed JSON or missing required field |
| `unknownTarget` | Target camera/page not found |
| `unknownField` | Field name not recognized |

---

## Playback

A camera that plays back (its Playback tile) has a `playback` object beside its `fields`, in `hello`, `snapshot`,
`cameras` and, whole, in `changes` when any part of it changes (`"playback": null` when it goes):

```json
"playback": {
  "clip": "A001C003",
  "clipNumber": 2,
  "clipCount": 3,
  "position": 12.4,
  "duration": 31.0,
  "commands": ["togglePlay", "play", "pause", "next", "previous", "fastForward", "rewind", "live", "review"]
}
```

`clip`, `clipNumber`, `clipCount`, `position` and `duration` (seconds) are there only when the camera says.
`commands` are the transport commands the camera takes now, from what it can do and where it is (the Playback tile's
buttons): a camera that has to be put into review takes the clip commands only in review, and `review` only while it
isn't recording; offline, none. `play` and `pause` are there only on a camera that says whether it's playing, and are
absolute: `play` while it plays is accepted and not sent, since on a Sony or a VENICE the button is one toggle.
The held scans are there only on a camera played through its own buttons, and not on a VENICE, which opens its clip
list for an `endScan`.

A transport command:

```json
{"type":"command","id":"9","target":{"camera":"A"},"command":{"playback":"next"}}
```

```json
{"type":"command","id":"10","target":{"camera":"A"},"command":{"playback":"skip","by":-5}}
```

| `playback` | Does |
|---|---|
| `togglePlay`, `play`, `pause` | Play or pause the clip |
| `stop` | Stop (Blackmagic: pause where it is; Sony: halt) |
| `next`, `previous` | The next or previous clip |
| `fastForward`, `rewind` | One press of the camera's FF or REW |
| `scanForward`, `scanBackward`, `endScan` | Fast-forward or rewind until `endScan` (an arrow held down) |
| `skip` | Seek `by` seconds, forward or back |
| `recReview` | Play the last take back (Sony) |
| `review`, `live` | Into recorded clips, or back to the live picture |

A result's entry is `accepted` when the command was sent (a transport press has nothing to confirm), or `rejected`
with an `error`: `unsupported` (not in the camera's `commands` now), `camera not connected`, or
`skip needs by, in seconds`. Playback doesn't link: a command goes to the cameras targeted, no further.

`playbackMode` and `playing` are fields too, for a client that sets and lights a key the way it does every other
field. `playbackMode` is a string, so a Live/Review key `cycle`s it (two options: it flips); `toggle` is for bools.
