#!/usr/bin/env python3
"""Compares two PNGs pixel by pixel: how many differ, the largest channel difference, and the regions they're in.

    pixdiff.py a.png b.png [diff.png]

Exits 0 when they're identical, 1 when they differ (or differ in size). diff.png, if given, marks the differences.
"""
import sys

from PIL import Image, ImageChops


def regions(mask, size, cell=16):
    """Bounding boxes of the differing pixels, merged on a coarse grid."""
    w, h = size
    cells = set()
    for y in range(h):
        for x in range(w):
            if mask[x, y]:
                cells.add((x // cell, y // cell))
    boxes = []
    for cx, cy in sorted(cells):
        box = [cx * cell, cy * cell, (cx + 1) * cell, (cy + 1) * cell]
        for other in boxes:
            if box[0] <= other[2] and other[0] <= box[2] and box[1] <= other[3] and other[1] <= box[3]:
                other[0], other[1] = min(other[0], box[0]), min(other[1], box[1])
                other[2], other[3] = max(other[2], box[2]), max(other[3], box[3])
                break
        else:
            boxes.append(box)
    return boxes


def main():
    a, b = Image.open(sys.argv[1]).convert("RGBA"), Image.open(sys.argv[2]).convert("RGBA")
    if a.size != b.size:
        print(f"sizes differ: {a.size} and {b.size}")
        return 1
    diff = ImageChops.difference(a, b)
    channel_max = max(hi for _, hi in diff.getextrema())
    differs = diff.convert("L").point(lambda v: 255 if v else 0)
    count = differs.histogram()[255]
    boxes = regions(differs.load(), a.size) if count else []
    print(f"{count} pixels differ, max channel delta {channel_max}, {len(boxes)} regions")
    for box in boxes[:10]:
        print(f"  region ({box[0]}, {box[1]}, {box[2]}, {box[3]})")
    if len(sys.argv) > 3 and count:
        marked = b.convert("RGB")
        marked.paste((255, 0, 255), mask=differs)
        marked.save(sys.argv[3])
    return 1 if count else 0


if __name__ == "__main__":
    sys.exit(main())
