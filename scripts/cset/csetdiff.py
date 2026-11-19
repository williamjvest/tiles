#!/usr/bin/env python3
"""Diff two Blackmagic presets (.cset) field by field: section, wire path, before → after."""
import sys
from cset import parse, sections


def flatten(b, path=""):
    out = {}
    fields = parse(b) or []
    seen = {}
    for field, wt, v in fields:
        seen[field] = seen.get(field, 0) + 1
        p = f"{path}.{field}" if path else str(field)
        if seen[field] > 1:
            p += f"[{seen[field] - 1}]"
        if wt == 2:
            nested = parse(v) if v else None
            printable = False
            try:
                printable = bool(v) and v.decode("utf-8").isprintable()
            except UnicodeDecodeError:
                pass
            if nested and not printable:
                out.update(flatten(v, p))
            else:
                out[p] = v.decode("utf-8", "replace") if printable else v.hex()
        elif wt == 0:
            out[p] = v
        else:
            out[p] = v.hex()
    return out


a, b = (sections(open(f, "rb").read()) for f in sys.argv[1:3])
for name in sorted(set(a) | set(b)):
    fa, fb = flatten(a.get(name, b"")), flatten(b.get(name, b""))
    for key in sorted(set(fa) | set(fb), key=lambda k: [int(x.split("[")[0]) for x in k.split(".")]):
        if fa.get(key) != fb.get(key):
            print(f"{name}  {key}: {fa.get(key)} -> {fb.get(key)}")
