#!/usr/bin/env python3
"""Generate PNG icons for the Tiles Stream Deck plugin.

All icons are white on transparent, monochrome, as required by the Elgato guidelines.
Key icons: 72x72 px + 144x144 @2x
Action list icons: 20x20 px + 40x40 @2x
Plugin icon: 256x256 + 512x512 @2x
"""
import os
import math
from PIL import Image, ImageDraw, ImageFont

IMGS = os.path.join(os.path.dirname(__file__), "com.toldwell.twcc.sdPlugin", "imgs")
os.makedirs(IMGS, exist_ok=True)

WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)
RED   = (240, 60, 56, 255)
DK    = (40,  40,  40, 255)  # dark background for colored states


def canvas(size):
    return Image.new("RGBA", (size, size), CLEAR)


def circle(draw, cx, cy, r, fill=None, outline=None, width=1):
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=fill, outline=outline, width=width)


def rect(draw, x, y, w, h, fill=None, outline=None, width=1, radius=0):
    if radius > 0:
        draw.rounded_rectangle([x, y, x + w, y + h], radius=radius, fill=fill, outline=outline, width=width)
    else:
        draw.rectangle([x, y, x + w, y + h], fill=fill, outline=outline, width=width)


def text_center(draw, img_size, txt, font_size, color=WHITE):
    """Draw text centered in the image."""
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", font_size)
    except Exception:
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size)
        except Exception:
            font = ImageFont.load_default()
    bbox = draw.textbbox((0, 0), txt, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    x = (img_size - tw) / 2 - bbox[0]
    y = (img_size - th) / 2 - bbox[1]
    draw.text((x, y), txt, font=font, fill=color)


def save(img, name, size):
    path = os.path.join(IMGS, f"{name}.png")
    img.save(path)
    # @2x
    path2 = os.path.join(IMGS, f"{name}@2x.png")
    img2 = img.resize((size * 2, size * 2), Image.LANCZOS)
    img2.save(path2)
    print(f"  {path}")


# ─── Plugin icon (256x256) ────────────────────────────────────────────────────

def make_plugin_icon():
    for sz in [256, 512]:
        img = canvas(sz)
        d = ImageDraw.Draw(img)
        m = sz // 8
        # Circle ring
        r = sz // 2 - m
        cx = cy = sz // 2
        lw = max(4, sz // 32)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=lw)
        # Inner REC dot
        ri = sz // 8
        d.ellipse([cx - ri, cy - ri, cx + ri, cy + ri], fill=WHITE)
        suffix = "" if sz == 256 else "@2x"
        path = os.path.join(IMGS, f"plugin-icon{suffix}.png")
        img.save(path)
        print(f"  {path}")

make_plugin_icon()


# ─── Action list icons (20x20) ────────────────────────────────────────────────

def make_action_icon(name, draw_fn):
    for sz in [20, 40]:
        img = canvas(sz)
        d = ImageDraw.Draw(img)
        draw_fn(d, sz)
        suffix = "" if sz == 20 else "@2x"
        path = os.path.join(IMGS, f"{name}{suffix}.png")
        img.save(path)
        print(f"  {path}")

def icon_rec(d, sz):
    m = sz * 0.15
    r = (sz - 2 * m) / 2
    cx = cy = sz / 2
    lw = max(1, int(sz * 0.12))
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=lw)
    ri = r * 0.35
    d.ellipse([cx - ri, cy - ri, cx + ri, cy + ri], fill=WHITE)

def icon_iso(d, sz, arrow_up=True):
    m = sz * 0.15
    lw = max(1, int(sz * 0.1))
    # "ISO" indicator: two horizontal lines + arrow
    mid = sz / 2
    # bar
    d.line([(m, mid), (sz - m, mid)], fill=WHITE, width=lw)
    # arrow
    ah = sz * 0.25
    hw = sz * 0.2
    if arrow_up:
        d.polygon([(mid, m), (mid - hw, mid - ah + m), (mid + hw, mid - ah + m)], fill=WHITE)
    else:
        d.polygon([(mid, sz - m), (mid - hw, sz - m - ah + m), (mid + hw, sz - m - ah + m)], fill=WHITE)

def icon_wb(d, sz):
    m = sz * 0.15
    lw = max(1, int(sz * 0.1))
    # Kelvin / temperature: thermometer-like symbol
    r = (sz - 2 * m) / 3
    cx, cy = sz / 2, sz * 0.55
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=lw)
    stem_w = r * 0.5
    d.rectangle([cx - stem_w/2, m, cx + stem_w/2, cy - r + lw], outline=WHITE, width=lw)

def icon_lut(d, sz):
    m = sz * 0.15
    lw = max(1, int(sz * 0.1))
    # Three horizontal gradient-like bars
    bar_h = (sz - 2 * m) / 4
    for i in range(3):
        y = m + i * bar_h * 1.2
        d.rounded_rectangle([m, y, sz - m, y + bar_h],
                             radius=bar_h * 0.3, outline=WHITE, width=lw)

def icon_false_color(d, sz):
    m = sz * 0.15
    lw = max(1, int(sz * 0.1))
    # Eye symbol
    ex, ey = sz / 2, sz / 2
    ew, eh = (sz - 2 * m) * 0.9, (sz - 2 * m) * 0.5
    # Upper arc
    d.arc([ex - ew/2, ey - eh, ex + ew/2, ey + eh * 0.3], start=210, end=330, fill=WHITE, width=lw)
    # Lower arc
    d.arc([ex - ew/2, ey - eh * 0.3, ex + ew/2, ey + eh], start=30, end=150, fill=WHITE, width=lw)
    ri = sz * 0.1
    d.ellipse([ex - ri, ey - ri, ex + ri, ey + ri], fill=WHITE)

def icon_camera(d, sz):
    m = sz * 0.15
    lw = max(1, int(sz * 0.1))
    # Simple camera body
    bw = sz - 2 * m
    bh = bw * 0.65
    by = (sz - bh) / 2 + sz * 0.05
    d.rounded_rectangle([m, by, sz - m, by + bh], radius=lw * 1.5, outline=WHITE, width=lw)
    # Lens
    r = bh * 0.28
    cx, cy = sz / 2, by + bh / 2
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=lw)
    # Viewfinder bump
    vw, vh = bw * 0.3, bh * 0.25
    vx = sz / 2 - vw / 2
    d.rectangle([vx, by - vh + lw, vx + vw, by + lw], fill=WHITE)

make_action_icon("icon-rec",         icon_rec)
make_action_icon("icon-iso-up",      lambda d, sz: icon_iso(d, sz, True))
make_action_icon("icon-iso-down",    lambda d, sz: icon_iso(d, sz, False))
make_action_icon("icon-wb",          icon_wb)
make_action_icon("icon-lut",         icon_lut)
make_action_icon("icon-false-color", icon_false_color)
make_action_icon("icon-camera",      icon_camera)


# ─── Key icons (72x72) ────────────────────────────────────────────────────────

def make_key_icon(name, draw_fn):
    for sz in [72, 144]:
        img = canvas(sz)
        d = ImageDraw.Draw(img)
        draw_fn(d, sz, img)
        suffix = "" if sz == 72 else "@2x"
        path = os.path.join(IMGS, f"{name}{suffix}.png")
        img.save(path)
        print(f"  {path}")

def key_rec_idle(d, sz, img):
    cx = cy = sz / 2
    r = sz * 0.38
    lw = max(2, int(sz * 0.07))
    # White ring
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=lw)
    # Small REC dot
    ri = r * 0.28
    d.ellipse([cx - ri, cy - ri, cx + ri, cy + ri], fill=WHITE)
    # "REC" label
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", int(sz * 0.18))
    except Exception:
        font = ImageFont.load_default()
    bbox = d.textbbox((0, 0), "REC", font=font)
    tw = bbox[2] - bbox[0]
    d.text((cx - tw / 2 - bbox[0], cy + r * 0.55), "REC", font=font, fill=WHITE)

def key_rec_active(d, sz, img):
    cx = cy = sz / 2
    r = sz * 0.38
    lw = max(2, int(sz * 0.07))
    # Red filled circle
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=RED, outline=RED, width=lw)
    # "STOP" label
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", int(sz * 0.2))
    except Exception:
        font = ImageFont.load_default()
    bbox = d.textbbox((0, 0), "STOP", font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    d.text((cx - tw / 2 - bbox[0], cy - th / 2 - bbox[1]), "STOP", font=font, fill=WHITE)

def key_iso_up(d, sz, img):
    cx = cy = sz / 2
    lw = max(2, int(sz * 0.06))
    # ISO label
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", int(sz * 0.22))
    except Exception:
        font = ImageFont.load_default()
    bbox = d.textbbox((0, 0), "ISO", font=font)
    tw = bbox[2] - bbox[0]
    d.text((cx - tw / 2 - bbox[0], cy * 0.55), "ISO", font=font, fill=WHITE)
    # Up arrow
    ah = sz * 0.2
    hw = sz * 0.18
    ay = cy * 1.45
    d.polygon([(cx, ay - ah), (cx - hw, ay), (cx + hw, ay)], fill=WHITE)

def key_iso_down(d, sz, img):
    cx = cy = sz / 2
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", int(sz * 0.22))
    except Exception:
        font = ImageFont.load_default()
    bbox = d.textbbox((0, 0), "ISO", font=font)
    tw = bbox[2] - bbox[0]
    d.text((cx - tw / 2 - bbox[0], cy * 0.25), "ISO", font=font, fill=WHITE)
    ah = sz * 0.2
    hw = sz * 0.18
    ay = cy * 1.35
    d.polygon([(cx, ay + ah), (cx - hw, ay), (cx + hw, ay)], fill=WHITE)

def key_wb(d, sz, img):
    cx = cy = sz / 2
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", int(sz * 0.2))
    except Exception:
        font = ImageFont.load_default()
    d.text((cx - 18, cy * 0.3), "WB", font=font, fill=WHITE)
    # cycle arrow
    r = sz * 0.28
    lw = max(2, int(sz * 0.06))
    bbox = [cx - r, cy * 0.85, cx + r, cy * 0.85 + 2 * r]
    d.arc(bbox, start=60, end=300, fill=WHITE, width=lw)
    # arrowhead
    ex = cx + r * math.cos(math.radians(300))
    ey = cy * 0.85 + r + r * math.sin(math.radians(300))
    d.polygon([(ex, ey), (ex - 6, ey - 10), (ex + 6, ey - 10)], fill=WHITE)

def key_lut(d, sz, img):
    cx = cy = sz / 2
    m = sz * 0.15
    lw = max(2, int(sz * 0.06))
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", int(sz * 0.18))
    except Exception:
        font = ImageFont.load_default()
    d.text((m, m), "LUT", font=font, fill=WHITE)
    bar_h = sz * 0.1
    for i in range(3):
        y = cy + i * bar_h * 1.4
        w = (sz - 2 * m) * (0.9 - i * 0.15)
        d.rounded_rectangle([m, y, m + w, y + bar_h], radius=bar_h * 0.3, outline=WHITE, width=lw)

def key_lut_on(d, sz, img):
    cx = cy = sz / 2
    m = sz * 0.15
    lw = max(2, int(sz * 0.06))
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", int(sz * 0.18))
    except Exception:
        font = ImageFont.load_default()
    d.text((m, m), "LUT", font=font, fill=WHITE)
    # Filled bars for "on"
    bar_h = sz * 0.1
    for i in range(3):
        y = cy + i * bar_h * 1.4
        w = (sz - 2 * m) * (0.9 - i * 0.15)
        d.rounded_rectangle([m, y, m + w, y + bar_h], radius=bar_h * 0.3, fill=WHITE, width=lw)

def key_false_color(d, sz, img):
    cx = cy = sz / 2
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", int(sz * 0.16))
    except Exception:
        font = ImageFont.load_default()
    d.text((cx - 28, sz * 0.1), "FALSE", font=font, fill=WHITE)
    d.text((cx - 22, sz * 0.3), "COLOR", font=font, fill=WHITE)
    # Eye
    m = sz * 0.1
    ex, ey = cx, cy * 1.3
    ew, eh = (sz - 2 * m) * 0.9, (sz - 2 * m) * 0.4
    lw = max(2, int(sz * 0.06))
    d.arc([ex - ew/2, ey - eh, ex + ew/2, ey + eh * 0.3], start=210, end=330, fill=WHITE, width=lw)
    d.arc([ex - ew/2, ey - eh * 0.3, ex + ew/2, ey + eh], start=30, end=150, fill=WHITE, width=lw)
    ri = sz * 0.07
    d.ellipse([ex - ri, ey - ri, ex + ri, ey + ri], fill=WHITE)

def key_false_color_on(d, sz, img):
    key_false_color(d, sz, img)
    # Add filled eye pupil to indicate "on"
    cx = sz / 2
    ey = sz / 2 * 1.3
    ri = sz * 0.12
    d.ellipse([cx - ri, ey - ri, cx + ri, ey + ri], fill=WHITE)

def key_camera(d, sz, img):
    cx = cy = sz / 2
    m = sz * 0.12
    lw = max(2, int(sz * 0.06))
    bw = sz - 2 * m
    bh = bw * 0.65
    by = cy - bh / 2 + sz * 0.05
    d.rounded_rectangle([m, by, sz - m, by + bh], radius=lw * 2, outline=WHITE, width=lw)
    r = bh * 0.28
    d.ellipse([cx - r, cy + sz * 0.05 - r, cx + r, cy + sz * 0.05 + r], outline=WHITE, width=lw)
    vw, vh = bw * 0.3, bh * 0.25
    vx = cx - vw / 2
    d.rectangle([vx, by - vh + lw, vx + vw, by + lw], fill=WHITE)

make_key_icon("key-rec-idle",         key_rec_idle)
make_key_icon("key-rec-active",       key_rec_active)
make_key_icon("key-iso-up",           key_iso_up)
make_key_icon("key-iso-down",         key_iso_down)
make_key_icon("key-wb",               key_wb)
make_key_icon("key-lut-off",          key_lut)
make_key_icon("key-lut-on",           key_lut_on)
make_key_icon("key-false-color-off",  key_false_color)
make_key_icon("key-false-color-on",   key_false_color_on)
make_key_icon("key-camera",           key_camera)

# ── One-tap monitoring switches: a label, outlined when off, filled when on ─────────

def icon_toggle(d, sz):
    m = sz * 0.12
    lw = max(1, int(sz * 0.08))
    h = (sz - 2 * m) * 0.55
    y = (sz - h) / 2
    d.rounded_rectangle([m, y, sz - m, y + h], radius=h / 2, outline=WHITE, width=lw)
    r = h * 0.32
    cx, cy = sz - m - h / 2, sz / 2
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=WHITE)

def key_label(lines, on):
    def draw(d, sz, img):
        try:
            font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", int(sz * 0.17))
        except Exception:
            font = ImageFont.load_default()
        m = sz * 0.1
        lw = max(2, int(sz * 0.05))
        if on:
            d.rounded_rectangle([m, m, sz - m, sz - m], radius=sz * 0.12, fill=WHITE)
        else:
            d.rounded_rectangle([m, m, sz - m, sz - m], radius=sz * 0.12, outline=WHITE, width=lw)
        line_h = sz * 0.21
        top = sz / 2 - len(lines) * line_h / 2
        for i, line in enumerate(lines):
            w = d.textlength(line, font=font)
            d.text(((sz - w) / 2, top + i * line_h), line, font=font, fill=DK if on else WHITE)
    return draw

make_action_icon("icon-toggle", icon_toggle)
for name, lines in [("clean-feed", ["CLEAN", "FEED"]), ("status-text", ["STATUS", "TEXT"]), ("zebra", ["ZEBRA"]),
                    ("focus-assist", ["FOCUS", "ASSIST"]), ("frame-guides", ["FRAME", "GUIDES"]),
                    ("hdmi-info", ["HDMI", "INFO"]), ("grid-lines", ["GRID", "LINES"])]:
    make_key_icon(f"key-{name}-off", key_label(lines, False))
    make_key_icon(f"key-{name}-on", key_label(lines, True))

# ── Step, Any Control, Playback, Lock and timecode keys ───────────────────────

def icon_nd(d, sz, arrow_up=True):
    m = sz * 0.15
    lw = max(1, int(sz * 0.1))
    mid = sz / 2
    d.line([(m, mid), (sz - m, mid)], fill=WHITE, width=lw)
    ah = sz * 0.25
    hw = sz * 0.2
    if arrow_up:
        d.polygon([(mid, m), (mid - hw, mid - ah + m), (mid + hw, mid - ah + m)], fill=WHITE)
    else:
        d.polygon([(mid, sz - m), (mid - hw, sz - m - ah + m), (mid + hw, sz - m - ah + m)], fill=WHITE)

def icon_tint(d, sz, arrow_up=True):
    m = sz * 0.15
    lw = max(1, int(sz * 0.1))
    mid = sz / 2
    # diagonal line to suggest color temperature offset
    d.line([(m, mid + sz * 0.1), (sz - m, mid - sz * 0.1)], fill=WHITE, width=lw)
    ah = sz * 0.25
    hw = sz * 0.18
    if arrow_up:
        d.polygon([(mid, m), (mid - hw, mid - ah + m), (mid + hw, mid - ah + m)], fill=WHITE)
    else:
        d.polygon([(mid, sz - m), (mid - hw, sz - m - ah + m), (mid + hw, sz - m - ah + m)], fill=WHITE)

def icon_any_control(d, sz):
    m = sz * 0.15
    lw = max(1, int(sz * 0.1))
    cx, cy = sz / 2, sz / 2
    # gear-like circle with crosshairs
    r = (sz - 2 * m) / 2 - lw
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=lw)
    d.line([(cx, m), (cx, sz - m)], fill=WHITE, width=lw)
    d.line([(m, cy), (sz - m, cy)], fill=WHITE, width=lw)

def icon_playback(d, sz):
    m = sz * 0.15
    # Play triangle
    cx, cy = sz / 2, sz / 2
    h = (sz - 2 * m) * 0.7
    hw = h * 0.6
    d.polygon([(cx - hw * 0.4, cy - h / 2), (cx - hw * 0.4, cy + h / 2), (cx + hw * 0.6, cy)], fill=WHITE)

def icon_lock(d, sz):
    m = sz * 0.15
    lw = max(1, int(sz * 0.1))
    cx = sz / 2
    bw = (sz - 2 * m) * 0.7
    bh = bw * 0.7
    bx = cx - bw / 2
    by = sz * 0.5
    # body
    d.rounded_rectangle([bx, by, bx + bw, by + bh], radius=lw * 1.5, outline=WHITE, width=lw)
    # shackle
    sr = bw * 0.28
    sh = bh * 0.55
    d.arc([cx - sr, by - sh, cx + sr, by + sh * 0.2], start=180, end=0, fill=WHITE, width=lw)

def icon_tc_duration(d, sz):
    m = sz * 0.15
    lw = max(1, int(sz * 0.1))
    # Clock-like circle with tick marks
    cx, cy = sz / 2, sz / 2
    r = (sz - 2 * m) / 2
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=lw)
    # hands
    d.line([(cx, cy), (cx, cy - r * 0.55)], fill=WHITE, width=lw)
    d.line([(cx, cy), (cx + r * 0.4, cy)], fill=WHITE, width=lw)

make_action_icon("icon-nd-up",       lambda d, sz: icon_nd(d, sz, True))
make_action_icon("icon-nd-down",     lambda d, sz: icon_nd(d, sz, False))
make_action_icon("icon-tint-up",     lambda d, sz: icon_tint(d, sz, True))
make_action_icon("icon-tint-down",   lambda d, sz: icon_tint(d, sz, False))
make_action_icon("icon-any-control", icon_any_control)
make_action_icon("icon-playback",    icon_playback)
make_action_icon("icon-lock",        icon_lock)
make_action_icon("icon-tc-duration", icon_tc_duration)

# Key icons in the same label pattern as the monitoring switches

def key_nd_up(d, sz, img):
    cx = cy = sz / 2
    lw = max(2, int(sz * 0.06))
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", int(sz * 0.22))
    except Exception:
        font = ImageFont.load_default()
    bbox = d.textbbox((0, 0), "ND", font=font)
    tw = bbox[2] - bbox[0]
    d.text((cx - tw / 2 - bbox[0], cy * 0.55), "ND", font=font, fill=WHITE)
    ah = sz * 0.2
    hw = sz * 0.18
    ay = cy * 1.45
    d.polygon([(cx, ay - ah), (cx - hw, ay), (cx + hw, ay)], fill=WHITE)

def key_nd_down(d, sz, img):
    cx = cy = sz / 2
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", int(sz * 0.22))
    except Exception:
        font = ImageFont.load_default()
    bbox = d.textbbox((0, 0), "ND", font=font)
    tw = bbox[2] - bbox[0]
    d.text((cx - tw / 2 - bbox[0], cy * 0.25), "ND", font=font, fill=WHITE)
    ah = sz * 0.2
    hw = sz * 0.18
    ay = cy * 1.35
    d.polygon([(cx, ay + ah), (cx - hw, ay), (cx + hw, ay)], fill=WHITE)

def key_tint_up(d, sz, img):
    cx = cy = sz / 2
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", int(sz * 0.2))
    except Exception:
        font = ImageFont.load_default()
    bbox = d.textbbox((0, 0), "TINT", font=font)
    tw = bbox[2] - bbox[0]
    d.text((cx - tw / 2 - bbox[0], cy * 0.55), "TINT", font=font, fill=WHITE)
    ah = sz * 0.2
    hw = sz * 0.18
    ay = cy * 1.45
    d.polygon([(cx, ay - ah), (cx - hw, ay), (cx + hw, ay)], fill=WHITE)

def key_tint_down(d, sz, img):
    cx = cy = sz / 2
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFCompactRounded.ttf", int(sz * 0.2))
    except Exception:
        font = ImageFont.load_default()
    bbox = d.textbbox((0, 0), "TINT", font=font)
    tw = bbox[2] - bbox[0]
    d.text((cx - tw / 2 - bbox[0], cy * 0.25), "TINT", font=font, fill=WHITE)
    ah = sz * 0.2
    hw = sz * 0.18
    ay = cy * 1.35
    d.polygon([(cx, ay + ah), (cx - hw, ay), (cx + hw, ay)], fill=WHITE)

make_key_icon("key-nd-up",   key_nd_up)
make_key_icon("key-nd-down", key_nd_down)
make_key_icon("key-tint-up",   key_tint_up)
make_key_icon("key-tint-down", key_tint_down)

for name, lines in [("any-control", ["ANY", "CTRL"]), ("playback-idle", ["▶"]),
                    ("lock-off", ["🔓"]), ("lock-on", ["🔒"]),
                    ("tc-duration-off", ["TC"]), ("tc-duration-on", ["DUR"])]:
    make_key_icon(f"key-{name}", key_label(lines, False))

make_key_icon("key-playback-active", key_label(["▶"], True))
make_key_icon("key-any-control-off", key_label(["ANY", "CTRL"], False))
make_key_icon("key-any-control-on",  key_label(["ANY", "CTRL"], True))
make_key_icon("key-lock-on",         key_label(["LOCK"], True))
make_key_icon("key-lock-off",        key_label(["LOCK"], False))
make_key_icon("key-tc-duration-on",  key_label(["DUR"], True))
make_key_icon("key-tc-duration-off", key_label(["TC"], False))

# ── FX6 lens drives and assignable buttons ──────────────────────────────────

def icon_focus(d, sz):
    m = sz * 0.15
    lw = max(1, int(sz * 0.1))
    cx, cy = sz / 2, sz / 2
    # Lens ring
    r = (sz - 2 * m) / 2
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=lw)
    # Inner dot representing focal point
    ri = r * 0.25
    d.ellipse([cx - ri, cy - ri, cx + ri, cy + ri], fill=WHITE)

def icon_zoom(d, sz):
    m = sz * 0.15
    lw = max(1, int(sz * 0.1))
    cx, cy = sz / 2, sz / 2
    # Outer lens ring
    r = (sz - 2 * m) / 2
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=lw)
    # Inner ring (zoom lens)
    ri = r * 0.5
    d.ellipse([cx - ri, cy - ri, cx + ri, cy + ri], outline=WHITE, width=lw)

def icon_assignable(d, sz):
    m = sz * 0.15
    lw = max(1, int(sz * 0.1))
    # Rounded rect representing a physical button
    d.rounded_rectangle([m, m * 1.5, sz - m, sz - m * 1.5], radius=lw * 2, outline=WHITE, width=lw)
    # Star / asterisk to suggest assignable function
    cx, cy = sz / 2, sz / 2
    for angle in range(0, 180, 60):
        rad = math.radians(angle)
        x1 = cx + (sz * 0.22) * math.cos(rad)
        y1 = cy + (sz * 0.22) * math.sin(rad)
        x2 = cx - (sz * 0.22) * math.cos(rad)
        y2 = cy - (sz * 0.22) * math.sin(rad)
        d.line([(x1, y1), (x2, y2)], fill=WHITE, width=lw)

def icon_autofocus(d, sz):
    # A focus frame's four corners round a center dot
    m = sz * 0.18
    lw = max(1, int(sz * 0.1))
    arm = sz * 0.2
    for x, dx in ((m, 1), (sz - m, -1)):
        for y, dy in ((m, 1), (sz - m, -1)):
            d.line([(x, y), (x + dx * arm, y)], fill=WHITE, width=lw)
            d.line([(x, y), (x, y + dy * arm)], fill=WHITE, width=lw)
    r = sz * 0.08
    d.ellipse([sz / 2 - r, sz / 2 - r, sz / 2 + r, sz / 2 + r], fill=WHITE)

make_action_icon("icon-focus",      icon_focus)
make_action_icon("icon-zoom",       icon_zoom)
make_action_icon("icon-assignable", icon_assignable)
make_action_icon("icon-autofocus",  icon_autofocus)

for name, lines in [("focus", ["FOCUS"]), ("zoom", ["ZOOM"]), ("assignable", ["ASGN"]), ("autofocus", ["PUSH", "AF"])]:
    make_key_icon(f"key-{name}", key_label(lines, False))

print("Done.")
