#!/usr/bin/env python3
"""Screenshots of Tiles' own pages, drawn by dashboard-snapshot with demo cameras shown as real ones.

The App Store's, each under a headline at the sizes App Store Connect takes: assets/app-store/<device>/<n>-<name>.png.
The README's, the device's screen as a card on a cool off-white, rounded as the screen is, with a soft shadow:
docs/images/*.jpg.

    python3 scripts/screenshots.py                  # all of them
    python3 scripts/screenshots.py ipad readme      # some: ipad, iphone-6.9, iphone-6.3, mac, readme

Needs Pillow (with raqm, for kerning) and the SF Pro fonts in /Library/Fonts. Builds dashboard-snapshot first.
"""
import os
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = pathlib.Path(__file__).resolve().parent.parent
PACKAGE = REPO / "Packages/CameraKit"
OUT = REPO / "assets/app-store"
FONTS = pathlib.Path("/Library/Fonts")

# A device's screen in points, its scale, and what the system keeps at its edges: the app draws between them.
# corner: the screen's corner radius in points; chrome: a Mac window's title bar.
DEVICES = {
    "ipad": dict(canvas=(2752, 2064), screen=(1376, 1032), scale=2, top=24, bottom=20, corner=18),
    "iphone-6.9": dict(canvas=(1320, 2868), screen=(440, 956), scale=3, top=62, bottom=34, corner=55),
    "iphone-6.3": dict(canvas=(1206, 2622), screen=(402, 874), scale=3, top=62, bottom=34, corner=55),
    "mac": dict(canvas=(2880, 1800), screen=(1440, 860), scale=2, top=0, bottom=0, corner=12, chrome=28),
}

# name, headline, line under it, snapshot settings (CC_SNAPSHOT_<key>), mode (window or edit).
# Cameras side by side have the same layout: bodies of one family, or a VENICE beside ALEXAs, whose blocks and columns
# line up. A BURANO or an FX6 beside either leaves rows that don't match.
IPAD = [
    ("cameras", "Every camera on one page",
     "Exposure, REC, LUTs and playback for each camera on set, side by side.",
     dict(BODIES="venice2,alexa35,alexaMini"), "window"),
    ("rec", "Rolling when the camera is",
     "Tiles shows rolling once the camera confirms it, and linked cameras roll together.",
     dict(BODIES="fx6,fx6", RECORDING="A,B"), "window"),
    ("layout", "Laid out your way",
     "Drag, resize and add tiles. Portrait and landscape keep their own layouts.",
     dict(BODIES="venice2"), "edit"),
    ("glance", "Readable at a glance",
     "Large values and the camera's own names, on a page for one camera or for several.",
     dict(PYXIS="1"), "window"),
    ("links", "Made for long links",
     "Latency on every page, the Wi-Fi HaLow link's signal, and cameras that reconnect on their own.",
     dict(BODIES="venice2,venice2", HALOW="1"), "window"),   # the VENICE block has HaLow under latency
]
IPHONE = [
    ("camera", "The whole camera in one hand",
     "ISO, shutter, white balance, ND, LUT and REC, sized for a thumb.",
     dict(BODIES="fx3"), "window"),
    ("rec", "Rolling when the camera is",
     "Tiles shows rolling once the camera confirms it, not when you tap.",
     dict(BODIES="fx6", RECORDING="A"), "window"),
    ("layout", "Laid out your way",
     "Drag, resize and add tiles, for each camera.",
     dict(BODIES="burano"), "edit"),
]
MAC = [
    ("cameras", "Every camera on one page",
     "Exposure, REC, LUTs and playback for each camera, in a window beside your monitor.",
     dict(BODIES="venice2,alexa35,alexaMini"), "window"),
    ("rec", "Rolling when the camera is",
     "Tiles shows rolling once the camera confirms it, and linked cameras roll together.",
     dict(BODIES="fx6,fx6,fx6", RECORDING="A,B,C"), "window"),
    ("layout", "Laid out your way",
     "Drag, resize and add tiles. Every page keeps its own layout.",
     dict(BODIES="venice2"), "edit"),
]
SHOTS = {"ipad": IPAD, "iphone-6.9": IPHONE, "iphone-6.3": IPHONE, "mac": MAC}

# The README's: file, device, snapshot settings, mode, width in pixels.
README = [
    ("ipad-two-cameras.jpg", "ipad", dict(BODIES="venice2,venice2"), "window", 1800),
    ("iphone-fx3.jpg", "iphone-6.3", dict(BODIES="fx3"), "window", 598),
    ("iphone-two-cameras.jpg", "iphone-6.3", dict(BODIES="fx3,fx6"), "window", 598),
    ("ipad-pyxis.jpg", "ipad", dict(PYXIS="1"), "window", 1800),
    ("ipad-edit.jpg", "ipad", dict(PYXIS="1"), "edit", 1800),
]

BACKGROUND_TOP, BACKGROUND_BOTTOM = (0, 0, 0), (24, 24, 27)
HEADLINE, SUBHEAD, EDGE = (255, 255, 255), (152, 152, 159), (58, 58, 62)
CARD, CARD_SHADOW = (242, 244, 247), (16, 22, 34)


def snapshot(binary, device, settings, mode, path):
    """The app between the system's edges, at the device's scale."""
    width, height = device["screen"]
    height -= device["top"] + device["bottom"]
    env = dict(os.environ, CC_SNAPSHOT_SHOWCASE="1", CC_SNAPSHOT_SCALE=str(device["scale"]),
               **{f"CC_SNAPSHOT_{key}": value for key, value in settings.items()})
    subprocess.run([str(binary), str(path), str(width), str(height), "", mode], env=env, check=True,
                   stdout=subprocess.DEVNULL)
    return Image.open(path).convert("RGB")


def screen_image(device, app):
    """The device's screen: the app, with the system's bars as empty black above and below it (a Mac: a window)."""
    scale = device["scale"]
    width, height = (v * scale for v in device["screen"])
    if "chrome" in device:
        bar = device["chrome"] * scale
        screen = Image.new("RGB", (width, height + bar), (30, 30, 32))
        screen.paste(app, (0, bar))
        draw = ImageDraw.Draw(screen)
        for i, color in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
            cx, cy, r = (20 + 20 * i) * scale, bar // 2, 6 * scale
            draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=color)
        return screen
    screen = Image.new("RGB", (width, height), (0, 0, 0))
    screen.paste(app, (0, device["top"] * scale))
    return screen


def rounded(image, radius):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, image.width - 1, image.height - 1), radius=radius, fill=255)
    return mask


def card(screen, corner):
    """The screen on a cool off-white, its corners rounded as the device's are (drawn 4× and scaled down, so they're
    smooth), lifted off the background by two shadows: a close one where it sits, a wide soft one below."""
    side = max(screen.size)
    pad = round(side * 0.06)
    big = Image.new("L", (screen.width * 4, screen.height * 4), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, big.width - 1, big.height - 1), radius=corner * 4, fill=255)
    mask = big.resize(screen.size, Image.LANCZOS)
    canvas = Image.new("RGB", (screen.width + 2 * pad, screen.height + 2 * pad), CARD)
    for drop, blur, strength in ((0.003, 0.004, 0.25), (0.018, 0.032, 0.32)):
        shadow = Image.new("L", canvas.size, 0)
        shadow.paste(mask, (pad, pad + round(side * drop)))
        shadow = shadow.filter(ImageFilter.GaussianBlur(side * blur)).point(lambda v: round(v * strength))
        canvas.paste(CARD_SHADOW, (0, 0, *canvas.size), shadow)
    canvas.paste(screen, (pad, pad), mask)
    return canvas


def wrap(draw, text, font, width):
    """As few lines as fit in `width`, as even as can be: no word left alone on the last line."""
    words = text.split()
    count = 1
    while True:
        best = None
        # Every way to break the words into `count` lines; text here is a few words, so trying them all is cheap.
        def splits(start, left):
            if left == 1:
                yield [" ".join(words[start:])]
                return
            for end in range(start + 1, len(words) - left + 2):
                for rest in splits(end, left - 1):
                    yield [" ".join(words[start:end])] + rest
        for lines in splits(0, count):
            widths = [draw.textlength(line, font=font) for line in lines]
            if max(widths) <= width and (best is None or max(widths) - min(widths) < best[0]):
                best = (max(widths) - min(widths), lines)
        if best or count == len(words):
            return best[1] if best else words
        count += 1


def compose(device, screen, headline, subhead):
    cw, ch = device["canvas"]
    landscape = cw > ch
    canvas = Image.new("RGB", (cw, ch))
    top, bottom = BACKGROUND_TOP, BACKGROUND_BOTTOM
    gradient = ImageDraw.Draw(canvas)
    for y in range(ch):
        t = y / (ch - 1)
        gradient.line([(0, y), (cw, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))

    unit = cw / (2752 if landscape else 1320)  # type and spacing scale with the canvas
    head_font = ImageFont.truetype(str(FONTS / "SF-Pro-Display-Bold.otf"), round((118 if landscape else 104) * unit))
    sub_font = ImageFont.truetype(str(FONTS / "SF-Pro-Display-Regular.otf"), round((52 if landscape else 50) * unit))
    draw = ImageDraw.Draw(canvas)
    text_width = cw * (0.72 if landscape else 0.86)
    head_lines = wrap(draw, headline, head_font, text_width)
    sub_lines = wrap(draw, subhead, sub_font, text_width)
    head_step, sub_step, gap = round(head_font.size * 1.1), round(sub_font.size * 1.3), round(22 * unit)
    # The same room for the type on every screenshot of a device (a headline of one line on a Mac or an iPad, two on an
    # iPhone, and two lines under it), so the screens sit in one place as people swipe through; the type is centered in it.
    room = (1 if landscape else 2) * head_step + gap + 2 * sub_step
    used = len(head_lines) * head_step + gap + len(sub_lines) * sub_step
    top = round((130 if landscape else 170) * unit)
    y = top + max(0, room - used) // 2
    for line in head_lines:
        draw.text((cw / 2, y), line, font=head_font, fill=HEADLINE, anchor="mt", features=["kern"])
        y += head_step
    y += gap
    for line in sub_lines:
        draw.text((cw / 2, y), line, font=sub_font, fill=SUBHEAD, anchor="mt", features=["kern"])
        y += sub_step
    y = top + max(room, used) + round((80 if landscape else 90) * unit)

    # The whole screen, as big as fits under the type with a margin below it, and no wider than most of the canvas.
    room = ch - y - round((110 if landscape else 130) * unit)
    scale = min(room / screen.height, cw * 0.86 / screen.width)
    shown = screen.resize((round(screen.width * scale), round(screen.height * scale)), Image.LANCZOS)
    shown_width = shown.width
    y += (room - shown.height) // 2
    corner = round(device["corner"] * device["scale"] * scale)
    edge = max(2, round(3 * unit))
    x = (cw - shown_width) // 2
    frame = Image.new("RGB", (shown.width + 2 * edge, shown.height + 2 * edge), EDGE)
    canvas.paste(frame, (x - edge, y - edge), rounded(frame, corner + edge))
    canvas.paste(shown, (x, y), rounded(shown, corner))
    return canvas


def main():
    wanted = sys.argv[1:] or [*DEVICES, "readme"]
    subprocess.run(["swift", "build", "--product", "dashboard-snapshot"], cwd=PACKAGE, check=True,
                   stdout=subprocess.DEVNULL)
    binary = PACKAGE / ".build/debug/dashboard-snapshot"
    with tempfile.TemporaryDirectory() as tmp:
        if "readme" in wanted:
            for file, name, settings, mode, width in README:
                device = DEVICES[name]
                app = snapshot(binary, device, settings, mode, pathlib.Path(tmp) / f"readme-{file}.png")
                screen = screen_image(device, app)
                factor = width / screen.width
                screen = screen.resize((width, round(screen.height * factor)), Image.LANCZOS)
                image = card(screen, round(device["corner"] * device["scale"] * factor))
                path = REPO / "docs/images" / file
                image.save(path, quality=90, optimize=True)
                print(f"{path.relative_to(REPO)}  {image.width}×{image.height}  {path.stat().st_size // 1024} KB")
        for name in (n for n in wanted if n in DEVICES):
            device = DEVICES[name]
            (OUT / name).mkdir(parents=True, exist_ok=True)
            for n, (slug, headline, subhead, settings, mode) in enumerate(SHOTS[name], 1):
                app = snapshot(binary, device, settings, mode, pathlib.Path(tmp) / f"{name}-{slug}.png")
                image = compose(device, screen_image(device, app), headline, subhead)
                path = OUT / name / f"{n}-{slug}.png"
                image.save(path, optimize=True)
                print(f"{path.relative_to(REPO)}  {image.width}×{image.height}  {path.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
