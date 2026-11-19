#!/usr/bin/env python3
"""Decode a Blackmagic camera preset (.cset): protobuf, sections of {1: name, 2: settings message}. No schema: prints
the wire format, field numbers and values, so two presets can be diffed."""
import sys


def varint(b, i):
    shift = value = 0
    while True:
        byte = b[i]
        i += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return value, i


def parse(b):
    """[(field, wiretype, value)] or None when b isn't a well-formed message."""
    out, i = [], 0
    try:
        while i < len(b):
            key, i = varint(b, i)
            field, wt = key >> 3, key & 7
            if field == 0:
                return None
            if wt == 0:
                v, i = varint(b, i)
            elif wt == 1:
                v, i = b[i:i + 8], i + 8
            elif wt == 2:
                n, i = varint(b, i)
                v, i = b[i:i + n], i + n
                if i > len(b):
                    return None
            elif wt == 5:
                v, i = b[i:i + 4], i + 4
            else:
                return None
            out.append((field, wt, v))
    except IndexError:
        return None
    return out


def show(b, indent=0, path=""):
    fields = parse(b)
    for field, wt, v in fields:
        p = f"{path}.{field}" if path else str(field)
        pad = "  " * indent
        if wt == 2:
            nested = parse(v) if v else None
            text = None
            try:
                t = v.decode("utf-8")
                if t.isprintable():
                    text = t
            except UnicodeDecodeError:
                pass
            if nested and not (text and len(text) > 2 and not any(c < 0x20 for c in v)):
                print(f"{pad}{p}: {{")
                show(v, indent + 1, p)
                print(f"{pad}}}")
            elif text is not None:
                print(f"{pad}{p}: {text!r}")
            else:
                print(f"{pad}{p}: bytes {v.hex()}")
        elif wt == 0:
            print(f"{pad}{p}: {v}")
        else:
            print(f"{pad}{p}: fixed {v.hex()}")


def sections(b):
    out = {}
    for field, wt, v in parse(b):
        if field == 10 and wt == 2:
            entry = dict((f, val) for f, _, val in parse(v))
            out[entry[1].decode()] = entry.get(2, b"")
    return out


if __name__ == "__main__":
    data = open(sys.argv[1], "rb").read()
    secs = sections(data)
    if len(sys.argv) == 2:
        for name, body in secs.items():
            print(f"{name}: {len(body)} bytes")
    else:
        for name in sys.argv[2:]:
            print(f"== {name}")
            show(secs[name])
