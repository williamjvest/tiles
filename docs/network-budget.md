# Tiles — Network Budget

**Measured**: ILME-FX3 on a LAN via SSH tunnel (aes128-ctr), 2026-10-09.  
**Fixtures**: `fx3-idle-75s-ssh-events-2026-10-09.jsonl`, `fx3-idle-75s-ssh-2026-10-09.jsonl`,  
`fx3-rec-hold-start/stop-2026-10-09.jsonl`, `fx3-propinfo-full.bin`, `fx3-propinfo-changed.bin`.

---

## Framing assumptions

Every PTP-IP packet travels as one libssh2 `channel-data` message (aes128-ctr, hmac-sha1):

| Layer | Overhead |
|---|---|
| SSH channel-data header | 4 + 1 + 1 + 4 + 4 = 14 B |
| SSH padding (avg) | 8 B |
| SSH MAC (hmac-sha1) | 20 B |
| **SSH per PTP-IP packet** | **~42 B** |
| TCP + IPv4 per segment (20+20 B) | 40 B |

Network.framework uses Nagle's algorithm by default (TCP_NODELAY off), so small PTP-IP frames
are coalesced into fewer TCP segments. This is the right setting for bandwidth efficiency.

SSH keepalive (`libssh2_keepalive_config`, 60 s interval): ~68 B overhead, negligible.

---

## Connect sequence (one-time per session)

| Step | PTP-IP payload |
|---|---|
| PTP-IP Init handshake (4 packets) | 112 B |
| SDIO_Connect × 3 | ~150 B |
| SDIO_GetExtDeviceInfo | ~200 B |
| SDIO_OpenSession | ~40 B |
| GetAllExtDevicePropInfo (full) | **9 511 B** (measured, `fx3-propinfo-full.bin`) |
| GetDisplayStringList × 2 | ~600 B |
| GetDeviceInfo | ~80 B |
| **Total PTP-IP** | **~10.7 KB** |
| + SSH framing (~60 msgs × 42 B) | ~2 520 B |
| + TCP/IP (~60 segs × 40 B) | ~2 400 B |
| **On-wire total** | **~15.6 KB** |

At 64 kbit/s (8 KB/s), PTP-IP transfer alone takes ~1.3 s; SSH handshake adds ~2 s → **~3.3 s total**
(ShapedLinkTests `slowLink` measured 3.3 s at 64 kbit/s / 300 ms RTT with the fake camera's smaller dataset;
the real FX3's 14 KB connect phase adds ~1.7 s at that rate).

---

## Idle steady-state (post-connect)

### Measurement: event-driven (current), 75 s capture

| Metric | Value |
|---|---|
| PTP-IP payload | 4 258 B in 70.9 s steady-state |
| PTP-IP rate | **60 B/s** |
| Packets | 57 in 70.9 s = 0.8 pkt/s |

**Steady-state pattern** (repeats every ~10 s driven by the camera):

1. Camera sends `Probe_Request` (12 B) every ~10 s — we respond `Probe_Response` (8 B) + camera acks (8 B) = **28 B PTP-IP**
2. Our safety-net poll fires: `Cmd_Request` (26 B sent) → `End_Data` (438 B recv) + housekeeping = **~493 B PTP-IP per poll**
3. Occasionally a `SDIE_DevicePropChanged` event arrives (~18 B) and triggers an event-driven changed-only fetch.

The camera's own 10 s keepalive probes keep the link alive regardless of our poll interval.
Our probe (`probeInterval` 4 s, `probeTimeout` 4 s, checked every second) goes out once the link has been quiet for
4 s, and the link is failed if nothing at all comes back within 4 s, so a silent link is noticed within ~8 s. At idle
that's about two of our probes per camera probe: 8 B each way of PTP-IP, ~200 B a probe with SSH and TCP framing,
roughly 40 B/s.

---

## Per-action costs

| Action | PTP-IP payload | On-wire estimate |
|---|---|---|
| Connect (see above) | ~10.7 KB | ~15.6 KB |
| REC start (command + confirmation polls, post-connect) | ~1 000 B | ~1 700 B |
| REC stop | ~1 000 B | ~1 700 B |
| One control set (ISO / kelvin / shutter angle, etc.) | ~26 B cmd + 439 B resp = ~465 B | ~820 B |
| Option-driver set (codec / framerate / baseISO → full re-read) | ~9 551 B | ~10 400 B |
| Safety-net poll (changed-only, 30 s interval) | 465 B | ~821 B |
| Camera keepalive probe exchange (every ~10 s) | 28 B | ~152 B |
| Live view frame, Low quality (0xD26A=0x01) [measured FX3 2026-10-09] | 6835 B JPEG avg | **~7249 B** avg (~58 kbit/s at 1 fps) |
| Live view — tile visible, current page, app active | ~7249 B/frame @ 1 fps = **~58 kbit/s** | Stream shared; tile + sheet never fetch in parallel |
| Live view — tile off-page, app backgrounded, or sheet closed | **0 B/s** | Stream stopped; stopLiveView() called on camera |

---

## Resilience findings

Tests in `ShapedLinkTests.swift`:

| Scenario | Result |
|---|---|
| 64 kbit/s, 300 ms RTT: connect | ✓ connects in ~3.3 s (fake cam); real FX3 ~5 s |
| 64 kbit/s, 300 ms RTT: REC confirm | ✓ confirmed in ~1.5 s |
| Link cut → reconnect | ✓ `CameraController` reconnects autonomously (1, 2, 4…30 s backoff) |
| REC pending when link drops | ✓ fails with "Lost the camera" — never stuck |
| REC after reconnect | ✓ works correctly |
| Two overlapping `connect()` calls | ✓ one session wins, no leaked transport |
| 20% packet loss (new `dropRate` in `ShapedLink`) | ✓ REC confirms or fails explicitly, never stuck |
| Link closes (connection canceled) | ✓ seen at once |
| Link goes silent (connections open, nothing forwarded) | ✓ noticed within `probeInterval + probeTimeout`: a probe needs an answer. Before 2026-10-11 nothing checked for one, and a pulled iPad cable took 30+ s |
| Camera silent mid-fetch (`killAfterTransactions`) | ✓ `transactionTimeout` fires; connection fails cleanly |

REC is **never optimistic**: the backend reads `0xD21D` before clearing the pending request.  
A timeout re-reads recording state rather than resending (never double-fires a REC command).

---

## Blackmagic (REST and WebSocket)

Measured against the fake PYXIS (`connectAndIdleBudget`) and the real one over HaLow:

| Action | On-wire |
|---|---|
| Connect: six REST reads, then one subscribe burst on the WebSocket | ~4 KB up, ~7 KB down |
| Idle | Pushes when something changes, the latency ping, three REST reads a minute (the timecode twice, and dynamic range, which the camera doesn't push), and a preset read a minute (four requests, ~2.6 KB down: status text, what it shows, the de-squeeze) |
| A setting through a preset (status text, what it shows, de-squeeze) | The state saved and read (~2.6 KB down), the one section changed sent back (~100–200 B up), loaded, then read until the change shows (~2.6 KB down each read), about 1.2 s over USB-C |
| One control set | One REST PUT; the change comes back as a push |
| Live view, Low (Tiles' platform: 1.5 Mbps configured at 1080p30, 1 Mbps at 720p30) | **~1.6 Mbps** measured at 1080p24 |
| Live view, High (4 Mbps at 1080p30) | ~4 Mbps as configured; not measured |
| Live view closed | 0: the receiver stops at once; for the minute the camera's stream lingers it only retries the connection, every ~10 s |

## ARRI (Web Remote over HTTP)

Built before a camera (2026-10-22), so these are the design's numbers, against `FakeArriCamera` and `mock_alexa.py`:

| Action | On-wire |
|---|---|
| Connect | `all.cgi` (the mock's ALEXA Mini: 5 KB; a real camera's size is a capture-day number) and the page script (the mock's: 5 KB; a real one's is larger), the script kept per camera and revalidated with its ETag (a 304) after that |
| Idle | One `update.cgi?id=` held open: nothing while the camera is quiet; each answer carries what changed (one that only moves the counter is fetched with `all.cgi`). Answers are paced to stay near 64 kbit/s (`ArriCameraBackend.trafficBudget`). One `all.cgi` a minute of quiet, for ranges and the link check |
| No long poll | `all.cgi` every max(2 s, its size × 8 / 64 kbit/s) |
| One control set | One `set.cgi` (~100 B up); the change comes back on the long poll. A frame rate, sensor mode or codec change adds one `all.cgi`, for the ranges it moves |
| REC, playback | One `call.cgi` each, and one `all.cgi` when REC or playback starts or stops (the read-only flags rolling sets) |

## Open items

- **Real HaLow 2 MHz measurements**: all numbers above are from 802.11 Wi-Fi via SSH tunnel.
  Field-link capacity and latency at 2 MHz HaLow (≤1 Mbit/s, potentially >300 ms RTT) still to measure.
  Budget looks comfortable at ~60 B/s steady-state (Wi-Fi); connect time is the constraint at narrowest channels.
- **SSH compression**: libssh2 supports zlib compression, which could reduce the 9.5 KB full-read by
  ~30–50% at the cost of CPU. Not implemented; prop data is mostly binary, marginal gain.
- **TCP_NODELAY**: deliberately left off (Nagle enabled). Enabling it would fragment small PTP-IP frames
  into individual TCP segments and increase overhead. The current Nagle-on default is correct.
