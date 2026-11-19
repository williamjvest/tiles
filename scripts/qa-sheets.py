#!/usr/bin/env python3
"""Contact sheets for a scripts/qa-screens.sh run: phones and iPads, each in portrait and in landscape, a row per
device and a column per capture (in use, edit mode, then the offline PYXIS in Test Mode and in edit mode, then the
demo cameras' A+B page in use and in edit mode). Every
capture is turned upright and scaled to one height, whatever the device's resolution, so they compare side by side.

  uv run --with pillow python3 scripts/qa-sheets.py qa-out/<run>

Writes phones-portrait.png, phones-landscape.png, pads-portrait.png and pads-landscape.png into the run's folder.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

CAPTURES = ["normal", "edit", "pyxis-test", "pyxis-edit", "lineup", "lineup-b", "lineup-edit"]
HEIGHT = {"portrait": 820, "landscape": 440}
PAD, LABEL = 12, 34


def upright(img: Image.Image, orientation: str) -> Image.Image:
    # XCUIScreen hands a landscape capture over in the screen's own portrait orientation: turn it a quarter left.
    if orientation == "landscape" and img.height > img.width:
        return img.rotate(90, expand=True)
    if orientation == "portrait" and img.width > img.height:
        return img.rotate(-90, expand=True)
    return img


def main(run: Path) -> None:
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 24)
    groups = {"phones": "iPhone", "pads": "iPad"}
    for group, prefix in groups.items():
        devices = sorted(d for d in run.iterdir() if d.is_dir() and d.name.startswith(prefix))
        for orientation, height in HEIGHT.items():
            rows = []
            for device in devices:
                shots = []
                for capture in CAPTURES:
                    path = device / f"{orientation}-{capture}.png"
                    if not path.exists():
                        continue
                    img = upright(Image.open(path).convert("RGB"), orientation)
                    shots.append((capture, img.resize((round(img.width * height / img.height), height), Image.LANCZOS)))
                if shots:
                    rows.append((device.name.strip("-"), shots))
            if not rows:
                continue
            width = max(sum(img.width + PAD for _, img in shots) for _, shots in rows) + PAD
            sheet = Image.new("RGB", (width, len(rows) * (LABEL + height + PAD) + PAD), (40, 40, 44))
            draw = ImageDraw.Draw(sheet)
            y = PAD
            for name, shots in rows:
                x = PAD
                for capture, img in shots:
                    draw.text((x, y + 4), f"{name}  {capture}", font=font, fill=(230, 230, 230))
                    sheet.paste(img, (x, y + LABEL))
                    x += img.width + PAD
                y += LABEL + height + PAD
            out = run / f"{group}-{orientation}.png"
            sheet.save(out)
            print(f"  saved {out} {sheet.size[0]}x{sheet.size[1]}")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
