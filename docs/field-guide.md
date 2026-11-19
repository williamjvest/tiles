# Tiles Field Guide

For camera assistants and DITs on set.

## Camera profiles

Profiles are saved cameras you can add in one tap. Set them up once in **Settings → Camera Profiles**; they appear at the top of Add Camera whenever you add a new camera. Adding or removing a camera from the dashboard never changes a profile.

To create a profile:
- **From Settings**: tap **Camera Profiles** → **Add Profile**. Fill in the name, address, type and credentials.
- **From an existing camera**: open **Settings** → tap the camera → tap **Save as Profile**.

## Add a camera

**On the FX3 first** (Sony's Help Guide, firmware 2.00 and later; older firmware calls it PC Remote Function):
- Put it on the same Wi-Fi as the phone or iPad: MENU → Network → Wi-Fi → **Wi-Fi Connect** On, then **Access Point
  Set.** to join the network. **Display Wi-Fi Info.** on the same menu shows its IP address.
- Turn on remote control: MENU → Network → Cnct./Remote Sht. → Remote Shoot Function → **Remote Shooting** On.
- A phone connected to the camera through Sony's own app stops anything else controlling it: disconnect it.

Sony's pages: [Wi-Fi Connect](https://helpguide.sony.net/ilc/2210/v1/en/contents/TP1000843952.html),
[Remote Shooting](https://helpguide.sony.net/ilc/2210/v1/en/contents/TP1000884035.html),
[Wi-Fi Info](https://helpguide.sony.net/ilc/2210/v1/en/contents/TP1000884194.html),
[Access Authentication](https://helpguide.sony.net/ilc/2210/v1/en/contents/TP1001106325.html).

Then in Tiles:

1. Tap the gear icon → **Add Camera** (or **Add a Camera** on the first screen).
2. If you have profiles set up, tap one under **Profiles** to fill in the type, address, color and credentials automatically. A profile whose address is already on the dashboard shows **Added** and is disabled.
   **Color** is the camera's on every tile, its letter and its tab: one of the eight, or the eyedropper after them for
   any color (Tiles' color picker opens from it: pick from **Grid**, **Spectrum** or **Sliders**, or type a hex
   value; the **×** closes it, and tapping one of the eight goes back).
   On a HaLow mesh, once the app has found a node, **On the HaLow Mesh** lists what the nodes see (cameras that say
   who made them first); tap one to fill in its address, and its type when the camera says.
   Otherwise choose **Sony** (or **Blackmagic** — see below) and type the camera's IP address. Under **Camera**, pick
   **FX3 · FX30 · FX5 · FX6 · BURANO** or **VENICE · VENICE 2**; Tiles asks the address as you type it and picks for you,
   and says which it found (a camera that's off leaves it as it is). A VENICE: see "Adding a VENICE" below. An
   ALEXA: choose **ARRI** (see "Adding an ARRI camera" below).
3. **Access Authentication on** (SSH, the camera's default): enter the user name and password from the camera's
   **Access Authen. Info** screen (MENU → Network → Network Option). The app saves the camera's fingerprint the first
   time it connects.
4. **Access Authentication off** (pairing): leave the toggle off. Open **Pairing** on the camera
   (MENU → Network → Cnct./Remote Sht. → Remote Shoot Function) before you save. When the camera shows *"Allow pairing
   with the device? 'Tiles'"*, press OK on the camera body.

**An FX5 (and the FX6, BURANO, and Sony's other pro bodies) on a network.** The menu is laid out differently from the
FX3's:

1. Join the network: MENU → Network → **Wireless LAN** → Setting → **Station Mode** (or Wired LAN → Setting → On).
2. Turn remote control on, under that same network's menu: **Camera Remote Control → Enable**.
3. Read the login from Network → Network Setup → **Show Authentication**, and enter it in Tiles as for Access
   Authentication above.

**An FX5's live view comes through its stream:** it has no picture over Camera Remote, so Tiles sets one of its
RTMP destinations to itself ("Tiles") and starts the stream while live view is open. Turn streaming on once: MENU →
Network → Stream → **Setting → On**. It records as it streams. About 1.5 Mbps at Low, as a PYXIS's live view.

**If Camera Remote Control is grayed out**, the camera's USB is set to remote control, and the camera takes one
remote at a time. Set MENU → Technical → USB → **USB Cnct Mode (PORT1)** (and PORT2) to **Off**, and the network's
Camera Remote Control can be enabled (an FX5 keeps it grayed until USB is off). The other way round,
USB Remote on a Mac needs those network remotes off.

**Adding a VENICE or VENICE 2.** On the camera, set a password under Technical > Authentication (there's no factory
password; 8 or more characters, letters and numbers; the user name is `admin`), then Technical > Network > Setting =
LAN, LAN > DHCP On (or a fixed address), and **Set**. In Tiles: Sony → Camera **VENICE · VENICE 2** → the address,
user `admin` and that password. It talks to the camera the way its own Web Remote page does; RM/RCP Paint Control
off. The page it gets has every control the Web Remote has: REC, EI with the base ISO switch, shutter, ND, white
balance, frame rate with Select FPS, imager mode, codec, de-squeeze, iris (with a lens that reports it), the look, and
output by output (SDI 1/2, SDI 3/4, Monitor, VF, HDMI) the LUT, frame lines and status info; false color and peaking
on the Monitor and VF, zebra on the VF; color bars, sensor flip and playback. Tried on a VENICE 2
(camera firmware V4.00) over HaLow.

A VENICE takes one connection at a time: Tiles or its web page, not both, and the two connected together trip it up.
So Tiles has no Web GUI button: to use the camera's own page, quit Tiles first. After Tiles quits, the camera
takes a few seconds to let the next connection in. Changing the imager mode, the codec, the project rate or the
de-squeeze restarts the camera's picture (X-OCN to ProRes reboots it), so Tiles asks first. A setting the camera has
locked (the imager mode while recording, say) is grayed until it unlocks. The base ISO switch puts the EI on the new
base (800 or 3200): the camera itself would go back to the EI it last had on that base. Tap the timecode to switch the camera's own
display between timecode and the clip's duration (DUR). The naming sheet sets the camera ID, the reel and the camera
position (C, L, R). On SDI 3/4 the status info is the camera's one SDI overlay, shared with SDI 1/2.

- **The LUT** tile lists every look on the camera: s709, R709(800%) and the S-Log3 presets, then each user 3D LUT by
  its slot and file name. Picking one loads it and puts every output that shows a LUT on it; each output's switch (the
  tile's **Outputs**, or Monitoring Options) turns its LUT on or back to Log. **Load LUT onto camera…** (the end of the
  LUT list, or Settings → the camera) uploads a .cube into one of the 16 slots, as the camera's own page does.
- **False Color** is the camera's Exposure Assist, which lives on its assignable buttons: Tiles presses the button
  Monitor Exposure Assist or VF Exposure Assist is assigned to (the VENICE 2 tried had them on Assignable 2 and VF B).
  With neither assigned, there's no False Color tile: assign one on the camera, in its Assignable Button menu.
- **Color Bars** go through the menu, or the camera's own switch while that menu item is locked.
- An output the camera shows the same as another (HDMI or SDI 3/4 "Same as Monitor") shows that output's frame lines
  and overlays, grayed, and says so in Monitoring Options: set them on that output. Its LUT stays its own. The link
  comes from the outputs' formats, on the camera.

**Adding an ARRI camera (ALEXA Mini, Mini LF, ALEXA 35, AMIRA).** Tiles talks to the camera the way its own Web
Remote page does, and that has no login. Get the camera onto the network: its Ethernet (on an ALEXA Mini the ETH socket
is a 10-pin LEMO, so it needs ARRI's KC 153-S cable to RJ-45), or its Wi-Fi, which is on by default (the camera is
then 192.168.153.1, or joins a network in Wi-Fi client mode). Set the LAN IP under System > Network/WiFi (DHCP, or a
static address), and read it off INFO > Network info, which also shows the camera's Web Remote URL. In Tiles: **ARRI**
→ the address (or `mini-<serial>.local` on an ALEXA Mini).
Tiles says "This camera answered as an ALEXA Mini". The page it gets has REC, EI, shutter (angle and time), ND, white
balance (Kelvin and CC), sensor fps, sensor mode and codec, the look (which one, and on or off output by output),
frame lines, false color, zebra, peaking and overlays on each output (SDI 1, SDI 2, EVF, and MON on a Mini LF or
ALEXA 35), a true clean feed on each SDI (Clean Feed is the camera's SDI 1 / SDI 2 image: Clean, as it records, no
overlays or surround view; only one SDI can be Processed unless SDI 2 clones SDI 1, so the other's switch grays), the
lens's iris as the camera reads it, reel and camera letter, and playback. In Add Tile: **Color Bars** (the camera's own
SMPTE bars on SDI, in standby only; REC turns them off) and **Sensor Flip** (on is V+H, the camera upside down; any
flip set on the camera reads as on). Sensor flip flips the recording too, not just the monitors. ARRI's
names are on the tiles: EI, Look, Peaking. Not yet tried on a camera; the demos (Demo → ALEXA Mini, Mini LF, ALEXA 35)
show the page.

**On a Mac, a Sony or Blackmagic camera can be on a USB-C cable instead.** On a Sony camera: MENU → Setup → USB → USB
Connection Mode → **Remote Shooting**, then plug it into the Mac. Add Camera lists it under **On USB**; tap it. No
address, no login, and live view runs at the camera's own rate (about 24 fps) instead of the network's one frame a
second. A camera that's plugged in but in another USB mode says so. On an iPhone or iPad with USB-C, Add Camera →
**On USB** → **Find a Camera on USB** does the same through Apple's camera framework (it asks to control cameras the
first time).

A Blackmagic camera needs nothing set for the cable: plug it in and it's under **On USB** too, on a Mac, with nothing
to type. It still needs Remote Control or Network Access on, as on a network, and Add Camera
asks it which. Tiles finds it on its cable each time it connects, so any port does, and one that's unplugged
reconnects as soon as it's plugged back in. One Blackmagic camera by cable per device: two of them hand out the same
addresses, and Tiles says so. On an iPhone or iPad Tiles looks for what the camera announces over the cable, as
Blackmagic's own app does, but on the first try (2026-11-10, an iPhone) the camera never showed up there. Blackmagic's
manual has a phone on the camera's USB-C with its Personal Hotspot on (Settings → Personal Hotspot → Allow Others to
Join), and Trust tapped when the phone asks: the camera then joins the phone's hotspot, and Tiles finds it there too.
That hasn't been tried with a camera yet, so for a shoot connect an iPhone or iPad over the network (HaLow or Wi-Fi).
If you try the cable, the Activity Log (Settings → Report a Problem) afterwards says what the device saw.
A camera that won't connect says why in the bars at the top: tap them, and tap the camera to try again.

**Something wrong?** Settings → **Report a Problem** (on a Mac, Help → Report a Problem…): say what happened, and
Email Report opens a message to Toldwell in your mail app with the app's version, the device, each camera's model,
link and state, and the Activity Log attached. The Activity Log is what Tiles has done with its cameras since it
opened: each connect, why one failed, and live view starting, its first frame and what stopped it. Nothing goes until
you send it, and it carries no passwords or user names. Copy Report puts the same on the clipboard, for an email from
somewhere else or a GitHub issue.

On iPhone and iPad the screen stays on while a camera is connected or connecting, because a locked device
suspends Tiles, and that drops every camera.

## What the tiles do

Tiles and options come from the camera itself. A control the camera doesn't have isn't shown. A grayed control
is one the camera won't change right now (the FX3's bitrate under XAVC S-I, for example). Pickers only list what
the camera will take in its current mode: change the codec and the frame rates on offer change with it.


**REC** — tap to start or stop recording.
- Standby: dark circle with red ring labeled **REC**.
- Recording: solid red circle labeled **STOP**.
- The tile only changes when the camera confirms. While it waits, the badge reads **REC…** and the
  button doesn't take another tap.
- If the camera refuses (no card, card full) or never confirms, the badge reads **REC FAILED**.

**ISO / EI** — tap the number or the chevron to open a picker. Base ISO selector appears below when
the camera reports it. Tapping the current base ISO (e.g. 800 or 12800) returns the EI to that native
base — tap it even if EI already reads that value, and it will snap to native.

**ND** — the ND tile shows the camera's ND; tap it for the camera's list. Its **−** **+** step buttons are an option:
in edit mode, tap **Step − +** on the tile to switch them on or off (off unless switched on). **ND −** and **ND +**
are a step each as a whole tile, captioned ND, with the big − or + saying which way. Every page with an ND tile has
them beside it unless you take them off; on a page you've arranged yourself, add them from **Add Tile**.

**Shutter** — the dial and the value tile show the current shutter; tap to pick. The value tile has an
**Angle | Speed** switch (a small **ANG** / **SPD** chip when space is tight; the chips draw their labels in capitals).

**White Balance** — the Kelvin tile shows the current color temperature; tap to open the preset
picker: the same six Kelvin presets on every camera, 2800, 3200, 4300, 5000, 5600 and 6500K (those inside the
camera's range), then **Auto** where the camera has it, and on a VENICE the presets saved on the camera after them. On a Blackmagic camera Auto takes the white balance from the middle of the
picture once (fill it with a white or gray card). On a Sony it's the camera's AWB, and the tile says Auto until you
pick a Kelvin; the FX3 doesn't offer AWB in Cine EI, so there it isn't in the menu. A BURANO also lists **AWB**, its
one-push white balance: it measures the light once (fill the frame with a white or gray card) and the tile then shows the
Kelvin it found. The sliders tile shows **Temp** and
**Tint** sliders, one over the other, or side by side in a wide, short tile (a phone on its side). Double-tap a slider to reset: Temp
resets to 5600 K (daylight mark), Tint resets to 0. ‹ and › at the ends of a slider move it one camera step (100 K,
a quarter of tint, a third of a stop on iris); taps add up before the camera answers. After a drag, the knob stays
where you let go while the camera applies it.

**Iris** — horizontal slider through the f-stops the lens offers (full stops marked). Tap the f-number
to open a list.

**LUT** — shows the current LUT name. Tap the name to pick from the camera's LUTs. **LUT On** turns the
LUT on the camera's monitor on and off. A **FALSE COLOR** switch appears in the tile header when any LUT
option name contains "false" (case-insensitive) or "FC" as its own word (e.g. "GK_SLOG3_Log_FC"). Tap it
to switch to False Color, tap again to go back to the LUT you were on. The LUT is a monitor overlay — it doesn't affect what's recorded.

With **Settings → Add False Color to FX3s** on, an FX3 (or FX3A) that connects without a false color LUT gets Tiles'
own ("TW False Color", for S-Log3) in its first empty User slot, so the switch is always there. It's off on a new
install: it writes to the camera. Other cameras are left alone. A LUT already in a slot is never replaced; with every
slot full, nothing is loaded.
Its colors, by exposure from
18% gray: purple black clip, blue just above black, green 18% gray, pink one stop over, yellow just under clip, red
clipped; everything else gray.

**Naming** — the name the camera will give the next take, as the camera reports it, then the title, camera ID and reel
that go into it where the tile is wide enough (under the timecode on an FX3's page on iPad and Mac; on iPhone, from Add
Tile). Tap it for **Clip Naming**: the title (up to 37 letters, digits, _ and -),
the camera ID (A–Z) and the reel (1–999). Each change shows once the camera has taken it. Which of them go into the
clip's name is the camera's file name format, set in its menu; a new camera ID starts the reel again at 1.

**Playback** — in the default layout for cameras with playback controls over the network (beside the frame rate on
iPad and Mac, over REC on iPhone), and in **Add Tile**. Blackmagic cameras offer it. A Sony camera offers it when it lists
Sony's playback buttons (the BURANO, the FX6 and the FX5), or, like the FX3, lets its own buttons be pressed
remotely. A VENICE and an ALEXA offer it.

Shows the current clip name, clip number, and a row of buttons for the transport controls the camera
actually supports, then **Live | Review**: the same switch on every camera. Review puts the camera into playback and
plays the last take straight away, Live takes it back to the live picture, and the buttons work in Review (gray on
Live). Blackmagic: previous, −15 s, −5 s,
play/pause, +5 s, +15 s, next. VENICE and ALEXA: previous, rewind, play/pause, forward, next, stop (a VENICE's rewind and
forward say 4× under them: the camera's own speed). BURANO: those and
Rec Review (the replay symbol), which plays the last take from the live picture, so it's the one button lit on Live and
gray in Review; on a BURANO Review starts the clip playing, and holding ◀◀ ▶▶ scans until you let go. Only buttons the
camera has are drawn, and a narrow tile drops the least essential first (it always keeps previous, play/pause and next).

A Blackmagic camera plays from a list of clips it keeps itself, and that list can leave out your newest takes (on a
PYXIS it held only the clips in the format the card started with). When it does, Review plays the last clip on that
list and the tile says **not the latest take**: press Play on the camera itself to see the newest ones.

FX3: **Live | Review** puts the camera into playback, playing the clip it opens on, and back to the live picture, from
anywhere (a playing clip included). Each button then does one thing: ⏯ plays and pauses, ⏮ ⏭ go to the previous or next clip, and ◀◀ ▶▶ move
within the clip (tap to skip a few seconds, hold to scan and let go to play on; a clip that isn't playing starts
first). A narrow tile keeps ⏮ ⏭ before ◀◀ ▶▶. The FX3 doesn't say whether it's playing, so that button is a plain toggle, and the clip shows in the
**Live View** tile, not as a name. The buttons stay gray until the camera is in review: on the live picture those same
buttons are its shooting shortcuts (peaking, zebras), so Tiles won't press them there. ⏮ ⏭ on a playing clip land on
its neighbor, playing. Review isn't offered while
recording, and reconnecting (a dropped link, say) brings the camera back to the live picture.

**ND Mode**, **Tally**, **Call**, **Color Gamut** — BURANO, in **Add Tile**. ND Mode switches the ND between Step and
Variable over the network, whatever the body's switch says. Tally lights the camera's tally lamps, green or red (one at
a time), or neither. Call shows CALL on the camera's display, to get the operator's attention. Color Gamut picks what
the camera records, S-Gamut3.Cine or S-Gamut3; the FX3 offers this one too.

**Camera Menu** — BURANO and VENICE, in **Add Tile**. Opens the camera's own buttons: on a BURANO, MENU (held, as on
the camera, which opens the full menu), Home, Back, Display, Clips and the multi-selector, to work its menu from a
monitor on its output; Home switches the camera's screen between video monitoring and its information display, which
decides whether HDMI carries the menu. On a VENICE, MENU, Home, Back (the camera's Cancel), the up and down arrows and
Set. Only the buttons the camera lists are drawn; the FX3 doesn't get it (its arrows are shooting shortcuts). A VENICE
key the camera doesn't answer comes off the window until Tiles reconnects, and a tap while the last key is still on
its way is dropped, so a slow link never queues presses up behind REC.

**User Frame A**, **User Frame B** — VENICE, in **Add Tile**. Which of the camera's two user frame lines its frame line
set A (or B) shows: 1 + 2, 1, 2 or Off (On or Off on a camera with one). A tap steps to the next, as the camera's own
"Line A: User Frame Disp." button does, so one tap cycles the guides; touch and hold to pick one. Lit while any is
shown. An output shows set A or B, picked on the camera, and only while its frame lines are on (**Frame Guides**).

**An FX6's own tiles** — in **Add Tile** for an FX6 or an FX5:
- **Shooting Mode**: Custom, Flexible ISO, Cine EI Quick or Cine EI. Each mode keeps its own white balance, look and
  exposure, so Tiles asks first, and not during a take. In Custom an FX6 works in dB: the ISO tile shows **Gain**,
  with a **Low | High** base switch. An FX5 in Custom works in ISO: the ISO tile has a **Low | Mid | High** base
  switch, and in Flexible ISO **800 | 4000 | 12800**. Where the tile is too small for the switch, its chip steps to
  the next base.
- **LUT in Rec**: the LUT baked into what's recorded. Nothing else turns it on: the LUT tile's **Outputs** switch and
  the **Monitoring** window are SDI/HDMI and the viewfinder only. While it's on, the LUT tile says "in rec". An FX5
  has no LUT in the recording; its outputs are HDMI, Proxy/Live View (the proxy and Tiles' own picture) and LCD/VF,
  as its LUT On/Off menu has them (in Flexible ISO; Custom has none).
- **Proxy**: proxy recording on or off, with what the proxy recorder is doing under it.
- **ECS**: on or off, and its frequency a step down or up with **−** **+**. The Shutter tile shows "ECS" and the
  frequency while it's on.
- **Focus**: hold **«** to focus nearer, **»** farther, at the speed on the pill (Slow, Med, Fast); letting go stops it.
  The bar shows where the focus is, near on the left, with the distance once the lens has said. If the app loses a
  lift, Tiles stops the lens itself within a second. **Zoom**: the same for a power zoom lens.
- **Assignable**: the camera's ten assignable buttons, each with what it's set to do and its light. Only functions
  checked on a camera press from here (S&Q Motion, Base ISO/Sens., Rec Review; on an FX5 only Base ISO/Sens. so far);
  the rest are listed, grayed. A button set to Last Clip Del. is never pressed.
- **Auto** on the ND, ISO (Gain in Custom) and Iris tiles: Auto ND, auto gain and auto iris. On Auto the value shows
  what the camera picked and can't be set. In a small tile Auto gives way to the tile's other switches. Tint takes a change only with the body's **B/A/PRESET** switch on A or B.

**Audio** — Add Tile. A Blackmagic camera's channels: each one's gain ("CH1 +30 dB"), grayed while nothing is plugged
into its input; tap for each channel's input, gain, phantom power, low cut and pad, where its input has them. A VENICE's
four meters, as its viewfinder stacks them: the quiet part of each bar dim, the rest bright, the top red; grayed while
S&Q records no sound. The VENICE's sound can't be set over the network, only watched.

**Autofocus** — Add Tile, a Blackmagic camera with a lens it can focus. One tap focuses on the middle of the picture,
once; the tile lights for a moment to say the tap went (the camera doesn't say what it found).

**Live View** and **Live View Button** — opt-in tiles, in no default layout; add them from **Add Tile**.

**Live View** shows the live picture in the tile at any size, aspect-fit, with the camera's tint border. A red dot and
LIVE (with its frame rate) in the corner show it's pulling frames; when it stops, the last frame stays, dimmed. Added
from Add Tile, it comes in at the picture's 16:9 for the page it's on.
**Live View Button** shows no picture and sends nothing until tapped. Tapping either opens the **Live View sheet**
(20 s auto-stop over a network, Keep watching; none for a Blackmagic camera's stream). Under the picture: the frame rate and picture size as they arrive, and
**Quality**, which picks High or Low pictures and 1 to 30 frames a second for that camera (a Blackmagic camera's
stream: High or Low only, at the camera's own frame rate). Until one's picked, the link
decides: High as fast as the camera goes on a cable, Low at 1 fps over a network. The choice is kept, and the tile
streams the same way. Its full-screen button fills the whole screen on iPhone and iPad; on the Mac it opens
a Live View window in full screen. Live View tiles saved before the two kinds existed come back as buttons.

**When the tile pulls data**: only while all four conditions hold simultaneously:
1. The tile is on screen: on the *current* page, and on iPhone on the camera you've swiped to. Changing page,
   swiping to another camera, or arranging tiles (Edit) stops it.
2. The app is in the foreground.
3. The camera is connected and reports live view available.
4. No full Live View sheet is open for that camera (the sheet takes over; the tile pauses to avoid parallel fetches).

Any condition failing → zero network traffic, camera's live view stopped. On a Blackmagic camera the receiver closes at
once, so no picture data flows, and the camera's stream itself stops a minute later, or 15 s later with Remote Control
on (see Blackmagic cameras).

**In Playback (review) mode**: place a Live View tile next to the Playback tile. The Sony live view stream carries the clip the camera is playing back, so the tile becomes the review monitor inline on the dashboard.

On the FX3: ~1 fps, ~7 KB per frame, ~58 kbit/s. At most one stream per camera regardless of how many tiles are visible (tile + sheet never fetch in parallel).

**HaLow** — shows the signal of the HaLow node this device is on, in dBm (e.g. **−72 dBm**), colored by
signal quality. Read-only; never changes anything on the radio.

## Loading a LUT onto the camera

The camera has 16 User LUT slots (User1–User16). Use **Load LUT onto camera…** to import a .cube file
from the app:

1. Open **Settings** (gear icon) → tap the camera.
2. Tap **Load LUT onto camera…** (visible when the camera is connected and supports import).
3. Tap **Choose .cube File…** and pick a .cube file from Files.
4. Edit the **Display Name** shown on the camera (defaults to the filename without extension).
   Note: a name containing "false" (case-insensitive) or "FC" as its own word makes the False Color switch appear.
5. Choose the **Slot** (User1–User16). Occupied slots show their current name. Overwriting a used slot
   shows a confirmation: "Overwrite 'CurrentName'?"
6. Tap **Import**. A progress indicator appears; the camera typically takes 2–5 seconds.
7. On success the LUT picker refreshes automatically so the new LUT is immediately available.

You can also open **Load LUT onto camera…** directly from the LUT tile by tapping the tile name to open

**LUT names.** Settings → **LUT Names** renames LUTs in the picker, for every camera that has a LUT of that name; the
cameras keep their own names. S-Log3 shows as **S-Log3 (No LUT)**: it's the camera's log picture with no LUT on it.
the picker, then selecting **Load LUT onto camera…** at the bottom.

**Errors**:
- *Camera not connected* — connect the camera first.
- *Camera busy* — another operation is in progress; wait a moment and retry.
- *Name rejected* — remove special characters from the display name.
- *File too large* — the file exceeds the camera's maximum upload size.
- *Timeout* — the camera didn't respond; check the connection and retry.

From the command line:
```sh
swift run camctl lut list <camera-ip>
swift run camctl lut import <camera-ip> path/to/lut.cube --slot N --name "LUT Name"
```
Project LUTs are in `assets/luts/` in the repo.

**AF / MF** — two-state switch between the focus modes the camera reports (e.g. "AF-C" and "MF").

**Battery** — battery percentage (volts on a camera that reads volts: a VENICE 2, a BURANO set to show voltage, a
Blackmagic camera on a DC input such as a power plate).
Tap to switch percent and volts on a camera that reports both. Turns red at 15% or less.

**Media** — card remaining time. Tap to switch minutes and hours. Turns red at 10 minutes or less.

On every camera's automatic page, Battery and Media are separate tiles in the identity strip, one above the other.
The combined **Battery / Media** tile (which shows both readings side by side or stacked) is still available from
Add Tile and in any saved layout that used it.

**REC time** — counts up from the start of the take, whether REC was pressed in Tiles or on the camera. The
counter is red while rolling. After the take it shows the length of the last take in gray. A take that was
already rolling when Tiles connected shows --:--:--, since its start isn't known. Sony's PTP protocol does not
carry a running timecode, so the tile shows the take timer instead.

**Latency** — round trip to the camera. Green below 80 ms, yellow 80–200 ms, red above 200 ms. A dash while the
camera isn't connected, and after a reconnect until the first new round trip.

## Top bar

The top bar shows a **link meter** for the cameras on the current page: signal bars derived from the worst latency among them. No bars means at least one camera on the page isn't connected. Tap the meter to see per-camera status and latency. A camera that's down shows as **Reconnect** with why (offline, or what failed): tap it and Tiles tries it at once. Otherwise Tiles retries by itself after 1, 2, 4 and 8 s, then every 10 s.

## Pages

Tabs along the top switch pages. Each page can hold tiles for multiple cameras.

**Edit mode**: tap the pencil in the top bar. On an iPhone held upright you edit the camera on screen: its iPhone arrangement is its own, so it doesn't move anything on the iPad or Mac. Swipe the camera strip to edit another camera; **Done** leaves you on the camera you edited. Drag a
tile onto another to swap them; drop it where other tiles are and they make room, moving down when they can't take its
place. Hold it still for a moment and the page shows what the drop will do before you let go. No tile changes size
to make room: drag the bottom-right corner to resize, and tap the red × at the top-left to remove one. Carry a tile to
the top or bottom edge of the screen and hold it there: the page scrolls under it, so it can go anywhere on a long
page. **Undo** (the curved arrow in the edit bar, or ⌘Z with a keyboard) takes back the last change, one at a time,
until you tap Done. On an iPhone or iPad you feel a tap when you pick a tile up, when the page makes room, and when
you drop it. On an iPhone held upright, Fit to Screen and Reset are under ⋯ in the edit bar. The camera's letter sits beside each
tile's name: tap it to give the tile to another camera, or, under **All of Camera B's Tiles on This Page**, to move
every one of that camera's tiles to another (a page laid out on a demo camera goes to the real one in one step). On a
Blackmagic camera's monitoring tiles (LUT, False Color, Zebra, Focus Assist, Frame Guides, Clean Feed), the output
switch under the name picks which output a tap changes. Tap **Done** when finished.

A camera that isn't connected shows as a demo of itself while you edit ("PYXIS 12K demo", with sample values; the edit
bar says which cameras are offline), so a page can be laid out with the camera off: its tiles, Add Tile and the output
switches all work. Nothing is sent to it. Out of edit mode it's offline again.

**Test Mode** (Settings): a camera that isn't connected runs as a demo of itself on every page, not only while you
edit, so you can try a page out with the camera off: tap its tiles, change values, open its menus. Nothing is sent to
the camera, and it takes over as soon as it connects. **TEST** shows in the top bar while it's on: tap it to turn it
off. It's also in the menu under the signal bars, beside which cameras are offline. When a camera connects, a banner
says "Camera A is live" (its own values from then on); when it drops out, "Camera A is offline: its demo is showing".

**On an iPhone on its side**, a page of several cameras shows one at a time, as wide as the screen: swipe between them,
or tap a camera's letter in the top bar. In edit mode you edit the camera on screen (its letter in the edit bar
switches camera), and Add Tile starts on it. With three or more cameras on the page, edit mode shows that camera's
part of the page as it is there (two columns, scrolling).

Portrait and landscape each keep their own tile arrangement. **Add Tile** opens a list of available tiles, for the
page's own camera unless another is picked at the top.

**Fit to Screen** (in the edit bar, and in Settings → the page): on, tiles shrink so the whole page fits, down to about 42 pt for a standard tile;
past that the page scrolls. Off, tiles keep the size of the page's automatic layout and the page scrolls, so you can keep
adding tiles below.

**Lock**: the padlock locks the controls, so a pocket or a stray hand can't change anything. The **Lock** tile (Add
Tile) is the same lock on the page: either one locks every tile, and either one unlocks them. It's the one tile that
still answers while they're locked, and it fills yellow (or Appearance's Highlight) while they are, like the padlock. Locked, the controls gray; what
you read (the camera's letter, battery and card, timecode, latency, HaLow, live view's picture) stays bright, and so does
REC while it's rolling.

**Appearance** (Settings → **Appearance**): **Custom Colors** sets the tiles', the background's and the text's color
for every tile, starting on white tiles with black text on black, which reads in daylight where the dark look doesn't.
Tap a color's row to open the color picker from its well: **Grid**, **Spectrum** or **Sliders**, or type a hex
value. It applies as you pick, and the **×** (or a tap outside it) closes it.
**Highlight** is the padlock's and the Lock tile's fill while locked, and the outline on a tile just added (yellow to
start). REC keeps its red and each camera its color (a camera color that wouldn't read on the tiles, yellow on white,
is drawn darker); the top bar takes the tiles' color. Turned off, the page goes back to the standard
look and keeps the colors for next time. **Tile Corners** goes from square (0) to rounder than standard (20 pt).
**Tile Outlines** (off to start) draws a line round each tile in its camera's color, 1 to 4 pt thick, with or without
custom colors.
**Text Size**: **Size** makes every tile's titles, labels and buttons bigger, on any screen, from 100 % up to 150 %; a
title that wouldn't fit its tile stays as big as fits, and on a phone on its side, where the rows are very short, they
keep the standard size. The big values stay as they are. **Standardized** (the standard) draws them at one size in
every tile, whatever the tile's size. **Dynamic** draws them bigger still in a bigger tile, up to half again, as far as
the tile keeps its layout: on a big iPad, make a tile bigger for bigger text in it. A phone's tiles are already at their
smallest and don't grow with Dynamic, and nor do the camera's letter, battery, timecode, REC, the shutter dial, Playback
and HaLow. The settings sheets keep the standard look either way.

## Linking cameras

Tap the chain icon in the top bar to open the link menu for the current page. Linking is **off by
default**.

- The first item turns linking on or off for the page.
- Below it, tick which controls are linked: **White Balance**, **Frame Rate**, **Shutter**, **Record**.

When linking is on, a small chain badge appears on linked tiles. Changing a linked control on one
camera sends the same value to all cameras on the page with that control linked. REC is "make it roll" or "make it
stop" on each camera, so a camera already rolling keeps rolling. A frame rate that restarts a camera asks first and
names every linked camera it restarts (a VENICE's project rate). A camera that can't take a value (another make's frame
rate, a setting it has locked while rolling) is left as it is.

## HaLow nodes

Settings → **HaLow Nodes** shows the HaLow radio link from within the app. It finds the nodes by itself.

1. Enter the nodes' **Password** (user `root`, the admin login from the node's setup). One login covers every node.
2. The nodes on the network appear under **Nodes**, where their firmware lets the app check them before it sends the
   password. The node this device is on is marked **this device's node**.
3. **Add Node Address** is for a node the app can't find by itself.
4. **Show**: *When a node answers* (default), *Always* (nodes stay listed when they stop answering), or *Off*.

**Node states:**

| State | Meaning |
|---|---|
| Connected (green) | Node is answering and reporting HaLow stats. |
| Needs password | No password saved yet. |
| Login failed (red) | Password rejected. Not tried again until it changes. |
| Access denied (red) | The login works, but the node won't let the account read its radios. |
| Not a HaLow node (gray) | Host responded but has no HaLow radio below 1 GHz. |
| No answer (gray) | Host unreachable. |

The app polls the node this device is on every 10 s and the others every minute. It is read-only and never changes
anything on the radio. The HaLow tile and top-bar link meter both reflect node signal.

## Control API

Settings → **Integrations** → **Control API** exposes a local WebSocket and HTTP server so Stream Deck,
Bitfocus Companion, and scripts can subscribe to camera state and send commands over the LAN.

1. Open **Settings** → **Control API**.
2. Toggle **Control API** on.
3. Once running, the **Endpoints** section shows the addresses:
   - WebSocket: `ws://<host>:51800/`
   - HTTP: `http://<host>:51801/`
4. Under **Pairing Token**, tap **Show** to reveal the token, or **Copy Token** to copy it. Paste it
   into your Stream Deck or Companion connection settings.

Ports 51800 (WebSocket) and 51801 (HTTP) are fixed and survive app restarts. On iPhone and iPad the
server only runs while the app is in the foreground. Protocol reference: `docs/control-api.md`.

## Stream Deck plugin

Install from `integrations/streamdeck/`. Build and setup: see its `README.md`.

**Stream Deck+ dials**: ISO, Shutter, Kelvin, Tint, Iris, and Variable ND each have a dial action.
Rotate to step; press to cycle or toggle (e.g. press ISO dial to toggle base ISO).

**Focus** and **Zoom**, for an FX6: hold the key to drive the lens Near or Far (Wide or Tele, with a power zoom) at
speed 1 to 8; letting go stops it. **Assignable Button** presses one of the FX6's buttons, 1 to 10, where it's set to
a function Tiles presses (S&Q Motion, Base ISO/Sens., Rec Review).

## Bitfocus Companion module

Install from `integrations/companion-module/`. Build and setup: see its `README.md`.

On iPad, Tiles is the preferred host for the Control API (larger screen stays foreground easily).

For an FX6: **Focus — Drive** or **Zoom — Drive** on a button's Pressed action, with **Focus — Stop** or **Zoom — Stop**
on its Released action, drives the lens while the button is held (the Near, Far, Wide and Tele presets are set up that
way). **Assignable Button — Press** presses one of its buttons, 1 to 10, as the Stream Deck key does.

## Blackmagic cameras

Tiles can connect to Blackmagic cameras (PYXIS 12K and similar) over the REST API.

**Before adding the camera:**
1. Open **Blackmagic Camera Setup** on a Mac connected to the camera (network or USB-C).
2. Select the camera → **Network Access** → enable **Web Media Manager**. For HTTPS, also **Generate Certificate**.
3. Click **Save**. Nothing changes until you do, and Tiles can't reach the camera.
4. On the camera itself, Setup, page 13: turn on **Remote Control** ("control and monitor") if you'll use live view.
   Closing live view then shows nothing on the camera's outputs (see Live view below).

**Or through Remote Control alone:** on the camera itself (Setup, page 13), turn on **Remote Control** ("control and
monitor") and set a **remote password**. In Tiles, set **Connect With** to **Remote Control** and enter just that
password: Tiles connects on the camera's port 444, and Web Media Manager can stay off. Everything works the same way
in, over the network or a USB-C cable to a Mac. A camera that has never had Generate Certificate run in Blackmagic
Camera Setup hasn't been tried this way yet.

A new Blackmagic camera starts on Remote Control, and Add Camera checks the address as you type it: Remote Control if
the camera's port 444 answers, else Network Access if its API answers on the usual port, and it says which. A way in
picked by hand, or saved, stays as it is.

Without the camera, the demo (Add Camera → Demo → PYXIS 12K) shows the page and works as one does.

**Adding the camera in Tiles:**
1. Tap the gear icon → **Add Camera**.
2. Set **Type** to **Blackmagic**.
3. Enter the camera's IP address or mDNS hostname (e.g. `pyxis-12k.local`). Turn on HTTPS if you generated a
   certificate; Tiles pins it on first connect.
4. If the camera's network access has a login, turn on **Login** and enter its user name and password, as set in
   Blackmagic Camera Setup under **Network Access** → **Secure Login** (Blackmagic's login has both). A PYXIS with a
   login turns down HTTPS without it ("The camera wants a login") and still answers plain HTTP. A login set for a
   camera without one does no harm.
5. Tap **Add**.

On a Mac, a USB-C cable to the camera works too, without an address: Add Camera lists the camera under **On USB**
(see the cameras on a USB-C cable, above).

**Monitoring:** a Blackmagic camera's outputs (LCD, the USB-C monitors, SDI) each have their own overlays.
**Monitoring Options** opens them: LUT, false color, zebra, focus assist, frame guides, grids, safe area and clean
feed output by output, and the zebra level and guide ratio. **LUT** and **False Color** switch the display LUT and
false color on every output at once, the tile filled indigo when every output shows it; so do **Zebra**, **Focus
Assist** and **Frame Guides** (Add Tile). **Clean feed** on an output hides all its overlays but the LUT, so Monitoring
Options grays them there and the every-output tiles leave that output alone. On a VENICE each output also has
**Frame Lines** (Line A or Line B, the camera's two frame line sets) and **Audio Meters**. A VENICE's audio meters belong
to the info set an output's overlay shows (Info A or B), so switching them on one output switches them on every output
showing the same set; an output showing only the REC indicator has none.

**HDMI Info and Grid Lines** (Add Tile, Sony): one tap turns the camera's info on its HDMI output on or off (off is
clean HDMI, for a client monitor or a recorder), and its grid lines. The FX3 lists both as settable; zebra, peaking and
frame markers it doesn't let a remote control.

**LUT** (Add Tile): which LUT the camera uses, from the ones Tiles has seen it use, with the monitor LUT's on/off
switch. The camera can't list its LUTs over the network, so Tiles learns them: a LUT picked on the camera joins the
list within a minute and stays on it. One deleted from the camera comes off when picking it fails.

**Status text and de-squeeze**: **Status Text** (Add Tile) turns an output's status text on and off with a tap (SDI to
start with, or every output). **Status Text For** switches what an output's status text shows: SDI's for the
cinematographer or the director, the LCD's and USB-C's meters or codec and resolution; pick the output in edit mode.
Monitoring Options has both for each output. **De-squeeze** (on the page, under Codec) picks the anamorphic
de-squeeze (None, 1.33x, 1.5x, 1.6x, 1.66x, 1.8x, 2.0x). The camera's API hasn't got these, so Tiles sets them through a preset of the camera's own
settings, sending only the part of them that changes: each takes a second or two (the tile shows it at once), changes
nothing else, and is grayed during a take. A change made on the camera itself shows in Tiles within a minute. A PYXIS
only for now: another model's presets haven't been taken apart. On camera software other than 10.3.1, where they
were, Tiles first checks that the camera's presets are laid out the same; if they aren't, these tiles drop off the
page (grayed in edit mode), and the Activity Log (Settings → Report a Problem) says why.

**One output, one tap:** **Clean Feed** (Add Tile) turns clean feed on and off with a tap; it starts on SDI. In edit
mode, the switch under a monitoring tile's name (**All Outputs ⌄**, or the outputs it's on) sets which outputs it
switches: **All Outputs**, or tick any of them — just SDI, or SDI 1/2 and SDI 3/4 but not the monitor. The list stays
open while you tick; tap outside it when you're done. Ticking every one is All Outputs. That goes for LUT, False Color, Zebra, Focus Assist and Frame Guides too. Out of edit mode, a tap
only turns it on or off, everywhere it's set to, and the tile names its outputs under its title ("SDI 1/2 + SDI 3/4",
or "3 Outputs"); it's lit only when every one of them shows it. A False Color, Zebra, Focus Assist or Frame Guides tile on an output that's on clean feed is grayed, since the
camera wouldn't show it there.

**The page:** a Blackmagic camera's page starts with its name, battery and card, timecode, and latency over the HaLow
tile (HaLow once this device has found a node); REC, ISO, the shutter dial and the shutter value; FPS, resolution,
codec and **Dynamic Range** (Film, Extended Video, Video); the WB sliders beside the WB preset; iris and ND where the
lens and body have them; LUT, False Color, Frame Guides and Monitoring Options; Playback beside Naming. A page you've
changed keeps your arrangement; Add Tile has the rest.

**ISO:** the sensor's native ISO is marked, "800 (base)" in the menu and BASE beside it on the tile (PYXIS 12K: 800;
PYXIS 6K: 400 and 3200).

**Tally** (Add Tile): lights the camera's tally, red for Program, green for Preview, or neither. A camera on a
switcher (an ATEM over SDI) may have its tally set there too, and the last one to set it wins.

**Naming:** a Blackmagic camera's Naming tile shows the camera letter (tap to change it) and the reel, which the
camera keeps with the card. Changing the camera letter starts a new reel on the card.

**Off-speed:** with Variable on in the FPS tile (Var where it's small), the tile shows the off-speed rate and the project rate after it
("60 → 24"); tap the number to pick another rate.

**Live view:** add the **Live View** tile. The camera's API has no picture, so live view comes through its livestream,
with Tiles as the server it streams to: about 3.5 s to start, then the camera's own frame rate at about 1.6 Mbps
(Low) or 4 Mbps (High). The stream runs on after you close live view, so changing pages or switching apps picks it
back up within seconds instead of starting it over. With **Remote Control** on at the camera (Setup, page 13, "control
and monitor"), Tiles stops the stream 15 s after you close live view, with nothing showing on the camera. Without
Remote Control, Tiles can only stop it by putting the camera into Review and back, which shows playback on its outputs
for a moment, so it waits a minute. Never during a take: it waits for the take to end. Review stops the stream too;
back in Live, Tiles starts it again. A broadcast the camera is already streaming is left alone, and live view says so.
Now and then the camera takes about 10 s to connect its stream after a start, so live view's picture comes then; it's
the camera, however the last stream stopped.

**Iris:** only for a lens the camera can drive, and read-only while auto exposure drives the aperture. Built from
Blackmagic's documentation; not yet tried with such a lens.

**What a Blackmagic camera doesn't offer over its API:**
- Picking a LUT or loading one: that's the camera's LUTs menu. The API only turns the display LUT on and off.
- De-squeeze and focus mode.
- Status text, including the SDI's Director or Cinematographer text: that's the camera's monitor settings.

Checked on a PYXIS 12K, REC included (docs/pyxis-controls.md). The tile set follows what the camera has.

## Errors

**Fingerprint changed** — the camera's SSH host key is different from the one saved when you first
connected. This happens after a reset or a swapped camera, or if something is intercepting the connection.
Tap **Trust New Fingerprint** only if it matches the camera's Access Authen. Info screen; otherwise
**Cancel**.

**The camera closed the session. Is another controller connected to it?** — the FX3 allows only one
controller at a time. Disconnect any other app or `camctl` session before connecting.

**REC FAILED** — the camera refused REC (usually no card, a full card or a card error) or never
confirmed it. Check the camera's media.
