# Tiles Design Style Guide

_Camera-Control Dashboard · SwiftUI · iPhone / iPad / Mac_
_Source of truth: `DashboardUI/Theme.swift`, `Components.swift`, `Tiles/` (a file per family of tiles), `DashboardView.swift`, `CameraCore/PageLayout.swift`._

---

## 1 · Principles

1. **Controls only.** Every tile represents something the connected camera actually reports. No decorative tiles, no status-only tiles that look like controls, no placeholders.
2. **Never optimistic.** A control dims (`opacity 0.28`) and stops accepting touches the moment the camera stops reporting that property. Gray = read-only or unavailable.
3. **No invented values.** If the camera hasn't reported, the value shows `—`. Timecode shows REC-time because Sony PTP 3 never sends running timecode; it would be invented.
4. **Confirmation before destructive actions.** Frame-rate changes that restart the camera require a confirmation dialog. Nothing else does.
5. **Controls lock as a safety mode.** The `controlsLocked` environment key disables all tile interaction but the Lock tile's. Controls gray (`Theme.lockedOpacity`) so a locked page reads as locked, every value still legible; read-outs keep their brightness (2026-10-26: a locked page looked exactly like an unlocked one, and a tap just did nothing).

### How a tile varies: one system for size, style and options

From design review, 2026-10-27: "make sure all these size variabilities and style changes
and variabilities ultimately work together under an intentionally documented design system." Everything a tile can
look like comes from three inputs, and nothing else may change it.

1. **Size** (where the tile is and how big). The grid's cell size comes from the screen (`GridMetrics`), the tile's
   cells from its template or from the user's resize. What the tile does with its size is fixed per kind in `TileSpec`
   (§5): a minimum, and the thresholds where it changes shape. Shapes, in the order a tile gives them up as it
   shrinks: caption row over value (§3) → caption beside value (`oneLineBelow`) → switches move from beside the value
   to the caption row (`SwitchPlacement`) → least essential parts drop (`ViewThatFits`, Playback's button priorities)
   → nothing is ever clipped or overlapped. Tiles with more than one arrangement say which in their doc comment: White
   Balance sliders stack their caption over the track, then go one line each, then put Temp and Tint side by side in a
   wide, short tile (a phone on its side); a narrow tile keeps both rows on shorter tracks (down to 14 pt), and only
   then drops Tint and keeps Temp (`WhiteBalanceSlidersTile.form`; 2026-10-28: Tint was cut off at the bottom of a
   phone's tile). Playback keeps its Live | Review switch and drops buttons by priority, and in a tile shorter than its
   36 pt buttons makes them, and the switch, as tall as the tile. A one-line tile shorter than a small control
   (`Theme.smallControl`, 20 pt) drops its switches, and a taller switch (`PillToggle`) gives way to a shorter line down
   to 20 pt; the iris track is never taller than its line. ND − / ND + and the Live View button put their caption beside
   the glyph when the caption row won't fit over it.
2. **Style** (how it's drawn). The look's tokens (§2) through `Theme`; Settings → Appearance over them (custom
   colors in Ink's proportions, Highlight, corners); the camera's color (one of eight, or its own picked color,
   `CameraSlot.tint`) in captions and badges, through `Theme.legible` where it must read; REC's red and the status
   colors fixed. Sheets keep the standard look (`Theme.sheet`). Colors are picked with Tiles' own picker
   (`ColourPickerPanel`: Grid, Spectrum, Sliders and a hex field) in a popover from the color's well, a sheet on an
   iPhone, the shape the system's had. The system's (`ColorPicker`, `UIColorPickerViewController`) draws in an
   extension that has come up empty on an iPad. Text Size, below, scales a tile's
   type and controls.
3. **Options** (what the tile is set to do), set only in edit mode as chips on the tile (§5, Edit-mode settings): its
   camera, a monitoring switch's outputs, the ND tile's step buttons. Saved on the tile (`PageWidget`), absent from the
   JSON until set, so older builds read the same layout. An option counts as an edit: Done keeps a page whose only
   change is an option customized (`PageLayout.sameArrangement` compares them), where an untouched page goes back to
   automatic.

**What scales with size: the value, and with Text Size the rest.** A tile's value grows with the room it has
(`Theme.valueSize`, capped per kind). Everything else (captions, readouts, button labels, insets, the caption row,
switches, step buttons, slider knobs, chevrons, symbols) is a fixed token (§2, §4). Settings → Appearance → **Text
Size** says what those tokens do (2026-10-27: on a big iPad the captions, the ND tile's − + and the Lock tile's
padlock read small; 2026-10-28: "standardized vs dynamic. dynamic is different per tile. standardize should be
the standard"):

- **Standardized** (the default, and every build before 53): the same in every tile, so a page reads as one surface. A
  bigger tile gets a bigger value and more parts, not bigger captions.
- **Dynamic**: each tile has a scale, `tileScale`, and draws every token that many times the standard, the value's cap
  and floor too. The heights and widths it compares its size with (`oneLineBelow`, `trailingFrom`, `footerFrom`, the
  34 pt short label, the slider forms) are scaled the same way, so a tile at scale k lays out exactly as the standard
  tile does at its size ÷ k, only k times bigger, and fits wherever that one does.
- **Size** (a slider, 100 to 150 % in tenths; 2026-10-28: "a way to bump the text sizes across the board ... even
  when I have the screen small"): every tile's small type, on any screen and in both modes: captions, readouts, the
  labels of switches, pills and buttons, chevrons and a one-line value (`Theme.textBump`, multiplied into the scaled
  roles), and the caption row that holds a caption (`Theme.captionRow`; every height that holds one grows by
  `captionRowGrowth`). Values sized to their room, insets and controls don't change, so a big value never shrinks for
  bigger captions. Scaling whole tiles the way Dynamic does was tried first: on a phone it shrank the values (the
  caption row and insets took the room) and dropped Tint. Where the bigger type can't fit it gives way: a caption on a
  line too narrow for it shrinks back toward the standard size, never below it (`minimumScaleFactor`); a one-line tile
  or row too short for it (a phone on its side, 10–14 pt rows: `Theme.captionLine`) keeps the standard type
  (`shortLine`); a one-line value is the bigger size only where the line has the height; a header switch that no
  longer fits becomes its chip, ISO's base too; Latency drops its caption beside the reading sooner (`captionFrom`
  times the slider's). Taller caption rows leave a tile less room, so it takes its smaller forms sooner: White Balance
  drops Tint where its rows no longer fit, as in a small tile ("auto drop tint ... once the tile is too small";
  keeping the standard type to keep Tint put its caption row out of line with the page's).

The scale, per tile (`TextZoom`, in `TextSize.swift`):

- It grows with the tile's height, from 1 at 66 pt (a standard two-half-row tile on an iPad mini, where the type was
  drawn) to 1.5, in steps of an eighth, so tiles of one size match.
- It's the largest step at which the tile keeps its shape: one line or two, switches full size or small, Temp and Tint
  or Temp alone. Switches may move from a column to a row along the bottom, where they're full size too (ISO on a
  13-inch iPad). A tile with no switches on its camera (an ND tile without step buttons, an FPS tile on an FX3) isn't
  held back by where they'd go (`CameraState.hasModeSwitches`).
- It never lays a tile out smaller than its smallest on the grid (`WidgetKind.smallestOnGrid`), where the gallery checks
  it. So a phone's tiles, already at their smallest across, stay at 1, as does an iPad mini's standard tile; a 13-inch
  iPad's bigger tiles grow.
- At 1 always: the identity strip (letter and model, battery and card, timecode, latency, naming), REC, the shutter
  dial, live view's picture, Playback and HaLow. They already size their content to the tile.
- Edit mode's outlines, chips and badges are the page's, not the tile's, and stay at 1. Resizing a tile in edit mode
  changes its text in those eighths, as it changes its form at a threshold.

It's drawn at real sizes, not zoomed. On iOS `scaleEffect` magnified the rendered text and it went soft,
`.drawingGroup()` broke menus and pickers, and a raised `displayScale` sharpened nothing and broke picks (all
2026-10-28). An earlier zoom (2026-10-27, branch `explore/text-size-zoom`, 1c031ea) also gave up a tile's shape for
size (Angle | Speed became ANG | SPD); the shape rule above is what fixes that. In code: a tile, and each component in
one, reads `@Environment(\.tileScale)` and multiplies its fixed numbers by it, through `Theme`'s scaled roles
(`caption(_:)`, `captionTracking(_:)`, `readout(_:)`, `buttonLabel(short:scale:)`, `segment(_:)`, `chevron(_:)`,
`valueSize(…scale:)`, `detail(forValue:scale:)`). Sizes handed to a control (`PillToggle.height`,
`RoundIconButton.diameter`, `MiniSegmented.segmentHeight`) are standard points, and the control scales them. At 1 each
of these is exactly the standard token, so Standardized draws pixel for pixel as it did. `WidgetView` sets the scale
(`TileScaling`); `TextZoomTests` hold the rule.

**Rules for any new variation.** It's a token, a `TileSpec` threshold or a `PageWidget` option, never a number inside
one tile. A fixed number in a tile is multiplied by `tileScale`; a new threshold goes into `TextZoom.shape` as well. It
renders in the gallery at every canonical size and at its smallest on the grid, Standardized and Dynamic, at the
slider's 100 to 150 %, and passes the audit (§7): nothing cut off, everything aligned. New small type goes through the
scaled roles (`Theme.caption(_:)` and the rest), so it takes the slider. The cameras people use on set render pixel-identical to the last
shipped build unless the change means them to (docs/testing.md, Snapshot renderer: the render gate). An interaction it
adds has a UI test (docs/testing.md).

---

## 2 · Tokens

### Looks: Ink (since 2026-10-15) and Outline

The tokens below live in `ThemeStyle` and are read through `Theme`, so tile code is the same in every look. **Ink** is
the app's look: borderless tiles on true black, each tile's captions in its camera's color, SF Pro with steady digits.
It replaced the original **Outline** (camera-colored borders, SF Mono) on 2026-10-15.
`CC_SNAPSHOT_STYLE=outline dashboard-snapshot …` still renders Outline, for comparison.

### Color roles

| Token | Ink | Outline | Use |
|---|---|---|---|
| `background` | black | `0.11` gray | App background, safe-area fill |
| `chrome` | black | `0.14` | Top bar, edit bar |
| `tile` | white `0.07` | `0.155` | Tile fill |
| `control` | white `0.15` | white `0.24` | Segmented control track, pill background, camera switcher chip |
| `controlSelected` | white `0.30` | white `0.44` | Active segment inside MiniSegmented |
| `text` | white `0.96` | white | Primary values; "on" state pill text |
| `secondaryText` | white `0.56` | white `0.62` | Disabled values; chevrons; inactive pill text; captions in Outline |
| `timecode` | white `0.96` | green `0.27/0.87/0.40` | Timecode value; status dot (connected); "on" PillToggle tint; link-on button |
| `recording` | `1.0/0.27/0.23` | `0.94/0.24/0.22` | STOP fill; REC ring; status dot (recording or failed); battery/media warning |
| `needle` | white `0.96` | blue `0.22/0.52/1.0` | Shutter dial needle |
| `accent` / `accentText` | white / black | blue / white | Selected page tab |
| `engaged` | white `0.30` | indigo `0.38/0.22/0.68` | **Whole-tile fill when a `ToggleTile` setting is on** (False Color, Zebra, Color Bars, Sensor Flip, Focus Assist, Frame Guides, Clean Feed, View Assist) |
| `locked` / `lockedText` | yellow (`SlotColor.yellow`) / black | same | The controls locked: the Lock tile's fill and the top bar padlock's, and the outline on a tile just added. Yellow in every look; with custom colors on, the picked **Highlight** (`AppearanceSettings.highlight`), and `lockedText` is black or white on it, whichever reads (2026-10-27; the Lock tile filled `engaged` before, which didn't stand out on a page the lock had grayed) |
| `strong` | white | white | A mark on a tile rather than text: a slider's knob and ticks, the Live View launcher's camera, edit mode's dashed outline |
| `dialRing`, `dialTick`, `track`, `recFill` | `0.20`, `0.50`, `0.17`, black | `0.34`, `0.60`, `0.30`, `0.17` | Shutter dial ring and ticks; slider tracks; the unlit REC button's fill |

Camera slot colors (`SlotColor`) say which camera a tile belongs to: in Ink, the color of the tile's captions (`Caption`
reads the tile's color from the environment, `tileTint`); in Outline, the tile's border. They aren't used as fill, and
not as text beyond captions and the camera's letter (badge text follows `badgeText`).

### Appearance (Settings → Appearance, 2026-10-27)

Added after a river shoot: Ink's dark tiles were hard to read outdoors. `AppearanceSettings`
(CameraCore) holds custom colors (tile, background, text; off by default, starting on white tiles and black text on
black), a corner radius (0–20 pt, nil for the look's own) and tile outlines (off by default; 1–4 pt in halves, drawn in
each tile's camera color by `Tile`, as the Outline look draws them, `ThemeStyle.drawsOutline`). `ThemeStore`
(`Theme.swift`) is the look with them on top:
every token reads `ThemeStore.shared.style`, which is `@Observable`, so a view that drew with a token draws again when
the appearance changes. Nothing is rebuilt with `.id()`, which would also close the Settings sheet it's set from. The
app reads the saved appearance (`appearance.v1`) at launch, before the first frame; tests and dashboard-snapshot never
read it.

With custom colors on, every color comes from the three picked (`AppearancePalette`), in Ink's proportions: Ink's
grays are its tile (0.07) mixed toward its text (0.96), a control 9 % of the way, a selected control or a switched-on
tile 26 %, secondary text 55 %. Text on a fill that may be either light or dark (a chosen segment, the selected page
tab) is black or white by WCAG luminance. What doesn't change: REC's red and the camera colors (a camera can have its
own picked color, `CameraSlot.customColor`, but the appearance never changes it). `locked` (the padlock, the Lock tile,
the outline on a tile just added) is the picked highlight, yellow until one is picked; `lockedText` is black or white on
it, whichever reads.

- **The bars take the tile's color, not the background's.** Everything in the top bar and the edit bar is drawn in a
  tile's colors (text, controls, the link meter), and with black text on a black background it vanished. Their
  color scheme follows (`Theme.chromeScheme`), so the system's switches and buttons in them are drawn for a light bar.
- **Text on the bare background** (the empty page, the welcome screen, edit mode's grid) takes `backgroundText`: the
  text color if it reads there at 4.5:1, else black or white.
- **Sheets, forms and popovers keep the standard look** (`Theme.sheet`, the look without the appearance). Their rows
  and backgrounds are the system's dark ones, so their text can't take the page's: black text picked for white tiles
  would vanish on them. They stay `.dark`. `SheetColourTests` fails on a page color in a file that's only sheets
  (Settings, Add Camera's lists, Control API, LUT import); in the files that mix sheets with tiles, it's on review.
- **A camera's color as text** (captions, the camera's letter) goes through `Theme.legible`: on a tile it doesn't read
  on at 3:1 (yellow on white) it's mixed toward the text color until it does, the same hue darker. Red and blue read on
  white as they are, so camera A's red tag stays red. The status yellows and oranges (latency, the link meter, HaLow
  signal, awaiting approval) go through it too, and so does every stop of a gradient track (White Balance's Temp and
  Tint), whose white middle and pale stops vanished into a white tile (2026-10-28): on a white tile the middle is
  a gray. The standard colors are untouched.
- **The page's color scheme** follows its background (`Theme.pageScheme`): the status bar sits over it.

**Whole-tile toggle fill system (2026-10-12):** When a `ToggleTile` is engaged (its boolean setting is on), the tile's fill changes to `Theme.engaged` (muted indigo) and its label stays white. This is the same anatomy `RecordTile` uses — tile fill communicates state — but `recording` red is reserved for the record action. The engaged color was chosen to be: (1) legible with white text at this brightness, (2) not a slot border color, (3) clearly distinct from the green used for "live" status. `PillToggle` and in-tile switches keep their own lit/unlit states (`timecode` green tint for pills) unchanged — the full-fill is only for tiles where the entire tile is the toggle (no caption, no picker).

A toggle tile's title is one string, on one line where it fits and wrapped at the space where it doesn't (two lines at most; one in a short stacked tile). Never a typed line break: "Frame\nGuides" sat on two lines beside a one-line "False Color" in tiles of one width. `TileTypographyTests` fails on one.

A monitoring toggle set to one output or several (`PageWidget.targets`: a Blackmagic camera's SDI, a VENICE's SDI 1/2 + SDI 3/4) names them under the title in `caption`, uppercase (beside the title, on its baseline, in a short tile): `secondaryText`, white on the engaged fill, where gray on indigo barely read. A toggle for every output shows its title alone, as it always did.

### Type scale

Every piece of text in a tile is one of these roles (`Theme`), and tile code uses nothing else:
`TileTypographyTests` fails on `Theme.mono(` or `.system(size:` in the files in `Tiles/`, `AudioTiles.swift`,
`Components.swift`, `GridPageView.swift` or `HaLowTile.swift`. Sheets inside those files use the system's text styles (`.body`).

| Role | Font | Use |
|---|---|---|
| `caption` | 10 pt bold, tracking 1.4 (Outline: heavy, 0.6) | Tile captions; badges; BASE; pill toggles and small segmented controls; the live view chip; edit-mode tile names |
| `readout` | 12 pt semibold mono | A readout beside a caption (Kelvin, tint, f-number, Playback's clip count); small information on or under a picture (live view's frame rate and size, "Fetching first frame…", errors); menu labels |
| `value(size)` | bold mono, at `valueSize` | A tile's main value. Text values (codec, bitrate, resolution, LUT, clip) share one cap, `textValueMax` (22 pt); numbers (ISO, frame rate, shutter, WB) go larger |
| `detail(forValue:)` | semibold mono, 0.6 × the value, 10 pt at least | A value's second part, on its baseline, muted ("→ 24", "4:2:2 10bit") |
| `identity(size)` | semibold mono, at `identitySize` | The identity strip: timecode, battery, card, and the model beside the letter |
| `letter(size)` | heavy mono | A camera's letter: identity strip, camera chips |
| `hero(size)` | heavy mono, sized to the button | REC, STOP |
| `buttonLabel(short:)` | semibold mono, 15 pt (12 pt short) | One-button tiles (toggles, Monitoring Options, Lock) and buttons in live view |
| `segment` | 12 pt semibold | A full-size segmented control's options |
| `chevron` | 10 pt bold | ⌄ and › |
| `symbol(size, weight)` | SF Symbol | Icons in controls (transport, ±, step arrows), sized by their control |

Values take the look's design: in Ink, SF Pro with **tabular digits** (`monospacedDigit`), each weight two steps lighter
(bold reads as medium); in Outline, SF Mono at the weights in the table. Captions are proportional uppercase. Before 2026-10-12 the tiles held 17 styles
of their own (a 9 pt live chip, an 11 pt Color Bars toggle, a 10 pt clip count, a bold timecode beside semibold
battery and latency); each now takes a role.

**Caption height:** 14 pt fixed. **Caption gap:** 3 pt below caption to value area. These are constants; do not vary them per tile. Dynamic Text Size scales them with the rest of the tile's tokens, by the tile's `tileScale` (§ 1, How a tile varies); every role in the table but `identity`, `letter` and `hero`, which only the tiles that stay at 1 use, has a scaled form.

### Spacing

| Token | Value | Use |
|---|---|---|
| `gap` | 6 pt (Outline 8) | Spacing between tiles in the grid |
| `inset` | 10 pt | Horizontal padding from tile edge to content in every captioned tile |
| `insetV` | 7 pt | Vertical padding from tile edge to content; identical across all tiles |
| `columnGap` | 20 pt (gap × 2.5) | Gap between camera columns in multi-camera views |
| `padding` | 16 pt (gap × 2) | Dashboard outer padding |

### Tile shell

| Property | Value |
|---|---|
| Corner radius | 12 pt, `.continuous` (Outline 9); Settings → Appearance sets 0–20 pt (`Theme.corner`; controls inside keep their own) |
| Border | none; the captions carry the camera's color (Outline: 1.5 pt stroke, camera slot color) |
| Fill | `Theme.tile` |
| Disabled opacity | 0.28 (content layer only; in Outline the border stays full) |
| Locked opacity | 0.55 (`Theme.lockedOpacity`; content layer of a control only, not of a read-out or a disabled tile, which stays at 0.28) |

---

## 3 · Tile Anatomy

### Standard captioned tile (`TileFrame`)

```
┌─────────────────────────────────────┐  ← border (1.5pt, slot color)
│  CAPTION            [accessory]     │  ← 10pt heavy, secondaryText; row 14pt
│                                     │  ← captionGap (3pt)
│  Value / Control                    │  ← fills remaining height
│                                     │
└─────────────────────────────────────┘
```

- Caption is **always top-left**, on a `captionHeight` (14 pt) row that starts `insetV` (7 pt, every tile) from the top.
  That row is always a `CaptionRow`: a zero-width readout-font strut fixes its baseline, and whatever sits beside the
  caption (a readout on its baseline, switches) is laid over the row by baseline, so it can overhang the row but
  never move the caption. Hand-made rows drifted: ISO's Base switch lifted its caption 1 pt, ND −/+ sat 1.5 pt high.
- Value starts at `inset` (10 pt) from both sides.
- The entire tile face is the tap target for pickers (`ChoiceMenu` overlays a `Color.clear` rectangle).

**What the glyph at the trailing edge promises** (10 pt bold, `secondaryText`, on the value's line):

| Glyph | Component | Means | Tiles |
|---|---|---|---|
| ⌄ `chevron.down` | `Chevron` | a menu drops down from the tile, in place | every picker: ISO, WB, FPS, codec, iris's f-number |
| › `chevron.forward` | `SheetChevron` | the tile opens a window | Naming, Monitoring Options |
| none | — | the tile acts where it is (a toggle, REC, a button), or there's nothing to pick | toggles, read-only values |

A tile that opens a window never gets ⌄: that promises a menu and a window comes up (2026-10-12, on the
Monitoring tile). A one-button tile that opens a window is its name, centered like a toggle, with › after it
(`WindowButtonLabel`). The › aligns on `firstTextBaseline` with the title text — `HStack(alignment: .firstTextBaseline)` — so the glyph sits level with the text capitals at any tile height, not at the midpoint of different-sized line boxes.

### One-line mode (`oneLineBelow`)

When `height < 49 pt` (default; `FocusModeTile` uses 60 pt), the tile collapses to a single horizontal line:

```
CAPTION   value / control   [accessory]
```

Caption gets `layoutPriority(2)`, accessory gets `layoutPriority(1)`, value fills the middle.

**The value wins over the caption** (`valueWins`, `OneLineRow`) in a tile whose content is its value, a picker's
`PickerValue`: Shutter, FPS, ISO, WB, ND, Res, Codec, Bitrate, De-squeeze and the plain pickers (Dynamic Range…). A
VENICE's Shutter on a phone on its side read "1…" beside a whole "SHUTTER" and ANG | SPD, and FPS's value vanished
beside Fixed | Var. Where caption, value and switches don't all fit at their own widths: the value's type gives up to
15 % first; then the switches give way (to a chip: ANG); then the caption gives way, whole: a caption is whole or not
there, never cut ("CO…" and "BITR…" on a page of four cameras read as broken); and only then does the value shrink
further. The value says what it is where its caption has gone, as Latency's reading does. Content with its own ways to fit (Naming's reel, Playback's buttons,
Latency's icon, a LUT's switch) keeps the caption whole, as above. `OneLineRowTests` holds the order.

### Captions inside the content (`CaptionedValue`)

A caption that labels a value inside a tile ("ID A", "REEL 1" in Naming) is a `CaptionedValue`: the caption aligned
to the value on their **cap centers**, not their line-box midpoints. A 10 pt caption and a 22 pt value have very
different line boxes; centering on the line box puts the caption a hair low relative to the value's capitals (2026-10-12). `HStack(alignment: .capCenter)` with `.capCentered()` on both elements makes them share the same
visual capital-height axis. Never an `HStack` on `.center` or `.firstTextBaseline`: the former drifts on large
values, the latter aligns baselines but not cap-height centers.

### Switch placement rules (`SwitchPlacement`)

| Condition | Placement | Switch size |
|---|---|---|
| Width ≥ `trailingFrom`, and the height for the full-size switch (34 pt) under the caption | `.trailing` — own column on the right | Full (`small: false`) |
| Height ≥ `footerFrom` (and not wide enough for trailing) | `.footer` — row along the bottom | Full |
| Otherwise | `.header` — right of caption row | Small (`small: true`), overhangs the 14 pt caption row |
| Height < `oneLineBelow` | `.inline` — beside value on one line | Small |

`switchCaption` ("Base", "Monitor", "Mode", "S&Q", "Step"): in a column it sits **on the tile's caption row, left-aligned over the switch**, so the tile reads as two small ones; along the bottom it leads the row. A tile only gets a column or row when this camera gives it switches (nil caption → header only).

Tiles that use `trailingFrom` / `footerFrom`. All values live in `WidgetKind.spec` (`TileSpec` in `PageLayout.swift`) — change there, not at call sites:

| Tile (`WidgetKind`) | `trailingFrom` | `footerFrom` | `oneLineBelow` |
|---|---|---|---|
| `.ndPreset` | 240 pt | — | default |
| `.shutterValue` | 260 pt | 110 pt | default |
| `.frameRate` | 260 pt | 110 pt | default |
| `.iso` | 300 pt | 110 pt | default |
| `.lut` | 250 pt | — | 58 pt |
| `.focusMode` | — | — | 60 pt |
| `.iris` | — | — | 56 pt |

**2026-10-12:** `FrameRateTile`'s `trailingFrom` was 300 pt (12 pt wider than Shutter). Lowered to 260 pt so the Fixed | Variable switch gets its own trailing column at the same widths as the Shutter's Mode switch. Equal thresholds means the two tiles behave identically side by side.

**Corner controls: equidistant from top and side (2026-10-12).** Header-row switches sit `inset` (10 pt) from the trailing edge of their tile (via the VStack's `.padding(.horizontal, inset)`), but only `insetV` (7 pt) from the top. A 3 pt top offset is applied to the header accessory in `TileFrame` (`.padding(.top, inset - insetV)`) so corner controls are equidistant from both edges. The rule: any control in a tile corner should be `inset` pt from both edges it is nearest to.

**Mode switches are one control (`ModeSwitch`, 2026-10-28).** Shutter's Angle | Speed and FPS's Fixed | Variable are the
same component at the same sizes, so tiles of one size show the same switch: in the header or on one line, the small
segmented control (caption type, 20 pt), or where even that won't fit, one chip showing the mode, which flips it; in a
column or along the bottom, the full-size control (30 pt segments), with the short labels ("Fixed | Var") where the full
ones would squeeze. On a phone the FPS tile's switch was bigger than the shutter's beside it (the 2026-10-12 rule
gave FPS 26 pt segments in the header). A one-line tile shorter than a small control (`Theme.smallControl`, 20 pt) drops
its switches rather than cut them off.

### Identity readouts (no caption)

`LabelTile` (camera letter + model, like the camera chips), `StatusTile` (battery + card), `TimecodeTile` (REC time, or timecode where a camera sends it): a glyph and a value, no caption, **centered** (see Alignment). Font size is `identitySize(geo.size)`: capped to the tile's height (× 0.45) and width (fitting ~7 em for a timecode), so a row of them reads at one size. The label's letter is 1.25× that and the model 5/8 of the letter.

`LatencyTile` and `HaLowTile` both use the **left-aligned captioned style** (`TileFrame`). Decision (2026-10-12): both tiles carry a meaningful label ("LATENCY", "HALOW"), have values that benefit from left alignment to match other captioned tiles beside them, and are often placed adjacent. `LatencyTile` keeps its `dot.radiowaves.left.and.right` icon as part of the value — it distinguishes latency from a plain number at a glance and matches HaLow's visual language (a value that needs context). Moving Latency from centered-identity to captioned-left makes the two tiles visually similar without dropping the icon. Narrower than its `captionFrom` (160 pt) on one line, Latency drops the caption and keeps the icon and value, left-aligned: beside the caption the value would shrink past reading, and the icon names it on its own.

### Hero controls

**`RecordTile`** — no caption. Center-fills the available space with a circle (62% of the shorter dimension). Standby: dark fill with red ring + "REC" in red. Recording: red fill + "STOP" in white. A `REC FAILED` badge (orange, top-left) overlays on failure.

**`PlaybackTile`** — the transport buttons (36 pt targets) and the Live | Review switch grow with the tile, by up to a
third, as long as the whole row still fits its width; a row that doesn't fit drops its least essential buttons first.
In a tile shorter than 36 pt (a phone on its side) they're as tall as the tile, rather than cut off top and bottom.
The row is centered in the whole tile where that clears the caption at its top left and the clip readout at its top
right, and centered under the caption row where it would run into either (`CentredTransport`, which measures the two;
2026-10-28: in a wide tile the row sat low with room either side of it).
Every camera that plays back has the same Live | Review switch, after the buttons: the FX3, a BURANO or FX6, a VENICE, an
ALEXA, a Blackmagic camera's transport mode (2026-10-27: "consistent across cameras"). The buttons work in Review,
and the switch is held back during a take. No Live button beside it (an ALEXA had one). Rec Review, where a Sony body
has it, is the one live-side button: lit on the live picture, gray in Review, a replay symbol (`memories`; ↩ read as
Back). The clip count rides in the header where there is one.

**`ShutterDial`** — no caption. A clock-face dial; the value is rendered at `diameter × 0.2`. The blue needle is 2.5 pt wide, and points at the actual shutter position: `needleAngle` is clockwise degrees from 12 o'clock, passed by `ShutterTile`. Angle mode: needle = the shutter angle (180° = straight down, 360° = back at top). Speed mode: needle = 360 × frameRate × (1/N), using off-speed rate when variable mode is on. If the angle cannot be computed (no shutter value, or speed mode with no frame rate), no needle is drawn. Paired with `ShutterValueTile` in wide layouts; carries its own mode switch (`showsMode: true`) in the iPhone column.

---

## 4 · Controls

### When to use each control type

| Control | Use when |
|---|---|
| `PickerValue` + `ChoiceMenu` | Camera reports a discrete options list (ISO values, frame rates, ND presets, codecs). Renders as the current value + chevron; menu on tap. |
| `MiniSegmented` (standard, `small: false`) | 2–4 options that are always visible and often switched (Fixed/Variable, AF-C/MF, base ISO). 34 pt tall (30 pt segments in a 2 pt track); use in `.trailing` or `.footer` placement, or one-line mode. Its segments share the width equally, so its ideal width is its widest label's times the options: a `ViewThatFits` falls back before a label shrinks ("Fixed \| Variable" squeezed "Variable" in an iPad's footer, 2026-10-28). |
| `ModeSwitch` | A tile's two-way mode (Shutter's Angle \| Speed, FPS's Fixed \| Variable): the small `MiniSegmented` in the header or on one line, then a chip; full size in a column or along the bottom, then with short labels (§3). |
| `MiniSegmented` (small, `small: true`) | Same options but header space only (~16–20 pt). Falls back to `PillToggle` via `ViewThatFits` when even this won't fit. |
| `PillToggle` | Binary toggle shown as a chip (lit = on, unlit = off, nil = mode chip). Smaller than MiniSegmented; used as `ViewThatFits` fallback and for LUT switches. Height 20 pt in header; 30 pt in trailing/footer. |
| `TrackSlider` | Continuous range (Kelvin, tint, iris f-stop). Drag to change; commits on release only (no flooding). Double-tap resets. Single tap does nothing. |
| `RoundIconButton` | Discrete step within a range (ND ±1). Diameter 20 pt in header; 34 pt in trailing. |
| `ToggleTile` | Full-tile boolean toggle (Color Bars, False Color, Look, Sensor Flip, the monitoring overlays, Call). Fills `Theme.engaged` when on, and a light beside its name is lit (a ring when off): the fill alone makes an off switch look like a tile that only says something. A tile that opens a window has › and no light. |
| `ChoiceTile` | A caption over a value the camera names and lists, picked with ⌄ (`PickerValue`): Dynamic Range, ND Mode, Tally, Color Gamut, User Frame A and B. |
| `ColorChooser` | Edit Camera / profile color: the eight `SlotColor` swatches, 26 pt circles 10 pt apart, and a ninth, an eyedropper on a ring of colors (or on the picked color, ringed white), which opens Tiles' color picker from it (`TilesUITests/CustomColourTests`). |
| `ColourRow` + `ColourPickerPanel` | A color to pick (Settings → Appearance): its name, and its color in a well (`ColourWell`) that opens Tiles' own picker in a popover, a sheet on an iPhone: Grid, Spectrum, Sliders and a hex field, each pick applied as it's made and shown in the hex field, even while the field has the focus (a Mac gives it the focus as the picker opens, and the hex stayed on the opening color; `ColourPickerHexTests`). Not the system's picker, whose extension came up empty on a tester's iPad (§1). |
| Checklist popover (`EditOverlay.outputsChecklist`) | Several choices at once (a monitoring tile's outputs in edit mode). Stays open while ticking, closes on a tap outside; anchored to the tile, not the chip, which moves as its name grows. A menu is for one choice: it closes on the pick, and macOS menus can't be kept open. |
| `BarButton` | The top bar's actions, 30 × 24 pt symbols on `control`: the pencil (Edit Tiles; four squares before 2026-10-22), the lock, the gear. |

### Touch targets

| Component | Nominal size |
|---|---|
| `MiniSegmented` (standard) | 34 pt tall (30 pt segments), width varies — below 44 pt HIG minimum |
| `MiniSegmented` (small) | 16 pt tall — below 44 pt HIG minimum |
| `PillToggle` (header) | 20 pt tall — below 44 pt HIG minimum |
| `PillToggle` (trailing/footer) | 30 pt tall (28 on one line), down to 20 pt in a shorter line — below 44 pt HIG minimum |
| `RoundIconButton` (header) | 20 pt diameter — below 44 pt HIG minimum |
| `RoundIconButton` (trailing) | 34 pt diameter — below 44 pt HIG minimum |
| `RecordTile` button | Full tile (always ≥ 44 pt) ✓ |
| `ToggleTile` button | Full tile ✓ |
| `ChoiceMenu` overlay | Full tile face ✓ |
| `TrackSlider` drag | Full tile height × width ✓ |

The small controls (header switches, step buttons in header mode) deliberately trade HIG minimum size for information density. This is an accepted tradeoff for this use case; document but do not "fix" it without user testing.

---

## 5 · Layout

### Tile spec registry (`TileSpec`)

Every tile kind's layout constants live in **one place**: `WidgetKind.spec` in `CameraCore/PageLayout.swift`,
returning a `TileSpec`. A `TileSpec` carries `minimumSize`, `defaultSize`, `trailingFrom`, `footerFrom`,
`oneLineBelow` and `captionFrom` (the width below which a one-line tile whose glyph names it drops its caption, so the
value doesn't shrink past reading: Latency). Tile code reads from the spec, not from hardcoded literals:

```swift
let spec = WidgetKind.frameRate.spec
TileFrame(caption: "FPS", ..., trailingFrom: spec.trailingFrom, footerFrom: spec.footerFrom)
```

Adding or adjusting a layout threshold is one edit in `PageLayout.swift`; every call site follows automatically.

### Grid unit

The grid uses **columns × half-rows**. One half-row = `GridMetrics.rowHeight`: the page's automatic rows fit the screen, added rows shrink it to no less than 17 pt, then the page scrolls. Standard tiles are 2 half-rows tall; identity strip tiles are 2 half-rows; the shutter dial, frame rate, and ISO tiles are 4 half-rows; WB sliders are 3–4 half-rows; REC is 3 half-rows. A 1-half-row tile (`h=1`) is a "short" tile; two stack in one standard slot (timecode over clip name in the wide layout).

**Minimum tile sizes** (`WidgetKind.minimumSize`) — derived per tile from what the tile must show. Resizing stops there, and no built-in template places a tile below it (`tileMinimumsFitEveryTemplate`):

| Tile | Min (col × half-row) | Why |
|---|---|---|
| `timecode` | 1 × 1 | HH:MM:SS fits in one identity row |
| `label` | 1 × 2 | Letter + model needs 2 half-rows to read |
| `status` | 1 × 2 | Battery + card need 2 half-rows |
| `latency` | 1 × 1 | Caption + "99 ms" + icon fits in one line |
| `ndPreset` | 1 × 2 | Caption + value + ± buttons need height |
| `ndMinus`, `ndPlus` | 1 × 1 | Single-purpose step button |
| `shutterDial` | 1 × 2 | Falls back to value face; 2 half-rows keeps it readable |
| `shutterValue` | 1 × 1 | One-line mode is fine |
| `frameRate` | 1 × 2 | Caption + value + Fixed|Var switch needs 2 half-rows |
| `iso` | 1 × 2 | Caption + value + Base switch |
| `wbPreset` | 1 × 1 | Caption + value, one-line fine |
| `wbSliders` | 1 × 3 | Two slider rows + captions = 3 half-rows |
| `iris` | 1 × 2 | Slider + caption; 56pt one-line threshold |
| `record` | 1 × 2 | REC circle needs height to be visible |
| `clipName` | 1 × 1 | One column fits the letter and reel inline (a Blackmagic camera's whole name); wider shows more parts |
| `format` | 1 × 1 | One-line caption + value |
| `resolution`, `codec`, `desqueeze`, `dynamicRange` | 1 × 1 | Text values, one-line fine |
| `bitrate` | 1 × 1 | "600M" + detail fits on one line |
| `colorBars`, `falseColor`, `look`, `sensorFlip`, `viewAssist` | 1 × 1 | Single toggle label |
| `lut` | 2 × 2 | Caption + name + FC/ON switches; 2 cols for switches to be tappable |
| `focusMode` | 1 × 2 | Segmented control below caption needs 2 half-rows |
| `zebra`, `focusAssist`, `frameGuides`, `cleanFeed`, `statusText` | 1 × 1 | Single toggle or button (and the output it's set to) |
| `statusTextContent` | 2 × 2 | Caption + a two-way switch ("Cinematographer" or "Cine", "Director"); one column squeezed it past reading |
| `monitoring` | 1 × 1 | "Monitoring Options ›" on one line, or two in a narrow column |
| `liveView` | 2 × 2 | Useful picture preview needs 2 cols × 2 half-rows |
| `liveViewButton` | 1 × 1 | Icon + label fits in one cell |
| `playback` | 2 × 2 | Transport buttons row needs width and height |
| `haLow` | 1 × 1 | Caption + signal on one line; details drop as it narrows |
| `lock` | 1 × 1 | The padlock and "Lock" on one line |
| `ndMode`, `tally`, `colorGamut` | 1 × 1 | Caption + a short value, one-line fine (BURANO; Color Gamut also the FX3) |
| `call` | 1 × 1 | Single toggle label |
| `cameraMenu` | 1 × 1 | "Camera Menu ›" on one line (opens `CameraMenuView`) |

**Default sizes when added from palette** (`WidgetKind.defaultSize`):
- `timecode`, `clipName`, `latency`, `shutterValue`: 1 × 1
- `ndPreset`, `iris`, `format`, `resolution`, `codec`, `desqueeze`, `viewAssist`, `lut`: 2 × 2
- `shutterDial`, `frameRate`, `wbSliders`: 1 × 4
- `iso`: 2 × 4
- `focusMode`: 1 × 2
- Everything else: 1 × 2

### Built-in templates

**Narrow (2-column)** — iPhone column and 4-camera iPad. Strip order (top to bottom): identity (label + status → timecode + latency), ND preset, ND steps, shutter dial + FPS, ISO, WB (preset + focus left / sliders right), iris, LUT, LUT + False Color on every output (Blackmagic), codec + bitrate, Playback, REC. With several cameras side by side, every REC that ends its column reaches down to the page's bottom row, so the buttons line up whatever controls each camera has.

**Blackmagic (4-column)** — a Blackmagic camera's own block (`blackmagicCells`, picked by `CameraProfile.make`), laid out for the PYXIS 12K: name, camera info, timecode, and latency over HaLow; REC, ISO, the dial and the shutter value at one height; FPS, resolution, codec over de-squeeze, and dynamic range in a row (without a de-squeeze Codec takes the height); WB sliders beside the WB preset; iris in a row of its own (it closes for a manual lens), and on a body with filters ND (2 wide) with ND − and ND + in the row under it (until 2026-10-28 ND shared iris's row); LUT, False Color, Frame Guides and Monitoring Options; Playback beside Naming. A PYXIS has no ND, so its page has none of the ND rows. The HaLow tile is there only once this device has found a HaLow node (`DashboardStore.haLowSeen`, remembered across launches so the page keeps its shape); without it latency takes the corner.

**Wide (4-column)** — 1–2 cameras on iPad or Mac, every camera but the FX3 family and Blackmagic. Identity strip full width; REC + ISO + shutter dial in the first three columns; shutter value and WB preset stacked in column 4; FPS, ND, ND −, ND +; codec beside bitrate; resolution beside de-squeeze (Sony) or dynamic range (Blackmagic); WB sliders full width; iris full width; LUT + focus; then LUT and False Color on every output beside Monitoring Options (a Blackmagic camera); Playback. View Assist only shows on a camera with monitoring outputs, where it's the LUT on every output (`LayoutTemplates.shows`); a Sony page never had it.

**ARRI (4-column)** — an ARRI camera's own block (`arriCells`, picked by `make == .arri`), 2026-10-22: the VENICE block's shape with ARRI's controls: identity with clip name, latency over HaLow; REC, EI, the dial, shutter value over the WB preset; ND, ND −, ND +, sensor fps; sensor mode (2 wide), codec and de-squeeze; WB sliders (Kelvin and CC); iris (read off the lens); Look beside Frame Guides and False Color; Zebra, Peaking, Status Text and Monitoring Options; Playback across the bottom (its Web Remote tile went with the VENICE's Web GUI, 2026-10-28). Captions use ARRI's words: EI (not ISO), Look (not LUT), Peaking (not Focus Assist).

**VENICE (4-column)** — a VENICE / VENICE 2's own block (`veniceCells`, picked by `CameraProfile.isVenice`), 2026-10-22: identity with clip name, latency over HaLow; REC, EI (base ISO inside), the dial, shutter value over the WB preset; ND, ND −, ND +, frame rate (Select FPS); imager mode (2 wide), codec and de-squeeze; WB sliders; iris; LUT (which LUT and on/off) beside Frame Guides and False Color; Status Text, Monitoring Options, color bars, sensor flip; Playback across the bottom. No Web GUI tile: it came off the page on 2026-10-23 and out of Tiles on 2026-10-28 ("it can trip up the camera connecting from two places"); `Snapshot` version 9 takes any saved one off. What the body doesn't report drops out and closes up.

**ND − and ND + on every block with ND (2026-10-28).** The ND tile's own Step − + are off unless switched on in edit mode
(`PageWidget.stepByDefault`), so every block with an ND tile has the ND − and ND + tiles beside it, a column each, two
half-rows tall ("I only didn't want the step option on the drop down tile turned on by default. But I want the
stand alone buttons there by default"). A body without ND drops all three and the row closes. Changing a shipped block
means copying the set as it shipped (e.g. `LayoutTemplates.v4`) and resetting layouts built from it that nobody
changed (`Snapshot` version 9), so they follow the new block; a page someone arranged keeps its arrangement.

**FX3 (4-column)** — Identity strip of four at one size (name, camera info, timecode, latency); REC + ISO + shutter dial, shutter value over WB; WB sliders; iris; frame rate + codec; Playback beside bitrate over the next clip's name; LUT + focus. No resolution or de-squeeze: the FX3 doesn't offer them over the network.

### Edit-mode drag

The tile follows the finger and a ghost shows the cell it would land in: green where it fits, red where it would overlap
(the drop is then refused and the tile goes back). Resizing shows the ghost only. The move is measured in the window
(`DragGesture(coordinateSpace: .global)`), never in the tile's own coordinates: the tile moves with the drag, so in its
own coordinates every other reading comes out near zero and the tile shivers between the finger and home.

### Edit-mode settings

A tile's settings are set in edit mode, so in use a tile only does its one thing. Each sits in the tile's center as a
chip with what it's set to: the camera's letter beside the tile's name (`cameraChip`, with more than one camera), and
under them, for the ND tile, its step buttons (`stepChip`, "Step − +" ticked or not: a tap switches them, saved as
`PageWidget.showsStep`; a tile nobody has switched shows `PageWidget.stepByDefault`, which stays on through 2026-10-28 and then goes off by default), and for a monitoring toggle on a camera with outputs, the outputs it switches with ⌄ (`outputChip`: a
checklist in a popover off the tile — "<TILE> ON" in `caption`, All Outputs, a divider, then every output, a tick on the
ones it's set to, rows 40 pt tall — that stays open while outputs are ticked and closes on a tap outside it (2026-10-22:
a menu closed after every pick, and macOS menus can't be kept open); ticking all of them is All Outputs. What status
text shows stays one output, picked from a menu that closes on the pick). The camera chip's menu also moves every tile of that
camera on the page to another camera. A camera that isn't connected is drawn as a demo of itself while editing
(sample values, "demo" after its model in the label tile, "Camera A is offline: demo values" in the edit bar), so its
tiles look as they will; in Test Mode it's a working demo everywhere, and the top bar carries a yellow TEST badge
(the edit bar's yellow) so a page of sample values is never mistaken for a camera.

Moving a tile: the green outline is where it lands, and the tiles that make room slide there (`.snappy`, 0.28 s)
once the finger has rested for 200 ms, so a tile carried across the page doesn't shuffle everything it passes. Held
within 64 pt (or a tenth of the screen) of the top or bottom, the page scrolls under it a half-row every 150 ms.
Haptics follow the Home Screen: a light tap on pickup, a selection tick as tiles make room, a medium tap on the drop.
Undo sits beside Add Tile, dimmed when there's nothing to take back; on an upright iPhone it's an icon only.

Test Mode's banner ("Camera A is live", "Camera A is offline: its demo is showing") is a capsule in the chrome color
under the top bar, outlined and dotted in white when the camera is live (the color connected things use in Ink) and in
the edit bar's yellow when its demo takes over. It shows for 3 s, and a tap dismisses it. Tiles
keep their size; only the corner resizes. The edit bar never wraps a label: it drops the hint, then the title, then
on an upright iPhone keeps Add Tile and Done with the rest under ⋯. Done is in the look's accent, like the selected
page tab. A tile too short for the two rows puts them side by side,
and a smaller one shows the output chip alone; the chips keep clear of the corner controls (delete top-left, resize
bottom-right).

### Gap closing (`closingGaps`)

When the camera reports it doesn't have a control, that tile is dropped and the remaining tiles within the same camera's column/block **close up**. Strips (row-bands no tile crosses) maintain their order. Stacks within a strip move left into freed columns. The last stack absorbs any spare columns. This happens on every layout pass; no holes ever show.

On an automatic page of several cameras the columns line up row by row (`LayoutTemplates.materialize`): a row any of
them uses stays in every column, so a camera without that control has a gap there. The gap shows as a held tile
(`HeldGap`, `HeldGapTile`): the tile's shape at half the tile's fill, named when the other cameras have one control in
it ("No ND", "No Playback") and blank when they have several (a VENICE's LUT and False Color switches beside an FX6 whose
LUT tile has the same switch). A bare hole reads as a page drawn wrong. Customized pages keep their holes.

### iPhone column

The `narrow` template, drawn on the grid like every page. With a customized page and no iPhone arrangement of its
own, a camera's column changes only where the page did (`LayoutTemplates.phone`): removed tiles come off and the
gap closes, added tiles go below the column's own at phone size.

### Screen-size behavior

| Context | Width | Layout mode |
|---|---|---|
| iPhone (portrait) | 393–430 pt | Narrow 2-col column; horizontal pager if multi-camera |
| iPhone (landscape) | ~844 pt | Still < `compactWidth`(500)? No — iPhone landscape exceeds 500 pt, so it uses wide blocks |
| iPad mini portrait | 744 pt | Single camera: wide 4-col block; 4 cameras: narrow 2-col columns |
| iPad mini landscape | 1133 pt | Wide blocks; 2 cameras side by side |
| iPad Pro 11" | 1194 pt | Wide blocks; up to 2 per screen, pager for more |
| Mac compact | 980 pt | Wide blocks |
| Mac full | 1280 pt | Wide blocks |
| < `compactWidth` (500 pt) | — | Phone pager mode: one camera at a time, horizontal swipe |
| Per-column width < `wideMinWidth` (480 pt) | — | Narrow 2-col blocks |
| Per-column width ≥ `wideMinWidth` (480 pt) | — | Wide blocks |

**CameraSwitcher** appears when the page has more cameras than fit side by side. Height 38 pt, above the content area.

**CameraChips** replace it on a phone on its side, where 38 pt would cost the page rows. They're small chips in the top
bar and the edit bar: the letter in its camera's color, 24 pt tall, the camera shown filled and outlined, the rest
outlined faintly, and a red dot on one recording.

---

### `ClipNameTile` wide layout

Each part (the next clip's name, then `CaptionedValue`s for Title, ID and Reel) starts an equal column across the tile (`ColumnsRow`), at its own width: a wide tile is filled rather than left with a gap before its ›, and nothing stretches or truncates. `ColumnsRow`'s ideal width is the parts' own, so `ViewThatFits` falls back to `shortForm` (the next clip's name, or the camera ID) only when they don't fit. (Flexible frames on the parts made `ViewThatFits` take the full row and truncate "Reel" to "R…" in one column.)

### `HaLowTile` narrow widths

Details are dropped gracefully from least important to most important: `phyRate` → `retryRatio` → `channelWidth` → `MCS` → `batteryPercent` (node-level battery last). `ViewThatFits` tries the full detail string, then 2 parts, then 1 part, then the value alone. A narrow tile always shows at least the signal dBm value.

---

## 6 · Adding a New Tile

Checklist for every new tile:

- [ ] **`WidgetKind` case** — add to `PageLayout.swift`, with its `TileSpec` in `WidgetKind.spec`: a minimum from what it must show, at or below every template's size for it (`tileMinimumsFitEveryTemplate`), and its default size and thresholds.
- [ ] **`CameraState.offers`** — add the `case` pointing at the right optional on `CameraState`; never return `true` unconditionally unless it truly has no camera dependency (like `label`/`record`/`status`/`latency`/`timecode`).
- [ ] **Title** — add to `WidgetKind.title`; keep it short (≤ 20 chars), title-case.
- [ ] **Tile struct** — place in its family's file in `Tiles/` (identity, exposure, recording, monitoring, live view, playback). Use `TileFrame` unless the tile has no caption (identity, hero). Pass `trailingFrom` / `footerFrom` if the tile has mode switches.
- [ ] **Switch placement** — if the tile has mode switches, choose the right `TileFrame` thresholds; test all four `SwitchPlacement` cases manually (header, trailing, footer, inline/one-line).
- [ ] **Templates** — add to `narrowCells`, `wideCells`, `fx3Cells` and `blackmagicCells` in `PageLayout.swift` only if the tile belongs in the default layout. Not every tile goes in every template.
- [ ] **Snapshots** — run `dashboard-snapshot` at all six canonical sizes (see §7) and visually verify: no clipped text, caption top-left, value correctly sized, chevron only when pickable, switch in the right slot. Check new work against the gallery (see §7); re-render it when tiles change.
- [ ] **Alignment audit passes** — the gallery prints `alignment: every tile lines up`. A tile that only a Blackmagic camera has, or draws differently for one, goes in the gallery's PYXIS rows: the Naming tile's Blackmagic form was never rendered at the canonical sizes, which is how its misalignment shipped.
- [ ] **`CameraProfile.offered`** — if the tile should be saved in the per-camera profile so offline pages keep their shape, add its kind there.
- [ ] **Control API** — a tile that sets something is a field too: `ControlProtocol.swift` (state → `fields`), `ControlServer+Commands.swift` (`set`), the field list in `ControlServerTests.cameraCommandFieldCoverage`, and docs/control-api.md. Otherwise a field missing from the API no longer means the camera hasn't got the control (the BURANO's four new tiles shipped without them, 2026-10-27).
- [ ] **Docs** — docs/field-guide.md (what the tile does, for users), and the camera's controls doc (`docs/<camera>-controls.md`).
- [ ] **Doc comment** — one sentence in the tile struct explaining what the tile controls and any non-obvious reason it works the way it does (see existing tiles for examples).

---

## 7 · Canonical Snapshot Sizes

Run after any tile or layout change:

```bash
cd Packages/CameraKit
swift build --product dashboard-snapshot

BIN=.build/debug/dashboard-snapshot
CC_SNAPSHOT_SCALE=2 $BIN out-iphone.png        402  874  C    window
CC_SNAPSHOT_SCALE=2 $BIN out-ipad-mini-p.png   744  1133 C    window
CC_SNAPSHOT_SCALE=2 $BIN out-ipad-mini-l.png   1133 744  'A+B' window
CC_SNAPSHOT_SCALE=2 $BIN out-ipad-pro.png      1194 834  All  window
CC_SNAPSHOT_SCALE=2 $BIN out-mac-wide.png      1280 800  C    window
CC_SNAPSHOT_SCALE=2 $BIN out-mac-compact.png   980  680  'A+B' window
```

### Gallery render

`docs/gallery.png` is the canonical tile reference. Re-render it when tiles change:

```bash
cd Packages/CameraKit
swift build --product dashboard-snapshot
CC_SNAPSHOT_SCALE=1 .build/debug/dashboard-snapshot ../../docs/gallery.png 0 0 "" gallery
```

At 1× (about 1.5 MB in git each time it changes): the audit checks the alignment a 2× render was for. Render 2× to
a scratch file when you need to look closely.

The gallery mode ignores width/height/page arguments; it sizes its own canvas and reads `CC_SNAPSHOT_SCALE`.
Check new work against the gallery: every `WidgetKind` appears at all six canonical sizes (Blackmagic-only kinds from a
PYXIS 12K, Autofocus and Audio included; the BURANO-only ND Mode, Tally, Call, Color Gamut and Camera Menu from a BURANO;
User Frame A and B from a VENICE 2; the FX6's own, Shooting Mode to Assignable, from an FX6), then a PYXIS row for each tile it draws differently (Naming without a clip name, Live | Review, its WB
presets, ISO BASE, LUT), VENICE rows for its Audio tile's meters and its Playback tile's 4× under ◀◀ ▶▶, and FX6 rows
for Auto in its ISO and Iris tiles and its LUT tile's Outputs; the state strip at the bottom shows every tile state described in §8. The last column draws
every kind at its smallest on the grid (`WidgetKind.smallestOnGrid`: its minimum columns of a phone's 180 pt half width,
on its minimum half-rows at the 17 pt floor Fit to Screen can shrink rows to). It runs the audit (§ Alignment) and
exits 2 when a tile fails it; a canonical size below a tile's smallest isn't audited. Run it Standardized and Dynamic
(`CC_SNAPSHOT_TEXT_SIZE=dynamic`), and at the slider's sizes (`CC_SNAPSHOT_TEXT_SCALE=1.1` … `1.5`): every run must print
`alignment: every tile lines up`. An option gets its own row where it
changes the tile (the ND tile with its step buttons).

Real pages go smaller than the gallery's 17 pt floor: a page's automatic rows always fit the screen, so a phone on its
side draws 12 pt half-rows. Before a build, run the audit on real pages too, both Text Sizes, at least the VENICE, FX3,
FX6, BURANO and ALEXA lineups at an iPhone's content sizes upright and on its side (393 × 759, 759 × 372, 375 × 647) and
an iPad's: `CC_SNAPSHOT_AUDIT=1 CC_SNAPSHOT_BODIES=venice2 dashboard-snapshot out.png 759 372 "" window`. On
2026-10-28 that found Playback's switch, the LUT tile's one-line switches and the iris knob cut off on phones, none of
which the gallery could see.

### Checking a new tile's renders

Add `dashboard-snapshot ... gallery` to the §6 checklist and re-render `docs/gallery.png` after adding the tile.

Check each render:
- Identity strip readable at that size
- No captions clipped or truncated
- No value text overflowing a tile
- Switch placement matches the thresholds for that tile width
- Tiles the simulated camera doesn't offer are absent (no placeholders)

---

### Alignment: when things are centered, when they're left-aligned

**The rule: anything with a caption reads left to right; anything without one is centered.** A caption and its value
are a label and a field, like a form: they start at the same left edge in every tile, so the eye runs down a column
of them. A tile with no caption is one thing (a status, a single readout, a big button), and centering makes it read
as a whole at a glance.

| What | Horizontal | Vertical |
|---|---|---|
| Caption | leading, at `inset` | top: the 14 pt caption row, same baseline in every tile |
| Picker value under a caption | leading; chevron at the trailing edge, on the value's line | centered in the space under the caption at every tile height |
| Readout beside a caption (f-number, Kelvin, tint) | trailing | on the caption's baseline |
| Mode switches | header: trailing. Own column: left-aligned under the column's caption, which sits on the tile's caption row. Bottom row: after its caption | centered on their line |
| Slider track, segmented control | full width between the insets | centered in the space under the caption |
| One-line tile | caption leading, content after it, switches trailing | everything centered on the line |
| Identity readouts (name + model, battery + card, REC time) | centered | on the middle of the capitals (`.capCenter`, from the font's cap height), not the line box, which has descender room and sits text high |
| Hero controls (REC, shutter dial) | centered | centered |

Adding a tile? Ask one question: does it have a caption? Yes → the left-aligned anatomy (`TileFrame`). No → center it
like the identity readouts or a hero control. Don't mix the two inside one tile.

**Captions are built from three pieces and nothing else:** `CaptionRow` at the top of a two-row tile, `TileFrame`'s
caption leading a one-line tile, `CaptionedValue` for a caption beside a value inside the content. The rules above
held for a year in prose and were still broken in four tiles, because every tile hand-made its own `HStack`; the
pieces make the rule the default, and the audit below catches a tile that goes around them.

#### The alignment audit

`AlignmentAudit` measures every caption in a render and fails it when:

- a caption, a value or a control (`.audited(.control)`: sliders, switches, chips, step buttons) lies outside its tile:
  nothing is ever cut off (Tint's slider hung off the bottom of a phone's tile, 2026-10-28). A caption counts by its
  letters, capitals with no descenders: its line box less 2/13 of it above and below (2 pt at the standard 10 pt), so a
  12 pt tile on a phone on its side, whose captions read whole, passes;
- two captions on one line sit on different baselines (a caption that gave way to a narrow line is smaller, on its
  neighbors' baseline);
- a caption at the top of a two-row tile isn't in a `CaptionRow`;
- a tile's caption row's baseline sits at a different height from every other tile's of its Dynamic scale (Dynamic
  draws a bigger tile's row lower).

The gallery always runs it; any other render runs it with `CC_SNAPSHOT_AUDIT=1`. It prints `ALIGNMENT:` lines and
exits 2 after writing the image, and `alignment: every tile lines up` when it passes. It found the Naming tile's
2 pt step (put the old layout back and it fails), plus the ISO, iris, shutter and ND steps nobody had noticed.
It checks values too: a value's text starts at its area's left edge and sits in the middle of it, under the
caption row or on the one line (it caught HaLow's value sitting at the bottom). What it can't see: a glyph off its
line, color, and size, which the type roles cover. Those stay with the eye, on renders at 2×.



### Two rows, or one line

Every captioned tile has two forms: **two rows** (caption row above the content) and **one line** (caption, content
and switches side by side, centered). A tile switches to one line at the height where its two-row form would squeeze
its content, not at a fixed size, so nothing ever touches an edge or spills out:

| Tile content | One line below | Why |
|---|---|---|
| A value (pickers) | 49 pt (`Theme.oneLineBelow`) | caption row + a 15 pt value line (18 pt) between the insets: two rows never draw a value smaller than one line does |
| A slider (iris) | 56 pt: `2 × 7 + 14 + 4 + 24` | caption row + a full 24 pt knob |
| A full-size segmented control (focus) | 60 pt | caption row + a 30 pt switch |
| Switches in their own column (LUT) | 58 pt | caption row over a 30 pt switch column |

On an iPhone (rows of ~40–48 pt after the safe areas) iris, LUT and focus read as one line; with room they get two
rows. The WB sliders keep each track at least its knob's 20 pt where they can: stacked where both rows fit, one line
each in a wide tile, side by side in a wide, short one. A narrow tile can't go to one line, so it keeps both rows on
tracks down to 14 pt (64 pt between the insets), then shows Temp alone rather than cut
Tint off (a phone's 2-wide column, 2026-10-28). They lay out from the top, since centered overflow once lifted their
caption row above every other tile's (2026-10-26). New tiles follow this rule: work out what the two-row form needs at
full size, and go to one line below that.

> **Render phones at their real content height.** A device's safe areas take ~90 pt (iPhone 15 Pro: 393×852 points, 393×759 usable), so a full-height render hides overflow. Use `dashboard-snapshot out.png 393 759 "<page>" window` (and `CC_SNAPSHOT_STATE=<saved setup>` for a real device's pages).

## 8 · States

Every tile can be in one of these states. Each state has a specific visual form and a specific code path.

### Live (writable, connected)

The camera is connected (`ConnectionState.connected`) and the field is writable (`isWritable == true`) with at
least one option. The tile's value shows in `Theme.text`; `ChoiceMenu` is active; `PickerValue` shows its
chevron. `TrackSlider` and `MiniSegmented` accept touches.


### Read-only

The field exists but `isWritable == false`. `PickerValue` receives `isLive: false`: `ChoiceMenu` gets
`isEnabled: false`, which skips the `Menu` overlay entirely. With the camera connected the value is the camera's
real setting, set on the camera: `ValueLine` draws it in `Theme.text` with a lock where the chevron would be
(`setOnCamera`; VoiceOver's hint says "Set on the camera"). Grayed, it reads as broken or stale. With the
camera not connected the value is stale and grays (`Theme.secondaryText`, no lock); `WidgetView` passes the camera's
state down as `cameraIsControllable`.

FX3 bitrate under XAVC S-I is the canonical example: `state.recordingSetting` has `isWritable: false` because
the bitrate follows the frame rate on that body.

A read-only `ToggleTile` draws its title in `Theme.secondaryText` and takes no taps: False Color, Zebra and the other
every-output overlays when every output is on clean feed (`MonitoringState.onEverywhere`). In Monitoring Options an
output's own switches gray the same way while its clean feed is on (`MonitorOutput.setting`).


### Not offered by this camera

The tile's field is nil on `CameraState`. `CameraState.offers(_:)` returns false. On automatic pages,
`LayoutTemplates.closingGaps` omits the tile and the remaining tiles in that camera's block close up (no
holes). On customized pages, the tile stays where the user placed it but renders grayed (`opacity 0.28`) in
edit mode and is hidden in use.


FX3 never offers `.resolution`, `.desqueeze`, or `.clipName`; those are absent from `fx3Cells` and
`CameraState.offers` returns false for them when the camera has reported.

### Not reported yet

The field on `CameraState` is nil because the camera hasn't sent it yet — different from "not offered":
the camera may send it once a full sync completes. The tile renders with `Tile(isEnabled: false)`, which
applies `opacity 0.28` to the content layer only; the slot-color border stays full opacity.


`CameraState.hasReported` (`recording.state != .unknown`) is the boundary: before the first full read,
everything is in this state. The `REC` tile disables itself until `recording.state != .unknown`.

### Pending

A value was sent and not yet confirmed by the camera. `Choice.pending` is non-nil; `Choice.shown` returns it
instead of `Choice.value`, so the tile immediately shows the new value at full opacity. The tile stays
writable (another tap sends a new command). The visual is identical to Live; no spinner or overlay.

`REC` is the exception: it dims to `opacity 0.4` while `recording.request != nil` and cannot be tapped
again until the camera confirms.


### Recording tally

`recording.state == .recording`. The `RecordTile` shows a red-filled circle with "STOP" in white. The
`StatusTile` border switches to `Theme.recording`. The `TimecodeTile` dot and its REC-time value go red.
`WidgetView` sets `tally = true` and passes it to `StatusTile`, `RecordTile`, and any `ToggleTile` that
opts into it.


### Failure (REC FAILED)

`recording.failure != nil`. The `RecordTile` shows an orange "REC FAILED" badge (top-left, via `Tile.badge`).
The button reverts to standby appearance; the tile stays enabled so the operator can try again.


There is no "camera refused REC" message beyond this badge. The badge is orange so it reads as a warning
rather than a new tally.

### Connection states in the label tile

`LabelTile` shows the connection phase as the model-name line (second element of the identity pair).

| `ConnectionState` | Text | Color |
|---|---|---|
| `.connecting` | "Connecting" | `Theme.secondaryText` |
| `.awaitingApproval` | "Approve on camera" | `Color.orange` |
| `.fingerprintChanged(_)` | "Fingerprint changed" | `Theme.recording` |
| `.stale` | "Resyncing" | `Theme.secondaryText` |
| `.disconnected` | "Offline" | `Theme.secondaryText` |
| `.failed(_)` | "Failed" | `Theme.recording` |
| `.connected` + model known | model name (e.g. "FX3") | `Theme.secondaryText` |
| `.connected` + `isDemo` | "\(model) demo" | `Theme.secondaryText` |

The `TimecodeTile` dot mirrors the connection: green when connected and idle, red when recording or failed,
orange when awaiting approval, gray otherwise.

With the link down (anything but `.connected`), everything on the camera's page is what it last said, and grays:
the controls' values (Read-only, above) and the read-outs too (timecode, battery, media, format), where latency shows
none. The label tile is the one thing that keeps its color, and it says why (`LabelTile.linkStatus`). On an iPhone,
where the other cameras' pages are out of view, the camera switcher says the same words in place of the model, and
VoiceOver reads them, with Showing and Recording, in both switchers.


### Locked

`@Environment(\.controlsLocked) var locked` is `true`. Set by the lock button in the top bar, or the Lock tile
(`LockTile`, Add Tile only, 2026-10-26): one lock, `DashboardView.isLocked`, which the tile switches through the
`toggleControlsLock` environment action, so either locks every tile and either unlocks them.
`Tile.body` calls `.allowsHitTesting(isEnabled && (!locked || ignoresLock))`, so tiles ignore touches. A control's
content grays to `Theme.lockedOpacity` (0.55): about the gray of a value the camera won't change right now, so the page
reads as locked and every value still reads. It isn't the 0.28 of a control the camera hasn't got, which a lock mustn't
look like, and a disabled tile stays at 0.28 rather than fading further. Read-outs keep their brightness
(`Tile(isReadout:)`): the camera's letter, battery and media, timecode, latency, HaLow, Format, live view's picture (its
button grays), and REC while it rolls, where STOP is the tally. Only the Lock tile sets `ignoresLock`: it's the one tile
that answers while they're locked, or nothing on the page could unlock them, and it doesn't gray. It fills `locked`
(the padlock's yellow, black on it) and its padlock closes while locked, the padlocks the bar uses (`lock.fill`,
`lock.open`). It filled `engaged` until 2026-10-27, and on a page the lock had grayed that gray didn't stand out. Tiles carry no lock logic of
their own: Playback grayed its own buttons and switch until 2026-10-26, the only tile that changed look when locked.

The lock only reaches what's inside a tile's content. A gesture attached to the outside of `Tile` gets past it and must
check `locked` itself: the timecode tile's tap (a VENICE's timecode / duration switch) did until 2026-10-26.


Switches inside `MiniSegmented` and `PillToggle` have their own `isEnabled` parameters; `TileFrame`'s
`isEnabled` guard is the tile level, not the component level. The lock is tile-level via the environment key.

### Demo

`camera.isDemo == true`. `LabelTile` appends " demo" to the model name (e.g. "FX3 demo"). No other visual
difference; the demo camera uses `MockCameraBackend` and behaves like a live camera for all tile states.

---

## 9 · Open Deviations

Issues in the current source, most visible first.

1. **`RoundIconButton` touch targets below HIG minimum** — `NDPresetTile`: header-mode buttons are 20 pt, trailing-mode 30 pt. ND is FX6/BURANO only; worth 36 pt in trailing and footer placements when those bodies are tested.

2. **`PillToggle` height 20 pt in the header** — the LUT tile's FC and ON switches when it's too short for its switch column. Under the 44 pt HIG minimum; the column and one-line placements use 28 pt.

3. **The shutter dial's header-switch offset** — with the Angle | Speed switch in its header (the iPhone column), the dial sits `.padding(.top, 8).padding(.bottom, 2)` inside `TileFrame` to clear the overhanging switch, not the standard insets.

4. **`SliderRow` one-line mode uses fixed column widths** — `Caption(caption).frame(width: 34)` and `value.frame(minWidth: 46)`; the `WhiteBalanceSlidersTile` one-line threshold `geo.size.width < 220` is a magic number too.

5. **`locked` is a slot color** — the padlock and the Lock tile fill with `SlotColor.yellow`, which is also a yellow camera's color and the TEST badge's. Chosen to match the padlock rather than add a color (2026-10-27). With custom colors on it's the picked Highlight instead, which can match a camera's own color just as easily.

6. **`TrackSlider` minimum drag distance is 2 pt** — intentional (a tap does nothing; the ‹ › buttons step), but a system change to the minimum distance would break it silently.

7. **`WhiteBalanceSlidersTile` shows the tint row before a camera reports** — `showsTint = wb == nil || wb?.tint != nil` keeps the tile's shape until the camera answers; a body without tint then drops the row, a small layout shift after connecting.

`FormatTile` and the `.look` tile only render for layouts saved by earlier builds; Add Tile doesn't offer them.

