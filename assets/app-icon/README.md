# App icon

Four camera tiles, drawn the way the app draws its own tiles, in the Ink look (2026-10-15): true black with the
faintest lift (so it doesn't read as a hole on a dark wallpaper), borderless tiles, each tile's caption a bar in its
camera's color. Camera A is rolling, as the app's REC tile draws it: a red ring. The other three tiles show:

- a readout (a value);
- the latency mark;
- the shutter tile's ANG | SPD control.

The four tiles were chosen on 2026-10-10, and their Ink version ("1 Inked", round 05) on 2026-10-15, with the app's
new look.

| File | What it is |
|---|---|
| `tiles-icon.svg` | **Layered vector master.** It has one layer per tile (Tile A to D), each split into Body and Glyph sublayers, over a Background layer. The groups come through as named layers in Figma, Illustrator and Inkscape. |
| `layers/1-background.svg`, `2-tiles.svg`, `3-glyphs.svg` | The same art split into full-canvas layer files, ready for Icon Composer (Liquid Glass) or any tool that stacks layers. |
| `final-preview.png` | The iPhone/iPad and Mac versions side by side. |
| `../../App/CameraControl/Assets.xcassets/AppIcon.appiconset/` | What ships: `ios-1024.png` (full bleed, no alpha) and `mac-16` to `mac-1024.png` (macOS rounded body with a shadow). |

All of it comes from `scripts/app-icon.swift` (`swift scripts/app-icon.swift` from the repo root). The PNGs and the
SVG use the same geometry: rendered with `rsvg-convert`, the SVG matches `ios-1024.png` to within 0.3/255 on average.
To tweak the icon, edit the script and re-run it.

If the icon gets reworked by hand in Figma or Illustrator, start from `tiles-icon.svg` and export the new PNGs into
the appiconset. From then on that file is the source, so stop running the script: it would overwrite the PNGs.
